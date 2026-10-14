// SPDX-License-Identifier: Apache-2.0

/// The recent VPN-transition sweeps an owner (the DIRECT tunnel registry, a
/// connection pool) ran, so a dial that straddled one can be judged by it
/// when it completes (#148).
///
/// A dial reads `epoch` when it starts; each sweep advances it. On
/// completion, `missed(since:)` lists the sweeps the dial straddled, or
/// `nil` when it is older than every remembered one. Not synchronised: the
/// owner keeps it under the same lock as the collection it sweeps, so the
/// check and the sweep are atomic.
///
/// Bounded: the last `capacity` sweeps.
package struct TransitionSweeps<Rule> {
    package static var capacity: Int { 8 }

    package private(set) var epoch: UInt64 = 0
    /// Oldest first; each tagged with the epoch it advanced to.
    private var sweeps: [(epoch: UInt64, rule: Rule)] = []

    package init() {}

    package mutating func record(_ rule: Rule) {
        epoch += 1
        sweeps.append((epoch, rule))
        if sweeps.count > Self.capacity { sweeps.removeFirst(sweeps.count - Self.capacity) }
    }

    /// The sweeps run since `dialEpoch`, or `nil` when some of them are
    /// forgotten: the dial crossed more transitions than are remembered.
    package func missed(since dialEpoch: UInt64) -> [Rule]? {
        guard dialEpoch < epoch else { return [] }
        if let oldest = sweeps.first?.epoch, oldest > dialEpoch + 1 { return nil }
        return sweeps.filter { $0.epoch > dialEpoch }.map(\.rule)
    }

    /// Whether a dial that began at `dialEpoch` should be retired: a sweep it
    /// straddled selects it, or it is older than the remembered history.
    package func retires(since dialEpoch: UInt64, _ selects: (Rule) -> Bool) -> Bool {
        guard let missed = missed(since: dialEpoch) else { return true }
        return missed.contains(where: selects)
    }
}
