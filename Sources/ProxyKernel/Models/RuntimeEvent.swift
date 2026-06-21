// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// Structured runtime event for observability. Machine-consumable first, human-readable second.
/// Maps to the v2 plan's event categories: lifecycle, routing, auth, connection, health, config, vpn.
package enum RuntimeEventKind: String, Codable, Sendable {
    case lifecycle
    case routing
    case auth
    case connection
    case health
    case config
    /// VPN state-machine transitions emitted from the orchestrator's
    /// `handleVPNStateChange(_:)` (Phase 4). Distinct from `.network` because
    /// VPN events are a richer signal than generic network changes — they
    /// drive direct-mode transitions, breaker resets, and flap-survival
    /// telemetry. See `docs/design-vpn-flap-resilience.md`.
    case vpn
}

package struct RuntimeEvent: Codable, Sendable {
    package let timestamp: Date
    package let kind: RuntimeEventKind
    package let event: String
    package let detail: String?

    package init(kind: RuntimeEventKind, event: String, detail: String? = nil) {
        self.timestamp = .now
        self.kind = kind
        self.event = event
        self.detail = detail.map(SensitiveValueSanitizer.sanitize)
    }
}

/// Bounded ring buffer for runtime events. Fixed capacity, oldest evicted on overflow.
/// TIGER_STYLE: "put a limit on everything."
///
/// Thread-safe: all mutable state is serialized behind `stateLock`. The `@unchecked Sendable`
/// conformance is sound because every read and write happens under the lock.
package final class RuntimeEventLog: @unchecked Sendable {
    private struct State {
        var buffer: [RuntimeEvent]
        var writeIndex: Int = 0
        var count: Int = 0
        var sink: (@Sendable (RuntimeEvent) -> Void)?
    }

    private let capacity: Int
    private let stateLock: NIOLockedValueBox<State>

    package init(capacity: Int = 512) {
        // `append()` does `(writeIndex + 1) % capacity`, so a non-positive capacity would
        // trap on modulo-by-zero. Assert at construction time instead of lazily crashing
        // on first event — the fault is always the caller's, not runtime input.
        precondition(capacity > 0, "RuntimeEventLog capacity must be positive")
        self.capacity = capacity
        let initialBuffer = Array(repeating: RuntimeEvent(kind: .lifecycle, event: "init"), count: capacity)
        self.stateLock = NIOLockedValueBox(State(buffer: initialBuffer))
    }

    package func append(_ event: RuntimeEvent) {
        let capacity = self.capacity
        let sink = stateLock.withLockedValue { state -> (@Sendable (RuntimeEvent) -> Void)? in
            state.buffer[state.writeIndex] = event
            state.writeIndex = (state.writeIndex + 1) % capacity
            state.count = min(state.count + 1, capacity)
            return state.sink
        }
        sink?(event)
    }

    package func setSink(_ sink: (@Sendable (RuntimeEvent) -> Void)?) {
        stateLock.withLockedValue { state in
            state.sink = sink
        }
    }

    package var events: [RuntimeEvent] {
        let capacity = self.capacity
        return stateLock.withLockedValue { state in
            if state.count < capacity {
                return Array(state.buffer[0..<state.count])
            }
            return Array(state.buffer[state.writeIndex..<capacity]) + Array(state.buffer[0..<state.writeIndex])
        }
    }

    package var totalCount: Int {
        stateLock.withLockedValue { $0.count }
    }
}
