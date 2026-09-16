// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
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
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "fe8::1"), "first hextet is 0fe8")
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "::1"))
        XCTAssertFalse(LinkLocalConnectPolicy.isLinkLocal(host: "fe80"))
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "FE9F::1"))
        XCTAssertTrue(LinkLocalConnectPolicy.isLinkLocal(host: "fe80:0000:0000:0000:0000:0000:0000:0001"))
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

    /// The shared dial: a link-local timeout is remembered, and the next dial
    /// to that target fails at once with an event, without connecting.
    func testDialRemembersALinkLocalTimeoutAndRefusesTheNextAttempt() async throws {
        LinkLocalFailureMemo.shared.reset()
        defer { LinkLocalFailureMemo.shared.reset() }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let events = NIOLockedValueBox<[String]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event.event) } }
        let budgets = NIOLockedValueBox<[TimeAmount]>([])

        func dial(_ host: String) async throws -> Channel {
            try await LinkLocalConnectPolicy.dial(host: host, port: 80, on: loop, eventSink: sink) { budget in
                budgets.withLockedValue { $0.append(budget) }
                return loop.makeFailedFuture(ChannelError.connectTimeout(budget))
            }.get()
        }

        _ = try? await dial("169.254.169.254")
        XCTAssertEqual(budgets.withLockedValue { $0 }, [LinkLocalConnectPolicy.connectTimeout])
        XCTAssertEqual(LinkLocalFailureMemo.shared.count, 1)

        do {
            _ = try await dial("169.254.169.254")
            XCTFail("expected the remembered failure")
        } catch {
            XCTAssertTrue(error is LinkLocalFailureMemo.RecentFailure, "\(error)")
        }
        XCTAssertEqual(budgets.withLockedValue { $0.count }, 1, "the second dial did not connect")
        XCTAssertEqual(events.withLockedValue { $0 }, ["direct.link_local_refused"])

        _ = try? await dial("192.0.2.1")
        XCTAssertEqual(budgets.withLockedValue { $0.last }, TimeAmount.seconds(10), "a routable target keeps the default budget")
        XCTAssertEqual(LinkLocalFailureMemo.shared.count, 1, "and is not remembered")
    }

    func testRepeatedFailureIsLoggedQuietly() {
        let failure = LinkLocalFailureMemo.RecentFailure(target: "169.254.169.254:80", secondsAgo: 3, retryAfterSeconds: 60)
        XCTAssertEqual(HTTPProxyHandler.directConnectFailureLevel(failure, default: .error), .info)
        XCTAssertEqual(HTTPProxyHandler.directConnectFailureLevel(ChannelError.connectTimeout(.seconds(2)), default: .error), .error)
    }
}
