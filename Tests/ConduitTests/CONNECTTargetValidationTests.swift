// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A tunnel's target is written into the CONNECT request line and the `Host`
/// header of a request that carries Conduit's own `Proxy-Authorization`.
/// A target is bytes a local client chose, so one that could end
/// that line or add a header to it never reaches an upstream, whichever
/// listener it came through.
final class CONNECTTargetValidationTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton
    private var upstream: AuthenticatingUpstream?

    override func tearDown() async throws {
        await upstream?.stop()
        upstream = nil
        try await super.tearDown()
    }

    private static let forgedHosts = [
        "a.corp.example\r\nX-Injected: 1",
        "a.corp.example\nX-Injected: 1",
        "a.corp.example\0X-Injected",
        "a.corp.example X-Injected",
        "a.corp.example\tX-Injected",
        "a.corp.example\u{7f}X-Injected",
        "bücher.corp.example",
    ]

    func testAWritableTargetIsOneTokenOfVisibleASCII() {
        for host in ["a.corp.example", "UNDER_score.corp.example", "192.0.2.10", "[2001:db8::1]", "2001:db8::1", "xn--bcher-kva.corp.example"] {
            XCTAssertTrue(TunnelAuthority.isWritable(host), host)
            XCTAssertTrue(TunnelAuthority.isWritable("\(host):443"), host)
        }
        for host in Self.forgedHosts + ["a.corp.example\r", "a.corp.example\u{1}"] {
            XCTAssertFalse(TunnelAuthority.isWritable(host), host.debugDescription)
            XCTAssertFalse(TunnelAuthority.isWritable("\(host):443"), host.debugDescription)
        }
        XCTAssertFalse(TunnelAuthority.isWritable(""))
        // Not request-line metacharacters: what a client wrote after the authority is carried as it was sent.
        for target in ["user@a.corp.example:443", "a.corp.example:443?sig=s#f", "a.corp.example/path:443"] {
            XCTAssertTrue(TunnelAuthority.isWritable(target), target)
        }
    }

    /// A SOCKS5 name is any 255 bytes, so a client can send credentials in it. They reach neither the event nor the log line.
    func testARejectedTargetsUserinfoReachesNeitherTheEventNorTheLog() async throws {
        // Credentials before or after a `?`, `#` or `@`: the report shows none of the target.
        for target in ["[alice:s3cr3t@host\r\n]:443", "[alice:s3cr3t?rest@host\r\n]:443", "host?token=alice@s3cr3t\r\n:443",
                       "host#alice@s3cr3t\r\n:443"] {
            let lines = NIOLockedValueBox<[String]>([])
            let (coordinator, events) = try await startCoordinator(logger: LineRecorder(lines: lines))

            do {
                _ = try await coordinator.connectUpstreamTunnel(target: target).get()
                XCTFail("a forged target was tunnelled: \(target.debugDescription)")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .malformedTunnelTarget)
            }

            let details = events.withLockedValue { $0 }.filter { $0.event == "connection.tunnel_target_rejected" }.map { $0.detail ?? "" }
            XCTAssertEqual(details, ["target_bytes=\(target.utf8.count) suppressed=0"], target.debugDescription)
            let logged = lines.withLockedValue { $0 }
            XCTAssertEqual(logged.filter { $0.contains("connection.tunnel_target_rejected") }.count, 1, "\(logged)")
            for text in details + logged {
                XCTAssertFalse(text.contains("s3cr3t"), text)
                XCTAssertFalse(text.contains("alice"), text)
            }
        }
    }

    /// Every path that writes a CONNECT line goes through the coordinator.
    func testTheCoordinatorRefusesATargetThatCouldSplitItsCONNECT() async throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000_000))
        let (coordinator, events) = try await startCoordinator(now: { clock.withLockedValue { $0 } })

        for host in Self.forgedHosts {
            do {
                _ = try await coordinator.connectUpstreamTunnel(target: "\(host):443").get()
                XCTFail("\(host.debugDescription) was tunnelled")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .malformedTunnelTarget, "\(host.debugDescription): \(error)")
            }
        }

        XCTAssertEqual(upstream?.connectHeads(), [], "nothing was dialled for a malformed target")
        // A local client chooses how often to send one, so the event is limited to one a minute for every target together.
        let rejected = { events.withLockedValue { $0 }.filter { $0.event == "connection.tunnel_target_rejected" }.map { $0.detail ?? "" } }
        XCTAssertEqual(rejected(), ["target_bytes=\(Self.forgedHosts[0].utf8.count + 4) suppressed=0"])
        clock.withLockedValue { $0 += 60 }
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "a.corp.example\r\nX-Injected: 2:443").get()
            XCTFail("a forged target was tunnelled")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .malformedTunnelTarget)
        }
        XCTAssertEqual(rejected().last, "target_bytes=\("a.corp.example\r\nX-Injected: 2:443".utf8.count) suppressed=\(Self.forgedHosts.count - 1)")

        let tunnel = try await coordinator.connectUpstreamTunnel(target: "under_score.corp.example:443").get()
        tunnel.channel.close(promise: nil)
        XCTAssertEqual(upstream?.connectHeads().map { $0.components(separatedBy: "\r\n")[0] }, [
            "CONNECT under_score.corp.example:443 HTTP/1.1", "CONNECT under_score.corp.example:443 HTTP/1.1",
        ], "a well-formed target still reaches the upstream")
    }

    /// The client SOCKS listener reads a domain as up to 255 bytes of anything.
    func testTheClientSOCKSListenerCarriesNoForgedNameIntoACONNECT() async throws {
        let upstream = try await AuthenticatingUpstream.start(group: group)
        self.upstream = upstream
        let config = Self.config(upstreamPort: upstream.port)
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { config },
                                  authenticatorProvider: { _ in StubNegotiateAuthenticator() })
        defer { pool.closeAll(scope: .all) }
        let server = SOCKS5Server(
            group: group,
            connectCoordinator: CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink()),
            logger: DiscardingLogSink(), directModeProvider: { (false, .none) }, pacRoutingEngine: nil,
            configProvider: { config }, gatewayMode: false
        )
        try await server.start(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(server.listeningPort)

        for host in Self.forgedHosts {
            let reply = try await socksReply(connecting: host, port: 443, through: port)
            XCTAssertNotEqual(reply, 0x00, host.debugDescription)
        }
        _ = await server.stop()

        XCTAssertEqual(upstream.connectHeads(), [], "no forged name reached the upstream")
    }

    /// The HTTP listener's parser already closes the connection on every one
    /// of these bytes in a request line, before the handler sees it.
    func testTheHTTPListenerCarriesNoForgedTargetIntoACONNECT() async throws {
        let upstream = try await AuthenticatingUpstream.start(group: group)
        self.upstream = upstream
        let config = Self.config(upstreamPort: upstream.port)
        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: group, logger: DiscardingLogSink()),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        let port = try XCTUnwrap(server.listeningPort)

        for host in Self.forgedHosts {
            let answer = try await rawExchange("CONNECT \(host):443 HTTP/1.1\r\nHost: a.corp.example:443\r\n\r\n", port: port)
            XCTAssertFalse(answer.hasPrefix("HTTP/1.1 200"), "\(host.debugDescription): \(answer.debugDescription)")
        }
        await server.stop()

        XCTAssertEqual(upstream.connectHeads(), [], "no forged target reached the upstream")
    }

    /// A refused target is a local refusal, like a VPN transition during the dial: the client gets a 502, the request fails
    /// locally, and a PAC `DIRECT` after the proxy neither dials the origin nor reports an upstream failure. The HTTP parser
    /// closes the connection on these bytes before the handler sees them, so the head is respelled after it.
    func testTheHTTPHandlerRefusesAMalformedTargetLocallyWhenPACOffersDIRECT() async throws {
        try await assertHTTPHandlerRefusesAMalformedTargetLocally(strictMode: false)
    }

    /// In strict mode PAC's `DIRECT` is no fallback, and the refusal is still no upstream failure.
    func testTheHTTPHandlerRefusesAMalformedTargetLocallyInStrictMode() async throws {
        try await assertHTTPHandlerRefusesAMalformedTargetLocally(strictMode: true)
    }

    private func assertHTTPHandlerRefusesAMalformedTargetLocally(strictMode: Bool) async throws {
        let upstream = try await AuthenticatingUpstream.start(group: group)
        self.upstream = upstream
        let accepted = NIOLockedValueBox(0)
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                return channel.close()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try await origin.close().get() }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        var config = Self.config(upstreamPort: upstream.port)
        config.pacRoutingEnabled = true
        config.pacURL = "https://pac.corp.example/proxy.pac"
        config.strictMode = strictMode
        let fixed = config
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event) } }
        let engine = PACRoutingEngine(
            configProvider: { fixed }, resolver: ProxyThenDirectPAC(upstreamPort: upstream.port), refreshInterval: 300, eventSink: sink
        )
        try await engine.refresh(force: true)
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { fixed },
                                  authenticatorProvider: { _ in StubNegotiateAuthenticator() })
        addTeardownBlock { pool.closeAll(scope: .all) }
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink(), eventSink: sink
        )
        let detector = DirectConnectDetector(group: group, logger: DiscardingLogSink())
        let outcomes = NIOLockedValueBox<[RequestOutcome]>([])
        // A non-ASCII byte after the authority: the host and port the handler parses stay the loopback origin's.
        let malformed = "127.0.0.1:\(originPort)?\u{e9}"
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let handler = HTTPProxyHandler(
                    pool: pool, connectCoordinator: coordinator, logger: DiscardingLogSink(), configProvider: { fixed },
                    directModeProvider: { (false, .none) }, directConnectDetector: detector, pacRoutingEngine: engine,
                    gatewayMode: false, authSource: nil, eventLoopGroup: self.group,
                    onConnectionOpened: { _ in }, onConnectionClosed: { _ in }, onConnectionActivity: { _ in },
                    onRequestCompleted: { outcome, _ in outcomes.withLockedValue { $0.append(outcome) } },
                    eventSink: sink
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                    )
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                    try channel.pipeline.syncOperations.addHandler(TargetRespeller(target: malformed))
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try await listener.close().get() }
        let port = try XCTUnwrap(listener.localAddress?.port)

        let answer = try await rawExchange("CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n", port: port)

        XCTAssertTrue(answer.hasPrefix("HTTP/1.1 502"), answer.debugDescription)
        XCTAssertEqual(accepted.withLockedValue { $0 }, 0, "no DIRECT fallback dialled the origin")
        XCTAssertEqual(upstream.connectHeads(), [], "nothing reached the upstream")
        XCTAssertEqual(outcomes.withLockedValue { $0 }, [.failed(.local)])
        let names = events.withLockedValue { $0 }.map(\.event)
        XCTAssertEqual(names.filter { $0 == "connection.tunnel_target_rejected" }.count, 1, "\(names)")
        XCTAssertFalse(names.contains("upstream.tunnel_failed"), "\(names)")
    }

    // MARK: - Harness

    private static func config(upstreamPort: Int) -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.localPort = 0
        config.socksEnabled = false
        config.pacRoutingEnabled = false
        config.noProxyHosts = []
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstreamPort, priority: 0)]
        return config
    }

    private func startCoordinator(
        now: @escaping @Sendable () -> Date = { Date() },
        logger: any LogSink = DiscardingLogSink()
    ) async throws -> (CONNECTCoordinator, NIOLockedValueBox<[RuntimeEvent]>) {
        let upstream = try await AuthenticatingUpstream.start(group: group)
        self.upstream = upstream
        let config = Self.config(upstreamPort: upstream.port)
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { config },
                                  authenticatorProvider: { _ in StubNegotiateAuthenticator() })
        addTeardownBlock { pool.closeAll(scope: .all) }
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: logger,
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            targetRejectionGate: RuntimeEventRepeatGate(now: now)
        )
        return (coordinator, events)
    }

    /// Sends `request` and returns what the listener answered before it closed or went quiet.
    private func rawExchange(_ request: String, port: Int) async throws -> String {
        String(decoding: try await exchange([Array(request.utf8)], port: port, until: 1), as: UTF8.self)
    }

    /// One SOCKS5 CONNECT for `host` as a name on a fresh connection; the reply code, nil when the listener closed without one.
    private func socksReply(connecting host: String, port: Int, through proxyPort: Int) async throws -> UInt8? {
        let request = [0x05, 0x01, 0x00, 0x03, UInt8(host.utf8.count)] + Array(host.utf8) + [UInt8(port >> 8), UInt8(port & 0xff)]
        let received = try await exchange([[0x05, 0x01, 0x00], request], port: proxyPort, until: 6)
        return received.count >= 4 ? received[3] : nil
    }

    /// Sends each write once the listener answered the one before, and returns what it received once it holds `count`
    /// bytes, closed or went quiet.
    private func exchange(_ writes: [[UInt8]], port: Int, until count: Int) async throws -> [UInt8] {
        let received = NIOLockedValueBox<[UInt8]>([])
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(ByteCollector(bytes: received)) }
            .connect(host: "127.0.0.1", port: port).get()
        for (index, write) in writes.enumerated() {
            var buffer = client.allocator.buffer(capacity: write.count)
            buffer.writeBytes(write)
            try await client.writeAndFlush(buffer).get()
            let wanted = index == writes.count - 1 ? count : 2
            for _ in 0..<300 where client.isActive && received.withLockedValue({ $0.count }) < wanted {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        client.close(promise: nil)
        return received.withLockedValue { $0 }
    }
}

