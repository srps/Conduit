// SPDX-License-Identifier: Apache-2.0

/// Consecutive observations of one subject that connected and then got no
/// answer, plus the conclusive failure that may stand beside them.
///
/// One silence says nothing (STYLE rule 11: slowness is not loss). The
/// second in a row is the failure. So is the first silence after a
/// conclusive failure (a refused or timed-out connect, a 5xx, a rejected
/// credential), because that subject was already known to be failing. An
/// answer clears both. A value with one owner per subject, written on that
/// owner's actor; it schedules nothing, so #181's primitive can hold one.
package struct UnansweredStreak: Equatable, Sendable {
    package struct Verdict: Equatable, Sendable {
        package let consecutive: Int
        package let isDecisive: Bool
    }

    /// Two in a row. Fixed by #197, not a config knob: a window that decides
    /// on its own is what rule 11 forbids.
    package static let decisiveCount = 2

    package private(set) var consecutive = 0
    package private(set) var failureStanding = false

    package init() {}

    /// Records one silence and says whether it is the one that counts.
    package mutating func recordUnanswered() -> Verdict {
        consecutive += 1
        let decisive = consecutive >= Self.decisiveCount || failureStanding
        if decisive { failureStanding = true }
        return Verdict(consecutive: consecutive, isDecisive: decisive)
    }

    /// A conclusive failure. It ends the silence streak and stands until an answer.
    package mutating func recordFailure() {
        consecutive = 0
        failureStanding = true
    }

    /// An answer. Clears the streak and the standing failure.
    package mutating func recordAnswer() {
        consecutive = 0
        failureStanding = false
    }

    /// For the sites where routing or the lifecycle moves on: the evidence
    /// measured the old network or run.
    package mutating func reset() { recordAnswer() }
}
