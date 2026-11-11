// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A half-open breaker passes its upstream over until its probe settles (decision 0045), and since a failure without
/// the probe cannot reopen it, a probe that never settles keeps the upstream out of selection for good. A streamed
/// probe settles at its response head, and a challenge whose body stalls times out.
final class ProbeSettlementTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var upstreams: [RawResponseUpstream] = []
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() async throws {
        for upstream in upstreams { try await upstream.stop() }
        try await group.shutdownGracefully()
        try await super.tearDown()
    }

    /// The probe is a long download: its head arrives and its body does not end. The head is the probe's verdict, so
    /// the breaker closes while the body still streams and the next request may use the upstream.
    func testAStreamedProbeClosesTheBreakerAtItsResponseHead() async throws {
        let upstream = try await startUpstream { _ in "HTTP/1.1 200 OK\r\nContent-Length: 100000\r\n\r\nfirst bytes" }
        let (pool, proxy) = makeHalfOpenPool(port: upstream.port)
        try await waitUntilProbeMay(pool, proxy)

        let client = try await StreamingClientSink.make(group: group)
        let download = pool.startStreamingExchange(head: Self.head("http://files.corp.example/large"), requestBody: nil, clientChannel: client.channel)
        try await waitFor("the breaker closes once the probe's head arrives") { self.state(pool, proxy) == .closed }

        let next = try XCTUnwrap(pool.selectTunnelUpstream(excluding: []))
        XCTAssertEqual(next.proxy.id, proxy.id)
        XCTAssertNil(next.probe, "a closed breaker has no probe to claim")
        XCTAssertEqual(named("upstream.circuit_closed"), ["upstream=U endpoint=127.0.0.1:\(upstream.port) reason=probe_success"])

        pool.closeAll(scope: .all)
        do {
            _ = try await download.result.get()
            XCTFail("the download was cut off by closeAll")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isStreamingResponseInterrupted(error), "\(error)")
        }
        await client.close()
    }

    /// The probe meets a 407 whose body never arrives. It times out as a silence, which on one origin does not
    /// count, so the probe slot is given back and the next request probes again.
    func testAChallengeWhoseBodyStallsTimesOutAndSettlesTheProbe() async throws {
        let upstream = try await startUpstream { _ in
            "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 64\r\n\r\n"
        }
        let (pool, proxy) = makeHalfOpenPool(port: upstream.port)
        try await waitUntilProbeMay(pool, proxy)

        let exchange = pool.exchange(head: Self.head("http://a.corp.example/"), body: nil)
        do {
            _ = try await within(seconds: 3, exchange)
            XCTFail("a 407 with no body cannot be answered")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
        }

        XCTAssertEqual(named("upstream.probe_released").count, 1, "the probe settled: \(events.withLockedValue { $0.map(\.event) })")
        XCTAssertEqual(state(pool, proxy), .halfOpen)
        XCTAssertNotNil(pool.selectTunnelUpstream(excluding: [])?.probe, "the next request probes again")
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

    private static func head(_ uri: String) -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
        head.headers.add(name: "Host", value: URL(string: uri)?.host ?? uri)
        return head
    }

    private func startUpstream(_ script: @escaping @Sendable (String) -> String?) async throws -> RawResponseUpstream {
        let upstream = RawResponseUpstream(script)
        try await upstream.start(group: group)
        upstreams.append(upstream)
        return upstream
    }

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

    private func waitFor(_ what: String, _ condition: @escaping () -> Bool) async throws {
        for _ in 0..<200 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what)
    }

    private func within<T: Sendable>(seconds: Int64, _ future: EventLoopFuture<T>) async throws -> T {
        let promise = group.next().makePromise(of: T.self)
        future.cascade(to: promise)
        let deadline = group.next().scheduleTask(in: .seconds(seconds)) { promise.fail(DeadlineElapsed()) }
        defer { deadline.cancel() }
        return try await promise.futureResult.get()
    }

    private func named(_ name: String) -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == name }.map { $0.detail ?? "" }
    }

    private func state(_ pool: ConnectionPool, _ proxy: UpstreamProxy) -> UpstreamCircuitState? {
        pool.upstreamStatuses().first { $0.id == proxy.id }?.circuitState
    }
}

private struct DeadlineElapsed: Error {}
