// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The DoH upstream route (decision 0045), driven end to end: the forwarder's
/// own `URLSession`, the real SOCKS listener, `CONNECTCoordinator` and
/// `ConnectionPool`, against an upstream that demands authentication.
///
/// The provider is `192.0.2.10` (TEST-NET-1), which nothing answers, so the
/// direct route is a black hole the way direct 443 is under a full-tunnel VPN.
final class DoHUpstreamRouteTests: XCTestCase {
    private static let providerHost = "192.0.2.10"
    private static let answerIP = "198.51.100.30"

    private let group = MultiThreadedEventLoopGroup.singleton
    private var upstream: AuthenticatingUpstream?
    private var forwarder: LocalDNSForwarder?
    private var pool: ConnectionPool?

    override func tearDown() async throws {
        await forwarder?.stop()
        pool?.closeAll(scope: .all)
        await upstream?.stop()
        forwarder = nil
        pool = nil
        upstream = nil
        try await super.tearDown()
    }

    /// The client routing rules say DIRECT for the provider, and direct is a
    /// black hole. The lookup is answered through the upstream, which Conduit
    /// authenticated to itself.
    func testALookupIsAnsweredThroughTheUpstreamWhenTheRulesSayDirect() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query")

        let answer = try await resolve("through-upstream.example", port: running.dnsPort)

