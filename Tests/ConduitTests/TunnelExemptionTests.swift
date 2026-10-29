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
        let tunnelChannel = EmbeddedChannel(), pooledChannel = EmbeddedChannel()
        defer {
            XCTAssertNoThrow(try tunnelChannel.finish())
            XCTAssertNoThrow(try pooledChannel.finish())
        }

        let tunnel = PooledUpstreamConnection(proxy: proxy, channel: tunnelChannel)
        tunnel.isDedicatedTunnel = true
        tunnel.lastUsedAt = Date.distantPast

        let pooled = PooledUpstreamConnection(proxy: proxy, channel: pooledChannel)
        pooled.lastUsedAt = Date.distantPast

        let stale = ConnectionPool.stalledConnectionIDs(from: [tunnel, pooled], olderThan: 0)
        XCTAssertFalse(stale.contains(tunnel.id), "Dedicated tunnel should survive stalled reaping")
        XCTAssertTrue(stale.contains(pooled.id), "Non-tunnel connection should be reaped")
    }

    func testNonTunnelConnectionIsReaped() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        let conn = PooledUpstreamConnection(proxy: proxy, channel: channel)
        conn.lastUsedAt = Date.distantPast

        let stale = ConnectionPool.stalledConnectionIDs(from: [conn], olderThan: 0)
        XCTAssertTrue(stale.contains(conn.id))
    }

    func testRecentConnectionNotReaped() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }

        let conn = PooledUpstreamConnection(proxy: proxy, channel: channel)
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
        let group = MultiThreadedEventLoopGroup.singleton
        let config = ProxyConfig.testFixture()
        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        defer { pool.closeAll() }

        let channel = EmbeddedChannel()
        defer { XCTAssertNoThrow(try channel.finish()) }
        pool.removeDedicatedTunnelByChannel(channel)
    }
}
