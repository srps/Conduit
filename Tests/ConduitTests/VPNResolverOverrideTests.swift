// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// A helper that holds one arm, with what it would say about its key scripted.
final class ScriptedVPNDNSOverrideClient: PrivilegeClient, @unchecked Sendable {
    struct Unreachable: LocalizedError {
        var errorDescription: String? { "helper_unreachable" }
    }

    enum Scripted {
        case reply(VPNDNSOverrideReply)
        case fail
    }

    private let lock = NSLock()
    private var held: VPNResolverOverrideArm?
    private var published = true
    private var reason: String?
    private var owned = true
    private var losesArmReplies = false
    private var script: [Scripted] = []
    private var log: [VPNDNSOverrideRequest] = []
    private var onCall: (@Sendable (VPNDNSOverrideRequest) -> Void)?
    private let supported: Bool

    init(supported: Bool = true) {
        self.supported = supported
    }

    var requests: [VPNDNSOverrideRequest] { lock.withLock { log } }
    var arm: VPNResolverOverrideArm? { lock.withLock { held } }

    func script(_ replies: Scripted...) {
        lock.withLock { script.append(contentsOf: replies) }
    }

    func onEachCall(_ hook: @escaping @Sendable (VPNDNSOverrideRequest) -> Void) {
        lock.withLock { onCall = hook }
    }

    /// The helper withdrawing its key by itself, keeping the arm.
    func withdrawOnItsOwn(reason: String) {
        lock.withLock {
            published = false
            self.reason = reason
        }
    }

    func publishAgain() {
        lock.withLock {
            published = true
            reason = nil
        }
    }

    /// A fresh helper: the arm is gone.
    func restart() {
        lock.withLock { held = nil }
    }

    /// Another process armed it.
    func disown() {
        lock.withLock { owned = false }
    }

    func loseArmReplies() {
        lock.withLock { losesArmReplies = true }
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
        let (reply, lost) = lock.withLock { () -> (VPNDNSOverrideReply, Bool) in
            switch request {
            case .arm(let service, let servers):
                held = VPNResolverOverrideArm(service: service, servers: servers)
                owned = true
                return (.armed, losesArmReplies)
            case .disarm:
                held = nil
                return (.disarmed, false)
            case .status:
                return (.status(held.map {
                    VPNDNSOverrideState(
                        serviceID: $0.service, servers: $0.servers, published: published,
                        reason: published ? nil : reason, owned: owned, port: published ? HelperConstants.vpnDNSOverrideRelayPort : nil
                    )
                }), false)
            }
        }
        if lost { throw Unreachable() }
        return reply
    }
}

private let service = "com.cisco.anyconnect"
private let tunnelServers = ["192.0.2.53", "198.51.100.53"]
private let target = VPNResolverOverrideArm(service: service, servers: tunnelServers)
private let ours = FirstResolver(nameserver: "127.0.0.1", port: HelperConstants.vpnDNSOverrideRelayPort)

private func fullTunnel(_ id: String = service, servers: [String] = tunnelServers, interface: String = "utun6") -> PushedResolver {
    PushedResolver(
        serviceID: id, searchOrder: 1, interface: interface, domains: ["corp.example"], servers: servers, overridesPrimary: true
    )
}

private func splitTunnel() -> PushedResolver {
    PushedResolver(serviceID: "split", interface: "utun3", domains: ["corp.example"], servers: ["192.0.2.10"])
}

final class VPNResolverOverridePolicyTests: XCTestCase {
    private func input(
        _ resolvers: [PushedResolver] = [fullTunnel()],
        inUse: Set<String> = Set(tunnelServers),
        armed: VPNResolverOverrideArm? = nil,
        configure: (inout VPNResolverOverrideInput) -> Void = { _ in }
    ) -> VPNResolverOverrideInput {
        var input = VPNResolverOverrideInput(
            helperSupports: true, manageSystemDNS: true, relayServing: true, entriesWanted: true,
            reading: PushedResolverReading(resolvers: resolvers), serversInUse: inUse, armed: armed
        )
        configure(&input)
        return input
    }

