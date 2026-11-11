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
        "a.corp.example/X-Injected",
        "user@a.corp.example",
        "bücher.corp.example",
    ]

    func testAWritableAuthorityIsOneOfHostCharacters() {
        for host in ["a.corp.example", "UNDER_score.corp.example", "192.0.2.10", "[2001:db8::1]", "2001:db8::1", "xn--bcher-kva.corp.example"] {
            XCTAssertTrue(TunnelAuthority.isWritable(host), host)
            XCTAssertTrue(TunnelAuthority.isWritable("\(host):443"), host)
        }
        for host in Self.forgedHosts + ["a.corp.example\r", "a.corp.example\u{7f}"] {
            XCTAssertFalse(TunnelAuthority.isWritable(host), host.debugDescription)
            XCTAssertFalse(TunnelAuthority.isWritable("\(host):443"), host.debugDescription)
        }
        XCTAssertFalse(TunnelAuthority.isWritable(""))
    }

    /// Every path that writes a CONNECT line goes through the coordinator.
    func testTheCoordinatorRefusesATargetThatCouldSplitItsCONNECT() async throws {
        let (coordinator, events) = try await startCoordinator()

        for host in Self.forgedHosts {
            do {
                _ = try await coordinator.connectUpstreamTunnel(target: "\(host):443").get()
                XCTFail("\(host.debugDescription) was tunnelled")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .malformedTunnelTarget, "\(host.debugDescription): \(error)")
            }
        }

        XCTAssertEqual(upstream?.connectHeads(), [], "nothing was dialled for a malformed target")
        let rejected = events.withLockedValue { $0 }.filter { $0.event == "connection.tunnel_target_rejected" }
        XCTAssertEqual(rejected.count, Self.forgedHosts.count)
        XCTAssertEqual(rejected.first?.detail, "target=a.corp.example__X-Injected:_1:443")
        XCTAssertFalse(rejected.contains { ($0.detail ?? "").contains { $0.isNewline || $0 == " " || $0 == "\0" } }, "\(rejected)")

        let tunnel = try await coordinator.connectUpstreamTunnel(target: "under_score.corp.example:443").get()
        tunnel.channel.close(promise: nil)
        XCTAssertEqual(upstream?.connectHeads().map { $0.components(separatedBy: "\r\n")[0] }, [
            "CONNECT under_score.corp.example:443 HTTP/1.1", "CONNECT under_score.corp.example:443 HTTP/1.1",
        ], "a well-formed target still reaches the upstream")
    }

    /// The client SOCKS listener reads a domain as up to 255 bytes of anything.
    func testTheClientSOCKSListenerCarriesNoForgedNameIntoACONNECT() async throws {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: "198.51.100.30")
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
            let reply = try await SOCKS5TestClient.reply(connecting: host, port: 443, through: port, group: group)
            XCTAssertNotEqual(reply, 0x00, host.debugDescription)
        }
        _ = await server.stop()

        XCTAssertEqual(upstream.connectHeads(), [], "no forged name reached the upstream")
    }

    /// The HTTP listener's parser already refuses a request line that a CR,
    /// an LF or a space would split, and the coordinator refuses the rest.
    func testTheHTTPListenerCarriesNoForgedTargetIntoACONNECT() async throws {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: "198.51.100.30")
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

    private func startCoordinator() async throws -> (CONNECTCoordinator, NIOLockedValueBox<[RuntimeEvent]>) {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: "198.51.100.30")
        self.upstream = upstream
        let config = Self.config(upstreamPort: upstream.port)
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { config },
                                  authenticatorProvider: { _ in StubNegotiateAuthenticator() })
        addTeardownBlock { pool.closeAll(scope: .all) }
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink(),
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        return (coordinator, events)
    }

    /// Sends `request` and returns what the listener answered before it closed or went quiet.
    private func rawExchange(_ request: String, port: Int) async throws -> String {
        let received = NIOLockedValueBox<[UInt8]>([])
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(ByteCollector(bytes: received)) }
            .connect(host: "127.0.0.1", port: port).get()
        var buffer = client.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await client.writeAndFlush(buffer).get()
        for _ in 0..<300 where client.isActive && received.withLockedValue({ $0.isEmpty }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        client.close(promise: nil)
        return String(decoding: received.withLockedValue { $0 }, as: UTF8.self)
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
