// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// When routing under the proxy last changed: a VPN transition, or a
/// direct-mode change such as upstreams recovering (#97). The orchestrator
/// owns VPN state and writes this; the strict-mode hint probe, which runs
/// from NIO handlers, reads it without reaching into the orchestrator, for
/// the cost of one lock.
package final class RoutingTransitionSignal: Sendable {
    package struct State: Equatable, Sendable {
        /// Transitions being handled now (a VPN change awaits its reprobe).
        package var inFlight = 0
        /// When the most recent transition finished, if any has.
        package var settledAt: Date?
        /// Transitions finished so far; tells two apart that share a stamp.
        package var completed = 0
    }

    private let state = NIOLockedValueBox(State())
    private let now: @Sendable () -> Date

    package init(now: @escaping @Sendable () -> Date = { Date() }) {
        self.now = now
    }

    /// A transition started; routing is unsettled until the matching `end()`.
    package func begin() {
        state.withLockedValue { $0.inFlight += 1 }
    }

    /// A transition that `begin()` opened finished now.
    package func end() {
        let at = now()
        state.withLockedValue {
            $0.inFlight = max(0, $0.inFlight - 1)
            $0.settledAt = at
            $0.completed += 1
        }
    }

    /// A transition that happens in one step finished now.
    package func mark() {
        let at = now()
        state.withLockedValue {
            $0.settledAt = at
            $0.completed += 1
        }
    }

    package var current: State {
        state.withLockedValue { $0 }
    }

    /// Whether routing is still settling at `date`: a transition is in
    /// flight, or one finished less than `window` ago.
    package func isSettling(at date: Date, window: TimeInterval) -> Bool {
        let snapshot = current
        if snapshot.inFlight > 0 { return true }
        guard let settledAt = snapshot.settledAt else { return false }
        return date.timeIntervalSince(settledAt) < window
    }
}
