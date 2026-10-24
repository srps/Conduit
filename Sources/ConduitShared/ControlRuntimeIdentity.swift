// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Marks one identifier or revision family. Each marker gives its wrapper a
/// distinct type, so a request ID cannot stand in for an operation ID and a
/// configuration revision cannot stand in for a lifecycle revision.
package protocol ControlIdentityDomain: Sendable {}

/// A UUID-valued identifier, spelled as its canonical UUID string on the wire.
package struct ControlIdentifier<Domain: ControlIdentityDomain>: Codable, Sendable, Hashable,
    CustomStringConvertible
{
    package let rawValue: UUID

    package init(rawValue: UUID) {
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let uuid = UUID(uuidString: try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "an identifier must be a UUID")
        }
        self.rawValue = uuid
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue.uuidString)
    }

    package var description: String { rawValue.uuidString }
}

/// A non-negative revision or cursor. Revisions of different families are
/// different types even when their numbers coincide.
package struct ControlOrdinal<Domain: ControlIdentityDomain>: Codable, Sendable, Hashable, Comparable {
    package let rawValue: Int

    package init?(rawValue: Int) {
        guard rawValue >= 0 else { return nil }
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Int.self)
        guard value >= 0 else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "a revision or cursor is negative")
        }
        self.rawValue = value
    }

    package func encode(to encoder: any Encoder) throws {
        guard rawValue >= 0 else {
            throw EncodingError.invalidValue(rawValue, .init(
                codingPath: encoder.codingPath, debugDescription: "a revision or cursor is negative"
            ))
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package enum ControlRequestDomain: ControlIdentityDomain {}
package enum ControlOperationDomain: ControlIdentityDomain {}
package enum ControlIncarnationDomain: ControlIdentityDomain {}
package enum ControlConnectionDomain: ControlIdentityDomain {}
package enum ControlUpstreamDomain: ControlIdentityDomain {}
package enum ControlTunnelDomain: ControlIdentityDomain {}
package enum ControlConfigRevisionDomain: ControlIdentityDomain {}
package enum ControlLifecycleRevisionDomain: ControlIdentityDomain {}
package enum ControlPresentationRevisionDomain: ControlIdentityDomain {}
package enum ControlCollectionRevisionDomain: ControlIdentityDomain {}
package enum ControlEventCursorDomain: ControlIdentityDomain {}

/// The caller's request, one per submitted command. The host coalesces or
/// rejects by it within one incarnation.
package typealias ControlRequestID = ControlIdentifier<ControlRequestDomain>
/// An admitted operation, assigned by the host at admission.
package typealias ControlOperationID = ControlIdentifier<ControlOperationDomain>
/// One runtime host lifetime. Identifiers, cursors and revisions are scoped to it.
package typealias ControlHostIncarnation = ControlIdentifier<ControlIncarnationDomain>
package typealias ControlConnectionID = ControlIdentifier<ControlConnectionDomain>
package typealias ControlUpstreamID = ControlIdentifier<ControlUpstreamDomain>
package typealias ControlTunnelID = ControlIdentifier<ControlTunnelDomain>

/// The persisted configuration generation a runtime value was built from.
package typealias ControlConfigRevision = ControlOrdinal<ControlConfigRevisionDomain>
/// The lifecycle generation that preconditions lifecycle commands.
package typealias ControlLifecycleRevision = ControlOrdinal<ControlLifecycleRevisionDomain>
/// The presentation snapshot generation. It advances on counter traffic, so
/// command preconditions must not use it.
package typealias ControlPresentationRevision = ControlOrdinal<ControlPresentationRevisionDomain>
/// A pinned immutable collection version that pages refer to.
package typealias ControlCollectionRevision = ControlOrdinal<ControlCollectionRevisionDomain>
/// A position in one incarnation's event sequence.
package typealias ControlEventCursor = ControlOrdinal<ControlEventCursorDomain>

/// A validity rule for a scalar that crosses the wire. The rule is checked on
/// both encode and decode, so an invalid value cannot be produced or accepted.
package protocol ControlValueRule: Sendable {
    associatedtype Value: Codable & Sendable & Hashable & Comparable
    static func accepts(_ value: Value) -> Bool
}

/// A scalar that carries its rule in its type. Construction and both coding
/// directions refuse a value the rule rejects.
package struct ControlChecked<Rule: ControlValueRule>: Codable, Sendable, Hashable, Comparable {
    package let rawValue: Rule.Value

    package init(_ rawValue: Rule.Value) throws {
        guard Rule.accepts(rawValue) else { throw ControlRuntimeWireError.invalidValue }
        self.rawValue = rawValue
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let value = try container.decode(Rule.Value.self)
        guard Rule.accepts(value) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "a value is outside its range")
        }
        self.rawValue = value
    }

    package func encode(to encoder: any Encoder) throws {
        guard Rule.accepts(rawValue) else {
            throw EncodingError.invalidValue(rawValue, .init(
                codingPath: encoder.codingPath, debugDescription: "a value is outside its range"
            ))
        }
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }

    package static func < (lhs: Self, rhs: Self) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

package enum ControlCountRule: ControlValueRule {
    package static func accepts(_ value: Int) -> Bool { value >= 0 }
}

package enum ControlPortRule: ControlValueRule {
    package static func accepts(_ value: Int) -> Bool { (1...65_535).contains(value) }
}

package enum ControlNonNegativeNumberRule: ControlValueRule {
    package static func accepts(_ value: Double) -> Bool { value.isFinite && value >= 0 }
}

package enum ControlTimestampRule: ControlValueRule {
    package static func accepts(_ value: Double) -> Bool { value.isFinite }
}

/// The milliseconds a caller may wait, carried on the wire. Its range is the
/// `Int32` range so the value stays representable on every peer; no policy
/// budget is implied.
package enum ControlWireBudgetRule: ControlValueRule {
    package static func accepts(_ value: Int) -> Bool { (0...Int(Int32.max)).contains(value) }
}

/// A count of items, bytes or events. Never negative.
package typealias ControlCount = ControlChecked<ControlCountRule>
/// A finite, non-negative measurement such as a duration or latency.
package typealias ControlNonNegativeNumber = ControlChecked<ControlNonNegativeNumberRule>
/// Seconds since the Unix epoch. Finite on both sides; never a process-local clock.
package typealias ControlTimestamp = ControlChecked<ControlTimestampRule>
/// A TCP or UDP port that is actually bound or configured (1 through 65535).
package typealias ControlPort = ControlChecked<ControlPortRule>
/// The remaining time a caller grants the host, in milliseconds.
package typealias ControlWireBudget = ControlChecked<ControlWireBudgetRule>
