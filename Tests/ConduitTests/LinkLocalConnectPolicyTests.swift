// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
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

    /// #100: the real install logged 1,350 link-local timeouts and not one
    /// of them started while the memo held a failure. More than half began
    /// while another dial to the same target was still waiting out its two
    /// seconds, before there was anything to remember. A dial in flight is
    /// joined instead: one connect attempt, and the joiners fail with it.
    func testConcurrentDialsToALinkLocalTargetShareOneConnectAttempt() async throws {
        LinkLocalFailureMemo.shared.reset()
        defer { LinkLocalFailureMemo.shared.reset() }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let events = NIOLockedValueBox<[String]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event.event) } }
        let attempts = NIOLockedValueBox(0)
        let pending = loop.makePromise(of: Channel.self)

        let dials = (0..<4).map { _ in
            LinkLocalConnectPolicy.dial(host: "169.254.169.254", port: 80, on: loop, eventSink: sink) { _ in
                attempts.withLockedValue { $0 += 1 }
                return pending.futureResult
            }
        }
        XCTAssertEqual(attempts.withLockedValue { $0 }, 1, "the later dials joined the first")

        pending.fail(ChannelError.connectTimeout(LinkLocalConnectPolicy.connectTimeout))
        var kinds: [String] = []
        for dial in dials {
            do {
                _ = try await dial.get()
                XCTFail("expected every dial to fail")
            } catch let error as LinkLocalFailureMemo.RecentFailure {
                XCTAssertEqual(error.target, "169.254.169.254:80")
                kinds.append("recent")
            } catch {
                XCTAssertTrue(LinkLocalConnectPolicy.isConnectTimeout(error), "\(error)")
                kinds.append("timeout")
            }
        }
        XCTAssertEqual(kinds, ["timeout", "recent", "recent", "recent"])
        XCTAssertEqual(attempts.withLockedValue { $0 }, 1, "a joiner never dialled")

        // Repeats inside the memo window keep failing at once, and the
        // refusal event is emitted once per window, not once per attempt.
        for _ in 0..<5 {
            _ = try? await LinkLocalConnectPolicy.dial(host: "169.254.169.254", port: 80, on: loop, eventSink: sink) { _ in
                attempts.withLockedValue { $0 += 1 }
                return loop.makeFailedFuture(ChannelError.connectTimeout(LinkLocalConnectPolicy.connectTimeout))
            }.get()
        }
        XCTAssertEqual(attempts.withLockedValue { $0 }, 1)
        XCTAssertEqual(events.withLockedValue { $0 }, ["direct.link_local_refused"])
    }

    /// A peer that answers (a Thunderbolt bridge, a self-assigned neighbour)
    /// is not refused: when the dial a joiner waited on succeeds, the
    /// joiner makes its own connection.
    func testAJoinerDialsItselfWhenTheFirstDialSucceeds() async throws {
        LinkLocalFailureMemo.shared.reset()
        defer { LinkLocalFailureMemo.shared.reset() }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let attempts = NIOLockedValueBox(0)
        let first = loop.makePromise(of: Channel.self)
        let connected = EmbeddedChannel()

        let leader = LinkLocalConnectPolicy.dial(host: "169.254.10.1", port: 22, on: loop, eventSink: nil) { _ in
            attempts.withLockedValue { $0 += 1 }
            return first.futureResult
        }
        let joiner = LinkLocalConnectPolicy.dial(host: "169.254.10.1", port: 22, on: loop, eventSink: nil) { _ in
            attempts.withLockedValue { $0 += 1 }
            return loop.makeSucceededFuture(connected)
        }
        XCTAssertEqual(attempts.withLockedValue { $0 }, 1)
        first.succeed(connected)
        _ = try await leader.get()
        _ = try await joiner.get()
        XCTAssertEqual(attempts.withLockedValue { $0 }, 2)
        XCTAssertEqual(LinkLocalFailureMemo.shared.count, 0)
    }

    /// Codex on PR #106: joiners released by a leader that did not time out
    /// must not queue behind whichever of them leads next. Every one dials
    /// at once, whether the leader connected or failed another way.
    func testReleasedJoinersDialIndependentlyAfterASuccess() async throws {
        try await assertReleasedJoinersDialIndependently { $0.succeed(EmbeddedChannel()) }
    }

    func testReleasedJoinersDialIndependentlyAfterANonTimeoutFailure() async throws {
        try await assertReleasedJoinersDialIndependently {
            $0.fail(IOError(errnoCode: ECONNREFUSED, reason: "connect"))
        }
    }

    private func assertReleasedJoinersDialIndependently(
        finishLeader: (EventLoopPromise<Channel>) -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        LinkLocalFailureMemo.shared.reset()
        defer { LinkLocalFailureMemo.shared.reset() }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        // Every dial gets its own promise the test controls; none completes
        // until the test says so.
        let dials = NIOLockedValueBox<[EventLoopPromise<Channel>]>([])
        let connect: @Sendable (TimeAmount) -> EventLoopFuture<Channel> = { _ in
            let promise = loop.makePromise(of: Channel.self)
            dials.withLockedValue { $0.append(promise) }
            return promise.futureResult
        }
        let dial = { LinkLocalConnectPolicy.dial(host: "169.254.20.1", port: 22, on: loop, eventSink: nil, connect) }

        let leader = dial()
        let joiners = (0..<3).map { _ in dial() }
        XCTAssertEqual(dials.withLockedValue { $0.count }, 1, "the joiners wait for the leader", file: file, line: line)

        finishLeader(dials.withLockedValue { $0[0] })
        // Completion callbacks run on `loop`; a task queued behind them runs
        // after every released joiner has made its decision.
        try await loop.submit {}.get()
        XCTAssertEqual(dials.withLockedValue { $0.count }, 4, "every released joiner dialled at once", file: file, line: line)

        // Complete every dial, including any a serialized joiner opens later,
        // so a regression fails the assertion above instead of hanging here.
        var completed = 1
        for _ in 0..<joiners.count {
            let open = dials.withLockedValue { Array($0.dropFirst(completed)) }
            completed += open.count
            for promise in open { promise.succeed(EmbeddedChannel()) }
            try await loop.submit {}.get()
        }
        _ = try? await leader.get()
        for joiner in joiners { _ = try await joiner.get() }
    }
}
