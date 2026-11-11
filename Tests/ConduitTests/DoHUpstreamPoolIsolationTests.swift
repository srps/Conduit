// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The DoH upstream route dials through a pool of its own (decision 0045).
/// Driven on the real runtime: its forwarder, its route listener and its
/// pools, against two upstreams that refuse the DoH provider.
final class DoHUpstreamPoolIsolationTests: XCTestCase {
    private static let provider = (host: "192.0.2.10", port: 80)

    private let group = MultiThreadedEventLoopGroup.singleton
    private var upstreams: [Channel] = []

    override func tearDown() async throws {
        for upstream in upstreams { try await upstream.close().get() }
        upstreams = []
        try await super.tearDown()
    }

    /// A proxy that blocks DoH by policy answers 403 to every CONNECT for a
    /// provider. The tunnels' pool, which the transparent proxy shares, keeps
    /// the breaker state and the preferred upstream it had.
    @RuntimeActor func testAnUpstreamThatRefusesDoHLeavesTheTunnelPoolsHealthAndPreferenceAlone() async throws {
        let running = try await start(answering: 403)
        let tunnels = running.orchestrator.tunnelConnectionPool
        // State the tunnels' own traffic left: Primary's breaker open, Secondary carrying.
        let primary = running.orchestrator.config.enabledUpstreams[0]
        for _ in 0..<running.orchestrator.config.circuitFailureThreshold { tunnels.recordDedicatedTunnelFailure(for: primary) }
        XCTAssertEqual(tunnels.switchToNextUpstream(), running.orchestrator.config.enabledUpstreams[1].endpoint)
        let before = Health(of: tunnels)
        XCTAssertEqual(before.circuits, [.open, .closed], "precondition")

        for _ in 0..<(running.orchestrator.config.circuitFailureThreshold + 1) {
            let reply = try await SOCKS5TestClient.reply(
                connecting: Self.provider.host, port: Self.provider.port, through: running.routePort, group: group
            )
            XCTAssertEqual(reply, 0x05, "both upstreams refused the provider")
        }

        XCTAssertGreaterThanOrEqual(running.refusals.withLockedValue { $0 }, 2 * running.orchestrator.config.circuitFailureThreshold,
                                    "every lookup asked both upstreams")
        XCTAssertEqual(Health(of: tunnels), before)
        let opened = running.orchestrator.eventLog.events.filter { $0.event == "upstream.circuit_opened" }
        XCTAssertEqual(opened.count, 1, "only the one the test opened: \(opened.map(\.detail))")
        await stop(running)
    }

    /// The upstream answered, so a 4xx says what it thinks of the target, not
    /// how healthy it is: the route's own pool counts nothing either.
    @RuntimeActor func testAPolicyRefusalOpensNoBreakerInTheRoutesOwnPool() async throws {
        let running = try await start(answering: 403)

        for _ in 0..<(running.orchestrator.config.circuitFailureThreshold + 1) {
            _ = try await SOCKS5TestClient.reply(
                connecting: Self.provider.host, port: Self.provider.port, through: running.routePort, group: group
            )
        }

        let pool = running.orchestrator.dohUpstreamPool
        let health = Health(of: pool)
        XCTAssertEqual(health.circuits, [.closed, .closed])
        XCTAssertEqual(health.consecutiveFailures, [0, 0])

        // Closed and unmoved would also be the state of a pool the route never dialled through. With both breakers open, a
        // lookup forces each into a half-open probe; the 403 that answers it is seen by this pool, frees the probe and counts nothing.
        for proxy in running.orchestrator.config.enabledUpstreams {
            for _ in 0..<running.orchestrator.config.circuitFailureThreshold { pool.recordDedicatedTunnelFailure(for: proxy) }
        }
        XCTAssertEqual(Health(of: pool).circuits, [.open, .open], "precondition")
        let reply = try await SOCKS5TestClient.reply(
            connecting: Self.provider.host, port: Self.provider.port, through: running.routePort, group: group
        )
        XCTAssertEqual(reply, 0x05)
        let released = running.orchestrator.eventLog.events.filter { $0.event == "upstream.probe_released" }
        XCTAssertEqual(released.map { $0.detail ?? "" }.sorted(), running.orchestrator.config.enabledUpstreams.map {
            "upstream=\($0.name) endpoint=\($0.endpoint) origin=\(Self.provider.host):\(Self.provider.port) answered=403 pool=doh"
        }.sorted(), "each upstream's probe met the route's 403 in the route's own pool")
        XCTAssertEqual(Health(of: pool).circuits, [.halfOpen, .halfOpen])
        await stop(running)
    }

