// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class UnansweredStreakTests: XCTestCase {
    func testTheSecondConsecutiveSilenceIsDecisive() {
        var streak = UnansweredStreak()
        XCTAssertEqual(streak.recordUnanswered(), .init(consecutive: 1, isDecisive: false))
        XCTAssertEqual(streak.recordUnanswered(), .init(consecutive: 2, isDecisive: true))
        XCTAssertEqual(streak.recordUnanswered(), .init(consecutive: 3, isDecisive: true))
    }

    func testAnAnswerBetweenTwoSilencesKeepsTheSecondHeld() {
        var streak = UnansweredStreak()
        _ = streak.recordUnanswered()
        streak.recordAnswer()
        XCTAssertFalse(streak.recordUnanswered().isDecisive)
    }

    func testAStandingFailureMakesTheNextSilenceDecisive() {
        var streak = UnansweredStreak()
        streak.recordFailure()
        XCTAssertEqual(streak.recordUnanswered(), .init(consecutive: 1, isDecisive: true))
        streak.recordAnswer()
        XCTAssertFalse(streak.recordUnanswered().isDecisive, "the answer cleared the standing failure")
    }

    func testADecisiveSilenceStandsLikeAFailure() {
        var streak = UnansweredStreak()
        _ = streak.recordUnanswered()
        _ = streak.recordUnanswered()
        streak.recordFailure()
        XCTAssertTrue(streak.recordUnanswered().isDecisive)
    }

    func testResetIsAnAnswer() {
        var streak = UnansweredStreak()
        streak.recordFailure()
        streak.reset()
        XCTAssertEqual(streak, UnansweredStreak())
    }
}
