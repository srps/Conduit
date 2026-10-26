// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The control wire's projection of a typed runtime event (decision 0013). It
/// mirrors the domain layout without importing `RuntimeEvents` or the kernel, so
/// `ProxyControlBridge` maps the domain values onto these types exhaustively.
/// The JSON matches the file's: `{"family": "lifecycle", "lifecycle": {"type": …}}`.
///
/// Package access: `ControlRuntimeEvent`'s v1 shape and public API are unchanged;
/// this field is additive and absent from every legacy record. The kind, name and
/// detail a payload implies are derived here, and `ControlRuntimeEvent` requires the
/// outer fields to agree with them on both decode and encode.
package enum ControlTypedRuntimeEvent: Codable, Sendable, Equatable {
    case lifecycle(ControlLifecycleEvent)
    case configWorkflow(ControlConfigWorkflowEvent)

    /// The `kind` the outer record must carry for this family.
    package var kind: String {
        switch self {
        case .lifecycle: "lifecycle"
        case .configWorkflow: "config"
        }
    }

    /// The `event` the outer record must carry for this payload.
    package var name: String {
        switch self {
        case .lifecycle(let event): event.name
        case .configWorkflow(let event): event.name
        }
    }

    /// The human `detail` the outer record must carry for this payload.
    package var detail: String {
        switch self {
        case .lifecycle(let event): event.detail
        case .configWorkflow(let event): event.detail
        }
    }

    private enum CodingKeys: String, CodingKey {
        case family, lifecycle, configWorkflow
    }

    /// Shared by the codec and record classifier so a new family requires both to handle it.
    enum Family: String {
        case lifecycle
        case configWorkflow = "config_workflow"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let family = try container.decode(String.self, forKey: .family)
        switch Family(rawValue: family) {
        case .lifecycle?:
            self = .lifecycle(try container.decode(ControlLifecycleEvent.self, forKey: .lifecycle))
        case .configWorkflow?:
            self = .configWorkflow(try container.decode(ControlConfigWorkflowEvent.self, forKey: .configWorkflow))
        case nil:
            throw DecodingError.dataCorruptedError(
                forKey: .family, in: container, debugDescription: "an unknown typed event family"
            )
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .lifecycle(let event):
            try container.encode(Family.lifecycle.rawValue, forKey: .family)
            try container.encode(event, forKey: .lifecycle)
        case .configWorkflow(let event):
            try container.encode(Family.configWorkflow.rawValue, forKey: .family)
            try container.encode(event, forKey: .configWorkflow)
        }
    }
}

