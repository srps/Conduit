// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// Decision 0045's guard: a Conduit `URLSession` cancels a proxy challenge.
///
/// The tests fall in two groups. The first sends nothing: it hands each
/// session's delegate a made-up challenge and reads the answer. The second
/// lets a loopback proxy answer 407 to a real request, which is only safe
/// while the guard holds, so each of those calls `ProxyChallengeCanary` on
/// the session it is about to use and sends nothing if the guard is gone.
/// A PAC fetch builds its session itself, so those tests run the canary from
/// `downloadWillResume`, on that session, before its request is sent.
final class ProxyChallengeRefusalTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton
    private var proxy: ChallengingProxy?
    private var origin: Channel?
    private var forwarder: LocalDNSForwarder?

    override func tearDown() async throws {
        await forwarder?.stop()
        forwarder = nil
        if let proxy { _ = try? await proxy.channel.close().get() }
        proxy = nil
        if let origin { _ = try? await origin.close().get() }
        origin = nil
        try await super.tearDown()
    }

    // MARK: - No request sent

    func testEverySessionTheFactoryBuildsCancelsAProxyChallengeOfEveryScheme() async throws {
        let delegate = ProxyChallengeRefusingDelegate(client: .doh) { _ in }
        let routes = [DoHSessionFactory.Route(proxy: nil), DoHSessionFactory.Route(proxy: ("127.0.0.1", 3128))]
        for route in routes {
            let session = DoHSessionFactory.session(for: route, delegate: delegate)
            defer { session.invalidateAndCancel() }
            XCTAssertTrue(session.delegate === delegate, "\(String(describing: route.proxy))")
            try ProxyChallengeCanary.requireRefusal(session)
        }
    }

    func testEverySessionARunningForwarderHoldsCancelsAProxyChallenge() async throws {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        let frozen = config
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = LocalDNSForwarder(
            group: group, logger: logger, configProvider: { frozen }, localProxyPort: { 3128 }
        )
        self.forwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)

        let sessions = forwarder.doHSessions
        XCTAssertEqual(sessions.count, 2, "direct and the client listener")
        try ProxyChallengeCanary.requireRefusal(sessions)
    }

    /// Checked on the session the PAC download builds for itself, stopped
    /// before its request is sent.
    func testThePACDownloadSessionCancelsAProxyChallengeOfEveryScheme() async throws {
        let checked = NIOLockedValueBox(0)
        let evaluator = CFPACEvaluator(downloadWillResume: { session in
            XCTAssertNotNil(session.delegate)
            try ProxyChallengeCanary.requireRefusal(session)
            checked.withLockedValue { $0 += 1 }
            throw StopBeforeSending()
        })

        do {
            _ = try await evaluator.fetchPAC(from: "https://192.0.2.10/proxy.pac")
            XCTFail("the hook stops the fetch")
        } catch is StopBeforeSending {}
        XCTAssertEqual(checked.withLockedValue { $0 }, 1)
    }

    /// The canary has to be able to fail: a session with no delegate is the
    /// regression it exists for.
    func testTheCanaryRejectsASessionWithNoGuard() async throws {
        let unguarded = URLSession(configuration: .ephemeral)
        defer { unguarded.invalidateAndCancel() }
        XCTAssertThrowsError(try ProxyChallengeCanary.requireRefusal(unguarded)) { error in
            XCTAssertTrue(error is ProxyChallengeCanary.NotGuarded, "\(error)")
        }
        XCTAssertThrowsError(try ProxyChallengeCanary.requireRefusal([URLSession]())) { error in
            XCTAssertTrue(error is ProxyChallengeCanary.NotGuarded, "nothing checked is not a pass: \(error)")
        }
    }

    /// URLSession gives NTLM and Negotiate to a session-level handler when the
    /// delegate has one, whatever its task-level handler says. The canary asks
    /// the handler URLSession would ask.
    func testTheCanaryRejectsASessionLevelHandlerThatPassesProxyChallengesOn() async throws {
        let delegate = SessionLevelDefaultHandling()
        let session = URLSession(configuration: .ephemeral, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        XCTAssertThrowsError(try ProxyChallengeCanary.requireRefusal(session)) { error in
            XCTAssertTrue(error is ProxyChallengeCanary.NotGuarded, "\(error)")
        }
        for (method, expected) in [
            (NSURLAuthenticationMethodNTLM, URLSession.AuthChallengeDisposition.performDefaultHandling),
            (NSURLAuthenticationMethodNegotiate, .performDefaultHandling),
            (NSURLAuthenticationMethodHTTPBasic, .cancelAuthenticationChallenge),
            (NSURLAuthenticationMethodHTTPDigest, .cancelAuthenticationChallenge),
        ] {
            let answer = ProxyChallengeCanary.disposition(
                of: delegate, in: session, for: ProxyChallengeCanary.proxyChallenge(method: method)
            )
            XCTAssertEqual(answer, expected, method)
        }
    }

    func testEachSchemeIsReportedUnderItsOwnName() async throws {
        for scheme in ProxyChallengeCanary.schemes {
            let events = NIOLockedValueBox<[RuntimeEvent]>([])
            let delegate = ProxyChallengeRefusingDelegate(client: .originResolver) { event in
                events.withLockedValue { $0.append(event) }
            }
            let session = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: nil), delegate: delegate)
            defer { session.invalidateAndCancel() }

            let answer = ProxyChallengeCanary.disposition(
                of: delegate, in: session, for: ProxyChallengeCanary.proxyChallenge(method: scheme.method)
            )

            XCTAssertEqual(answer, .cancelAuthenticationChallenge, scheme.name)
            XCTAssertEqual(events.withLockedValue { $0 }.map(\.detail), [
                "client=origin_resolver proxy=\(ProxyChallengeCanary.proxyHost):\(ProxyChallengeCanary.proxyPort) method=\(scheme.name) suppressed=0",
            ])
            XCTAssertEqual(delegate.refusalCount, 1)
        }
    }

    func testAServerChallengeKeepsDefaultHandlingAndIsNotReported() async throws {
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in events.withLockedValue { $0.append(event) } }
        let session = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: nil), delegate: delegate)
        defer { session.invalidateAndCancel() }
        let methods = [NSURLAuthenticationMethodServerTrust, NSURLAuthenticationMethodHTTPBasic, NSURLAuthenticationMethodNegotiate]

        for method in methods {
            let doh = ProxyChallengeCanary.disposition(of: delegate, in: session, for: ProxyChallengeCanary.serverChallenge(method: method))
            XCTAssertEqual(doh, .performDefaultHandling, method)
        }
        XCTAssertEqual(events.withLockedValue { $0 }.count, 0)
        XCTAssertEqual(delegate.refusalCount, 0)

        let pacAnswers = NIOLockedValueBox<[URLSession.AuthChallengeDisposition?]>([])
        let evaluator = CFPACEvaluator(downloadWillResume: { download in
            for method in methods {
                let answer = ProxyChallengeCanary.disposition(
                    of: download.delegate, in: download, for: ProxyChallengeCanary.serverChallenge(method: method)
                )
                pacAnswers.withLockedValue { $0.append(answer) }
            }
            throw StopBeforeSending()
        })
        do {
            _ = try await evaluator.fetchPAC(from: "https://192.0.2.10/proxy.pac")
            XCTFail("the hook stops the fetch")
        } catch is StopBeforeSending {}
        XCTAssertEqual(pacAnswers.withLockedValue { $0 }, Array(repeating: .performDefaultHandling, count: methods.count), "PAC")
    }

    // MARK: - A real 407, sent only past the canary

    /// HTTPS, because a DoH provider is HTTPS and its CONNECT is where the
    /// 407 becomes a challenge. CFNetwork hands a plain-HTTP request's 407
    /// back as a response, with no challenge.
    func testProxyChallengeIsCancelledReportedOnceAndNeverAnswered() async throws {
        let proxy = try await ChallengingProxy.start(group: group)
        self.proxy = proxy
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in
            events.withLockedValue { $0.append(event) }
        }
        let session = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: ("127.0.0.1", proxy.port)), delegate: delegate)
        defer { session.invalidateAndCancel() }
        try ProxyChallengeCanary.requireRefusal(session)

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
        let recorded = Self.refusals(in: events, from: proxy)
        XCTAssertEqual(recorded.count, 1, "reported once a minute per proxy and scheme: \(recorded)")
        XCTAssertEqual(recorded.first?.kind, .auth)
        XCTAssertEqual(recorded.first?.detail, "client=doh proxy=127.0.0.1:\(proxy.port) method=ntlm suppressed=0",
                       "of Negotiate, NTLM and Basic, CFNetwork hands the delegate NTLM")
    }

    /// One scheme offered at a time, so the scheme CFNetwork raises is the
    /// one under test. Negotiate has its own test below: CFNetwork raises no
    /// challenge for it.
    func testEachSchemeOfferedAloneIsCancelledAndReportedByName() async throws {
        let offers: [(name: String, header: String)] = [
            ("ntlm", "NTLM"),
            ("basic", "Basic realm=\"corp.example\""),
            ("digest", "Digest realm=\"corp.example\", nonce=\"MTIzNDU2Nzg5MGFiY2RlZg==\", qop=\"auth\", algorithm=MD5"),
        ]
        for offer in offers {
            let proxy = try await ChallengingProxy.start(group: group, offering: [offer.header])
            defer { proxy.channel.close(promise: nil) }
            let events = NIOLockedValueBox<[RuntimeEvent]>([])
            let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in
                events.withLockedValue { $0.append(event) }
            }
            let session = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: ("127.0.0.1", proxy.port)), delegate: delegate)
            defer { session.invalidateAndCancel() }
            try ProxyChallengeCanary.requireRefusal(session)

            do {
                let (_, response) = try await session.data(from: URL(string: "https://192.0.2.10/dns-query?name=\(offer.name).example&type=A")!)
                XCTFail("\(offer.name): got \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
            } catch {
                XCTAssertEqual((error as? URLError)?.code, .cancelled, offer.name)
            }

            XCTAssertEqual(
                Self.refusals(in: events, from: proxy).map(\.detail),
                ["client=doh proxy=127.0.0.1:\(proxy.port) method=\(offer.name) suppressed=0"],
                offer.name
            )
            let heads = proxy.requestHeads()
            XCTAssertEqual(heads.count, 1, "\(offer.name): \(heads)")
            XCTAssertFalse(heads.contains { $0.lowercased().contains("proxy-authorization") }, "\(offer.name): \(heads)")
        }
    }

    /// A proxy that offers only Negotiate never reaches the delegate.
    /// CFNetwork tries the user's Kerberos ticket by itself, with no password
    /// to ask for, and fails the task when it has no ticket for the proxy.
    /// This pins what was measured on macOS 26, so a change in CFNetwork that
    /// starts raising the challenge, or answering it, shows up here.
    func testANegotiateOnlyProxyRaisesNoChallengeAndGetsNoCredential() async throws {
        let proxy = try await ChallengingProxy.start(group: group, offering: ["Negotiate"])
        self.proxy = proxy
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in
            events.withLockedValue { $0.append(event) }
        }
        let session = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: ("127.0.0.1", proxy.port)), delegate: delegate)
        defer { session.invalidateAndCancel() }
        try ProxyChallengeCanary.requireRefusal(session)

        do {
            let (_, response) = try await session.data(from: URL(string: "https://192.0.2.10/dns-query?name=negotiate.example&type=A")!)
            XCTFail("got \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        } catch {
            XCTAssertNotEqual((error as? URLError)?.code, .cancelled, "nothing cancelled it: \(error)")
        }

        XCTAssertEqual(Self.refusals(in: events, from: proxy).count, 0, "the delegate was not asked")
        let heads = proxy.requestHeads()
        XCTAssertEqual(heads.count, 1, "\(heads)")
        XCTAssertFalse(heads.contains { $0.lowercased().contains("proxy-authorization") }, "\(heads)")
    }

    /// A server's own 401 is not a proxy's business: the session lets
    /// CFNetwork handle it, and with no credential stored the 401 comes back
    /// as the response.
    func testAServerThatAnswers401StillGetsDefaultHandling() async throws {
        let origin = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(OneShotResponder(response:
                "HTTP/1.1 401 Unauthorized\r\nWWW-Authenticate: Basic realm=\"corp.example\"\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            )) }
            .bind(host: "127.0.0.1", port: 0).get()
        self.origin = origin
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in events.withLockedValue { $0.append(event) } }
        let session = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: nil), delegate: delegate)
        defer { session.invalidateAndCancel() }
        try ProxyChallengeCanary.requireRefusal(session)
        let canaryRefusals = delegate.refusalCount

        let port = try XCTUnwrap(origin.localAddress?.port)
        let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/dns-query")!)

        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 401, "the task was not cancelled")
        XCTAssertEqual(delegate.refusalCount, canaryRefusals, "a server challenge is not a refusal")
        XCTAssertFalse(events.withLockedValue { $0 }.contains { ($0.detail ?? "").contains("127.0.0.1") })
    }

    func testPACFetchThroughAChallengingProxyFailsWithTheRefusal() async throws {
        let proxy = try await ChallengingProxy.start(group: group)
        self.proxy = proxy
        let carrier = Self.carrier(through: proxy)
        defer { carrier.invalidateAndCancel() }
        let canary = CanaryRuns()

        do {
            let script = try await canary.evaluator(session: carrier).fetchPAC(from: "https://192.0.2.10/proxy.pac")
            XCTFail("a 407 must not become a script, got \(script.utf8.count) bytes")
        } catch let PACResolverError.fetchFailed(message) {
            XCTAssertTrue(message.hasPrefix("PAC fetch refused a proxy-authentication challenge (proxy=127.0.0.1:\(proxy.port) method="), message)
        }
        XCTAssertEqual(canary.count, 1, "the canary checked the session the fetch used")
        XCTAssertFalse(proxy.requestHeads().contains { $0.lowercased().contains("proxy-authorization") })
    }

    /// The refusal reaches the owner where a PAC failure is reported: `pac.refresh_failed`.
    func testAPACRefreshThroughAChallengingProxyReportsTheRefusalInRefreshFailed() async throws {
        let proxy = try await ChallengingProxy.start(group: group, offering: ["NTLM"])
        self.proxy = proxy
        let carrier = Self.carrier(through: proxy)
        defer { carrier.invalidateAndCancel() }
        let canary = CanaryRuns()
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://192.0.2.10/proxy.pac"
        config.pacRoutingEnabled = true
        let frozen = config
        let events = RuntimeEventLog(capacity: 16)
        let engine = PACRoutingEngine(
            configProvider: { frozen }, resolver: canary.evaluator(session: carrier),
            eventSink: { events.append($0) }
        )

        do {
            try await engine.refresh(force: true)
            XCTFail("the refresh must fail")
        } catch let PACResolverError.fetchFailed(message) {
            XCTAssertTrue(message.contains("refused a proxy-authentication challenge"), message)
        }

        let failed = events.events.filter { $0.event == "pac.refresh_failed" }
        XCTAssertEqual(failed.count, 1)
        let detail = failed.first?.detail ?? ""
        XCTAssertTrue(
            detail.contains("PAC fetch refused a proxy-authentication challenge (proxy=127.0.0.1:\(proxy.port) method=ntlm)"),
            detail
        )
        XCTAssertEqual(canary.count, 1, "the canary checked the session the refresh used")
        XCTAssertFalse(proxy.requestHeads().contains { $0.lowercased().contains("proxy-authorization") })
    }

    /// When a refusal is why nothing answered, the warning says so instead of
    /// calling the providers unreachable.
    func testTheAllProvidersFailedWarningNamesARefusedChallenge() async throws {
        let proxy = try await ChallengingProxy.start(group: group, offering: ["NTLM"])
        self.proxy = proxy
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localHost = "127.0.0.1"
        config.dohProviders = ["https://192.0.2.10/dns-query"]
        config.dnsEntries = []
        let frozen = config
        let logger = RecordingLogSink(minLevel: .debug)
        let proxyPort = proxy.port
        let forwarder = LocalDNSForwarder(
            group: group, logger: logger, configProvider: { frozen },
            preferProxyPathForDoH: { true }, localProxyPort: { proxyPort }
        )
        self.forwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        try ProxyChallengeCanary.requireRefusal(forwarder.doHSessions)

        let client = try await DatagramBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let query = DNSWireFormat.buildQuery(domain: "refused.example", txID: 0x0407, qtype: 1)
        var buffer = client.allocator.buffer(capacity: query.count)
        buffer.writeBytes(query)
        try await client.writeAndFlush(AddressedEnvelope(
            remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: try XCTUnwrap(forwarder.listeningPort)), data: buffer
        )).get()
        func warnings() -> [String] {
            logger.entries().filter { $0.level == .warning && $0.message.contains("DoH provider(s) failed") }.map(\.message)
        }
        for _ in 0..<1_400 where warnings().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await client.close().get()

        let warning = try XCTUnwrap(warnings().first)
        XCTAssertTrue(warning.contains("asked for authentication and Conduit refused the challenge"), warning)
        XCTAssertTrue(warning.contains("auth.proxy_challenge_refused"), warning)
        XCTAssertFalse(warning.contains("the providers were unreachable"), warning)
    }

    func testTheWarningStillSaysUnreachableWhenNothingWasRefused() {
        XCTAssertTrue(
            DoHFailureSignature(statuses: [], proxyChallengeRefused: false).explanation
                .hasPrefix("no HTTP response at all — the providers were unreachable")
        )
        let blocked = DoHFailureSignature(statuses: [403, 404], proxyChallengeRefused: false).explanation
        XCTAssertTrue(blocked.contains("answered HTTP 403/404 instead of a DNS payload"), blocked)
        XCTAssertFalse(blocked.contains("refused the challenge"), blocked)
        let both = DoHFailureSignature(statuses: [403], proxyChallengeRefused: true).explanation
        XCTAssertTrue(both.contains("answered HTTP 403") && both.contains("refused the challenge"), both)
        XCTAssertNotEqual(
            DoHFailureSignature(statuses: [], proxyChallengeRefused: true),
            DoHFailureSignature(statuses: [], proxyChallengeRefused: false),
            "a refusal starting or ending repeats the warning at once"
        )
    }

    private static func carrier(through proxy: ChallengingProxy) -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = DoHSessionFactory.proxyDictionary(host: "127.0.0.1", port: proxy.port)
        return URLSession(configuration: configuration)
    }

    /// The refusals `proxy` caused; the canary's own are under its own proxy name.
    private static func refusals(in events: NIOLockedValueBox<[RuntimeEvent]>, from proxy: ChallengingProxy) -> [RuntimeEvent] {
        events.withLockedValue { $0 }.filter {
            $0.event == "auth.proxy_challenge_refused" && ($0.detail ?? "").contains("proxy=127.0.0.1:\(proxy.port) ")
        }
    }
}

