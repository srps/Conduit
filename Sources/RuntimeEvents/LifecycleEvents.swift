// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The typed `lifecycle.*` events (decision 0013; design in
/// `docs/design-runtime-host-contract.md`). A value holds the closed operation
/// and reason enums and the numeric generations and budgets its record needs.
/// No field takes free text, so a credential or a path has nowhere to go.
///
/// Producers build these values. The kernel's `RuntimeEvent(payload:)` derives
/// the name, kind and human detail from them, and `LifecycleLane` takes an
/// operation enum rather than a string.
package enum LifecycleOperation: String, Codable, Sendable, Equatable, CaseIterable {
    case proxyStart = "proxy_start"
    case proxyStop = "proxy_stop"
    case dnsStart = "dns_start"
    case dnsStop = "dns_stop"
    case runtimeStart = "runtime_start"
    case runtimeStop = "runtime_stop"
}

/// Why a superseded operation stopped short of its platform work.
package enum LifecycleSupersessionReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// A later start or stop began while this one was in flight.
    case superseded
    /// A proxy start's listeners were down by the time it would have gone on.
    case runtimeDown = "runtime_down"
}

/// The names the typed family emits. `scripts/check-event-catalogue.py` pins
/// this list, so adding a typed name is a reviewed change to both places.
package enum LifecycleEventName: String, Sendable, CaseIterable {
    case superseded = "lifecycle.superseded"
    case coalesced = "lifecycle.coalesced"
    case terminationDrainExpired = "lifecycle.termination_drain_expired"
    case versionChanged = "lifecycle.version_changed"
}

/// `lifecycle.superseded`: an operation stopped after its last suspension.
package struct LifecycleSuperseded: Equatable, Sendable {
    package let operation: LifecycleOperation
    /// The operation's own generation, at least 1.
    package let generation: Int
    /// The lane's latest generation when the operation stopped. Never below `generation`.
    package let current: Int
    package let reason: LifecycleSupersessionReason

    /// A `superseded` reason means a later generation overtook this one, so `current`
    /// is strictly newer. `runtime_down` is recorded while this operation may still be
    /// the latest, so it allows `current == generation`.
    package static func isValid(generation: Int, current: Int, reason: LifecycleSupersessionReason) -> Bool {
        guard generation >= 1 else { return false }
        return reason == .superseded ? current > generation : current >= generation
    }

    package init(operation: LifecycleOperation, generation: Int, current: Int, reason: LifecycleSupersessionReason) {
        precondition(
            Self.isValid(generation: generation, current: current, reason: reason),
            "generation must be at least 1, and current must exceed it when superseded"
        )
        self.operation = operation
        self.generation = generation
        self.current = current
        self.reason = reason
    }
}

/// `lifecycle.coalesced`: an operation joined the identical one in flight.
package struct LifecycleCoalesced: Equatable, Sendable {
    package let operation: LifecycleOperation
    /// The generation joined, at least 1.
    package let joined: Int

    package static func isValid(joined: Int) -> Bool { joined >= 1 }

    package init(operation: LifecycleOperation, joined: Int) {
        precondition(Self.isValid(joined: joined), "a joined generation is at least 1")
        self.operation = operation
        self.joined = joined
    }
}

/// `lifecycle.termination_drain_expired`: quit stopped waiting for the platform queue.
package struct LifecycleTerminationDrainExpired: Equatable, Sendable {
    package let deadlineMilliseconds: Int

    package static func isValid(deadlineMilliseconds: Int) -> Bool { deadlineMilliseconds >= 0 }

    package init(deadlineMilliseconds: Int) {
        precondition(Self.isValid(deadlineMilliseconds: deadlineMilliseconds), "a drain deadline is not negative")
        self.deadlineMilliseconds = deadlineMilliseconds
    }
}