/// The wire's `lifecycle.*` values. Operations and reasons are closed enums; the
/// numeric and version fields carry the same invariants as the domain values, through
/// the same predicates `isValid…` below (the domain's copies are checked against these
/// by the projection tests).
package enum ControlLifecycleEvent: Codable, Sendable, Equatable {
    case superseded(operation: ControlLifecycleOperation, generation: Int, current: Int, reason: ControlLifecycleReason)
    case coalesced(operation: ControlLifecycleOperation, joined: Int)
    case terminationDrainExpired(deadlineMilliseconds: Int)
    case versionChanged(from: String, to: String)

    private enum WireType: String, Codable, CaseIterable {
        case superseded
        case coalesced
        case terminationDrainExpired = "termination_drain_expired"
        case versionChanged = "version_changed"
    }

    /// The stable event names, spelled once here. The domain's `LifecycleEventName` pins the same four.
    private enum EventName: String, CaseIterable {
        case superseded = "lifecycle.superseded"
        case coalesced = "lifecycle.coalesced"
        case terminationDrainExpired = "lifecycle.termination_drain_expired"
        case versionChanged = "lifecycle.version_changed"
    }

    private enum CodingKeys: String, CodingKey {
        case type, operation, generation, current, reason, joined, from, to
        case deadlineMilliseconds = "deadline_ms"
    }

    /// The `type` spellings this build decodes. The record classifier reads this set, so it cannot drift.
    package static let knownWireTypes: Set<String> = Set(WireType.allCases.map(\.rawValue))

    /// The event names this build emits and decodes. The record classifier reads this set, so it cannot drift.
    package static let knownEventNames: Set<String> = Set(EventName.allCases.map(\.rawValue))

    /// A `superseded` reason means a later generation overtook this one, so `current`
    /// must be strictly newer. `runtime_down` may have `current == generation`.
    package static func isValidSuperseded(generation: Int, current: Int, reason: ControlLifecycleReason) -> Bool {
        guard generation >= 1 else { return false }
        return reason == .superseded ? current > generation : current >= generation
    }

    package static func isValidCoalesced(joined: Int) -> Bool { joined >= 1 }

    package static func isValidTerminationDrain(deadlineMilliseconds: Int) -> Bool { deadlineMilliseconds >= 0 }

    /// The longest version the wire carries, in bytes: the domain's `LifecycleVersionChanged.maximumVersionBytes`,
    /// with the same reason. At 59 the rendered `from=<version>` line is 64 bytes, under the sanitizer's
    /// 65-byte run, so the outer detail the wire compares against is the line this value renders unchanged.
    package static let maximumVersionBytes = 59

    /// A version is 1 to `maximumVersionBytes` ASCII token bytes: letters, digits, `.`, `-`, `+`, `_`. The
    /// same grammar as the domain's `LifecycleVersionChanged`, not a semver parse.
    private static let versionBytes = Set(
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+_".utf8)
    )

    package static func isValidVersion(_ version: String) -> Bool {
        (1...maximumVersionBytes).contains(version.utf8.count) && version.utf8.allSatisfy { versionBytes.contains($0) }
    }

    /// The mirror of the domain's `readsAsBearerCredential`: a `from` ending in the word `Bearer` (any case),
    /// at the start or after `.`, `-` or `+`. The sanitizer masks its rendered `from=… to=…` line.
    private static func readsAsBearerCredential(from version: String) -> Bool {
        let word = "bearer"
        guard version.lowercased().hasSuffix(word) else { return false }
        let stem = version.dropLast(word.count)
        return stem.last.map { ".-+".contains($0) } ?? true
    }

    /// The mirror of the domain's pair rule, checked against it by the projection tests.
    package static func isValidVersionChange(from: String, to: String) -> Bool {
        isValidVersion(from) && !readsAsBearerCredential(from: from) && isValidVersion(to)
    }

    /// The stable event name, the same spelling the domain derives.
    package var name: String {
        switch self {
        case .superseded: EventName.superseded.rawValue
        case .coalesced: EventName.coalesced.rawValue
        case .terminationDrainExpired: EventName.terminationDrainExpired.rawValue
        case .versionChanged: EventName.versionChanged.rawValue
        }
    }

    /// The human detail, byte for byte what the legacy records carried.
    package var detail: String {
        switch self {
        case .superseded(let operation, let generation, let current, let reason):
            "operation=\(operation.rawValue) generation=\(generation) current=\(current) reason=\(reason.rawValue)"
        case .coalesced(let operation, let joined):
            "operation=\(operation.rawValue) joined=\(joined)"
        case .terminationDrainExpired(let deadlineMilliseconds):
            "deadline_ms=\(deadlineMilliseconds)"
        case .versionChanged(let from, let to):
            "from=\(from) to=\(to)"
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .superseded:
            let operation = try container.decode(ControlLifecycleOperation.self, forKey: .operation)
            let generation = try container.decode(Int.self, forKey: .generation)
            let current = try container.decode(Int.self, forKey: .current)
            let reason = try container.decode(ControlLifecycleReason.self, forKey: .reason)
            guard Self.isValidSuperseded(generation: generation, current: current, reason: reason) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .current, in: container,
                    debugDescription: "generation must be at least 1, and current must exceed it when superseded"
                )
            }
            self = .superseded(operation: operation, generation: generation, current: current, reason: reason)
        case .coalesced:
            let joined = try container.decode(Int.self, forKey: .joined)
            guard Self.isValidCoalesced(joined: joined) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .joined, in: container, debugDescription: "a joined generation is at least 1"
                )
            }
            self = .coalesced(
                operation: try container.decode(ControlLifecycleOperation.self, forKey: .operation),
                joined: joined
            )
        case .terminationDrainExpired:
            let milliseconds = try container.decode(Int.self, forKey: .deadlineMilliseconds)
            guard Self.isValidTerminationDrain(deadlineMilliseconds: milliseconds) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deadlineMilliseconds, in: container, debugDescription: "a drain deadline is not negative"
                )
            }
            self = .terminationDrainExpired(deadlineMilliseconds: milliseconds)
        case .versionChanged:
            let from = try container.decode(String.self, forKey: .from)
            let to = try container.decode(String.self, forKey: .to)
            guard Self.isValidVersionChange(from: from, to: to) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .from, in: container,
                    debugDescription: "a version is 1 to \(Self.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer"
                )
            }
            self = .versionChanged(from: from, to: to)
        }
    }

    /// Refuses to write a known value that decoding would reject.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .superseded(let operation, let generation, let current, let reason):
            guard Self.isValidSuperseded(generation: generation, current: current, reason: reason) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "generation must be at least 1, and current must exceed it when superseded"
                ))
            }
            try container.encode(WireType.superseded, forKey: .type)
            try container.encode(operation, forKey: .operation)
            try container.encode(generation, forKey: .generation)
            try container.encode(current, forKey: .current)
            try container.encode(reason, forKey: .reason)
        case .coalesced(let operation, let joined):
            guard Self.isValidCoalesced(joined: joined) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a joined generation is at least 1"
                ))
            }
            try container.encode(WireType.coalesced, forKey: .type)
            try container.encode(operation, forKey: .operation)
            try container.encode(joined, forKey: .joined)
        case .terminationDrainExpired(let deadlineMilliseconds):
            guard Self.isValidTerminationDrain(deadlineMilliseconds: deadlineMilliseconds) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a drain deadline is not negative"
                ))
            }
            try container.encode(WireType.terminationDrainExpired, forKey: .type)
            try container.encode(deadlineMilliseconds, forKey: .deadlineMilliseconds)
        case .versionChanged(let from, let to):
            guard Self.isValidVersionChange(from: from, to: to) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "a version is 1 to \(Self.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer"
                ))
            }
            try container.encode(WireType.versionChanged, forKey: .type)
            try container.encode(from, forKey: .from)
            try container.encode(to, forKey: .to)
        }
    }
}

/// Wire spelling of a lifecycle operation: the same raw values as the domain's,
/// kept here as a separate closed set.
package enum ControlLifecycleOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case proxyStart = "proxy_start"
    case proxyStop = "proxy_stop"
    case dnsStart = "dns_start"
    case dnsStop = "dns_stop"
    case runtimeStart = "runtime_start"
    case runtimeStop = "runtime_stop"
}

/// Wire spelling of a supersession reason.
package enum ControlLifecycleReason: String, Codable, Sendable, Equatable, CaseIterable {
    case superseded
    case runtimeDown = "runtime_down"
}
