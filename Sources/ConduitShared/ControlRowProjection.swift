// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The rows of one collection, as a closed set of kinds. A capture carries these, so its rows and its kind cannot disagree.
package enum ControlProjectedRows: Sendable {
    case activeConnections([ControlConnectionRow])
    case upstreamHealth([ControlUpstreamRow])
    case tunnelBindings([ControlTunnelBindingRow])
    case tunnelDNSHosts([ControlTunnelDNSHostRow])

    package var kind: ControlCollectionKind {
        switch self {
        case .activeConnections: .activeConnections
        case .upstreamHealth: .upstreamHealth
        case .tunnelBindings: .tunnelBindings
        case .tunnelDNSHosts: .tunnelDNSHosts
        }
    }

    /// The number of rows, which a capture checks against the snapshot's exact total for the same owner turn.
    package var rowCount: Int {
        switch self {
        case .activeConnections(let list): list.count
        case .upstreamHealth(let list): list.count
        case .tunnelBindings(let list): list.count
        case .tunnelDNSHosts(let list): list.count
        }
    }
}

/// The closed answer of one bounded projection. A refusal is whole: an over-budget projection carries no rows and is never truncated.
package enum ControlProjection: Sendable {
    /// The rows, and the encoded bytes of each row as the codec writes it. The bytes are the sum of the rows alone, without the array.
    case rows(ControlProjectedRows, encodedBytes: Int)
    /// The rows exceed the count or the encoded-byte bound. The projection stopped at the first row past a bound.
    case overBudget
    /// A row could not be built or encoded. It is a closed internal failure, never a capacity answer, and no error text is kept.
    case internalFailure
}

/// The closed result of measuring a bounded set of rows.
package enum ControlRowsMeasure<Row: ControlCollectionRow> {
    case complete(rows: [Row], bytes: Int)
    case overBudget
    case internalFailure
}

/// The count and encoded-byte bounds one bounded projection may spend. Each row is checked before it is kept: the count before
/// the row is mapped, and the encoded bytes after it is encoded and before it is kept. The first row past either bound ends the
/// projection as `overBudget`, so the rest of the collection is never built and no truncated array is returned.
package struct ControlRowBudget: Sendable, Equatable {
    package let maxRows: Int
    package let maxBytes: Int

    package init(maxRows: Int, maxBytes: Int) {
        self.maxRows = maxRows
        self.maxBytes = maxBytes
    }

    /// Maps the inputs in order, and keeps each row that fits. `Inputs` is any sequence, so a caller's raw storage is iterated
    /// without first building a mapped array. A mapping or encoding error ends the measure as `internalFailure`, and its text is dropped.
    package func measure<Inputs: Sequence, Row: ControlCollectionRow>(
        _ inputs: Inputs,
        _ map: (Inputs.Element) throws -> Row
    ) -> ControlRowsMeasure<Row> {
        let encoder = ControlRuntimeCodec.makeEncoder()
        var rows: [Row] = []
        var bytes = 0
        for input in inputs {
            guard rows.count < maxRows else { return .overBudget }
            let row: Row
            let size: Int
            do {
                row = try map(input)
                size = try encoder.encode(row).count
            } catch {
                return .internalFailure
            }
            guard size <= maxBytes - bytes else { return .overBudget }
            bytes += size
            rows.append(row)
        }
        return .complete(rows: rows, bytes: bytes)
    }
}