    /// A 5xx is the upstream failing. It counts in the route's pool, is
    /// reported with that pool's name, and still moves nothing else.
    @RuntimeActor func testAServerErrorCountsInTheRoutesOwnPoolOnly() async throws {
        let running = try await start(answering: 502)
        let before = Health(of: running.orchestrator.tunnelConnectionPool)

        for _ in 0..<running.orchestrator.config.circuitFailureThreshold {
            _ = try await SOCKS5TestClient.reply(
                connecting: Self.provider.host, port: Self.provider.port, through: running.routePort, group: group
            )
        }

        XCTAssertEqual(Health(of: running.orchestrator.dohUpstreamPool).circuits, [.open, .open])
        XCTAssertEqual(Health(of: running.orchestrator.tunnelConnectionPool), before)
        let opened = running.orchestrator.eventLog.events.filter { $0.event == "upstream.circuit_opened" }
        XCTAssertEqual(opened.count, 2)
        XCTAssertTrue(opened.allSatisfy { $0.detail?.hasSuffix(" pool=doh") == true }, "\(opened.map(\.detail))")
        await stop(running)
    }

    /// Breakers the route's pool opened on the old path are closed when the
    /// VPN comes back, so the first lookup on the new path tries the
    /// preferred upstream again.
    @RuntimeActor func testAFlapRecoveryClosesTheRoutesOwnBreakers() async throws {
        let running = try await start(answering: 502)
        let pool = running.orchestrator.dohUpstreamPool
        for _ in 0..<running.orchestrator.config.circuitFailureThreshold {
            _ = try await SOCKS5TestClient.reply(
                connecting: Self.provider.host, port: Self.provider.port, through: running.routePort, group: group
            )
        }
        XCTAssertEqual(Health(of: pool).circuits, [.open, .open], "precondition")

        await running.orchestrator.handleVPNStateChange(.reasserting)
        await running.orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(Health(of: pool).circuits, [.closed, .closed])
        await stop(running)
    }

    // MARK: - Harness

    private struct Health: Equatable {
        let circuits: [UpstreamCircuitState]
        let consecutiveFailures: [Int]
        let active: String?

        init(of pool: ConnectionPool) {
            let statuses = pool.upstreamStatuses()
            circuits = statuses.map(\.circuitState)
            consecutiveFailures = statuses.map(\.consecutiveFailures)
            active = pool.activeUpstream()
        }
    }

    private struct Running {
        let orchestrator: ProxyOrchestrator
        let routePort: Int
        /// CONNECTs for the provider that an upstream refused.
        let refusals: NIOLockedValueBox<Int>
    }

