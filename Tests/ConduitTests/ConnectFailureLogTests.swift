// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// #100: one host that never resolves wrote 1,667 ERROR lines in a minute.
/// A connect failure is reported the first time, then at most once per
/// target and failure kind per interval with the count it stood for; the
/// event keeps the same bound and still precedes its line.
final class ConnectFailureLogTests: XCTestCase {
    private final class Fixture: @unchecked Sendable {
        let logger = RecordingLogSink(minLevel: .info)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000_000))
        /// A scheduled flush as the fake event loop holds it: pending until
        /// it runs or is cancelled.
        struct ScheduledFlush {
            let delay: TimeInterval
            let work: @Sendable () -> Void
            var cancelled = false
        }

        let scheduled = NIOLockedValueBox<[ScheduledFlush]>([])
        let log: ConnectFailureLog

        init(interval: TimeInterval = 60, capacity: Int = 256) {
            let events = self.events
            let clock = self.clock
            let scheduled = self.scheduled
            log = ConnectFailureLog(
                logger: logger,
                eventSink: { event in events.withLockedValue { $0.append(event) } },
                interval: interval,
                capacity: capacity,
                now: { clock.withLockedValue { $0 } },
                scheduleFlush: { delay, work in
                    let index = scheduled.withLockedValue { tasks in
                        tasks.append(ScheduledFlush(delay: delay, work: work))
                        return tasks.count - 1
                    }
                    return { scheduled.withLockedValue { $0[index].cancelled = true } }
                }
            )
        }

        func advance(_ seconds: TimeInterval) {
            clock.withLockedValue { $0 = $0.addingTimeInterval(seconds) }
        }

        /// Flushes scheduled and neither run nor cancelled.
        var pendingFlushes: Int { scheduled.withLockedValue { $0.filter { !$0.cancelled }.count } }

        /// Runs the flushes pending now, as the event loop would once their
        /// delay has passed; one a flush schedules stays pending.
        func runScheduled() {
            let work = scheduled.withLockedValue { tasks in
                let due = tasks.filter { !$0.cancelled }.map(\.work)
                for index in tasks.indices { tasks[index].cancelled = true }
                return due
            }
            work.forEach { $0() }
        }

        func proxyLines() -> [LogEntry] { logger.entries().filter { $0.category == .proxy } }
        func emitted() -> [RuntimeEvent] { events.withLockedValue { $0 } }
    }

    private let nxdomain = AddressFamilyAwareResolver.ResolutionError(host: "pancake.apple.com", rc: EAI_NONAME)

    private func reportNXDOMAIN(_ fixture: Fixture, target: String = "pancake.apple.com:443") {
        fixture.log.report(
            "direct.connect_failed", level: .error, target: target, error: nxdomain,
            message: "Direct connect to \(target) failed: \(nxdomain.displayDescription)"
        )
    }

    func testAStormLogsTheFirstFailureAndOneSummary() {
        let fixture = Fixture()
        for _ in 0..<1667 {
            reportNXDOMAIN(fixture)
            fixture.advance(0.03)
        }
        XCTAssertEqual(fixture.proxyLines().count, 1, "only the first failure is logged inside the interval")
        XCTAssertEqual(fixture.emitted().count, 1, "the event keeps the same bound")
        XCTAssertEqual(fixture.pendingFlushes, 1, "one flush per window, not one per failure")

        fixture.advance(60)
        fixture.runScheduled()

        let lines = fixture.proxyLines()
        XCTAssertEqual(lines.count, 2, "one line plus one summary")
        XCTAssertEqual(lines.map(\.level), [.error, .error])
        XCTAssertTrue(lines[1].message.contains("suppressed=1666"), lines[1].message)
        XCTAssertTrue(lines[1].message.hasPrefix("Direct connect to pancake.apple.com:443 failed"), lines[1].message)
        let events = fixture.emitted()
        XCTAssertEqual(events.map(\.event), ["direct.connect_failed", "direct.connect_failed"])
        XCTAssertFalse(events[0].detail?.contains("suppressed=") ?? true)
        XCTAssertTrue(events[1].detail?.contains("suppressed=1666") ?? false, events[1].detail ?? "")
        XCTAssertTrue(events[1].detail?.contains("kind=dns") ?? false, events[1].detail ?? "")
        XCTAssertLessThanOrEqual(events[1].timestamp, lines[1].timestamp, "the summary event precedes its line")
    }

    func testTargetsAndFailureKindsCoalesceSeparately() {
        let fixture = Fixture()
        reportNXDOMAIN(fixture, target: "a.example.test:443")
        reportNXDOMAIN(fixture, target: "b.example.test:443")
        fixture.log.report(
            "direct.connect_failed", level: .error, target: "a.example.test:443",
            error: ChannelError.connectTimeout(.seconds(10)), message: "Direct connect to a.example.test:443 failed: timeout"
        )
        reportNXDOMAIN(fixture, target: "a.example.test:443")
        XCTAssertEqual(fixture.proxyLines().count, 3)
        XCTAssertEqual(fixture.log.count, 3)
    }

    func testAFailureAfterAQuietIntervalIsReportedAsNew() {
        let fixture = Fixture()
        reportNXDOMAIN(fixture)
        fixture.advance(61)
        reportNXDOMAIN(fixture)
        let lines = fixture.proxyLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(lines[1].message.contains("suppressed="), lines[1].message)
        XCTAssertEqual(fixture.pendingFlushes, 0, "nothing was suppressed, so nothing to flush")
    }

    /// Without a scheduler the summary still comes out, on the first repeat
    /// after the window closed.
    func testAnOverdueSummaryRidesOnTheNextFailure() {
        let fixture = Fixture()
        reportNXDOMAIN(fixture)
        reportNXDOMAIN(fixture)
        reportNXDOMAIN(fixture)
        fixture.advance(61)
        reportNXDOMAIN(fixture)
        let lines = fixture.proxyLines()
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[1].message.contains("suppressed=2"), lines[1].message)
    }

    func testTheMapIsHardCappedAndAnEvictedCountIsNotLost() {
        let fixture = Fixture(capacity: 4)
        for i in 0..<10 {
            reportNXDOMAIN(fixture, target: "h\(i).example.test:443")
            reportNXDOMAIN(fixture, target: "h\(i).example.test:443")
            fixture.advance(0.1)
        }
        XCTAssertLessThanOrEqual(fixture.log.count, 4)
        let summaries = fixture.proxyLines().filter { $0.message.contains("suppressed=1") }
        XCTAssertEqual(summaries.count, 6, "each evicted target reported the repeat it had held back")
    }

    /// Codex on PR #106: one flush task per suppressed key, never cancelled
    /// on eviction, piles up timers under a high-cardinality failure
    /// stream. One reschedulable flush serves every window.
    func testAHighCardinalityStormKeepsAtMostOneFlushPending() {
        let fixture = Fixture()
        var mostPending = 0
        for i in 0..<1000 {
            reportNXDOMAIN(fixture, target: "h\(i).example.test:443")
            reportNXDOMAIN(fixture, target: "h\(i).example.test:443")
            mostPending = max(mostPending, fixture.pendingFlushes)
            fixture.advance(0.01)
        }
        XCTAssertEqual(mostPending, 1, "never more than one flush pending")
        XCTAssertLessThanOrEqual(fixture.log.count, 256)
        XCTAssertEqual(fixture.pendingFlushes, 1)

        fixture.advance(60)
        fixture.runScheduled()
        XCTAssertEqual(fixture.pendingFlushes, 0, "every window was flushed; nothing left to arm")
        XCTAssertEqual(fixture.proxyLines().filter { $0.message.contains("suppressed=1 ") }.count, 1000,
                       "each key's held-back repeat was reported, by eviction or by the flush")
    }

    /// The flush is armed for the earliest window that holds a count and
    /// re-armed for the next one after it runs.
    func testTheFlushFollowsTheEarliestOpenWindow() {
        let fixture = Fixture()
        reportNXDOMAIN(fixture, target: "a.example.test:443")
        fixture.advance(10)
        reportNXDOMAIN(fixture, target: "b.example.test:443")
        reportNXDOMAIN(fixture, target: "b.example.test:443")
        fixture.advance(10)
        reportNXDOMAIN(fixture, target: "a.example.test:443")
        XCTAssertEqual(fixture.pendingFlushes, 1)
        let armed = fixture.scheduled.withLockedValue { $0.last { !$0.cancelled }?.delay } ?? 0
        XCTAssertEqual(armed, 40, accuracy: 0.1, "a's window closes first, at 60 s")

        fixture.advance(40)
        fixture.runScheduled()
        XCTAssertEqual(fixture.proxyLines().filter { $0.message.contains("suppressed=") }.count, 1, "only a's window closed")
        XCTAssertEqual(fixture.pendingFlushes, 1, "re-armed for b")
        let rearmed = fixture.scheduled.withLockedValue { $0.last { !$0.cancelled }?.delay } ?? 0
        XCTAssertEqual(rearmed, 10, accuracy: 0.1, "b's window closes at 70 s")

        fixture.advance(10)
        fixture.runScheduled()
        XCTAssertEqual(fixture.proxyLines().filter { $0.message.contains("suppressed=") }.count, 2)
        XCTAssertEqual(fixture.pendingFlushes, 0)
    }

    func testAQuietFailureStaysOutOfTheEventStream() {
        let fixture = Fixture()
        let memo = LinkLocalFailureMemo.RecentFailure(target: "169.254.169.254:80", secondsAgo: 1, retryAfterSeconds: 60)
        for _ in 0..<5 {
            fixture.log.report("direct.connect_failed", level: .info, target: "169.254.169.254:80", error: memo,
                               message: "Direct connect to 169.254.169.254:80 failed: \(memo)")
        }
        XCTAssertTrue(fixture.emitted().isEmpty)
        XCTAssertEqual(fixture.proxyLines().count, 1)
    }

    func testFailureKinds() async throws {
        XCTAssertEqual(ConnectFailureKind(nxdomain), .dns)
        XCTAssertEqual(ConnectFailureKind(ChannelError.connectTimeout(.seconds(2))), .timeout)
        XCTAssertEqual(ConnectFailureKind(IOError(errnoCode: ECONNREFUSED, reason: "connect")), .refused)
        XCTAssertEqual(ConnectFailureKind(IOError(errnoCode: EADDRNOTAVAIL, reason: "connect")), .unreachable)
        XCTAssertEqual(ConnectFailureKind(IOError(errnoCode: EHOSTUNREACH, reason: "connect")), .unreachable)
        XCTAssertEqual(
            ConnectFailureKind(LinkLocalFailureMemo.RecentFailure(target: "169.254.169.254:80", secondsAgo: 1, retryAfterSeconds: 60)),
            .linkLocalRecent
        )
        XCTAssertEqual(ConnectFailureKind(MetadataBlocklist.BlockedAddressError(host: "x", resolvedIP: "127.0.0.1")), .blocked)
        XCTAssertEqual(ConnectFailureKind(ChannelError.ioOnClosedChannel), .other)

        // The shapes `connect(host:port:)` really produces.
        let group = MultiThreadedEventLoopGroup.singleton
        do {
            _ = try await ClientBootstrap(group: group)
                .resolver(AddressFamilyAwareResolver(group: group))
                .connect(host: "conduit-connect-failure-kind.invalid", port: 443).get()
            XCTFail("expected NXDOMAIN")
        } catch {
            XCTAssertEqual(ConnectFailureKind(error), .dns, "\(error)")
        }
        let closed = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = closed.localAddress!.port!
        try await closed.close().get()
        do {
            _ = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: port).get()
            XCTFail("expected a refusal")
        } catch {
            XCTAssertEqual(ConnectFailureKind(error), .refused, "\(error)")
        }
    }
}
