// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

final class UpstreamFailoverTests: XCTestCase {

    private func makeConfig(upstreams: [UpstreamProxy]) -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.upstreams = upstreams
        config.connectionCheckTimeoutMS = 200
        return config
    }

    // MARK: - CONNECTCoordinator failover

    @MainActor
    func testConnectTunnelFailsOverToNextUpstream() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let config = makeConfig(upstreams: [
            UpstreamProxy(name: "Dead1", host: "192.0.2.1", port: 9999, priority: 0),
            UpstreamProxy(name: "Dead2", host: "192.0.2.2", port: 9999, priority: 1),
            UpstreamProxy(name: "Dead3", host: "192.0.2.3", port: 9999, priority: 2)
        ])

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "D", workstation: "W", ntHash: SecretBytes.repeating(0, count: 16)))
            }
        )

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "D", workstation: "W", ntHash: SecretBytes.repeating(0, count: 16)))
            },
            logger: logger
        )

        let start = Date()
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            XCTFail("Should have failed after exhausting all upstreams")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 5, "Failover through 3 dead upstreams at 200ms timeout should complete in <5s")
            let switched = pool.activeUpstream()
            XCTAssertNotNil(switched, "Pool should have cycled through upstreams during failover")
        }

        pool.closeAll()
    }

    @MainActor
    func testConnectTunnelFailoverCyclesThroughAllUpstreams() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let config = makeConfig(upstreams: [
            UpstreamProxy(name: "A", host: "192.0.2.1", port: 9999, priority: 0),
            UpstreamProxy(name: "B", host: "192.0.2.2", port: 9999, priority: 1)
        ])

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        XCTAssertEqual(pool.enabledUpstreamCount, 2)

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials },
            logger: logger
        )

        let start = Date()
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "test.com:443").get()
            XCTFail("Should have failed")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 3, "Failover through 2 dead upstreams should complete quickly")
        }

        pool.closeAll()
    }

    @MainActor
    func testConnectTunnelWithNoUpstreamsFailsImmediately() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let config = makeConfig(upstreams: [])

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        XCTAssertEqual(pool.enabledUpstreamCount, 0)

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials },
            logger: logger
        )

        let start = Date()
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "test.com:443").get()
            XCTFail("Should have failed immediately")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 1, "No upstreams should fail instantly")
        }
    }

    // MARK: - Pool rotation after failover

    @MainActor
    func testSwitchToNextUpstreamWrapsWithFixtureProxies() {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let config = ProxyConfig.testFixture()

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        XCTAssertEqual(pool.enabledUpstreamCount, config.enabledUpstreams.count)

        let first = pool.activeUpstream()
        for _ in 0..<config.enabledUpstreams.count {
            _ = pool.switchToNextUpstream()
        }
        let afterFullCycle = pool.activeUpstream()
        XCTAssertEqual(first, afterFullCycle, "Should wrap around after cycling through every upstream")

        pool.closeAll()
    }
}