    /// The runtime with the proxy and the DNS forwarder running, the VPN
    /// connected, and two upstreams that pass the reachability probe and
    /// answer every other CONNECT with `status`.
    @RuntimeActor private func start(answering status: Int) async throws -> Running {
        let refusals = NIOLockedValueBox(0)
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dohProviders = ["http://\(Self.provider.host)/dns-query"]
        // The tests open breakers with back-to-back failures.
        config.circuitBreakerWindowSeconds = 0
        config.upstreams = []
        for (index, name) in ["Primary", "Secondary"].enumerated() {
            let upstream = try await ServerBootstrap(group: group)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { $0.pipeline.addHandler(RefusingUpstream(status: status, refusals: refusals)) }
                .bind(host: "127.0.0.1", port: 0).get()
            upstreams.append(upstream)
            config.upstreams.append(
                UpstreamProxy(name: name, host: "127.0.0.1", port: try XCTUnwrap(upstream.localAddress?.port), priority: index)
            )
        }
        let orchestrator = ProxyOrchestrator(
            config: config, logger: DiscardingLogSink(), authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        return Running(
            orchestrator: orchestrator,
            routePort: try XCTUnwrap(orchestrator.dnsForwarder.doHUpstreamRoutePort, "the route is offered with the VPN connected"),
            refusals: refusals
        )
    }

    @RuntimeActor private func stop(_ running: Running) async {
        await running.orchestrator.stopDNS()
        await running.orchestrator.stopProxy()
    }
}

/// Answers the reachability probe's CONNECT with a Negotiate 407, which the
/// probe counts as a usable proxy, and every other CONNECT with `status`.
private final class RefusingUpstream: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let status: Int
    private let refusals: NIOLockedValueBox<Int>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    init(status: Int, refusals: NIOLockedValueBox<Int>) {
        self.status = status
        self.refusals = refusals
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let head = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              head.contains("\r\n\r\n") else { return }
        accumulated.clear()
        let response: String
        if head.hasPrefix("CONNECT example.com:443 ") {
            response = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n"
        } else {
            refusals.withLockedValue { $0 += 1 }
            response = "HTTP/1.1 \(status) Refused\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}

/// `AnsweredStatusAccounting.serverErrorsOnly`, on a pool alone.
final class AnsweredStatusAccountingTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton

    private func makePool(
        _ accounting: AnsweredStatusAccounting, events: NIOLockedValueBox<[RuntimeEvent]> = NIOLockedValueBox([])
    ) -> (pool: ConnectionPool, proxy: UpstreamProxy, threshold: Int) {
        var config = ProxyConfig.testFixture()
        config.circuitBreakerWindowSeconds = 0
        config.upstreams = [UpstreamProxy(name: "corp", host: "192.0.2.1", port: 8080, priority: 0)]
        let frozen = config
        let pool = ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { frozen },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() },
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            answeredStatusAccounting: accounting, label: "doh"
        )
        return (pool, frozen.enabledUpstreams[0], frozen.circuitFailureThreshold)
    }

    private func refuse(_ status: Int, _ pool: ConnectionPool, _ proxy: UpstreamProxy, times: Int) {
        for _ in 0..<times {
            pool.recordExchangeError(
                ConnectionPoolError.upstreamReturnedStatus(status, target: "192.0.2.10:443"),
                for: proxy, origin: .connect("192.0.2.10:443")
            )
        }
    }

    func testEveryStatusCountsByDefault() {
        let (pool, proxy, threshold) = makePool(.everyStatus)
        refuse(403, pool, proxy, times: threshold)
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open])
    }

    func testA4xxCountsNothingAndA5xxCounts() {
        let (pool, proxy, threshold) = makePool(.serverErrorsOnly)
        for status in [400, 403, 404, 451, 499] { refuse(status, pool, proxy, times: threshold) }
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.closed])
        XCTAssertEqual(pool.upstreamStatuses().map(\.consecutiveFailures), [0])

        refuse(502, pool, proxy, times: threshold)
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open])
    }

    /// A rejected authentication is not a policy on the target: it counts.
    func testARejectedAuthenticationStillCounts() {
        let (pool, proxy, threshold) = makePool(.serverErrorsOnly)
        for _ in 0..<threshold {
            pool.recordExchangeError(ConnectionPoolError.authenticationRejected, for: proxy, origin: .connect("192.0.2.10:443"))
        }
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open])
    }

    /// The half-open probe that meets a 4xx neither closes the breaker nor
    /// reopens it, and gives its slot back so the next request probes.
    func testA4xxOnTheHalfOpenProbeFreesTheProbeSlot() throws {
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let (pool, proxy, threshold) = makePool(.serverErrorsOnly, events: events)
        defer { pool.closeAll() }
        refuse(502, pool, proxy, times: threshold)
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open])
        // The only upstream is open, so selecting it forces the half-open probe.
        _ = pool.makeDedicatedTunnelConnection()
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.halfOpen])

        refuse(403, pool, proxy, times: 1)

        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.halfOpen])
        let released = events.withLockedValue { $0 }.filter { $0.event == "upstream.probe_released" }
        XCTAssertEqual(released.map(\.detail), ["upstream=corp endpoint=192.0.2.1:8080 origin=192.0.2.10:443 answered=403 pool=doh"])
        refuse(502, pool, proxy, times: 1)
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open], "the freed probe's failure reopens it")
    }
}
