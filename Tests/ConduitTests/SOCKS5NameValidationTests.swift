// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A SOCKS5 client names its target as up to 255 bytes of anything (#309).
/// The listener writes that name into log lines, an event detail and the
/// CONNECT it sends an upstream, so a name that is not a host is refused
/// when the request is parsed, before any of them.
final class SOCKS5NameValidationTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton

    /// Each would forge a log line, forge an event field or carry credentials into the log.
    private static let forgedNames = [
        "a.corp.example\r\nX-Forged: 1",
        "a.corp.example\nX-Forged: 1",
        "a.corp.example\rX-Forged: 1",
        "a.corp.example X-Forged=1",
        "a.corp.example\tX-Forged=1",
        "alice:s3cr3t?rest@a.corp.example",
        "alice:s3cr3t@a.corp.example",
        "2001:db8::1\0\r\nX-Forged: 1",
        "192.0.2.10\0\r\nX-Forged: 1",
        "a.corp.example\u{1b}[2KX-Forged",
        "[2001:db8::1]",
        "bücher.corp.example",
        "a..corp.example",
        "",
    ]

    func testAForgedNameIsRefusedBeforeAnyLogLineEventOrUpstream() async throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000_000))
        let fixture = try await start(now: { clock.withLockedValue { $0 } })

        for name in Self.forgedNames {
            let reply = try await socksReply(connecting: name, port: 443, through: fixture.port)
            XCTAssertEqual(reply, 0x01, "general failure for \(name.debugDescription)")
        }

        let lines = fixture.logger.entries().map(\.message)
        let events = fixture.events.withLockedValue { $0 }
        for text in lines + events.map({ "\($0.event) \($0.detail ?? "")" }) {
            for forged in ["X-Forged", "s3cr3t", "alice", "\r", "\n", "\0", "\u{1b}"] {
                XCTAssertFalse(text.contains(forged), "\(forged.debugDescription) in \(text.debugDescription)")
            }
        }
        XCTAssertFalse(events.contains { $0.event == "routing.socks5_force_proxy" }, "no routing decision was made")
        XCTAssertEqual(fixture.upstream.heads(), [], "no forged name reached the upstream")

        // A local client chooses how often to send one, so the event is limited to one a minute for every name together.
        let rejected = { fixture.events.withLockedValue { $0 }.filter { $0.event == "connection.socks5_name_rejected" }.map { $0.detail ?? "" } }
        XCTAssertEqual(rejected(), ["name_bytes=\(Self.forgedNames[0].utf8.count) suppressed=0"])
        XCTAssertEqual(lines.filter { $0.hasPrefix("connection.socks5_name_rejected ") }.count, 1, "\(lines)")
        clock.withLockedValue { $0 += 60 }
        _ = try await socksReply(connecting: "a.corp.example\r\nX-Forged: 2", port: 443, through: fixture.port)
        XCTAssertEqual(rejected().last, "name_bytes=\("a.corp.example\r\nX-Forged: 2".utf8.count) suppressed=\(Self.forgedNames.count - 1)")
    }

    func testAHostNameOrAddressStillTunnels() async throws {
        let fixture = try await start()
        let accepted = [
            ("origin.corp.example", "origin.corp.example:443"),
            ("Under_score.corp.example", "Under_score.corp.example:443"),
            ("a.corp.example.", "a.corp.example.:443"),
            ("intranet", "intranet:443"),
            ("xn--bcher-kva.corp.example", "xn--bcher-kva.corp.example:443"),
            ("192.0.2.10", "192.0.2.10:443"),
            ("2001:db8::1", "[2001:db8::1]:443"),
        ]
        for (name, _) in accepted {
            let reply = try await socksReply(connecting: name, port: 443, through: fixture.port)
            XCTAssertEqual(reply, 0x00, name)
        }
        XCTAssertEqual(fixture.upstream.heads().map { $0.components(separatedBy: "\r\n")[0] },
                       accepted.map { "CONNECT \($0.1) HTTP/1.1" })
        XCTAssertFalse(fixture.events.withLockedValue { $0 }.contains { $0.event == "connection.socks5_name_rejected" })
    }

    func testAHostIsADomainNameOrAnUnbracketedAddress() {
        for host in ["a.corp.example", "a.corp.example.", "intranet", "_srv._tcp.corp.example", "192.0.2.10", "2001:db8::1", "::1"] {
            XCTAssertTrue(HostSyntax.isHost(host), host)
        }
        for host in Self.forgedNames + ["a.corp.example..", ".", "-a.corp.example", "fe80::1%en0", "2001:db8::1\0"] {
            XCTAssertFalse(HostSyntax.isHost(host), host.debugDescription)
        }
    }

    private struct Fixture {
        let port: Int
        let logger: RecordingLogSink
        let events: NIOLockedValueBox<[RuntimeEvent]>
        let upstream: TunnellingUpstream
    }

    private func start(now: @escaping @Sendable () -> Date = { Date() }) async throws -> Fixture {
        let upstream = try await TunnellingUpstream.start(group: group)
        addTeardownBlock { await upstream.stop() }
        var config = ProxyConfig.testFixture()
        config.localPort = 0
        config.socksEnabled = false
        config.pacRoutingEnabled = false
        config.noProxyHosts = []
        // Every name is a force-proxy name, so a forged one would reach the routing event too.
        config.forceProxyHosts = ["*"]
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let fixed = config
        let logger = RecordingLogSink()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let pool = ConnectionPool(group: group, logger: logger, configProvider: { fixed },
                                  authenticatorProvider: { _ in UnchallengedAuthenticator() })
        addTeardownBlock { pool.closeAll(scope: .all) }
        let server = SOCKS5Server(
            group: group,
            connectCoordinator: CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in UnchallengedAuthenticator() }, logger: logger),
            logger: logger, directModeProvider: { (false, .none) }, pacRoutingEngine: nil,
            configProvider: { fixed }, gatewayMode: false,
            eventSink: { event in events.withLockedValue { if $0.count < 64 { $0.append(event) } } },
            nameRejectionGate: RuntimeEventRepeatGate(now: now)
        )
        try await server.start(host: "127.0.0.1", port: 0)
        addTeardownBlock { await server.stop() }
        return Fixture(port: try XCTUnwrap(server.listeningPort), logger: logger, events: events, upstream: upstream)
    }

    /// One SOCKS5 CONNECT for `name` on a fresh connection; the reply code, nil when the listener closed without one.
    private func socksReply(connecting name: String, port: Int, through proxyPort: Int) async throws -> UInt8? {
        let request = [0x05, 0x01, 0x00, 0x03, UInt8(name.utf8.count)] + Array(name.utf8) + [UInt8(port >> 8), UInt8(port & 0xff)]
        let received = NIOLockedValueBox<[UInt8]>([])
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(ReplyCollector(bytes: received)) }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        for (write, wanted) in [([UInt8]([0x05, 0x01, 0x00]), 2), (request, 12)] {
            var buffer = client.allocator.buffer(capacity: write.count)
            buffer.writeBytes(write)
            try await client.writeAndFlush(buffer).get()
            for _ in 0..<300 where client.isActive && received.withLockedValue({ $0.count }) < wanted {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        client.close(promise: nil)
        let bytes = received.withLockedValue { $0 }
        return bytes.count >= 4 ? bytes[3] : nil
    }
}

