// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class ScriptedVPNDNSOverrideClient: PrivilegeClient, @unchecked Sendable {
    struct Unreachable: LocalizedError {
        var errorDescription: String? { "helper_unreachable" }
    }

    enum Scripted {
        case reply(VPNDNSOverrideReply)
        case fail
    }

    private let lock = NSLock()
    private var held: VPNDNSOverrideState?
    private var lastRelease: String?
    private var script: [Scripted] = []
    private var log: [VPNDNSOverrideRequest] = []
    private var onCall: (@Sendable (VPNDNSOverrideRequest) -> Void)?
    private let supported: Bool

    init(supported: Bool = true) {
        self.supported = supported
    }

    var requests: [VPNDNSOverrideRequest] { lock.withLock { log } }
    var record: VPNDNSOverrideState? { lock.withLock { held } }

    func script(_ replies: Scripted...) {
        lock.withLock { script.append(contentsOf: replies) }
    }

    func onEachCall(_ hook: @escaping @Sendable (VPNDNSOverrideRequest) -> Void) {
        lock.withLock { onCall = hook }
    }

    func releaseOnItsOwn(reason: String? = nil) {
        lock.withLock {
            held = nil
            lastRelease = reason
        }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {}
    func dnsRelayStatus() throws -> DNSRelayStatus? { nil }

    func vpnDNSOverride(_ request: VPNDNSOverrideRequest) throws -> VPNDNSOverrideReply {
        let (hook, scripted) = lock.withLock { () -> ((@Sendable (VPNDNSOverrideRequest) -> Void)?, Scripted?) in
            log.append(request)
            return (onCall, script.isEmpty ? nil : script.removeFirst())
        }
        hook?(request)
        switch scripted {
        case .reply(let reply)?: return reply
        case .fail?: throw Unreachable()
        case nil: break
        }
        guard supported else { return .unsupported }
        return lock.withLock {
            switch request {
            case .apply(let service, let expected):
                held = VPNDNSOverrideState(serviceID: service, originals: expected)
                return .applied
            case .release:
                held = nil
                return .released
            case .status:
                return .status(held, lastRelease: lastRelease)
            }
        }
    }
}

private let service = "com.cisco.anyconnect"
private let tunnelServers = ["192.0.2.53", "198.51.100.53"]

private func fullTunnel(
    _ id: String = service, servers: [String] = tunnelServers, interface: String = "utun6", overridden: Bool = false
) -> PushedResolver {
    PushedResolver(
        serviceID: id, searchOrder: 1, interface: interface, domains: ["corp.example"], servers: servers,
        overridesPrimary: true, overridden: overridden
    )
}

private func splitTunnel() -> PushedResolver {
    PushedResolver(serviceID: "split", interface: "utun3", domains: ["corp.example"], servers: ["192.0.2.10"])
}

final class VPNResolverOverridePolicyTests: XCTestCase {
    private let t0 = ContinuousClock.now

    private func input(
        _ resolvers: [PushedResolver] = [fullTunnel()],
        inUse: Set<String> = Set(tunnelServers),
        record: VPNDNSOverrideState? = nil,
        at offset: Duration = .zero,
        applies: [Duration] = [],
        backoffUntil: Duration? = nil,
        configure: (inout VPNResolverOverrideInput) -> Void = { _ in }
    ) -> VPNResolverOverrideInput {
        var input = VPNResolverOverrideInput(
            helperSupports: true, manageSystemDNS: true, relayServing: true, entriesWanted: true,
            reading: PushedResolverReading(resolvers: resolvers), serversInUse: inUse, record: record,
            now: t0 + offset, applies: applies.isEmpty ? [:] : [service: applies.map { t0 + $0 }],
            backoffUntil: backoffUntil.map { t0 + $0 }
        )
        configure(&input)
        return input
    }

    private let held = VPNDNSOverrideState(serviceID: service, originals: tunnelServers)

