// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel
import RuntimeEvents

/// The one configuration owner of one `RuntimeHost` (decisions 0015, 0025, 0027, 0031 and 0032). It holds the sole
/// `ConfigurationStore` privately. It owns the intent generation, the synchronous Start and Stop admissions and the session Stop fence.
/// The store has no intent counter of its own, and nothing else in the host writes configuration.
///
/// The operations return typed `ConfigurationWorkflowEvent` values, and the host emits them. The workflow never emits or logs, so
/// there is one emitter per host (decision 0031).
///
/// Admission rules:
/// - A Start is admitted synchronously, before launch recovery is awaited. Its preparation checks the same admission again after the
///   join and after its commit, so a newer Stop is never cleared by it.
/// - A Stop fences at once. Its cleanup still waits for recovery, but its fence does not wait for anything.
/// - Only a Start clears the fence. A reload never clears it, and it never restores an enabled flag a Stop left behind.
/// - A reload captures the generation before its read and compares it after. A stale observation stays a durable observation, but it
///   cannot change the applied view, the reconciler's requested configuration or its retry baseline.
@MainActor
final class RuntimeConfigurationWorkflow {
    /// One admitted facade Start: the group the module intents gave it. It is current while that group is the latest admission and still
    /// holds a member.
    struct StartTicket: Equatable, Sendable {
        let lifecycle: RuntimeLifecycleTicket

        var generation: Int { lifecycle.group }
    }

    /// What `open` observed. `values` is the store's adopted observation, read before any baseline or reconciler exists.
    struct Opened {
        let values: ConfigurationValues
        let events: [ConfigurationWorkflowEvent]

        var config: ProxyConfig { values.runtime }
        var platformConfig: PlatformIntegrationConfig { values.platform }
        var appPreferences: AppPreferences { values.preferences }
    }

    /// Why `startRuntime` did not start. The typed `config.workflow` event carries the reason; the entry point logs this error's
    /// description, as it logs a failed start.
    enum StartRefusal: LocalizedError, Equatable, Sendable {
        /// The required inputs did not verify, or the runtime input blocks a start. Nothing was started.
        case held
        /// The workflow's intent generation is at its maximum, so this Start was not admitted.
        case intentExhausted
        /// A terminal stop has latched, so no Start runs in this process.
        case terminated
        /// This Start joined an identical Start in flight, and that Start ended without leaving the runtime running. This call does not
        /// claim a start that did not happen.
        case notRunning

        var errorDescription: String? {
            switch self {
            case .held: "the configuration inputs did not verify or block a start, so nothing was started"
            case .intentExhausted: "the intent generation is at its maximum, so the start was not admitted"
            case .terminated: "a terminal stop has latched, so no start runs in this process"
            case .notRunning: "the identical start this call joined ended without leaving the runtime running"
            }
        }
    }

    /// `open` refused the startup inputs. The daemon reports `event` and exits, as it does for a failed load.
    struct OpenRefusal: Error {
        let event: ConfigurationWorkflowEvent
    }

    enum StartPreparation {
        /// The required inputs verified as one exact pair, and the admission still stands.
        case ready(VerifiedRuntimePlatformInput)
        /// The required inputs did not verify, or the runtime input blocks a start. The prior applied configuration keeps running.
        case held
        /// A newer Start or Stop was admitted, so this Start stops without applying anything.
        case superseded
    }

    struct StartOutcome {
        let preparation: StartPreparation
        let events: [ConfigurationWorkflowEvent]
    }

    struct ReloadOutcome {
        let events: [ConfigurationWorkflowEvent]
        /// The runtime and platform inputs the host may apply. `nil` keeps the applied view and the reconciler's baseline as they are.
        let applied: (runtime: ProxyConfig, platform: PlatformIntegrationConfig)?
        /// The preferences the observation adopted. They are independent of the apply hold, and a stale observation adopts none.
        let preferences: AppPreferences?
    }

    private let store: ConfigurationStore
    private let startupAllowsMissing: Bool
    private let incarnation = ControlHostIncarnation(rawValue: UUID())
    /// The one per-module intent the workflow owns (decisions 0035 and 0036). The write claims read it from the platform queue, so it sits
    /// behind a short lock that no I/O holds.
    private let intent: NIOLockedValueBox<RuntimeModuleIntents>
    /// Store-using operations begun and not yet returned to the host. A settle reads it, so no host reports settled while a read,
    /// a required commit or a reload can still write.
    private var operationsInFlight = 0

