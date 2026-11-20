// SPDX-License-Identifier: Apache-2.0
import NIOPosix
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

final class RuntimeHostVPNDNSOverrideTests: XCTestCase {
    private var harness: InteractiveHostHarness?
    private let tunnelServer = "192.0.2.53"
    private let corpIP = "198.51.100.10"

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private struct Running {
        let host: RuntimeHost
        let harness: InteractiveHostHarness

        @RuntimeActor var lines: [String] {
            host.orchestrator.eventLog.events.map { "\($0.event) \($0.detail ?? "")" }
        }

        @RuntimeActor func index(_ prefix: String) -> Int? {
            lines.firstIndex { $0.hasPrefix(prefix) }
        }

        @RuntimeActor func report(_ state: VPNObservedState, live: [String]) async {
            harness.vpn.liveInterfaceNames = live
            harness.vpn.connectedInterfaceName = live.first
            harness.vpn.emit(state)
            await host.deliveries.drain()
        }
    }

    private func fullTunnel() -> PushedResolver {
        PushedResolver(
            serviceID: "com.cisco.anyconnect", searchOrder: 1, interface: "utun6", domains: ["corp.example"],
            servers: [tunnelServer], overridesPrimary: true
        )
    }

    private func requireForwardingAudit() throws {
        let audited = AuditingPrivilegeClient(base: ScriptedVPNDNSOverrideClient(), eventSink: { _ in })
        XCTAssertNotEqual(try audited.vpnDNSOverride(.status), .unsupported)
    }

    @RuntimeActor private func start(override client: ScriptedVPNDNSOverrideClient?) async throws -> Running {
        let corp = try await FakeSplitDNSServer.start(domain: "corp.example", ip: corpIP)
        let doh = try await AnsweringDoHProvider.start(group: MultiThreadedEventLoopGroup.singleton, ip: "203.0.113.7")
        addTeardownBlock {
            await corp.stop()
            await doh.channel.closeForTest()
        }
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        let harness = try InteractiveHostHarness(config: config, platform: PlatformIntegrationConfig(manageSystemDNS: true))
        self.harness = harness
        harness.dnsForwarderTuning = SplitDNSProbe.tuning([tunnelServer: corp.port])
        harness.pushedResolvers.primedReading = PushedResolverReading(resolvers: [fullTunnel()])
        harness.vpnDNSOverride = client
        let host = try await harness.makeHost()
        try await host.startRuntime()
        await host.deliveries.drain()
        XCTAssertEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertTrue(host.vpnDNSOverrideRelayServing, "the health timer watches the relay")
        return Running(host: host, harness: harness)
    }

    @RuntimeActor func testAHelperWithoutTheFeatureLeavesTheVPNKeyAlone() async throws {
        let running = try await start(override: nil)

        await running.report(.connected, live: ["utun6"])

        XCTAssertNotNil(running.index("dns.split_table_changed detected_domains=1"))
        XCTAssertEqual(running.lines.filter { $0.hasPrefix("dns.vpn_override_") }, [])
        XCTAssertEqual(running.host.vpnDNSOverride.support, .unsupported)
    }

    @RuntimeActor func testTheArmLandsAfterTheTunnelsServersAreInUse() async throws {
        try requireForwardingAudit()
        let client = ScriptedVPNDNSOverrideClient()
        let running = try await start(override: client)

        await running.report(.connected, live: ["utun6"])

        XCTAssertEqual(client.requests.first, .arm(service: "com.cisco.anyconnect", servers: [tunnelServer]))
        let set = try XCTUnwrap(running.index("dns.split_table_changed detected_domains=1"))
        let armed = try XCTUnwrap(running.index("dns.vpn_override_armed service=com.cisco.anyconnect servers=1"))
        let published = try XCTUnwrap(running.index("dns.vpn_override_published service=com.cisco.anyconnect"))
        XCTAssertLessThan(set, armed)
        XCTAssertLessThan(armed, published)
    }

    @RuntimeActor func testAFailedArmIsSettledByTheNextStatusAndSentAgain() async throws {
        try requireForwardingAudit()
        let client = ScriptedVPNDNSOverrideClient()
        client.script(.fail)
        let running = try await start(override: client)
        let arms = { client.requests.filter { if case .arm = $0 { true } else { false } }.count }

        await running.report(.connected, live: ["utun6"])
        XCTAssertEqual(arms(), 1)
        for _ in 0..<50 { await Task.yield() }
        await running.host.deliveries.drain()
        XCTAssertEqual(arms(), 1, "a failure triggers no pass of its own")
        XCTAssertTrue(running.host.vpnDNSOverride.mayArm, "an arm with no reply may be held")

        running.host.requestVPNDNSOverrideRun(pollStatus: true)
        await running.host.deliveries.drain()
        XCTAssertEqual(arms(), 2)
    }

