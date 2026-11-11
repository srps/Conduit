// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A dial that fails on this machine charges no breaker (decision 0045), so on its own it would leave an upstream that
/// can never be dialled from here (an IPv6-only upstream on an IPv4-only network, a route gone for good) preferred
/// forever for its latency score. The pool passes such an upstream over while another may be asked, and a plain-HTTP
/// request whose dial failed locally goes to another upstream, since none of its bytes reached any.
///
/// P is `127.0.0.1:0`: macOS fails a dial to port 0 with `EADDRNOTAVAIL`, a local dial failure, on every attempt.
final class LocallyUnreachableUpstreamTests: XCTestCase {
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

    /// P has the better latency score and fails every dial locally; S answers. Every request, buffered or streamed,
    /// is answered through S, from the first one on. P is not picked again until its re-check interval has passed,
    /// and its breaker stays closed throughout.
    func testAnUpstreamThatFailsEveryDialLocallyIsPassedOverAndPlainHTTPFailsOver() async throws {
        let s = try await startUpstream { _ in "HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok" }
        let (pool, p, sProxy) = makeTwoUpstreamPool(sPort: s.port, recheck: 0.5)

        let first = try await pool.exchange(head: Self.head("http://a.corp.example/"), body: nil).get()
        XCTAssertEqual(first.upstream.id, sProxy.id, "the first request failed over to S")
        XCTAssertEqual(named("upstream.locally_unreachable").count, 1)
        XCTAssertEqual(
            named("upstream.failure_uncharged").first,
            "upstream=P endpoint=127.0.0.1:0 reason=local_dial errno=EADDRNOTAVAIL suppressed=0"
        )

        for _ in 0..<2 {
            let answered = try await pool.exchange(head: Self.head("http://a.corp.example/"), body: nil).get()
            XCTAssertEqual(answered.upstream.id, sProxy.id)
        }
        let client = try await StreamingClientSink.make(group: group)
        let streamed = pool.startStreamingExchange(head: Self.head("http://b.corp.example/"), requestBody: nil, clientChannel: client.channel)
        let result = try await streamed.result.get()
        await client.close()
        XCTAssertEqual(result.upstream.id, sProxy.id)
        XCTAssertEqual(streamed.upstream?.id, sProxy.id, "the attempt names the upstream it dialled")
        scoreSlow(pool, sProxy)
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, sProxy.id, "P is passed over until its re-check")
        XCTAssertEqual(named("upstream.locally_unreachable").count, 1, "P was not dialled again: \(named("upstream.locally_unreachable"))")
        XCTAssertEqual(s.requestLines.count, 4)

