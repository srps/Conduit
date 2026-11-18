// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Makes a store observer's `stop` a barrier for its deliveries: once `stop`
/// returns, nothing its stopped session admitted reaches the consumer or
/// changes what the observer exposes.
///
/// A delivery checks its generation and publishes, state and callbacks
/// together, inside `deliver`; `stop` ends the generation inside `stop`. Both
/// enter one critical section, so `stop` waits out a delivery in flight on
/// another thread, and a delivery that enters after it finds its generation
/// gone. A check made outside, then a publish, leaves a window in which a
/// stop and a restart can pass, and the old session's reading lands in the
/// new one.
///
/// The section is recursive, so a consumer may call `stop` or `start` from
/// inside its own callback: that `stop` returns at once and ends the session
/// there, and the delivery that called it must check its generation again
/// before each later step it publishes. A callback must not wait on another
/// thread that may call `stop`, as that thread waits for the callback.
///
/// Lock order: this section, then the observer's lifecycle lock, never the
/// reverse. The hosts call `stop` on `RuntimeActor` holding no lock, and their
/// callbacks take only leaf locks and start tasks, so the wait is the length
/// of one callback.
package final class ObserverStopBarrier: @unchecked Sendable {
    private let lock = NSRecursiveLock()

    package init() {}

    /// Runs one delivery: `publish` checks the generation and, if it is
    /// current, changes state and calls the consumer.
    package func deliver(_ publish: () -> Void) {
        lock.withLock(publish)
    }

    /// Runs a stop's teardown once no delivery is in flight on another thread.
    package func stop<T>(_ teardown: () -> T) -> T {
        lock.withLock(teardown)
    }
}
