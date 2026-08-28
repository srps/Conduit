// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class AddressFamilyAwareResolverTests: XCTestCase {
    func testLinkLocalAndLoopbackAreNotRoutable() {
        XCTAssertFalse(IPv6Availability.isRoutable(ipv6: "fe80::2d:6f49:6ef4:36a1"))
        XCTAssertFalse(IPv6Availability.isRoutable(ipv6: "FE80::1"))
        XCTAssertFalse(IPv6Availability.isRoutable(ipv6: "febf::1"))
        XCTAssertFalse(IPv6Availability.isRoutable(ipv6: "::1"))
        XCTAssertTrue(IPv6Availability.isRoutable(ipv6: "2603:1026:c0d:1028::2"))
        XCTAssertTrue(IPv6Availability.isRoutable(ipv6: "fd00::1"), "ULA can reach internal AAAA hosts")
        XCTAssertTrue(IPv6Availability.isRoutable(ipv6: "fec0::1"), "site-local is outside fe80::/10")
    }

    func testAAAAQueryIsEmptyWithoutRoutableIPv6() throws {
        let resolver = AddressFamilyAwareResolver(group: MultiThreadedEventLoopGroup.singleton, hasRoutableIPv6: { false })
        let addresses = try resolver.initiateAAAAQuery(host: "localhost", port: 80).wait()
        XCTAssertEqual(addresses, [])
    }

    func testAAAAQueryResolvesWhenIPv6IsRoutable() throws {
        let resolver = AddressFamilyAwareResolver(group: MultiThreadedEventLoopGroup.singleton, hasRoutableIPv6: { true })
        let addresses = try resolver.initiateAAAAQuery(host: "localhost", port: 80).wait()
        XCTAssertTrue(addresses.allSatisfy { $0.protocol == .inet6 })
        XCTAssertTrue(addresses.contains { $0.ipAddress == "::1" }, "\(addresses)")
    }

    func testAQueryResolvesIPv4Only() throws {
        let resolver = AddressFamilyAwareResolver(group: MultiThreadedEventLoopGroup.singleton, hasRoutableIPv6: { false })
        let addresses = try resolver.initiateAQuery(host: "localhost", port: 80).wait()
        XCTAssertTrue(addresses.allSatisfy { $0.protocol == .inet })
        XCTAssertTrue(addresses.contains { $0.ipAddress == "127.0.0.1" }, "\(addresses)")
    }

    func testConnectThroughResolverReachesLocalServer() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let port = server.localAddress!.port!

        let channel = try ClientBootstrap(group: group)
            .resolver(AddressFamilyAwareResolver(group: group, hasRoutableIPv6: { false }))
            .connect(host: "localhost", port: port)
            .wait()
        defer { try? channel.close().wait() }
        XCTAssertEqual(channel.remoteAddress?.ipAddress, "127.0.0.1")
    }
}
