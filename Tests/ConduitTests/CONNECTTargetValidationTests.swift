// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A tunnel's target is written into the CONNECT request line and the `Host`
/// header Conduit sends an upstream, after Conduit's own `Proxy-Authorization`
/// is attached. A target is bytes a local client chose, so one that could end
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
        XCTAssertEqual(TunnelAuthority.printable("a b=c\r\nd"), "a_b_c__d")
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
        XCTAssertEqual(rejected(), ["target=a.corp.example__X-Injected:_1:443 suppressed=0"])
        clock.withLockedValue { $0 += 60 }
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "a.corp.example\r\nX-Injected: 2:443").get()
            XCTFail("a forged target was tunnelled")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .malformedTunnelTarget)
        }
        XCTAssertEqual(rejected().last, "target=a.corp.example__X-Injected:_2:443 suppressed=\(Self.forgedHosts.count - 1)")

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

    /// The HTTP listener's parser already refuses a request line that a CR,
    /// an LF or a space would split, and the coordinator refuses the rest:
    /// a tab, a NUL, DEL and a non-ASCII byte.
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
        now: @escaping @Sendable () -> Date = { Date() }
    ) async throws -> (CONNECTCoordinator, NIOLockedValueBox<[RuntimeEvent]>) {
        let upstream = try await AuthenticatingUpstream.start(group: group)
        self.upstream = upstream
        let config = Self.config(upstreamPort: upstream.port)
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { config },
                                  authenticatorProvider: { _ in StubNegotiateAuthenticator() })
        addTeardownBlock { pool.closeAll(scope: .all) }
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink(),
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