/// The upstream below never challenges, so no token is asked for.
private final class UnchallengedAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate unused" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { scheme.caseInsensitiveCompare("Negotiate") == .orderedSame }
    func reset() {}
}

/// A corporate proxy stand-in that records each request head and answers it with a tunnel.
private final class TunnellingUpstream: @unchecked Sendable {
    private let channel: Channel
    private let recorded: NIOLockedValueBox<[String]>

    private init(channel: Channel, recorded: NIOLockedValueBox<[String]>) {
        self.channel = channel
        self.recorded = recorded
    }

    var port: Int { channel.localAddress?.port ?? 0 }
    func heads() -> [String] { recorded.withLockedValue { $0 } }

    static func start(group: EventLoopGroup) async throws -> TunnellingUpstream {
        let recorded = NIOLockedValueBox<[String]>([])
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(Session(recorded: recorded)) }
            .bind(host: "127.0.0.1", port: 0).get()
        return TunnellingUpstream(channel: channel, recorded: recorded)
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
        private let recorded: NIOLockedValueBox<[String]>
        private var tunnelled = false
        private var accumulated = ByteBufferAllocator().buffer(capacity: 1024)

        init(recorded: NIOLockedValueBox<[String]>) { self.recorded = recorded }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !tunnelled else { return }
            var buffer = unwrapInboundIn(data)
            accumulated.writeBuffer(&buffer)
            guard let head = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
                  head.contains("\r\n\r\n") else { return }
            tunnelled = true
            recorded.withLockedValue { if $0.count < 64 { $0.append(head) } }
            var out = context.channel.allocator.buffer(capacity: 64)
            out.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
            context.writeAndFlush(NIOAny(out), promise: nil)
        }
    }
}

private final class ReplyCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let bytes: NIOLockedValueBox<[UInt8]>
    init(bytes: NIOLockedValueBox<[UInt8]>) { self.bytes = bytes }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let read = buffer.readBytes(length: buffer.readableBytes) ?? []
        bytes.withLockedValue { if $0.count < 4096 { $0.append(contentsOf: read) } }
    }
}