    /// Whether no store-using operation is in flight on this workflow. Read on the main actor.
    var isIdle: Bool {
        operationsInFlight == 0
    }

    /// - Parameter startupAllowsMissing: the startup's explicit `allowMissing`. A reload uses the same value, so it keeps the combinations
    ///   the loader accepts at startup, and an explicit `--config` start keeps its refusal of a missing runtime file.
    /// - Parameter generation: the intent generation before the first admission. The host always starts at 0; a test seeds it near
    ///   `Int.max` to reach the exhausted branches.
    init(store: ConfigurationStore, startupAllowsMissing: Bool, generation: Int = 0) {
        precondition(generation >= 0, "an intent generation is never negative")
        self.store = store
        self.startupAllowsMissing = startupAllowsMissing
        // DNS's configured intent is the store's adopted value, set by `open` before any admission.
        self.intent = NIOLockedValueBox(RuntimeModuleIntents(counter: generation, dnsEnabled: false))
    }

    /// Whether the whole-host Stop fence is in force: every module is fenced. Read on the main actor, for the host's view of its own
    /// admission. A Stop of one module fences only that module.
    var stopFenced: Bool {
        intent.withLockedValue { $0.allFenced }
    }

    /// The counter value the latest admission took. Read on the main actor.
    var generation: Int {
        intent.withLockedValue { $0.counter }
    }

    // MARK: - Open

    /// The one startup observation, through the store, before any baseline exists. Nothing is written. A refused observation throws,
    /// because the host cannot run from it.
    func open() async throws -> Opened {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        let report = await store.load(context: context(generation: generation), allowMissing: startupAllowsMissing)
        guard case .admitted(let loaded) = report else {
            throw OpenRefusal(event: .observed(ConfigurationWorkflowObserved(phase: .startup, observation: .refused(.busy))))
        }
        switch loaded.outcome {
        case .refused(let refusal):
            let mapped = Self.refusal(refusal)
            throw OpenRefusal(event: .observed(ConfigurationWorkflowObserved(phase: .startup, observation: .refused(mapped))))
        case .adopted:
            guard let values = store.values else {
                preconditionFailure("an adopted observation carries its values")
            }
            let counter = generation
            intent.withLockedValue { $0 = RuntimeModuleIntents(counter: counter, dnsEnabled: values.runtime.dnsForwarderEnabled) }
            return Opened(
                values: values,
                events: [.observed(ConfigurationWorkflowObserved(phase: .startup, observation: .adopted))]
            )
        }
    }

    // MARK: - Start and Stop admission

    /// Admits the whole-host facade Start: proxy and tunnels Starts and DNS's configured Start, as one group. Synchronous, before any
    /// suspension. The fences stay until `authorize`, after the verified pair is adopted. Returns `nil` when the request is refused, and
    /// a refusal changes nothing.
    func admitStart() -> StartTicket? {
        let facade = RuntimeLifecycleRequest(actions: PrivateModuleSlots(proxy: .start, dns: .configuredStart, tunnels: .start))
        return intent.withLockedValue { state in
            guard case .success(let ticket) = state.admit(facade) else { return nil }
            return StartTicket(lifecycle: ticket)
        }
    }

    /// Admits a whole-host Stop. Synchronous, and it fences every module at once, before any save or recovery is awaited. The legacy
    /// facade persists no DNS disable. The counter advances when it can; the fence holds either way, so a Stop at the maximum still
    /// refuses every older Start and claim. A terminal stop is the process quit, which also latches.
    @discardableResult
    func admitStop(terminal: Bool = false) -> Int {
        intent.withLockedValue { $0.stop(Set(ControlModule.allCases), reason: terminal ? .processQuit : .facade) }
    }

    /// Authorizes a Start whose verified pair the host has adopted: its members gain the permission the facade grants and lose their
    /// fences. Returns false when the ticket no longer stands.
    func authorize(_ ticket: StartTicket) -> Bool {
        intent.withLockedValue { !$0.authorize(ticket.lifecycle).isEmpty }
    }

