// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How `RuntimeHost.settleStoppedEffects` ended. Only `.settled` says that the work the stopped host still ran, its
/// credential warm-up and the observer deliveries admitted before the call with their cascades, finished, in the state
/// that was stopped when the caller asked. The other outcomes are not quiescence.
package enum StoppedEffectsSettlement: Equatable, Sendable {
    /// The joined work finished, and no start or stop came in meanwhile.
    case settled
    /// The caller's deadline passed first. The join still runs, and holds the root's session, until its work finishes.
    case deadlineExpired
    /// A start is running, or a lifecycle operation is in flight, so nothing was joined.
    case runtimeActive
    /// A newer start or stop was admitted while the join was pending, so this result is stale.
    case superseded
    /// Another settle's join is still in flight on this host. Nothing was allocated.
    case busy
}

/// The one settle a host has in flight (capacity one), confined to the host's main actor.
///
/// Its caller waits on the first of three things: the join's own outcome, the caller's deadline, or a newer start or
/// stop. The waiter resumes exactly once, because `finish` records its outcome before it resumes anyone and ignores
/// later calls. The join is not this object's: the host runs it, and frees the slot when it ends.
@MainActor
final class StoppedEffectsJoin {
    /// The lifecycle generation and the config generation the settle observed. Either one moving means the host is no
    /// longer the one that was stopped, so the result is stale. Both are read-only here.
    let lifecycleGeneration: Int
    let configGeneration: Int
    private var waiter: CheckedContinuation<StoppedEffectsSettlement, Never>?
    private var result: StoppedEffectsSettlement?
    private var timer: Task<Void, Never>?

    init(lifecycleGeneration: Int, configGeneration: Int) {
        self.lifecycleGeneration = lifecycleGeneration
        self.configGeneration = configGeneration
    }

    /// Arms the caller's deadline. The deadline ends only the caller's wait, not the join.
    func armDeadline(_ deadline: ContinuousClock.Instant) {
        timer = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(until: deadline, clock: .continuous)
            } catch {
                // Cancelled by `finish`, which already gave the caller its answer.
                return
            }
            self?.finish(.deadlineExpired)
        }
    }

    /// The caller's answer. Installs the waiter synchronously, so an outcome that arrived first is returned at once.
    func outcome() async -> StoppedEffectsSettlement {
        await withCheckedContinuation { (continuation: CheckedContinuation<StoppedEffectsSettlement, Never>) in
            if let result {
                continuation.resume(returning: result)
            } else {
                waiter = continuation
            }
        }
    }

    /// Ends the caller's wait with `outcome`, at most once. Later calls change nothing.
    func finish(_ outcome: StoppedEffectsSettlement) {
        guard result == nil else { return }
        result = outcome
        timer?.cancel()
        timer = nil
        let pending = waiter
        waiter = nil
        pending?.resume(returning: outcome)
    }
}
