// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel
import RuntimeEvents

/// Why the host's `startRuntime` facade did not start, its typed thrown outcome. The typed `config.workflow` event carries the reason; the
/// entry point logs this error's description, as it logs a failed start. No case carries a configuration value.
package enum RuntimeStartRefusal: LocalizedError, Equatable, Sendable {
    /// The required inputs did not verify, or the runtime input blocks a start. Nothing was started.
    case held
    /// The workflow's intent generation is at its maximum, so this Start was not admitted.
    case intentExhausted
    /// A terminal stop has latched, so no Start runs in this process.
    case terminated
    /// This Start joined a start in flight, an identical host Start or the kernel's proxy start, and that start ended without leaving the
    /// runtime running. This call does not claim a start that did not happen.
    case notRunning
    /// DNS still owes a session Stop's disable save, which this Start may not displace. Nothing was admitted.
    case stopSaveOwed
    /// A newer Start or Stop was admitted, or the saved input this Start captured no longer stands (changed, or its baseline lost or
    /// refused by a reload), before its effects. Completed saves stay reported; the remaining work did not run and is not retried.
    case superseded
    /// The revision the request named for this module moved since it was observed, so the whole request was refused at admission and
    /// nothing changed (decision 0035).
    case stale(ControlModule)

    package var errorDescription: String? {
        switch self {
        case .held: "the configuration inputs did not verify or block a start, so nothing was started"
        case .intentExhausted: "the intent generation is at its maximum, so the start was not admitted"
        case .terminated: "a terminal stop has latched, so no start runs in this process"
        case .notRunning: "the start this call joined ended without leaving the runtime running"
        case .stopSaveOwed: "DNS still owes a stop's disable save, so the start was not admitted"
        case .superseded: "a newer start or stop, or a change or loss of the saved input it captured, ended this start before it ran"
        case .stale(let module): "the \(module.rawValue) revision moved since it was observed, so the whole request was refused"
        }
    }

    /// The hold reason of a refusal made at admission, which the host reports as the typed event.
    var admissionReason: ConfigurationWorkflowHoldReason? {
        switch self {
        case .intentExhausted: .intentExhausted
        case .terminated: .terminating
        case .stopSaveOwed: .stopSaveOwed
        case .stale: .staleRevision
        case .held, .notRunning, .superseded: nil
        }
    }
}

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
    /// holds a member. It carries no configuration value until its preparation captures one (decision 0037).
    struct StartTicket: Equatable, Sendable {
        fileprivate(set) var lifecycle: RuntimeLifecycleTicket
        /// The client request this Start follows, which every store context of its preparation names. Nil for the host's own facade,
        /// which has no client request, so each of its store calls names a fresh one.
        let requestID: ControlRequestID?

        var generation: Int { lifecycle.group }
    }

    /// A Start whose preparation captured the store's saved pair once and verified it through the required commit (decision 0037). The
    /// effects that follow use this pair only. It is current while its group stands and the store's baselines are still the ones its
    /// receipts name, so a newer observation or write of either file holds the remaining work instead of rebinding it.
    struct PreparedStart: Equatable, Sendable {
        let ticket: StartTicket
        let input: VerifiedRuntimePlatformInput
    }

    /// What `open` observed. `values` is the store's adopted observation, read before any baseline or reconciler exists.
    struct Opened {
        let values: ConfigurationValues
        let events: [ConfigurationWorkflowEvent]

        var config: ProxyConfig { values.runtime }
        var platformConfig: PlatformIntegrationConfig { values.platform }
        var appPreferences: AppPreferences { values.preferences }
    }

    /// `open` refused the startup inputs. The daemon reports `event` and exits, as it does for a failed load.
    struct OpenRefusal: Error {
        let event: ConfigurationWorkflowEvent
    }

    enum StartPreparation {
        /// The captured inputs verified as one exact pair, and the admission still stands.
        case ready(PreparedStart)
        /// The required inputs did not verify, or the runtime input blocks a start. The prior applied configuration keeps running.
        case held
        /// A newer Start or Stop was admitted, or the captured input was replaced, so this Start stops without applying anything.
        case superseded
    }

    struct StartOutcome {
        let preparation: StartPreparation
        let events: [ConfigurationWorkflowEvent]
        /// The commit's persistence facts and the DNS bit it staged, when the store ran the commit. A receipt reports them whatever the
        /// Start then does.
        var commit: RuntimePlatformCommitResult? = nil
        var dnsStaged: Bool? = nil
        /// The store's one slot was taken, so nothing was captured or written.
        var storeBusy = false
    }

    /// A frozen editor candidate (decision 0018): the submitted values and the exact baselines its request named. The DNS bit and the
    /// launch-at-login flag are merged from the store inside the claim, so the request can neither restore an older enable nor override the
    /// administrative flag.
    struct FrozenInput: Sendable {
        let runtime: ProxyConfig
        let platform: PlatformIntegrationConfig
        let expected: ConfigurationSlots<ConfigurationBaselineToken?>
    }

    /// One admitted all-save-only update: no lifecycle admission, no revision change and no fence change. It stands while no terminal stop
    /// has latched and DNS's durable intent has not moved since it was admitted.
    struct SaveTicket: Sendable {
        let dnsIntentRevision: Int?
        let requestID: ControlRequestID?
        /// The revision each apply-while-running module was admitted at, nil for a save-only module: actionable intent (decision 0035),
        /// so a Stop or Start of such a module after admission revokes the unstarted write.
        var applying = PrivateModuleSlots<Int?>(proxy: nil, dns: nil, tunnels: nil)
        /// The quit's reserved flush: admitted after the terminal latch, which does not revoke its claim; the window's close does.
        var quitFlush = false
    }

    struct SaveOutcome {
        let commit: RuntimePlatformCommitResult?
        let dnsStaged: Bool?
        /// The claim no longer stood, by a terminal stop or a newer DNS intent, so nothing was captured or written.
        let superseded: Bool
        let events: [ConfigurationWorkflowEvent]
        /// The store's one slot was taken, so nothing was captured or written.
        var storeBusy = false
    }

    struct ReloadOutcome {
        let events: [ConfigurationWorkflowEvent]
        /// The runtime and platform inputs the host may apply. `nil` keeps the applied view and the reconciler's baseline as they are.
        let applied: (runtime: ProxyConfig, platform: PlatformIntegrationConfig)?
        /// Whether a current observation was adopted, whatever the apply decision. A stale observation is still the store's durable one,
        /// but it is not current, so it is not counted here.
        let adopted: Bool
    }

    private let store: ConfigurationStore
    private let startupAllowsMissing: Bool
    /// The host's one incarnation, the same value its service and observations name. The store's own baseline namespace is separate.
    private let incarnation: ControlHostIncarnation
    /// The one per-module intent the workflow owns (decisions 0035 and 0036). The write claims read it from the platform queue, so it sits
    /// behind a short lock that no I/O holds.
    private let intent: NIOLockedValueBox<RuntimeModuleIntents>
    /// Store-using operations begun and not yet returned to the host. A settle reads it, so no host reports settled while a read,
    /// a required commit or a reload can still write.
    private var operationsInFlight = 0 {
        didSet {
            guard operationsInFlight == 0, let waiter = idleWaiter else { return }
            idleWaiter = nil
            waiter.resume()
        }
    }
    /// The process quit's one wait for the store operations already begun. One slot: the host runs a single quit.
    private var idleWaiter: CheckedContinuation<Void, Never>?

    /// Whether no store-using operation is in flight on this workflow. Read on the main actor.
    var isIdle: Bool {
        operationsInFlight == 0
    }

    /// Returns once no store-using operation is in flight, so the quit joins every read, commit or save already begun before the root's
    /// authority can be released. Only the host's single quit calls it.
    func waitUntilIdle() async {
        guard operationsInFlight > 0 else { return }
        precondition(idleWaiter == nil, "the host runs a single quit")
        await withCheckedContinuation { idleWaiter = $0 }
    }

    /// - Parameter startupAllowsMissing: the startup's explicit `allowMissing`. A reload uses the same value, so it keeps the combinations
    ///   the loader accepts at startup, and an explicit `--config` start keeps its refusal of a missing runtime file.
    /// - Parameter incarnation: the host's incarnation, which every store context names.
    /// - Parameter generation: the intent generation before the first admission. The host always starts at 0; a test seeds it near
    ///   `Int.max` to reach the exhausted branches.
    init(store: ConfigurationStore, incarnation: ControlHostIncarnation, startupAllowsMissing: Bool, generation: Int = 0) {
        precondition(generation >= 0, "an intent generation is never negative")
        self.store = store
        self.incarnation = incarnation
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

    // MARK: - Editor observation

    /// One memory observation for the private editor (decisions 0032 and 0034): the store's current values, each component's baseline or
    /// its closed retained reason, the module intents and the terminal latch, all from this one owner turn, with no disk read and no apply.
    /// The host's accepted view never enters it, so it confers no persistence authority the store does not hold. It is copy-on-write
    /// values only: mapping and encoding run off the owner.
    struct EditorCapture: Sendable {
        let values: ConfigurationValues
        let components: PrivateComponentSlots<PrivateComponentState>
        let modules: PrivateModuleSlots<PrivateModuleState>
        let terminal: Bool
    }

    /// Captures the editor observation in this turn. A host exists only after an adopted open, so the store holds values; a later refused
    /// reload keeps them for display and marks every component retained.
    func editorCapture() -> EditorCapture {
        guard let values = store.values else { preconditionFailure("an opened workflow's store holds adopted values") }
        let state = intent.withLockedValue { $0 }
        func component(_ component: ConfigurationComponent) -> PrivateComponentState {
            switch store.componentState(component) {
            case .verified(let token): .verified(Self.privateBaseline(token))
            case .absent(let token): .absent(Self.privateBaseline(token))
            case .retained(let reason): .retained(Self.retained(reason))
            }
        }
        func module(_ module: ControlModule) -> PrivateModuleState {
            let intent = state.modules[module]
            guard let revision = ControlLifecycleRevision(rawValue: intent.revision) else {
                preconditionFailure("a lifecycle revision is never negative")
            }
            return PrivateModuleState(lifecycleRevision: revision, enabled: intent.enabled, fenced: intent.fenced)
        }
        return EditorCapture(
            values: values,
            components: PrivateComponentSlots(runtime: component(.runtime), platform: component(.platform), preferences: component(.preferences)),
            modules: PrivateModuleSlots(proxy: module(.proxy), dns: module(.dns), tunnels: module(.tunnels)),
            terminal: state.terminal
        )
    }

    /// The wire form of a store token: its namespace, file and exact `UInt64` version, never narrowed.
    static func privateBaseline(_ token: ConfigurationBaselineToken) -> PrivateBaseline {
        let file: ControlConfigWorkflowFile = switch token.component {
        case .runtime: .runtime
        case .platform: .platform
        case .preferences: .preferences
        }
        return PrivateBaseline(namespace: PrivateBaselineNamespace(rawValue: token.storeIncarnation), component: file, version: token.version)
    }

    private static func retained(_ reason: ConfigurationLatchReason) -> PrivateRetainedReason {
        switch reason {
        case .observationRefused: .observationRefused
        case .changedSinceBaseline: .changedSinceBaseline
        case .writeUnknown: .writeUnknown
        }
    }

    // MARK: - Start and Stop admission

    /// Admits the whole-host facade Start: proxy and tunnels Starts and DNS's configured Start, as one group. Synchronous, before any
    /// suspension. The fences stay until `authorize`, after the verified pair is adopted. A refusal changes nothing, and it comes with its
    /// typed `config.workflow.held` event.
    func admitStart() -> Result<StartTicket, RuntimeStartRefusal> {
        admitStart(PrivateModuleSlots(proxy: .start, dns: .configuredStart, tunnels: .start))
    }

    /// Admits one module Start request in one turn (decisions 0035 and 0036): every actionable revision the caller observed is checked
    /// before anything changes, and one stale slot refuses the whole request. Its explicit Starts form one group with one shared prepare; a
    /// conditional DNS companion rides in the ticket and changes no DNS control. The host composes `actions`, so an invalid composition is
    /// a host bug.
    func admitStart(
        _ actions: PrivateModuleSlots<RuntimeModuleAction>,
        expecting revisions: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil),
        requestID: ControlRequestID? = nil
    ) -> Result<StartTicket, RuntimeStartRefusal> {
        let request = RuntimeLifecycleRequest(actions: actions, expectedRevisions: revisions)
        let admission = intent.withLockedValue { $0.admit(request) }
        switch admission {
        case .success(let ticket):
            return .success(StartTicket(lifecycle: ticket, requestID: requestID))
        case .failure(.terminated):
            return .failure(.terminated)
        case .failure(.exhausted):
            return .failure(.intentExhausted)
        case .failure(.busy):
            return .failure(.stopSaveOwed)
        case .failure(.stale(let module)):
            return .failure(.stale(module))
        case .failure(.invalid):
            preconditionFailure("the host composes only valid module requests")
        }
    }

    /// Each module's lifecycle revision now: what a caller observes before it names expected revisions. Read on the main actor.
    var revisions: PrivateModuleSlots<Int> {
        intent.withLockedValue { state in
            PrivateModuleSlots(proxy: state.modules.proxy.revision, dns: state.modules.dns.revision, tunnels: state.modules.tunnels.revision)
        }
    }

    /// The typed event for a Start refused at admission.
    func admissionEvents(_ refusal: RuntimeStartRefusal) -> [ConfigurationWorkflowEvent] {
        guard let reason = refusal.admissionReason else { return [] }
        return [held(.start, .unit, reason)]
    }

    /// Admits a whole-host Stop. Synchronous, and it fences every module at once, before any save or recovery is awaited. The legacy
    /// facade persists no DNS disable. The counter advances when it can; the fence holds either way, so a Stop at the maximum still
    /// refuses every older Start and claim. A terminal stop is the process quit, which also latches.
    @discardableResult
    func admitStop(terminal: Bool = false) -> Int {
        admitStop(Set(ControlModule.allCases), reason: terminal ? .processQuit : .facade)
    }

    /// Admits a Stop of `modules` in one turn, before any await and whether or not the store's slot is free: each is fenced and loses its
    /// permission at once. A session Stop of DNS also owes its disable save, in DNS's one pending slot; `saveOwedDNSStop` persists it.
    @discardableResult
    func admitStop(_ modules: Set<ControlModule>, reason: RuntimeStopReason) -> Int {
        intent.withLockedValue { $0.stop(modules, reason: reason) }
    }

    /// What `saveOwedDNSStop` did with DNS's owed disable.
    enum DNSStopSave: Equatable {
        /// No disable save is owed.
        case notOwed
        /// The disable verified, and the obligation ended.
        case saved
        /// The obligation stays owed: the store's slot was taken, the write did not verify, or a pending explicit DNS Start carries it and
        /// nothing was written. Nothing retries it; the next explicit Stop, save or reload attempt is the next chance.
        case owed
    }

    /// Persists the disable a session DNS Stop owes, through the store's runtime-only lifecycle commit (decision 0015): the canonical
    /// stager, the legacy-preservation checks and the runtime baseline guard all apply, and no platform file is touched. The write is claimed
    /// only while that Stop's save is still the one owed, and the obligation ends only once the write verifies. It never retries.
    /// An explicit DNS Start pending in the slot may carry the obligation instead: it is still owed, and that Start's own verified write,
    /// or its end without one, settles it, so this writes nothing. `requestID` is the client request of the Stop that owes it, nil for
    /// the host's own composition.
    func saveOwedDNSStop(requestID: ControlRequestID? = nil) async -> (save: DNSStopSave, events: [ConfigurationWorkflowEvent]) {
        enum Owed { case save(revision: Int), carried, notOwed }
        let owed = intent.withLockedValue { state -> Owed in
            switch state.modules.dns.pending {
            case .stopSave(let revision): .save(revision: revision)
            case .start(let start) where start.displacesOwedSave: .carried
            case .start, nil: .notOwed
            }
        }
        let revision: Int
        switch owed {
        case .save(let owedRevision): revision = owedRevision
        case .carried: return (.owed, [])
        case .notOwed: return (.notOwed, [])
        }
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        let intent = self.intent
        let admission = await store.commitDNSLifecycle(
            enabled: false,
            expecting: store.baselineToken(for: .runtime),
            context: context(generation: revision, requestID: requestID),
            claim: ConfigurationWriteClaim { intent.withLockedValue { $0.stopSaveIsCurrent(revision: revision) } }
        )
        // A busy slot attempts nothing: the disable stays owed, the fence stays, and the typed hold says why.
        guard case .admitted(let result) = admission else { return (.owed, [held(.stop, .runtime, .storeBusy)]) }
        let events = [committed(.runtime, result.runtime)]
        guard result.runtime.isVerified else { return (.owed, events) }
        intent.withLockedValue { $0.finishStopSave(revision: revision) }
        return (.saved, events)
    }

    /// Authorizes a Start whose verified pair the host has adopted: its members gain the permission the facade grants and lose their
    /// fences. Returns false when the prepared Start no longer stands.
    func authorize(_ prepared: PreparedStart) -> Bool {
        guard store.stillHolds(prepared.input) else { return false }
        return intent.withLockedValue { !$0.authorize(prepared.ticket.lifecycle).isEmpty }
    }

    /// Settles a Start's effect. A failure restores each member's prior permission and fence and advances the counter, so a reload or a
    /// pass admitted under that Start stops, and the host's revert then runs under the lane token. At the maximum the counter cannot
    /// advance, so the member is fenced instead. A ticket a newer admission replaced changes nothing.
    /// Each member in `modules` is settled on its own, so a module whose effect completed keeps its success while another fails.
    func finishStart(_ ticket: StartTicket, modules: Set<ControlModule> = Set(ControlModule.allCases), succeeded: Bool) {
        intent.withLockedValue { state in
            for module in ControlModule.allCases where modules.contains(module) {
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
    func endFailedStart(_ ticket: StartTicket, modules: Set<ControlModule> = Set(ControlModule.allCases)) {
        finishStart(ticket, modules: modules, succeeded: false)
    }

    /// Whether `module` still acts under the ticket's group. Another module's admission does not end it (decision 0035).
    func holds(_ module: ControlModule, for ticket: StartTicket) -> Bool {
        intent.withLockedValue { $0.holds(module, for: ticket.lifecycle) }
    }

    /// Whether the ticket's DNS companion may start DNS now (decision 0036): its proxy Start runs under the ticket, no DNS admission came
    /// since, DNS's configured intent is on and no Stop fence is in force. The host checks DNS's run state itself.
    func conditionalActivationAllowed(_ ticket: StartTicket) -> Bool {
        intent.withLockedValue { $0.conditionalActivationAllowed(ticket.lifecycle) }
    }

    /// Settles the companion's physical start. It grants only the runtime permission a DNS it started needs, and never writes intent.
    func settleConditional(_ ticket: StartTicket, succeeded: Bool) {
        intent.withLockedValue { $0.settleConditional(ticket.lifecycle, succeeded: succeeded) }
    }

    /// Whether DNS's configured intent is on and no Stop fence is in force: the companion's no-op causes, read for its typed result.
    var dnsIntent: (configured: Bool, fenced: Bool) {
        intent.withLockedValue { ($0.dnsConfigured, $0.modules.dns.fenced) }
    }

    /// Whether a terminal stop has latched. Read on the main actor.
    var isTerminal: Bool {
        intent.withLockedValue { $0.terminal }
    }

    /// Opens or closes the quit's reserved flush window in the intent the flush's write claims read. It opens only after the latch.
    func setQuitFlush(open: Bool) {
        intent.withLockedValue { $0.quitFlushOpen = open && $0.terminal }
    }

    /// The typed event for a Start that stopped after it was admitted, with its closed cause: a newer generation, a terminal stop, a Stop at
    /// the maximum that ended the group, or a replacement of the input its members still wait on.
    /// A group whose members still wait on their prepare was ended by its replaced input, whatever an admission on another module did to the
    /// counter meanwhile.
    func supersession(of ticket: StartTicket) -> [ConfigurationWorkflowEvent] {
        let waiting = intent.withLockedValue { !$0.terminal && !$0.members(of: ticket.generation).isEmpty }
        if waiting { return [held(.start, .unit, .inputReplaced)] }
        let current = generation
        if ConfigurationWorkflowSuperseded.isValid(phase: .start, generation: ticket.generation, current: current) {
            return [.superseded(ConfigurationWorkflowSuperseded(phase: .start, generation: ticket.generation, current: current))]
        }
        if isTerminal { return [held(.start, .unit, .terminating)] }
        return [held(.start, .unit, .stopFenced)]
    }

    /// The typed event for one authorized member that no longer acts under its group: the admission that changed the module, named by
    /// the module's own revision, or the terminal latch, or a Stop at the maximum, which is the closed fence hold.
    func supersession(of ticket: StartTicket, module: ControlModule) -> [ConfigurationWorkflowEvent] {
        if isTerminal { return [held(.start, .unit, .terminating)] }
        let revision = intent.withLockedValue { $0.modules[module].revision }
        if ConfigurationWorkflowSuperseded.isValid(phase: .start, generation: ticket.generation, current: revision) {
            return [.superseded(ConfigurationWorkflowSuperseded(phase: .start, generation: ticket.generation, current: revision))]
        }
        return [held(.start, .unit, .stopFenced)]
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

    /// Whether the admission still stands for at least one member: a Stop or newer Start of each member, a failed settle or the terminal
    /// latch ends it, and an admission on a module outside the group does not (decision 0035).
    func isCurrent(_ ticket: StartTicket) -> Bool {
        intent.withLockedValue { state in ControlModule.allCases.contains { state.holds($0, for: ticket.lifecycle) } }
    }

    /// Whether a prepared Start still stands: its group does, and no observation or write has replaced the pair it captured (decision 0037).
    func isCurrent(_ prepared: PreparedStart) -> Bool {
        isCurrent(prepared.ticket) && holdsInput(prepared)
    }

    /// Whether the store still holds the pair a prepared Start captured. After authorization the host's lane tokens and member checks
    /// order the Start against newer admissions, and this alone says whether its remaining effects may use the pair. Any later write
    /// replaces it, a DNS Stop's verified disable included (decision 0037).
    /// Whether the store still holds a verified pair: no observation or write replaced either file since it verified.
    func stillHolds(_ input: VerifiedRuntimePlatformInput) -> Bool {
        store.stillHolds(input)
    }

    func holdsInput(_ prepared: PreparedStart) -> Bool {
        store.stillHolds(prepared.input)
    }

    // MARK: - Start preparation

    /// Prepares a saved-input Start after launch recovery (decision 0037). The store takes its one slot and, in that same turn, the capture
    /// reads the store's current pair, observes its DNS bit and merges DNS's local intent; the commit then runs against the baselines that
    /// pair came from. A busy store captures nothing and holds the Start. A runtime input that blocks a start holds without any write.
    /// Absent defaults are persisted here, before the Start, and a present file that verifies is verified without a rewrite. The admission is
    /// checked again after the commit, and the prepared pair is returned only when both receipts verified.
    func prepareStart(_ ticket: StartTicket, frozen: FrozenInput? = nil) async -> StartOutcome {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        guard isCurrent(ticket) else {
            return StartOutcome(preparation: .superseded, events: supersession(of: ticket))
        }
        enum Capture { case pending, ended, blocking, captured(RuntimeLifecycleTicket) }
        var capture = Capture.pending
        // The claim reads the captured binding, so a change of the staged DNS value after the capture revokes the write. It asks whether
        // the group's shared prepare still stands, so an admission on a module outside the group does not revoke it (decision 0035).
        let binding = NIOLockedValueBox(ticket.lifecycle)
        let intent = self.intent
        let claim = ConfigurationWriteClaim {
            let lifecycle = binding.withLockedValue { $0 }
            return intent.withLockedValue { $0.isPending(lifecycle) }
        }
        let operation = context(generation: ticket.generation, requestID: ticket.requestID)
        let admission = await store.commitCapturedRuntimeAndPlatform(
            expecting: frozen?.expected, context: operation, claim: claim
        ) { values in
            guard let values else { return nil }
            // The store's adopted DNS bit is a durable fact, observed first, so a reload that adopted it before this point supplies the
            // value and is never written over.
            guard let lifecycle = intent.withLockedValue({ $0.capture(ticket.lifecycle, observedDNS: values.runtime.dnsForwarderEnabled) }),
                  let staged = lifecycle.dnsStaged else {
                capture = .ended
                return nil
            }
            let candidate = Self.merged(frozen.map { ($0.runtime, $0.platform) } ?? (values.runtime, values.platform), dns: staged, store: values)
            guard !candidate.runtime.validate().contains(where: \.blocksProxyStart) else {
                capture = .blocking
                return nil
            }
            capture = .captured(lifecycle)
            binding.withLockedValue { $0 = lifecycle }
            return candidate
        }
        guard case .admitted(let committed) = admission else {
            return StartOutcome(preparation: .held, events: [held(.start, .unit, .storeBusy)], storeBusy: true)
        }
        let lifecycle: RuntimeLifecycleTicket
        switch capture {
        case .captured(let value):
            lifecycle = value
        case .ended:
            return StartOutcome(preparation: .superseded, events: supersession(of: ticket))
        case .blocking:
            return StartOutcome(preparation: .held, events: [held(.start, .runtime, .startBlocking)])
        case .pending:
            // The store has no adopted values, so nothing was captured or written.
            return StartOutcome(preparation: .held, events: [held(.start, .unit, .commitFailed)])
        }
        guard let result = committed, let staged = lifecycle.dnsStaged else {
            preconditionFailure("a captured candidate is committed with its staged DNS value")
        }
        var captured = ticket
        captured.lifecycle = lifecycle
        var events = [
            self.committed(.runtime, result.runtime),
            self.committed(.platform, result.platform),
        ]
        // A verified runtime file is a saved fact before any check below can end the Start (decision 0015).
        if result.runtime.isVerified {
            intent.withLockedValue { $0.recordVerifiedDNSWrite(staged, for: lifecycle) }
        }
        // The admission is checked again after the commit's suspension. A committed file keeps its persistence even if the Start stops.
        guard isCurrent(captured) else {
            events += supersession(of: captured)
            return StartOutcome(preparation: .superseded, events: events, commit: result, dnsStaged: staged)
        }
        if let verified = result.verifiedInput {
            return StartOutcome(
                preparation: .ready(PreparedStart(ticket: captured, input: verified)), events: events, commit: result, dnsStaged: staged
            )
        }
        if result.platform.isVerified {
            events.append(held(.start, .runtime, .commitFailed))
        } else {
            events.append(held(.start, .platform, .commitFailed))
            if case .notAttempted(.heldBehindPlatform) = result.runtime {
                events.append(held(.start, .runtime, .heldBehind))
            }
        }
        return StartOutcome(preparation: .held, events: events, commit: result, dnsStaged: staged)
    }

    /// The candidate a commit stages: `values` with the DNS bit its claim staged and the store's own launch-at-login flag. A saved capture's
    /// values already hold that flag; a frozen request never carries it (decision 0018), so the administrative value stays the store's.
    private static func merged(
        _ values: (runtime: ProxyConfig, platform: PlatformIntegrationConfig),
        dns staged: Bool,
        store: ConfigurationValues
    ) -> (runtime: ProxyConfig, platform: PlatformIntegrationConfig) {
        var runtime = values.runtime
        runtime.dnsForwarderEnabled = staged
        var platform = values.platform
        platform.launchAtLogin = store.platform.launchAtLogin
        return (runtime, platform)
    }

    /// The frozen candidate of an editor request, with the exact tokens its baselines name. The store mints them, and its authority decides.
    func frozenInput(
        runtime: ProxyConfig,
        platform: PlatformIntegrationConfig,
        runtimeBaseline: PrivateBaseline,
        platformBaseline: PrivateBaseline
    ) -> FrozenInput {
        FrozenInput(
            runtime: runtime,
            platform: platform,
            expected: ConfigurationSlots(
                runtime: store.token(naming: runtimeBaseline), platform: store.token(naming: platformBaseline), preferences: nil
            )
        )
    }

    /// The wire form of a receipt's baseline: the same namespace, file and exact version.
    static func privateBaseline(_ receipt: ConfigurationReceipt) -> PrivateBaseline {
        let file: ControlConfigWorkflowFile = switch receipt.component {
        case .runtime: .runtime
        case .platform: .platform
        case .preferences: .preferences
        }
        return PrivateBaseline(namespace: PrivateBaselineNamespace(rawValue: receipt.storeIncarnation), component: file, version: receipt.version)
    }

    // MARK: - Administration

    /// The login-item administration's platform-only commit under the client's exact platform baseline. It changes no intent and applies
    /// nothing; a terminal stop revokes it before its replacement. A nil write is a busy store, which attempted nothing.
    func commitLaunchAtLogin(
        _ enabled: Bool,
        expecting baseline: PrivateBaseline,
        requestID: ControlRequestID
    ) async -> (write: ConfigurationWriteOutcome?, events: [ConfigurationWorkflowEvent]) {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        let intent = self.intent
        let admission = await store.commitLaunchAtLogin(
            enabled: enabled,
            expecting: store.token(naming: baseline),
            context: context(generation: generation, requestID: requestID),
            claim: ConfigurationWriteClaim { intent.withLockedValue { !$0.terminal } }
        )
        guard case .admitted(let write) = admission else { return (nil, [held(.start, .unit, .storeBusy)]) }
        return (write, [committed(.platform, write)])
    }

    // MARK: - Save

    /// Admits an all-save-only update in one turn. It changes no intent, revision or fence, so it neither clears a Stop fence nor leaves any
    /// activation behind. After a terminal stop nothing new is admitted, except the quit's one reserved flush, which its caller admitted.
    func admitSave(
        requestID: ControlRequestID?,
        applying: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil),
        quitFlush: Bool = false
    ) -> Result<SaveTicket, RuntimeStartRefusal> {
        let state = intent.withLockedValue { (terminal: $0.terminal, revision: $0.dnsIntentRevision) }
        guard !state.terminal || quitFlush else { return .failure(.terminated) }
        return .success(SaveTicket(dnsIntentRevision: state.revision, requestID: requestID, applying: applying, quitFlush: quitFlush))
    }

    /// Commits a save's frozen candidate through the one coupled commit, with DNS's durable intent merged inside the claim: a session Stop's
    /// disable stays, and another request's pending enable is never written (decision 0015). The claim holds while DNS's intent has not moved
    /// and no terminal stop latched; nothing is applied, and a verified disable fulfils the Stop save it matches.
    func saveFrozen(_ ticket: SaveTicket, _ frozen: FrozenInput) async -> SaveOutcome {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        let intent = self.intent
        // The quit's latch revokes every save but its own reserved flush, and the flush only while its window is open; a newer DNS intent, or
        // a moved revision of a module the save applies to, revokes either. One short lock, at the capture and again just before each
        // replacement. The quit stages no disable, so a Stop's disable owed from before it is still the staged value and is written by the
        // flush.
        let claim = ConfigurationWriteClaim {
            intent.withLockedValue { state in
                (ticket.quitFlush ? state.quitFlushOpen : !state.terminal) && state.dnsIntentRevision == ticket.dnsIntentRevision
                    && ControlModule.allCases.allSatisfy { module in
                        ticket.applying[module].map { state.modules[module].revision == $0 } ?? true
                    }
            }
        }
        var staged: Bool?
        let admission = await store.commitCapturedRuntimeAndPlatform(
            expecting: frozen.expected, context: context(generation: generation, requestID: ticket.requestID), claim: claim
        ) { values in
            guard let values, claim.isCurrent() else { return nil }
            let dns = intent.withLockedValue { $0.stagedDNSForwarderEnabled(for: nil) }
            staged = dns
            return Self.merged((frozen.runtime, frozen.platform), dns: dns, store: values)
        }
        guard case .admitted(let written) = admission else {
            return SaveOutcome(commit: nil, dnsStaged: nil, superseded: false, events: [held(.start, .unit, .storeBusy)], storeBusy: true)
        }
        guard let result = written, let staged else {
            // The claim no longer stood when the slot was taken: a terminal stop, or a newer intent the save was admitted under.
            return SaveOutcome(
                commit: nil, dnsStaged: nil, superseded: true, events: [held(.start, .unit, isTerminal ? .terminating : .staleRevision)]
            )
        }
        if result.runtime.isVerified {
            intent.withLockedValue { $0.recordVerifiedDNSWrite(staged, intentRevision: ticket.dnsIntentRevision, ownEnable: false) }
        }
        return SaveOutcome(
            commit: result, dnsStaged: staged, superseded: false,
            events: [committed(.runtime, result.runtime), committed(.platform, result.platform)]
        )
    }

    /// Commits a preferences update through the store's preferences commit, under the exact baseline its request named (decision 0018).
    /// It is admitted as an all-save-only update, but only the terminal latch revokes it, or, for the quit's flush, the window's close: the
    /// preferences file holds no lifecycle intent, so no DNS or module admission moves it, and nothing is applied. A nil write is a busy store,
    /// which attempted nothing.
    func savePreferences(
        _ ticket: SaveTicket,
        _ preferences: AppPreferences,
        expecting baseline: PrivateBaseline
    ) async -> (write: ConfigurationWriteOutcome?, events: [ConfigurationWorkflowEvent]) {
        operationsInFlight += 1
        defer { operationsInFlight -= 1 }
        let intent = self.intent
        let admission = await store.commitPreferences(
            preferences,
            expecting: store.token(naming: baseline),
            context: context(generation: generation, requestID: ticket.requestID),
            claim: ConfigurationWriteClaim { intent.withLockedValue { ticket.quitFlush ? $0.quitFlushOpen : !$0.terminal } }
        )
        guard case .admitted(let result) = admission else { return (nil, [held(.start, .unit, .storeBusy)]) }
        return (result.preferences, [committed(.preferences, result.preferences)])
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
                adopted: false
            )
        }
        switch loaded.outcome {
        case .refused(let refusal):
            return ReloadOutcome(
                events: [.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(Self.refusal(refusal))))],
                applied: nil,
                adopted: false
            )
        case .adopted:
            var events: [ConfigurationWorkflowEvent] = [
                .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .adopted)),
            ]
            guard let values = store.values else {
                preconditionFailure("an adopted observation carries its values")
            }
            // The adopted DNS bit is a durable fact whether or not this observation may apply; the intents keep any fence, pending Start or
            // owed save, and the observation never raises a permission. The store's values, the preferences among them, are adopted either
            // way; only the apply decision below depends on the generation.
            intent.withLockedValue { $0.observeDurableDNS(values.runtime.dnsForwarderEnabled) }
            // A newer intent that landed during the read makes this observation stale. It stays a durable observation, and nothing applies.
            let current = generation
            guard current == captured else {
                events += staleEvents(.reload, generation: captured, current: current)
                return ReloadOutcome(events: events, applied: nil, adopted: false)
            }
            let applied = eligibleInput(values, events: &events)
            return ReloadOutcome(events: events, applied: applied, adopted: true)
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

    /// The context a store call echoes. A client request names its own ID, so one request ID follows its workflow (decision 0018); the
    /// host's own compositions, startup, reload and the facade, have no client request and name a fresh one per call.
    private func context(generation: Int, requestID: ControlRequestID? = nil) -> ConfigurationOperationContext {
        guard let ordinal = PrivateConfigExpectedGeneration(rawValue: generation) else {
            preconditionFailure("an intent generation is never negative")
        }
        return ConfigurationOperationContext(
            requestID: requestID ?? ControlRequestID(rawValue: UUID()),
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
