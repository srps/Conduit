// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// A failed exchange through the upstream is reported once, naming both the
/// request target and the upstream that exchange dialed (#146).
///
/// Two requests for the same target are each taken and held by a different
/// upstream, which then closes without answering. Between the two requests
/// the active upstream switches, as recovery's "switch upstream" step does,
/// so by the time both fail the pool's last selection is the second
/// upstream. Each failure must still be its own report: one line and one
/// `upstream.exchange_failed` event naming the target and the upstream that
/// request dialed. Coalescing keyed on the target alone would fold the
/// second into the first.
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

        // The origin is never dialed: strict mode keeps the request on the
        // upstream. Both requests share one target; a header tells them apart.
        let origin = "127.0.0.1:9"
        let target = "http://\(origin)/shared"
        let requests = ["one", "two"]
        var responses: [EventLoopFuture<String>] = []
        for request in requests {
            responses.append(try await RawClient.send(
                group: group, port: port,
                request: "GET \(target) HTTP/1.1\r\nHost: \(origin)\r\nX-Sim-Request: \(request)\r\n\r\n"
            ))
            try await waitUntil { upstreams.contains { $0.requests.contains(request) } }
            if request == "one" { _ = try await server.switchToNextUpstream() }
        }
        let owners = requests.map { request in upstreams.first { $0.requests.contains(request) } }
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
        assertions.append(.init("one log line per failed exchange, not folded by target", lines.count == 2))
        assertions.append(.init("one upstream.exchange_failed event per failed exchange", failed.count == 2))
        for (request, owner) in zip(requests, owners) {
            let upstream = owner.map { "127.0.0.1:\($0.port)" } ?? "unknown"
            assertions.append(.init(
                "request \(request): a line names the target and the upstream it dialed",
                lines.contains { $0.hasPrefix("Proxy exchange for \(target) via \(upstream) failed: ") }
            ))
            assertions.append(.init(
                "request \(request): an event carries the target and the upstream it dialed",
                failed.contains { $0.detail?.hasPrefix("target=\(target) upstream=\(upstream) reason=") ?? false }
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

/// Reads one request head, records its `X-Sim-Request` value and holds the
/// connection until `release()`, then closes it without a response.
private final class HoldThenCloseUpstream: @unchecked Sendable {
    private var channel: Channel?
    private let state = NIOLockedValueBox<(requests: [String], held: [Channel])>(([], []))

    var port: Int { channel?.localAddress?.port ?? 0 }
    var requests: [String] { state.withLockedValue { $0.requests } }

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

    private let state: NIOLockedValueBox<(requests: [String], held: [Channel])>
    private var pending = ""

    init(state: NIOLockedValueBox<(requests: [String], held: [Channel])>) {
        self.state = state
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        guard let headEnd = pending.range(of: "\r\n\r\n") else { return }
        let request = pending[..<headEnd.lowerBound]
            .components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("x-sim-request:") }
            .map { $0.dropFirst("x-sim-request:".count).trimmingCharacters(in: .whitespaces) } ?? ""
        let channel = context.channel
        state.withLockedValue {
            $0.requests.append(request)
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
