// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class UpstreamFailureClassTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let box = NIOLockedValueBox<[RuntimeEvent]>([])
        func record(_ event: RuntimeEvent) { box.withLockedValue { $0.append(event) } }
        func count(_ name: String) -> Int { box.withLockedValue { $0.filter { $0.event == name }.count } }
    }

    private static let attempts = 3

    func testEachFailureIsClassedByWhoseFactItIs() {
        let table: [(Error, UpstreamFailureClass)] = [
            (ConnectionPoolError.upstreamResponseTimedOut, .inconclusive),
            (ChannelError.connectTimeout(.seconds(5)), .upstream),
            (IOError(errnoCode: ECONNREFUSED, reason: "connect"), .upstream),
            (ConnectionPoolError.upstreamReturnedStatus(503, target: "example.com:443"), .upstream),
            (ConnectionPoolError.authenticationRejected, .upstream),
            (ConnectionPoolError.authHandshakeLimitExceeded, .local),
            (ConnectionPoolError.poolExhausted, .local),
            (ConnectionPoolError.vpnTransitionDuringConnect, .local),
            (ConnectionPoolError.connectionTrackingFull, .local),
        ]
        for (error, expected) in table {
            XCTAssertEqual(ConnectionPoolError.failureClass(error), expected, "\(error)")
        }
    }

    func testResponseTimeoutsOnTheExchangeAndTheTunnelLeaveTheBreakerAlone() async throws {
        let silent = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        let events = Events()
        let pool = makePool(port: try XCTUnwrap(silent.localAddress?.port), events: events)
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") }, logger: DiscardingLogSink())

        for _ in 0..<Self.attempts {
            await assertFails(with: .upstreamResponseTimedOut) {
                _ = try await pool.exchange(head: Self.head, body: nil).get()
            }
            await assertFails(with: .upstreamResponseTimedOut) {
                _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            }
        }

        XCTAssertEqual(pool.upstreamStatuses().first?.consecutiveFailures, 0)
        XCTAssertGreaterThanOrEqual(events.count("upstream.response_timeout"), Self.attempts, "each exchange still ended with its event")
        pool.closeAll()
        try await silent.close().get()
    }

    func testRefusedConnectsStillFeedTheBreaker() async throws {
        let released = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(released.localAddress?.port)
        try await released.close().get()
        let pool = makePool(port: port, events: Events())

        for _ in 0..<Self.attempts {
            do {
                _ = try await pool.exchange(head: Self.head, body: nil).get()
                XCTFail("a refused connect cannot succeed")
            } catch {}
        }

        XCTAssertEqual(pool.upstreamStatuses().first?.consecutiveFailures, Self.attempts, "each refusal is one strike")
        pool.closeAll()
    }

    func testASilentHalfOpenProbeReopensTheBreaker() async throws {
        let released = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let refusedPort = try XCTUnwrap(released.localAddress?.port)
        try await released.close().get()
        let silent = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        let events = Events()
        var config = ProxyConfig.testFixture()
        config.upstreamResponseTimeoutSeconds = 0.1
        config.circuitFailureThreshold = Self.attempts
        config.circuitBreakerWindowSeconds = 0
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: refusedPort, priority: 0)]
        let current = NIOLockedValueBox(config)
        let pool = ConnectionPool(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), configProvider: { current.withLockedValue { $0 } },
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") }, eventSink: events.record
        )
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") }, logger: DiscardingLogSink())

        for _ in 0..<Self.attempts {
            do {
                _ = try await pool.exchange(head: Self.head, body: nil).get()
                XCTFail("a refused connect cannot succeed")
            } catch {}
        }
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)
        XCTAssertEqual(events.count("upstream.circuit_opened"), 1)

        let silentPort = try XCTUnwrap(silent.localAddress?.port)
        current.withLockedValue { $0.upstreams[0].port = silentPort }
        await assertFails(with: .upstreamResponseTimedOut) {
            _ = try await pool.exchange(head: Self.head, body: nil).get()
        }
        let reopened = await eventually { events.count("upstream.circuit_opened") == 2 }
        XCTAssertTrue(reopened, "the silent exchange was the half-open probe, and the upstream was silent to the liveness probe too")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)

        await assertFails(with: .upstreamResponseTimedOut) {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
        }
        let reopenedAgain = await eventually { events.count("upstream.circuit_opened") == 3 }
        XCTAssertTrue(reopenedAgain, "the silent tunnel was the half-open probe")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)
        XCTAssertEqual(events.count("upstream.circuit_half_opened"), 2)
        pool.closeAll()
        try await silent.close().get()
    }

    private static let head: HTTPRequestHead = {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        head.headers.add(name: "Host", value: "example.com")
        return head
    }()

    private func makePool(port: Int, events: Events) -> ConnectionPool {
        var config = ProxyConfig.testFixture()
        config.upstreamResponseTimeoutSeconds = 0.1
        config.circuitFailureThreshold = Self.attempts
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: port, priority: 0)]
        return ConnectionPool(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), configProvider: { config },
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") }, eventSink: events.record
        )
    }

    private func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return condition() }
        }
        return condition()
    }

    private func assertFails(
        with expected: ConnectionPoolError, file: StaticString = #filePath, line: UInt = #line,
        _ body: () async throws -> Void
    ) async {
        do {
            try await body()
            XCTFail("expected \(expected)", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, expected, file: file, line: line)
        }
    }
}