    /// Settles a Start's effect. A failure restores each member's prior permission and fence and advances the counter, so a reload or a
    /// pass admitted under that Start stops, and the host's revert then runs under the lane token. At the maximum the counter cannot
    /// advance, so the member is fenced instead. A ticket a newer admission replaced changes nothing.
    func finishStart(_ ticket: StartTicket, succeeded: Bool) {
        intent.withLockedValue { state in
            for module in ControlModule.allCases {
                state.settle(module, ticket: ticket.lifecycle, succeeded: succeeded)
            }
        }
    }

    /// Ends a held or superseded Start before authorization. Its members keep the permission and fence they had, and a newer operation in
    /// a member's slot is not touched.
    func retire(_ ticket: StartTicket) {
        intent.withLockedValue { $0.retire(ticket.lifecycle) }
    }

    /// Ends a Start that failed after it was authorized: `finishStart` with a failure.
    func endFailedStart(_ ticket: StartTicket) {
        finishStart(ticket, succeeded: false)
    }

    /// Whether a terminal stop has latched. Read on the main actor.
    var isTerminal: Bool {
        intent.withLockedValue { $0.terminal }
    }

    /// The typed event for a Start that stopped after it was admitted: a newer generation, or a Stop fence at the maximum.
    func supersession(of ticket: StartTicket) -> [ConfigurationWorkflowEvent] {
        staleEvents(.start, generation: ticket.generation, current: generation)
    }

    /// The typed event for a Start refused after a terminal stop latched.
    func terminalRefusal() -> [ConfigurationWorkflowEvent] {
        [held(.start, .unit, .terminating)]
    }

    /// Whether `generation` is still the latest admitted intent. A Stop that resumes after recovery uses it to stop once a newer Start
    /// or Stop owns the surfaces.
    func isLatest(_ generation: Int) -> Bool {
        self.generation == generation
    }

    /// Whether the admission still stands: no newer Start or Stop has been admitted, and its group still holds a member.
    func isCurrent(_ ticket: StartTicket) -> Bool {
        intent.withLockedValue { $0.holdsGroup(ticket.lifecycle) }
    }

    /// The claim the store checks before each replacement this Start makes. It holds only while the admission stands.
    func writeClaim(for ticket: StartTicket) -> ConfigurationWriteClaim {
        let intent = self.intent
        let lifecycle = ticket.lifecycle
        return ConfigurationWriteClaim {
            intent.withLockedValue { $0.holdsGroup(lifecycle) }
        }
    }

    // MARK: - Start preparation