private struct StopBeforeSending: Error {}

/// Builds a PAC evaluator whose every HTTPS download runs the canary on its
/// own session before the request is sent, and counts the runs.
private final class CanaryRuns: Sendable {
    private let runs = NIOLockedValueBox(0)
    var count: Int { runs.withLockedValue { $0 } }

    func evaluator(session: URLSession) -> CFPACEvaluator {
        CFPACEvaluator(session: session, downloadWillResume: { [runs] download in
            try ProxyChallengeCanary.requireRefusal(download)
            runs.withLockedValue { $0 += 1 }
        })
    }
}

/// Cancels a proxy challenge at the task level but passes the ones URLSession
/// sends to the session level on to CFNetwork.
private final class SessionLevelDefaultHandling: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(
        _ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.performDefaultHandling, nil)
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}

private final class OneShotResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private let response: String
    private var responded = false
    init(response: String) { self.response = response }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        responded = true
        let channel = context.channel
        var out = channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in channel.close(promise: nil) }
    }
}

private final class ChallengingProxy: @unchecked Sendable {
    let channel: Channel
    private let heads: NIOLockedValueBox<[String]>

    var port: Int { channel.localAddress?.port ?? 0 }

    func requestHeads() -> [String] { heads.withLockedValue { $0 } }

