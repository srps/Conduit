// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The control wire's `runtime_service.*` values (decisions 0013 and 0014). They mirror the domain layout in `RuntimeEvents` without
/// importing it, so `ProxyControlBridge` maps the domain values onto these types exhaustively. Every field is a closed enum, and the
/// derived `name` and `detail` match the domain's byte for byte, because the outer record must agree.
package enum ControlRuntimeServiceFault: String, Codable, Sendable, Equatable, CaseIterable {
    case submitCommandNotEncodable = "submit_command_not_encodable"
    case outcomeNotEncodable = "outcome_not_encodable"
    case projectionNotEncodable = "projection_not_encodable"
    case projectionCountMismatch = "projection_count_mismatch"
    case snapshotIncarnationMismatch = "snapshot_incarnation_mismatch"
    case revisionTotalChanged = "revision_total_changed"
    case collectionAccountingMismatch = "collection_accounting_mismatch"
    case quiescenceAccountingMismatch = "quiescence_accounting_mismatch"
    case snapshotNotEncodable = "snapshot_not_encodable"
    case snapshotOverBound = "snapshot_over_bound"
    case snapshotRevisionConflict = "snapshot_revision_conflict"
    case snapshotRevisionRegressed = "snapshot_revision_regressed"
}

package enum ControlRuntimeServiceSnapshotReason: String, Codable, Sendable, Equatable, CaseIterable {
    case projectionFailed = "projection_failed"
    case revisionExhausted = "revision_exhausted"
}

package enum ControlRuntimeServiceEvent: Codable, Sendable, Equatable {
    case fault(ControlRuntimeServiceFault)
    case snapshotUnavailable(ControlRuntimeServiceSnapshotReason)

    private enum WireType: String, Codable, CaseIterable {
        case fault
        case snapshotUnavailable = "snapshot_unavailable"
    }

    /// The stable event names, spelled once here. The domain's `RuntimeServiceEventName` pins the same two.
    private enum EventName: String, CaseIterable {
        case fault = "runtime_service.fault"
        case snapshotUnavailable = "runtime_service.snapshot_unavailable"
    }

    private enum CodingKeys: String, CodingKey {
        case type, fault, reason
    }

    /// The `type` spellings this build decodes. The record classifier reads this set, so it cannot drift.
    package static let knownWireTypes: Set<String> = Set(WireType.allCases.map(\.rawValue))

    /// The event names this build emits and decodes. The record classifier reads this set, so it cannot drift.
    package static let knownEventNames: Set<String> = Set(EventName.allCases.map(\.rawValue))

    /// The stable event name, the same spelling the domain derives.
    package var name: String {
        switch self {
        case .fault: EventName.fault.rawValue
        case .snapshotUnavailable: EventName.snapshotUnavailable.rawValue
        }
    }

    /// The human detail, byte for byte what the domain derives.
    package var detail: String {
        switch self {
        case .fault(let fault): "fault=\(fault.rawValue)"
        case .snapshotUnavailable(let reason): "reason=\(reason.rawValue)"
        }
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .fault:
            self = .fault(try container.decode(ControlRuntimeServiceFault.self, forKey: .fault))
        case .snapshotUnavailable:
            self = .snapshotUnavailable(try container.decode(ControlRuntimeServiceSnapshotReason.self, forKey: .reason))
        }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .fault(let fault):
            try container.encode(WireType.fault, forKey: .type)
            try container.encode(fault, forKey: .fault)
        case .snapshotUnavailable(let reason):
            try container.encode(WireType.snapshotUnavailable, forKey: .type)
            try container.encode(reason, forKey: .reason)
        }
    }
}
