// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import RuntimeEvents

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
    /// The typed value behind `event`, for a migrated family. Nil for a legacy
    /// event and for a record written before this field existed: decoding never
    /// derives one from `event` or `detail`.
    package let typed: RuntimeEventPayload?

    /// The legacy envelope, for unmigrated families. Every name in the closed `lifecycle.`, `config.workflow.`,
    /// `runtime_service.` and `proxy_recovery.` namespaces traps here: those are emitted through
    /// `init(payload:)` only, so no untyped record can carry one.
    package init(kind: RuntimeEventKind, event: String, detail: String? = nil) {
        precondition(
            !RuntimeEventPayload.requiresTypedPayload(event),
            "\(event) is in a closed typed namespace; emit it through RuntimeEvent(payload:)"
        )
        self.timestamp = .now
        self.kind = kind
        self.event = event
        self.detail = detail.map(SensitiveValueSanitizer.sanitize)
        self.typed = nil
    }

    /// A typed event. Its name, kind and detail come from the payload, and the
    /// detail still passes the sanitizer like every other detail.
    package init(payload: RuntimeEventPayload) {
        self.timestamp = .now
        self.kind = Self.kind(of: payload)
        self.event = payload.name
        self.detail = SensitiveValueSanitizer.sanitize(payload.detail)
        self.typed = payload
    }

    private static func kind(of payload: RuntimeEventPayload) -> RuntimeEventKind {
        switch payload {
        case .lifecycle: .lifecycle
        case .configWorkflow: .config
        case .runtimeService: .health
        case .proxyRecovery: .health
        }
    }

    private enum CodingKeys: String, CodingKey {
        case timestamp, kind, event, detail, typed
    }

    /// A record without `typed` decodes as a legacy event. A `typed` value that is
    /// present, even as `null`, must be a valid payload that agrees with the
    /// record's kind, name and detail; a disagreement throws instead of dropping
    /// the typed value.
    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let timestamp = try container.decode(Date.self, forKey: .timestamp)
        let kind = try container.decode(RuntimeEventKind.self, forKey: .kind)
        let event = try container.decode(String.self, forKey: .event)
        let detail = try container.decodeIfPresent(String.self, forKey: .detail)
        var typed: RuntimeEventPayload?
        if container.contains(.typed) {
            let payload = try container.decode(RuntimeEventPayload.self, forKey: .typed)
            guard payload.name == event, Self.kind(of: payload) == kind,
                  SensitiveValueSanitizer.sanitize(payload.detail) == detail
            else {
                throw DecodingError.dataCorruptedError(
                    forKey: .typed, in: container,
                    debugDescription: "the typed payload disagrees with the event's name, kind or detail"
                )
            }
            typed = payload
        }
        self.timestamp = timestamp
        self.kind = kind
        self.event = event
        self.detail = detail
        self.typed = typed
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
