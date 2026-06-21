// SPDX-License-Identifier: Apache-2.0
// Locked-down decision-table tests for `WindowBehaviorView`'s coalescing
// logic. The original PR added an early-return guard against `lastApplied`
// to suppress per-body-refresh window-property reapplies; that guard had a
// race where rapid toggles within one run-loop turn could drop the final
// value (the early-return read `lastApplied` before the async block had a
// chance to update it). The fix tracks `pendingTarget` separately and
// makes both pieces of decision logic — "should updateNSView dispatch?"
// and "should the async block actually mutate the window?" — pure
// functions that we exercise here.

import XCTest
@testable import Conduit

final class WindowBehaviorCoalescingTests: XCTestCase {

    // MARK: - decideUpdate

    func testDecideUpdate_initialApplyWhenNothingApplied() {
        // Cold start: lastApplied=nil, no pending, target=true.
        // First call must always dispatch.
        let decision = WindowBehaviorView.decideUpdate(
            target: true,
            lastApplied: nil,
            pendingTarget: nil
        )
        XCTAssertEqual(decision, .scheduleApply(true))
    }

    func testDecideUpdate_steadyStateMatchSkips() {
        // The dominant case: SwiftUI re-renders the parent view ~1Hz while
        // proxy is active, calling updateNSView with the SAME `enabled`
        // value over and over. Must short-circuit without scheduling.
        let decision = WindowBehaviorView.decideUpdate(
            target: true,
            lastApplied: true,
            pendingTarget: nil
        )
        XCTAssertEqual(decision, .noChange,
                       "Steady-state same-value must early-return — that's the perf optimisation the original PR added.")
    }

    func testDecideUpdate_realTransitionSchedulesNewApply() {
        // User actually toggled. lastApplied=true, no pending, target=false.
        let decision = WindowBehaviorView.decideUpdate(
            target: false,
            lastApplied: true,
            pendingTarget: nil
        )
        XCTAssertEqual(decision, .scheduleApply(false))
    }

    func testDecideUpdate_midFlightSupersedesPendingOnly() {
        // Async block scheduled (pending=true), now caller wants false.
        // We must NOT schedule a second async block (the existing one
        // will pick up the latest pending), but we MUST update pending.
        let decision = WindowBehaviorView.decideUpdate(
            target: false,
            lastApplied: nil,
            pendingTarget: true
        )
        XCTAssertEqual(decision, .updatePendingOnly(false),
                       "Mid-flight toggle must mutate `pendingTarget` only — the existing async block reads the latest value at run time.")
    }

    func testDecideUpdate_midFlightMatchingPendingSkips() {
        // Pending already matches the target. No work needed.
        let decision = WindowBehaviorView.decideUpdate(
            target: true,
            lastApplied: nil,
            pendingTarget: true
        )
        XCTAssertEqual(decision, .noChange)
    }

    /// The reviewer's reported regression: `false → true → false` rapid
    /// sequence within a single run-loop turn must end with the window
    /// in `false` state, not stranded in `true` because the original
    /// guard skipped the second `false` call.
    func testDecideUpdate_reviewerReportedRapidToggleScenario() {
        // Initial state: lastApplied=false (steady), no pending.
        var lastApplied: Bool? = false
        var pendingTarget: Bool? = nil

        // Call 1: target=true. The first toggle.
        var decision = WindowBehaviorView.decideUpdate(
            target: true,
            lastApplied: lastApplied,
            pendingTarget: pendingTarget
        )
        XCTAssertEqual(decision, .scheduleApply(true),
                       "First toggle (false → true) must schedule an async apply.")
        // Apply the side effect of `scheduleApply` to the simulated
        // coordinator state.
        if case .scheduleApply(let v) = decision { pendingTarget = v }

        // Call 2: target=false. The user immediately toggled back BEFORE
        // any async block ran. Pre-fix this returned .noChange (the bug).
        decision = WindowBehaviorView.decideUpdate(
            target: false,
            lastApplied: lastApplied,
            pendingTarget: pendingTarget
        )
        XCTAssertEqual(decision, .updatePendingOnly(false),
                       "Mid-flight toggle back to the original `lastApplied` value MUST overwrite pendingTarget, not be dropped. This is the bug the reviewer reported.")
        if case .updatePendingOnly(let v) = decision { pendingTarget = v }

        // Now the async block fires. It reads pendingTarget (=false) and
        // sees lastApplied (=false) already matches → skip mutation.
        // Either way, the window is NOT left in the `true` state.
        let outcome = WindowBehaviorView.decideApplyOutcome(
            pendingTarget: pendingTarget,
            windowAvailable: true,
            lastApplied: lastApplied
        )
        XCTAssertEqual(outcome, .skip,
                       "Final state: pending matches lastApplied (both false). No window mutation needed — and crucially, the older `true` value is NOT applied.")
        // Simulate: pending always cleared by the async block.
        pendingTarget = nil

        XCTAssertEqual(lastApplied, false,
                       "Window remains correctly in `false` state after the rapid toggle.")
        XCTAssertNil(pendingTarget)
    }

