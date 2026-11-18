// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The clock a dynamic-store observer reads and waits on for its read
/// schedule (decision 0048). `FakeStoreObserverClock` in `PlatformFakes.swift`
/// is the injection point.
package struct StoreObserverClock: Sendable {
    /// Seconds on a monotonic clock; only differences matter.
    package var now: @Sendable () -> TimeInterval
    /// Returns once `seconds` have passed, at most `tolerance` late, or throws
    /// when its task is cancelled first.
    package var sleep: @Sendable (_ seconds: TimeInterval, _ tolerance: TimeInterval) async throws -> Void

    package init(
        now: @escaping @Sendable () -> TimeInterval,
        sleep: @escaping @Sendable (_ seconds: TimeInterval, _ tolerance: TimeInterval) async throws -> Void
    ) {
        self.now = now
        self.sleep = sleep
    }

    /// `ContinuousClock`, which keeps counting while the Mac sleeps, so a
    /// wake-up that came due during a sleep runs at the first chance after it.
    package static var continuous: StoreObserverClock {
        let origin = ContinuousClock.now
        return StoreObserverClock(
            now: {
                let elapsed = (ContinuousClock.now - origin).components
                return TimeInterval(elapsed.seconds) + TimeInterval(elapsed.attoseconds) / 1e18
            },
            sleep: { seconds, tolerance in
                try await Task.sleep(for: .seconds(seconds), tolerance: .seconds(tolerance), clock: .continuous)
            }
        )
    }
}
