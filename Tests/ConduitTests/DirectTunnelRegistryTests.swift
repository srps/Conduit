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

    func testReconnectClosesOnlyTunnelsOpenedWhileTheVPNWasDown() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let offVPN = try channel(), onVPN = try channel(), noUpstreams = try channel()
        registry.register(offVPN, startedCause: .vpnDisconnected)
        registry.register(onVPN, startedCause: .none)
        registry.register(noUpstreams, startedCause: .noUpstreamsConfigured)

        let result = registry.closeTunnels(openedUnder: .vpnDisconnected)

        XCTAssertEqual(result.closed, 1)
        XCTAssertEqual(result.untracked, 0)
        XCTAssertFalse(offVPN.isActive)
        XCTAssertTrue(onVPN.isActive)
        XCTAssertTrue(noUpstreams.isActive)
        XCTAssertEqual(registry.count, 2)
    }

    func testAClosedTunnelLeavesTheRegistry() throws {
        let registry = DirectTunnelRegistry(capacity: { 8 })
        let tunnel = try channel()
        registry.register(tunnel, startedCause: .vpnDisconnected)
        try tunnel.close().wait()
        tunnel.embeddedEventLoop.run()
        XCTAssertEqual(registry.count, 0)
        XCTAssertEqual(registry.closeTunnels(openedUnder: .vpnDisconnected).closed, 0)
    }

    func testAFullRegistryCountsUntrackedTunnelsAndReportsThemOnce() throws {
        let registry = DirectTunnelRegistry(capacity: { 1 })
        let tracked = try channel(), overflow = try channel()
        XCTAssertTrue(registry.register(tracked, startedCause: .vpnDisconnected))
        XCTAssertFalse(registry.register(overflow, startedCause: .vpnDisconnected))

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
        for tunnel in [overVPN, overWiFi, unknownLocal] { registry.register(tunnel, startedCause: .none) }

        let result = registry.closeTunnels(orphanedFrom: ["192.168.2.20", "127.0.0.1"])

        XCTAssertEqual(result.closed, 1)
        XCTAssertFalse(overVPN.isActive)
        XCTAssertTrue(overWiFi.isActive)
        XCTAssertTrue(unknownLocal.isActive, "no known local address is never treated as orphaned")
    }

    func testLocalAddressesListsLoopback() throws {
        XCTAssertTrue(try LocalAddresses.assigned().contains("127.0.0.1"))
    }
}