    func testDecideUpdate_reverseRapidToggleScenario() {
        // Same shape but mirrored: lastApplied=true, then true → false → true.
        // Must also collapse cleanly to the no-op end state.
        var lastApplied: Bool? = true
        var pendingTarget: Bool? = nil

        var decision = WindowBehaviorView.decideUpdate(
            target: false,
            lastApplied: lastApplied,
            pendingTarget: pendingTarget
        )
        XCTAssertEqual(decision, .scheduleApply(false))
        if case .scheduleApply(let v) = decision { pendingTarget = v }

        decision = WindowBehaviorView.decideUpdate(
            target: true,
            lastApplied: lastApplied,
            pendingTarget: pendingTarget
        )
        XCTAssertEqual(decision, .updatePendingOnly(true))
        if case .updatePendingOnly(let v) = decision { pendingTarget = v }

        let outcome = WindowBehaviorView.decideApplyOutcome(
            pendingTarget: pendingTarget,
            windowAvailable: true,
            lastApplied: lastApplied
        )
        XCTAssertEqual(outcome, .skip)
        pendingTarget = nil
        XCTAssertEqual(lastApplied, true)
        XCTAssertNil(pendingTarget)
    }

    // MARK: - decideApplyOutcome

    func testDecideApplyOutcome_appliesWhenWindowReadyAndDifferent() {
        let outcome = WindowBehaviorView.decideApplyOutcome(
            pendingTarget: true,
            windowAvailable: true,
            lastApplied: nil
        )
        XCTAssertEqual(outcome, .apply(true))
    }

    func testDecideApplyOutcome_skipsWhenWindowNotReady() {
        // First call may run while the SwiftUI host hasn't attached the
        // NSView to a window yet. The async block must skip and leave
        // pending cleared so the next updateNSView retries.
        let outcome = WindowBehaviorView.decideApplyOutcome(
            pendingTarget: true,
            windowAvailable: false,
            lastApplied: nil
        )
        XCTAssertEqual(outcome, .skip)
    }

    func testDecideApplyOutcome_skipsWhenPendingMatchesLastApplied() {
        // Mid-flight toggle sequence collapsed back to the applied value.
        // No mutation needed.
        let outcome = WindowBehaviorView.decideApplyOutcome(
            pendingTarget: true,
            windowAvailable: true,
            lastApplied: true
        )
        XCTAssertEqual(outcome, .skip,
                       "Pending matches lastApplied — the toggle burst collapsed to a no-op.")
    }

    func testDecideApplyOutcome_skipsWhenPendingNil() {
        // Defensive: shouldn't happen in practice (updateNSView only
        // schedules when pending is being set), but the helper is total.
        let outcome = WindowBehaviorView.decideApplyOutcome(
            pendingTarget: nil,
            windowAvailable: true,
            lastApplied: nil
        )
        XCTAssertEqual(outcome, .skip)
    }

    // MARK: - Multi-call sequences (decision-table style)

    /// Simulates the steady-state SwiftUI re-render storm: 100 calls with
    /// the same `enabled` value. Must produce 0 schedules after the first
    /// apply lands.
    func testSteadyStateBurstSchedulesOnce() {
        var lastApplied: Bool? = nil
        var pendingTarget: Bool? = nil
        var scheduleCount = 0
        var pendingMutationCount = 0

        for _ in 0..<100 {
            let decision = WindowBehaviorView.decideUpdate(
                target: true,
                lastApplied: lastApplied,
                pendingTarget: pendingTarget
            )
            switch decision {
            case .noChange:
                break
            case .scheduleApply(let v):
                scheduleCount += 1
                pendingTarget = v
                // Simulate the async block firing immediately for the test.
                let outcome = WindowBehaviorView.decideApplyOutcome(
                    pendingTarget: pendingTarget,
                    windowAvailable: true,
                    lastApplied: lastApplied
                )
                pendingTarget = nil
                if case .apply(let applied) = outcome { lastApplied = applied }
            case .updatePendingOnly(let v):
                pendingMutationCount += 1
                pendingTarget = v
            }
        }

        XCTAssertEqual(scheduleCount, 1,
                       "100 calls with the same target must produce exactly 1 schedule (the first one). The remaining 99 must early-return — that's the perf contract.")
        XCTAssertEqual(pendingMutationCount, 0)
        XCTAssertEqual(lastApplied, true)
        XCTAssertNil(pendingTarget)
    }
}
