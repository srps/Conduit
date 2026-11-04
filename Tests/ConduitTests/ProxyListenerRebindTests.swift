// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class ProxyListenerRebindTests: XCTestCase {

    @RuntimeActor private func makeOrchestrator(port: Int = 0, dns: Bool = false) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = port
        config.upstreams = []
        config.dnsForwarderEnabled = dns
        config.dnsForwarderPort = 0
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }

    @RuntimeActor private func events(_ name: String, in orchestrator: ProxyOrchestrator) -> [RuntimeEvent] {
        orchestrator.eventLog.events.filter { $0.event == name }
    }

    @RuntimeActor private func transportResets(_ orchestrator: ProxyOrchestrator) -> [String] {
        events("dns.transports_reset", in: orchestrator).compactMap(\.detail)
    }

    nonisolated private static func squat(on port: Int) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port)
            .get()
    }

    @RuntimeActor private func loseAndRecycle(_ orchestrator: ProxyOrchestrator) async throws -> (old: Int, squatter: Channel) {
        let old = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort, "the start published its listener")
        await orchestrator.localProxyServer.simulateListenerLossForTesting()
        let squatter = try await Self.squat(on: old)
        try await orchestrator.localProxyServer.recycleListener()
        return (old, squatter)
    }

    @RuntimeActor func testAnEphemeralRecycleIsPublishedInTheSnapshot() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        let (old, squatter) = try await loseAndRecycle(orchestrator)
        defer { Task { @RuntimeActor in _ = try? await squatter.close().get(); await orchestrator.stopProxy() } }

        let recycled = try XCTUnwrap(events("proxy.listener_recycled", in: orchestrator).last?.detail, "the recycle is on the event stream")
        let port = try XCTUnwrap(orchestrator.localProxyServer.listeningPort)
        XCTAssertEqual(recycled, "listener=127.0.0.1:\(port) configured_port=0")
        XCTAssertEqual(orchestrator.snapshot.bindings.proxyPort, port, "the snapshot names the live binding when the recycle returns")
        XCTAssertNotEqual(port, old)
    }

    @RuntimeActor func testARecycleThatLostItsLifecyclePublishesNothing() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        let stamp = orchestrator.localProxyServer.listenerStamp
        await orchestrator.localProxyServer.simulateListenerLossForTesting()
        await orchestrator.stopProxy()

        do {
            try await orchestrator.localProxyServer.recycleListener(expecting: stamp)
            XCTFail("a recycle under a stopped lifecycle must be refused")
        } catch is CancellationError {}
        XCTAssertNil(orchestrator.snapshot.bindings.proxyPort, "the stop's clear stands")
        XCTAssertEqual(events("proxy.listener_recycled", in: orchestrator).count, 0)
    }

    @RuntimeActor func testTheDoHRouteFollowsAMovedEphemeralListener() async throws {
        let orchestrator = makeOrchestrator(dns: true)
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")
        XCTAssertEqual(orchestrator.dnsForwarder.doHLocalProxyPort, orchestrator.snapshot.bindings.proxyPort, "DNS started beside the listener")
        let (old, squatter) = try await loseAndRecycle(orchestrator)
        defer { Task { @RuntimeActor in _ = try? await squatter.close().get(); await orchestrator.stopDNS(); await orchestrator.stopProxy() } }

        XCTAssertEqual(transportResets(orchestrator).filter { $0 == "source=listener_rebound" }.count, 1,
                       "the DoH route is rebuilt once for the moved listener: \(transportResets(orchestrator))")
        let port = try XCTUnwrap(orchestrator.localProxyServer.listeningPort)
        XCTAssertNotEqual(port, old)
        XCTAssertEqual(orchestrator.dnsForwarder.doHLocalProxyPort, port, "the forwarder's local-proxy route dials the rebound listener")
    }

    @RuntimeActor func testAFixedPortNeverResetsTheDoHRouteForTheListener() async throws {
        let orchestrator = makeOrchestrator(port: try reserveLoopbackPort(), dns: true)
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")
        defer { Task { @RuntimeActor in await orchestrator.stopDNS(); await orchestrator.stopProxy() } }

        await orchestrator.stopProxy()
        try await orchestrator.startProxy()
        await orchestrator.localProxyServer.simulateListenerLossForTesting()
        try await orchestrator.localProxyServer.recycleListener()

        XCTAssertEqual(events("proxy.listener_recycled", in: orchestrator).count, 1, "the recycle ran")
        XCTAssertEqual(transportResets(orchestrator).filter { $0 == "source=proxy_started" || $0 == "source=listener_rebound" }, [],
                       "a fixed port never moves the DoH route")
        XCTAssertEqual(orchestrator.dnsForwarder.doHLocalProxyPort, orchestrator.snapshot.bindings.proxyPort, "and keeps dialling it")
    }

    @RuntimeActor func testAPortZeroStartWhileDNSRunsRebuildsTheRoute() async throws {
        let orchestrator = makeOrchestrator(dns: true)
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")
        defer { Task { @RuntimeActor in await orchestrator.stopDNS(); await orchestrator.stopProxy() } }
        XCTAssertNil(orchestrator.dnsForwarder.doHLocalProxyPort, "no listener, no local-proxy route")

        try await orchestrator.startProxy()

        XCTAssertEqual(transportResets(orchestrator), ["source=proxy_started"], "the route DNS was built without now has a port")
        XCTAssertEqual(orchestrator.dnsForwarder.doHLocalProxyPort, orchestrator.snapshot.bindings.proxyPort)
    }

    @RuntimeActor func testTheServedPACScriptNamesTheReboundListener() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.dnsForwarderEnabled = false
        config.localPACEnabled = true
        config.localPACPort = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        let pacPort = try XCTUnwrap(orchestrator.snapshot.bindings.localPACPort, "the local PAC server is up")
        let (old, squatter) = try await loseAndRecycle(orchestrator)
        defer { Task { @RuntimeActor in _ = try? await squatter.close().get(); await orchestrator.stopProxy() } }
        let port = try XCTUnwrap(orchestrator.localProxyServer.listeningPort)

        let script = try await Self.fetchServedPAC(port: pacPort)

        XCTAssertEqual(events("local_pac.updated", in: orchestrator).map(\.detail), ["reason=listener_rebound"])
        XCTAssertTrue(script.contains("127.0.0.1:\(port)"), "the script names the rebound listener: \(script)")
        XCTAssertFalse(script.contains("127.0.0.1:\(old)"), "and not the port the squatter holds")
    }

    /// A direct fetch: the session's proxy dictionary is set empty, so the machine's system proxy is not consulted.
    nonisolated private static func fetchServedPAC(port: Int) async throws -> String {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        let url = try XCTUnwrap(URL(string: "http://127.0.0.1:\(port)\(LocalPACServer.pacPath)"))
        let (data, _) = try await URLSession(configuration: configuration).data(from: url)
        return String(decoding: data, as: UTF8.self)
    }
}