private final class StubNegotiateAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate stub-initial" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { "Negotiate stub-challenge-response" }
    func canHandle(scheme: String) -> Bool { scheme.caseInsensitiveCompare("Negotiate") == .orderedSame }
    func reset() {}
}

/// A corporate proxy stand-in that records every request head it reads. Each
/// connection's first CONNECT gets a 407 `Negotiate` challenge, and a CONNECT
/// that answers it gets a 200.
private final class AuthenticatingUpstream: @unchecked Sendable {
    private let channel: Channel
    private let heads: NIOLockedValueBox<[String]>

    private init(channel: Channel, heads: NIOLockedValueBox<[String]>) {
        self.channel = channel
        self.heads = heads
    }

    var port: Int { channel.localAddress?.port ?? 0 }
    func connectHeads() -> [String] { heads.withLockedValue { $0 } }

    static func start(group: EventLoopGroup) async throws -> AuthenticatingUpstream {
        let heads = NIOLockedValueBox<[String]>([])
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Session(heads: heads)) }
            .bind(host: "127.0.0.1", port: 0).get()
        return AuthenticatingUpstream(channel: channel, heads: heads)
    }

    func stop() async {
        do {
            try await channel.close().get()
        } catch ChannelError.alreadyClosed {
        } catch {
            XCTFail("upstream listener close failed: \(error)")
        }
    }

    private final class Session: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let heads: NIOLockedValueBox<[String]>
        private var challenged = false
        private var tunnelled = false
        private var accumulated = ByteBufferAllocator().buffer(capacity: 1024)

        init(heads: NIOLockedValueBox<[String]>) { self.heads = heads }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !tunnelled else { return }
            var buffer = unwrapInboundIn(data)
            accumulated.writeBuffer(&buffer)
            guard let head = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
                  head.contains("\r\n\r\n") else { return }
            accumulated.clear()
            heads.withLockedValue { if $0.count < 64 { $0.append(head) } }
            let response: String
            if challenged, head.contains("Proxy-Authorization: Negotiate ") {
                tunnelled = true
                response = "HTTP/1.1 200 Connection Established\r\n\r\n"
            } else {
                challenged = true
                response = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n"
            }
            var out = context.channel.allocator.buffer(capacity: response.utf8.count)
            out.writeString(response)
            context.writeAndFlush(NIOAny(out), promise: nil)
        }
    }
}

