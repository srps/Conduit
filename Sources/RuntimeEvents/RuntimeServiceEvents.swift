// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The typed `runtime_service.*` events (decisions 0013 and 0014; #180). The runtime control service reports a broken invariant to its
/// owner, and the owner reports when it cannot give its state a control snapshot. Every field is a closed enum, so a command, a payload
/// or an error text has nowhere to go.
///
/// The shared host's control owner builds these values. The kernel's `RuntimeEvent(payload:)` derives the name, the `health` kind and
/// the detail from them. The wire mirror (`ConduitShared`) is a separate closed set that `ProxyControlBridge` maps onto exhaustively.

/// The site where the service found a broken invariant: one case per service fault, spelled as the `fault=` detail.
package enum RuntimeServiceFault: String, Codable, Sendable, Equatable, CaseIterable {
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

/// Why the host could not give its state a control snapshot.
package enum RuntimeServiceSnapshotUnavailableReason: String, Codable, Sendable, Equatable, CaseIterable {
    /// The projection of the kernel's state failed.
    case projectionFailed = "projection_failed"
    /// A changed snapshot needed a presentation revision past the maximum.
    case revisionExhausted = "revision_exhausted"
}

/// The names the typed family emits.
package enum RuntimeServiceEventName: String, Sendable, CaseIterable {
    case fault = "runtime_service.fault"
    case snapshotUnavailable = "runtime_service.snapshot_unavailable"
}

package enum RuntimeServiceEvent: Equatable, Sendable {
    /// `runtime_service.fault`: the service reported a broken invariant at the named site.
    case fault(RuntimeServiceFault)
    /// `runtime_service.snapshot_unavailable`: a snapshot failure episode began.
    case snapshotUnavailable(RuntimeServiceSnapshotUnavailableReason)

    /// The stable event name.
    package var name: String {
        switch self {
        case .fault: RuntimeServiceEventName.fault.rawValue
        case .snapshotUnavailable: RuntimeServiceEventName.snapshotUnavailable.rawValue
        }
    }

    /// The human detail, byte for byte what the untyped records carried.
    package var detail: String {
        switch self {
        case .fault(let fault): "fault=\(fault.rawValue)"
        case .snapshotUnavailable(let reason): "reason=\(reason.rawValue)"
        }
    }
}

/// Wire layout: `{"type": "fault", "fault": …}` or `{"type": "snapshot_unavailable", "reason": …}`. An unknown type, fault or reason
/// throws rather than becoming some other value.
extension RuntimeServiceEvent: Codable {
    private enum WireType: String, Codable {
        case fault
        case snapshotUnavailable = "snapshot_unavailable"
    }

    private enum CodingKeys: String, CodingKey {
        case type, fault, reason
    }

    package init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(WireType.self, forKey: .type) {
        case .fault:
            self = .fault(try container.decode(RuntimeServiceFault.self, forKey: .fault))
        case .snapshotUnavailable:
            self = .snapshotUnavailable(try container.decode(RuntimeServiceSnapshotUnavailableReason.self, forKey: .reason))
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
