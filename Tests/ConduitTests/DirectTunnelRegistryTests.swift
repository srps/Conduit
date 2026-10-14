// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

final class DirectTunnelRegistryTests: XCTestCase {
    private func channel(local: String? = nil) throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        if let local { channel.localAddress = try SocketAddress(ipAddress: local, port: 50_000) }
        try channel.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: 443)).wait()
        return channel
    }

    private func register(_ registry: DirectTunnelRegistry, _ channel: Channel,
                          _ cause: DirectModeCause) -> DirectTunnelRegistry.Registration {
        registry.register(channel, startedCause: cause, epoch: registry.epoch)
    }

    func testReconnectClosesOnlyTunnelsOpenedWhileTheVPNWasDown() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let offVPN = try channel(), onVPN = try channel(), noUpstreams = try channel()
        XCTAssertEqual(register(registry, offVPN, .vpnDisconnected), .tracked)
        XCTAssertEqual(register(registry, onVPN, .none), .tracked)
        XCTAssertEqual(register(registry, noUpstreams, .noUpstreamsConfigured), .tracked)

        let result = registry.closeTunnels(openedUnder: .vpnDisconnected)

        XCTAssertEqual(result, .init(closed: 1, untracked: 0, lateClosed: 0))
        XCTAssertFalse(offVPN.isActive)
        XCTAssertTrue(onVPN.isActive)
        XCTAssertTrue(noUpstreams.isActive)
        XCTAssertEqual(registry.count, 2)
    }

    func testAClosedTunnelLeavesTheRegistry() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let tunnel = try channel()
        register(registry, tunnel, .vpnDisconnected)
        try tunnel.close().wait()
        tunnel.embeddedEventLoop.run()
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(registry.closeTunnels(openedUnder: .vpnDisconnected).closed, 0)
    }

    func testAFullRegistryCountsUntrackedTunnelsAndReportsThemOnce() throws {
        let registry = DirectTunnelRegistry(capacity: { 1 })
        let tracked = try channel(), overflow = try channel()
        XCTAssertEqual(register(registry, tracked, .vpnDisconnected), .tracked)
        XCTAssertEqual(register(registry, overflow, .vpnDisconnected), .untracked)

        let first = registry.closeTunnels(openedUnder: .vpnDisconnected)
        XCTAssertEqual(first.closed, 1)
        XCTAssertEqual(first.untracked, 1)
        XCTAssertTrue(overflow.isActive, "an untracked tunnel is left to its own timeout")
        XCTAssertEqual(registry.closeTunnels(openedUnder: .vpnDisconnected).untracked, 0)
    }

    func testDisconnectClosesTunnelsWhoseLocalAddressLeftWithTheVPN() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let overVPN = try channel(local: "10.20.30.40")
        let overWiFi = try channel(local: "192.168.2.20")
        let unknownLocal = try channel()
        for tunnel in [overVPN, overWiFi, unknownLocal] { register(registry, tunnel, .none) }

        let result = registry.closeTunnels(orphanedFrom: ["192.168.2.20", "127.0.0.1"])

        XCTAssertEqual(result.closed, 1)
        XCTAssertFalse(overVPN.isActive)
        XCTAssertTrue(overWiFi.isActive)
        XCTAssertTrue(unknownLocal.isActive, "no known local address is never treated as orphaned")
    }

    // MARK: - Dials that straddle a sweep

    func testATunnelDialedOffVPNThatRegistersAfterTheReconnectSweepIsRetired() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dialEpoch = registry.epoch                       // dial starts while the VPN is down
        _ = registry.closeTunnels(openedUnder: .vpnDisconnected) // reconnect sweep runs mid-dial
        let late = try channel()

        XCTAssertEqual(registry.register(late, startedCause: .vpnDisconnected, epoch: dialEpoch), .retired)
        XCTAssertFalse(late.isActive)
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(registry.closeTunnels(openedUnder: .vpnDisconnected).lateClosed, 1,
                       "the next sweep reports the retirement once")
        XCTAssertEqual(registry.closeTunnels(openedUnder: .vpnDisconnected).lateClosed, 0)
    }

    func testALateTunnelTheMissedSweepWouldNotHaveClosedIsTracked() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dialEpoch = registry.epoch
        _ = registry.closeTunnels(openedUnder: .vpnDisconnected)
        let onVPN = try channel()

        XCTAssertEqual(registry.register(onVPN, startedCause: .none, epoch: dialEpoch), .tracked)
        XCTAssertTrue(onVPN.isActive)
    }

    func testALateTunnelOnAnAddressTheDisconnectRemovedIsRetired() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dialEpoch = registry.epoch
        _ = registry.closeTunnels(orphanedFrom: ["192.168.2.20"])
        let oldPath = try channel(local: "10.20.30.40")
        let newPath = try channel(local: "192.168.2.20")

        XCTAssertEqual(registry.register(oldPath, startedCause: .none, epoch: dialEpoch), .retired)
        XCTAssertEqual(registry.register(newPath, startedCause: .none, epoch: dialEpoch), .tracked)
        XCTAssertFalse(oldPath.isActive)
        XCTAssertTrue(newPath.isActive)
    }

    func testADialOlderThanEveryRememberedSweepIsRetired() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dialEpoch = registry.epoch
        for _ in 0...DirectTunnelRegistry.sweepHistory {
            _ = registry.closeTunnels(openedUnder: .noUpstreamsConfigured)
        }
        let ancient = try channel()
        XCTAssertEqual(registry.register(ancient, startedCause: .none, epoch: dialEpoch), .retired)
    }

    func testADialWithinRememberedHistoryIsJudgedOnlyByTheSweepsItMissed() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        for _ in 0..<DirectTunnelRegistry.sweepHistory {
            _ = registry.closeTunnels(openedUnder: .vpnDisconnected)
        }
        let dialEpoch = registry.epoch
        _ = registry.closeTunnels(openedUnder: .noUpstreamsConfigured)
        let tunnel = try channel()
        XCTAssertEqual(registry.register(tunnel, startedCause: .vpnDisconnected, epoch: dialEpoch), .tracked,
                       "the vpnDisconnected sweeps finished before this dial began")
    }

    func testLocalAddressesListsLoopback() throws {
        XCTAssertTrue(try LocalAddresses.assigned().contains("127.0.0.1"))
    }
}
