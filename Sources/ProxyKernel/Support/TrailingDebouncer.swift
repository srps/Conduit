// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers

/// Coalesces a burst of signals into one delivery, `interval` after the last
/// signal, carrying the last value. One pending work item at most.
/// `signal` may be called from any thread; `deliver` runs on `queue`.
package final class TrailingDebouncer<Value: Sendable>: @unchecked Sendable {
    private let interval: TimeInterval
    private let queue: DispatchQueue
    private let deliver: @Sendable (Value) -> Void
    private let lock = NIOLock()
    private var pending: DispatchWorkItem?

    package init(
        interval: TimeInterval,
        queue: DispatchQueue,
        deliver: @escaping @Sendable (Value) -> Void
    ) {
        self.interval = interval
        self.queue = queue
        self.deliver = deliver
    }

    /// Schedules delivery of `value` after `interval`, replacing a pending
    /// delivery. An interval of zero or less delivers without waiting.
    package func signal(_ value: Value) {
        let deliver = self.deliver
        let item = DispatchWorkItem { deliver(value) }
        let previous: DispatchWorkItem? = lock.withLock {
            let previous = pending
            pending = item
            return previous
        }
        previous?.cancel()
        if interval > 0 {
            queue.asyncAfter(deadline: .now() + interval, execute: item)
        } else {
            queue.async(execute: item)
        }
    }

    package func cancel() {
        let previous: DispatchWorkItem? = lock.withLock {
            let previous = pending
            pending = nil
            return previous
        }
        previous?.cancel()
    }
}