    /// Prepares a Start after launch recovery. It checks the admission first, refuses a runtime input that blocks a start without any I/O,
    /// and commits the required inputs through the store. Absent defaults are persisted here, before the Start. A present file that
    /// verifies is verified without a rewrite. The admission is checked again after the commit, and the exact pair is returned only when
    /// both required receipts verified.
    func prepareStart(_ ticket: StartTicket) async -> StartOutcome {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        guard isCurrent(ticket) else {
            return StartOutcome(preparation: .superseded, events: staleEvents(.start, generation: ticket.generation, current: generation))
        }
        guard var values = store.values else {
            return StartOutcome(preparation: .held, events: [held(.start, .unit, .commitFailed)])
        }
        // The store's adopted DNS bit is a durable fact, observed here too, so a reload that adopted it before its own resumption cannot
        // be written over. When it changes what this group staged, the admission no longer stands and nothing is written (decision 0035).
        let adoptedDNS = values.runtime.dnsForwarderEnabled
        intent.withLockedValue { $0.observeDurableDNS(adoptedDNS) }
        guard isCurrent(ticket) else {
            return StartOutcome(preparation: .superseded, events: staleEvents(.start, generation: ticket.generation, current: generation))
        }
        // The write carries the DNS intent the group was admitted on. For the facade that is the adopted value just checked; only a
        // local DNS Start or Stop intent differs from the file.
        values.runtime.dnsForwarderEnabled = ticket.lifecycle.dnsStaged
        if values.runtime.validate().contains(where: \.blocksProxyStart) {
            return StartOutcome(preparation: .held, events: [held(.start, .runtime, .startBlocking)])
        }
        let expected = ConfigurationSlots(
            runtime: store.baselineToken(for: .runtime),
            platform: store.baselineToken(for: .platform),
            preferences: nil
        )
        let admission = await store.commitRuntimeAndPlatform(
            values.runtime,
            values.platform,
            expecting: expected,
            context: context(generation: ticket.generation),
            claim: writeClaim(for: ticket)
        )
        // A busy slot means no required commit verified, so the Start holds as a failed commit.
        guard case .admitted(let result) = admission else {
            return StartOutcome(preparation: .held, events: [held(.start, .unit, .commitFailed)])
        }
        var events = [
            committed(.runtime, result.runtime),
            committed(.platform, result.platform),
        ]
        // A verified runtime file is a saved fact before any check below can end the Start (decision 0015).
        if result.runtime.isVerified {
            let staged = values.runtime.dnsForwarderEnabled
            intent.withLockedValue { $0.recordVerifiedDNSWrite(staged, for: ticket.lifecycle) }
        }
        // The admission is checked again after the commit's suspension. A committed file keeps its persistence even if the Start stops.
        guard isCurrent(ticket) else {
            events += staleEvents(.start, generation: ticket.generation, current: generation)
            return StartOutcome(preparation: .superseded, events: events)
        }
        if let verified = result.verifiedInput {
            return StartOutcome(preparation: .ready(verified), events: events)
        }
        if result.platform.isVerified {
            events.append(held(.start, .runtime, .commitFailed))
        } else {
            events.append(held(.start, .platform, .commitFailed))
            if case .notAttempted(.heldBehindPlatform) = result.runtime {
                events.append(held(.start, .runtime, .heldBehind))
            }
        }
        return StartOutcome(preparation: .held, events: events)
    }

    // MARK: - Reload