    func testAFullTunnelWhoseServersAreInUseIsArmed() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input()), .arm(target))
    }

    func testASplitTunnelIsNeverArmed() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([splitTunnel()])), .none)
    }

    func testTwoFullTunnelsAreNeitherArmedNorKept() {
        let two = [fullTunnel(), fullTunnel("other", servers: ["203.0.113.53"], interface: "utun7")]
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(two)), .none)
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(two, armed: target)), .disarm(.notInUse))
    }

    func testALiveSetWithoutEveryTunnelServerWaitsAndDisarms() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(inUse: [tunnelServers[0]])), .none)
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(inUse: [tunnelServers[0]], armed: target)), .disarm(.notInUse))
    }

    func testAReadingWithNoFullTunnelDisarms() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input([], armed: target)), .disarm(.notInUse))
    }

    func testEachPreconditionDisarmsWithItsReason() {
        let cases: [(VPNResolverOverrideDisarmReason, (inout VPNResolverOverrideInput) -> Void)] = [
            (.manageOff, { $0.manageSystemDNS = false }),
            (.relayNotServing, { $0.relayServing = false }),
            (.stop, { $0.dnsStopping = true; $0.relayServing = false }),
            (.gate, { $0.entriesWanted = false }),
        ]
        for (reason, configure) in cases {
            XCTAssertEqual(VPNResolverOverridePolicy.decide(input(armed: target, configure: configure)), .disarm(reason))
            XCTAssertEqual(VPNResolverOverridePolicy.decide(input(configure: configure)), .none, "nothing armed, nothing sent")
        }
    }

    func testAMatchingArmIsKeptAndNewServersAreArmedAgain() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input(armed: target)), .none)
        let moved = ["203.0.113.53"]
        XCTAssertEqual(
            VPNResolverOverridePolicy.decide(input([fullTunnel(servers: moved)], inUse: Set(moved), armed: target)),
            .arm(VPNResolverOverrideArm(service: service, servers: moved))
        )
    }

    func testAnUnsupportedHelperIsNeverAskedToArm() {
        XCTAssertEqual(VPNResolverOverridePolicy.decide(input { $0.helperSupports = false }), .none)
    }
}

final class VPNResolverOverrideControllerTests: XCTestCase {
    @RuntimeActor private final class Events {
        var lines: [String] = []
    }

    @RuntimeActor private let recorded = Events()
    @RuntimeActor private var events: [String] { recorded.lines }
    private let order = FakeResolverOrder(first: ours)

    @RuntimeActor private func controller(_ client: ScriptedVPNDNSOverrideClient) -> VPNResolverOverrideController {
        let recorded = self.recorded
        return VPNResolverOverrideController(
            client: client, work: PlatformWork(label: "test.vpn-override"), resolverOrder: order
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

    @RuntimeActor func testAnArmIsConfirmedByTheHelpersStatus() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)

        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertEqual(client.requests, [.arm(service: service, servers: tunnelServers), .status])
        XCTAssertEqual(controller.armed, target)
        XCTAssertTrue(controller.published)
        XCTAssertEqual(events, [
            "dns.vpn_override_armed service=com.cisco.anyconnect servers=2",
            "dns.vpn_override_published service=com.cisco.anyconnect",
        ])
        XCTAssertFalse(events.joined().contains("192.0.2"), "no server address in an event")

        await controller.pass({ self.inputs() }, pollStatus: false)
        XCTAssertEqual(client.requests.count, 2, "a matching arm sends nothing")
    }

    @RuntimeActor func testAHelperWithoutTheFeatureIsAskedOnceAndLeftAlone() async {
        let client = ScriptedVPNDNSOverrideClient(supported: false)
        let controller = controller(client)

        await controller.pass({ self.inputs() }, pollStatus: true)
        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertEqual(client.requests, [.arm(service: service, servers: tunnelServers)])
        XCTAssertEqual(controller.support, .unsupported)
        XCTAssertFalse(controller.mayArm)
        XCTAssertEqual(events, [])
    }

    @RuntimeActor func testAPolicyDisarmCarriesItsReason() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        await controller.pass({ self.inputs(entriesWanted: false) }, pollStatus: false)

