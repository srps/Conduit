// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

/// The read schedule of decision 0048 as a pure value.
final class StoreReadScheduleTests: XCTestCase {
    func testRetriesBackOffToThirtySecondsAndStayThere() {
        var schedule = StoreReadSchedule(audit: nil)
        var now: TimeInterval = 100
        var delays: [TimeInterval] = []
        for _ in 0..<8 {
            let retry = schedule.failed(at: now)
            delays.append(retry.due - now)
            now = retry.due
        }
        XCTAssertEqual(delays, [1, 2, 4, 8, 16, 30, 30, 30])
        XCTAssertEqual(schedule.failedAttempts, 8)
    }

    func testTheFirstGoodReadingResetsTheScheduleAndCarriesTheRunItEnded() {
        var schedule = StoreReadSchedule(audit: nil)
        _ = schedule.failed(at: 0)
        _ = schedule.failed(at: 1)
        _ = schedule.failed(at: 3)

        XCTAssertEqual(schedule.succeeded(at: 7), .init(recoveredAfter: 3, due: nil))
        XCTAssertEqual(schedule.succeeded(at: 8), .init(recoveredAfter: nil, due: nil), "a second good reading ends no run")
        XCTAssertEqual(schedule.failed(at: 9), .init(attempt: 1, reports: true, due: 10), "a new run starts from the first delay")
    }

    func testAnAuditIsDueOnlyWhileHealthy() {
        var schedule = StoreReadSchedule(audit: StoreReadSchedule.Constants.vpnAudit)
        XCTAssertEqual(schedule.succeeded(at: 5).due, 65)
        XCTAssertEqual(schedule.failed(at: 65).due, 66, "a failure is retried on the backoff, not the audit")
        XCTAssertEqual(schedule.succeeded(at: 66), .init(recoveredAfter: 1, due: 126))
    }

    func testReportedAttemptsArePowersOfTwoUpToSixtyFourThenEverySixtyFourth() {
        let reported = (1...400).filter(StoreReadSchedule.reports(attempt:))
        XCTAssertEqual(reported, [1, 2, 4, 8, 16, 32, 64, 128, 192, 256, 320, 384])

        var schedule = StoreReadSchedule(audit: nil)
        let fromSchedule = (1...130).map { _ in schedule.failed(at: 0) }.filter(\.reports).map(\.attempt)
        XCTAssertEqual(fromSchedule, [1, 2, 4, 8, 16, 32, 64, 128])
    }

    func testAnHourOfFailureCostsAFewEvents() {
        var schedule = StoreReadSchedule(audit: nil)
        var now: TimeInterval = 0
        var events = 0
        while now < 3600 {
            let retry = schedule.failed(at: now)
            if retry.reports { events += 1 }
            now = retry.due
        }
        XCTAssertEqual(events, 7, "attempts 1, 2, 4 … 64; the hour holds 124 attempts")
    }

    func testLeewayIsATenthOfTheDelay() {
        XCTAssertEqual(StoreReadSchedule.leeway(for: 30), 3, accuracy: 1e-9)
        XCTAssertEqual(StoreReadSchedule.leeway(for: 1), 0.1, accuracy: 1e-9)
    }
}
