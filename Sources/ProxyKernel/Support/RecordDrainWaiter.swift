// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers

/// How an awaited drain ended. This is a fact about the queue only: `drained` means the queued records left the queue,
/// not that they were written. Loss is counted separately in the writer's statistics. `skippedBudget` is decided by the
/// caller that owns a phase deadline, and `unavailable` by a sink that cannot drain asynchronously.
package enum RecordDrainOutcome: String, Sendable, Equatable {
    case drained
    case timedOut = "timed_out"
    case busy
    case skippedBudget = "skipped_budget"
    case cancelled
    case unavailable
}

/// Awaits one `DispatchGroup` without blocking the caller.
///
/// One reservation is physically outstanding at a time. It has two parts: the group's `notify`, and one detached
/// `Task` that sleeps until the absolute deadline. The reservation is released only when both have acknowledged: the
/// notify by firing, the task by its body ending. A caller that times out or is cancelled returns at once, but the
/// reservation stays held until both parts quiesce, so a wait made meanwhile is `.busy`.
///
/// The timer is a `Task` and not a `DispatchSourceTimer` because a dispatch timer runs on uptime, which excludes sleep,
/// while `ContinuousClock` advances across sleep. The sleep seam is injected so tests can simulate expiry and cancel
/// cleanup without the machine's clock.
///
/// The waiter holds its core strongly. Every callback holds the core weakly, so no callback keeps the caller's waiter
/// alive. Continuations and the cleanup seam run outside the state lock.
package final class RecordDrainWaiter: @unchecked Sendable {
    private let core: Core

    /// `onCleanup` runs once both parts are released; it is delivered as its own block on the serial queue, after the
    /// callbacks that released the last part have returned. `onTimerReleased` runs when the timer's body ends.
    /// `onRegistered` runs once a wait's reservation exists. `sleep` defaults to a sleep until the deadline on the
    /// continuous clock.
    package init(group: DispatchGroup, onCleanup: (@Sendable () -> Void)? = nil,
                 onTimerReleased: (@Sendable () -> Void)? = nil,
                 onRegistered: (@Sendable () -> Void)? = nil,
                 sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { deadline in
                     try await Task.sleep(until: deadline, clock: .continuous)
                 }) {
        core = Core(group: group, onCleanup: onCleanup, onTimerReleased: onTimerReleased,
                    onRegistered: onRegistered, sleep: sleep)
    }

    /// Waits until the group drains or `deadline` passes. The deadline is absolute and is checked again at
    /// registration, so a late registration gets only what the deadline still has, never a fresh window.
    package func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
        await core.drain(until: deadline)
    }

    private final class Core: @unchecked Sendable {
        /// One caller's wait. Settled exactly once, by whichever of notify, expiry or cancellation takes it first.
        final class Pending: @unchecked Sendable {
            var continuation: CheckedContinuation<RecordDrainOutcome, Never>?
            var cancelRequested = false
        }

        struct State {
            /// The group's notify is registered and has not fired.
            var notifyOutstanding = false
            /// The timer task exists and its body has not ended.
            var timerOutstanding = false
            var timer: Task<Void, Never>?
            var current: Pending?
        }

        private static let resolutionQueue = DispatchQueue(label: "conduit.record-drain-waiter", qos: .utility)

        private let group: DispatchGroup
        private let state = NIOLockedValueBox(State())
        private let onCleanup: (@Sendable () -> Void)?
        private let onTimerReleased: (@Sendable () -> Void)?
        private let onRegistered: (@Sendable () -> Void)?
        private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

        init(group: DispatchGroup, onCleanup: (@Sendable () -> Void)?, onTimerReleased: (@Sendable () -> Void)?,
             onRegistered: (@Sendable () -> Void)?, sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
            self.group = group
            self.onCleanup = onCleanup
            self.onTimerReleased = onTimerReleased
            self.onRegistered = onRegistered
            self.sleep = sleep
        }

        func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
            if groupIsEmpty() { return .drained }
            let pending = Pending()
            return await withTaskCancellationHandler {
                await withCheckedContinuation { (continuation: CheckedContinuation<RecordDrainOutcome, Never>) in
                    let immediate = state.withLockedValue { s -> RecordDrainOutcome? in
                        if pending.cancelRequested { return .cancelled }
                        if s.notifyOutstanding || s.timerOutstanding { return .busy }
                        let remaining = ContinuousClock.now.duration(to: deadline)
                        guard remaining > .zero else { return .skippedBudget }
                        pending.continuation = continuation
                        s.current = pending
                        s.notifyOutstanding = true
                        s.timerOutstanding = true
                        // Both calls only schedule work; neither runs a callback while the lock is held.
                        group.notify(queue: Self.resolutionQueue) { [weak self] in self?.finishedGroup() }
                        let sleepUntil = sleep
                        // The one timer for this reservation. Its body ends the timer part, however it ends.
                        s.timer = Task.detached(priority: .utility) { [weak self, weak pending] in
                            defer { self?.timerReleased() }
                            // A cancelled sleep means the caller was already settled by the cancel path.
                            do { try await sleepUntil(deadline) } catch { return }
                            self?.timedOut(pending)
                        }
                        return nil
                    }
                    if let immediate {
                        continuation.resume(returning: immediate)
                    } else {
                        onRegistered?()
                    }
                }
            } onCancel: { [self] in
                cancel(pending)
            }
        }

        /// A non-blocking read of the group. The owner enters and leaves it under its own lock. It stays out of the async
        /// `drain`, where `DispatchGroup.wait` is unavailable.
        private func groupIsEmpty() -> Bool {
            group.wait(timeout: .now()) == .success
        }

        /// The group emptied: the notify is spent. The caller drained, and the reservation ends once the timer body has ended.
        private func finishedGroup() {
            let detached = state.withLockedValue { s -> (CheckedContinuation<RecordDrainOutcome, Never>?, Task<Void, Never>?, Bool) in
                s.notifyOutstanding = false
                let continuation = s.current?.continuation
                s.current?.continuation = nil
                s.current = nil
                return (continuation, s.timer, !s.timerOutstanding)
            }
            // The caller resolves now. Only the physical timer part stays reserved, until its body ends. The timer is
            // cancelled here, but a held body may outlive that cancel, and the next non-empty wait is busy until it ends.
            detached.1?.cancel()
            detached.0?.resume(returning: .drained)
            if detached.2 { deliverCleanup() }
        }

        /// The deadline passed. The group has not drained, so the notify stays registered and the reservation stays held.
        private func timedOut(_ pending: Pending?) {
            let detached = state.withLockedValue { s -> (CheckedContinuation<RecordDrainOutcome, Never>?, Task<Void, Never>?) in
                guard let pending, s.current === pending else { return (nil, nil) }
                s.current = nil
                let continuation = pending.continuation
                pending.continuation = nil
                return (continuation, s.timer)
            }
            detached.1?.cancel()
            detached.0?.resume(returning: .timedOut)
        }

        /// The timer body ended. Its part of the reservation is released; the notify's may still be held.
        private func timerReleased() {
            let quiescent = state.withLockedValue { s -> Bool in
                s.timerOutstanding = false
                s.timer = nil
                return !s.notifyOutstanding
            }
            onTimerReleased?()
            if quiescent { deliverCleanup() }
        }

        /// The caller's task was cancelled. The writer's work continues, the timer is cancelled, and the notify stays held.
        private func cancel(_ pending: Pending) {
            let detached = state.withLockedValue { s -> (CheckedContinuation<RecordDrainOutcome, Never>?, Task<Void, Never>?) in
                pending.cancelRequested = true
                guard s.current === pending else { return (nil, nil) }
                s.current = nil
                let continuation = pending.continuation
                pending.continuation = nil
                return (continuation, s.timer)
            }
            detached.1?.cancel()
            detached.0?.resume(returning: .cancelled)
        }

        /// Runs the cleanup seam as a later block on the serial queue. The block that released the last part has returned
        /// by then. The closure captured here holds no reference to the core.
        private func deliverCleanup() {
            guard let cleanup = onCleanup else { return }
            Self.resolutionQueue.async { cleanup() }
        }
    }
}
