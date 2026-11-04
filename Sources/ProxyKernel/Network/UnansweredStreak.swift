// SPDX-License-Identifier: Apache-2.0

/// Consecutive observations of one subject that connected and then got no
/// answer, plus the conclusive failure that may stand beside them.
///
/// One silence says nothing (STYLE rule 11: slowness is not loss). The
/// second in a row is the failure. So is the first silence after a
/// conclusive failure (a refused or timed-out connect, a 5xx, a rejected
/// credential), because that subject was already known to be failing. An
/// answer clears both.
package struct UnansweredStreak: Equatable, Sendable {
    package struct Verdict: Equatable, Sendable {
        package let consecutive: Int
        package let isDecisive: Bool
    }

    package static let decisiveCount = 2

    package private(set) var consecutive = 0
    package private(set) var failureStanding = false

    package init() {}

    package mutating func recordUnanswered() -> Verdict {
        consecutive += 1
        let decisive = consecutive >= Self.decisiveCount || failureStanding
        if decisive { failureStanding = true }
        return Verdict(consecutive: consecutive, isDecisive: decisive)
    }

    package mutating func recordFailure() {
        consecutive = 0
        failureStanding = true
    }

    package mutating func recordAnswer() {
        consecutive = 0
        failureStanding = false
    }

    package mutating func reset() { recordAnswer() }
}