    private init(channel: Channel, heads: NIOLockedValueBox<[String]>) {
        self.channel = channel
        self.heads = heads
    }

    static func start(
        group: EventLoopGroup,
        offering schemes: [String] = ["Negotiate", "NTLM", "Basic realm=\"corp.example\""]
    ) async throws -> ChallengingProxy {
        let heads = NIOLockedValueBox<[String]>([])
        let challenge = schemes.map { "Proxy-Authenticate: \($0)\r\n" }.joined()
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(Responder(heads: heads, challenge: challenge)) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return ChallengingProxy(channel: channel, heads: heads)
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private let heads: NIOLockedValueBox<[String]>
        private let challenge: String
        private var responded = false

        init(heads: NIOLockedValueBox<[String]>, challenge: String) {
            self.heads = heads
            self.challenge = challenge
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !responded else { return }
            responded = true
            var buffer = unwrapInboundIn(data)
            let head = String(decoding: buffer.readBytes(length: buffer.readableBytes) ?? [], as: UTF8.self)
            heads.withLockedValue { if $0.count < 64 { $0.append(head) } }
            let response = "HTTP/1.1 407 Proxy Authentication Required\r\n" + challenge +
                "Content-Length: 0\r\nConnection: close\r\n\r\n"
            let channel = context.channel
            var out = channel.allocator.buffer(capacity: response.utf8.count)
            out.writeString(response)
            context.writeAndFlush(wrapOutboundOut(out)).whenComplete { _ in channel.close(promise: nil) }
        }
    }
}
