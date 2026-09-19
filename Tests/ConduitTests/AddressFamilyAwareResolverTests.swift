// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOPosix
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class AddressFamilyAwareResolverTests: XCTestCase {
    func testLiteralsCompleteWhileHostnameLookupQueueIsBlocked() throws {
        let queue = DispatchQueue(label: "test.resolver.blocked-lookup")
        queue.suspend()
        // Always release the real hostname lookup before the test ends. No
        // global-pool saturation or scheduling-sensitive sleeps are needed.
        let resolver = AddressFamilyAwareResolver(
            group: MultiThreadedEventLoopGroup.singleton,
            hasRoutableIPv6: { XCTFail("Literal resolution must not enumerate interfaces"); return false },
            lookupQueue: queue
        )
        let nameFuture = resolver.initiateAQuery(host: "localhost", port: 80)
        defer {
            queue.resume()
            XCTAssertNoThrow(try nameFuture.wait())
        }

        let cases: [(String, Bool, [SocketAddress])] = try [
            ("127.0.0.1", false, [SocketAddress(ipAddress: "127.0.0.1", port: 443)]),
            ("127.0.0.1", true, []),
            ("::1", true, [SocketAddress(ipAddress: "::1", port: 443)]),
            ("::1", false, []),
            ("::ffff:127.0.0.1", true, [SocketAddress(ipAddress: "::ffff:127.0.0.1", port: 443)]),
            ("fe80::1%1", true, [SocketAddress(ipAddress: "fe80::1%1", port: 443)])
        ]
        for (host, ipv6, expected) in cases {
            let done = expectation(description: "numeric \(host), AAAA=\(ipv6)")
            let result = NIOLockedValueBox<Result<[SocketAddress], Error>?>(nil)
            let future = ipv6 ? resolver.initiateAAAAQuery(host: host, port: 443)
                : resolver.initiateAQuery(host: host, port: 443)
            future.whenComplete { value in result.withLockedValue { $0 = value }; done.fulfill() }
            wait(for: [done], timeout: 1)
            let value = try XCTUnwrap(result.withLockedValue { $0 })
            XCTAssertEqual(try value.get(), expected)
        }
        // No wait on the suspended queue; the absence of completion is
        // guaranteed by suspension, not inferred from a wall-clock delay.
    }

    func testInvalidLiteralPortsFailWithoutTrapping() throws {
        let resolver = AddressFamilyAwareResolver(group: MultiThreadedEventLoopGroup.singleton)
        for port in [-1, 65536, Int.max] {
            XCTAssertThrowsError(try resolver.initiateAQuery(host: "127.0.0.1", port: port).wait())
            XCTAssertThrowsError(try resolver.initiateAAAAQuery(host: "::1", port: port).wait())
        }
        for port in [0, 65535] {
            XCTAssertEqual(try resolver.initiateAQuery(host: "127.0.0.1", port: port).wait().first?.port, port)
        }
    }

    func testConnectToLiteralDoesNotWaitForHostnameLookupQueue() throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).wait()
        defer { try? server.close().wait() }
        let queue = DispatchQueue(label: "test.resolver.literal-connect")
        queue.suspend()
        defer { queue.resume() }
        let resolver = AddressFamilyAwareResolver(group: group, hasRoutableIPv6: { false }, lookupQueue: queue)
        let channel = try ClientBootstrap(group: group)
            .resolver(resolver)
            .connectTimeout(.seconds(2))
            .connect(host: "127.0.0.1", port: XCTUnwrap(server.localAddress?.port))
            .wait()
        defer { try? channel.close().wait() }
        XCTAssertEqual(channel.remoteAddress?.ipAddress, "127.0.0.1")
    }

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
