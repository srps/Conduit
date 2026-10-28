// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers

/// Stamps VPN observations in the order the monitor reports them (#155).
///
/// Hosts hand each report to the runtime actor in its own task, and those
/// tasks are not ordered, so a consumer can receive an older report after
/// a newer one. The host stamps each report on the monitor's own callback;
/// a consumer applies a report only when its stamp is newer than the last
/// one it applied (`VPNObservationOrder`).
package final class VPNObservationSequencer: @unchecked Sendable {
    private let lock = NIOLock()
    private var last: UInt64 = 0

    package init() {}

    /// The next stamp. Call on the monitor's callback, before any hop.
    package func next() -> UInt64 {
        lock.withLock {
            last &+= 1
            return last
        }
    }
}

/// One consumer's position in the stamped VPN observations. Each consumer
/// (the orchestrator, a host's split-DNS gate) keeps its own.
package struct VPNObservationOrder: Sendable {
    package private(set) var applied: UInt64 = 0

    package init() {}

    /// Whether the report stamped `sequence` is newer than every one
    /// admitted before; if so it becomes the latest.
    package mutating func admit(_ sequence: UInt64) -> Bool {
        guard sequence > applied else { return false }
        applied = sequence
        return true
    }
}
