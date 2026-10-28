// SPDX-License-Identifier: Apache-2.0
import Dispatch

/// Where main-actor code sends platform work that blocks: a helper round
/// trip, a `networksetup` read, a liveness probe. Run inline, that work holds
/// the main thread for as long as the helper or the child takes, which
/// `HelperTransactionBudget` bounds at forty seconds and nothing makes short.
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
    /// before the call. The runtime host relies on that: a start checks its
    /// `LifecycleLane` token and queues its surface work with no suspension in
    /// between, so a stop issued after the check is queued after the start's
    /// work, and a stop issued before it is caught by the check.
    nonisolated(nonsending) package func run<T: Sendable>(
        _ work: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
