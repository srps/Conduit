// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// #148: an upstream dial that straddles a confirmed-VPN-transition sweep is
/// judged by that sweep when it completes, not inserted past it.
final class ConnectionPoolMigrationTests: XCTestCase {
    private let proxy = UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)

    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    private func makePool() -> ConnectionPool {
        let config = ProxyConfig.testFixture()
        let events = self.events
        return ConnectionPool(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
                              configProvider: { config },
                              authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                              eventSink: { event in events.withLockedValue { $0.append(event) } })
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

    func testADialCompletingAfterTheDirectRoutingSweepIsClosedAndFailsItsAcquisition() throws {
        let pool = makePool()
        let dialEpoch = pool.transitionEpoch                  // dial starts on the VPN
        XCTAssertEqual(pool.closeConnections(migrating: .all), 0)
        let late = try dialed()                               // and completes after the sweep

        XCTAssertThrowsError(try pool.insertDialedConnection(late, dialEpoch: dialEpoch, target: "http://origin.test/a?q=1")) { error in
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
            XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure(error), "never a breaker signal")
        }
        XCTAssertFalse(late.channel.isActive)
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty, "never handed to a request")
        XCTAssertEqual(retirements.count, 1, "reported when it happens, not at the next sweep")
        let detail = try XCTUnwrap(retirements.first)
        XCTAssertTrue(detail.hasPrefix("target="), detail)
        XCTAssertFalse(detail.contains("q=1"), "the target is sanitized: \(detail)")
        XCTAssertTrue(detail.contains(" upstream=127.0.0.1:9 reason=the upstream dial completed after the disconnect sweep switched routing DIRECT "), detail)
    }

    func testALateDialIsJudgedByTheAddressSweepItStraddled() throws {
        let pool = makePool()
        let dialEpoch = pool.transitionEpoch
        pool.closeConnections(migrating: .orphanedFrom(["192.168.2.20"]))
        let oldPath = try dialed(local: "10.20.30.40")
        let newPath = try dialed(local: "192.168.2.20")

        XCTAssertThrowsError(try pool.insertDialedConnection(oldPath, dialEpoch: dialEpoch, target: "origin.test:443"))
        XCTAssertNoThrow(try pool.insertDialedConnection(newPath, dialEpoch: dialEpoch, target: "origin.test:443"))
        XCTAssertEqual(pool.allConnectionSnapshot.map(\.id), [newPath.id])
        XCTAssertTrue(newPath.inUse)
        pool.closeAll()
    }

    func testADialStartedAfterTheSweepIsInserted() throws {
        let pool = makePool()
        pool.closeConnections(migrating: .all)
        let fresh = try dialed()
        XCTAssertNoThrow(try pool.insertDialedConnection(fresh, dialEpoch: pool.transitionEpoch, target: "origin.test:443"))
        XCTAssertEqual(pool.allConnectionSnapshot.count, 1)
        pool.closeAll()
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
        let pool = ConnectionPool(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
                                  configProvider: { config },
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") })
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://origin.test/",
                                   headers: ["Host": "origin.test"])
        let exchange = pool.exchange(head: head, body: nil)
        let deadline = ContinuousClock.now + .seconds(3)
        while accepted.withLockedValue({ $0 }) == 0 || pool.allConnectionSnapshot.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(pool.closeConnections(migrating: .all), 1)

        do {
            _ = try await exchange.get()
            XCTFail("the exchange must fail")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .vpnTransitionDuringConnect)
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(accepted.withLockedValue { $0 }, 1, "no fresh upstream connection")
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty)
        try await server.close().get()
    }

    func testTheSweepClosesEstablishedConnectionsItSelects() throws {
        let pool = makePool()
        let overVPN = try dialed(local: "10.20.30.40"), overWiFi = try dialed(local: "192.168.2.20")
        try pool.insertDialedConnection(overVPN, dialEpoch: pool.transitionEpoch, target: "origin.test:443")
        try pool.insertDialedConnection(overWiFi, dialEpoch: pool.transitionEpoch, target: "origin.test:443")

        XCTAssertEqual(pool.closeConnections(migrating: .orphanedFrom(["192.168.2.20"])), 1)
        XCTAssertFalse(overVPN.channel.isActive)
        XCTAssertEqual(pool.allConnectionSnapshot.map(\.id), [overWiFi.id])
        XCTAssertEqual(pool.closeConnections(migrating: .all), 1)
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty)
    }
}
