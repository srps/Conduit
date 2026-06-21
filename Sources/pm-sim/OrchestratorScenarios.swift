// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import ProxyKernel

enum OrchestratorScenarios {

    // MARK: - Health check through the real LocalProxyServer + ConnectionPool.exchange path

    @MainActor
    static func healthCheck(verbose: Bool) async throws -> ScenarioResult {
        let name = "healthCheck(HEAD via upstream)"
        let harness = SimHarness(verbose: verbose)
        try await harness.start(
            originBehavior: .silent  // Not used -- health check goes via plain HTTP, not CONNECT.
        )
        defer { Task { @MainActor in await harness.stop() } }

        let start = Date()
        var notes: [String] = []

        // 5 health checks in a row to simulate steady-state polling.
        var successes = 0
        var latencies: [Int] = []
        for i in 0..<5 {
            guard let server = harness.server else { break }
            let result = await server.performHealthCheck()
            latencies.append(result.responseTimeMS)
            if result.healthy { successes += 1 }
            notes.append("#\(i) healthy=\(result.healthy) ms=\(result.responseTimeMS) upstream=\(result.activeUpstream ?? "-")")
        }

        let elapsed = Date().timeIntervalSince(start)
        let totalLatency = latencies.reduce(0, +)
        return ScenarioResult(
            name: name,
            clientCount: 5,
            clientsOpened: successes,
            clientsWithFirstByte: successes,
            clientsClosedEarly: 5 - successes,
            totalBytes: totalLatency,
            durationSeconds: elapsed,
            aggregateMBps: 0,
            minBytes: latencies.min() ?? 0,
            maxBytes: latencies.max() ?? 0,
            medianBytes: latencies.sorted()[latencies.count / 2],
            earliestClose: nil,
            latestClose: nil,
            notes: notes
        )
    }

    // MARK: - Upstream failover: first upstream dies, `switchToNextUpstream` + reconnect works.

