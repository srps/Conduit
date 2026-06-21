// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOPosix
import XCTest
@testable import ProxyKernel

final class TunnelExemptionTests: XCTestCase {

    func testDedicatedTunnelSurvivesStalledReaping() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]

        let tunnel = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        tunnel.isDedicatedTunnel = true
        tunnel.lastUsedAt = Date.distantPast

        let pooled = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        pooled.lastUsedAt = Date.distantPast

        let stale = ConnectionPool.stalledConnectionIDs(from: [tunnel, pooled], olderThan: 0)
        XCTAssertFalse(stale.contains(tunnel.id), "Dedicated tunnel should survive stalled reaping")
        XCTAssertTrue(stale.contains(pooled.id), "Non-tunnel connection should be reaped")
    }

    func testNonTunnelConnectionIsReaped() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]

        let conn = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        conn.lastUsedAt = Date.distantPast

        let stale = ConnectionPool.stalledConnectionIDs(from: [conn], olderThan: 0)
        XCTAssertTrue(stale.contains(conn.id))
    }

    func testRecentConnectionNotReaped() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]

        let conn = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        conn.lastUsedAt = Date()

        let stale = ConnectionPool.stalledConnectionIDs(from: [conn], olderThan: 60)
        XCTAssertTrue(stale.isEmpty, "Recent connection should not be reaped")
    }

    func testEmptyCollectionReturnsEmpty() {
        let stale = ConnectionPool.stalledConnectionIDs(
            from: [] as [PooledUpstreamConnection],
            olderThan: 0
        )
        XCTAssertTrue(stale.isEmpty)
    }

    @MainActor func testRemoveDedicatedTunnelByChannelIsCallable() {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let config = ProxyConfig.testFixture()
        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        defer { pool.closeAll() }

        let channel = EmbeddedChannel()
        pool.removeDedicatedTunnelByChannel(channel)
    }
}
