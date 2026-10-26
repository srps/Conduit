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

    private func admitted(_ intents: inout RuntimeModuleIntents, _ request: RuntimeLifecycleRequest) throws -> Int {
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
        XCTAssertEqual(intents.authorize(group: group), [.dns])
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
            intents.retire(group: held)
            XCTAssertEqual(intents.modules.dns.enabled, before.enabled, "held: \(dnsEnabled) \(stopFirst)")
            XCTAssertEqual(intents.modules.dns.fenced, before.fenced, "held: \(dnsEnabled) \(stopFirst)")
            XCTAssertNil(intents.modules.dns.pending)

            let failed = try admitted(&intents, request(dns: .start))
            XCTAssertEqual(intents.authorize(group: failed), [.dns])
            let replacing = try admitted(&intents, request(dns: .start))
            intents.settle(.dns, group: failed, succeeded: false)
            XCTAssertNil(intents.modules.dns.authorized, "the replaced authorization is gone")
            XCTAssertEqual(intents.authorize(group: replacing), [.dns])
            intents.settle(.dns, group: replacing, succeeded: false)
            XCTAssertEqual(intents.modules.dns.enabled, before.enabled, "failed: the chain restores the pre-Start state")
            XCTAssertEqual(intents.modules.dns.fenced, before.fenced, "failed: \(dnsEnabled) \(stopFirst)")
            XCTAssertFalse(intents.conditionalActivationAllowed(group: replacing))
        }
    }

    /// A companion activation projects DNS's existing intent and never enables it. Its failure, unlike an explicit Start's, changes nothing,
    /// so the prior enable stays for the next explicit request. A Stop of DNS cancels only the companion; the proxy Start stands.
    func testAConditionalActivationNeverEnablesAndADNSStopCancelsOnlyIt() throws {
        var disabled = RuntimeModuleIntents(dnsEnabled: false)
        let off = try admitted(&disabled, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertFalse(disabled.stagedDNSForwarderEnabled)
        XCTAssertFalse(disabled.conditionalActivationAllowed(group: off), "a disabled DNS is a typed no-op")
        XCTAssertEqual(disabled.authorize(group: off), [.proxy], "the companion is not a member of the shared prepare")
        XCTAssertFalse(disabled.modules.dns.enabled)

        var enabled = RuntimeModuleIntents(dnsEnabled: true)
        let on = try admitted(&enabled, request(proxy: .start, dns: .conditionalActivation))
        XCTAssertTrue(enabled.conditionalActivationAllowed(group: on))
        enabled.finishConditional(group: on)
        XCTAssertTrue(enabled.modules.dns.enabled, "a failed companion keeps the prior enable and fence")
        XCTAssertFalse(enabled.modules.dns.fenced)

        var stopped = RuntimeModuleIntents(dnsEnabled: true)
        let restart = try admitted(&stopped, request(proxy: .start, dns: .conditionalActivation))
        stopped.stop([.dns], terminal: false)
        XCTAssertFalse(stopped.conditionalActivationAllowed(group: restart))
        XCTAssertTrue(stopped.isPending(group: restart), "the proxy Start is not stopped by the companion's cancellation")

        XCTAssertEqual(stopped.admit(request(dns: .conditionalActivation)), .failure(.invalid), "a companion needs a proxy Start")
        XCTAssertEqual(stopped.admit(request(proxy: .conditionalActivation)), .failure(.invalid))
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
        let group = try admitted(&intents, request(proxy: .start, dns: .conditionalActivation, tunnels: .start))
        let newer = try admitted(&intents, request(dns: .start))
        XCTAssertTrue(intents.isPending(group: group), "replacing the companion leaves the group")
        intents.stop([.tunnels], terminal: false)
        XCTAssertFalse(intents.isPending(group: group))
        XCTAssertNil(intents.modules.proxy.pending, "the proxy member ended with the group")
        XCTAssertTrue(intents.isPending(group: newer), "the newer DNS Start is not the old group's")
        XCTAssertEqual(intents.modules.proxy.revision, intents.counter, "an ended member takes the superseding revision")
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

    /// Every sequence of up to four steps from both DNS starting values. The checks are invariants stated from the decisions, not a copy of
    /// the transitions: only an authorization raises a permission or clears a fence; a held or failed Start restores what its admission found;
    /// a refusal changes nothing; the counter never goes back; the projection is the explicit DNS target, else the durable intent.
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
        var latest: Int?
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
                case .success(let group):
                    latest = group
                    admittedFrom[group] = before
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
                if !intents.authorize(group: group).isEmpty {
                    if before.modules.proxy.fenced && !intents.modules.proxy.fenced
                        || before.modules.dns.fenced && !intents.modules.dns.fenced {
                        coverage["authorize.clearedFence", default: 0] += 1
                    }
                }
            case .retire:
                guard let group = latest, let origin = admittedFrom[group] else { continue }
                let members = intents.members(of: group)
                intents.retire(group: group)
                for module in members {
                    if intents.modules[module].enabled != origin.modules[module].enabled
                        || intents.modules[module].fenced != origin.modules[module].fenced {
                        return "a held Start left \(module) different from its admission"
                    }
                    coverage["retire.restored", default: 0] += 1
                }
            case .fail, .succeed:
                guard let group = latest else { continue }
                for module in ControlModule.allCases where intents.modules[module].authorized?.group == group {
                    let prior = intents.modules[module].authorized!
                    intents.settle(module, group: group, succeeded: step == .succeed)
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
            for module in ControlModule.allCases {
                let raised = !before.modules[module].enabled && intents.modules[module].enabled
                let cleared = before.modules[module].fenced && !intents.modules[module].fenced
                if (raised || cleared) && step != .authorize { return "\(step) raised \(module)'s permission or cleared its fence" }
                if case .conditional = intents.modules[module].pending, module != .dns { return "a companion on \(module)" }
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
        let reread = try XCTUnwrap(fixture.access.storedBytes(at: fixture.plan.config.path))
        XCTAssertFalse(String(decoding: reread, as: UTF8.self).contains("\"dnsForwarderEnabled\":true"))

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

    /// A runtime file that carries legacy preference values with no sidecar is held, as every runtime rewrite is (decision 0026).
    func testTheDNSDisableKeepsTheLegacyPreferenceGuard() async throws {
        let staged = try enabledRuntime()
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: staged) as? [String: Any])
        object["showMenuBarIcon"] = false
        let legacy = try JSONSerialization.data(withJSONObject: object)
        let fixture = try ConfigurationStoreTests.Fixture(runtime: legacy, platform: try platformBytes())
        defer { fixture.close() }
        try await load(fixture)

        let outcome = await disable(fixture)
        XCTAssertEqual(outcome, .notAttempted(.preservationHeld(.sidecarAbsent)))
        XCTAssertEqual(writes(fixture, at: fixture.plan.config.path), 0)
        XCTAssertEqual(fixture.access.storedBytes(at: fixture.plan.config.path), legacy)
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