        XCTAssertEqual(client.requests.last, .disarm)
        XCTAssertNil(client.arm)
        XCTAssertFalse(controller.mayArm)
        XCTAssertEqual(Array(events.suffix(2)), ["dns.vpn_override_disarmed reason=gate", "dns.vpn_override_withdrawn reason=disarmed"])
    }

    @RuntimeActor func testAWithdrawalTheHelperMadeIsSeenThroughStatusAndTheArmIsKept() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        client.withdrawOnItsOwn(reason: "target_silent")
        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertEqual(events.last, "dns.vpn_override_withdrawn reason=target_silent")
        XCTAssertEqual(controller.armed, target, "the helper keeps the arm and republishes by itself")
        XCTAssertEqual(client.requests.filter { if case .arm = $0 { true } else { false } }.count, 1)

        client.publishAgain()
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.last, "dns.vpn_override_published service=com.cisco.anyconnect")
    }

    @RuntimeActor func testAFreshHelperIsArmedAgain() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        client.restart()
        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertTrue(events.contains("dns.vpn_override_withdrawn reason=helper_stopping"))
        XCTAssertEqual(client.arm, target)
        XCTAssertEqual(client.requests.filter { if case .arm = $0 { true } else { false } }.count, 2)
        XCTAssertTrue(controller.published)
    }

    @RuntimeActor func testAnArmAnotherCallerHoldsIsArmedAgain() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        client.disown()
        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertTrue(events.contains("dns.vpn_override_withdrawn reason=rearmed"))
        XCTAssertEqual(client.requests.filter { if case .arm = $0 { true } else { false } }.count, 2)
    }

    @RuntimeActor func testAnArmWhoseReplyIsLostCountsAsArmedUntilAStatusSettlesIt() async {
        let client = ScriptedVPNDNSOverrideClient()
        client.loseArmReplies()
        let controller = controller(client)

        await controller.pass({ self.inputs() }, pollStatus: false)
        XCTAssertTrue(events.contains { $0.hasPrefix("dns.vpn_override_failed operation=arm") })
        XCTAssertEqual(controller.unconfirmed, target)
        XCTAssertTrue(controller.mayArm)

        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(controller.armed, target, "the status shows the helper took it")
        XCTAssertNil(controller.unconfirmed)
        XCTAssertEqual(client.requests.filter { if case .arm = $0 { true } else { false } }.count, 1)
    }

    @RuntimeActor func testAnArmWhoseReplyIsLostIsDisarmedOnceNoLongerWanted() async {
        let client = ScriptedVPNDNSOverrideClient()
        client.loseArmReplies()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)

        await controller.pass({ self.inputs(entriesWanted: false) }, pollStatus: false)

        XCTAssertEqual(client.requests.last, .disarm)
        XCTAssertNil(client.arm)
        XCTAssertFalse(controller.mayArm)
    }

    @RuntimeActor func testAResolverOrderThatSkipsTheKeyIsReportedOncePerChange() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        order.first = FirstResolver(nameserver: tunnelServers[0], port: nil)

        await controller.pass({ self.inputs() }, pollStatus: false)
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_not_first") }, ["dns.vpn_override_not_first service=com.cisco.anyconnect"])

        order.first = ours
        await controller.pass({ self.inputs() }, pollStatus: true)
        order.first = FirstResolver(nameserver: "127.0.0.1", port: 53)
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_not_first") }.count, 2, "the :53 relay first is not the key")
    }

    @RuntimeActor func testAnUnreadableResolverOrderIsReportedOncePerChange() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        order.failure = .exitStatus(1)

        await controller.pass({ self.inputs() }, pollStatus: false)
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_order_unreadable") },
                       ["dns.vpn_override_order_unreadable service=com.cisco.anyconnect reason=exit_status_1"])
        XCTAssertFalse(events.contains { $0.hasPrefix("dns.vpn_override_not_first") }, "an unread order is not a wrong one")

        order.failure = nil
        await controller.pass({ self.inputs() }, pollStatus: true)
        order.failure = .noFirstResolver
        await controller.pass({ self.inputs() }, pollStatus: true)
        XCTAssertEqual(events.filter { $0.hasPrefix("dns.vpn_override_order_unreadable") }.count, 2, "a good read rearms the report")
    }

    @RuntimeActor func testTheOrderIsNotReadWhileTheKeyIsWithdrawn() async {
        let client = ScriptedVPNDNSOverrideClient()
        client.withdrawOnItsOwn(reason: "vpn_changed")
        let controller = controller(client)

        await controller.pass({ self.inputs() }, pollStatus: true)

        XCTAssertEqual(order.reads, 0)
        XCTAssertFalse(controller.published)
    }

    @RuntimeActor func testADisarmWithNothingArmedAsksNothing() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.disarm(.stop)
        XCTAssertEqual(client.requests, [])
        XCTAssertEqual(events, [])
    }

    @RuntimeActor func testAFailedDisarmKeepsTheArmForTheNextPass() async {
        let client = ScriptedVPNDNSOverrideClient()
        let controller = controller(client)
        await controller.pass({ self.inputs() }, pollStatus: false)
        client.script(.fail)

        await controller.disarm(.stop)

        XCTAssertTrue(controller.mayArm)
        XCTAssertTrue(events.contains { $0.hasPrefix("dns.vpn_override_failed operation=disarm") })
        await controller.pass({ self.inputs(entriesWanted: false) }, pollStatus: false)
        XCTAssertFalse(controller.mayArm)
    }
}

