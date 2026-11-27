// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The published key's deadline, shared with a thread off the helper's loop, so a command that holds the loop cannot keep
/// a key past `VPNDNSOverridePublisher.unverifiedSecondsToWithdraw` without a confirmed answer.
package final class VPNDNSOverrideExpiry: @unchecked Sendable {
    private let lock = NSLock()
    private var deadline: UInt64?

    package init() {}

    /// Monotonic nanoseconds, or nil while no key of this session is published.
    package func update(_ deadline: UInt64?) {
        lock.withLock { self.deadline = deadline }
    }

    /// Runs `remove` once the deadline has passed and clears it, under the lock, so the loop cannot set a new deadline
    /// in between. Nil when nothing was due; otherwise whether the removal succeeded.
    package func expire(now: UInt64, remove: () -> Bool) -> Bool? {
        lock.withLock {
            guard let deadline, now >= deadline else { return nil }
            self.deadline = nil
            return remove()
        }
    }
}