/// `lifecycle.version_changed`: the app launched a different version than the one it last recorded.
/// Both fields are version tokens, not free text. A version is 1 to `maximumVersionBytes` bytes of
/// ASCII letters, digits and `.`, `-`, `+`, `_`. That is a boundary rule for what a typed field may
/// hold, not a semver parse. It admits `0.5.8`, `0.5.8-rc.1+7` and `unbundled`, and it has no `:`,
/// `/`, `=`, space or quote, so a URL, a header or a bearer token has no place in either field. A pair
/// also refuses a `from` that reads as a bearer credential in its rendered line (`readsAsBearerCredential`),
/// so the sanitizer leaves every valid line unchanged. The producer sanitizes before it checks (`AppUpdates`).
package struct LifecycleVersionChanged: Equatable, Sendable {
    package let from: String
    package let to: String

    /// The longest version a typed field carries, in bytes. The sanitizer masks a run of 65 or more
    /// base64-like bytes, and the rendered `from=` prefix adds five bytes in front of the version.
    /// At 59 the whole `from=<version>` run is 64 bytes, so the sanitizer leaves the line unchanged
    /// (`to=` adds only three). The wire repeats this value as `ControlLifecycleEvent.maximumVersionBytes`.
    package static let maximumVersionBytes = 59

    private static let versionBytes = Set(
        Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-+_".utf8)
    )

    package static func isValid(version: String) -> Bool {
        (1...maximumVersionBytes).contains(version.utf8.count) && version.utf8.allSatisfy { versionBytes.contains($0) }
    }

    /// The sanitizer's bearer rule is `\bBearer\s+`, and the rendered `from=<from> to=<to>` line puts a
    /// space right after `from`. So a `from` that ends in the word `Bearer` (any case) is masked. The word
    /// is whole when it starts the value or follows `.`, `-` or `+`, the only non-word bytes a version
    /// holds. `to` has nothing after it that could be whitespace, so it is never masked.
    private static func readsAsBearerCredential(from version: String) -> Bool {
        let word = "bearer"
        guard version.lowercased().hasSuffix(word) else { return false }
        let stem = version.dropLast(word.count)
        return stem.last.map { ".-+".contains($0) } ?? true
    }

    /// Both fields are tokens, and `from` does not read as a bearer credential. This is the one pair
    /// rule: a valid pair's rendered line is a sanitizer fixed point, and an invalid one is not.
    package static func isValid(from: String, to: String) -> Bool {
        isValid(version: from) && !readsAsBearerCredential(from: from) && isValid(version: to)
    }

    package init(from: String, to: String) {
        precondition(Self.isValid(from: from, to: to), "a version is 1 to \(Self.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer")
        self.from = from
        self.to = to
    }
}

package enum LifecycleEvent: Equatable, Sendable {
    case superseded(LifecycleSuperseded)
    case coalesced(LifecycleCoalesced)
    case terminationDrainExpired(LifecycleTerminationDrainExpired)
    case versionChanged(LifecycleVersionChanged)

    /// The stable event name.
    package var name: String {
        switch self {
        case .superseded: LifecycleEventName.superseded.rawValue
        case .coalesced: LifecycleEventName.coalesced.rawValue
        case .terminationDrainExpired: LifecycleEventName.terminationDrainExpired.rawValue
        case .versionChanged: LifecycleEventName.versionChanged.rawValue
        }
    }

    /// The human detail, byte for byte what the legacy records carried.
    package var detail: String {
        switch self {
        case .superseded(let event):
            "operation=\(event.operation.rawValue) generation=\(event.generation) current=\(event.current) reason=\(event.reason.rawValue)"
        case .coalesced(let event):
            "operation=\(event.operation.rawValue) joined=\(event.joined)"
        case .terminationDrainExpired(let event):
            "deadline_ms=\(event.deadlineMilliseconds)"
        case .versionChanged(let event):
            "from=\(event.from) to=\(event.to)"
        }
    }
}

/// Wire layout: `{"type": "superseded", "operation": …, "generation": …,
/// "current": …, "reason": …}`, and so on. Decoding validates the numeric
/// invariants the constructors check, so a malformed known payload throws
/// rather than becoming some other value.
extension LifecycleEvent: Codable {
    private enum WireType: String, Codable {
        case superseded
        case coalesced
        case terminationDrainExpired = "termination_drain_expired"
        case versionChanged = "version_changed"
    }

