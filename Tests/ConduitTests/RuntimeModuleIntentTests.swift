// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import PlatformMac
import XCTest
@testable import ConduitRuntime
@testable import ProxyKernel

/// The per-module lifecycle intent (decisions 0015, 0035 and 0036) and the runtime-only DNS lifecycle commit it persists through.
@MainActor
final class RuntimeModuleIntentTests: XCTestCase {
    private func request(
        proxy: RuntimeModuleAction = .none,
        dns: RuntimeModuleAction = .none,
        tunnels: RuntimeModuleAction = .none,
        expected: PrivateModuleSlots<Int?> = PrivateModuleSlots(proxy: nil, dns: nil, tunnels: nil)
    ) -> RuntimeLifecycleRequest {
        RuntimeLifecycleRequest(actions: PrivateModuleSlots(proxy: proxy, dns: dns, tunnels: tunnels), expectedRevisions: expected)
    }

    private func admitted(_ intents: inout RuntimeModuleIntents, _ request: RuntimeLifecycleRequest) throws -> RuntimeLifecycleTicket {
        try intents.admit(request).get()
    }

    // MARK: - Scenarios

    /// An explicit DNS Start after a DNS Stop stages the enable for its file while the fence and the permission stay in force until it is
    /// authorized. A Stop before the write revokes the staged target.
    func testAnExplicitDNSStartStagesTheEnableBeforeItsFenceClears() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        intents.stop([.dns], terminal: false)
        XCTAssertFalse(intents.stagedDNSForwarderEnabled, "the Stop's save projects the disable")
        let group = try admitted(&intents, request(dns: .start))
        XCTAssertTrue(intents.stagedDNSForwarderEnabled, "the pending explicit Start's write stages the enable")
        XCTAssertTrue(intents.modules.dns.fenced, "the fence protects runtime activation until the verified write")
        XCTAssertFalse(intents.modules.dns.enabled)
        XCTAssertEqual(intents.authorize(group), [.dns])
        XCTAssertFalse(intents.modules.dns.fenced)
        XCTAssertTrue(intents.modules.dns.enabled)

