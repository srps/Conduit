// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel

enum ReconnectReprobeScenarios {
    private struct ProbeState { var reachable = true; var attempts = 0 }

    @RuntimeActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// Only probe reachability is injected. The production timer, orchestrator,
    /// pool and established CONNECT pipeline own the actual sockets under test.
    @RuntimeActor
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
        func tunnel(_ id: Int) async throws -> FakeClient {
            let client = FakeClient(id: id, group: group, localProxyHost: "127.0.0.1", localProxyPort: port,
                target: "reprobe.test:443", behavior: .periodicPing(requestBytes: 16, pingIntervalMs: 250, pingBytes: 16))
            ScenarioCleanup.register { await client.close() }
            try await client.run()
            guard try await until(timeout: 3, { client.metrics.bytesReceived > 0 }) else {
                throw ScenarioExecutionError(message: "established CONNECT never echoed")
            }
            return client
        }
        // A confirmed disconnect that routes DIRECT retires the upstream
        // tunnel at once (#148): it left with the VPN and cannot resume.
        let onVPN = try await tunnel(0)
        state.withLockedValue { $0.reachable = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let migratedOnDisconnect = try await until(timeout: 2, { onVPN.metrics.closedAt != nil })
        let migration = orchestrator.eventLog.events.last {
            $0.event == "vpn.tunnels_migrated" && ($0.detail?.contains("phase=routing") ?? false)
        }
        await orchestrator.handleVPNStateChange(.connected)
        let degraded = orchestrator.snapshot.directModeCause
        let attempts = state.withLockedValue { $0.attempts }
        let connectedEvents = orchestrator.eventLog.events.filter { $0.event == "vpn.connected" }.count
        // A tunnel opened on the reconnected VPN, while the reprobe still
        // fails, must ride out the production retry.
        let client = try await tunnel(1)
        let before = client.metrics.bytesReceived
        state.withLockedValue { $0.reachable = true }
        let recovered = try await until(timeout: 22) {
            orchestrator.snapshot.directModeCause == .none && orchestrator.eventLog.events.contains {
                $0.event == "connectivity.reprobe_completed" && $0.detail?.contains("reachable=true cause=none") == true
            }
        }
        let metrics = client.metrics
        let retried = state.withLockedValue { $0.attempts } > attempts
        let sameVPNReport = connectedEvents == orchestrator.eventLog.events.filter { $0.event == "vpn.connected" }.count
        return ScenarioResult(name: "vpn-reconnect-reprobe", clientCount: 2, clientsOpened: 2,
            clientsWithFirstByte: metrics.firstByteAt == nil ? 0 : 1, clientsClosedEarly: metrics.closedAt == nil ? 0 : 1,
            totalBytes: metrics.bytesReceived, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: metrics.bytesReceived, maxBytes: metrics.bytesReceived, medianBytes: metrics.bytesReceived,
            earliestClose: nil, latestClose: nil, assertions: [
                .init("a DIRECT-routing disconnect closes the upstream tunnel with one migration event",
                      migratedOnDisconnect && migration?.detail?.contains("phase=routing reason=user routing=direct upstream_closed=") == true
                          && migration?.detail?.hasSuffix(" upstream_closed=0") == false),
                .init("failed first probe degrades health without allowing strict DIRECT", degraded == .upstreamsUnreachable && !degraded.routesClientTrafficDirectly),
                .init("production retry restores reachable state without another VPN report", recovered && retried && sameVPNReport),
                .init("a CONNECT opened on the reconnected VPN keeps exchanging bytes on the same listener", metrics.closedAt == nil && metrics.bytesReceived > before && orchestrator.snapshot.bindings.proxyPort == port),
            ], notes: ["Real 15-second retry cadence; injected probe outcomes; no real VPN, helper, settings or credentials",
                       "migration: \(migration?.detail ?? "none")"])
    }
}