    private enum CodingKeys: String, CodingKey {
        case type, operation, generation, current, reason, joined, from, to
        case deadlineMilliseconds = "deadline_ms"
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .superseded:
            let operation = try container.decode(LifecycleOperation.self, forKey: .operation)
            let generation = try container.decode(Int.self, forKey: .generation)
            let current = try container.decode(Int.self, forKey: .current)
            let reason = try container.decode(LifecycleSupersessionReason.self, forKey: .reason)
            guard LifecycleSuperseded.isValid(generation: generation, current: current, reason: reason) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .current, in: container,
                    debugDescription: "generation must be at least 1, and current must exceed it when superseded"
                )
            }
            self = .superseded(LifecycleSuperseded(
                operation: operation, generation: generation, current: current, reason: reason
            ))
        case .coalesced:
            let joined = try container.decode(Int.self, forKey: .joined)
            guard LifecycleCoalesced.isValid(joined: joined) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .joined, in: container, debugDescription: "a joined generation is at least 1"
                )
            }
            self = .coalesced(LifecycleCoalesced(
                operation: try container.decode(LifecycleOperation.self, forKey: .operation),
                joined: joined
            ))
        case .terminationDrainExpired:
            let milliseconds = try container.decode(Int.self, forKey: .deadlineMilliseconds)
            guard LifecycleTerminationDrainExpired.isValid(deadlineMilliseconds: milliseconds) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deadlineMilliseconds, in: container, debugDescription: "a drain deadline is not negative"
                )
            }
            self = .terminationDrainExpired(LifecycleTerminationDrainExpired(deadlineMilliseconds: milliseconds))
        case .versionChanged:
            let from = try container.decode(String.self, forKey: .from)
            let to = try container.decode(String.self, forKey: .to)
            guard LifecycleVersionChanged.isValid(from: from, to: to) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .from, in: container,
                    debugDescription: "a version is 1 to \(LifecycleVersionChanged.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer"
                )
            }
            self = .versionChanged(LifecycleVersionChanged(from: from, to: to))
        }
    }

    /// Encoding checks what decoding checks, through the same predicates, so a value
    /// the file reader would reject is never written. Constructors already guarantee
    /// it, but a future case must not slip past.
    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .superseded(let event):
            guard LifecycleSuperseded.isValid(generation: event.generation, current: event.current, reason: event.reason) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "superseded generations violate the wire invariant"
                ))
            }
            try container.encode(WireType.superseded, forKey: .type)
            try container.encode(event.operation, forKey: .operation)
            try container.encode(event.generation, forKey: .generation)
            try container.encode(event.current, forKey: .current)
            try container.encode(event.reason, forKey: .reason)
        case .coalesced(let event):
            guard LifecycleCoalesced.isValid(joined: event.joined) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a joined generation is at least 1"
                ))
            }
            try container.encode(WireType.coalesced, forKey: .type)
            try container.encode(event.operation, forKey: .operation)
            try container.encode(event.joined, forKey: .joined)
        case .terminationDrainExpired(let event):
            guard LifecycleTerminationDrainExpired.isValid(deadlineMilliseconds: event.deadlineMilliseconds) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath, debugDescription: "a drain deadline is not negative"
                ))
            }
            try container.encode(WireType.terminationDrainExpired, forKey: .type)
            try container.encode(event.deadlineMilliseconds, forKey: .deadlineMilliseconds)
        case .versionChanged(let event):
            guard LifecycleVersionChanged.isValid(from: event.from, to: event.to) else {
                throw EncodingError.invalidValue(self, .init(
                    codingPath: encoder.codingPath,
                    debugDescription: "a version is 1 to \(LifecycleVersionChanged.maximumVersionBytes) ASCII token bytes, and from may not end in Bearer"
                ))
            }
            try container.encode(WireType.versionChanged, forKey: .type)
            try container.encode(event.from, forKey: .from)
            try container.encode(event.to, forKey: .to)
        }
    }
}