private final class ByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let bytes: NIOLockedValueBox<[UInt8]>
    init(bytes: NIOLockedValueBox<[UInt8]>) { self.bytes = bytes }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let read = buffer.readBytes(length: buffer.readableBytes) ?? []
        bytes.withLockedValue { if $0.count < 4096 { $0.append(contentsOf: read) } }
    }
}

private struct LineRecorder: LogSink {
    let lines: NIOLockedValueBox<[String]>
    var minLevel: LogLevel { .debug }
    func logImpl(_: LogLevel, _ message: String, category _: LogCategory) {
        lines.withLockedValue { if $0.count < 64 { $0.append(message) } }
    }
}

/// Answers every URL with `PROXY` the test upstream, then `DIRECT`.
private struct ProxyThenDirectPAC: PacEvaluator, PacScriptEvaluating {
    let upstreamPort: Int
    func fetchPAC(from _: String) async throws -> String { "scripted" }
    func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }
    func resolveProxyChain(for _: URL) throws -> [String] { ["PROXY 127.0.0.1:\(upstreamPort)", "DIRECT"] }
    func routeChain(for _: [String]) -> PACChain { PACChain(routes: [.proxy(host: "127.0.0.1", port: upstreamPort), .direct]) }
}

/// Replaces a decoded request head's target with `target`, which the HTTP parser itself would not have let through.
private final class TargetRespeller: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias InboundOut = HTTPServerRequestPart
    private let target: String
    init(target: String) { self.target = target }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .head(var head) = unwrapInboundIn(data) else { return context.fireChannelRead(data) }
        head.uri = target
        context.fireChannelRead(wrapInboundOut(.head(head)))
    }
}
