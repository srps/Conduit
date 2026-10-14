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

    /// Dial and register with no sweep in between.
    @discardableResult
    private func open(_ registry: DirectTunnelRegistry, _ channel: Channel) -> DirectTunnelRegistry.Registration {
        registry.register(channel, dial: registry.beginDial())
    }

    func testReconnectClosesOnlyTunnelsOpenedWhileTheVPNWasDown() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let onVPN = try channel()
        XCTAssertEqual(open(registry, onVPN), .tracked)
        registry.markVPNDown()
        let offVPN = try channel()
        XCTAssertEqual(open(registry, offVPN), .tracked)

        let result = registry.closeTunnelsOpenedWhileVPNDown()

        XCTAssertEqual(result, .init(closed: 1, untracked: 0, lateClosed: 0))
        XCTAssertFalse(offVPN.isActive)
        XCTAssertTrue(onVPN.isActive)
        XCTAssertEqual(registry.count, 1)
    }

    /// The sweep follows the VPN state, not the direct-mode cause: a
    /// no-proxy or PAC-DIRECT dial while the probe is pending or on-prem
    /// leaves on the off-VPN path under cause `.none` (#148).
    func testTheReconnectSweepEndsTheOutageOnce() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        XCTAssertNil(registry.closeTunnelsOpenedWhileVPNDown(), "no outage, no sweep")
        registry.markVPNDown()
        XCTAssertTrue(registry.beginDial().whileVPNDown)
        XCTAssertNotNil(registry.closeTunnelsOpenedWhileVPNDown())
        XCTAssertFalse(registry.beginDial().whileVPNDown)
        XCTAssertNil(registry.closeTunnelsOpenedWhileVPNDown())
    }

    func testAClosedTunnelLeavesTheRegistry() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        registry.markVPNDown()
        let tunnel = try channel()
        open(registry, tunnel)
        try tunnel.close().wait()
        tunnel.embeddedEventLoop.run()
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(registry.closeTunnelsOpenedWhileVPNDown()?.closed, 0)
    }

    func testAFullRegistryCountsUntrackedTunnelsAndReportsThemOnce() throws {
        let registry = DirectTunnelRegistry(capacity: { 1 })
        registry.markVPNDown()
        let tracked = try channel(), overflow = try channel()
        XCTAssertEqual(open(registry, tracked), .tracked)
        XCTAssertEqual(open(registry, overflow), .untracked)

        let first = registry.closeTunnelsOpenedWhileVPNDown()
        XCTAssertEqual(first?.closed, 1)
        XCTAssertEqual(first?.untracked, 1)
        XCTAssertTrue(overflow.isActive, "an untracked tunnel is left to its own timeout")
        XCTAssertEqual(registry.closeTunnels(orphanedFrom: []).untracked, 0)
    }

    func testDisconnectClosesTunnelsWhoseLocalAddressLeftWithTheVPN() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let overVPN = try channel(local: "10.20.30.40")
        let overWiFi = try channel(local: "192.168.2.20")
        let unknownLocal = try channel()
        for tunnel in [overVPN, overWiFi, unknownLocal] { open(registry, tunnel) }

        let result = registry.closeTunnels(orphanedFrom: ["192.168.2.20", "127.0.0.1"])

        XCTAssertEqual(result.closed, 1)
        XCTAssertFalse(overVPN.isActive)
        XCTAssertTrue(overWiFi.isActive)
        XCTAssertTrue(unknownLocal.isActive, "no known local address is never treated as orphaned")
    }

    // MARK: - Dials that straddle a sweep

    func testATunnelDialedOffVPNThatRegistersAfterTheReconnectSweepIsRetired() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        registry.markVPNDown()
        let dial = registry.beginDial()                     // dial starts while the VPN is down
        _ = registry.closeTunnelsOpenedWhileVPNDown()       // reconnect sweep runs mid-dial
        let late = try channel()

        XCTAssertEqual(registry.register(late, dial: dial), .retired)
        XCTAssertFalse(late.isActive)
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(registry.closeTunnels(orphanedFrom: []).lateClosed, 1,
                       "the next sweep reports the retirement once")
        XCTAssertEqual(registry.closeTunnels(orphanedFrom: []).lateClosed, 0)
    }

    func testALateTunnelDialedOnTheVPNIsTracked() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dial = registry.beginDial()
        registry.markVPNDown()
        _ = registry.closeTunnelsOpenedWhileVPNDown()
        let onVPN = try channel()

        XCTAssertEqual(registry.register(onVPN, dial: dial), .tracked)
        XCTAssertTrue(onVPN.isActive)
    }

    func testALateTunnelOnAnAddressTheDisconnectRemovedIsRetired() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dial = registry.beginDial()
        _ = registry.closeTunnels(orphanedFrom: ["192.168.2.20"])
        let oldPath = try channel(local: "10.20.30.40")
        let newPath = try channel(local: "192.168.2.20")

        XCTAssertEqual(registry.register(oldPath, dial: dial), .retired)
        XCTAssertEqual(registry.register(newPath, dial: dial), .tracked)
        XCTAssertFalse(oldPath.isActive)
        XCTAssertTrue(newPath.isActive)
    }

    func testADialOlderThanEveryRememberedSweepIsRetired() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let dial = registry.beginDial()
        for _ in 0...TransitionSweeps<Int>.capacity {
            _ = registry.closeTunnels(orphanedFrom: [])
        }
        XCTAssertEqual(registry.register(try channel(), dial: dial), .retired)
    }

    func testADialWithinRememberedHistoryIsJudgedOnlyByTheSweepsItMissed() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        registry.markVPNDown()
        _ = registry.closeTunnelsOpenedWhileVPNDown()
        registry.markVPNDown()
        let dial = registry.beginDial()
        _ = registry.closeTunnels(orphanedFrom: [])
        XCTAssertEqual(registry.register(try channel(), dial: dial), .tracked,
                       "the reconnect sweep finished before this dial began")
    }

    func testLocalAddressesListsLoopback() throws {
        XCTAssertTrue(try LocalAddresses.assigned().contains("127.0.0.1"))
    }
}

final class TransitionSweepsTests: XCTestCase {
    func testMissedListsOnlyTheSweepsAfterTheDial() {
        var sweeps = TransitionSweeps<String>()
        sweeps.record("a")
        let dial = sweeps.epoch
        sweeps.record("b")
        sweeps.record("c")
        XCTAssertEqual(sweeps.missed(since: dial), ["b", "c"])
        XCTAssertEqual(sweeps.missed(since: sweeps.epoch), [])
    }

    func testHistoryIsBounded() {
        var sweeps = TransitionSweeps<Int>()
        for i in 0..<(TransitionSweeps<Int>.capacity * 3) { sweeps.record(i) }
        XCTAssertNil(sweeps.missed(since: 0), "forgotten sweeps retire the dial")
        XCTAssertEqual(sweeps.missed(since: sweeps.epoch - UInt64(TransitionSweeps<Int>.capacity))?.count,
                       TransitionSweeps<Int>.capacity)
    }
}