        var revoked = RuntimeModuleIntents(dnsEnabled: false)
        _ = try admitted(&revoked, request(dns: .start))
        revoked.stop([.dns], terminal: false)
        XCTAssertFalse(revoked.stagedDNSForwarderEnabled, "a newer Stop revokes the pending target before an unstarted write")
    }

    /// A held Start and a failed Start leave the permission and the fence they found, so nothing can act on them later. This holds for an
    /// initially enabled DNS, for a DNS fenced by a Stop, and for a Start that replaced an authorized one still unsettled.
    func testHeldAndFailedExplicitStartsCreateNoPermission() throws {
        for (dnsEnabled, stopFirst) in [(true, false), (false, false), (true, true)] {
            var intents = RuntimeModuleIntents(dnsEnabled: dnsEnabled)
            if stopFirst { intents.stop([.dns], terminal: false) }
            let before = intents.modules.dns
            let held = try admitted(&intents, request(dns: .start))
            intents.retire(held)
            XCTAssertEqual(intents.modules.dns.enabled, before.enabled, "held: \(dnsEnabled) \(stopFirst)")
            XCTAssertEqual(intents.modules.dns.fenced, before.fenced, "held: \(dnsEnabled) \(stopFirst)")
            XCTAssertNil(intents.modules.dns.pending)

            let failed = try admitted(&intents, request(dns: .start))
            XCTAssertEqual(intents.authorize(failed), [.dns])
            let replacing = try admitted(&intents, request(dns: .start))
            intents.settle(.dns, ticket:failed, succeeded: false)
            XCTAssertNil(intents.modules.dns.authorized, "the replaced authorization is gone")
            XCTAssertEqual(intents.authorize(replacing), [.dns])
            intents.settle(.dns, ticket:replacing, succeeded: false)
            XCTAssertEqual(intents.modules.dns.enabled, before.enabled, "failed: the chain restores the pre-Start state")
            XCTAssertEqual(intents.modules.dns.fenced, before.fenced, "failed: \(dnsEnabled) \(stopFirst)")
            XCTAssertFalse(intents.conditionalActivationAllowed(replacing))
        }
    }

    /// A companion activation projects DNS's existing intent and never enables it. Its failure, unlike an explicit Start's, changes nothing,
    /// so the prior enable stays for the next explicit request. A Stop of DNS cancels only the companion; the proxy Start stands.
    func testAConditionalActivationNeverEnablesAndADNSStopCancelsOnlyIt() throws {
        var disabled = RuntimeModuleIntents(dnsEnabled: false)
        let off = try admitted(&disabled, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertFalse(disabled.stagedDNSForwarderEnabled)
        XCTAssertFalse(disabled.conditionalActivationAllowed(off), "a disabled DNS is a typed no-op")
        XCTAssertEqual(disabled.authorize(off), [.proxy], "the companion is no explicit-enable member, though it shares the input")
        XCTAssertFalse(disabled.modules.dns.enabled)

        var enabled = RuntimeModuleIntents(dnsEnabled: true)
        let on = try admitted(&enabled, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(enabled.authorize(on), [.proxy])
        XCTAssertTrue(enabled.conditionalActivationAllowed(on))
        enabled.settleConditional(on, succeeded: false)
        XCTAssertTrue(enabled.modules.dns.enabled, "a failed companion keeps the prior enable and fence")
        XCTAssertFalse(enabled.modules.dns.fenced)
        XCTAssertTrue(enabled.stagedDNSForwarderEnabled, "and the configured intent")

        var retried = RuntimeModuleIntents(dnsEnabled: false)
        retried.observeDurableDNS(true)
        let explicit = try admitted(&retried, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(retried.authorize(explicit), [.proxy])
        retried.settleConditional(explicit, succeeded: false)
        XCTAssertFalse(retried.modules.dns.enabled, "a failed companion grants no permission it did not have")
        let later = try admitted(&retried, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(retried.authorize(later), [.proxy])
        retried.settleConditional(later, succeeded: true)
        XCTAssertTrue(retried.modules.dns.enabled, "a started companion keeps the runtime permission")
        XCTAssertFalse(retried.modules.dns.fenced)

        XCTAssertEqual(enabled.admit(request(dns: .conditionalActivation)), .failure(.invalid), "a companion needs a proxy Start")
        XCTAssertEqual(enabled.admit(request(proxy: .conditionalActivation)), .failure(.invalid))
    }

    /// A verified write's saved enable survives a held or failed Start (decision 0015): the fence and the permission return, the saved
    /// fact does not. A newer DNS Stop wins over a late write of the older enable.
    func testAVerifiedEnableSurvivesItsHeldStartAndLosesToANewerStop() throws {
        var held = RuntimeModuleIntents(dnsEnabled: false)
        held.stop([.dns], terminal: false)
        let group = try admitted(&held, request(dns: .start))
        held.recordVerifiedDNSWrite(held.stagedDNSForwarderEnabled, for:group)
        held.retire(group)
        XCTAssertTrue(held.stagedDNSForwarderEnabled, "the next write keeps the enable the file verified")
        XCTAssertTrue(held.modules.dns.fenced, "the prior fence returns")
        XCTAssertFalse(held.modules.dns.enabled, "and no permission is left")

        var failed = RuntimeModuleIntents(dnsEnabled: false)
        let start = try admitted(&failed, request(dns: .start))
        failed.recordVerifiedDNSWrite(true, for:start)
        XCTAssertEqual(failed.authorize(start), [.dns])
        failed.settle(.dns, ticket:start, succeeded: false)
        XCTAssertTrue(failed.stagedDNSForwarderEnabled)
        XCTAssertFalse(failed.modules.dns.enabled)

        var late = RuntimeModuleIntents(dnsEnabled: false)
        let staged = try admitted(&late, request(dns: .start))
        late.stop([.dns], terminal: false)
        late.recordVerifiedDNSWrite(true, for:staged)
        XCTAssertFalse(late.stagedDNSForwarderEnabled, "the Stop's disable wins over the late older write")
    }

    /// A companion changes no DNS control (decision 0036): admitted after a DNS Stop, it keeps the Stop's reserved disable save and DNS's
    /// revision; admitted beside a pending explicit DNS Start, it does not cancel that Start.
    func testACompanionKeepsDNSControlAndItsSave() throws {
        var stopped = RuntimeModuleIntents(dnsEnabled: true)
        let save = stopped.stop([.dns], terminal: false)
        let revision = stopped.modules.dns.revision
        let observed = PrivateModuleSlots<Int?>(proxy: stopped.modules.proxy.revision, dns: revision, tunnels: nil)
        _ = try stopped.admit(request(proxy: .start, dns: .conditionalActivation, expected: observed)).get()
        XCTAssertTrue(stopped.stopSaveIsCurrent(revision: save), "the companion keeps the Stop's disable save")
        XCTAssertEqual(stopped.modules.dns.revision, revision, "the companion does not advance DNS's revision")
        XCTAssertTrue(stopped.modules.dns.fenced)

        var starting = RuntimeModuleIntents(dnsEnabled: false)
        _ = try starting.admit(request(dns: .start)).get()
        let pending = starting.modules.dns.pending
        _ = try starting.admit(request(proxy: .start, dns: .conditionalActivation)).get()
        XCTAssertEqual(starting.modules.dns.pending, pending, "the companion does not cancel the explicit DNS Start")
    }

    /// One stale actionable slot rejects the whole request, and the rejection changes nothing.
    func testAStaleSlotRejectsTheWholeRequestUnchanged() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let observed = PrivateModuleSlots<Int?>(proxy: intents.modules.proxy.revision, dns: intents.modules.dns.revision, tunnels: nil)
        intents.stop([.dns], terminal: false)
        let before = intents
        XCTAssertEqual(intents.admit(request(proxy: .start, dns: .start, expected: observed)), .failure(.stale(.dns)))
        XCTAssertEqual(intents, before)
    }

    /// Superseding one member ends the whole pending group, and only the group's own records: a newer pending operation stays.
    func testSupersedingOneMemberEndsTheWholeGroupOnly() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let group = try admitted(&intents, request(proxy: .start, tunnels: .start))
        let newer = try admitted(&intents, request(dns: .start))
        intents.stop([.tunnels], terminal: false)
        XCTAssertFalse(intents.isPending(group))
        XCTAssertNil(intents.modules.proxy.pending, "the proxy member ended with the group")
        XCTAssertTrue(intents.isPending(newer), "the newer DNS Start is not the old group's")
        XCTAssertEqual(intents.modules.proxy.revision, intents.counter, "an ended member takes the superseding revision")
    }

    /// The companion depends on the group's shared input (decision 0035). A DNS Stop, or a newer DNS Start, before that input is adopted
    /// ends the whole group and leaves the newer DNS operation in place. After the group is authorized, a DNS Stop cancels only the companion.
    func testTheCompanionEndsItsGroupBeforeTheSharedInputAndOnlyItselfAfter() throws {
        var stoppedEarly = RuntimeModuleIntents(dnsEnabled: true)
        let early = try admitted(&stoppedEarly, request(proxy: .start, dns: .conditionalActivation))
        stoppedEarly.stop([.dns], terminal: false)
        XCTAssertFalse(stoppedEarly.isPending(early), "a DNS Stop before the shared input ends the whole group")
        XCTAssertEqual(stoppedEarly.authorize(early), [], "a stale group is never authorized")
        stoppedEarly.retire(early)
        XCTAssertNil(stoppedEarly.modules.proxy.pending)
        XCTAssertNotNil(stoppedEarly.modules.dns.pending, "the Stop's own save stays")

        var replaced = RuntimeModuleIntents(dnsEnabled: true)
        let old = try admitted(&replaced, request(proxy: .start, dns: .conditionalActivation))
        let newer = try admitted(&replaced, request(dns: .start))
        XCTAssertFalse(replaced.isPending(old), "a newer DNS Start before the shared input ends the old group")
        XCTAssertTrue(replaced.isPending(newer), "and keeps its own reference")

        var stoppedLate = RuntimeModuleIntents(dnsEnabled: true)
        let late = try admitted(&stoppedLate, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(stoppedLate.authorize(late), [.proxy])
        stoppedLate.stop([.dns], terminal: false)
        XCTAssertFalse(stoppedLate.conditionalActivationAllowed(late), "after the shared input, a DNS Stop cancels the companion")
        XCTAssertEqual(stoppedLate.modules.proxy.authorized?.group, late.group, "and leaves the started proxy alone")
    }

    /// A reload that observes DNS configured on is not itself a permission, but a later explicit proxy Start with its companion may start
    /// DNS once the group's shared input is adopted. A fenced DNS keeps its disable through the same reload.
    func testAConfiguredDNSActivatesOnlyThroughALaterExplicitCompanion() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: false)
        intents.observeDurableDNS(true)
        XCTAssertFalse(intents.modules.dns.enabled, "the observation alone grants no runtime permission")
        let group = try admitted(&intents, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertFalse(intents.conditionalActivationAllowed(group), "not before the shared input is adopted")
        XCTAssertEqual(intents.authorize(group), [.proxy])
        XCTAssertTrue(intents.conditionalActivationAllowed(group), "the explicit companion may activate the configured DNS")
        XCTAssertFalse(intents.modules.dns.fenced)

        var fenced = RuntimeModuleIntents(dnsEnabled: true)
        fenced.stop([.dns], terminal: false)
        fenced.observeDurableDNS(true)
        let blocked = try admitted(&fenced, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertEqual(fenced.authorize(blocked), [.proxy])
        XCTAssertFalse(fenced.conditionalActivationAllowed(blocked), "a Stop's fence keeps DNS off through a reload")
    }

    /// A terminal stop latches and persists no disable, but keeps a DNS save an earlier session Stop reserved.
    func testATerminalStopKeepsAnEarlierStopSaveAndPersistsNoDisable() throws {
        var intents = RuntimeModuleIntents(dnsEnabled: true)
        let saved = intents.stop([.dns], terminal: false)
        intents.stop(Set(ControlModule.allCases), terminal: true)
        XCTAssertTrue(intents.stopSaveIsCurrent(revision: saved))
        XCTAssertEqual(intents.admit(request(proxy: .start)), .failure(.terminated))

        var quit = RuntimeModuleIntents(dnsEnabled: true)
        quit.stop(Set(ControlModule.allCases), terminal: true)
        XCTAssertNil(quit.modules.dns.pending, "Quit reserves no disable save")
        XCTAssertTrue(quit.stagedDNSForwarderEnabled, "Quit leaves the durable enable")
    }

    /// A reload's observed bit can lower DNS's permission and never raise it.
    func testAReloadObservationNeverRaisesPermission() {
        var intents = RuntimeModuleIntents(dnsEnabled: false)
        intents.observeDurableDNS(true)
        XCTAssertTrue(intents.stagedDNSForwarderEnabled, "the durable observation is merged into later writes")
        XCTAssertFalse(intents.modules.dns.enabled, "but it is not an activation permission")
        intents.observeDurableDNS(false)
        XCTAssertFalse(intents.stagedDNSForwarderEnabled)

        var fenced = RuntimeModuleIntents(dnsEnabled: true)
        fenced.stop([.dns], terminal: false)
        fenced.observeDurableDNS(true)
        XCTAssertFalse(fenced.stagedDNSForwarderEnabled, "a fenced DNS keeps the disable its Stop set")
    }

    /// At the maximum a Start is refused unchanged, and a Stop fences without advancing.
    func testTheMaximumCounterRefusesStartsAndStillFences() {
        var intents = RuntimeModuleIntents(counter: Int.max, dnsEnabled: true)
        let before = intents
        XCTAssertEqual(intents.admit(request(proxy: .start)), .failure(.exhausted))
        XCTAssertEqual(intents, before)
        XCTAssertEqual(intents.stop([.dns], terminal: false), Int.max)
        XCTAssertTrue(intents.modules.dns.fenced)
    }

    // MARK: - Bounded exploration

    private enum Step: CaseIterable {
        case startProxy, startDNS, facade, staleStart, stopProxy, stopDNS, quit
        case authorize, retire, fail, succeed, observeOn, observeOff
    }

    /// A bounded property sweep, not an independent reference model: it drives the production value and reads its own members, priors and
    /// group helpers, then checks properties stated from the decisions. Every sequence of up to four steps from both DNS starting values:
    /// within this alphabet only an authorization raises a permission or clears a fence; a companion's admission changes no DNS control; a
    /// held or failed Start restores what its admission found; a refusal changes nothing; the counter never goes back; a pending explicit DNS
    /// Start stages the enable. The alphabet has no companion settlement: its one runtime grant, never a fence or configured change, is
    /// covered by `testAConditionalActivationNeverEnablesAndADNSStopCancelsOnlyIt`. The independent workflow reference adapter is still due
    /// with the workflow integration.
    func testEveryBoundedSequenceKeepsTheIntentInvariants() {
        let depth = 4
        var sequences: [[Step]] = [[]]
        var frontier: [[Step]] = [[]]
        for _ in 0..<depth {
            frontier = frontier.flatMap { prefix in Step.allCases.map { prefix + [$0] } }
            sequences += frontier
        }
        XCTAssertEqual(sequences.count, 30_941, "1 + 13 + 13^2 + 13^3 + 13^4 sequences")
        var coverage: [String: Int] = [:]
        for dnsEnabled in [false, true] {
            for sequence in sequences {
                if let problem = check(sequence, dnsEnabled: dnsEnabled, coverage: &coverage) {
                    return XCTFail("dnsEnabled=\(dnsEnabled) \(sequence): \(problem)")
                }
            }
        }
        for key in ["authorize.clearedFence", "retire.restored", "fail.restored", "refusal.unchanged", "stale.refused",
                    "terminal.refused", "group.endedByMember", "observe.lowered", "projection.pendingTarget"] {
            XCTAssertGreaterThan(coverage[key] ?? 0, 0, "never reached \(key)")
        }
    }

    private func check(_ sequence: [Step], dnsEnabled: Bool, coverage: inout [String: Int]) -> String? {
        var intents = RuntimeModuleIntents(dnsEnabled: dnsEnabled)
        var latest: RuntimeLifecycleTicket?
        var admittedFrom: [Int: RuntimeModuleIntents] = [:]
        for step in sequence {
            let before = intents
            switch step {
            case .startProxy, .startDNS, .facade, .staleStart:
                let asked: RuntimeLifecycleRequest = switch step {
                case .startProxy: request(proxy: .start)
                case .startDNS: request(dns: .start)
                case .facade: request(proxy: .start, dns: .conditionalActivation, tunnels: .start)
                default: request(proxy: .start, expected: PrivateModuleSlots(proxy: intents.modules.proxy.revision - 1, dns: nil, tunnels: nil))
                }
                switch intents.admit(asked) {
                case .success(let ticket):
                    latest = ticket
                    admittedFrom[ticket.group] = before
                case .failure(let refusal):
                    if intents != before { return "a refusal changed the intent" }
                    coverage["refusal.unchanged", default: 0] += 1
                    if case .stale = refusal { coverage["stale.refused", default: 0] += 1 }
                    if refusal == .terminated { coverage["terminal.refused", default: 0] += 1 }
                }
            case .stopProxy:
                let pendingTunnels = intents.modules.tunnels.pending
                intents.stop([.proxy], terminal: false)
                if pendingTunnels != nil, intents.modules.tunnels.pending == nil {
                    coverage["group.endedByMember", default: 0] += 1
                }
            case .stopDNS:
                intents.stop([.dns], terminal: false)
                if intents.stagedDNSForwarderEnabled { return "a session DNS Stop left the enable staged" }
            case .quit:
                intents.stop(Set(ControlModule.allCases), terminal: true)
            case .authorize:
                guard let group = latest else { continue }
                if !intents.authorize(group).isEmpty {
                    if before.modules.proxy.fenced && !intents.modules.proxy.fenced
                        || before.modules.dns.fenced && !intents.modules.dns.fenced {
                        coverage["authorize.clearedFence", default: 0] += 1
                    }
                }
            case .retire:
                guard let group = latest, let origin = admittedFrom[group.group] else { continue }
                let members = intents.members(of: group.group)
                intents.retire(group)
                for module in members {
                    if intents.modules[module].enabled != origin.modules[module].enabled
                        || intents.modules[module].fenced != origin.modules[module].fenced {
                        return "a held Start left \(module) different from its admission"
                    }
                    coverage["retire.restored", default: 0] += 1
                }
            case .fail, .succeed:
                guard let group = latest else { continue }
                for module in ControlModule.allCases where intents.modules[module].authorized?.group == group.group {
                    let prior = intents.modules[module].authorized!
                    intents.settle(module, ticket: group, succeeded: step == .succeed)
                    if step == .fail {
                        if intents.modules[module].enabled != prior.priorEnabled || intents.modules[module].fenced != prior.priorFenced {
                            return "a failed Start left \(module) different from its prior"
                        }
                        coverage["fail.restored", default: 0] += 1
                    }
                }
            case .observeOn, .observeOff:
                intents.observeDurableDNS(step == .observeOn)
                if before.modules.dns.enabled && !intents.modules.dns.enabled { coverage["observe.lowered", default: 0] += 1 }
            }
            if intents.counter < before.counter { return "the counter went back" }
            if step == .facade, intents.modules.dns != before.modules.dns { return "a companion changed DNS's control" }
            for module in ControlModule.allCases {
                let raised = !before.modules[module].enabled && intents.modules[module].enabled
                let cleared = before.modules[module].fenced && !intents.modules[module].fenced
                if (raised || cleared) && step != .authorize { return "\(step) raised \(module)'s permission or cleared its fence" }
                if case .stopSave = intents.modules[module].pending, module != .dns { return "a save on \(module)" }
            }
            if case .start = intents.modules.dns.pending {
                if !intents.stagedDNSForwarderEnabled { return "a pending explicit DNS Start staged no enable" }
                coverage["projection.pendingTarget", default: 0] += 1
            } else if intents.modules.dns.authorized == nil, case .stopSave = intents.modules.dns.pending,
                      intents.stagedDNSForwarderEnabled {
                return "a reserved Stop save stages the enable"
            }
        }
        return nil
    }

    // MARK: - The runtime-only DNS lifecycle commit

    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    private func enabledRuntime() throws -> Data {
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderEnabled = true
        return try ProxyConfigPersistence.stagedFileData(for: config)
    }

    private func platformBytes() throws -> Data {
        try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
    }

    private struct LoadNotAdopted: Error {}

    private func load(_ fixture: ConfigurationStoreTests.Fixture) async throws {
        guard case .admitted(let report) = await fixture.store.load(context: Self.context), case .adopted = report.outcome else {
            XCTFail("the fixture's load was not adopted")
            throw LoadNotAdopted()
        }
    }

    private func disable(_ fixture: ConfigurationStoreTests.Fixture, current: Bool = true) async -> ConfigurationWriteOutcome? {
        guard case .admitted(let result) = await fixture.store.commitDNSLifecycle(
            enabled: false,
            expecting: fixture.store.baselineToken(for: .runtime),
            context: Self.context,
            claim: ConfigurationWriteClaim { current }
        ) else { return nil }
        return result.runtime
    }

    private func writes(_ fixture: ConfigurationStoreTests.Fixture, at path: String) -> Int {
        fixture.access.observations.filter { if case .write(let written, _) = $0 { written == path } else { false } }.count
    }

    /// The disable writes the runtime file alone. An external platform edit neither holds it nor is written over, and the commit gives no
    /// verified pair, so the ordinary coupled apply stays held on the changed platform file.
    func testTheDNSDisableWritesOnlyTheRuntimeFileAndAuthorizesNoApply() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try enabledRuntime(), platform: try platformBytes())
        defer { fixture.close() }
        try await load(fixture)
        let external = Data("{\"externally\":\"edited\"}".utf8)
        fixture.access.externalEdit(.replace(external), at: fixture.plan.platformConfig.path)

        let disabled = await disable(fixture)
        let outcome = try XCTUnwrap(disabled)
        guard case .persisted = outcome else { return XCTFail("the disable persists, got \(outcome)") }
        XCTAssertEqual(writes(fixture, at: fixture.plan.platformConfig.path), 0, "the platform file is never written")
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.platformConfig.path), external)
        XCTAssertEqual(fixture.store.values?.runtime.dnsForwarderEnabled, false)

        let values = try XCTUnwrap(fixture.store.values)
        guard case .admitted(let coupled) = await fixture.store.commitRuntimeAndPlatform(
            values.runtime, values.platform,
            expecting: ConfigurationSlots(
                runtime: fixture.store.baselineToken(for: .runtime), platform: fixture.store.baselineToken(for: .platform), preferences: nil
            ),
            context: Self.context
        ) else { return XCTFail("the coupled commit was not admitted") }
        XCTAssertNil(coupled.verifiedInput, "the changed platform file still holds the ordinary apply")
    }

    /// The disable respects the runtime file's own external edit: it conflicts, writes nothing and keeps the edit.
    func testTheDNSDisableConflictsWithAnExternalRuntimeEdit() async throws {
        let fixture = try ConfigurationStoreTests.Fixture(runtime: try enabledRuntime(), platform: try platformBytes())
        defer { fixture.close() }
        try await load(fixture)
        var edited = GenericDefaults.shared.makeConfig()
        edited.dnsForwarderEnabled = true
        edited.profileName = "Edited"
        let external = try ProxyConfigPersistence.stagedFileData(for: edited)
        fixture.access.externalEdit(.replace(external), at: fixture.plan.config.path)

        let outcome = await disable(fixture)
        XCTAssertEqual(outcome, .conflict)
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), external)
        XCTAssertEqual(fixture.store.values?.runtime.dnsForwarderEnabled, true, "no adopted value claims the disable persisted")
    }

    private enum SidecarEdit: CaseIterable {
        case none, delete, change
    }

    /// The decoded `dnsForwarderEnabled` of the runtime file on disk, through the store's own load and the production decoder.
    private func savedDNSEnabled(_ fixture: ConfigurationStoreTests.Fixture) async throws -> Bool? {
        try await load(fixture)
        return fixture.store.values?.runtime.dnsForwarderEnabled
    }

    /// The runtime-only write keeps the legacy guard for both sidecars a runtime file can carry values for (decision 0026): an absent
    /// sidecar holds it, a present unchanged one lets it write, and one deleted or changed since its baseline holds it. No row writes a
    /// sidecar. A persisted row's file decodes to the disable.
    func testTheDNSDisableKeepsTheLegacyGuardForBothSidecars() async throws {
        let sidecars: [(ConfigurationComponent, String, Any, () throws -> Data)] = [
            (.platform, "manageSystemProxy", true, platformBytes),
            (.preferences, "showMenuBarIcon", false, { try AppPreferencesPersistence.stagedData(for: AppPreferences()) }),
        ]
        var rows = 0
        for (sidecar, key, value, bytes) in sidecars {
            for present in [false, true] {
                for edit in SidecarEdit.allCases where present || edit == .none {
                    var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: try enabledRuntime()) as? [String: Any])
                    object[key] = value
                    let legacy = try JSONSerialization.data(withJSONObject: object)
                    let platform = sidecar == .platform ? (present ? try bytes() : nil) : try platformBytes()
                    let preferences = sidecar == .preferences && present ? try bytes() : nil
                    let fixture = try ConfigurationStoreTests.Fixture(runtime: legacy, platform: platform, preferences: preferences)
                    defer { fixture.close() }
                    try await load(fixture)
                    let path = fixture.session.configurationFile(for: sidecar).path
                    switch edit {
                    case .none: break
                    case .delete: fixture.access.externalEdit(.remove, at: path)
                    case .change: fixture.access.externalEdit(.replace(Data("{}".utf8)), at: path)
                    }
                    let label = "\(sidecar) present=\(present) edit=\(edit)"
                    let outcome = await disable(fixture)
                    switch (present, edit) {
                    case (false, _):
                        XCTAssertEqual(outcome, .notAttempted(.preservationHeld(.sidecarAbsent)), label)
                        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), legacy, label)
                    case (true, .none):
                        guard case .persisted = outcome else { XCTFail("\(label): \(String(describing: outcome))"); continue }
                        let saved = try await savedDNSEnabled(fixture)
                        XCTAssertEqual(saved, false, "\(label): the saved file decodes to the disable")
                    case (true, _):
                        XCTAssertEqual(outcome, .notAttempted(.preservationHeld(.sidecarChanged)), label)
                        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), legacy, label)
                    }
                    for component in [ConfigurationComponent.platform, .preferences] {
                        XCTAssertEqual(writes(fixture, at: fixture.session.configurationFile(for: component).path), 0, "\(label): \(component)")
                    }
                    rows += 1
                }
            }
        }
        XCTAssertEqual(rows, 8)
    }

    /// An already-disabled file verifies without a write, and a revoked claim writes nothing.
    func testAnUnchangedDisableVerifiesAndARevokedClaimWritesNothing() async throws {
        let disabled = try ConfigurationStoreTests.Fixture(
            runtime: try ProxyConfigPersistence.stagedFileData(for: GenericDefaults.shared.makeConfig()), platform: try platformBytes()
        )
        defer { disabled.close() }
        try await load(disabled)
        let unchanged = await disable(disabled)
        guard case .unchanged = try XCTUnwrap(unchanged) else { return XCTFail("an unchanged file verifies, got \(String(describing: unchanged))") }
        XCTAssertEqual(writes(disabled, at: disabled.plan.config.path), 0)

        let revoked = try ConfigurationStoreTests.Fixture(runtime: try enabledRuntime(), platform: try platformBytes())
        defer { revoked.close() }
        try await load(revoked)
        let outcome = await disable(revoked, current: false)
        XCTAssertEqual(outcome, .notAttempted(.superseded))
        XCTAssertEqual(writes(revoked, at: revoked.plan.config.path), 0)
        XCTAssertEqual(revoked.store.values?.runtime.dnsForwarderEnabled, true)
    }
}