    @RuntimeActor func testADisconnectDisarmsBeforeTheSetDrops() async throws {
        try requireForwardingAudit()
        let client = ScriptedVPNDNSOverrideClient()
        let running = try await start(override: client)
        await running.report(.connected, live: ["utun6"])

        await running.report(.disconnected(reason: .userInitiated), live: [])

        let disarmed = try XCTUnwrap(running.index("dns.vpn_override_disarmed reason=gate"))
        let dropped = try XCTUnwrap(running.index("dns.split_table_changed detected_domains=0"))
        XCTAssertLessThan(disarmed, dropped, "the default resolver leaves the relay before the tunnel's servers do")
        XCTAssertNil(client.arm)
    }

    @RuntimeActor func testManageSystemDNSOffDisarmsBeforeSystemDNSIsRestored() async throws {
        try requireForwardingAudit()
        let client = ScriptedVPNDNSOverrideClient()
        let running = try await start(override: client)
        await running.report(.connected, live: ["utun6"])
        let before = running.lines.count

        _ = await running.host.perform(
            .clearSystemDNS, config: running.host.config, previousConfig: running.host.config,
            platform: PlatformIntegrationConfig(), previousPlatform: running.host.platformConfig
        )

        let after = Array(running.lines.dropFirst(before))
        let disarmed = try XCTUnwrap(after.firstIndex { $0.hasPrefix("dns.vpn_override_disarmed reason=manage_off") })
        if let relayStop = after.firstIndex(where: { $0.contains("command=stop-dns-relay outcome=requested") }) {
            XCTAssertLessThan(disarmed, relayStop)
        }
        XCTAssertNil(client.arm)
    }

    @RuntimeActor func testASetHeldWhileAnArmIsOutIsDecidedOnAgainBeforeItIsApplied() async throws {
        try requireForwardingAudit()
        let client = ScriptedVPNDNSOverrideClient()
        let running = try await start(override: client)
        let applying = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        client.onEachCall { request in
            guard case .arm = request else { return }
            applying.signal()
            proceed.wait()
        }
        running.harness.vpn.liveInterfaceNames = ["utun6"]
        running.harness.vpn.connectedInterfaceName = "utun6"
        running.harness.vpn.emit(.connected)
        await Task.detached { Self.block(on: applying) }.value

        running.harness.vpn.liveInterfaceNames = []
        running.harness.vpn.connectedInterfaceName = nil
        running.harness.vpn.emit(.disconnected(reason: .userInitiated))
        for _ in 0..<500 where running.host.vpnDNSOverrideHeldSet == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertNotNil(running.host.vpnDNSOverrideHeldSet, "the empty set waits for the pass")
        proceed.signal()
        await running.host.deliveries.drain()

        let armed = try XCTUnwrap(running.index("dns.vpn_override_armed"))
        let disarmed = try XCTUnwrap(running.index("dns.vpn_override_disarmed reason=gate"))
        let dropped = try XCTUnwrap(running.index("dns.split_table_changed detected_domains=0"))
        XCTAssertLessThan(armed, disarmed)
        XCTAssertLessThan(disarmed, dropped, "the disarm lands before the forwarder loses the tunnel's servers")
        XCTAssertNil(client.arm)
        XCTAssertNil(running.host.vpnDNSOverrideHeldSet)
    }

    /// Off the RuntimeActor: the host's pass runs while this waits.
    nonisolated private static func block(on semaphore: DispatchSemaphore) {
        semaphore.wait()
    }

    @RuntimeActor func testStopDisarmsBeforeTheRelayStops() async throws {
        try requireForwardingAudit()
        let client = ScriptedVPNDNSOverrideClient()
        let running = try await start(override: client)
        await running.report(.connected, live: ["utun6"])
        let before = running.lines.count

        await running.host.stopRuntime()
        await running.host.deliveries.drain()

        let after = Array(running.lines.dropFirst(before))
        let disarmed = try XCTUnwrap(after.firstIndex { $0.hasPrefix("dns.vpn_override_disarmed reason=stop") })
        if let relayStop = after.firstIndex(where: { $0.contains("command=stop-dns-relay outcome=requested") }) {
            XCTAssertLessThan(disarmed, relayStop)
        }
        XCTAssertNil(client.arm)
    }
}
