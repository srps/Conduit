// SPDX-License-Identifier: Apache-2.0
import AppKit
import ProxyKernel
import SwiftUI

struct WindowBehaviorView: NSViewRepresentable {
    let enabled: Bool

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        NSView()
    }

    /// SwiftUI re-evaluates `MainView`'s body whenever the runtime adapter
    /// publishes (≥ 1 Hz when proxy is active), and that re-render walks
    /// `.background(WindowBehaviorView(...))` which calls back into
    /// `updateNSView`. Without coalescing we'd dispatch a window-property
    /// reapply on every body refresh — cheap individually, but it churns
    /// AppKit's NSWindow KVO observers and produces noise in `sample` runs.
    ///
    /// Two pieces of state on the coordinator:
    ///   - `lastApplied` is what we successfully wrote to the window.
    ///   - `pendingTarget` is the latest `enabled` value waiting for an
    ///     async block to run. `nil` when no apply is in flight.
    ///
    /// The early-return compares `target` against the most recent *intent*
    /// (`pendingTarget ?? lastApplied`), not just `lastApplied`. This is
    /// load-bearing for rapid toggle sequences within a single run-loop
    /// turn: a `false → true → false` burst would otherwise drop the
    /// final `false` (the guard would see `lastApplied == false` and skip
    /// scheduling), then leave the still-queued `true` block to apply,
    /// stranding the window in the wrong level until another
    /// `updateNSView` fired.
    ///
    /// Mid-flight toggles overwrite `pendingTarget`; the existing async
    /// block reads the *latest* `pendingTarget` when it runs, so we
    /// schedule at most one block per pending intent and the block always
    /// applies the freshest value. The decision is encoded in
    /// `decideUpdate(target:lastApplied:pendingTarget:)` and
    /// `decideApplyOutcome(...)` static helpers so the coalescing logic is
    /// testable as pure functions without standing up a SwiftUI host.
    func updateNSView(_ nsView: NSView, context: Context) {
        let coord = context.coordinator
        let decision = WindowBehaviorView.decideUpdate(
            target: enabled,
            lastApplied: coord.lastApplied,
            pendingTarget: coord.pendingTarget
        )
        switch decision {
        case .noChange:
            return
        case .updatePendingOnly(let newPending):
            // An async block is already in flight; it'll pick up the new
            // pending value when it runs. No new dispatch needed.
            coord.pendingTarget = newPending
        case .scheduleApply(let newPending):
            coord.pendingTarget = newPending
            DispatchQueue.main.async {
                let outcome = WindowBehaviorView.decideApplyOutcome(
                    pendingTarget: coord.pendingTarget,
                    windowAvailable: nsView.window != nil,
                    lastApplied: coord.lastApplied
                )
                // Always clear pending before any apply: if the apply
                // itself bounces (window not yet attached) the next
                // updateNSView re-checks intent and schedules afresh.
                coord.pendingTarget = nil
                guard case .apply(let toApply) = outcome,
                      let window = nsView.window else {
                    return
                }
                window.level = toApply ? .floating : .normal
                window.titleVisibility = .hidden
                window.titlebarAppearsTransparent = true
                coord.lastApplied = toApply
            }
        }
    }

    /// Pure decision: given the caller's `target`, the value we last
    /// applied, and any in-flight `pendingTarget`, decide whether to
    /// schedule a new async apply, just update the in-flight pending, or
    /// short-circuit. Extracted so the rapid-toggle behaviour
    /// (`false → true → false` collapses to no work when `lastApplied`
    /// already equals the final value) is testable without a SwiftUI
    /// host.
    enum UpdateDecision: Equatable {
        case noChange
        case updatePendingOnly(Bool)
        case scheduleApply(Bool)
    }
    static func decideUpdate(
        target: Bool,
        lastApplied: Bool?,
        pendingTarget: Bool?
    ) -> UpdateDecision {
        // Compare against the most recent intent — pending takes priority
        // over applied because a still-pending value will overwrite the
        // applied one when its block runs.
        let currentIntent = pendingTarget ?? lastApplied
        if currentIntent == target { return .noChange }
        if pendingTarget != nil { return .updatePendingOnly(target) }
        return .scheduleApply(target)
    }

    /// Pure decision for the async block: given the freshest pending
    /// target plus whether the window is available and what we last
    /// applied, decide whether to actually mutate the window. Surfaces
    /// the "pending was cleared mid-flight" and "value matches
    /// lastApplied so don't bother" cases.
    enum ApplyOutcome: Equatable {
        case skip
        case apply(Bool)
    }
    static func decideApplyOutcome(
        pendingTarget: Bool?,
        windowAvailable: Bool,
        lastApplied: Bool?
    ) -> ApplyOutcome {
        guard windowAvailable, let toApply = pendingTarget else { return .skip }
        if lastApplied == toApply { return .skip }
        return .apply(toApply)
    }

    @MainActor
    final class Coordinator {
        /// Last `enabled` value successfully written to the host window.
        /// `nil` until the first apply completes.
        var lastApplied: Bool?
        /// Latest `enabled` value waiting to be applied by an in-flight
        /// async block. `nil` when no apply is pending. Mutated
        /// synchronously by `updateNSView` so rapid toggles within a
        /// single run-loop turn collapse to the freshest value.
        var pendingTarget: Bool?
    }
}
