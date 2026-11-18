// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// The pool applies the circuit-breaker time-window guard (`circuitBreakerWindowSeconds`): a burst of failures
/// inside the window is a transient-path signal, such as every in-flight request failing at the same VPN-flap
/// instant, not upstream rot. The guard's state machine is `UpstreamCircuitBreakerTests`'.
///
/// See `docs/design-vpn-flap-resilience.md` § "Circuit breaker hardening".
final class CircuitBreakerWindowTests: XCTestCase {
    func testABurstOfRefusedDialsInsideTheWindowDoesNotTripTheBreaker() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let closed = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(closed.localAddress?.port)
        try await closed.close().get()
        var config = ProxyConfig.testFixture()
        config.circuitBreakerWindowSeconds = 10
        config.circuitFailureThreshold = 5
        config.upstreams = [UpstreamProxy(name: "refusing", host: "127.0.0.1", port: port, priority: 0)]
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { [config] in config },
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") })
        let proxy = config.upstreams[0]

        await pool.failTunnels(through: proxy, count: 10)

        let status = pool.upstreamStatuses().first { $0.id == proxy.id }
        XCTAssertEqual(status?.circuitState, .closed, "10 refusals well inside the 10 s window must not trip the breaker")
        XCTAssertEqual(status?.consecutiveFailures, 10, "every refusal counted")
        pool.closeAll()
        try await group.shutdownGracefully()
    }
}

/// Phase 5 config-section / Codable tests for `circuitBreakerWindowSeconds`.
final class CircuitBreakerWindowConfigTests: XCTestCase {

    func testHealthSectionDefaultIs10Seconds() {
        let health = HealthSection()
        XCTAssertEqual(health.circuitBreakerWindowSeconds, 10,
                       "Default per design doc — 10s gates burst-trips while staying responsive")
    }

    func testProxyConfigAccessorMirrorsHealthSection() {
        var config = ProxyConfig()
        XCTAssertEqual(config.circuitBreakerWindowSeconds, 10)

        config.circuitBreakerWindowSeconds = 30
        XCTAssertEqual(config.health.circuitBreakerWindowSeconds, 30,
                       "ProxyConfig accessor must write through to HealthSection")
    }

    func testCircuitBreakerWindowRoundTripsThroughCodable() throws {
        var config = ProxyConfig()
        config.circuitBreakerWindowSeconds = 20

        let encoded = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: encoded)
        XCTAssertEqual(decoded.circuitBreakerWindowSeconds, 20)
    }

    func testCircuitBreakerWindowDecodesAsDefaultWhenMissing() throws {
        // Old config files (pre-Phase 5) omit the field entirely. Should default
        // to the HealthSection default (10s) per the decodeIfPresent pattern.
        let config = ProxyConfig()
        var dict = try JSONSerialization.jsonObject(
            with: JSONEncoder().encode(config)
        ) as! [String: Any]
        dict.removeValue(forKey: "circuitBreakerWindowSeconds")
        let stripped = try JSONSerialization.data(withJSONObject: dict)

        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: stripped)
        XCTAssertEqual(decoded.circuitBreakerWindowSeconds, 10,
                       "Missing field decodes as the default (10s); old config files load cleanly")
    }
}
