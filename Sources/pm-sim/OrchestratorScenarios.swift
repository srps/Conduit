// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

enum OrchestratorScenarios {

    // MARK: - Health check through the real LocalProxyServer + ConnectionPool.exchange path

    @MainActor
    static func healthCheck(verbose: Bool) async throws -> ScenarioResult {
        let name = "healthCheck(HEAD via upstream)"
        let harness = SimHarness(verbose: verbose)
        ScenarioCleanup.register { await harness.stop() }
        try await harness.start(
            originBehavior: .silent  // Not used -- health check goes via plain HTTP, not CONNECT.
        )

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
            medianBytes: latencies.sorted().dropFirst(latencies.count / 2).first ?? 0,
            earliestClose: nil,
            latestClose: nil,
            assertions: [.init("all five health checks succeeded", successes == 5)],
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
        ScenarioCleanup.register { await origin.stop() }
        try await origin.start()

        // Two upstream proxies, both routing to the same origin.
        let upstream1 = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port)
        ScenarioCleanup.register { await upstream1.stop() }
        try await upstream1.start()
        let upstream2 = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port)
        ScenarioCleanup.register { await upstream2.stop() }
        try await upstream2.start()

        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.proxy.maxConnections = 64
        config.proxy.inboundConnectionMaxLimit = 2048
        config.proxy.inboundConnectionWarnThreshold = 1024
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
        ScenarioCleanup.register { await server.stop() }
        try await server.start()

        var notes: [String] = []
        let start = Date()

        // 1. Baseline: active upstream is Upstream1 initially.
        let before = server.activeUpstream() ?? "-"
        notes.append("initial=\(before)")

        // 2. Kill upstream1. The next health check / request should trigger failover.
        await upstream1.stop()
        notes.append("upstream1.stopped at \(String(format: "%.2f", Date().timeIntervalSince(start)))s")

        // 3. The pool retries the failed first upstream through the surviving
        // second upstream; a healthy result must name that surviving endpoint.
        let hc1 = await server.performHealthCheck()
        notes.append("hc1 healthy=\(hc1.healthy) summary=\(hc1.summary)")

        // 4. Explicit rotation can now select the dead upstream again because
        // the health check already failed over. The next request must recover.
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
            assertions: [
                .init("initially selects first upstream", before == capturedConfig.upstreams[0].endpoint),
                .init("health check fails over to surviving upstream", hc1.healthy && hc1.activeUpstream == "127.0.0.1:\(upstream2.port)"),
                .init("explicit rotation completes", switched != nil),
                .init("next request recovers through surviving upstream", hc2.healthy && hc2.activeUpstream == "127.0.0.1:\(upstream2.port)")
            ],
            notes: notes
        )
    }

    // MARK: - Connect-failure log severity gating.

    /// Direct-mode silence: a direct connect that fails while the VPN is off
    /// is expected and must stay quiet, an upstream that fails under an
    /// unexpected cause must be loud. "Quiet" and "loud" are measured on the
    /// contract, not on message text: the request is reported failed either
    /// way, a loud failure emits its `*_failed` event and an `.error` line in
    /// the proxy category, a quiet one emits neither (#36).
    ///
    /// Run 2 goes through the upstream path on purpose: since `c376eb1`,
    /// `.upstreamsUnreachable` does not route client traffic directly even
    /// when `directModeProvider` says direct, so the loud line the product
    /// emits under that cause is the upstream failure.
    @MainActor
    static func directModeSilence(verbose: Bool) async throws -> ScenarioResult {
        let name = "directModeSilence(VPN-off vs upstreams-unreachable)"
        let group = MultiThreadedEventLoopGroup.singleton
        var notes: [String] = []
        let start = Date()

        // RFC 5737 reserved for documentation; TCP SYN reliably fails without
        // depending on local network state and resolves through .connectTimeout
        // within a few seconds. Same address used for both runs to keep the
        // failure-shape comparison clean.
        let unreachableHost = "192.0.2.1"
        let unreachablePort = 9999

        // Run #1: cause = .vpnDisconnected (expected) + empty upstreams →
        // direct connect attempted → quiet.
        var directOnlyConfig = ProxyConfig()
        directOnlyConfig.proxy.host = "127.0.0.1"
        directOnlyConfig.proxy.port = 0
        directOnlyConfig.routing.pacRoutingEnabled = false
        directOnlyConfig.upstreams = []  // forces the direct path under the (true, .vpnDisconnected) gate
        let expected = try await runFailureProbe(
            cause: .vpnDisconnected,
            logger: RecordingLogSink(minLevel: .info),
            config: directOnlyConfig,
            group: group,
            target: "\(unreachableHost):\(unreachablePort)"
        )
        let expectedPass = expected.requestFailed && expected.loudProxyLevels.isEmpty && expected.failureEvents.isEmpty
        notes.append("expected(VPN off): \(expected.summary) → \(expectedPass ? "quiet" : "LOUD")")

        // Run #2: cause = .upstreamsUnreachable (unexpected) + one configured
        // upstream pointing at the black hole → upstream tunnel attempted → loud.
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
        let unexpected = try await runFailureProbe(
            cause: .upstreamsUnreachable,
            logger: RecordingLogSink(minLevel: .info),
            config: upstreamFailingConfig,
            group: group,
            target: "example.invalid:443"
        )
        let unexpectedPass = unexpected.requestFailed
            && unexpected.loudProxyLevels.contains(.error)
            && unexpected.failureEvents.contains("upstream.tunnel_failed")
        notes.append("unexpected(upstreams unreachable): \(unexpected.summary) → \(unexpectedPass ? "loud" : "QUIET")")

        let pass = expectedPass && unexpectedPass
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
            assertions: [
                .init("expected VPN-off failure stays quiet", expectedPass),
                .init("unexpected upstream failure is observable", unexpectedPass),
            ],
            notes: notes
        )
    }

    /// Spins up a `LocalProxyServer` with the supplied fixed direct-mode
    /// cause and config, sends one CONNECT to `target`, waits for the request
    /// to be reported failed, and returns what the failure left behind: the
    /// `.proxy` log lines at `.warning` or above and the `*_failed` events.
    @MainActor
    private static func runFailureProbe(
        cause: DirectModeCause,
        logger: RecordingLogSink,
        config: ProxyConfig,
        group: EventLoopGroup,
        target: String
    ) async throws -> FailureProbeResult {
        let events = RuntimeEventLog(capacity: 64)
        let failedRequests = NIOLockedValueBox(0)
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
            onRequestCompleted: { succeeded, _ in
                if !succeeded { failedRequests.withLockedValue { $0 += 1 } }
            },
            eventSink: { events.append($0) }
        )
        ScenarioCleanup.register { await server.stop() }
        try await server.start()

        guard let port = server.listeningPort else {
            throw NSError(domain: "directModeSilence", code: 1)
        }

        let client = FakeClient(
            id: 0,
            group: group,
            localProxyHost: "127.0.0.1",
            localProxyPort: port,
            target: target,
            behavior: .sendOnceThenListen(requestBytes: 32)
        )
        try await client.run()

        // The failure is logged and its event emitted before the request is
        // reported completed, so the callback is the signal to stop waiting.
        // The direct path spends up to its 10 s connect timeout first; cap at
        // 15 s so pm-sim cannot hang if the underlying behaviour changes.
        for _ in 0..<60 {
            try await Task.sleep(for: .milliseconds(250))
            if failedRequests.withLockedValue({ $0 }) > 0 { break }
        }
        await client.close()

        return FailureProbeResult(
            requestFailed: failedRequests.withLockedValue { $0 } > 0,
            loudProxyLevels: logger.entries().filter { $0.category == .proxy && $0.level >= .warning }.map(\.level),
            failureEvents: events.events.map(\.event).filter { $0.hasSuffix("_failed") }
        )
    }

    private struct FailureProbeResult {
        let requestFailed: Bool
        let loudProxyLevels: [LogLevel]
        let failureEvents: [String]

        var summary: String {
            "requestFailed=\(requestFailed) loudProxyLines=\(loudProxyLevels.map(\.rawValue)) failureEvents=\(failureEvents)"
        }
    }

    // MARK: - Keepalive readback: verify OS accepted the options on a dedicated client socket.

    @MainActor
    static func keepaliveReadback(verbose: Bool) async throws -> ScenarioResult {
        let name = "keepaliveReadback"
        let group = MultiThreadedEventLoopGroup.singleton

        let origin = FakeOrigin(group: group, behavior: .silent)
        ScenarioCleanup.register { await origin.stop() }
        try await origin.start()

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
            assertions: [.init("keepalive options accepted by OS", pass)],
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
