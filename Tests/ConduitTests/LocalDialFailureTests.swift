// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A dial that fails on this machine (no route to the upstream's network, no local address, out of descriptors or
/// buffers) says nothing about the upstream. During a VPN flap such a gap must not open a healthy upstream's breaker,
/// in a tunnel's dial or a pooled exchange's, and a half-open probe that meets one gives its slot back. A refused
/// connect, a timeout and a host-unreachable still count.
final class LocalDialFailureTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton

    func testALocalDialFailureChargesNothingAndARefusalStillDoes() {
        let (pool, _) = makePool(port: 3128)
        let local: [Int32] = [ENETUNREACH, ENETDOWN, EADDRNOTAVAIL, EMFILE, ENFILE, ENOBUFS, ENOMEM]
        for code in local {
            for _ in 0..<3 { charge(pool, IOError(errnoCode: code, reason: "connect")) }
            XCTAssertEqual(state(pool), .closed, "errno \(code) is this machine's, not the upstream's")
        }
        for (name, error) in [
            ("ECONNREFUSED", IOError(errnoCode: ECONNREFUSED, reason: "connect") as Error),
            ("ETIMEDOUT", IOError(errnoCode: ETIMEDOUT, reason: "connect")),
            ("connect timeout", ChannelError.connectTimeout(.seconds(1))),
            ("EHOSTUNREACH", IOError(errnoCode: EHOSTUNREACH, reason: "connect")),
        ] {
            pool.resetCircuitsAfterFlap()
            for _ in 0..<2 { charge(pool, error) }
            XCTAssertEqual(state(pool), .open, "\(name) is the upstream's and counts")
        }
    }

    /// The half-open probe meets a dial with no route: the slot is free for the next request, and a refusal then
    /// reopens the breaker.
    func testAProbeThatMeetsNoRouteGivesItsSlotBack() async throws {
        let (pool, p) = makePool(port: 3128, openInterval: 0.05)
        for _ in 0..<2 { pool.recordConnectFailure(for: p) }
        try await Task.sleep(for: .milliseconds(100))

        let probe = try XCTUnwrap(pool.selectTunnelUpstream(excluding: []))
        XCTAssertNotNil(probe.probe, "precondition: the selection claimed the probe")
        pool.recordExchangeError(IOError(errnoCode: ENETUNREACH, reason: "connect"), for: probe, origin: .connect("a.corp.example:443"))
        XCTAssertEqual(state(pool), .halfOpen, "the routing gap was not the probe's failure")

        let next = try XCTUnwrap(pool.selectTunnelUpstream(excluding: []))
        XCTAssertNotNil(next.probe, "the slot was given back")
        pool.recordExchangeError(IOError(errnoCode: ECONNREFUSED, reason: "connect"), for: next, origin: .connect("a.corp.example:443"))
        XCTAssertEqual(state(pool), .open)
    }

    /// A real dial NIO fails locally, in the shape it reports one: a connect to port 0 fails with `EADDRNOTAVAIL`,
    /// wrapped in `NIOConnectionError`. Neither a tunnel's dial nor a pooled exchange's charges it.
    func testARealLocalDialFailureOpensNoBreakerInEitherPath() async throws {
        let (pool, _) = makePool(port: 0)
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink())

        for _ in 0..<3 {
            do {
                let opened = try await coordinator.connectUpstreamTunnel(target: "a.corp.example:443").get()
                opened.channel.close(promise: nil)
                XCTFail("a dial to port 0 connected")
            } catch {
                assertLocalAddressFailure(error)
            }
        }
        XCTAssertEqual(state(pool), .closed, "the tunnel's local dial failures were not charged")

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://a.corp.example/")
        head.headers.add(name: "Host", value: "a.corp.example")
        for _ in 0..<3 {
            do {
                _ = try await pool.exchange(head: head, body: nil).get()
                XCTFail("a dial to port 0 connected")
            } catch {
                assertLocalAddressFailure(error)
            }
        }
        XCTAssertEqual(state(pool), .closed, "the exchange's local dial failures were not charged")
    }

    // MARK: - Harness

    private func makePool(port: Int, openInterval: TimeInterval = 300) -> (ConnectionPool, UpstreamProxy) {
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "P", host: "127.0.0.1", port: port, priority: 0)]
        config.circuitBreakerWindowSeconds = 0
        config.circuitFailureThreshold = 2
        config.circuitBaseOpenIntervalSeconds = openInterval
        config.circuitMaxOpenIntervalSeconds = openInterval
        let frozen = config
        let pool = ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { frozen },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        addTeardownBlock { pool.closeAll(scope: .all) }
        return (pool, frozen.enabledUpstreams[0])
    }

    private func charge(_ pool: ConnectionPool, _ error: Error) {
        guard let selection = pool.selectTunnelUpstream(excluding: []) else { return XCTFail("no upstream to select") }
        pool.recordExchangeError(error, for: selection, origin: .connect("a.corp.example:443"))
    }

    private func state(_ pool: ConnectionPool) -> UpstreamCircuitState? {
        pool.upstreamStatuses().first?.circuitState
    }

    private func assertLocalAddressFailure(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard let connection = error as? NIOConnectionError, !connection.connectionErrors.isEmpty else {
            return XCTFail("NIO reports a host dial as NIOConnectionError, got \(error)", file: file, line: line)
        }
        let codes = connection.connectionErrors.map { ($0.error as? IOError)?.errnoCode }
        XCTAssertEqual(codes, codes.map { _ in EADDRNOTAVAIL }, "\(error)", file: file, line: line)
    }
}
