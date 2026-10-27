// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import CryptoKit
import Foundation

/// A partition of request aliases and of stop slots: ordinary commands, or one control module's stops.
enum RuntimePartition: Hashable, Sendable {
    case ordinary
    case stop(ControlModule)
    /// The process quit and its reserved flushes (decision 0015). Neither waits on ordinary capacity: the host's terminal latch admits one
    /// quit per host, and its window each declared flush once, so the partition holds at most three operations.
    case quit

    static let all: [RuntimePartition] = [.ordinary, .quit] + ControlModule.allCases.map { RuntimePartition.stop($0) }

    static func of(_ command: ControlRuntimeCommand) -> RuntimePartition {
        switch command {
        case .stop(let module): .stop(module)
        case .quit: .quit
        case .restart, .testDNS, .testUpstream, .refreshPreflight, .setLaunchAtLogin: .ordinary
        }
    }

    /// The module of a stop partition, and nil for every other one.
    var stopModule: ControlModule? {
        switch self {
        case .ordinary, .quit: nil
        case .stop(let module): module
        }
    }
}

/// The request aliases of one service: what each request ID was answered with, so a recorded request recovers its
/// admission, and a changed payload conflicts.
///
/// Ownership: an alias is retention policy only. It answers one request ID with its admission and a fixed-size
/// fingerprint of the command, never the command body. It never references an operation's lifetime, so a pending
/// operation is never pinned by an alias, and an alias is never needed to launch or quiesce anything. Each partition
/// is bounded by count and by bytes, the oldest alias is evicted first, and an alias expires `retentionAge` after its
/// admission. Admission never waits for alias room, so an alias cannot block a fence.
///
/// The table takes no lock and calls nothing. The owner turn is its only caller.
/// Where an alias came from. An ordinary request keeps its command fingerprint, so a resend recovers its admission and a different
/// payload conflicts. A private editor request keeps nothing derived from its body: its ID is lookup-only, and any reuse is refused.
enum RuntimeAliasOrigin: Equatable {
    case ordinary(fingerprint: Data)
    case privateEditor
}

struct RuntimeAliasTable {
    struct Alias {
        let origin: RuntimeAliasOrigin
        let admission: ControlAdmission
        let partition: RuntimePartition
        let admittedAt: ContinuousClock.Instant
    }

    private let limits: RuntimeServiceLimits
    private var aliases: [ControlRequestID: Alias] = [:]
    /// Each partition's request IDs, oldest first. Admission times only grow, so the expired ones form a prefix.
    private var order: [RuntimePartition: [ControlRequestID]] = [:]
    /// The bytes each partition charges. Each alias is charged its measured worst record.
    private var bytes: [RuntimePartition: Int] = [:]

    init(limits: RuntimeServiceLimits) {
        self.limits = limits
    }

    /// The number of aliases held, across every partition.
    var count: Int {
        aliases.count
    }

    /// The bytes every partition charges, together.
    var bytesTotal: Int {
        bytes.values.reduce(0, +)
    }

    /// The fingerprint of an encoded command: SHA-256, so a conflict is detected without retaining the body.
    static func fingerprint(of encoded: Data) -> Data {
        Data(SHA256.hash(data: encoded))
    }

    /// Records one alias. It always succeeds: the oldest aliases of the partition are evicted until the record fits, and
    /// nothing else is touched.
    mutating func record(
        _ id: ControlRequestID,
        origin: RuntimeAliasOrigin,
        partition: RuntimePartition,
        admission: ControlAdmission,
        now: ContinuousClock.Instant
    ) {
        // A private alias holds no fingerprint, so its record is never larger than the worst ordinary one it is charged as.
        let charge = limits.aliasRecordWorstBytes
        while let oldest = order[partition, default: []].first, isFull(partition, adding: charge) {
            remove(oldest)
        }
        aliases[id] = Alias(origin: origin, admission: admission, partition: partition, admittedAt: now)
        order[partition, default: []].append(id)
        bytes[partition, default: 0] += charge
    }

    /// The live alias for one request. An expired alias is removed here, and it is reported as absent.
    mutating func live(_ id: ControlRequestID, now: ContinuousClock.Instant) -> Alias? {
        guard let alias = aliases[id] else { return nil }
        if now - alias.admittedAt >= limits.retentionAge {
            remove(id)
            return nil
        }
        return alias
    }

    /// Removes expired aliases from the head of each partition, at most `batch` in total. Each partition's sweep stops at its
    /// first live alias, so the work per turn is bounded by `batch`, and no scan passes a live alias.
    mutating func sweep(now: ContinuousClock.Instant, batch: Int) {
        var removed = 0
        for partition in RuntimePartition.all {
            while removed < batch,
                  let oldest = order[partition, default: []].first,
                  let alias = aliases[oldest],
                  now - alias.admittedAt >= limits.retentionAge {
                remove(oldest)
                removed += 1
            }
        }
    }

    private func isFull(_ partition: RuntimePartition, adding charge: Int) -> Bool {
        order[partition, default: []].count >= limits.aliasCapacityPerPartition
            || bytes[partition, default: 0] > limits.aliasByteCapacityPerPartition - charge
    }

    private mutating func remove(_ id: ControlRequestID) {
        guard let alias = aliases.removeValue(forKey: id) else { return }
        bytes[alias.partition, default: 0] -= limits.aliasRecordWorstBytes
        if let index = order[alias.partition, default: []].firstIndex(of: id) {
            order[alias.partition, default: []].remove(at: index)
        }
    }
}
