// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// One captured revision's bounded proof. The revision is compared by equality only. The total is the exact count that the
/// owner's snapshot reference named in the same turn as the rows. `rows` is nil once the rows are physically released, and the
/// proof stays. The proof answers expiry from its capture time alone, so a read never depends on whether the janitor has run.
struct RuntimeCaptureProof {
    let revision: ControlCollectionRevision
    let total: ControlCount
    let capturedAt: ContinuousClock.Instant
    private(set) var rows: ControlProjectedRows?
    private(set) var rowBytes: Int

    fileprivate init(revision: ControlCollectionRevision, total: ControlCount, capturedAt: ContinuousClock.Instant, rows: ControlProjectedRows, rowBytes: Int) {
        self.revision = revision
        self.total = total
        self.capturedAt = capturedAt
        self.rows = rows
        self.rowBytes = rowBytes
    }

    fileprivate mutating func releaseRows() -> Int {
        let freed = rows == nil ? 0 : rowBytes
        rows = nil
        rowBytes = 0
        return freed
    }
}

/// What a page request for one kind resolves to, decided against the owner's current revision and the bounded proofs.
enum RuntimePageDecision {
    /// The current revision's rows are retained and not logically expired, so they serve the page. `total` is the exact count the proof
    /// recorded. The service has already compared it with the same turn's snapshot, before it asked for this decision.
    case current(ControlProjectedRows, total: ControlCount)
    /// An older revision whose rows are retained and not logically expired. The page names that revision, and it reports the
    /// current one as stale.
    case stale(revision: ControlCollectionRevision, rows: ControlProjectedRows)
    /// The current revision has no live rows, so it must be captured before a page is served.
    case needsCapture
    /// The revision has a proof, and its rows are gone or past their age at this read. The proof's exact total is known.
    case expired(total: ControlCount)
    /// No proof is held: the revision was never captured, or its proof was evicted. No total is known, so none is reported.
    /// An unknown revision is never expired.
    case notCaptured
}

/// The closed result of one capture. Capacity and owner-data refusals precede mutation.
/// An internal invariant failure does not promise recovery or unchanged corrupted state.
enum RuntimeCaptureResult: Equatable {
    case stored
    /// The rows exceed the row bound, the per-capture byte bound, or the retained-byte bound. Nothing was stored.
    case overBudget
    /// The owner's rows are of another kind, or they do not count the snapshot's exact total. Nothing was stored.
    case countOrKindMismatch
    /// The ledger's own byte accounting disagrees with the row sets it holds. That is a bug in the service, not a capacity answer. It is
    /// detected before any change, so nothing was stored or released.
    case invariantFailure
}

/// The bounded collection ledger. It keeps one proof per captured revision, up to a fixed count per kind. It keeps the rows of the
/// newest revisions within a count per kind and a byte total across all kinds.
///
/// Expiry is logical and physical, and they are separate. A row set is logically expired at a read when its age, from its own
/// capture time and the injected clock, has reached the row retention age. The read decides that directly, so an expired row set
/// is never served just because the janitor has not reached it. Physical release happens in three places: a capture releases the
/// expired row sets first, so the live set that a capture leaves behind does not depend on the janitor; the bounded janitor
/// releases expired rows at its own pace; and eviction releases the oldest live row set when a bound needs room.
///
/// Eviction is best effort and visible. Releasing rows leaves an exact proof, which reports expiry. Evicting a proof leaves no
/// trace, which reports not captured. Nothing is tombstoned, no revision is ordered or assumed dense, and no lease is promised.
struct RuntimeCollectionLedger {
    private let maxRows: Int
    private let proofCapacityPerKind: Int
    private let rowRevisionsPerKind: Int
    private let rowByteCapacity: Int
    private let captureByteCapacity: Int
    private let rowRetentionAge: Duration
    /// Proofs per kind, oldest capture first. The owner's clock is monotonic, so capture times follow the same order.
    private var proofs: [ControlCollectionKind: [RuntimeCaptureProof]] = [:]
    /// The encoded bytes of every physically retained row set, across all kinds. It never exceeds `rowByteCapacity`.
    private(set) var retainedRowBytes = 0
    /// The janitor's rotating position over every proof slot, which is `kinds × proofCapacityPerKind` slots in all.
    private var sweepSlot = 0
    /// The slots the last janitor turn inspected. It never exceeds the batch it was given.
    private(set) var inspectedSlotsInLastSweep = 0

