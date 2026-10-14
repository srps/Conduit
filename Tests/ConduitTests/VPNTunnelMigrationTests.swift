// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

/// #148: the order of a confirmed disconnect's two migration phases.
@MainActor
final class VPNTunnelMigrationTests: XCTestCase {
    private func migrations(_ events: [RuntimeEvent]) -> [String] {
        events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
    }

    /// The address phase must not wait for the connectivity probe: the probe
    /// can take its whole connect budget while stranded sockets stall.
    func testTheAddressPhaseRunsBeforeTheProbeAndTheRoutingPhaseAfterIt() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let log = NIOLockedValueBox<RuntimeEventLog?>(nil)
        let seenByProbe = NIOLockedValueBox<[String]?>(nil)
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                let up = reachable.withLockedValue { $0 }
                if !up, let events = log.withLockedValue({ $0 })?.events {
                    seenByProbe.withLockedValue { $0 = events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail) }
                }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        log.withLockedValue { $0 = orchestrator.eventLog }
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        reachable.withLockedValue { $0 = false }

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        let atProbe = try XCTUnwrap(seenByProbe.withLockedValue { $0 }, "the probe ran")
        XCTAssertEqual(atProbe.count, 1)
        XCTAssertTrue(atProbe[0].hasPrefix("transition=disconnected phase=addresses reason=user "), atProbe[0])
        let after = migrations(orchestrator.eventLog.events)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last, "transition=disconnected phase=routing reason=user routing=direct upstream_closed=0 upstream_late_closed=0")
        await orchestrator.stopProxy()
    }

    /// On-prem, or while the probe is pending, the direct-mode cause is
    /// `.none`, yet DIRECT dials leave on the off-VPN path: the outage is the
    /// VPN state, and the reconnect still sweeps them.
    func testAnOnPremOutageMarksDIRECTDialsAndTheReconnectSweepsThem() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertFalse(orchestrator.directTunnels.beginDial().whileVPNDown)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)
        XCTAssertTrue(orchestrator.directTunnels.beginDial().whileVPNDown)

        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertFalse(orchestrator.directTunnels.beginDial().whileVPNDown)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=reconnected route=direct closed=0 late_closed=0 untracked=0")
        await orchestrator.stopProxy()
    }

    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        var holding: Bool { waiter != nil }
        func open() { waiter?.resume(); waiter = nil }
    }

    /// A reconnect that runs while the disconnect handler waits on its probe
    /// owns routing; the stale handler must not sweep on its old verdict.
    func testADisconnectSupersededDuringItsProbeSkipsTheRoutingSweep() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let holdNextProbe = NIOLockedValueBox(false)
        let gate = Gate()
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                let up = reachable.withLockedValue { $0 }
                if holdNextProbe.withLockedValue({ let hold = $0; $0 = false; return hold }) { await gate.wait() }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        reachable.withLockedValue { $0 = false }
        holdNextProbe.withLockedValue { $0 = true }

        let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        while !(await gate.holding) { try await Task.sleep(for: .milliseconds(5)) }
        reachable.withLockedValue { $0 = true }
        await orchestrator.handleVPNStateChange(.connected)
        await gate.open()
        await disconnect.value

        let routing = migrations(orchestrator.eventLog.events).filter { $0.contains("phase=routing") }
        XCTAssertEqual(routing, ["transition=disconnected phase=routing reason=user skipped=superseded"])
        await orchestrator.stopProxy()
    }

    /// A reconnect while the listener is stopped (a config restart in
    /// flight) still retires the DIRECT tunnels the restart preserved.
    func testAReconnectWithTheListenerStoppedStillSweepsTheOutage() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: false) })
            })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let offVPN = EmbeddedChannel()
        try await offVPN.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: 443)).get()
        XCTAssertEqual(orchestrator.directTunnels.register(offVPN, dial: orchestrator.directTunnels.beginDial()), .tracked)
        await orchestrator.stopProxy(scope: .allButDedicated)

        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertFalse(offVPN.isActive)
        XCTAssertFalse(orchestrator.directTunnels.beginDial().whileVPNDown)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=reconnected route=direct closed=1 late_closed=0 untracked=0")
    }

    /// On-prem: the probe finds the upstream, so the routing phase closes nothing.
    func testAReachableUpstreamKeepsItsChannelsInTheRoutingPhase() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))

        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=disconnected phase=routing reason=lost routing=upstream upstream_closed=0 upstream_late_closed=0")
        await orchestrator.stopProxy()
    }
}