final class ScutilResolverOrderTests: XCTestCase {
    private let published = """
    DNS configuration

    resolver #1
      nameserver[0] : 127.0.0.1
      port     : 15353
      flags    : Supplemental, Request A records
      reach    : 0x00030002 (Reachable,Local Address,Directly Reachable Address)
      order    : 0

    resolver #2
      search domain[0] : corp.example
      nameserver[0] : 192.0.2.53
      if_index : 23 (utun6)
      flags    : Request A records
      order    : 1

    DNS configuration (for scoped queries)

    resolver #1
      nameserver[0] : 127.0.0.1
      if_index : 15 (en0)
    """

    func testResolverOneIsReadWithItsPort() {
        XCTAssertEqual(ScutilResolverOrder.parse(published), FirstResolver(nameserver: "127.0.0.1", port: 15353))
    }

    func testResolverOneWithoutAPortHasNone() {
        let vpn = "DNS configuration\n\nresolver #1\n  nameserver[0] : 192.0.2.53\n  order    : 1\n\nresolver #2\n  port : 15353\n"
        XCTAssertEqual(ScutilResolverOrder.parse(vpn), FirstResolver(nameserver: "192.0.2.53", port: nil))
    }

    func testOutputWithoutAResolverIsUnreadable() {
        XCTAssertNil(ScutilResolverOrder.parse(""))
        XCTAssertNil(ScutilResolverOrder.parse("No DNS configuration available\n"))
    }

    func testRenderRoundTrips() {
        for first in [ours, FirstResolver(nameserver: "192.0.2.53", port: nil), FirstResolver(nameserver: nil, port: nil)] {
            XCTAssertEqual(ScutilResolverOrder.parse(ScutilResolverOrder.render(first: first)), first)
        }
    }

    func testAFailedRunIsUnreadable() {
        let published = self.published
        let failed = ScutilResolverOrder(run: { _, _ in CommandResult(exitCode: 1, standardOutput: published, standardError: "") })
        XCTAssertEqual(failed.firstResolver(), .failure(.exitStatus(1)))
        struct Boom: Error {}
        guard case .failure(.runFailed) = ScutilResolverOrder(run: { _, _ in throw Boom() }).firstResolver() else {
            return XCTFail("a run that throws is unreadable")
        }
        let empty = ScutilResolverOrder(run: { _, _ in CommandResult(exitCode: 0, standardOutput: "", standardError: "") })
        XCTAssertEqual(empty.firstResolver(), .failure(.noFirstResolver))
        let ran = ScutilResolverOrder(run: { path, arguments in
            XCTAssertEqual(path, "/usr/sbin/scutil")
            XCTAssertEqual(arguments, ["--dns"])
            return CommandResult(exitCode: 0, standardOutput: published, standardError: "")
        })
        XCTAssertEqual(ran.firstResolver(), .success(FirstResolver(nameserver: "127.0.0.1", port: 15353)))
    }
}
