// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// Decision 0045: a Conduit DoH session never lets CFNetwork answer a proxy's
/// 407, which on a real network asked macOS for a saved credential and then
/// prompted the user. The proxy is a loopback fake; the DoH target is a
/// TEST-NET address the fake never dials.
final class ProxyChallengeRefusalTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton
    private var proxy: ChallengingProxy?

    override func tearDown() async throws {
        if let proxy { _ = try? await proxy.channel.close().get() }
        proxy = nil
        try await super.tearDown()
    }

    /// HTTPS, because a DoH provider is HTTPS and its CONNECT is where the
    /// 407 becomes a challenge. CFNetwork hands a plain-HTTP request's 407
    /// back as a response, with no challenge.
    func testProxyChallengeIsCancelledReportedOnceAndNeverAnswered() async throws {
        let proxy = try await ChallengingProxy.start(group: group)
        self.proxy = proxy
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let delegate = ProxyChallengeRefusingDelegate(client: "doh", gate: RuntimeEventRepeatGate()) { event in
            events.withLockedValue { $0.append(event) }
        }
        let session = DoHSessionFactory.session(
            for: DoHSessionFactory.Route(proxy: ("127.0.0.1", proxy.port)),
            delegate: delegate
        )
        defer { session.invalidateAndCancel() }

        for name in ["a.example", "b.example"] {
            let url = URL(string: "https://192.0.2.10/dns-query?name=\(name)&type=A")!
            do {
                let (_, response) = try await session.data(from: url)
                XCTFail("\(name): a 407 must not become a response, got \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cancelled, "\(name): the challenge ends the task")
            }
        }

        let heads = proxy.requestHeads()
        XCTAssertEqual(heads.count, 2, "one CONNECT per fetch, no retry: \(heads)")
        XCTAssertFalse(heads.contains { $0.lowercased().contains("proxy-authorization") }, "no credential was sent: \(heads)")
        let recorded = events.withLockedValue { $0 }
        XCTAssertEqual(recorded.map(\.event), ["auth.proxy_challenge_refused"], "reported once a minute per proxy and scheme")
        XCTAssertEqual(recorded.first?.kind, .auth)
        let detail = recorded.first?.detail ?? ""
        XCTAssertTrue(detail.hasPrefix("client=doh proxy=127.0.0.1:\(proxy.port) method="), detail)
        XCTAssertTrue(detail.hasSuffix(" suppressed=0"), detail)
    }

    func testPACFetchThroughAChallengingProxyFailsWithTheRefusal() async throws {
        let proxy = try await ChallengingProxy.start(group: group)
        self.proxy = proxy
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = DoHSessionFactory.proxyDictionary(host: "127.0.0.1", port: proxy.port)
        let carrier = URLSession(configuration: configuration)
        defer { carrier.invalidateAndCancel() }

        do {
            let script = try await CFPACEvaluator(session: carrier).fetchPAC(from: "https://192.0.2.10/proxy.pac")
            XCTFail("a 407 must not become a script, got \(script.utf8.count) bytes")
        } catch let PACResolverError.fetchFailed(message) {
            XCTAssertTrue(message.hasPrefix("PAC fetch refused a proxy-authentication challenge (proxy=127.0.0.1:\(proxy.port) method="), message)
        }
        XCTAssertFalse(proxy.requestHeads().contains { $0.lowercased().contains("proxy-authorization") })
    }
}

/// Answers every request, CONNECT or not, with a 407 offering Negotiate,
/// NTLM and Basic, the way a corporate proxy does, and keeps each request's
/// head.
private final class ChallengingProxy: @unchecked Sendable {
    let channel: Channel
    private let heads: NIOLockedValueBox<[String]>

    var port: Int { channel.localAddress?.port ?? 0 }

    func requestHeads() -> [String] { heads.withLockedValue { $0 } }

    private init(channel: Channel, heads: NIOLockedValueBox<[String]>) {
        self.channel = channel
        self.heads = heads
    }

    static func start(group: EventLoopGroup) async throws -> ChallengingProxy {
        let heads = NIOLockedValueBox<[String]>([])
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Responder(heads: heads)) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return ChallengingProxy(channel: channel, heads: heads)
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let heads: NIOLockedValueBox<[String]>
        private var responded = false

        init(heads: NIOLockedValueBox<[String]>) { self.heads = heads }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !responded else { return }
            responded = true
            var buffer = unwrapInboundIn(data)
            let head = String(decoding: buffer.readBytes(length: buffer.readableBytes) ?? [], as: UTF8.self)
            heads.withLockedValue { if $0.count < 64 { $0.append(head) } }
            let response = "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                "Proxy-Authenticate: Negotiate\r\nProxy-Authenticate: NTLM\r\n" +
                "Proxy-Authenticate: Basic realm=\"corp.example\"\r\n" +
                "Content-Length: 0\r\nConnection: close\r\n\r\n"
            let channel = context.channel
            var out = channel.allocator.buffer(capacity: response.utf8.count)
            out.writeString(response)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