    init(limits: RuntimeServiceLimits) {
        self.init(
            rowCapacity: limits.collectionRowCapacity,
            rowByteCapacity: limits.collectionRetainedByteCapacity,
            captureByteCapacity: limits.collectionByteCapacity,
            proofCapacityPerKind: limits.collectionProofCapacityPerKind,
            rowRevisionsPerKind: limits.collectionRowRevisionsPerKind,
            rowRetentionAge: limits.collectionRowRetentionAge
        )
    }

    /// The accounting seam. It takes explicit bounds, so a test can reach values that no shipping limit can express, such as a
    /// total near `Int.max`. Production builds the ledger with `init(limits:)`, and the bounds are the validated limits.
    init(
        rowCapacity: Int,
        rowByteCapacity: Int,
        captureByteCapacity: Int,
        proofCapacityPerKind: Int,
        rowRevisionsPerKind: Int,
        rowRetentionAge: Duration
    ) {
        self.maxRows = rowCapacity
        self.rowByteCapacity = rowByteCapacity
        self.captureByteCapacity = captureByteCapacity
        self.proofCapacityPerKind = proofCapacityPerKind
        self.rowRevisionsPerKind = rowRevisionsPerKind
        self.rowRetentionAge = rowRetentionAge
    }

    /// The proofs one kind holds now.
    func proofCount(_ kind: ControlCollectionKind) -> Int {
        proofs[kind, default: []].count
    }

    /// The physically retained row sets one kind holds now. A set that is logically expired but not yet released still counts.
    func retainedRowSetCount(_ kind: ControlCollectionKind) -> Int {
        proofs[kind, default: []].filter { $0.rows != nil }.count
    }

    /// The proof for one revision, when one is held.
    func proof(_ kind: ControlCollectionKind, revision: ControlCollectionRevision) -> RuntimeCaptureProof? {
        proofs[kind, default: []].last { $0.revision == revision }
    }

    /// Whether a proof's rows have reached their age at `now`. The age is measured from the proof's own capture.
    func isExpired(_ entry: RuntimeCaptureProof, at now: ContinuousClock.Instant) -> Bool {
        now - entry.capturedAt >= rowRetentionAge
    }

    /// Decides one page request at `now`. A nil cursor, or one equal to the current revision, reads the current revision. Any other
    /// cursor reads its own revision, and no decision is made from any ordering between revisions. The decision does not change
    /// any state, so it never waits for the janitor.
    func decision(
        kind: ControlCollectionKind,
        cursor: ControlCollectionRevision?,
        current: ControlCollectionRevision,
        at now: ContinuousClock.Instant
    ) -> RuntimePageDecision {
        guard let cursor, cursor != current else {
            guard let entry = proof(kind, revision: current), !isExpired(entry, at: now), let rows = entry.rows else {
                return .needsCapture
            }
            return .current(rows, total: entry.total)
        }
        guard let entry = proof(kind, revision: cursor) else { return .notCaptured }
        guard let rows = entry.rows, !isExpired(entry, at: now) else { return .expired(total: entry.total) }
        return .stale(revision: cursor, rows: rows)
    }

    /// Stores one capture of a kind's current revision. A capture is refused whole, with no truncation, and with no state change,
    /// when its rows are of another kind or do not count the exact total, when the total is past the row bound, or when its bytes
    /// exceed one capture's bound or the retained bound. Every one of those checks runs before the first change.
    ///
    /// A stored capture first replaces any proof of the same revision, then releases every logically expired row set, then evicts the
    /// oldest live row sets of its kind until the count bound holds, then the oldest live row sets of any kind until the byte bound
    /// holds, then the oldest proofs of its kind. The byte check compares against the remaining room, so it cannot overflow.
    @discardableResult
    mutating func capture(
        _ kind: ControlCollectionKind,
        revision: ControlCollectionRevision,
        total: ControlCount,
        rows: ControlProjectedRows,
        encodedBytes: Int,
        at now: ContinuousClock.Instant
    ) -> RuntimeCaptureResult {
        guard rows.kind == kind, rows.rowCount == total.rawValue else { return .countOrKindMismatch }
        guard total.rawValue <= maxRows, encodedBytes <= captureByteCapacity, encodedBytes <= rowByteCapacity else {
            return .overBudget
        }
        // The accounting is checked before the first change, so an accounting bug is refused whole and never applied in part.
        guard retainedRowBytes == heldRowBytes() else {
            assertionFailure("the retained bytes disagree with the held row sets")
            return .invariantFailure
        }
        // A revision that is captured again replaces its own proof, so no revision is held twice.
        if let index = proofs[kind]?.lastIndex(where: { $0.revision == revision }) {
            release(kind, at: index)
            proofs[kind]?.remove(at: index)
        }
        releaseExpired(at: now)
        while retainedRowSetCount(kind) >= rowRevisionsPerKind {
            guard let index = proofs[kind]?.firstIndex(where: { $0.rows != nil }) else { break }
            release(kind, at: index)
        }
        // `retainedRowBytes` never exceeds `rowByteCapacity`, so the remaining room is never negative and nothing is summed.
        while encodedBytes > rowByteCapacity - retainedRowBytes {
            guard let oldest = oldestRowSet() else {
                // Unreachable once the accounting check above has passed: with no row set held, no bytes are held, and the encoded bytes
                // already fit the whole bound. The assertion catches the bug in a debug build, and the result stays closed in a release build.
                assertionFailure("the retained bytes name no row set")
                return .invariantFailure
            }
            release(oldest.kind, at: oldest.index)
        }
        let entry = RuntimeCaptureProof(
            revision: revision,
            total: total,
            capturedAt: now,
            rows: rows,
            rowBytes: encodedBytes
        )
        proofs[kind, default: []].append(entry)
        retainedRowBytes += encodedBytes
        // The oldest proof goes first, and its rows go with it. The new proof is never the one removed.
        while proofCount(kind) > proofCapacityPerKind {
            release(kind, at: 0)
            proofs[kind]?.removeFirst()
        }
        return .stored
    }

