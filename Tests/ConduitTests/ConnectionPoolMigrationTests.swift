// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// #148, #156: an upstream dial that straddles a confirmed VPN transition
/// is closed when it completes, not inserted past it; the pool's sockets
/// are swept through the runtime's `TransitionAuthority`.
final class ConnectionPoolMigrationTests: XCTestCase {
    private let proxy = UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)

    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    private func makeAuthority() -> TransitionAuthority {
        let events = self.events
        return TransitionAuthority(capacity: { 64 }, retirementLog: ConnectFailureLog(
            logger: DiscardingLogSink(), eventSink: { event in events.withLockedValue { $0.append(event) } }
        ))
    }

    private func makePool(_ transitions: TransitionAuthority) -> ConnectionPool {
        let config = ProxyConfig.testFixture()
        let events = self.events
        return ConnectionPool(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
                              configProvider: { config },
                              authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                              eventSink: { event in events.withLockedValue { $0.append(event) } },
                              transitions: transitions)
    }

    private var retirements: [String] {
        events.withLockedValue { $0 }.filter { $0.event == LateDialRetired.event }.compactMap(\.detail)
    }

    private func dialed(local: String? = nil) throws -> PooledUpstreamConnection {
        let channel = EmbeddedChannel()
        if let local { channel.localAddress = try SocketAddress(ipAddress: local, port: 50_000) }
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 9)).wait()
        return PooledUpstreamConnection(proxy: proxy, channel: channel)
    }

    private func settle(_ connections: PooledUpstreamConnection...) {
        for connection in connections { (connection.channel as? EmbeddedChannel)?.embeddedEventLoop.run() }
    }

    func testADialCompletingAfterATransitionIsClosedAndFailsItsAcquisition() throws {
        let transitions = makeAuthority()
        let pool = makePool(transitions)
        let stamp = transitions.stamp()                       // dial starts on the VPN
        XCTAssertEqual(transitions.closeUpstream(), 0)        // the disconnect routes DIRECT
        let late = try dialed()                               // and the dial completes after

        XCTAssertThrowsError(try pool.insertDialedConnection(late, stamp: stamp, target: "http://origin.test/a?q=1")) { error in
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
            XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure(error), "never a breaker signal")
        }
        XCTAssertFalse(late.channel.isActive)
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty, "never handed to a request")
        XCTAssertEqual(retirements.count, 1, "reported when it happens, not at the next sweep")
        let detail = try XCTUnwrap(retirements.first)
        XCTAssertTrue(detail.hasPrefix("target="), detail)
        XCTAssertFalse(detail.contains("q=1"), "the target is sanitized: \(detail)")
        XCTAssertTrue(detail.contains(" upstream=127.0.0.1:9 reason=\(LateDialRetired.transition) "), detail)
    }

    func testADialStartedAfterTheTransitionIsInsertedAndTracked() throws {
        let transitions = makeAuthority()
        let pool = makePool(transitions)
        transitions.beginOutage()
        let fresh = try dialed()
        XCTAssertNoThrow(try pool.insertDialedConnection(fresh, stamp: transitions.stamp(), target: "origin.test:443"))
        XCTAssertEqual(pool.allConnectionSnapshot.count, 1)
        XCTAssertEqual(transitions.count, 1)
        XCTAssertTrue(fresh.inUse)
        pool.closeAll()
    }

    /// A stale request dials nothing: the pool refuses before connecting.
    func testAnExchangeStampedBeforeATransitionDialsNothing() async throws {
        let accepted = NIOLockedValueBox(0)
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: server.localAddress!.port!, priority: 0)]
        let transitions = makeAuthority()
        let pool = ConnectionPool(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
                                  configProvider: { config },
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                  transitions: transitions)
        let stamp = transitions.stamp()
        transitions.beginOutage()
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://origin.test/",
                                   headers: ["Host": "origin.test"])
        do {
            _ = try await pool.exchange(head: head, body: nil, stamp: stamp).get()
            XCTFail("the exchange must fail")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
        }
        do {
            _ = try await pool.makeDedicatedTunnelConnection(target: "origin.test:443", stamp: stamp).get()
            XCTFail("the tunnel must fail")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(accepted.withLockedValue { $0 }, 0, "nothing dialed")
        try await server.close().get()
    }

    /// An idempotent buffered GET whose connection the routing sweep closed
    /// fails locally instead of retrying on a fresh upstream connection:
    /// routing may have gone DIRECT (#148).
    func testAnExchangeTheSweepClosedIsNotRetriedOnAFreshUpstream() async throws {
        let accepted = NIOLockedValueBox(0)
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            // Accepts and never answers, counting connections.
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: server.localAddress!.port!, priority: 0)]
        let transitions = makeAuthority()
        let pool = ConnectionPool(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
                                  configProvider: { config },
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                  transitions: transitions)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://origin.test/",
                                   headers: ["Host": "origin.test"])
        let exchange = pool.exchange(head: head, body: nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while accepted.withLockedValue({ $0 }) == 0 || pool.allConnectionSnapshot.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(transitions.closeUpstream(), 1)

        do {
            _ = try await exchange.get()
            XCTFail("the exchange must fail")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(accepted.withLockedValue { $0 }, 1, "no fresh upstream connection")
        XCTAssertEqual(transitions.count, 0)
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty)
        try await server.close().get()
    }

    func testTheSweepClosesEstablishedConnectionsItSelectsAndThePoolDropsThem() throws {
        let transitions = makeAuthority()
        let pool = makePool(transitions)
        let overVPN = try dialed(local: "10.20.30.40"), overWiFi = try dialed(local: "192.168.2.20")
        try pool.insertDialedConnection(overVPN, stamp: transitions.stamp(), target: "origin.test:443")
        try pool.insertDialedConnection(overWiFi, stamp: transitions.stamp(), target: "origin.test:443")

        XCTAssertEqual(transitions.closeOrphaned(from: ["192.168.2.20"]).upstream, 1)
        settle(overVPN, overWiFi)
        XCTAssertFalse(overVPN.channel.isActive)
        XCTAssertTrue(overVPN.wasRetiredByVPNTransition)
        XCTAssertFalse(overWiFi.wasRetiredByVPNTransition)
        XCTAssertEqual(pool.allConnectionSnapshot.map(\.id), [overWiFi.id], "a closed socket leaves the pool at once")
        XCTAssertEqual(transitions.closeUpstream(), 1)
        settle(overWiFi)
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty)
    }

    /// A sweep that closes a dedicated tunnel mid-handshake fails the
    /// CONNECT at once, as a local failure, instead of after the response
    /// timeout, and the coordinator does not retry it on another upstream.
    func testASweepDuringTheCONNECTHandshakeFailsItPromptlyAndLocally() async throws {
        let accepted = NIOLockedValueBox(0)
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        var config = ProxyConfig.testFixture()
        config.upstreamResponseTimeoutSeconds = 30
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: server.localAddress!.port!, priority: 0),
                            UpstreamProxy(name: "second", host: "127.0.0.1", port: server.localAddress!.port!, priority: 1)]
        let transitions = makeAuthority()
        let pool = ConnectionPool(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
                                  configProvider: { config },
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                  transitions: transitions)
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                             logger: DiscardingLogSink())
        let tunnel = coordinator.connectUpstreamTunnel(target: "origin.test:443")
        let deadline = ContinuousClock.now + .seconds(3)
        while transitions.count == 0, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        let started = ContinuousClock.now
        XCTAssertEqual(transitions.closeUpstream(), 1)

        do {
            _ = try await tunnel.get()
            XCTFail("the tunnel must fail")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
        }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(5), "not the response timeout")
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(accepted.withLockedValue { $0 }, 1, "not retried on the next upstream")
        try await server.close().get()
    }
}
