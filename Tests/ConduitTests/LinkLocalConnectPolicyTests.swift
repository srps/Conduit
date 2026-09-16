// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class LinkLocalConnectPolicyTests: XCTestCase {
    func testRecognisesLinkLocalLiterals() {
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "169.254.169.254"))
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "169.254.0.1"))
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "fe80::1"))
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "[fe80::1%en0]"))
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "FEBF::1"))
    }

    func testLeavesEverythingElseAlone() {
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "169.253.1.1"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "169.255.1.1"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "10.0.0.1"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "fec0::1"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "fe7f::1"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "metadata.google.internal"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "169.254.169.254.example.com"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: ""))
    }

    func testMemoRemembersAFailureForItsTTL() {
        let memo = LinkLocalFailureMemo(ttl: 60, capacity: 4)
        let start = Date()
        XCTAssertNil(memo.recentFailure(target: "169.254.169.254:80", now: start))

        memo.recordFailure(target: "169.254.169.254:80", now: start)
        let recent = memo.recentFailure(target: "169.254.169.254:80", now: start.addingTimeInterval(5))
        XCTAssertEqual(recent?.secondsAgo, 5)
        XCTAssertEqual(recent?.retryAfterSeconds, 60)
        XCTAssertTrue(recent?.description.contains("169.254.169.254:80") == true)

        XCTAssertNil(memo.recentFailure(target: "169.254.169.254:80", now: start.addingTimeInterval(61)))
        XCTAssertEqual(memo.count, 0, "an expired entry is dropped when it is read")
        XCTAssertNil(memo.recentFailure(target: "169.254.169.254:81", now: start), "the port is part of the key")
    }

    func testMemoStaysWithinCapacity() {
        let memo = LinkLocalFailureMemo(ttl: 60, capacity: 3)
        let start = Date()
        for i in 0..<10 {
            memo.recordFailure(target: "169.254.0.\(i):80", now: start.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(memo.count, 3)
        XCTAssertNil(memo.recentFailure(target: "169.254.0.0:80", now: start.addingTimeInterval(10)), "the oldest entries were evicted")
        XCTAssertNotNil(memo.recentFailure(target: "169.254.0.9:80", now: start.addingTimeInterval(10)))
    }

    func testConnectTimeoutIsRecognisedBareAndWrapped() {
        XCTAssertTrue(LinkLocalConnectPolicy.isConnectTimeout(ChannelError.connectTimeout(.seconds(2))))
        XCTAssertFalse(LinkLocalConnectPolicy.isConnectTimeout(ChannelError.ioOnClosedChannel))
        XCTAssertFalse(LinkLocalConnectPolicy.isConnectTimeout(IOError(errnoCode: ECONNREFUSED, reason: "connect")))
    }

    /// Whatever shape `ClientBootstrap.connect(host:port:)` reports a timeout
    /// in (bare for an address literal, wrapped in `NIOConnectionError` for a
    /// resolved name), the classifier recognises it.
    func testTimeoutFromARealHostConnectIsRecognised() async throws {
        do {
            // TEST-NET-1 is unroutable; the connect times out rather than refuses.
            _ = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .connectTimeout(.milliseconds(100))
                .connect(host: "192.0.2.1", port: 9)
                .get()
            XCTFail("expected the connect to fail")
        } catch {
            XCTAssertTrue(LinkLocalConnectPolicy.isConnectTimeout(error), "\(error)")
        }
    }

    func testRepeatedFailureIsLoggedQuietly() {
        let failure = LinkLocalFailureMemo.RecentFailure(target: "169.254.169.254:80", secondsAgo: 3, retryAfterSeconds: 60)
        XCTAssertEqual(HTTPProxyHandler.directConnectFailureLevel(failure, default: .error), .info)
        XCTAssertEqual(HTTPProxyHandler.directConnectFailureLevel(ChannelError.connectTimeout(.seconds(2)), default: .error), .error)
    }
}