        XCTAssertEqual(answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip }, Self.answerIP)
        let heads = running.upstream.connectHeads()
        XCTAssertGreaterThanOrEqual(heads.count, 2, "a challenged CONNECT and its answer: \(heads)")
        XCTAssertTrue(heads.allSatisfy { $0.hasPrefix("CONNECT \(Self.providerHost):80 ") }, "\(heads)")
        XCTAssertTrue(heads.allSatisfy { $0.contains("Proxy-Authorization: Negotiate ") }, "Conduit's authenticator answers: \(heads)")
        XCTAssertTrue(heads.contains { $0.contains("Negotiate stub-challenge-response") }, "the 407 was answered: \(heads)")
        XCTAssertEqual(running.upstream.challengesSent, running.upstream.tunnelsOpened, "every 407 was answered with a tunnel")

        let events = running.events.withLockedValue { $0 }
        let used = events.filter { $0.event == "dns.doh_upstream_route_used" }
        XCTAssertEqual(used.map(\.detail), ["target=\(Self.providerHost):80 upstream=127.0.0.1:\(running.upstream.port) suppressed=0"])
        XCTAssertEqual(used.first?.kind, .routing)
        XCTAssertFalse(events.contains { $0.event == "auth.proxy_challenge_refused" }, "no challenge reached a URLSession")
    }

    /// The same network with no upstream route: what the forwarder had before
    /// the route existed. Nothing answers.
    func testWithoutTheUpstreamRouteTheSameLookupFails() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query", offerRoute: false)

        let answer = try await resolve("no-route.example", port: running.dnsPort)

        XCTAssertNil(answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip })
        XCTAssertEqual(answer.map { $0.count > 3 ? Int($0[3] & 0x0F) : -1 }, 2, "SERVFAIL")
        XCTAssertEqual(running.upstream.connectHeads(), [], "nothing dialled the upstream")
        XCTAssertNil(running.forwarder.doHUpstreamRoutePort)
    }

    /// An HTTPS provider, as in production. No TLS server stands behind the
    /// upstream, so the lookup is not answered; what is shown is that the
    /// session's TLS handshake arrives through an authenticated tunnel to
    /// the provider's 443.
    func testAnHTTPSProviderReachesTheUpstreamAsAnAuthenticatedTunnelCarryingTLS() async throws {
        let running = try await start(provider: "https://\(Self.providerHost)/dns-query")

        _ = try await resolve("over-tls.example", port: running.dnsPort)

        let heads = running.upstream.connectHeads()
        XCTAssertFalse(heads.isEmpty)
        XCTAssertTrue(heads.allSatisfy { $0.hasPrefix("CONNECT \(Self.providerHost):443 ") }, "\(heads)")
        XCTAssertTrue(heads.contains { $0.contains("Negotiate stub-challenge-response") }, "\(heads)")
        let first = running.upstream.firstTunnelBytes()
        XCTAssertFalse(first.isEmpty, "the session spoke through the tunnel")
        XCTAssertTrue(first.allSatisfy { $0.starts(with: [0x16, 0x03]) }, "each tunnel opens with a TLS handshake record: \(first)")
        XCTAssertFalse(
            running.events.withLockedValue { $0 }.contains { $0.event == "auth.proxy_challenge_refused" }
        )
    }

    func testTheRouteIsNotOfferedWhileTheHostSaysUpstreamsAreOutOfPlay() async throws {
        let offered = NIOLockedValueBox(false)
        let running = try await start(
            provider: "http://\(Self.providerHost)/dns-query", offered: { offered.withLockedValue { $0 } }
        )
        XCTAssertNil(running.forwarder.doHUpstreamRoutePort)

        let refused = try await resolve("not-offered.example", port: running.dnsPort)
        XCTAssertNil(refused.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip })
        XCTAssertEqual(running.upstream.connectHeads(), [])

        offered.withLockedValue { $0 = true }
        XCTAssertNotNil(running.forwarder.doHUpstreamRoutePort)
        let answer = try await resolve("offered-again.example", port: running.dnsPort)
        XCTAssertEqual(answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip }, Self.answerIP, "no restart needed")
    }

    func testTheRouteIsAbsentWithNoEnabledUpstream() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query", upstreamEnabled: false)

        XCTAssertNil(running.forwarder.doHUpstreamRoutePort)
        let answer = try await resolve("no-upstream.example", port: running.dnsPort)
        XCTAssertNil(answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip })
        XCTAssertEqual(running.upstream.connectHeads(), [])
    }

    /// The listener is not a general proxy: a local process asking it for
    /// anything but a provider is refused and nothing is dialled.
    func testTheRouteRefusesATargetThatIsNotAProvider() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)

        for (host, port) in [("intranet.corp.example", 443), (Self.providerHost, 443), ("198.51.100.7", 80)] {
            let reply = try await socksConnect(host: host, port: port, to: routePort)
            XCTAssertEqual(reply, 0x02, "\(host):\(port) is not allowed by the ruleset")
        }

        XCTAssertEqual(running.upstream.connectHeads(), [], "a refused target never reaches the upstream")
        let refusals = running.events.withLockedValue { $0 }.filter { $0.event == "dns.doh_upstream_route_refused" }
        XCTAssertEqual(refusals.map(\.detail), [
            "target=intranet.corp.example:443 reason=not_a_doh_provider suppressed=0",
            "target=\(Self.providerHost):443 reason=not_a_doh_provider suppressed=0",
            "target=198.51.100.7:80 reason=not_a_doh_provider suppressed=0",
        ])
    }

    func testAFailingUpstreamIsReportedAndTheListenerStopsWithTheForwarder() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)
        await running.upstream.stop()

        let reply = try await socksConnect(host: Self.providerHost, port: 80, to: routePort)
        XCTAssertEqual(reply, 0x05)
        let failures = running.events.withLockedValue { $0 }.filter { $0.event == "dns.doh_upstream_route_failed" }
        XCTAssertEqual(failures.count, 1)
        XCTAssertTrue(failures.first?.detail?.hasPrefix("target=\(Self.providerHost):80 error=") ?? false, "\(failures)")

        await running.forwarder.stop()
        XCTAssertNil(running.forwarder.doHUpstreamRoutePort)
        do {
            let channel = try await ClientBootstrap(group: group).connectTimeout(.seconds(2))
                .connect(host: "127.0.0.1", port: routePort).get()
            try await channel.close().get()
            XCTFail("the route's listener outlived the forwarder")
        } catch let error as NIOConnectionError {
            XCTAssertFalse(error.connectionErrors.isEmpty)
        }
    }

    // MARK: - Harness

    private struct Running {
        let forwarder: LocalDNSForwarder
        let upstream: AuthenticatingUpstream
        let events: NIOLockedValueBox<[RuntimeEvent]>
        let dnsPort: Int
    }

    private func start(
        provider: String,
        offerRoute: Bool = true,
        upstreamEnabled: Bool = true,
        offered: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Running {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: Self.answerIP)
        self.upstream = upstream

        var config = ProxyConfig.testFixture()
        var proxy = UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)
        proxy.enabled = upstreamEnabled
        config.upstreams = [proxy]
        config.dohProviders = [provider]
        config.dnsEntries = []
        // The client rules send the provider direct. The route must not care.
        config.noProxyHosts = [Self.providerHost]
        config.localPort = 0
        let frozen = config

        let logger = RecordingLogSink(minLevel: .debug)
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { frozen },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        self.pool = pool
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: logger
        )
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = LocalDNSForwarder(
            group: group, logger: logger, configProvider: { frozen },
            preferProxyPathForDoH: { true },
            upstreamRoute: offerRoute ? DoHUpstreamRouteSource(coordinator: coordinator, offered: offered) : nil,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        self.forwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return Running(
            forwarder: forwarder, upstream: upstream, events: events,
            dnsPort: try XCTUnwrap(forwarder.listeningPort)
        )
    }

    private func resolve(_ name: String, port: Int) async throws -> [UInt8]? {
        let answer = NIOLockedValueBox<[UInt8]?>(nil)
        let client = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(DatagramCollector(answer: answer)) }
            .bind(host: "127.0.0.1", port: 0).get()
        let query = DNSWireFormat.buildQuery(domain: name, txID: 0x0045, qtype: 1)
        var buffer = client.allocator.buffer(capacity: query.count)
        buffer.writeBytes(query)
        try await client.writeAndFlush(
            AddressedEnvelope(remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: port), data: buffer)
        ).get()
        // The forwarder always answers: a provider's answer, or SERVFAIL once
        // every route has timed out (4 s request, 8 s resource).
        for _ in 0..<1_400 where answer.withLockedValue({ $0 }) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        try await client.close().get()
        return answer.withLockedValue { $0 }
    }

    /// One SOCKS5 CONNECT to the route's listener; returns the reply code.
    private func socksConnect(host: String, port: Int, to routePort: Int) async throws -> UInt8? {
        let received = NIOLockedValueBox<[UInt8]>([])
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(ByteCollector(bytes: received)) }
            .connect(host: "127.0.0.1", port: routePort).get()
        var greeting = channel.allocator.buffer(capacity: 3)
        greeting.writeBytes([0x05, 0x01, 0x00])
        try await channel.writeAndFlush(greeting).get()
        for _ in 0..<200 where received.withLockedValue({ $0.count }) < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(received.withLockedValue { Array($0.prefix(2)) }, [0x05, 0x00])

        var request = channel.allocator.buffer(capacity: 64)
        if let address = try? SocketAddress(ipAddress: host, port: port), case .v4(let v4) = address {
            request.writeBytes([0x05, 0x01, 0x00, 0x01])
            withUnsafeBytes(of: v4.address.sin_addr) { request.writeBytes($0) }
        } else {
            request.writeBytes([0x05, 0x01, 0x00, 0x03, UInt8(host.utf8.count)])
            request.writeString(host)
        }
        request.writeInteger(UInt16(port))
        try await channel.writeAndFlush(request).get()
        for _ in 0..<600 where received.withLockedValue({ $0.count }) < 4 {
            try await Task.sleep(for: .milliseconds(10))
        }
        channel.close(promise: nil)
        return received.withLockedValue { $0.count >= 4 ? $0[3] : nil }
    }
}

