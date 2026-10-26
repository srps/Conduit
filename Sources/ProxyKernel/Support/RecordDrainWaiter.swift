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
/// Each wait makes a reservation with two parts: the group's `notify`, and one detached `Task` that sleeps until the
/// absolute deadline. A part is released only when it acknowledges: the notify by firing, the task by its body ending.
/// A caller that drains, times out or is cancelled returns at once, but its parts stay held until they quiesce.
///
/// One caller waits at a time, and at most one notify is outstanding, whatever the timer slots. A wait made while
/// either is held is `.busy`, so a timed-out or cancelled wait, whose notify stays registered, refuses the next one.
/// `timerSlots` bounds the timer bodies that may run at once, retired ones included, across every call. With the
/// default of one, a drained caller's cancelled timer body also refuses the next wait until it ends. A second slot lets
/// one new wait register beside that retired body; when every slot is held, the wait is `.busy`.
///
/// The timer is a `Task` and not a `DispatchSourceTimer` because a dispatch timer runs on uptime, which excludes sleep,
/// while `ContinuousClock` advances across sleep. The sleep seam is injected so tests can simulate expiry and cancel
/// cleanup without the machine's clock.
///
/// The waiter holds its core strongly. Every callback holds the core weakly, so no callback keeps the caller's waiter
/// alive. Continuations and the cleanup seam run outside the state lock.
package final class RecordDrainWaiter: @unchecked Sendable {
    /// The most timer slots a waiter may be given: a first wait, and one further wait beside its retired timer body.
    package static let maxTimerSlots = 2

    private let core: Core

    /// `timerSlots` is between one and `maxTimerSlots`. `onCleanup` runs each time the last held part is released; it
    /// is delivered as its own block on the serial queue, after the callbacks that released that part have returned.
    /// `onTimerReleased` runs when a timer's body ends. `onRegistered` runs once a wait's reservation exists. `sleep`
    /// defaults to a sleep until the deadline on the continuous clock.
    package init(group: DispatchGroup, timerSlots: Int = 1, onCleanup: (@Sendable () -> Void)? = nil,
                 onTimerReleased: (@Sendable () -> Void)? = nil,
                 onRegistered: (@Sendable () -> Void)? = nil,
                 sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = { deadline in
                     try await Task.sleep(until: deadline, clock: .continuous)
                 }) {
        precondition((1...Self.maxTimerSlots).contains(timerSlots))
        core = Core(group: group, timerSlots: timerSlots, onCleanup: onCleanup, onTimerReleased: onTimerReleased,
                    onRegistered: onRegistered, sleep: sleep)
    }

    /// Waits until the group drains or `deadline` passes. The deadline is absolute and is checked again at
    /// registration, so a late registration gets only what the deadline still has, never a fresh window.
    package func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
        await core.drain(until: deadline)
    }

    private final class Core: @unchecked Sendable {
        /// One caller's wait, and the identity of its reservation. Settled exactly once, by whichever of notify, expiry or
        /// cancellation takes it first. Its fields are read and written under the state lock.
        final class Pending: @unchecked Sendable {
            var continuation: CheckedContinuation<RecordDrainOutcome, Never>?
            var cancelRequested = false
            /// This wait's timer, from registration until its body ends.
            var timer: Task<Void, Never>?
        }

        struct State {
            /// The wait whose group notify is registered and has not fired. At most one, whatever the timer slots.
            var notifyOwner: Pending?
            /// The waits whose timer body has not ended, at most `timerSlots`. Only a wait's own timer removes it.
            var liveTimers: [Pending] = []
            /// The one caller waiting now.
            var current: Pending?
        }

        private static let resolutionQueue = DispatchQueue(label: "conduit.record-drain-waiter", qos: .utility)

        private let group: DispatchGroup
        private let timerSlots: Int
        private let state: NIOLockedValueBox<State>
        private let onCleanup: (@Sendable () -> Void)?
        private let onTimerReleased: (@Sendable () -> Void)?
        private let onRegistered: (@Sendable () -> Void)?
        private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

        init(group: DispatchGroup, timerSlots: Int, onCleanup: (@Sendable () -> Void)?,
             onTimerReleased: (@Sendable () -> Void)?, onRegistered: (@Sendable () -> Void)?,
             sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void) {
            self.group = group
            self.timerSlots = timerSlots
            var initial = State()
            initial.liveTimers.reserveCapacity(timerSlots)
            state = NIOLockedValueBox(initial)
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
                        if s.current != nil || s.notifyOwner != nil || s.liveTimers.count >= timerSlots { return .busy }
                        let remaining = ContinuousClock.now.duration(to: deadline)
                        guard remaining > .zero else { return .skippedBudget }
                        pending.continuation = continuation
                        s.current = pending
                        s.notifyOwner = pending
                        // Both calls only schedule work; neither runs a callback while the lock is held.
                        group.notify(queue: Self.resolutionQueue) { [weak self] in self?.finishedGroup() }
                        let sleepUntil = sleep
                        // This reservation's timer. Its body ends its own timer part, however it ends. It holds its
                        // wait so the release removes exactly that wait's entry; the wait drops the task once it has.
                        pending.timer = Task.detached(priority: .utility) { [weak self, pending] in
                            defer { self?.timerReleased(pending) }
                            // A cancelled sleep means the caller was already settled by the notify or cancel path.
                            do { try await sleepUntil(deadline) } catch { return }
                            self?.timedOut(pending)
                        }
                        s.liveTimers.append(pending)
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

        /// The group emptied: the notify is spent. Its owner drained if it is still the caller waiting, and its reservation
        /// ends once its timer body has ended.
        private func finishedGroup() {
            let detached = state.withLockedValue { s -> (CheckedContinuation<RecordDrainOutcome, Never>?, Task<Void, Never>?, Bool) in
                guard let owner = s.notifyOwner else { return (nil, nil, false) }
                s.notifyOwner = nil
                var continuation: CheckedContinuation<RecordDrainOutcome, Never>?
                if s.current === owner {
                    s.current = nil
                    continuation = owner.continuation
                    owner.continuation = nil
                }
                return (continuation, owner.timer, s.liveTimers.isEmpty)
            }
            // The caller resolves now. Only its timer part stays reserved, until its body ends. The timer is cancelled
            // here, but a held body may outlive that cancel and keeps its slot until it ends.
            detached.1?.cancel()
            detached.0?.resume(returning: .drained)
            if detached.2 { deliverCleanup() }
        }

        /// The deadline passed. The group has not drained, so the notify stays registered and the reservation stays held.
        /// A timer whose wait was already settled settles nothing.
        private func timedOut(_ pending: Pending) {
            let detached = state.withLockedValue { s -> (CheckedContinuation<RecordDrainOutcome, Never>?, Task<Void, Never>?) in
                guard s.current === pending else { return (nil, nil) }
                s.current = nil
                let continuation = pending.continuation
                pending.continuation = nil
                return (continuation, pending.timer)
            }
            detached.1?.cancel()
            detached.0?.resume(returning: .timedOut)
        }

        /// A timer body ended. Its slot is released; another wait's timer or the notify may still be held.
        private func timerReleased(_ pending: Pending) {
            let quiescent = state.withLockedValue { s -> Bool in
                if let index = s.liveTimers.firstIndex(where: { $0 === pending }) {
                    s.liveTimers.remove(at: index)
                }
                pending.timer = nil
                return s.liveTimers.isEmpty && s.notifyOwner == nil
            }
            onTimerReleased?()
            if quiescent { deliverCleanup() }
        }

        /// The caller's task was cancelled. The writer's work continues, the wait's own timer is cancelled, and the notify
        /// stays held.
        private func cancel(_ pending: Pending) {
            let detached = state.withLockedValue { s -> (CheckedContinuation<RecordDrainOutcome, Never>?, Task<Void, Never>?) in
                pending.cancelRequested = true
                guard s.current === pending else { return (nil, nil) }
                s.current = nil
                let continuation = pending.continuation
                pending.continuation = nil
                return (continuation, pending.timer)
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
