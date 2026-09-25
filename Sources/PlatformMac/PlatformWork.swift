// SPDX-License-Identifier: Apache-2.0
import Dispatch

/// Where a runtime host sends platform work that blocks: a helper round trip,
/// a `networksetup` read, a liveness probe. Both hosts are main-actor types,
/// and run inline that work holds the main thread for as long as the helper
/// or the child takes, which `HelperTransactionBudget` bounds at forty
/// seconds and nothing makes short.
///
/// A queue of its own rather than a detached task: the work blocks its
/// thread, and the cooperative pool has only as many threads as cores.
/// Serial, so two pieces of platform work land in the order they were sent.
/// The callers keep the queue short themselves, one item per kind in flight;
/// nothing here bounds it for them. The start and stop paths each await their
/// block before queueing the next, a superseded one queues nothing more, and
/// a repeat of the one in flight joins it instead of queueing (`LifecycleLane`),
/// so they add at most one item per lane in flight.
package struct PlatformWork: Sendable {
    private let queue: DispatchQueue

    package init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    /// Queues `work` and waits for its result.
    ///
    /// Runs on the caller's actor up to the point `work` is queued, so the
    /// queueing happens in the same turn as whatever the caller checked just
    /// before the call. The hosts rely on that: a start checks its
    /// `LifecycleLane` token and queues its surface work with no suspension in
    /// between, so a stop issued after the check is queued after the start's
    /// work, and a stop issued before it is caught by the check.
    package func run<T: Sendable>(
        isolation: isolated (any Actor)? = #isolation,
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation(isolation: isolation) { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }

    /// Blocks the calling thread until everything queued so far has run, or
    /// until `timeout` passes. Returns whether the queue drained.
    ///
    /// For a caller that cannot suspend and must not overlap the queue: the
    /// app's termination cleanup, synchronous by AppKit's contract, whose
    /// clears would otherwise interleave with a start's apply still out here.
    /// Bounded because a helper that is held keeps the queue busy for up to
    /// its transaction budget per call, and a quit must not wait that out.
    /// Nothing queued may wait on the caller's thread.
    package func waitUntilIdle(timeout: DispatchTimeInterval) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        return drained.wait(timeout: .now() + timeout) == .success
    }
}
