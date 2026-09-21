// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The hops a runtime host makes from an observer's callback onto the main
/// actor, counted so that something can wait for them.
///
/// The VPN observer, the path monitor, the wake notification and the
/// orchestrator's snapshot and event callbacks all arrive off the main actor
/// or mid-mutation, and each host hands them over with an unstructured
/// `Task { @MainActor in ... }`. Nothing held those tasks, so a test that
/// drove an observer could only poll the snapshot or sleep, and a poll can
/// pass on a stale intermediate state (#19).
///
/// A delivery often starts another: the VPN handler starts the orchestrator's
/// async handling, whose snapshot comes back through the snapshot callback.
/// Those start before the delivery that caused them finishes, so the count
/// does not touch zero in between and `drain()` returns only when the whole
/// cascade has landed. That holds for work started through `deliver`; a hop
/// made some other way is not waited for.
///
/// Deliveries are not serialised behind one another. They run as they did
/// before, each its own task, because a snapshot must not wait behind a VPN
/// handler that is still awaiting the orchestrator.
package final class ObserverDeliveries: @unchecked Sendable {
    /// `drain()` callers waiting at once. The callers are test harnesses and
    /// there is one of each; this is a bound, not a budget.
    package static let maximumWaiters = 8

    private let lock = NSLock()
    private var inFlight = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    package init() {}

    /// Deliveries started and not yet finished.
    package var inFlightCount: Int {
        lock.withLock { inFlight }
    }

    /// Runs `work` on the main actor in its own task. Callable from any
    /// thread, which is where the observers call from.
    package func deliver(_ work: @escaping @MainActor @Sendable () async -> Void) {
        lock.withLock { inFlight += 1 }
        Task { @MainActor in
            await work()
            self.finishOne()
        }
    }

    /// Returns once no delivery is in flight, at once if none is.
    package func drain() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let idle = lock.withLock { () -> Bool in
                guard inFlight > 0 else { return true }
                precondition(waiters.count < Self.maximumWaiters, "more than \(Self.maximumWaiters) concurrent drain() callers")
                waiters.append(continuation)
                return false
            }
            if idle { continuation.resume() }
        }
    }

    private func finishOne() {
        let resumed = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            precondition(inFlight > 0, "a delivery finished that was never started")
            inFlight -= 1
            guard inFlight == 0 else { return [] }
            defer { waiters = [] }
            return waiters
        }
        for continuation in resumed { continuation.resume() }
    }
}
