// SPDX-License-Identifier: Apache-2.0
import ProxyKernel

/// Which start or stop of one runtime is the latest, so an earlier one that
/// is still in flight can tell it has been overtaken.
///
/// Both hosts send a start's and a stop's platform-surface work to the same
/// serial `PlatformWork` queue, and each suspends while that work runs. The
/// queue orders the work: a stop issued while a start's apply is out queues
/// its clear behind that apply, so the machine ends cleared. What the queue
/// cannot do is stop the start from carrying on when its apply returns and
/// doing what follows a start — the DNS forwarder, the health timer, the
/// "Proxy Enabled" notification — for a runtime that is already down. That
/// is what this is for.
///
/// Every start and every stop calls `advance()` first and keeps the value.
/// After each suspension it checks `isCurrent(_:)`; once it is not, it does
/// nothing more, because the operation that superseded it owns the surfaces
/// now and has queued its own work behind whatever this one queued. The check
/// and the next queueing happen in one turn of the host's actor (see
/// `PlatformWork.run`), so nothing can slip between them.
package struct RuntimeGeneration: Sendable {
    package private(set) var current = 0

    package init() {}

    /// Starts a new operation and returns its generation. Every operation
    /// already in flight is superseded from here on.
    package mutating func advance() -> Int {
        current += 1
        return current
    }

    package func isCurrent(_ generation: Int) -> Bool {
        generation == current
    }

    /// The `lifecycle.superseded` event for `operation`, which stopped
    /// after its last suspension instead of going on. `reason` is
    /// `superseded` when a later start or stop overtook it, or the runtime
    /// state that made its follow-ups moot.
    package func supersededEvent(operation: String, generation: Int, reason: String = "superseded") -> RuntimeEvent {
        RuntimeEvent(
            kind: .lifecycle,
            event: "lifecycle.superseded",
            detail: "operation=\(operation) generation=\(generation) current=\(current) reason=\(reason)"
        )
    }
}
