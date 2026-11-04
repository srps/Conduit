// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel
import RuntimeEvents

enum SilentUpstreamScenarios {
    private final class DelayedHTTPUpstream: @unchecked Sendable {
        enum Answer { case after(TimeAmount), never }

        private let answerTo: @Sendable (String) -> Answer
        private var channel: (any Channel)?
        private let lines = NIOLockedValueBox<[String]>([])

        init(answerTo: @escaping @Sendable (String) -> Answer) {
            self.answerTo = answerTo
        }

        var port: Int { channel?.localAddress?.port ?? 0 }
        var requestLines: [String] { lines.withLockedValue { $0 } }

        @RuntimeActor
        func start(group: EventLoopGroup) async throws {
            let answerTo = self.answerTo, lines = self.lines
            let channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(RequestHandler { channel, requestLine in
                        lines.withLockedValue { $0.append(requestLine) }
                        guard case .after(let delay) = answerTo(requestLine) else { return }
                        channel.eventLoop.scheduleTask(in: delay) {
                            let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                            channel.writeAndFlush(channel.allocator.buffer(string: response), promise: nil)
                        }
                    })
                }
                .bind(host: "127.0.0.1", port: 0).get()
            self.channel = channel
            ScenarioCleanup.register { do { try await channel.close().get() } catch ChannelError.alreadyClosed {} catch { SilentUpstreamScenarios.reportCleanupFailure(error) } }
        }

        private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let onRequest: (any Channel, String) -> Void
            private var pending = ""

