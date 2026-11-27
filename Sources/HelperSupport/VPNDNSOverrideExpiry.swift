// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The published key's deadline, shared with a thread off the helper's loop, so a command that holds the loop cannot keep
/// a key past `VPNDNSOverridePublisher.unverifiedSecondsToWithdraw` without a confirmed answer. The watchdog acts only
/// between the loop's steps, and each step learns first whether it removed the key.
package final class VPNDNSOverrideExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: UInt64?
    private var removed = false

    package init() {}

    /// One step of the loop, which the watchdog cannot interleave with. `body` is told whether the watchdog removed the
    /// key since the last step, and returns its result and the deadline of the key it leaves published, if any.
    package func step<T>(_ body: (_ removedByWatchdog: Bool) -> (T, deadline: UInt64?)) -> T {
        lock.withLock {
            let removedByWatchdog = removed
            removed = false
            let (result, deadline) = body(removedByWatchdog)
            self.deadline = deadline
            return result
        }
    }

    /// Runs `remove` once the deadline has passed. Nil when nothing was due; otherwise whether the removal succeeded.
    /// A refused removal stays due, so the next wake tries it again.
    package func expire(now: UInt64, remove: () -> Bool) -> Bool? {
        lock.withLock {
            guard let deadline, now >= deadline else { return nil }
            guard remove() else { return false }
            self.deadline = nil
            removed = true
            return true
        }
    }
}
