// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A half-open breaker passes its upstream over until its probe settles (decision 0045), and a failure without the
/// probe cannot reopen it.
final class ProbeSettlementTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() async throws {
        try await group.shutdownGracefully()
        try await super.tearDown()
    }

    /// While a probe holds the half-open slot, silences from attempts without it leave the silence ledger alone. Had
    /// they entered it, the probe's own one-origin silence would find two origins pending and reopen the breaker.
    func testSilencesWithoutTheProbeLeaveTheLedgerToTheProbe() async throws {
        let (pool, proxy) = makeHalfOpenPool(port: 3128)
        try await waitUntilProbeMay(pool, proxy)
        let probe = try XCTUnwrap(pool.selectTunnelUpstream(excluding: []))
        XCTAssertNotNil(probe.probe, "precondition: the selection claimed the probe")

        for origin in ["a.corp.example:443", "b.corp.example:443"] {
            pool.recordExchangeError(ConnectionPoolError.upstreamResponseTimedOut, for: .forced(proxy), origin: .connect(origin))
        }
        XCTAssertEqual(state(pool, proxy), .halfOpen)
        XCTAssertNil(pool.selectTunnelUpstream(excluding: [])?.probe, "the probe still holds its slot")
        XCTAssertEqual(
            named("upstream.failure_uncharged"),
            ["upstream=U endpoint=127.0.0.1:3128 reason=probe_held suppressed=0"],
            "reported once a minute, not per silence"
        )

        pool.recordExchangeError(ConnectionPoolError.upstreamResponseTimedOut, for: probe, origin: .connect("c.corp.example:443"))
        XCTAssertEqual(state(pool, proxy), .halfOpen, "the probe's own silence is on one origin, so it does not count")
        XCTAssertNotNil(pool.selectTunnelUpstream(excluding: [])?.probe, "and its slot is free again")
    }

    // MARK: - Harness

    /// One upstream, U, whose breaker two refused connects have opened for 0.1 s.
    private func makeHalfOpenPool(port: Int) -> (ConnectionPool, UpstreamProxy) {
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "U", host: "127.0.0.1", port: port, priority: 0)]
        config.circuitBreakerWindowSeconds = 0
        config.circuitFailureThreshold = 2
        config.circuitBaseOpenIntervalSeconds = 0.1
        config.circuitMaxOpenIntervalSeconds = 0.1
        config.upstreamResponseTimeoutSeconds = 0.2
        let frozen = config, events = self.events
        let pool = ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { frozen },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        addTeardownBlock { pool.closeAll(scope: .all) }
        let proxy = frozen.enabledUpstreams[0]
        for _ in 0..<2 { pool.recordConnectFailure(for: proxy) }
        events.withLockedValue { $0.removeAll() }
        return (pool, proxy)
    }

    private func waitUntilProbeMay(_ pool: ConnectionPool, _ proxy: UpstreamProxy) async throws {
        XCTAssertEqual(state(pool, proxy), .open, "precondition: the breaker is open")
        try await Task.sleep(for: .milliseconds(150))
    }

    private func named(_ name: String) -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == name }.map { $0.detail ?? "" }
    }

    private func state(_ pool: ConnectionPool, _ proxy: UpstreamProxy) -> UpstreamCircuitState? {
        pool.upstreamStatuses().first { $0.id == proxy.id }?.circuitState
    }
}
