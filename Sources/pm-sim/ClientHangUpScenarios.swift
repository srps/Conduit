// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel
import ProxyPAC

/// A client that hangs up after the upstream answered in full is the
/// client's failure, not the upstream's. The upstream holds back the end of
/// a chunked response until the proxy has seen the client close, so writing
/// that end to the client fails every time. With PAC `PROXY …; DIRECT`, in
/// strict and in normal mode, nothing may follow: no DIRECT retry of the
/// served request, no strict-mode hint probe, no `upstream.exchange_failed`
/// and no breaker failure.
enum ClientHangUpScenarios {
    private struct Failure: Error { let message: String }

    private final class ProxyThenDirectPAC: PacEvaluator, PacScriptEvaluating, Sendable {
        let upstreamPort: Int
        init(upstreamPort: Int) { self.upstreamPort = upstreamPort }
        func fetchPAC(from urlString: String) async throws -> String { "synthetic PROXY; DIRECT" }
        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for url: URL) throws -> [String] { ["PROXY 127.0.0.1:\(upstreamPort)", "DIRECT"] }
        func routeChain(for entries: [String]) -> PACChain { CFPACEvaluator().routeChain(for: entries) }
    }

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let name = "client-hangup-after-response"
        let group = MultiThreadedEventLoopGroup.singleton
        let started = Date()
        var notes: [String] = []
        var assertions: [ScenarioAssertion] = []

        // Echoes, so a request wrongly retried DIRECT fails fast instead of hanging.
        let origin = FakeOrigin(group: group, behavior: .echo)
        ScenarioCleanup.register { await origin.stop() }
        try await origin.start()
        let upstream = HeldEndUpstream()
        ScenarioCleanup.register { upstream.stop() }
        try await upstream.start(group: group)

        for strict in [true, false] {
            let label = strict ? "strict" : "normal"
            var config = GenericDefaults.shared.makeConfig()
            config.localHost = "127.0.0.1"
            config.localPort = 0
            config.socksEnabled = false
            config.localPACEnabled = false
            config.strictMode = strict
            config.pacRoutingEnabled = true
            config.pacURL = "https://pac.example.test/synthetic.pac"
            config.noProxyHosts = []
            config.forceProxyHosts = []
            config.upstreams = [UpstreamProxy(name: "HeldEnd", host: "127.0.0.1", port: upstream.port, priority: 0)]
            let fixed = config

            let events = RuntimeEventLog(capacity: 64)
            let outcomes = NIOLockedValueBox<[RequestOutcome]>([])
            let pacEngine = PACRoutingEngine(configProvider: { fixed }, resolver: ProxyThenDirectPAC(upstreamPort: upstream.port))
            try await pacEngine.refresh(force: true)
            let detector = DirectConnectDetector(group: group, logger: DiscardingLogSink(), ttlSeconds: 30, baseTimeoutMS: 500)
            let server = LocalProxyServer(
                logger: ConsoleLogSink(minLevel: verbose ? .debug : .warning), configProvider: { fixed },
                directModeProvider: { (false, .none) },
                authenticatorProvider: { _ in MockAuthenticator() }, directConnectDetector: detector,
                pacRoutingEngine: pacEngine, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
                onRequestCompleted: { outcome, _ in outcomes.withLockedValue { $0.append(outcome) } },
                eventSink: { events.append($0) }
            )
            try await server.start()
            guard let port = server.listeningPort else { throw Failure(message: "HTTP listener missing") }

            let originBefore = origin.connectionCount
            let target = "127.0.0.1:\(origin.port)"
            let body = try await HangUpClient.readBodyThenClose(
                group: group, port: port,
                request: "GET http://\(target)/held HTTP/1.1\r\nHost: \(target)\r\n\r\n",
                marker: "<upstream>"
            )
            try await waitUntil { server.inboundConnectionCount == 0 }
            let sawClose = server.inboundConnectionCount == 0
            upstream.releaseEnd()
            try await waitUntil { !outcomes.withLockedValue { $0.isEmpty } }

            let recorded = outcomes.withLockedValue { $0 }
            let exchangeFailed = events.events.filter { $0.event == "upstream.exchange_failed" }.count
            let hints = events.events.filter { $0.event == "routing.strict_direct_reachable" }.count
            let failures = server.upstreamStatuses().map(\.consecutiveFailures)
            let directDials = origin.connectionCount - originBefore
            notes.append("\(label): outcomes=\(recorded) directDials=\(directDials) probes=\(detector.probeCount) exchangeFailed=\(exchangeFailed) hints=\(hints) breakerFailures=\(failures)")
            assertions += [
                .init("\(label): the client got the upstream's body", body.contains("<upstream>")),
                .init("\(label): the proxy saw the client close before the end", sawClose),
                .init("\(label): counted as a client failure", recorded == [.failed(.client)]),
                .init("\(label): no DIRECT retry and no hint probe", directDials == 0 && detector.probeCount == 0),
                .init("\(label): no upstream failure event or hint", exchangeFailed == 0 && hints == 0),
                .init("\(label): no breaker failure", failures == [0]),
            ]
            await server.stop()
        }

        return ScenarioResult(
            name: name, clientCount: 2, clientsOpened: 2, clientsWithFirstByte: 2,
            clientsClosedEarly: 2, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
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

/// Answers each request with a chunked `<upstream>` body and holds back the
/// terminating chunk until `releaseEnd()`.
private final class HeldEndUpstream: @unchecked Sendable {
    private var channel: Channel?
    private let held = NIOLockedValueBox<[Channel]>([])

    var port: Int { channel?.localAddress?.port ?? 0 }

    func start(group: EventLoopGroup) async throws {
        let held = self.held
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HeldEndHandler(held: held))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func releaseEnd() {
        for channel in held.withLockedValue({ held in defer { held = [] }; return held }) {
            channel.writeAndFlush(channel.allocator.buffer(string: "0\r\n\r\n"), promise: nil)
        }
    }

    func stop() {
        channel?.close(promise: nil)
    }
}

private final class HeldEndHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let held: NIOLockedValueBox<[Channel]>
    private var pending = ""

    init(held: NIOLockedValueBox<[Channel]>) {
        self.held = held
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        guard pending.contains("\r\n\r\n") else { return }
        pending = ""
        let body = "<upstream>"
        let reply = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n"
            + String(body.utf8.count, radix: 16) + "\r\n" + body + "\r\n"
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: reply)), promise: nil)
        held.withLockedValue { $0.append(context.channel) }
    }
}

/// Sends one request, reads until `marker`, then closes.
private enum HangUpClient {
    private struct Timeout: Error {}

    static func readBodyThenClose(group: EventLoopGroup, port: Int, request: String, marker: String) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) { promise.fail(Timeout()) }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(Reader(marker: marker, promise: promise)) }
            .connect(host: "127.0.0.1", port: port)
            .get()
        channel.writeAndFlush(channel.allocator.buffer(string: request), promise: nil)
        defer { timeout.cancel() }
        return try await promise.futureResult.get()
    }

    private final class Reader: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let marker: String
        private let promise: EventLoopPromise<String>
        private var text = ""
        private var done = false

        init(marker: String, promise: EventLoopPromise<String>) {
            self.marker = marker
            self.promise = promise
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            text += buffer.readString(length: buffer.readableBytes) ?? ""
            guard !done, text.contains(marker) else { return }
            done = true
            context.close(promise: nil)
            promise.succeed(text)
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
