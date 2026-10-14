// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel

/// #155: a disconnect's probe that is still pending when the VPN reconnects
/// must not turn routing DIRECT, or sweep, on its stale "unreachable" verdict.
enum ProbeSupersessionScenarios {
    /// Probe outcomes are injected and the disconnect's probe is held; the
    /// orchestrator, pool, listener and CONNECT tunnels are the real ones.
    private final class HeldProbe: @unchecked Sendable {
        private let lock = NIOLock()
        private var reachable = true
        private var holdNext = false
        private var parked: CheckedContinuation<Void, Never>?

        func set(reachable: Bool, holdNext: Bool = false) {
            lock.withLockVoid { self.reachable = reachable; self.holdNext = holdNext }
        }

        var isParked: Bool { lock.withLock { parked != nil } }

        func probe(_ targets: [UpstreamProxy]) async -> UpstreamProbeSummary {
            let (verdict, hold) = lock.withLock { () -> (Bool, Bool) in
                defer { holdNext = false }
                return (reachable, holdNext)
            }
            if hold { await withCheckedContinuation { continuation in lock.withLockVoid { parked = continuation } } }
            return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: verdict) })
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { parked = nil }; return parked }
            continuation?.resume()
        }
    }

    @MainActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @MainActor
    static func staleDisconnectProbe(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let probe = HeldProbe()
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
                                             connectivityProbe: { await probe.probe($0) })
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        await orchestrator.handleVPNStateChange(.connected)
        let port = orchestrator.snapshot.bindings.proxyPort!
        func tunnel(_ id: Int) async throws -> FakeClient {
            let client = FakeClient(id: id, group: group, localProxyHost: "127.0.0.1", localProxyPort: port,
                target: "superseded.test:443", behavior: .periodicPing(requestBytes: 16, pingIntervalMs: 250, pingBytes: 16))
            ScenarioCleanup.register { await client.close() }
            try await client.run()
            guard try await until(timeout: 3, { client.metrics.bytesReceived > 0 }) else {
                throw ScenarioExecutionError(message: "CONNECT \(id) never echoed")
            }
            return client
        }

        // Disconnect: its probe sees the upstream unreachable and is held.
        probe.set(reachable: false, holdNext: true)
        let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        guard try await until(timeout: 3, { probe.isParked }) else {
            throw ScenarioExecutionError(message: "the disconnect probe never ran")
        }
        // Reconnect before it returns; the upstream answers again.
        probe.set(reachable: true)
        await orchestrator.handleVPNStateChange(.connected)
        let afterReconnect = try await tunnel(1)
        let connectsBefore = upstream.connectCount
        probe.release()
        await disconnect.value

        let cause = orchestrator.snapshot.directModeCause
        let before = afterReconnect.metrics.bytesReceived
        let keptExchanging = try await until(timeout: 2, { afterReconnect.metrics.bytesReceived > before })
        let fresh = try await tunnel(2)
        let freshViaUpstream = upstream.connectCount > connectsBefore
        let superseded = orchestrator.eventLog.events.filter { $0.event == "connectivity.probe_superseded" }.compactMap(\.detail)
        let routing = orchestrator.eventLog.events.filter {
            $0.event == "vpn.tunnels_migrated" && $0.detail?.contains("phase=routing") == true
        }.compactMap(\.detail)
        let metrics = afterReconnect.metrics
        return ScenarioResult(name: "vpn-probe-superseded", clientCount: 2, clientsOpened: 2,
            clientsWithFirstByte: metrics.firstByteAt == nil ? 0 : 1, clientsClosedEarly: metrics.closedAt == nil ? 0 : 1,
            totalBytes: metrics.bytesReceived + fresh.metrics.bytesReceived, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: metrics.bytesReceived, maxBytes: metrics.bytesReceived, medianBytes: metrics.bytesReceived,
            earliestClose: nil, latestClose: nil, assertions: [
                .init("the stale disconnect probe is dropped as superseded by the reconnect",
                      superseded == ["by=transition probed_vpn=disconnected current_vpn=connected reachable=false"]),
                .init("routing stays on the upstream after the stale result lands", cause == .none
                          && orchestrator.snapshot.runtimeStatus.activeUpstream != "DIRECT"),
                .init("the stale handler sweeps nothing", routing == ["transition=disconnected phase=routing reason=user skipped=superseded"]),
                .init("a tunnel opened after the reconnect keeps exchanging bytes", keptExchanging && metrics.closedAt == nil),
                .init("a fresh CONNECT goes through the upstream", freshViaUpstream && fresh.metrics.bytesReceived > 0),
            ], notes: ["Injected probe outcomes with the disconnect probe held; real listener, pool and upstream CONNECT tunnels"])
    }
}
