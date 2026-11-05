// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

enum SilentUpstreamScenarios {
    private struct Failure: Error { let message: String }

    private final class DelayedHTTPUpstream: @unchecked Sendable {
        enum Answer { case after(TimeAmount), never }

        private let answerTo: @Sendable (String) -> Answer
        private var channel: Channel?
        private let lines = NIOLockedValueBox<[String]>([])

        init(answerTo: @escaping @Sendable (String) -> Answer) { self.answerTo = answerTo }

        var port: Int { channel?.localAddress?.port ?? 0 }
        var requestLines: [String] { lines.withLockedValue { $0 } }
        func requests(matching fragment: String) -> Int { requestLines.filter { $0.contains(fragment) }.count }

        func start(group: EventLoopGroup) async throws {
            let answerTo = self.answerTo, lines = self.lines
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(RequestHandler { channel, requestLine in
                        lines.withLockedValue { $0.append(requestLine) }
                        guard case .after(let delay) = answerTo(requestLine) else { return }
                        channel.eventLoop.scheduleTask(in: delay) {
                            channel.writeAndFlush(channel.allocator.buffer(string: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"), promise: nil)
                        }
                    })
                }
                .bind(host: "127.0.0.1", port: 0).get()
        }

        func stop() { channel?.close(promise: nil) }

        private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let onRequest: (Channel, String) -> Void
            private var pending = ""

            init(onRequest: @escaping (Channel, String) -> Void) { self.onRequest = onRequest }

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

    private static let responseTimeout: TimeInterval = 0.3

    @RuntimeActor
    private static func startServer(
        primary: DelayedHTTPUpstream, secondary: DelayedHTTPUpstream, verbose: Bool
    ) async throws -> (server: LocalProxyServer, port: Int, events: RuntimeEventLog, threshold: Int) {
        var config = GenericDefaults.shared.makeConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.socksEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.pacURL = ""
        config.strictMode = true
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.upstreamResponseTimeoutSeconds = responseTimeout
        config.circuitBreakerWindowSeconds = 0
        config.upstreams = [
            UpstreamProxy(name: "primary", host: "127.0.0.1", port: primary.port, priority: 0),
            UpstreamProxy(name: "secondary", host: "127.0.0.1", port: secondary.port, priority: 1),
        ]
        let fixed = config
        let events = RuntimeEventLog(capacity: 256)
        let server = LocalProxyServer(
            logger: RecordingLogSink(minLevel: verbose ? .debug : .info), configProvider: { fixed },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in MockAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), ttlSeconds: 30, baseTimeoutMS: 500),
            pacRoutingEngine: nil, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in },
            eventSink: { events.append($0) }
        )
        try await server.start()
        ScenarioCleanup.register { await server.stop() }
        guard let port = server.listeningPort else { throw Failure(message: "HTTP listener missing") }
        return (server, port, events, config.circuitFailureThreshold)
    }

    private static func send(port: Int, originPort: Int, tag: String) async throws -> String {
        let origin = "127.0.0.1:\(originPort)"
        let response = try await RawClient.send(
            group: MultiThreadedEventLoopGroup.singleton, port: port,
            request: "GET http://\(origin)/\(tag) HTTP/1.1\r\nHost: \(origin)\r\nX-Sim-Request: \(tag)\r\n\r\n"
        )
        return String(try await response.get().prefix(12))
    }

    private static func result(_ name: String, since started: Date, requests: Int, assertions: [ScenarioAssertion], notes: [String]) -> ScenarioResult {
        ScenarioResult(
            name: name, clientCount: requests, clientsOpened: requests, clientsWithFirstByte: requests,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }

    private static func servingAndStandby(_ upstreams: [DelayedHTTPUpstream]) -> (serving: DelayedHTTPUpstream, standby: DelayedHTTPUpstream)? {
        guard let serving = upstreams.first(where: { $0.requests(matching: "/warm-") == 2 }),
              let standby = upstreams.first(where: { $0 !== serving }), standby.requestLines.isEmpty else { return nil }
        return (serving, standby)
    }

    @RuntimeActor
    static func slowOrigin(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let upstreams = [0, 1].map { _ in DelayedHTTPUpstream { line in line.contains("/slow-") ? .after(.seconds(5)) : .after(.zero) } }
        for upstream in upstreams {
            ScenarioCleanup.register { upstream.stop() }
            try await upstream.start(group: group)
        }
        let (server, port, events, threshold) = try await startServer(primary: upstreams[0], secondary: upstreams[1], verbose: verbose)
        func count(_ event: String) -> Int { events.events.filter { $0.event == event }.count }

        var warm: [String] = []
        for index in 0..<2 { warm.append(try await send(port: port, originPort: 9, tag: "warm-\(index)")) }
        guard let (serving, standby) = servingAndStandby(upstreams) else {
            throw Failure(message: "the warm requests were not served by one upstream: \(upstreams.map(\.requestLines))")
        }
        var slow: [String] = []
        for index in 0..<(threshold + 1) { slow.append(try await send(port: port, originPort: 9, tag: "slow-\(index)")) }
        var fast: [String] = []
        for index in 0..<4 { fast.append(try await send(port: port, originPort: 9, tag: "fast-\(index)")) }
        let statuses = server.upstreamStatuses()

        return result("upstream-slow-origin", since: started, requests: warm.count + slow.count + fast.count, assertions: [
            .init("one upstream served both warm requests", warm.allSatisfy { $0.hasPrefix("HTTP/1.1 200") }),
            .init("every slow request ended with a 502 after the response budget",
                  slow.allSatisfy { $0.hasPrefix("HTTP/1.1 502") } && serving.requests(matching: "/slow-") == threshold + 1
                      && count("upstream.response_timeout") >= threshold + 1),
            .init("\(threshold + 1) timeouts on one origin counted nothing and opened no breaker",
                  count("upstream.silence_counted") == 0 && count("upstream.circuit_opened") == 0
                      && statuses.allSatisfy { $0.circuitState == .closed && $0.consecutiveFailures == 0 }),
            .init("the same upstream kept serving the fast requests after them",
                  fast.allSatisfy { $0.hasPrefix("HTTP/1.1 200") } && serving.requests(matching: "/fast-") == 4),
            .init("the standby was never asked", standby.requestLines.isEmpty),
        ], notes: [
            "R=\(responseTimeout)s threshold=\(threshold); /slow-* answered after 5 s",
            "serving upstream saw \(serving.requestLines.count) requests, standby \(standby.requestLines.count)",
        ])
    }

    @RuntimeActor
    static func silentUpstream(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let answering = [NIOLockedValueBox(true), NIOLockedValueBox(true)]
        let upstreams = answering.map { flag in DelayedHTTPUpstream { _ in flag.withLockedValue { $0 } ? .after(.zero) : .never } }
        for upstream in upstreams {
            ScenarioCleanup.register { upstream.stop() }
            try await upstream.start(group: group)
        }
        let (server, port, events, threshold) = try await startServer(primary: upstreams[0], secondary: upstreams[1], verbose: verbose)
        func details(_ event: String) -> [String] { events.events.filter { $0.event == event }.compactMap(\.detail) }

        var warm: [String] = []
        for index in 0..<2 { warm.append(try await send(port: port, originPort: 9, tag: "warm-\(index)")) }
        guard let (serving, standby) = servingAndStandby(upstreams) else {
            throw Failure(message: "the warm requests were not served by one upstream: \(upstreams.map(\.requestLines))")
        }
        let servingName = upstreams[0] === serving ? "primary" : "secondary"
        answering[upstreams[0] === serving ? 0 : 1].withLockedValue { $0 = false }
        var silent: [String] = []
        for index in 0..<(threshold + 1) { silent.append(try await send(port: port, originPort: 9 + index % 2, tag: "silent-\(index)")) }
        let opened = details("upstream.circuit_opened")
        var after: [String] = []
        for index in 0..<3 { after.append(try await send(port: port, originPort: 9, tag: "after-\(index)")) }
        let servingStatus = server.upstreamStatuses().first { $0.name == servingName }

        return result("upstream-silent", since: started, requests: warm.count + silent.count + after.count, assertions: [
            .init("one upstream served both warm requests", warm.allSatisfy { $0.hasPrefix("HTTP/1.1 200") }),
            .init("every request to the silent upstream ended with a 502 after the response budget",
                  silent.allSatisfy { $0.hasPrefix("HTTP/1.1 502") } && serving.requests(matching: "/silent-") == threshold + 1
                      && details("upstream.response_timeout").count >= threshold + 1),
            .init("the silences after the first, on two origins with no answer between, counted \(threshold) failures",
                  details("upstream.silence_counted").count == threshold
                      && details("upstream.silence_counted").allSatisfy { $0.contains("origins=127.0.0.1:9,127.0.0.1:10") }),
            .init("the silent upstream's breaker opened at the threshold",
                  opened.count == 1 && opened[0].hasPrefix("upstream=\(servingName) ") && opened[0].contains(" reason=threshold failures=\(threshold) ")
                      && servingStatus?.circuitState == .open),
            .init("the standby served every request after that",
                  after.allSatisfy { $0.hasPrefix("HTTP/1.1 200") } && standby.requests(matching: "/after-") == 3 && serving.requests(matching: "/after-") == 0),
        ], notes: [
            "R=\(responseTimeout)s threshold=\(threshold); origins alternate 127.0.0.1:9 and :10; \(servingName) served first and went silent",
            "counted: \(details("upstream.silence_counted"))",
            "opened: \(opened)",
        ])
    }
}
