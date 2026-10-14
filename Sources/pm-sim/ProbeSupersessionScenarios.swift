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

    /// Forwards to `base`, and calls `onListening` once when the listener
    /// logs that it is up: after the start probe committed, before startup
    /// reports running.
    private final class ListeningHook: LogSink, @unchecked Sendable {
        private let base: any LogSink
        private let fired = NIOLockedValueBox(false)
        private let onListening: @Sendable () -> Void
        init(base: any LogSink, _ onListening: @escaping @Sendable () -> Void) { self.base = base; self.onListening = onListening }
        var minLevel: LogLevel { .debug }
        func flush(timeout: TimeInterval) -> Bool { base.flush(timeout: timeout) }
        func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
            base.log(level, message, category: category)
            if message.hasPrefix("Local proxy listening on"), !fired.withLockedValue({ let was = $0; $0 = true; return was }) {
                onListening()
            }
        }
    }

    /// #155: a reconnect that lands after startup's connectivity verdict,
    /// while the listener binds, finds the listener not yet running. Startup
    /// decides again before it reports running, so the first CONNECT goes
    /// through the upstream instead of the off-VPN DIRECT verdict.
    @MainActor
    static func startupRederive(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let probe = HeldProbe()
        probe.set(reachable: false)
        let box = NIOLockedValueBox<ProxyOrchestrator?>(nil)
        let logger = ListeningHook(base: ConsoleLogSink(minLevel: verbose ? .debug : .warning)) {
            guard let orchestrator = box.withLockedValue({ $0 }) else { return }
            probe.set(reachable: true)
            Task { @MainActor in await orchestrator.handleVPNStateChange(.connected) }
        }
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
                                             connectivityProbe: { await probe.probe($0) })
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        box.withLockedValue { $0 = orchestrator }
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }

        let cause = orchestrator.snapshot.directModeCause
        let rederived = orchestrator.eventLog.events.filter { $0.event == "connectivity.startup_rederived" }.compactMap(\.detail)
        let port = orchestrator.snapshot.bindings.proxyPort!
        let client = FakeClient(id: 0, group: group, localProxyHost: "127.0.0.1", localProxyPort: port,
            target: "rederive.test:443", behavior: .periodicPing(requestBytes: 16, pingIntervalMs: 250, pingBytes: 16))
        ScenarioCleanup.register { await client.close() }
        try await client.run()
        let echoed = try await until(timeout: 3, { client.metrics.bytesReceived > 0 })
        let metrics = client.metrics
        return ScenarioResult(name: "vpn-startup-rederive", clientCount: 1, clientsOpened: 1,
            clientsWithFirstByte: metrics.firstByteAt == nil ? 0 : 1, clientsClosedEarly: metrics.closedAt == nil ? 0 : 1,
            totalBytes: metrics.bytesReceived, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: metrics.bytesReceived, maxBytes: metrics.bytesReceived, medianBytes: metrics.bytesReceived,
            earliestClose: nil, latestClose: nil, assertions: [
                .init("the reconnect during listener start re-derives routing once", rederived == ["attempt=1 vpn=connected"]),
                .init("startup reports the upstream route, not the stale DIRECT verdict",
                      cause == .none && orchestrator.snapshot.runtimeStatus.activeUpstream != "DIRECT"),
                .init("the first CONNECT goes through the upstream", echoed && upstream.connectCount == 1),
            ], notes: ["Injected probe outcomes; the reconnect is delivered when the listener logs that it is up"])
    }
}