    /// The janitor's bounded turn. It inspects at most `batch` proof slots, starting where the last turn stopped, and it releases the
    /// rows of each inspected proof that is logically expired. A full rotation takes at most `ceil(slots / batch)` turns, so every
    /// expired row set is reached in that many turns. It schedules no task and holds no queue.
    ///
    /// Physical cleanup is driven by activity: the service calls the janitor on its own turns, and it has no timer. So an expired row set
    /// stays resident while the service is idle. That residence is inside the fixed byte bound, and a read never serves it, because the
    /// read decides expiry from the proof's capture time.
    mutating func sweep(now: ContinuousClock.Instant, batch: Int) {
        let kinds = ControlCollectionKind.allCases
        let slots = kinds.count * proofCapacityPerKind
        inspectedSlotsInLastSweep = 0
        while inspectedSlotsInLastSweep < batch {
            let kind = kinds[sweepSlot / proofCapacityPerKind]
            let index = sweepSlot % proofCapacityPerKind
            if index < proofCount(kind), let entry = proofs[kind]?[index], entry.rows != nil, isExpired(entry, at: now) {
                release(kind, at: index)
            }
            sweepSlot = (sweepSlot + 1) % slots
            inspectedSlotsInLastSweep += 1
        }
    }

    /// Releases every logically expired row set, across all kinds. It scans the bounded proof table once.
    private mutating func releaseExpired(at now: ContinuousClock.Instant) {
        for kind in ControlCollectionKind.allCases {
            let entries = proofs[kind, default: []]
            for index in entries.indices where entries[index].rows != nil && isExpired(entries[index], at: now) {
                release(kind, at: index)
            }
        }
    }

    /// The encoded bytes of every physically held row set, summed from the proofs. It equals `retainedRowBytes` while the accounting holds.
    /// It scans the bounded proof table once, and it changes nothing.
    private func heldRowBytes() -> Int {
        var held = 0
        for entries in proofs.values {
            for entry in entries where entry.rows != nil {
                held += entry.rowBytes
            }
        }
        return held
    }

    /// Releases one proof's rows and returns their bytes to the total.
    private mutating func release(_ kind: ControlCollectionKind, at index: Int) {
        guard proofs[kind]?.indices.contains(index) == true else { return }
        let freed = proofs[kind]?[index].releaseRows() ?? 0
        retainedRowBytes -= freed
    }

    /// The physically retained row set captured earliest, across all kinds, when any is retained. Within a kind, the earliest in capture
    /// order is the oldest, since the clock is monotonic. Across kinds, a tie in capture instant goes to the kind that comes first in
    /// `ControlCollectionKind.allCases`, so the choice is deterministic and does not depend on the order of the captures.
    private func oldestRowSet() -> (kind: ControlCollectionKind, index: Int)? {
        var oldest: (kind: ControlCollectionKind, index: Int, at: ContinuousClock.Instant)?
        for kind in ControlCollectionKind.allCases {
            guard let index = proofs[kind]?.firstIndex(where: { $0.rows != nil }), let entry = proofs[kind]?[index] else {
                continue
            }
            if let current = oldest, current.at <= entry.capturedAt { continue }
            oldest = (kind, index, entry.capturedAt)
        }
        return oldest.map { (kind: $0.kind, index: $0.index) }
    }
}
