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
/// nothing here bounds it for them.
package struct PlatformWork: Sendable {
    private let queue: DispatchQueue

    package init(label: String) {
        queue = DispatchQueue(label: label, qos: .userInitiated)
    }

    package func run<T: Sendable>(_ work: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: work()) }
        }
    }
}
