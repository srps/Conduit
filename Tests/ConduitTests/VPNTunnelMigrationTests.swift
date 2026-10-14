// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

/// #148, #156: the order of a confirmed disconnect's two migration phases.
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
        XCTAssertEqual(after.last, "transition=disconnected phase=routing reason=user routing=direct upstream_closed=0")
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
        XCTAssertFalse(orchestrator.transitions.stamp().whileVPNDown)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)
        XCTAssertTrue(orchestrator.transitions.stamp().whileVPNDown)

        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertFalse(orchestrator.transitions.stamp().whileVPNDown)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=reconnected route=direct closed=0 untracked=0")
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
        try orchestrator.transitions.register(offVPN, route: .direct, stamp: orchestrator.transitions.stamp(), target: "origin.test:443")
        await orchestrator.stopProxy(scope: .allButDedicated)

        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertFalse(offVPN.isActive)
        XCTAssertFalse(orchestrator.transitions.stamp().whileVPNDown)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=reconnected route=direct closed=1 untracked=0")
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
                       "transition=disconnected phase=routing reason=lost routing=upstream upstream_closed=0")
        await orchestrator.stopProxy()
    }

    /// A disconnect while the listener is stopped still closes stranded
    /// sockets at once, and its routing phase runs once the start probe
    /// decides routing: an upstream tunnel the restart preserved would stall
    /// on proxies behind the gone VPN (#156).
    func testADisconnectWithTheListenerStoppedRoutesOnceTheStartProbeDecides() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        let preserved = EmbeddedChannel()
        try await preserved.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: 3128)).get()
        try orchestrator.transitions.register(preserved, route: .upstream, stamp: orchestrator.transitions.stamp(), target: "origin.test:443")
        await orchestrator.stopProxy(scope: .allButDedicated)
        reachable.withLockedValue { $0 = false }

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        XCTAssertTrue(orchestrator.transitions.stamp().whileVPNDown, "the outage began with the listener stopped")
        XCTAssertTrue(migrations(orchestrator.eventLog.events).last?.hasPrefix("transition=disconnected phase=addresses reason=user ") ?? false)
        XCTAssertTrue(preserved.isActive, "routing is not decided yet")

        try await orchestrator.startProxy()

        XCTAssertFalse(preserved.isActive)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=disconnected phase=routing reason=user routing=direct upstream_closed=1")
        await orchestrator.stopProxy()
    }

    /// Calls `onListening` when the listener logs that it is up: after the
    /// start probe committed, before startup reports running.
    private final class ListeningHook: LogSink, @unchecked Sendable {
        let onListening: @Sendable () -> Void
        init(_ onListening: @escaping @Sendable () -> Void) { self.onListening = onListening }
        var minLevel: LogLevel { .debug }
        func flush(timeout: TimeInterval) -> Bool { true }
        func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
            if message.hasPrefix("Local proxy listening on") { onListening() }
        }
    }

    /// A disconnect that lands after the start probe committed (while the
    /// listener binds) made that verdict stale; startup decides again and
    /// runs the routing phase before it reports running.
    func testADisconnectAfterTheStartProbeIsRoutedBeforeRunning() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let box = NIOLockedValueBox<ProxyOrchestrator?>(nil)
        let hook = ListeningHook {
            guard let orchestrator = box.withLockedValue({ $0 }) else { return }
            reachable.withLockedValue { $0 = false }
            Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        }
        let orchestrator = ProxyOrchestrator(config: config, logger: hook,
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        await orchestrator.handleVPNStateChange(.connected)
        let preserved = EmbeddedChannel()
        try await preserved.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: 3128)).get()
        try orchestrator.transitions.register(preserved, route: .upstream, stamp: orchestrator.transitions.stamp(), target: "origin.test:443")
        box.withLockedValue { $0 = orchestrator }

        try await orchestrator.startProxy()

        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .userInitiated), "the disconnect landed during startup")
        XCTAssertTrue(orchestrator.snapshot.directModeCause.routesClientTrafficDirectly)
        XCTAssertFalse(preserved.isActive, "the deferred routing phase ran before .running")
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=disconnected phase=routing reason=user routing=direct upstream_closed=1")
        await orchestrator.stopProxy()
    }
}
