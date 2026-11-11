// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
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
        XCTAssertEqual(
            refusals.map(\.detail), ["target=intranet.corp.example:443 reason=not_a_doh_provider suppressed=0"],
            "refusals share one limit, whatever they asked for"
        )
    }

    /// A request for the provider with bytes after its address, or in a short,
    /// octal, hex or numeric spelling, is refused, and nothing is dialled.
    /// Darwin's `inet_aton` reads every one of them as the provider.
    func testOnlyTheProvidersOwnSpellingIsAdmittedAndNothingRidesAlongWithIt() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)
        let forged = [
            "\(Self.providerHost)\r\nX-Injected: 1", "\(Self.providerHost)\nX-Injected: 1", "\(Self.providerHost)\0X-Injected",
            "\(Self.providerHost) X-Injected", "\(Self.providerHost)\tX-Injected",
            "192.0.522", "192.522", "3221225994", "0xc000020a", "0300.0.2.10",
        ]
        // `SocketAddress` reads a leading-zero form (`192.0.02.10`) as the address and sends its four bytes, so the parse of one
        // sent as a name is pinned by `DoHSessionFactoryTests` instead.

        for host in forged {
            let reply = try await socksConnect(host: host, port: 80, to: routePort)
            XCTAssertEqual(reply, 0x02, host.debugDescription)
        }

        XCTAssertEqual(running.upstream.connectHeads(), [], "nothing was dialled for a forged spelling")
        let refusals = running.events.withLockedValue { $0 }.filter { $0.event == "dns.doh_upstream_route_refused" }
        XCTAssertEqual(refusals.map(\.detail), ["target=[192.0.2.10__X-Injected:_1]:80 reason=not_a_doh_provider suppressed=0"])
    }

    /// An admitted request is dialled as the provider the config names, not as
    /// the client spelled it, and its events are keyed by that one spelling.
    func testAnAdmittedRequestIsDialledAsTheConfiguredProvider() async throws {
        let running = try await start(provider: "http://[::ffff:\(Self.providerHost)]/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)

        for host in [Self.providerHost, "::ffff:\(Self.providerHost)"] {
            let reply = try await socksConnect(host: host, port: 80, to: routePort)
            XCTAssertEqual(reply, 0x00, host)
        }

        let heads = running.upstream.connectHeads()
        XCTAssertEqual(heads.count, 4, "two challenged CONNECTs and their answers: \(heads)")
        XCTAssertTrue(heads.allSatisfy { $0.hasPrefix("CONNECT \(Self.providerHost):80 HTTP/1.1\r\nHost: \(Self.providerHost):80\r\n") }, "\(heads)")
        let used = running.events.withLockedValue { $0 }.filter { $0.event == "dns.doh_upstream_route_used" }
        XCTAssertEqual(used.map(\.detail), ["target=\(Self.providerHost):80 upstream=127.0.0.1:\(running.upstream.port) suppressed=0"])
    }

    func testAProviderNameIsDialledInTheConfigsSpelling() async throws {
        let running = try await start(provider: "http://doh.corp.example/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)

        let reply = try await socksConnect(host: "DOH.Corp.Example.", port: 80, to: routePort)

        XCTAssertEqual(reply, 0x00)
        let heads = running.upstream.connectHeads()
        XCTAssertFalse(heads.isEmpty)
        XCTAssertTrue(heads.allSatisfy { $0.hasPrefix("CONNECT doh.corp.example:80 HTTP/1.1\r\n") }, "\(heads)")
    }

    /// The refused name is bytes a local process chose. The event shows it as
    /// one printable token, and a process that sends a new name every time
    /// gets one event a minute, not one per name.
    func testRefusalsAreReportedOnceAMinuteWithThePrintableTarget() async throws {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: Self.answerIP)
        self.upstream = upstream
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        config.dohProviders = ["http://\(Self.providerHost)/dns-query"]
        let frozen = config
        let logger = RecordingLogSink(minLevel: .debug)
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        self.pool = pool
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let route = DoHUpstreamRoute(
            source: DoHUpstreamRouteSource(
                pool: pool,
                coordinator: CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: logger)
            ),
            group: group, logger: logger, configProvider: { frozen },
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            eventGate: RuntimeEventRepeatGate(now: { clock.withLockedValue { $0 } })
        )
        try await route.start()
        let routePort = try XCTUnwrap(route.listeningPort)
        let forged = "a.corp.example\r\nWARN forged line reason=ok"

        for index in 0..<70 {
            let reply = try await socksConnect(host: "host-\(index).corp.example", port: 443, to: routePort)
            XCTAssertEqual(reply, 0x02)
        }
        clock.withLockedValue { $0 += 61 }
        _ = try await socksConnect(host: forged, port: 443, to: routePort)
        _ = try await socksConnect(host: String(repeating: "x", count: 255), port: 443, to: routePort)
        clock.withLockedValue { $0 += 61 }
        _ = try await socksConnect(host: String(repeating: "x", count: 255), port: 443, to: routePort)
        await route.stop()

        let refusals = events.withLockedValue { $0 }.filter { $0.event == "dns.doh_upstream_route_refused" }
        XCTAssertEqual(refusals.map(\.detail), [
            "target=host-0.corp.example:443 reason=not_a_doh_provider suppressed=0",
            "target=a.corp.example__WARN_forged_line_reason_ok:443 reason=not_a_doh_provider suppressed=69",
            "target=\(String(repeating: "x", count: 48))...:443 reason=not_a_doh_provider suppressed=1",
        ])
        let lines = logger.entries().map(\.message).filter { $0.contains("dns.doh_upstream_route_refused") }
        XCTAssertEqual(lines.count, 3)
        XCTAssertFalse(lines.contains { $0.contains("\n") || $0.contains("\r") }, "\(lines)")
        XCTAssertEqual(upstream.connectHeads(), [])
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

    /// A provider configured by name, with the root dot and in mixed case.
    /// CFNetwork sends the listener the name unresolved, in its own
    /// spelling, and the upstream is asked for that name.
    func testAProviderConfiguredByNameIsCarriedThroughTheRealListener() async throws {
        // The CONNECT targets are what CFNetwork sent the listener on macOS 26: lowercased with the root dot kept, and punycode.
        let cases = [
            (provider: "http://DoH.Corp.Example./dns-query", asked: "doh.corp.example.:80"),
            (provider: "http://dns.b\u{FC}cher.corp.example:8053/dns-query", asked: "dns.xn--bcher-kva.corp.example:8053"),
        ]
        for (provider, asked) in cases {
            let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: Self.answerIP)
            var config = ProxyConfig.testFixture()
            config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
            config.dohProviders = [provider]
            let frozen = config
            let logger = RecordingLogSink(minLevel: .debug)
            let pool = ConnectionPool(
                group: group, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in StubNegotiateAuthenticator() }
            )
            let events = NIOLockedValueBox<[RuntimeEvent]>([])
            let route = DoHUpstreamRoute(
                source: DoHUpstreamRouteSource(
                    pool: pool,
                    coordinator: CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: logger)
                ),
                group: group, logger: logger, configProvider: { frozen },
                eventSink: { event in events.withLockedValue { $0.append(event) } }
            )
            try await route.start()
            let delegate = ProxyChallengeRefusingDelegate(client: .doh) { event in events.withLockedValue { $0.append(event) } }
            let session = DoHSessionFactory.session(for: .upstream(port: try XCTUnwrap(route.listeningPort)), delegate: delegate)

            let url = try XCTUnwrap(URL(string: "\(provider)?name=by-name.example&type=A"))
            let result: Result<(Data, URLResponse), Error>
            do { result = .success(try await session.data(from: url)) } catch { result = .failure(error) }
            session.invalidateAndCancel()
            await route.stop()
            await upstream.stop()

            let named = events.withLockedValue { $0 }.map { "\($0.event) \($0.detail ?? "")" }
            let (data, response) = try XCTUnwrap(try? result.get(), "\(provider): \(result) \(named)")
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200, provider)
            XCTAssertTrue(String(decoding: data, as: UTF8.self).contains(Self.answerIP), provider)
            let heads = upstream.connectHeads()
            XCTAssertEqual(upstream.tunnelsOpened, 1, "\(provider): \(heads)")
            XCTAssertTrue(heads.allSatisfy { $0.hasPrefix("CONNECT \(asked) ") }, "\(provider): \(heads)")
            XCTAssertFalse(named.contains { $0.hasPrefix("dns.doh_upstream_route_refused") }, "\(provider): \(named)")
        }
    }

    // MARK: - Origin resolver

    /// One resolution asks a provider in both encodings. Through the upstream
    /// route both ride one tunnel, so the upstream is authenticated to once.
    func testAnOriginResolutionOpensOneTunnelForAProvider() async throws {
        // The delay holds each answer long enough that a second connection, if the resolver opened one, has asked for its tunnel.
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: Self.answerIP, keepAliveOrigin: .milliseconds(300))
        self.upstream = upstream
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        config.dohProviders = ["http://\(Self.providerHost)/dns-query"]
        let frozen = config
        let logger = RecordingLogSink(minLevel: .debug)
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        self.pool = pool
        let route = DoHUpstreamRoute(
            source: DoHUpstreamRouteSource(
                pool: pool,
                coordinator: CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: logger)
            ),
            group: group, logger: logger, configProvider: { frozen }, eventSink: nil
        )
        try await route.start()
        let routePort = try XCTUnwrap(route.listeningPort)
        let resolver = DoHOriginResolver(logger: logger, configProvider: { frozen }, upstreamRoutePort: { routePort })

        let address = try await resolver.resolveOrigin(host: "origin.corp.example", port: 443, on: group.next()).get()
        await route.stop()

        XCTAssertEqual(address.ipAddress, Self.answerIP)
        XCTAssertEqual(upstream.tunnelsOpened, 1, "both encodings share the route's one connection to the provider")
        XCTAssertEqual(upstream.challengesSent, 1, "one authenticated CONNECT for the resolution")
        XCTAssertGreaterThanOrEqual(upstream.tunnelRequests, 1)
    }

    // MARK: - Stop

    /// A tunnel in use closes with the forwarder, on both of its sides.
    func testStoppingTheForwarderClosesAnEstablishedTunnel() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)
        let client = try await SOCKS5TestClient.connect(to: routePort, group: group)
        try await client.greet()
        let reply = try await client.request(host: Self.providerHost, port: 80)
        XCTAssertEqual(reply, 0x00)
        XCTAssertEqual(running.upstream.tunnelsOpened, 1)
        XCTAssertEqual(running.upstream.openConnections, 1)

        await running.forwarder.stop()

        try await client.waitUntilClosed()
        XCTAssertFalse(client.channel.isActive, "the accepted connection outlived the forwarder")
        try await waitUntil { running.upstream.openConnections == 0 }
        XCTAssertEqual(running.upstream.openConnections, 0, "its tunnel to the upstream outlived the forwarder")
    }

    /// A connection that has greeted and not yet asked for a target closes
    /// too, so a request it sends afterwards reaches nothing.
    func testStoppingTheForwarderClosesAConnectionStillInItsHandshake() async throws {
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query")
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)
        let client = try await SOCKS5TestClient.connect(to: routePort, group: group)
        try await client.greet()

        await running.forwarder.stop()

        try await client.waitUntilClosed()
        XCTAssertFalse(client.channel.isActive, "the accepted connection outlived the forwarder")
        XCTAssertEqual(running.upstream.connectHeads(), [], "nothing was dialled for it")
    }

    /// A request whose upstream CONNECT is still unanswered: the stop closes
    /// the accepted connection and the upstream connection opened for it.
    func testStoppingTheForwarderClosesAConnectionWaitingOnItsUpstream() async throws {
        let silent = try await SilentUpstream.start(group: group)
        addTeardownBlock { await silent.stop() }
        let running = try await start(provider: "http://\(Self.providerHost)/dns-query", upstreamPort: silent.port)
        let routePort = try XCTUnwrap(running.forwarder.doHUpstreamRoutePort)
        let client = try await SOCKS5TestClient.connect(to: routePort, group: group)
        try await client.greet()
        try await client.sendRequest(host: Self.providerHost, port: 80)
        try await waitUntil { silent.requestsReceived == 1 }
        XCTAssertEqual(silent.requestsReceived, 1, "the CONNECT is in flight")

        await running.forwarder.stop()

        try await client.waitUntilClosed()
        XCTAssertFalse(client.channel.isActive, "the accepted connection outlived the forwarder")
        try await waitUntil { silent.openConnections == 0 }
        XCTAssertEqual(silent.openConnections, 0, "the pending upstream connection outlived the forwarder")
        XCTAssertEqual(client.receivedBytes.count, 2, "no reply was written for a tunnel that never opened")
    }

    /// The stop marks the listener stopped before it closes each connection.
    /// A request read in between closes its connection and dials nothing.
    func testARequestReadAfterTheStopBeganDialsNothing() throws {
        let loop = EmbeddedEventLoop()
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        let frozen = config
        let logger = DiscardingLogSink()
        let pool = ConnectionPool(
            group: loop, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        let outcomes = NIOLockedValueBox<[String]>([])
        let accepted = SOCKS5AcceptedConnections()
        let channel = EmbeddedChannel(handler: SOCKS5Handler(
            connectCoordinator: CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: logger),
            logger: logger, group: loop, directModeProvider: { (false, .none) }, pacRoutingEngine: nil,
            configProvider: { frozen }, gatewayMode: false,
            routing: .upstreamOnly(SOCKS5UpstreamOnlyRoute(
                authority: { host, port in "\(host):\(port)" },
                refused: { _ in outcomes.withLockedValue { $0.append("refused") } },
                opened: { _, _ in outcomes.withLockedValue { $0.append("opened") } },
                failed: { _, _ in outcomes.withLockedValue { $0.append("failed") } }
            )),
            accepted: accepted,
            onConnectionOpened: { _ in }, onConnectionClosed: { _ in }, onConnectionActivity: { _ in }
        ), loop: loop)
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).wait()
        XCTAssertTrue(accepted.track(channel))
        XCTAssertEqual(accepted.stop().count, 1)

        var bytes = channel.allocator.buffer(capacity: 16)
        bytes.writeBytes([0x05, 0x01, 0x00])
        try channel.writeInbound(bytes)
        bytes.clear()
        bytes.writeBytes([0x05, 0x01, 0x00, 0x01, 192, 0, 2, 10, 0, 80])
        try channel.writeInbound(bytes)
        loop.run()

        XCTAssertFalse(channel.isActive, "the connection is closed, not routed")
        XCTAssertEqual(outcomes.withLockedValue { $0 }, [], "the coordinator was never asked: with no upstream it would have reported a failure")
        XCTAssertEqual(try channel.readOutbound(as: ByteBuffer.self).map { Array($0.readableBytesView) }, [5, 0], "the method selection")
        XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self), "and no reply")
        XCTAssertFalse(accepted.track(EmbeddedChannel()), "a stopped listener tracks nothing new")
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    // MARK: - Harness

    private func waitUntil(_ condition: @Sendable () -> Bool) async throws {
        for _ in 0..<400 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

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
        upstreamPort: Int? = nil,
        offered: @escaping @Sendable () -> Bool = { true }
    ) async throws -> Running {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: Self.answerIP)
        self.upstream = upstream

        var config = ProxyConfig.testFixture()
        var proxy = UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstreamPort ?? upstream.port, priority: 0)
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
            upstreamRoute: offerRoute ? DoHUpstreamRouteSource(pool: pool, coordinator: coordinator, offered: offered) : nil,
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

    private func socksConnect(host: String, port: Int, to routePort: Int) async throws -> UInt8? {
        try await SOCKS5TestClient.reply(connecting: host, port: port, through: routePort, group: group)
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
        var tunnelRequests = 0
    }

    var port: Int { channel.localAddress?.port ?? 0 }
    func connectHeads() -> [String] { state.withLockedValue { $0.connectHeads } }
    var challengesSent: Int { state.withLockedValue { $0.challengesSent } }
    var tunnelsOpened: Int { state.withLockedValue { $0.tunnelsOpened } }
    func firstTunnelBytes() -> [[UInt8]] { state.withLockedValue { $0.firstTunnelBytes } }
    var openConnections: Int { children.withLockedValue { $0.count } }
    /// Requests a keep-alive origin answered, over every tunnel.
    var tunnelRequests: Int { state.withLockedValue { $0.tunnelRequests } }

    private init(channel: Channel, state: NIOLockedValueBox<State>, children: NIOLockedValueBox<[ObjectIdentifier: Channel]>) {
        self.channel = channel
        self.state = state
        self.children = children
    }

    /// - Parameter keepAliveOrigin: nil for an origin that answers the
    ///   tunnel's first request and closes. Otherwise the origin keeps the
    ///   tunnel open and answers every request on it after this delay: a
    ///   `dns-json` GET with the answer, anything else with a 400.
    static func start(group: EventLoopGroup, answerIP: String, keepAliveOrigin: TimeAmount? = nil) async throws -> AuthenticatingUpstream {
        let state = NIOLockedValueBox(State())
        let children = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                let id = ObjectIdentifier(child)
                children.withLockedValue { if $0.count < 256 { $0[id] = child } }
                child.closeFuture.whenComplete { _ in children.withLockedValue { $0[id] = nil } }
                return child.pipeline.addHandler(Session(state: state, answerIP: answerIP, keepAliveOrigin: keepAliveOrigin))
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
        private let keepAliveOrigin: TimeAmount?
        private var phase = Phase.challenge
        private var accumulated = ByteBufferAllocator().buffer(capacity: 1024)

        init(state: NIOLockedValueBox<State>, answerIP: String, keepAliveOrigin: TimeAmount?) {
            self.state = state
            self.answerIP = answerIP
            self.keepAliveOrigin = keepAliveOrigin
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
            case .tunnel where keepAliveOrigin != nil:
                accumulated.writeBuffer(&buffer)
                answerKeptAliveRequests(context: context)
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

        /// Answers each complete request in `accumulated`, in order, after the delay.
        private func answerKeptAliveRequests(context: ChannelHandlerContext) {
            guard let delay = keepAliveOrigin else { return }
            while let text = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
                  let headEnd = text.range(of: "\r\n\r\n") {
                let head = String(text[..<headEnd.lowerBound])
                let bodyLength = head.split(separator: "\r\n")
                    .first { $0.lowercased().hasPrefix("content-length:") }
                    .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
                let total = head.utf8.count + 4 + bodyLength
                guard accumulated.readableBytes >= total else { return }
                accumulated.moveReaderIndex(forwardBy: total)
                state.withLockedValue { $0.tunnelRequests += 1 }
                let body = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"\#(answerIP)"}]}"#
                let response = head.hasPrefix("GET ")
                    ? "HTTP/1.1 200 OK\r\nContent-Type: application/dns-json\r\nContent-Length: \(body.utf8.count)\r\n\r\n\(body)"
                    : "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                nonisolated(unsafe) let context = context
                context.eventLoop.scheduleTask(in: delay) { self.write(response, context: context) }
            }
        }

        private func write(_ text: String, context: ChannelHandlerContext) {
            var out = context.channel.allocator.buffer(capacity: text.utf8.count)
            out.writeString(text)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
    }
}