    @MainActor
    static func upstreamFailover(verbose: Bool) async throws -> ScenarioResult {
        let name = "upstreamFailover"
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let origin = FakeOrigin(group: group, behavior: .burstStream(intervalMs: 50, chunkSize: 4096, durationMs: 8000))
        try await origin.start()

        // Two upstream proxies, both routing to the same origin.
        let upstream1 = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port)
        try await upstream1.start()
        let upstream2 = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port)
        try await upstream2.start()

        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.proxy.maxConnections = 64
        config.proxy.inboundConnectionMaxLimit = 2048
        config.proxy.inboundConnectionWarnThreshold = 2048
        config.routing.pacRoutingEnabled = false
        config.auth.mode = .systemNegotiated
        config.upstreams = [
            UpstreamProxy(name: "Upstream1", host: "127.0.0.1", port: upstream1.port, priority: 0),
            UpstreamProxy(name: "Upstream2", host: "127.0.0.1", port: upstream2.port, priority: 1)
        ]

        let detector = DirectConnectDetector(group: group, logger: logger)
        let capturedConfig = config
        let server = LocalProxyServer(
            logger: logger,
            configProvider: { capturedConfig },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in MockAuthenticator() },
            directConnectDetector: detector,
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onConnectionActivity: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        defer {
            Task { @MainActor in
                await server.stop()
                await upstream1.stop()
                await upstream2.stop()
                await origin.stop()
            }
        }

        var notes: [String] = []
        let start = Date()

        // 1. Baseline: active upstream is Upstream1 initially.
        let before = server.activeUpstream() ?? "-"
        notes.append("initial=\(before)")

        // 2. Kill upstream1. The next health check / request should trigger failover.
        await upstream1.stop()
        notes.append("upstream1.stopped at \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

        // 3. Force a health check. It should fail or indicate unhealthy.
        let hc1 = await server.performHealthCheck()
        notes.append("hc1 healthy=\(hc1.healthy) summary=\(hc1.summary)")

        // 4. Invoke switchToNextUpstream (simulating auto-recovery step).
        let switched = (try? await server.switchToNextUpstream()) ?? nil
        notes.append("switched to=\(switched ?? "-")")

        // 5. Second health check should go through Upstream2.
        let hc2 = await server.performHealthCheck()
        notes.append("hc2 healthy=\(hc2.healthy) summary=\(hc2.summary) via=\(hc2.activeUpstream ?? "-")")

        let elapsed = Date().timeIntervalSince(start)
        let success = hc2.healthy ? 1 : 0
        return ScenarioResult(
            name: name,
            clientCount: 2,
            clientsOpened: 2,
            clientsWithFirstByte: 2,
            clientsClosedEarly: success == 1 ? 0 : 1,
            totalBytes: 0,
            durationSeconds: elapsed,
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: notes
        )
    }

    // MARK: - Connect-failure log severity gating.

    /// Drives `LocalProxyServer` through two failure shapes and asserts that the
    /// `DirectModeCause`-driven log severity gating works end-to-end:
    ///
    ///   * **Run 1 — silenced direct-connect failure under `.vpnDisconnected`.**
    ///     Empty upstreams, `directModeProvider = (true, .vpnDisconnected)`,
    ///     CONNECT to an RFC 5737 black-hole address. Because
    ///     `.vpnDisconnected.routesClientTrafficDirectly` is `true`, the
    ///     handler attempts a direct connect, which fails. The failure must
    ///     log at `.info` (silenced) per `directFailureLogLevel(for:)` —
    ///     the user intentionally turned off the VPN; loud errors here
    ///     would be noise.
    ///   * **Run 2 — loud upstream failure under `.upstreamsUnreachable`.**
    ///     One configured upstream pointing at an RFC 5737 black-hole,
    ///     `directModeProvider = (true, .upstreamsUnreachable)`, CONNECT to
    ///     a real-looking target. Because
    ///     `.upstreamsUnreachable.routesClientTrafficDirectly` is `false`
    ///     (post-`c376eb1` design — VPN-connected degraded states keep
    ///     PAC/upstream routing for strict corporate profiles), the handler
    ///     attempts the upstream tunnel, which fails. The failure must log
    ///     at `.error` (loud) per `upstreamFailureLogLevel(for:)`.
    ///
    /// Pre-`c376eb1` this scenario tried to drive Run 2 through the same
    /// direct-connect path as Run 1 by lying to `directModeProvider`.
    /// That stopped working when the routing model split `isDirect` from
    /// `routesClientTrafficDirectly`: `.upstreamsUnreachable` no longer
    /// drives direct connects at all, so the "Direct connect failed" line
    /// the test was searching for never fired. The fix is to test the
    /// path that's actually emitted under the unexpected cause —
    /// upstream-failure logging — instead of forcing a counterfactual
    /// direct-connect.
    @MainActor
    static func directModeSilence(verbose: Bool) async throws -> ScenarioResult {
        let name = "directModeSilence(VPN-off vs upstreams-unreachable)"
        let group = MultiThreadedEventLoopGroup.singleton
        var notes: [String] = []
        let start = Date()

        // Capture every log entry at .info or above so we can scan for severity.
        // pm-sim no longer constructs AppLogStore (app target only); the
        // RecordingLogSink kernel-side stock impl gives us the same in-memory
        // capture without the @MainActor / Combine machinery.
        let expectedLogger = RecordingLogSink(minLevel: .info)
        let unexpectedLogger = RecordingLogSink(minLevel: .info)

        // RFC 5737 reserved for documentation; TCP SYN reliably fails without
        // depending on local network state and resolves through .connectTimeout
        // within a few seconds. Same address used for both runs to keep the
        // failure-shape comparison clean.
        let unreachableHost = "192.0.2.1"
        let unreachablePort = 9999

        // Run #1: cause = .vpnDisconnected (expected) + empty upstreams →
        // direct-connect attempted → "Direct connect ... failed" must be .info.
        var directOnlyConfig = ProxyConfig()
        directOnlyConfig.proxy.host = "127.0.0.1"
        directOnlyConfig.proxy.port = 0
        directOnlyConfig.routing.pacRoutingEnabled = false
        directOnlyConfig.upstreams = []  // forces the direct path under the (true, .vpnDisconnected) gate
        let infoResult = try await runFailureLogProbe(
            cause: .vpnDisconnected,
            logger: expectedLogger,
            config: directOnlyConfig,
            group: group,
            target: "\(unreachableHost):\(unreachablePort)",
            messageMatch: { $0.contains("Direct connect") && $0.contains("failed") }
        )
        notes.append("expected(VPN off): direct-failure logged at \(infoResult.severityLabel)")

        // Run #2: cause = .upstreamsUnreachable (unexpected) + one configured
        // upstream pointing at the black-hole → upstream tunnel attempted →
        // "CONNECT tunnel failed" must be .error. Cannot reuse the direct-
        // connect path here: post-c376eb1, .upstreamsUnreachable does not
        // route client traffic directly even when directModeProvider says
        // isDirect = true. The relevant loud log surfaces on the upstream-
        // failure path instead.
        var upstreamFailingConfig = ProxyConfig()
        upstreamFailingConfig.proxy.host = "127.0.0.1"
        upstreamFailingConfig.proxy.port = 0
        upstreamFailingConfig.routing.pacRoutingEnabled = false
        upstreamFailingConfig.upstreams = [
            UpstreamProxy(
                name: "BlackHoleUpstream",
                host: unreachableHost,
                port: unreachablePort,
                priority: 0
            )
        ]
        let errorResult = try await runFailureLogProbe(
            cause: .upstreamsUnreachable,
            logger: unexpectedLogger,
            config: upstreamFailingConfig,
            group: group,
            target: "example.invalid:443",
            messageMatch: { $0.contains("CONNECT tunnel failed") }
        )
        notes.append("unexpected(upstreams unreachable): upstream-failure logged at \(errorResult.severityLabel)")

        let pass = infoResult.severity == .info && errorResult.severity == .error
        notes.append(pass ? "PASS" : "FAIL")

        return ScenarioResult(
            name: name,
            clientCount: 2,
            clientsOpened: 2,
            clientsWithFirstByte: 0,
            clientsClosedEarly: 2,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: notes
        )
    }

    /// Generalised log-severity probe used by `directModeSilence`. Spins up a
    /// `LocalProxyServer` with the supplied fixed direct-mode cause + config,
    /// sends one CONNECT to `target`, polls the recording logger for a line
    /// matching `messageMatch`, and reports the line's severity (or
    /// `<no log line found>` if the poll exhausts).
    ///
    /// `messageMatch` is a closure rather than a single substring so each
    /// caller can describe the precise log shape its code path emits
    /// ("Direct connect ... failed" vs "CONNECT tunnel failed") without
    /// each path having to share an artificial common prefix.
    @MainActor
    private static func runFailureLogProbe(
        cause: DirectModeCause,
        logger: RecordingLogSink,
        config: ProxyConfig,
        group: EventLoopGroup,
        target: String,
        messageMatch: @Sendable @escaping (String) -> Bool
    ) async throws -> FailureLogProbeResult {
        let detector = DirectConnectDetector(group: group, logger: logger)
        let server = LocalProxyServer(
            logger: logger,
            configProvider: { config },
            directModeProvider: { (true, cause) },
            authenticatorProvider: { _ in MockAuthenticator() },
            directConnectDetector: detector,
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onConnectionActivity: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        defer { Task { @MainActor in await server.stop() } }

        guard let port = server.listeningPort else {
            throw NSError(domain: "directModeSilence", code: 1)
        }

        // Issue a CONNECT through the proxy. Whether it lands on the direct
        // path or the upstream path is determined by the cause + config combo
        // the caller supplied; the probe only cares about the severity of the
        // resulting failure log.
        let client = FakeClient(
            id: 0,
            group: group,
            localProxyHost: "127.0.0.1",
            localProxyPort: port,
            target: target,
            behavior: .sendOnceThenListen(requestBytes: 32)
        )
        try await client.run()

        // Wait for the failure to materialize and the log to flush. The 10s
        // connect timeout in handleDirectConnect plus the bridge() task hop
        // means we need to poll the entries buffer for a few seconds. Cap at
        // 15 s to avoid hanging pm-sim if the underlying behavior changes.
        var lastMatchingLine: LogEntry?
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if let entry = logger.entries().last(where: { messageMatch($0.message) && $0.message.lowercased().contains("fail") }) {
                lastMatchingLine = entry
                break
            }
        }
        await client.close()

        guard let line = lastMatchingLine else {
            return FailureLogProbeResult(severity: .debug, severityLabel: "<no log line found>")
        }
        return FailureLogProbeResult(severity: line.level, severityLabel: line.level.rawValue)
    }

    private struct FailureLogProbeResult {
        let severity: LogLevel
        let severityLabel: String
    }

    // MARK: - Keepalive readback: verify OS accepted the options on a dedicated client socket.

    @MainActor
    static func keepaliveReadback(verbose: Bool) async throws -> ScenarioResult {
        let name = "keepaliveReadback"
        let group = MultiThreadedEventLoopGroup.singleton

        let origin = FakeOrigin(group: group, behavior: .silent)
        try await origin.start()
        defer { Task { @MainActor in await origin.stop() } }

        let keepalive = TCPKeepaliveConfig.default

        let start = Date()
        let channel = try await ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepIdle), value: CInt(keepalive.keepIdleSeconds))
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepInterval), value: CInt(keepalive.keepIntervalSeconds))
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepCount), value: CInt(keepalive.keepCountProbes))
            .connect(host: "127.0.0.1", port: origin.port).get()

        let soKeep = try await channel.getOption(ChannelOptions.socketOption(.so_keepalive)).get()
        let idleVal = try await channel.getOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepIdle)).get()
        let intvlVal = try await channel.getOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepInterval)).get()
        let cntVal = try await channel.getOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepCount)).get()
        try await channel.close().get()

        let elapsed = Date().timeIntervalSince(start)

        // On Darwin, getsockopt(SO_KEEPALIVE) returns a non-zero value when enabled but not always
        // literal 1 (the kernel may return the option name's raw value). Any non-zero is "enabled".
        let pass =
            soKeep != 0 &&
            Int(idleVal) == keepalive.keepIdleSeconds &&
            Int(intvlVal) == keepalive.keepIntervalSeconds &&
            Int(cntVal) == keepalive.keepCountProbes

        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: 1,
            clientsWithFirstByte: 1,
            clientsClosedEarly: pass ? 0 : 1,
            totalBytes: 0,
            durationSeconds: elapsed,
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            notes: [
                "SO_KEEPALIVE=\(soKeep)",
                "TCP_KEEPALIVE(idle)=\(idleVal)s (expected \(keepalive.keepIdleSeconds))",
                "TCP_KEEPINTVL=\(intvlVal)s (expected \(keepalive.keepIntervalSeconds))",
                "TCP_KEEPCNT=\(cntVal) (expected \(keepalive.keepCountProbes))",
                pass ? "PASS" : "FAIL"
            ]
        )
    }
}