        try await Task.sleep(for: .milliseconds(600))
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, p.id, "after the re-check interval P is asked again")
        XCTAssertEqual(state(pool, p), .closed, "nothing was charged to P")
    }

    /// With one upstream there is nothing to fail over to: the request fails with the local error, the upstream is
    /// still dialled on the next request, and its breaker stays closed.
    func testWithOneUpstreamALocalFailureFailsTheRequestAndTheUpstreamIsStillDialled() async throws {
        let config = configBox([UpstreamProxy(name: "P", host: "127.0.0.1", port: 0, priority: 0)], recheck: 300)
        let pool = makePool(config)
        let p = config.withLockedValue { $0.enabledUpstreams[0] }

        for _ in 0..<2 {
            await assertLocalAddressFailure { try await pool.exchange(head: Self.head("http://a.corp.example/"), body: nil).get() }
        }
        for _ in 0..<2 {
            let client = try await StreamingClientSink.make(group: group)
            let streamed = pool.startStreamingExchange(head: Self.head("http://a.corp.example/"), requestBody: nil, clientChannel: client.channel)
            await assertLocalAddressFailure { try await streamed.result.get() }
            await client.close()
            XCTAssertEqual(streamed.upstream?.id, p.id)
        }

        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, p.id, "the only upstream is still selected")
        XCTAssertEqual(state(pool, p), .closed)
        XCTAssertEqual(named("upstream.locally_unreachable").count, 1, "reported once, not on every dial")
    }

    /// A flap reset and a success each make P selectable again, each with `upstream.locally_reachable`.
    func testAFlapResetOrASuccessMakesALocallyUnreachableUpstreamSelectableAgain() async throws {
        let s = try await startUpstream { _ in "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }
        let (pool, p, sProxy) = makeTwoUpstreamPool(sPort: s.port, recheck: 300)

        _ = try await pool.exchange(head: Self.head("http://a.corp.example/"), body: nil).get()
        scoreSlow(pool, sProxy)
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, sProxy.id, "precondition: P is passed over")

        pool.resetCircuitsAfterFlap()
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, p.id, "the reset makes P selectable at once")
        XCTAssertEqual(named("upstream.locally_reachable"), ["upstream=P endpoint=127.0.0.1:0 reason=reset_vpn_flap"])

        _ = try await pool.exchange(head: Self.head("http://a.corp.example/"), body: nil).get()
        scoreSlow(pool, sProxy)
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, sProxy.id, "P failed locally again")
        pool.recordDedicatedTunnelSuccess(for: p, latencyMS: 1)
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, p.id, "a success makes P selectable at once")
        XCTAssertEqual(named("upstream.locally_reachable").last, "upstream=P endpoint=127.0.0.1:0 reason=success")
    }

    /// A prewarm whose dial fails locally charges nothing and passes the upstream over, as a request's would.
    func testAPrewarmThatFailsLocallyChargesNothingAndPassesTheUpstreamOver() async throws {
        let s = try await startUpstream { _ in "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n" }
        let (pool, p, sProxy) = makeTwoUpstreamPool(sPort: s.port, recheck: 300)

        await pool.prewarmConnections(perUpstream: 3)
        scoreSlow(pool, sProxy)

        XCTAssertEqual(state(pool, p), .closed, "three local failures against a threshold of two charged nothing")
        XCTAssertEqual(named("upstream.locally_unreachable"), ["upstream=P endpoint=127.0.0.1:0 errno=EADDRNOTAVAIL recheckAfter=300s"])
        XCTAssertEqual(pool.selectTunnelUpstream(excluding: [])?.proxy.id, sProxy.id)
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

    private func configBox(_ upstreams: [UpstreamProxy], recheck: TimeInterval) -> NIOLockedValueBox<ProxyConfig> {
        var config = ProxyConfig.testFixture()
        config.upstreams = upstreams
        config.circuitBreakerWindowSeconds = 0
        config.circuitFailureThreshold = 2
        config.circuitBaseOpenIntervalSeconds = recheck
        config.circuitMaxOpenIntervalSeconds = max(recheck, 1)
        return NIOLockedValueBox(config)
    }

    private func makePool(_ config: NIOLockedValueBox<ProxyConfig>) -> ConnectionPool {
        let events = self.events
        let pool = ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { config.withLockedValue { $0 } },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        addTeardownBlock { pool.closeAll(scope: .all) }
        return pool
    }

    /// P first, with a warmed latency score S lacks, so the chooser prefers P whenever both may be asked.
    private func makeTwoUpstreamPool(sPort: Int, recheck: TimeInterval) -> (ConnectionPool, UpstreamProxy, UpstreamProxy) {
        let config = configBox([
            UpstreamProxy(name: "P", host: "127.0.0.1", port: 0, priority: 0),
            UpstreamProxy(name: "S", host: "127.0.0.1", port: sPort, priority: 1),
        ], recheck: recheck)
        let pool = makePool(config)
        let proxies = config.withLockedValue { $0.enabledUpstreams }
        pool.recordDedicatedTunnelSuccess(for: proxies[0], latencyMS: 1)
        events.withLockedValue { $0.removeAll() }
        return (pool, proxies[0], proxies[1])
    }

    /// Gives S a latency score far behind P's, so a selection that picks S did so because P was passed over.
    private func scoreSlow(_ pool: ConnectionPool, _ s: UpstreamProxy) {
        pool.recordDedicatedTunnelSuccess(for: s, latencyMS: 1_000)
    }

    private func named(_ name: String) -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == name }.map { $0.detail ?? "" }
    }

    private func state(_ pool: ConnectionPool, _ proxy: UpstreamProxy) -> UpstreamCircuitState? {
        pool.upstreamStatuses().first { $0.id == proxy.id }?.circuitState
    }

    private func assertLocalAddressFailure<T>(
        file: StaticString = #filePath, line: UInt = #line, _ body: () async throws -> T
    ) async {
        do {
            _ = try await body()
            XCTFail("a dial to port 0 connected", file: file, line: line)
        } catch {
            XCTAssertEqual(ConnectionPoolError.localDialFailureCodes(error), "EADDRNOTAVAIL", "\(error)", file: file, line: line)
        }
    }
}