    /// An explicit reload: one read-only observation through the store, then adoption and the eligibility decision. `captured` is the
    /// generation the caller read before its first suspension, launch recovery included, so an admission made during that wait makes
    /// this observation stale. Nothing is written, so a reload never writes a migration or a default.
    func reload(capturedAt captured: Int) async -> ReloadOutcome {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        let report = await store.load(context: context(generation: captured), allowMissing: startupAllowsMissing)
        guard case .admitted(let loaded) = report else {
            return ReloadOutcome(
                events: [.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(.busy)))],
                applied: nil,
                preferences: nil
            )
        }
        switch loaded.outcome {
        case .refused(let refusal):
            return ReloadOutcome(
                events: [.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(Self.refusal(refusal))))],
                applied: nil,
                preferences: nil
            )
        case .adopted:
            var events: [ConfigurationWorkflowEvent] = [
                .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .adopted)),
            ]
            guard let values = store.values else {
                preconditionFailure("an adopted observation carries its values")
            }
            // The adopted DNS bit is a durable fact whether or not this observation may apply; the intents keep any fence, pending Start or
            // owed save, and the observation never raises a permission.
            intent.withLockedValue { $0.observeDurableDNS(values.runtime.dnsForwarderEnabled) }
            // A newer intent that landed during the read makes this observation stale. It stays a durable observation, and nothing applies.
            let current = generation
            guard current == captured else {
                events += staleEvents(.reload, generation: captured, current: current)
                return ReloadOutcome(events: events, applied: nil, preferences: nil)
            }
            let applied = eligibleInput(values, events: &events)
            return ReloadOutcome(events: events, applied: applied, preferences: values.preferences)
        }
    }

    /// The runtime and platform the host may apply, or nil with a held event. Preferences are not in this decision.
    private func eligibleInput(
        _ values: ConfigurationValues,
        events: inout [ConfigurationWorkflowEvent]
    ) -> (runtime: ProxyConfig, platform: PlatformIntegrationConfig)? {
        if stopFenced {
            events.append(held(.reload, .unit, .stopFenced))
            return nil
        }
        // Decision 0032: a present required file is valid reload authority when this observation verified it, with matching adopted
        // baselines. A valid external edit needs no commit receipt, because the reload writes nothing. An absent required file is
        // uncommitted, and a later explicit Start commits its defaults first.
        guard store.isPresent(.runtime), store.isPresent(.platform) else {
            events.append(held(.reload, .unit, .uncommitted))
            return nil
        }
        if values.runtime.validate().contains(where: \.blocksProxyStart) {
            events.append(held(.reload, .runtime, .startBlocking))
            return nil
        }
        return (values.runtime, values.platform)
    }

    // MARK: - Mapping

    private func context(generation: Int) -> ConfigurationOperationContext {
        guard let ordinal = PrivateConfigExpectedGeneration(rawValue: generation) else {
            preconditionFailure("an intent generation is never negative")
        }
        return ConfigurationOperationContext(
            requestID: ControlRequestID(rawValue: UUID()),
            hostIncarnation: incarnation,
            expectedOwnerGeneration: ordinal
        )
    }

    private func held(
        _ phase: ConfigurationWorkflowIntentPhase,
        _ input: ConfigurationWorkflowHeldInput,
        _ reason: ConfigurationWorkflowHoldReason
    ) -> ConfigurationWorkflowEvent {
        .held(ConfigurationWorkflowHeld(phase: phase, input: input, reason: reason))
    }

    private func committed(_ file: ConfigurationWorkflowFile, _ outcome: ConfigurationWriteOutcome) -> ConfigurationWorkflowEvent {
        .committed(ConfigurationWorkflowCommitted(file: file, write: Self.write(outcome)))
    }

    /// The event for an admission that stopped under `generation`. A newer generation is `superseded`. The only other way one stops is a
    /// Stop fence at the maximum generation, which cannot advance, so that stop is reported as the closed fence hold.
    private func staleEvents(
        _ phase: ConfigurationWorkflowIntentPhase,
        generation: Int,
        current: Int
    ) -> [ConfigurationWorkflowEvent] {
        if ConfigurationWorkflowSuperseded.isValid(phase: phase, generation: generation, current: current) {
            return [.superseded(ConfigurationWorkflowSuperseded(phase: phase, generation: generation, current: current))]
        }
        return [held(phase, .unit, .stopFenced)]
    }

    private static func file(_ component: ConfigurationComponent) -> ConfigurationWorkflowFile {
        switch component {
        case .runtime: .runtime
        case .platform: .platform
        case .preferences: .preferences
        }
    }

    static func refusal(_ refusal: ConfigurationLoadRefusal) -> ConfigurationWorkflowRefusal {
        switch refusal {
        case .unreadable(let component, _): .unreadable(file(component))
        case .journalPresenceUnknown: .journalPresenceUnknown
        case .invalidContent: .invalidContent
        case .unexpected: .unexpected
        case .versionExhausted(let component): .versionExhausted(file(component))
        }
    }

    static func write(_ outcome: ConfigurationWriteOutcome) -> ConfigurationWorkflowWrite {
        switch outcome {
        case .persisted(_, let reported): .persisted(reportedError: reported != nil)
        case .unchanged: .unchanged
        case .notPersisted: .notPersisted
        case .unknown(let reason, let reported):
            .unknown(unknownCause(reason), reportedError: reported != nil)
        case .conflict: .conflict
        case .notAttempted(let reason): .notAttempted(notAttemptedCause(reason))
        }
    }

    private static func unknownCause(_ reason: ConfigurationFileUnknownReason) -> ConfigurationWorkflowUnknownCause {
        switch reason {
        case .readbackDiffers: .readbackDiffers
        case .readbackMissing: .readbackMissing
        case .readbackFailed: .readbackFailed
        }
    }

    private static func notAttemptedCause(_ reason: ConfigurationNotAttemptedReason) -> ConfigurationWorkflowNotAttemptedCause {
        switch reason {
        case .noAuthoritativeBaseline: .noBaseline
        case .baselineMismatch: .baselineMismatch
        case .stagingRefused: .stagingRefused
        case .preReadFailed: .preReadFailed
        case .refused: .replacementRefused
        case .heldBehindPlatform: .heldBehindPlatform
        case .heldBehindRuntime: .heldBehindRuntime
        case .preservationHeld: .preservationHeld
        case .sourceChanged: .sourceChanged
        case .sourceUnreadable: .sourceUnreadable
        case .versionExhausted: .versionExhausted
        case .superseded: .superseded
        }
    }
}