            init(onRequest: @escaping (any Channel, String) -> Void) { self.onRequest = onRequest }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                pending += buffer.readString(length: buffer.readableBytes) ?? ""
                while let end = pending.range(of: "\r\n\r\n") {
                    let head = String(pending[pending.startIndex..<end.lowerBound])
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    onRequest(context.channel, head.components(separatedBy: "\r\n").first ?? "")
                }
            }
        }
    }

    private static func reportCleanupFailure(_ error: Error) { fputs("silent upstream fixture cleanup failed: \(error)\n", stderr) }

    @RuntimeActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    private static func strictConfigWithBreakerBurstWindowOff() -> ProxyConfig {
        var config = ProxyConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.pacURL = ""
        config.strictMode = true
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.circuitBreakerWindowSeconds = 0
        return config
    }

    private static func sendThroughProxy(group: EventLoopGroup, port: Int, tag: String) async throws -> EventLoopFuture<String> {
        let origin = "127.0.0.1:9"
        return try await RawClient.send(
            group: group, port: port,
            request: "GET http://\(origin)/\(tag) HTTP/1.1\r\nHost: \(origin)\r\nX-Sim-Request: \(tag)\r\n\r\n"
        )
    }

    @RuntimeActor
    private static func orchestrator(
        config: ProxyConfig, verbose: Bool, probe: (@Sendable ([UpstreamProxy]) async -> UpstreamProbeSummary)? = nil
    ) -> ProxyOrchestrator {
        ProxyOrchestrator(
            config: config, logger: ConsoleLogSink(minLevel: verbose ? .debug : .warning),
            authenticatorProvider: { _ in MockAuthenticator() }, connectivityProbe: probe
        )
    }

    @RuntimeActor
    static func silentFailover(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let answering = NIOLockedValueBox(true)
        let upstream = DelayedHTTPUpstream { _ in answering.withLockedValue { $0 } ? .after(.zero) : .never }
        try await upstream.start(group: group)

        let responseTimeout: TimeInterval = 0.5, checkInterval: TimeInterval = 2, probeDeadline = UpstreamProber.defaultTimeoutSeconds
        var config = strictConfigWithBreakerBurstWindowOff()
        config.upstreamResponseTimeoutSeconds = responseTimeout
        config.healthCheckIntervalSeconds = checkInterval
        config.healthCheckURL = "http://silent-failover.test/"
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let threshold = config.circuitFailureThreshold
        let endpoint = "127.0.0.1:\(upstream.port)"
        let orchestrator = orchestrator(config: config, verbose: verbose)
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        guard let port = orchestrator.snapshot.bindings.proxyPort else {
            throw ScenarioExecutionError(message: "the HTTP listener did not bind")
        }
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        let servedFirst = try await until(timeout: 10) {
            orchestrator.snapshot.runtimeStatus.state == .running && orchestrator.snapshot.runtimeStatus.lastHealthSummary.hasPrefix("Healthy via ")
        }

        answering.withLockedValue { $0 = false }
        let silentAt = Date()
        var responses: [EventLoopFuture<String>] = []
        for index in 0..<(threshold + 1) {
            responses.append(try await sendThroughProxy(group: group, port: port, tag: "silent-\(index)"))
        }
        var statuses: [String] = []
        for response in responses { statuses.append(String(try await response.get().prefix(12))) }

        let connectSlack = 0.1, silentCheck = responseTimeout + connectSlack
        let nextCheckDue = checkInterval, heldCheck = silentCheck, recheckDue = max(checkInterval / 2, 1), decisiveCheck = silentCheck
        let ladderChecks = 3 * silentCheck, postLadderProbe = probeDeadline + connectSlack
        let bound = nextCheckDue + heldCheck + recheckDue + decisiveCheck + ladderChecks + postLadderProbe
        let fell = try await until(timeout: bound + 5) { orchestrator.snapshot.directModeCause.isDirect }
        let fellAt = Date().timeIntervalSince(silentAt)
        let status = orchestrator.snapshot.runtimeStatus
        let cause = orchestrator.snapshot.directModeCause
        let silentStatus = orchestrator.snapshot.upstreamStatuses.first { $0.endpoint == endpoint }
        let silences = events("health.inconclusive").compactMap(\.detail)
        let skipped = events("recovery.step_skipped").compactMap(\.detail)
        let exhausted = events("recovery.exhausted").compactMap(\.detail)
        let probes = events("connectivity.probe_inconclusive").compactMap(\.detail)

        return ScenarioResult(name: "upstream-silent-failover", clientCount: threshold + 1, clientsOpened: threshold + 1,
            clientsWithFirstByte: statuses.filter { !$0.isEmpty }.count, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("the upstream served a health check before it went silent", servedFirst),
                .init("every request to the silent upstream ended with a 502 after the response budget",
                      statuses.count == threshold + 1 && statuses.allSatisfy { $0.hasPrefix("HTTP/1.1 502") }
                        && events("upstream.response_timeout").count >= threshold + 1),
                .init("\(threshold + 1) response timeouts, which opened the breaker before #197 with the burst window off, left it closed",
                      events("upstream.circuit_opened").isEmpty && silentStatus?.consecutiveFailures == 0),
                .init("the first silent health check was held as inconclusive",
                      silences.first?.hasPrefix("reason=answer_timed_out consecutive=1 decisive=false ") == true),
                .init("the second consecutive silent check was decisive, and every later one while the failure stood",
                      silences.count >= 2 && silences[1].contains(" consecutive=2 decisive=true ")
                        && silences.dropFirst().allSatisfy { $0.contains(" decisive=true ") }),
                .init("the ladder skipped re-authentication because nothing answered",
                      skipped.count == 1 && skipped[0].hasPrefix("step=reauthenticate reason=upstream_silent")),
                .init("the ladder exhausted on a silence, not on an unreachable upstream",
                      exhausted.count == 1 && exhausted[0].hasPrefix("failure=answer_timed_out ")),
                .init("the post-ladder probe's silence was decisive because a failure stood",
                      probes.count == 1 && probes[0].contains("decisive=true")),
                .init("routing fell to DIRECT within the bound 1.5I + 5R + P + 6C",
                      fell && cause.routesClientTrafficDirectly && status.activeUpstream == "DIRECT" && fellAt <= bound + 2),
            ], notes: [
                "R=\(responseTimeout)s I=\(checkInterval)s P=\(probeDeadline)s C=\(connectSlack)s; bound \(String(format: "%.2f", bound))s (+2 s slack); fell to DIRECT (\(cause.rawValue)) \(String(format: "%.2f", fellAt))s after the silence began",
                "upstream saw \(upstream.requestLines.count) request heads, \(upstream.requestLines.filter { $0.hasPrefix("HEAD ") }.count) of them health checks",
            ])
    }

    @RuntimeActor
    static func slowServing(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let responseTimeout: TimeInterval = 0.4, checkInterval: TimeInterval = 1
        let slow = DelayedHTTPUpstream { line in
            if line.hasPrefix("HEAD ") { return .after(.milliseconds(Int64(responseTimeout * 500))) }
            if line.contains("/fast") { return .after(.zero) }
            return .after(.milliseconds(Int64(responseTimeout * 1500)))
        }
        try await slow.start(group: group)

        var config = strictConfigWithBreakerBurstWindowOff()
        config.upstreamResponseTimeoutSeconds = responseTimeout
        config.healthCheckIntervalSeconds = checkInterval
        config.healthCheckURL = "http://slow-serving.test/"
        config.upstreams = [UpstreamProxy(name: "slow", host: "127.0.0.1", port: slow.port, priority: 0)]
        let threshold = config.circuitFailureThreshold
        let endpoint = "127.0.0.1:\(slow.port)"
        let orchestrator = orchestrator(config: config, verbose: verbose, probe: { targets in
            UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
        })
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        guard let port = orchestrator.snapshot.bindings.proxyPort else {
            throw ScenarioExecutionError(message: "the HTTP listener did not bind")
        }
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        func heads() -> Int { slow.requestLines.filter { $0.hasPrefix("HEAD ") }.count }

        var responses: [EventLoopFuture<String>] = []
        for index in 0..<(threshold + 1) {
            responses.append(try await sendThroughProxy(group: group, port: port, tag: "slow-\(index)"))
        }
        var statuses: [String] = []
        for response in responses { statuses.append(String(try await response.get().prefix(12))) }
        // Read before the next HEAD can answer: a healthy check resets the count a timeout might have raised.
        let strikesRightAfterTheTimeouts = orchestrator.snapshot.upstreamStatuses.first { $0.endpoint == endpoint }?.consecutiveFailures
        // Checks run one at a time, so a fourth HEAD means three completed.
        let threeChecks = try await until(timeout: 5 * checkInterval + 5) { heads() >= 4 }
        let fast = String(try await sendThroughProxy(group: group, port: port, tag: "fast").get().prefix(12))
        let status = orchestrator.snapshot.runtimeStatus
        let slowStatus = orchestrator.snapshot.upstreamStatuses.first { $0.endpoint == endpoint }
        let recovery = orchestrator.eventLog.events.filter { event in
            if case .proxyRecovery? = event.typed { return true }
            return event.event.hasPrefix("recovery.")
        }

        return ScenarioResult(name: "upstream-slow-serving", clientCount: threshold + 2, clientsOpened: threshold + 2,
            clientsWithFirstByte: statuses.filter { !$0.isEmpty }.count + (fast.isEmpty ? 0 : 1), clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("every slow request ended with a 502 after the response budget",
                      statuses.count == threshold + 1 && statuses.allSatisfy { $0.hasPrefix("HTTP/1.1 502") }
                        && events("upstream.response_timeout").count >= threshold + 1),
                .init("\(threshold + 1) response timeouts left the breaker closed and struck nothing",
                      events("upstream.circuit_opened").isEmpty && strikesRightAfterTheTimeouts == 0 && slowStatus?.consecutiveFailures == 0),
                .init("three health checks completed within the budget and none was inconclusive",
                      threeChecks && events("health.inconclusive").isEmpty),
                .init("no recovery ladder ran", recovery.isEmpty),
                .init("the runtime stayed running on the same upstream and a fast request still succeeds through it",
                      status.state == .running && status.activeUpstream == endpoint && fast.hasPrefix("HTTP/1.1 200")),
            ], notes: ["R=\(responseTimeout)s I=\(checkInterval)s; HEAD answered at R/2, GET at 1.5R; \(threshold + 1) GETs timed out, breaker threshold \(threshold)"])
    }

    @RuntimeActor
    static func servedThenSilent(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let answering = NIOLockedValueBox(true)
        let primary = DelayedHTTPUpstream { _ in answering.withLockedValue { $0 } ? .after(.zero) : .never }
        let secondary = DelayedHTTPUpstream { _ in .after(.milliseconds(40)) }
        try await primary.start(group: group)
        try await secondary.start(group: group)

        let responseTimeout: TimeInterval = 0.5, checkInterval: TimeInterval = 2
        var config = strictConfigWithBreakerBurstWindowOff()
        config.upstreamResponseTimeoutSeconds = responseTimeout
        config.healthCheckIntervalSeconds = checkInterval
        config.healthCheckURL = "http://served-then-silent.test/"
        config.upstreams = [
            UpstreamProxy(name: "primary", host: "127.0.0.1", port: primary.port, priority: 0),
            UpstreamProxy(name: "secondary", host: "127.0.0.1", port: secondary.port, priority: 1),
        ]
        let threshold = config.circuitFailureThreshold, decisive = UnansweredStreak.decisiveCount
        let primaryEndpoint = "127.0.0.1:\(primary.port)", secondaryEndpoint = "127.0.0.1:\(secondary.port)"
        let orchestrator = orchestrator(config: config, verbose: verbose)
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        guard let port = orchestrator.snapshot.bindings.proxyPort else {
            throw ScenarioExecutionError(message: "the HTTP listener did not bind")
        }
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        func latency(_ endpoint: String) -> Double? { orchestrator.snapshot.upstreamStatuses.first { $0.endpoint == endpoint }?.ewmaLatencyMS }
        func status(_ response: EventLoopFuture<String>) async -> String {
            do { return String(try await response.get().prefix(12)) } catch { return "no answer: \(error)" }
        }

        // Before either upstream has a latency, ties alternate, so a concurrent wave reaches both.
        var warm: [EventLoopFuture<String>] = []
        for index in 0..<4 { warm.append(try await sendThroughProxy(group: group, port: port, tag: "warm-\(index)")) }
        for response in warm { _ = await status(response) }
        let primaryLatency = latency(primaryEndpoint), secondaryLatency = latency(secondaryEndpoint)
        let primaryPreferred = (primaryLatency ?? .infinity) < (secondaryLatency ?? .infinity)

        answering.withLockedValue { $0 = false }
        let silentAt = Date()
        var failedBeforeServed = 0
        var servedAfter: TimeInterval?
        for index in 0..<(threshold + 1) {
            let answer = await status(try await sendThroughProxy(group: group, port: port, tag: "silent-\(index)"))
            if answer.hasPrefix("HTTP/1.1 200") { servedAfter = Date().timeIntervalSince(silentAt); break }
            failedBeforeServed += 1
        }
        var wave: [EventLoopFuture<String>] = []
        for index in 0..<(threshold + 1) { wave.append(try await sendThroughProxy(group: group, port: port, tag: "wave-\(index)")) }
        var waveStatuses: [String] = []
        for response in wave { waveStatuses.append(await status(response)) }
        let healthyViaSecondary = try await until(timeout: 2 * checkInterval + 2 * responseTimeout + 2) {
            orchestrator.snapshot.runtimeStatus.lastHealthSummary.hasPrefix("Healthy via \(secondaryEndpoint) ")
        }

        let connectSlack = 0.1
        // origin/main opened the primary's breaker after `threshold` response timeouts and served the next request (2.6 s measured).
        let mainBound = Double(threshold) * (responseTimeout + connectSlack)
        let primaryStatus = orchestrator.snapshot.upstreamStatuses.first { $0.endpoint == primaryEndpoint }
        let deprioritized = events("upstream.deprioritized").compactMap(\.detail)
        let recovery = orchestrator.eventLog.events.filter { $0.event.hasPrefix("recovery.") }

        return ScenarioResult(name: "upstream-served-then-silent", clientCount: 4 + 2 * (threshold + 1), clientsOpened: 4 + 2 * (threshold + 1),
            clientsWithFirstByte: waveStatuses.filter { $0.hasPrefix("HTTP/") }.count, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("the primary served first with the lower latency, so selection preferred it", primaryPreferred),
                .init("a request was served within threshold x (R + C), origin/main's breaker path",
                      servedAfter.map { $0 <= mainBound } ?? false),
                .init("only the \(decisive) silences that make a verdict failed before the secondary served",
                      servedAfter != nil && failedBeforeServed == decisive),
                .init("the decisive silence ranked the primary behind the secondary, once",
                      deprioritized.count == 1 && deprioritized[0].contains("upstream=primary ") && deprioritized[0].contains(" consecutive=\(decisive) ")),
                .init("a concurrent wave after it was served in full", waveStatuses.allSatisfy { $0.hasPrefix("HTTP/1.1 200") }),
                .init("the silences opened no breaker and struck nothing",
                      events("upstream.circuit_opened").isEmpty && primaryStatus?.circuitState == .closed && primaryStatus?.consecutiveFailures == 0),
                .init("the health check went healthy via the secondary, with no recovery ladder and no DIRECT",
                      healthyViaSecondary && recovery.isEmpty && !orchestrator.snapshot.directModeCause.isDirect),
            ], notes: [
                "R=\(responseTimeout)s I=\(checkInterval)s C=\(connectSlack)s; warm latency primary=\(primaryLatency.map { String(format: "%.1f", $0) } ?? "nil") ms secondary=\(secondaryLatency.map { String(format: "%.1f", $0) } ?? "nil") ms",
                "served \(servedAfter.map { String(format: "%.2f", $0) } ?? "never") s after the silence began (bound \(String(format: "%.2f", mainBound)) s) after \(failedBeforeServed) failed requests",
                "primary saw \(primary.requestLines.count) request heads, secondary \(secondary.requestLines.count)",
                "last health check: \(orchestrator.snapshot.runtimeStatus.lastHealthSummary); recovery events: \(recovery.map(\.event)); direct: \(orchestrator.snapshot.directModeCause.rawValue)",
            ])
    }
}
