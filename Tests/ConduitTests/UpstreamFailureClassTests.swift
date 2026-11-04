// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// #197: an upstream that connected and then said nothing within
/// `upstreamResponseTimeout` is inconclusive, so it never feeds the breaker.
/// A refused or missed connect still does. Strikes are read from the
/// breaker's count: its burst window keeps it from opening within a test.
final class UpstreamFailureClassTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let box = NIOLockedValueBox<[RuntimeEvent]>([])
        func record(_ event: RuntimeEvent) { box.withLockedValue { $0.append(event) } }
        func count(_ name: String) -> Int { box.withLockedValue { $0.filter { $0.event == name }.count } }
    }

    private static let attempts = 3

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