/// An upstream that accepts a connection, reads what it is sent and never answers.
final class SilentUpstream: Sendable {
    private let channel: Channel
    /// Accepted connections, at most 64, so `stop` can close them.
    private let children: NIOLockedValueBox<[ObjectIdentifier: Channel]>
    private let requests: NIOLockedValueBox<Int>

    var port: Int { channel.localAddress?.port ?? 0 }
    var openConnections: Int { children.withLockedValue { $0.count } }
    var requestsReceived: Int { requests.withLockedValue { $0 } }

    private init(channel: Channel, children: NIOLockedValueBox<[ObjectIdentifier: Channel]>, requests: NIOLockedValueBox<Int>) {
        self.channel = channel
        self.children = children
        self.requests = requests
    }

    static func start(group: EventLoopGroup) async throws -> SilentUpstream {
        let children = NIOLockedValueBox<[ObjectIdentifier: Channel]>([:])
        let requests = NIOLockedValueBox(0)
        let channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { child in
                let id = ObjectIdentifier(child)
                children.withLockedValue { if $0.count < 64 { $0[id] = child } }
                child.closeFuture.whenComplete { _ in children.withLockedValue { $0[id] = nil } }
                return child.pipeline.addHandler(Counter(requests: requests))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        return SilentUpstream(channel: channel, children: children, requests: requests)
    }

    func stop() async {
        do {
            try await channel.close().get()
        } catch ChannelError.alreadyClosed {
        } catch {
            XCTFail("silent upstream close failed: \(error)")
        }
        for child in children.withLockedValue({ Array($0.values) }) {
            child.close(promise: nil)
        }
    }

    private final class Counter: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let requests: NIOLockedValueBox<Int>
        private var counted = false
        init(requests: NIOLockedValueBox<Int>) { self.requests = requests }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            guard !counted else { return }
            counted = true
            requests.withLockedValue { $0 += 1 }
        }
    }
}