private final class DatagramCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private let answer: NIOLockedValueBox<[UInt8]?>
    init(answer: NIOLockedValueBox<[UInt8]?>) { self.answer = answer }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        answer.withLockedValue { $0 = bytes }
    }
}

private final class ByteCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let bytes: NIOLockedValueBox<[UInt8]>
    init(bytes: NIOLockedValueBox<[UInt8]>) { self.bytes = bytes }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        let read = buffer.readBytes(length: buffer.readableBytes) ?? []
        bytes.withLockedValue { if $0.count < 64 { $0.append(contentsOf: read) } }
    }
}

final class StubNegotiateAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate stub-initial" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { "Negotiate stub-challenge-response" }
    func canHandle(scheme: String) -> Bool { scheme.caseInsensitiveCompare("Negotiate") == .orderedSame }
    func reset() {}
}

/// A corporate proxy stand-in. Each connection's first CONNECT gets a 407
/// `Negotiate` challenge. A CONNECT that answers it gets a 200, and from then
/// on the connection is the origin: the first request through the tunnel is
/// answered with a `dns-json` body. A request with no `Proxy-Authorization`
/// never gets a tunnel.
final class AuthenticatingUpstream: @unchecked Sendable {
    private let channel: Channel
    private let state: NIOLockedValueBox<State>
    /// Accepted connections, at most 256, so `stop` can close them too.
    private let children: NIOLockedValueBox<[ObjectIdentifier: Channel]>

