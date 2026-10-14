// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// A failed exchange through the upstream is reported once, naming both the
/// request target and the upstream that exchange dialed (#146).
///
/// Two upstreams take a request each and hold it, then close without
/// answering. Between the two requests the active upstream switches, as
/// recovery's "switch upstream" step does, so by the time both fail the
/// pool's last selection is the second upstream. Each request must still
/// produce exactly one line naming its own target and its own upstream, and
/// one `upstream.exchange_failed` event.
enum ExchangeFailureScenarios {
    private struct Failure: Error { let message: String }

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let name = "upstream-exchange-failure"
        let group = MultiThreadedEventLoopGroup.singleton
        let started = Date()
        var notes: [String] = []
        var assertions: [ScenarioAssertion] = []

        let upstreams = [HoldThenCloseUpstream(), HoldThenCloseUpstream()]
        for upstream in upstreams {
            ScenarioCleanup.register { upstream.stop() }
            try await upstream.start(group: group)
        }

        var config = GenericDefaults.shared.makeConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.socksEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.pacURL = ""
        // Strict: a failed exchange is answered 502, never retried DIRECT.
        config.strictMode = true
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.upstreams = upstreams.enumerated().map { index, upstream in
            UpstreamProxy(name: "Held \(index)", host: "127.0.0.1", port: upstream.port, priority: 0)
        }
        let fixed = config

        let events = RuntimeEventLog(capacity: 64)
        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        let server = LocalProxyServer(
            logger: logger, configProvider: { fixed },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in MockAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: group, logger: DiscardingLogSink(), ttlSeconds: 30, baseTimeoutMS: 500),
            pacRoutingEngine: nil, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in },
            eventSink: { events.append($0) }
        )
        try await server.start()
        ScenarioCleanup.register { await server.stop() }
        guard let port = server.listeningPort else { throw Failure(message: "HTTP listener missing") }

        // The origin is never dialed: strict mode keeps the request on the upstream.
        let origin = "127.0.0.1:9"
        var responses: [EventLoopFuture<String>] = []
        for path in ["/one", "/two"] {
            responses.append(try await RawClient.send(
                group: group, port: port,
                request: "GET http://\(origin)\(path) HTTP/1.1\r\nHost: \(origin)\r\n\r\n"
            ))
            try await waitUntil { upstreams.contains { $0.paths.contains(path) } }
            if path == "/one" { _ = try await server.switchToNextUpstream() }
        }
        let owners = ["/one", "/two"].map { path in upstreams.first { $0.paths.contains(path) } }
        upstreams.forEach { $0.release() }
        var statuses: [String] = []
        for response in responses {
            statuses.append(String(try await response.get().prefix(12)))
        }

        let lines = logger.entries().map(\.message).filter { $0.localizedCaseInsensitiveContains("exchange") }
        let failed = events.events.filter { $0.event == "upstream.exchange_failed" }
        notes.append("statuses=\(statuses) lines=\(lines) events=\(failed.map { $0.detail ?? "" })")
        assertions.append(.init("each request was held by a different upstream",
                                owners[0] != nil && owners[1] != nil && owners[0] !== owners[1]))
        assertions.append(.init("both clients got a 502", statuses.allSatisfy { $0.hasPrefix("HTTP/1.1 502") }))
        assertions.append(.init("one log line per failed exchange", lines.count == 2))
        assertions.append(.init("one upstream.exchange_failed event per failed exchange", failed.count == 2))
        for (path, owner) in zip(["/one", "/two"], owners) {
            let target = "http://\(origin)\(path)"
            let upstream = owner.map { "127.0.0.1:\($0.port)" } ?? "unknown"
            assertions.append(.init(
                "\(path): the line names its target and the upstream it dialed",
                lines.contains { $0.hasPrefix("Proxy exchange for \(target) via \(upstream) failed: ") }
            ))
            assertions.append(.init(
                "\(path): the event names its target",
                failed.contains { $0.detail?.hasPrefix("target=\(target) ") ?? false }
            ))
        }

        return ScenarioResult(
            name: name, clientCount: 2, clientsOpened: 2, clientsWithFirstByte: 2,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }

    /// Polls a condition; the deadline only keeps a regression from hanging pm-sim.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Reads one request head, records its path and holds the connection until
/// `release()`, then closes it without a response.
private final class HoldThenCloseUpstream: @unchecked Sendable {
    private var channel: Channel?
    private let state = NIOLockedValueBox<(paths: [String], held: [Channel])>(([], []))

    var port: Int { channel?.localAddress?.port ?? 0 }
    var paths: [String] { state.withLockedValue { $0.paths } }

    func start(group: EventLoopGroup) async throws {
        let state = self.state
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HoldThenCloseHandler(state: state))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func release() {
        for channel in state.withLockedValue({ state in defer { state.held = [] }; return state.held }) {
            channel.close(promise: nil)
        }
    }

    func stop() {
        release()
        channel?.close(promise: nil)
    }
}

private final class HoldThenCloseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let state: NIOLockedValueBox<(paths: [String], held: [Channel])>
    private var pending = ""

    init(state: NIOLockedValueBox<(paths: [String], held: [Channel])>) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        guard let headEnd = pending.range(of: "\r\n\r\n") else { return }
        // "GET http://host:port/path HTTP/1.1": record the path.
        let uri = pending[..<headEnd.lowerBound].split(separator: " ").dropFirst().first.map(String.init) ?? ""
        let path = URLComponents(string: uri)?.path ?? uri
        let channel = context.channel
        state.withLockedValue {
            $0.paths.append(path)
            $0.held.append(channel)
        }
        pending = ""
    }
}

/// Sends one request; the future holds everything read until the proxy closes.
private enum RawClient {
    private struct Timeout: Error {}

    static func send(group: EventLoopGroup, port: Int, request: String) async throws -> EventLoopFuture<String> {
        let promise = group.next().makePromise(of: String.self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(10)) { promise.fail(Timeout()) }
        promise.futureResult.whenComplete { _ in timeout.cancel() }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(Reader(promise: promise)) }
            .connect(host: "127.0.0.1", port: port)
            .get()
        channel.writeAndFlush(channel.allocator.buffer(string: request), promise: nil)
        return promise.futureResult
    }

    private final class Reader: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let promise: EventLoopPromise<String>
        private var text = ""
        private var done = false

        init(promise: EventLoopPromise<String>) {
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            text += buffer.readString(length: buffer.readableBytes) ?? ""
            // A complete 502 is enough; the proxy may keep the client open.
            guard !done, text.contains("\r\n\r\n") else { return }
            done = true
            promise.succeed(text)
            context.close(promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            if !done {
                done = true
                promise.succeed(text)
            }
            context.fireChannelInactive()
        }
    }
}