    func testAFullTunnelWhoseServersAreInUseIsApplied() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input()), .apply(service: service, expected: tunnelServers))
    }

    func testASplitTunnelIsNeverApplied() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([splitTunnel()], inUse: ["192.0.2.10"])), .none)
    }

    func testTwoFullTunnelsAreNeitherAppliedNorKept() {
        let two = [fullTunnel(), fullTunnel("other", servers: ["192.0.2.99"], interface: "utun7")]
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(two, inUse: Set(tunnelServers + ["192.0.2.99"]))), .none)
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(two, inUse: Set(tunnelServers + ["192.0.2.99"]), record: held)),
            .release(.notInUse)
        )
    }

    func testALiveSetWithoutEveryTunnelServerWaitsAndReleases() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(inUse: [tunnelServers[0]])), .none)
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(inUse: [], record: held)), .release(.notInUse))
    }

    func testEachPreconditionReleasesWithItsReason() {
        let cases: [(WritableKeyPath<VPNResolverOverrideInput, Bool>, VPNResolverOverrideReleaseReason)] = [
            (\.manageSystemDNS, .manageOff), (\.relayServing, .relayNotServing), (\.entriesWanted, .gate),
        ]
        for (field, reason) in cases {
            XCTAssertEqual(VPNResolverOverridePolicy.decide(input { $0[keyPath: field] = false }), .none, "\(reason)")
            XCTAssertEqual(VPNResolverOverridePolicy.decide(input(record: held) { $0[keyPath: field] = false }), .release(reason))
        }
    }

    func testAMatchingRecordIsKeptAndARewrittenKeyIsAppliedAgain() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(record: held)), .none)
        let rewritten = [fullTunnel(servers: ["203.0.113.53"])]
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(rewritten, inUse: ["203.0.113.53"], record: held)),
            .apply(service: service, expected: ["203.0.113.53"])
        )
    }

    func testAnUnsupportedHelperIsNeverAsked() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input { $0.helperSupports = false }), .none)
    }

    func testAnOverriddenReadingWithNoRecordSendsNothing() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([fullTunnel(overridden: true)])), .none)
    }

    func testABackoffHoldsTheApplyUntilItEnds() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(at: .seconds(59), backoffUntil: .seconds(60))), .none)
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(at: .seconds(60), backoffUntil: .seconds(60))),
            .apply(service: service, expected: tunnelServers)
        )
        XCTAssertEqual(
            (1...6).map(VPNResolverOverridePolicy.backoff(step:)),
            [.seconds(60), .seconds(120), .seconds(240), .seconds(480), .seconds(600), .seconds(600)]
        )
    }

    func testTheThirdApplyInTenMinutesIsTheLastAndThenItSuspends() {
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(at: .seconds(300), applies: [.zero, .seconds(100)])),
            .apply(service: service, expected: tunnelServers)
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(at: .seconds(300), applies: [.zero, .seconds(100), .seconds(200)])),
            .suspend(service: service, cap: .applied)
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(at: .seconds(601), applies: [.zero, .seconds(100), .seconds(200)])),
            .apply(service: service, expected: tunnelServers),
            "an apply older than the window no longer counts"
        )
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input { $0.suspended = [service: self.t0] }), .none)
    }

    func testASuspensionHoldsForItsLifetimeAndThenTheCapsDecideAfresh() {
        let suspended: (inout VPNResolverOverrideInput) -> Void = { $0.suspended = [service: self.t0] }
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(at: .seconds(599), configure: suspended)), .none)
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(at: .seconds(600), configure: suspended)),
            .apply(service: service, expected: tunnelServers)
        )
    }

    func testAReadingWithNoFullTunnelKeepsTheOverrideWhileTheHeldSetHasItsServers() {
        let ignored = PushedResolverReading(rejections: [
            .init(serviceID: service, interface: "utun6", reason: .noMatchDomains),
        ])
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([], record: held) { $0.reading = ignored }), .none)
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([], record: held)), .none, "the service left out entirely")
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input([splitTunnel()], inUse: Set(tunnelServers + ["192.0.2.10"]), record: held)),
            .none, "another service's split tunnel says nothing about this one"
        )
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([])), .none, "nothing held, nothing to keep")
    }

    func testTheHoldEndsWhenTheSetTheGateTheToggleOrTheRelayDoes() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([], inUse: [tunnelServers[0]], record: held)), .release(.notInUse))
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([], inUse: [], record: held)), .release(.notInUse))
        let cases: [(WritableKeyPath<VPNResolverOverrideInput, Bool>, VPNResolverOverrideReleaseReason)] = [
            (\.manageSystemDNS, .manageOff), (\.relayServing, .relayNotServing), (\.entriesWanted, .gate),
        ]
        for (field, reason) in cases {
            XCTAssertEqual(VPNResolverOverridePolicy.decide(input([], record: held) { $0[keyPath: field] = false }), .release(reason))
        }
    }

    func testAReadingOfAnotherFullTunnelOrOfTheServiceAsASplitTunnelReleases() {
        let other = fullTunnel("other", servers: ["192.0.2.99"], interface: "utun7")
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input([other], record: held)), .release(.notInUse),
            "another full tunnel, its servers not in use yet"
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input([other], inUse: Set(tunnelServers + ["192.0.2.99"]), record: held)),
            .apply(service: "other", expected: ["192.0.2.99"]), "once they are, the override moves to it"
        )
        let split = PushedResolver(serviceID: service, interface: "utun6", domains: ["corp.example"], servers: tunnelServers)
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([split], record: held)), .release(.notInUse))
    }

    func testAKeyTheClientRewroteWithTheSameServersIsAppliedAgain() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(record: held)), .none)
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(record: held) { $0.keyRewritten = true }),
            .apply(service: service, expected: tunnelServers)
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input([fullTunnel(overridden: true)], record: held) { $0.keyRewritten = true }),
            .none, "a reading of the relay is a release in flight or the helper's own write"
        )
    }


    func testASameServerRewriteCountsTowardNoCapAndWaitsOnlyForTheSpacing() {
        let capped: (inout VPNResolverOverrideInput) -> Void = {
            $0.applies = [service: [self.t0, self.t0 + .seconds(100), self.t0 + .seconds(200)]]
            $0.keyRewritten = true
            $0.lastApplies = [service: .init(at: self.t0 + .seconds(200), servers: tunnelServers)]
        }
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(record: held, at: .seconds(300), configure: capped)),
            .apply(service: service, expected: tunnelServers)
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(record: held, at: .seconds(203), configure: capped)),
            .wait(until: t0 + .seconds(210))
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(record: held, at: .seconds(210), configure: capped)),
            .apply(service: service, expected: tunnelServers)
        )
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input(
                [fullTunnel(servers: ["203.0.113.53"])], inUse: ["203.0.113.53"], record: held, at: .seconds(300), configure: capped
            )),
            .suspend(service: service, cap: .applied)
        )
    }

    func testAReleaseIsDecidedAgainstTheSetAboutToBeApplied() {
        let applied = input(record: held)
        XCTAssertEqual(VPNResolverOverridePolicy.decide(applied), .none, "the set in use has the tunnel's servers")
        var next = applied
        next.serversInUse = []
        XCTAssertEqual(VPNResolverOverridePolicy.decide(next), .release(.notInUse))
    }
}

final class VPNResolverOverrideControllerTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var instant = ContinuousClock.now
        var now: ContinuousClock.Instant { lock.withLock { instant } }
        func advance(_ by: Duration) { lock.withLock { instant += by } }
    }

    @RuntimeActor private final class Events {
        var lines: [String] = []
    }

    private let clock = Clock()
    @RuntimeActor private let recorded = Events()
    @RuntimeActor private var events: [String] {
        get { recorded.lines }
        set { recorded.lines = newValue }
    }

    @RuntimeActor private func controller(_ client: ScriptedVPNDNSOverrideClient) -> VPNResolverOverrideController {
        let clock = self.clock
        let recorded = self.recorded
        return VPNResolverOverrideController(
            client: client, work: PlatformWork(label: "test.vpn-override"), now: { clock.now }
        ) { event, _ in
            recorded.lines.append("\(event.event) \(event.detail ?? "")")
        }
    }

    nonisolated private func inputs(
        _ resolvers: [PushedResolver] = [fullTunnel()], inUse: Set<String> = Set(tunnelServers), entriesWanted: Bool = true
    ) -> VPNResolverOverrideController.Inputs {
        .init(
            manageSystemDNS: true, relayServing: true, entriesWanted: entriesWanted,
            reading: PushedResolverReading(resolvers: resolvers), serversInUse: inUse
        )
    }

    @RuntimeActor func testTheFirstApplyAsksTheHelperFirstAndSetsTheSubstitutionBeforeItIsSent() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        let seen = LockedLog<[String: [String]]>()
        client.onEachCall { [substitutions = controller.substitutions] request in
            if case .apply = request { seen.append(substitutions.current) }
        }

        await controller.pass({ self.inputs() }, pollStatus: false)

        XCTAssertEqual(client.requests, [.status, .apply(service: service, expected: tunnelServers)])
        XCTAssertEqual(seen.values, [[service: tunnelServers]], "set before the helper writes")
        XCTAssertEqual(controller.substitutions.current, [service: tunnelServers])
        XCTAssertEqual(controller.record, VPNDNSOverrideState(serviceID: service, originals: tunnelServers))
        XCTAssertEqual(events, ["dns.vpn_override_applied service=com.cisco.anyconnect servers=2"])
        XCTAssertFalse(events.joined().contains("192.0.2"), "no server address in an event")

        await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
        XCTAssertEqual(client.requests.count, 2, "a matching record sends nothing")
    }

    @RuntimeActor func testAHelperWithoutTheFeatureIsAskedOnceAndLeftAlone() async {
        let client = ScriptedVPNDNSOverrideClient(supported: false)
        let controller = controller(client)

        await controller.pass({ self.inputs() }, pollStatus: false)
        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertEqual(client.requests, [.status])
        XCTAssertEqual(controller.support, .unsupported)
        XCTAssertEqual(events, [])
    }

    @RuntimeActor func testARelayNotServingRefusalBacksOffAndRestoresTheSubstitutions() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        client.script(.reply(.status(nil)), .reply(.refused(.relayNotServing)))

        await controller.pass({ self.inputs() }, pollStatus: false)
        XCTAssertEqual(events, ["dns.vpn_override_refused reason=relay_not_serving"])
        XCTAssertEqual(controller.substitutions.current, [:])

        clock.advance(.seconds(59))
        await controller.pass({ self.inputs() }, pollStatus: false)
        XCTAssertEqual(client.requests.count, 2, "still backing off")

        clock.advance(.seconds(1))
        await controller.pass({ self.inputs() }, pollStatus: false)
        XCTAssertEqual(client.requests.last, .apply(service: service, expected: tunnelServers))
        XCTAssertNotNil(controller.record)
    }

    @RuntimeActor func testAReleaseTheHelperMadeIsSeenThroughStatusAndBacksOff() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)
        events = []

        client.releaseOnItsOwn()
        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertEqual(events, ["dns.vpn_override_released reason=helper:unknown"])
        XCTAssertNil(controller.record)
        XCTAssertEqual(controller.substitutions.current, [:])
        XCTAssertEqual(client.requests.last, .status, "backing off: no apply straight after")

        clock.advance(.seconds(60))
        await controller.pass({ self.inputs() }, pollStatus: false)
        XCTAssertEqual(client.requests.last, .apply(service: service, expected: tunnelServers))
    }

    @RuntimeActor func testTheHelpersReleaseReasonReachesTheEventAndAnUnknownOneDoesNot() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        client.releaseOnItsOwn(reason: "target_refused")
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.last, "dns.vpn_override_released reason=helper:target_refused")

        clock.advance(.seconds(60))
        await controller.pass({ self.inputs() }, pollStatus: false)
        client.releaseOnItsOwn(reason: "a reason from later 192.0.2.53")
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.last, "dns.vpn_override_released reason=helper:unknown")
    }

    @RuntimeActor func testAKeyThatLeavesTheOverrideAsksTheHelperWithoutATick() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
        let sent = client.requests.count

        client.releaseOnItsOwn()
        await controller.pass({ self.inputs([fullTunnel(overridden: false)]) }, pollStatus: false)

        XCTAssertEqual(client.requests.count, sent + 1)
        XCTAssertEqual(client.requests.last, .status)
        XCTAssertEqual(events.last, "dns.vpn_override_released reason=helper:unknown")
    }

    @RuntimeActor func testAnExplicitReleaseClearsTheSubstitutionsOnlyAfterItReturns() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)
        let seen = LockedLog<[String: [String]]>()
        client.onEachCall { [substitutions = controller.substitutions] request in
            if case .release = request { seen.append(substitutions.current) }
        }

        await controller.release(.stop)
        await controller.release(.stop)

        XCTAssertEqual(seen.values, [[service: tunnelServers]], "one release, sent while the substitution still holds")
        XCTAssertEqual(controller.substitutions.current, [:])
        XCTAssertEqual(events.last, "dns.vpn_override_released reason=stop")
        XCTAssertNil(client.record)
    }

    @RuntimeActor func testAPolicyReleaseCarriesItsReason() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        await controller.pass({ self.inputs(inUse: []) }, pollStatus: false)

        XCTAssertEqual(events.last, "dns.vpn_override_released reason=not_in_use")
        XCTAssertEqual(client.requests.last, .release)
    }

    @RuntimeActor func testAClientThatRewritesTheKeyIsFollowedThreeTimesThenSuspended() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        for index in 1...4 {
            let servers = ["203.0.113.\(index)"]
            await controller.pass({ self.inputs([fullTunnel(servers: servers)], inUse: Set(servers)) }, pollStatus: false)
            clock.advance(.seconds(10))
        }
        await controller.pass({ self.inputs([fullTunnel(servers: ["203.0.113.9"])], inUse: ["203.0.113.9"]) }, pollStatus: false)

        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 3)
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_suspended") }, ["dns.vpn_override_suspended service=com.cisco.anyconnect cap=applied"])

        await controller.pass({ self.inputs([], inUse: [], entriesWanted: false) }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel(servers: ["203.0.113.9"])], inUse: ["203.0.113.9"]) }, pollStatus: false)
        XCTAssertEqual(client.requests.last, .apply(service: service, expected: ["203.0.113.9"]))
    }

    @RuntimeActor func testAnApplyWithNoAnswerIsSettledByTheHelpersStatus() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        client.script(.reply(.status(nil)), .fail)

        await controller.pass({ self.inputs() }, pollStatus: false)

        XCTAssertEqual(events, ["dns.vpn_override_failed operation=apply reason=helper_unreachable"])
        XCTAssertTrue(controller.mayHoldRecord)
        XCTAssertEqual(controller.substitutions.current, [service: tunnelServers], "the helper may have written")

        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(Array(client.requests.suffix(2)), [.status, .apply(service: service, expected: tunnelServers)])
        XCTAssertNotNil(controller.record)
    }

    private var heldRecord: VPNDNSOverrideState { VPNDNSOverrideState(serviceID: service, originals: tunnelServers) }

    @RuntimeActor private func applied(_ controller: VPNResolverOverrideController) async {
        await controller.pass({ self.inputs() }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
    }

    @RuntimeActor private func flap(_ controller: VPNResolverOverrideController, _ client: ScriptedVPNDNSOverrideClient) async {
        await controller.pass({ self.inputs([]) }, pollStatus: false)
        client.script(.reply(.status(heldRecord)), .reply(.refused(.notPrimary)))
        await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
        await controller.pass({ self.inputs([]) }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
    }

    @RuntimeActor func testAFlapKeepsTheOverrideAndPutsTheRelayBackOnceTheServiceIsPrimary() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await applied(controller)
        events = []

        clock.advance(.seconds(66))
        await controller.pass({ self.inputs([]) }, pollStatus: false)
        XCTAssertEqual(client.requests.count, 2, "a reading with the service left out sends nothing, a release least of all")
        XCTAssertEqual(controller.record, heldRecord)
        XCTAssertEqual(controller.substitutions.current, [service: tunnelServers], "the key still reads as the tunnel's")

        clock.advance(.seconds(5))
        client.script(.reply(.status(heldRecord)), .reply(.refused(.notPrimary)))
        await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
        XCTAssertEqual(Array(client.requests.suffix(2)), [.status, .apply(service: service, expected: tunnelServers)],
                       "the client's own servers in the key: the helper still holds the record, so the client rewrote it")
        clock.advance(.seconds(1))
        await controller.pass({ self.inputs([]) }, pollStatus: false)
        clock.advance(.seconds(1))
        await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)

        XCTAssertEqual(events, [
            "dns.vpn_override_refused reason=not_primary",
            "dns.vpn_override_applied service=com.cisco.anyconnect servers=2",
        ])
        XCTAssertEqual(client.requests.filter { $0 == .release }, [])
        XCTAssertEqual(client.record, heldRecord)
    }

    @RuntimeActor func testASameServerRewriteBeforeAnyReadingOfTheWriteIsAppliedAgainByTheTick() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)
        let sent = client.requests.count

        clock.advance(.seconds(1))
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(Array(client.requests.dropFirst(sent)), [.status], "too soon: the reading may still be on its way")

        clock.advance(.seconds(29))
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(Array(client.requests.suffix(2)), [.status, .apply(service: service, expected: tunnelServers)])
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 2)
    }

    @RuntimeActor func testAFlapWhoseKeyStaysAtTheRelaySendsNothing() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await applied(controller)
        let sent = client.requests.count

        for _ in 1...3 {
            await controller.pass({ self.inputs([]) }, pollStatus: false)
            await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
        }
        await controller.pass({ self.inputs([]) }, pollStatus: true)

        XCTAssertEqual(Array(client.requests.dropFirst(sent)), [.status], "only the health tick's poll")
        XCTAssertEqual(events, ["dns.vpn_override_applied service=com.cisco.anyconnect servers=2"])
    }

    @RuntimeActor func testThreeFlapsInTenMinutesNeverSuspend() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await applied(controller)
        for _ in 1...3 {
            clock.advance(.seconds(150))
            await flap(controller, client)
        }

        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_suspended") }, "\(events)")
        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_released") })
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_refused") }.count, 3, "one refusal per flap")
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 4)
        XCTAssertEqual(client.record, heldRecord)
        XCTAssertEqual(controller.substitutions.current, [service: tunnelServers])
    }

    @RuntimeActor func testSameServerRewritesEvery25SecondsAreReappliedAtOnceAndNeverSuspend() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await applied(controller)
        for rewrite in 1...48 {
            clock.advance(.seconds(25))
            await controller.pass({ self.inputs([]) }, pollStatus: false)
            await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
            XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 1 + rewrite, "rewrite \(rewrite)")
            await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
        }

        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_suspended") })
        XCTAssertNil(controller.wakeAt)
        XCTAssertEqual(client.record, heldRecord)
    }

    @RuntimeActor func testInstantRewritesAreAppliedTenSecondsApart() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await applied(controller)
        for _ in 1...60 {
            clock.advance(.seconds(1))
            await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
            await controller.pass({ self.inputs([fullTunnel(overridden: true)]) }, pollStatus: false)
        }

        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 1 + 6)
        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_suspended") })
    }

    @RuntimeActor func testAWaitArmsOneWakeThatRunsAPass() async {
        let client = ScriptedVPNDNSOverrideClient()
        let released = AsyncStream<Void>.makeStream()
        let clock = self.clock
        let controller = VPNResolverOverrideController(
            client: client, work: PlatformWork(label: "test.vpn-override"), now: { clock.now },
            sleep: { _ in for await _ in released.stream { return } }
        ) { _, _ in }
        var wakes = 0
        controller.onWake = { wakes += 1 }
        await applied(controller)
        let appliedAt = clock.now

        clock.advance(.seconds(3))
        await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
        await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
        XCTAssertEqual(controller.wakeAt, appliedAt + VPNResolverOverridePolicy.minimumApplySpacing)
        XCTAssertEqual(client.requests.filter { if case .apply = $0 { true } else { false } }.count, 1)

        released.continuation.yield()
        for _ in 0..<1000 where wakes == 0 { await Task.yield() }
        XCTAssertEqual(wakes, 1)
        XCTAssertNil(controller.wakeAt)
    }

    @RuntimeActor func testChangedServersSuspendAtTheCapAndResumeWhenTheSuspensionExpires() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        for index in 1...4 {
            let servers = ["203.0.113.\(index)"]
            await controller.pass({ self.inputs([fullTunnel(servers: servers)], inUse: Set(servers)) }, pollStatus: false)
            clock.advance(.seconds(20))
        }
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 3)
        XCTAssertEqual(events.last, "dns.vpn_override_suspended service=com.cisco.anyconnect cap=applied")

        clock.advance(.seconds(579))
        await controller.pass({ self.inputs([fullTunnel(servers: ["203.0.113.4"])], inUse: ["203.0.113.4"]) }, pollStatus: false)
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_applied") }.count, 3)

        clock.advance(.seconds(1))
        await controller.pass({ self.inputs([fullTunnel(servers: ["203.0.113.4"])], inUse: ["203.0.113.4"]) }, pollStatus: false)
        XCTAssertEqual(Array(events.suffix(2)), [
            "dns.vpn_override_suspension_expired service=com.cisco.anyconnect",
            "dns.vpn_override_applied service=com.cisco.anyconnect servers=1",
        ])
        XCTAssertEqual(client.requests.last, .apply(service: service, expected: ["203.0.113.4"]))
    }

    @RuntimeActor func testAPersistentNotPrimaryRefusalNeverSuspendsAndIsAttemptedOncePerPass() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        client.script(.reply(.status(nil)))
        for pass in 1...120 {
            client.script(.reply(.refused(.notPrimary)))
            await controller.pass({ self.inputs() }, pollStatus: false)
            XCTAssertEqual(client.requests.filter { if case .apply = $0 { true } else { false } }.count, pass)
            XCTAssertNil(controller.wakeAt, "a refusal arms no wake")
            clock.advance(.seconds(1))
        }

        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_suspended") })
        XCTAssertNil(controller.record)
    }

    @RuntimeActor func testAClientThatFlapsEvery25SecondsAndIsRefusedEachTimeIsNeverSuspended() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await applied(controller)
        for flap in 1...48 {
            clock.advance(.seconds(25))
            await controller.pass({ self.inputs([]) }, pollStatus: false)
            client.script(.reply(.status(heldRecord)), .reply(.refused(.notPrimary)))
            await controller.pass({ self.inputs([fullTunnel()]) }, pollStatus: false)
            XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_refused") }.count, flap)
        }

        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_suspended") })
    }

    @RuntimeActor func testAReleaseWithNothingSentAsksNothing() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)

        await controller.release(.manageOff)

        XCTAssertEqual(client.requests, [])
        XCTAssertEqual(events, [])
    }
}