    struct State {
        var connectHeads: [String] = []
        var challengesSent = 0
        var tunnelsOpened = 0
        var firstTunnelBytes: [[UInt8]] = []
    }

    var port: Int { channel.localAddress?.port ?? 0 }
    func connectHeads() -> [String] { state.withLockedValue { $0.connectHeads } }
    var challengesSent: Int { state.withLockedValue { $0.challengesSent } }
    var tunnelsOpened: Int { state.withLockedValue { $0.tunnelsOpened } }
    func firstTunnelBytes() -> [[UInt8]] { state.withLockedValue { $0.firstTunnelBytes } }

    private init(channel: Channel, state: NIOLockedValueBox<State>, children: NIOLockedValueBox<[ObjectIdentifier: Channel]>) {
        self.channel = channel
        self.state = state
        self.children = children
    }

    static func start(group: EventLoopGroup, answerIP: String) async throws -> AuthenticatingUpstream {
        let state = NIOLockedValueBox(State())
        let children = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                let id = ObjectIdentifier(child)
                children.withLockedValue { if $0.count < 256 { $0[id] = child } }
                child.closeFuture.whenComplete { _ in children.withLockedValue { $0[id] = nil } }
                return child.pipeline.addHandler(Session(state: state, answerIP: answerIP))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return AuthenticatingUpstream(channel: channel, state: state, children: children)
    }

    /// Closes the listener and every accepted connection, as a proxy going down does.
    func stop() async {
        do {
            try await channel.close().get()
        } catch ChannelError.alreadyClosed {
        } catch {
            XCTFail("upstream listener close failed: \(error)")
        }
        for child in children.withLockedValue({ Array($0.values) }) {
            child.close(promise: nil)
        }
    }

    private final class Session: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias OutboundOut = ByteBuffer

        private enum Phase { case challenge, authenticate, tunnel, answered }
        private let state: NIOLockedValueBox<State>
        private let answerIP: String
        private var phase = Phase.challenge
        private var accumulated = ByteBufferAllocator().buffer(capacity: 1024)

        init(state: NIOLockedValueBox<State>, answerIP: String) {
            self.state = state
            self.answerIP = answerIP
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            switch phase {
            case .challenge, .authenticate:
                accumulated.writeBuffer(&buffer)
                guard let head = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
                      head.contains("\r\n\r\n") else { return }
                accumulated.clear()
                state.withLockedValue { if $0.connectHeads.count < 64 { $0.connectHeads.append(head) } }
                let authorized = head.contains("Proxy-Authorization: Negotiate ")
                if phase == .authenticate, authorized {
                    phase = .tunnel
                    state.withLockedValue { $0.tunnelsOpened += 1 }
                    write("HTTP/1.1 200 Connection Established\r\n\r\n", context: context)
                } else {
                    phase = .authenticate
                    state.withLockedValue { $0.challengesSent += 1 }
                    write(
                        "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n",
                        context: context
                    )
                }
            case .tunnel:
                phase = .answered
                let first = Array(buffer.readableBytesView.prefix(8))
                state.withLockedValue { if $0.firstTunnelBytes.count < 64 { $0.firstTunnelBytes.append(first) } }
                guard first.starts(with: Array("GET ".utf8)) || first.starts(with: Array("POST".utf8)) else { return }
                let body = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"\#(answerIP)"}]}"#
                write(
                    "HTTP/1.1 200 OK\r\nContent-Type: application/dns-json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)",
                    context: context
                )
            case .answered:
                return
            }
        }

        private func write(_ text: String, context: ChannelHandlerContext) {
            var out = context.channel.allocator.buffer(capacity: text.utf8.count)
            out.writeString(text)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
    }
}
