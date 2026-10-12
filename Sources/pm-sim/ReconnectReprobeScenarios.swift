// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel

enum ReconnectReprobeScenarios {
    private struct ProbeState { var reachable = true; var attempts = 0 }

    @MainActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// Only probe reachability is injected. The production timer, orchestrator,
    /// pool and established CONNECT pipeline own the actual sockets under test.
    @MainActor
    static func failedFirstProbe(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.strictMode = true; config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "recovering", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let state = NIOLockedValueBox(ProbeState())
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let reachable = state.withLockedValue { value in value.attempts += 1; return value.reachable }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: reachable) })
            })
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        await orchestrator.handleVPNStateChange(.connected)
        let port = orchestrator.snapshot.bindings.proxyPort!
        let client = FakeClient(id: 0, group: group, localProxyHost: "127.0.0.1", localProxyPort: port,
            target: "reprobe.test:443", behavior: .periodicPing(requestBytes: 16, pingIntervalMs: 250, pingBytes: 16))
        ScenarioCleanup.register { await client.close() }
        try await client.run()
        guard try await until(timeout: 3, { client.metrics.bytesReceived > 0 }) else {
            throw ScenarioExecutionError(message: "established CONNECT never echoed")
        }
        let before = client.metrics.bytesReceived
        state.withLockedValue { $0.reachable = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        await orchestrator.handleVPNStateChange(.connected)
        let degraded = orchestrator.snapshot.directModeCause
        let attempts = state.withLockedValue { $0.attempts }
        let connectedEvents = orchestrator.eventLog.events.filter { $0.event == "vpn.connected" }.count
        state.withLockedValue { $0.reachable = true }
        let recovered = try await until(timeout: 22) {
            orchestrator.snapshot.directModeCause == .none && orchestrator.eventLog.events.contains {
                $0.event == "connectivity.reprobe_completed" && $0.detail?.contains("reachable=true cause=none") == true
            }
        }
        let metrics = client.metrics
        let retried = state.withLockedValue { $0.attempts } > attempts
        let sameVPNReport = connectedEvents == orchestrator.eventLog.events.filter { $0.event == "vpn.connected" }.count
        return ScenarioResult(name: "vpn-reconnect-reprobe", clientCount: 1, clientsOpened: 1,
            clientsWithFirstByte: metrics.firstByteAt == nil ? 0 : 1, clientsClosedEarly: metrics.closedAt == nil ? 0 : 1,
            totalBytes: metrics.bytesReceived, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: metrics.bytesReceived, maxBytes: metrics.bytesReceived, medianBytes: metrics.bytesReceived,
            earliestClose: nil, latestClose: nil, assertions: [
                .init("failed first probe degrades health without allowing strict DIRECT", degraded == .upstreamsUnreachable && !degraded.routesClientTrafficDirectly),
                .init("production retry restores reachable state without another VPN report", recovered && retried && sameVPNReport),
                .init("the established CONNECT keeps exchanging bytes on the same listener", metrics.closedAt == nil && metrics.bytesReceived > before && orchestrator.snapshot.bindings.proxyPort == port),
            ], notes: ["Real 15-second retry cadence; injected probe outcomes; no real VPN, helper, settings or credentials"])
    }
}
