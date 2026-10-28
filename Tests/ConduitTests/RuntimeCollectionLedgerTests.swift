// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import XCTest
@testable import ConduitRuntime
@testable import ProxyKernel

/// The collection ledger, its projection bound, and the page decisions that the production service makes from it. Every limit is a
/// fixture value, and no test chooses a shipping bound. Rows are tunnel DNS hosts, whose encoded size is measured from the codec.
final class RuntimeCollectionLedgerTests: XCTestCase {
    private let kind = ControlCollectionKind.tunnelDNSHosts

    @RuntimeActor private func rev(_ value: Int) -> ControlCollectionRevision {
        ControlCollectionRevision(rawValue: value) ?? ControlCollectionRevision(rawValue: 0)!
    }

    /// Captures `rows` hostnames under `revision`, as the owner would: through the shared budget, then the ledger.
    @RuntimeActor private func capture(
        _ ledger: inout RuntimeCollectionLedger,
        revision value: Int,
        rows: Int,
        at now: ContinuousClock.Instant
    ) throws -> Bool {
        let names = Array(repeating: "a", count: rows)
        guard case .complete(let measured, let bytes) = ControlRowBudget(maxRows: 16, maxBytes: 1 << 14).measure(
            names, { ControlTunnelDNSHostRow(hostname: $0, outcome: .active) }
        ) else {
            return false
        }
        return ledger.capture(
            kind,
            revision: rev(value),
            total: try ControlCount(rows),
            rows: .tunnelDNSHosts(measured),
            encodedBytes: bytes,
            at: now
        ) == .stored
    }

    // MARK: - Ledger decisions

    @RuntimeActor func testACurrentCaptureServesItsRowsAndAMissingOneNeedsCapture() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits())
        let now = ContinuousClock.now
        XCTAssertTrue(ledger.decision(kind: kind, cursor: nil, current: rev(1), at: now).needsCapture)
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 2, at: now))
        guard case .current(let rows, _) = ledger.decision(kind: kind, cursor: nil, current: rev(1), at: now) else {
            return XCTFail("a captured current revision serves its rows")
        }
        XCTAssertEqual(rows.rowCount, 2)
        XCTAssertEqual(ledger.proofCount(kind), 1)
        XCTAssertEqual(ledger.retainedRowSetCount(kind), 1)
    }

    @RuntimeActor func testAnOlderRetainedRevisionIsStaleWithItsRowsAndAnUnknownRevisionIsNotCaptured() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits())
        let now = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 1, at: now))
        guard case .stale(let revision, let rows) = ledger.decision(kind: kind, cursor: rev(1), current: rev(2), at: now) else {
            return XCTFail("a retained older revision is stale, not current")
        }
        XCTAssertEqual(revision, rev(1))
        XCTAssertEqual(rows.rowCount, 1)
        guard case .notCaptured = ledger.decision(kind: kind, cursor: rev(9), current: rev(2), at: now) else {
            return XCTFail("a revision that was never captured is not captured, and it is never reported as expired")
        }
    }

    @RuntimeActor func testRowEvictionLeavesAnExactProofThatReportsExpiryWithItsTotal() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits(collectionRowSets: 1))
        let now = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 3, at: now))
        XCTAssertTrue(try capture(&ledger, revision: 2, rows: 1, at: now))
        guard case .expired(let total) = ledger.decision(kind: kind, cursor: rev(1), current: rev(2), at: now) else {
            return XCTFail("the proof of an evicted row set reports expiry")
        }
        XCTAssertEqual(total.rawValue, 3, "the expired proof carries its own captured total, not the current one")
        XCTAssertEqual(ledger.proofCount(kind), 2, "row eviction keeps the exact proof")
        XCTAssertEqual(ledger.retainedRowSetCount(kind), 1)
    }

    @RuntimeActor func testProofEvictionReportsNotCapturedNotExpired() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits(collectionProofs: 1))
        let now = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 1, at: now))
        XCTAssertTrue(try capture(&ledger, revision: 2, rows: 1, at: now))
        guard case .notCaptured = ledger.decision(kind: kind, cursor: rev(1), current: rev(2), at: now) else {
            return XCTFail("a forgotten proof is not captured, because nothing proves that the rows existed")
        }
        XCTAssertEqual(ledger.proofCount(kind), 1, "the proof table stays bounded, with no tombstones")
    }

    /// Expiry is decided at the read from the proof's own capture time. The janitor has not run, so the rows are still held, and the
    /// read still answers expired at the age boundary and current-needs-capture there.
    @RuntimeActor func testAnUnvisitedExpiredProofReadsAsExpiredAtTheAgeBoundaryWithoutTheJanitor() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits(collectionRowAge: .seconds(60)))
        let captured = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 1, at: captured))
        let justBefore = captured.advanced(by: .seconds(59))
        let atAge = captured.advanced(by: .seconds(60))
        guard case .stale = ledger.decision(kind: kind, cursor: rev(1), current: rev(2), at: justBefore) else {
            return XCTFail("one second before the age, the rows still serve")
        }
        guard case .expired = ledger.decision(kind: kind, cursor: rev(1), current: rev(2), at: atAge) else {
            return XCTFail("at the age, the rows are expired, even though nothing physically released them")
        }
        XCTAssertEqual(ledger.retainedRowSetCount(kind), 1, "the decision changed no state: the rows are still physically held")
        XCTAssertTrue(ledger.decision(kind: kind, cursor: nil, current: rev(1), at: atAge).needsCapture, "the current revision is captured again")
        XCTAssertFalse(ledger.decision(kind: kind, cursor: nil, current: rev(1), at: justBefore).needsCapture)
    }

    @RuntimeActor func testAnOverBudgetOrMismatchedCaptureIsRefusedWholeAndStoresNothing() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits(collectionCaptureBytes: 60))
        let now = ContinuousClock.now
        let oversize = ledger.capture(kind, revision: rev(1), total: try ControlCount(0), rows: .tunnelDNSHosts([]), encodedBytes: 1 << 20, at: now)
        XCTAssertEqual(oversize, .overBudget, "a capture past its byte bound is an honest capacity refusal")
        let row = ControlTunnelDNSHostRow(hostname: "a", outcome: .active)
        let countMismatch = ledger.capture(kind, revision: rev(1), total: try ControlCount(2), rows: .tunnelDNSHosts([row]), encodedBytes: 1, at: now)
        XCTAssertEqual(countMismatch, .countOrKindMismatch, "a count that disagrees with the exact total is the owner's invariant, not capacity")
        let kindMismatch = ledger.capture(kind, revision: rev(1), total: try ControlCount(0), rows: .upstreamHealth([]), encodedBytes: 1, at: now)
        XCTAssertEqual(kindMismatch, .countOrKindMismatch, "rows of another kind are refused")
        XCTAssertEqual(ledger.proofCount(kind), 0, "a refused capture leaves no proof")
        XCTAssertEqual(ledger.retainedRowBytes, 0)
    }

    /// A refusal for the total or for the owner's invariant is decided before any state changes. A held row set and its proof survive it.
    @RuntimeActor func testARefusedCaptureChangesNoHeldStateEvenWhenARowSetIsAlreadyHeld() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits())
        let now = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 2, at: now))
        let heldBytes = ledger.retainedRowBytes
        let seventeen = Array(repeating: ControlTunnelDNSHostRow(hostname: "a", outcome: .active), count: 17)
        let overRow = ledger.capture(kind, revision: rev(2), total: try ControlCount(17), rows: .tunnelDNSHosts(seventeen), encodedBytes: 1, at: now)
        XCTAssertEqual(overRow, .overBudget, "a total past the row bound is refused whole")
        let mismatch = ledger.capture(kind, revision: rev(1), total: try ControlCount(1), rows: .tunnelDNSHosts(seventeen), encodedBytes: 1, at: now)
        XCTAssertEqual(mismatch, .countOrKindMismatch)
        XCTAssertEqual(ledger.proofCount(kind), 1, "the held proof of revision 1 is not replaced by a refused capture")
        XCTAssertEqual(ledger.retainedRowBytes, heldBytes)
        guard case .current = ledger.decision(kind: kind, cursor: nil, current: rev(1), at: now) else {
            return XCTFail("the held revision still serves its rows after the refusals")
        }
    }

    @RuntimeActor func testRecapturingARevisionReplacesItsProofAndKeepsTheByteTotalExact() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits())
        let now = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 2, at: now))
        let once = ledger.retainedRowBytes
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 2, at: now))
        XCTAssertEqual(ledger.proofCount(kind), 1, "a revision is never held twice")
        XCTAssertEqual(ledger.retainedRowBytes, once, "replacing a row set does not double its bytes")
    }

    @RuntimeActor func testTheRetainedRowBytesNeverExceedTheirBoundAcrossCaptures() async throws {
        let limits = try RuntimeServiceFixtures.limits(collectionCaptureBytes: 200, collectionRetainedBytes: 200, collectionRowSets: 3)
        var ledger = RuntimeCollectionLedger(limits: limits)
        let now = ContinuousClock.now
        for step in 1...30 {
            _ = try capture(&ledger, revision: step, rows: 1 + step % 2, at: now.advanced(by: .seconds(step)))
            XCTAssertLessThanOrEqual(ledger.retainedRowBytes, limits.collectionRetainedByteCapacity, "step \(step)")
            XCTAssertLessThanOrEqual(ledger.proofCount(kind), limits.collectionProofCapacityPerKind, "step \(step)")
        }
    }

    /// The byte check compares against the room left, so a total near `Int.max` does not overflow. The bounds come through the
    /// accounting seam, because no shipping limit can express them. No row is allocated: only the encoded size is large.
    @RuntimeActor func testACaptureNearIntMaxEvictsTheOldRowsWithoutOverflow() async throws {
        var ledger = RuntimeCollectionLedger(
            rowCapacity: 16,
            rowByteCapacity: Int.max,
            captureByteCapacity: Int.max,
            proofCapacityPerKind: 4,
            rowRevisionsPerKind: 4,
            rowRetentionAge: .seconds(60)
        )
        let now = ContinuousClock.now
        let row = [ControlTunnelDNSHostRow(hostname: "a", outcome: .active)]
        XCTAssertEqual(ledger.capture(
            kind, revision: rev(1), total: try ControlCount(1),
            rows: .tunnelDNSHosts(row), encodedBytes: Int.max - 10, at: now
        ), .stored)
        XCTAssertEqual(ledger.capture(
            kind, revision: rev(2), total: try ControlCount(1),
            rows: .tunnelDNSHosts(row), encodedBytes: 20, at: now
        ), .stored, "the second capture fits after the first is released, without a sum that overflows")
        XCTAssertEqual(ledger.retainedRowBytes, 20)
        guard case .expired = ledger.decision(kind: kind, cursor: rev(1), current: rev(2), at: now) else {
            return XCTFail("the released row set leaves its proof, which reports expiry")
        }
    }

    // MARK: - The janitor's bounded turn

    /// Every janitor turn inspects at most its batch, even when most slots are empty or hold live rows. A rotation of
    /// `ceil(slots / batch)` turns reaches every expired row set, and it leaves the live one.
    @RuntimeActor func testTheJanitorInspectsAtMostItsBatchPerTurnAndReachesEveryExpiredRowSet() async throws {
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits(collectionProofs: 2, collectionRowAge: .seconds(60)))
        let start = ContinuousClock.now
        XCTAssertTrue(try capture(&ledger, revision: 1, rows: 1, at: start))
        XCTAssertTrue(try capture(&ledger, revision: 2, rows: 1, at: start.advanced(by: .seconds(30))))
        let now = start.advanced(by: .seconds(60))
        let batch = 3
        let slots = ControlCollectionKind.allCases.count * 2
        var turns = 0
        while ledger.retainedRowSetCount(kind) > 1, turns < slots {
            ledger.sweep(now: now, batch: batch)
            XCTAssertLessThanOrEqual(ledger.inspectedSlotsInLastSweep, batch, "turn \(turns)")
            turns += 1
        }
        XCTAssertEqual(ledger.retainedRowSetCount(kind), 1, "the expired row set was released, and the live one kept")
        XCTAssertLessThanOrEqual(turns, (slots + batch - 1) / batch, "one rotation reaches every slot")
        XCTAssertEqual(ledger.proofCount(kind), 2, "a released row set keeps its proof")
    }

    // MARK: - The shared projection bound

    /// The row mapper is observed through a counter, so a test can see how many rows were built. The count bound stops before the
    /// row past it is mapped, and the byte bound maps only the row it has to measure.
    @RuntimeActor func testTheProjectionStopsBuildingAtTheFirstRowPastTheCountBound() async {
        var built = 0
        let budget = ControlRowBudget(maxRows: 2, maxBytes: 1 << 20)
        let result = budget.measure(Array(0..<10)) { _ -> ControlTunnelDNSHostRow in
            built += 1
            return ControlTunnelDNSHostRow(hostname: "a", outcome: .active)
        }
        guard case .overBudget = result else { return XCTFail("an over-count capture is refused whole, got \(result)") }
        XCTAssertEqual(built, 2, "the third row is never built")
    }

    @RuntimeActor func testTheProjectionStopsBuildingAtTheFirstRowPastTheByteBound() async throws {
        let one = try RuntimeWireSize.bytes(of: ControlTunnelDNSHostRow(hostname: "a", outcome: .active))
        var built = 0
        let budget = ControlRowBudget(maxRows: 16, maxBytes: one)
        let result = budget.measure(Array(0..<10)) { _ -> ControlTunnelDNSHostRow in
            built += 1
            return ControlTunnelDNSHostRow(hostname: "a", outcome: .active)
        }
        guard case .overBudget = result else { return XCTFail("a second row past the byte bound refuses the whole, got \(result)") }
        XCTAssertEqual(built, 2, "the first row fits, and the second is built only to measure it")
    }

    /// A mapping that fails is an internal failure, not a capacity refusal, and the measure ends at the failing input.
    @RuntimeActor func testAMappingFailureIsAnInternalFailureAndEndsTheMeasureAtTheFailingInput() async {
        struct Invalid: Error {}
        var built = 0
        let budget = ControlRowBudget(maxRows: 16, maxBytes: 1 << 20)
        let result = budget.measure(Array(0..<10)) { value -> ControlTunnelDNSHostRow in
            built += 1
            if value == 3 { throw Invalid() }
            return ControlTunnelDNSHostRow(hostname: "a", outcome: .active)
        }
        guard case .internalFailure = result else { return XCTFail("a failed mapping is a closed internal failure, got \(result)") }
        XCTAssertEqual(built, 4, "the rows after the failing input are never mapped")
    }

    /// The bounds are checked for the whole measure, and an accepted measure keeps every row in order with the exact bytes.
    @RuntimeActor func testAMeasureWithinBothBoundsKeepsEveryRowInOrderWithItsExactBytes() async throws {
        let names = ["a", "bb", "ccc"]
        let budget = ControlRowBudget(maxRows: 3, maxBytes: 1 << 20)
        guard case .complete(let rows, let bytes) = budget.measure(names, { ControlTunnelDNSHostRow(hostname: $0, outcome: .active) }) else {
            return XCTFail("three rows within a three-row bound are complete")
        }
        XCTAssertEqual(rows.map(\.hostname), names)
        var expected = 0
        for row in rows {
            expected += try RuntimeWireSize.bytes(of: row)
        }
        XCTAssertEqual(bytes, expected, "the bytes are the sum of the rows, as the codec writes each")
    }

    // MARK: - Pages through the production service

    @RuntimeActor private func publish(_ harness: RuntimeServiceHarness, revision value: Int, hosts: [String]) throws {
        harness.owner.dnsHostnames = hosts
        harness.owner.snapshotValue = try RuntimeServiceFixtures.snapshot(
            incarnation: 1,
            collections: ControlCollectionRevisions(tunnelDNSHosts: rev(value)),
            dnsStatus: .active(hostnames: hosts)
        )
    }

    @RuntimeActor private func page(_ harness: RuntimeServiceHarness, cursor: ControlPageCursor? = nil) -> RuntimePageSource {
        harness.core.pageSource(ControlPageRequest(
            expectedIncarnation: RuntimeServiceFixtures.incarnation(1),
            collection: kind,
            cursor: cursor
        ))
    }

    /// The refusal a page source names, with its total as a plain count, so assertions read the same as the wire.
    private struct Refusal: Equatable {
        let reason: ControlCollectionUnavailableReason
        let knownTotal: Int?
    }

    @RuntimeActor private func refusal(_ source: RuntimePageSource) -> Refusal? {
        guard case .unavailable(let reason, let knownTotal) = source else { return nil }
        return Refusal(reason: reason, knownTotal: knownTotal?.rawValue)
    }

    @RuntimeActor func testAStaleCursorIsServedFromRetainedRowsAndNamesTheCurrentRevision() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        try publish(harness, revision: 1, hosts: ["a"])
        _ = page(harness)
        try publish(harness, revision: 2, hosts: ["x", "y"])
        let source = page(harness, cursor: try ControlPageCursor(revision: rev(1), offset: ControlCount(0)))
        guard case .rows(let revision, let rows, _, let status) = source else {
            return XCTFail("the retained rows of revision 1 are served, got \(source)")
        }
        XCTAssertEqual(revision, rev(1))
        XCTAssertEqual(rows.rowCount, 1)
        XCTAssertEqual(status, .staleRevision(current: rev(2)))
        XCTAssertEqual(harness.owner.projectionCount, 1, "a cursor read of an older revision serves its retained rows and captures nothing")
    }

    @RuntimeActor func testARowEvictedRevisionIsReportedAsExpiredWithItsOwnCapturedTotal() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionRowSets: 1))
        try publish(harness, revision: 1, hosts: ["a", "b"])
        _ = page(harness)
        try publish(harness, revision: 2, hosts: ["b"])
        _ = page(harness)
        let source = page(harness, cursor: try ControlPageCursor(revision: rev(1), offset: ControlCount(0)))
        XCTAssertEqual(refusal(source), Refusal(reason: .expiredRevision, knownTotal: 2), "the proof's total of revision 1, not the current total")
    }

    @RuntimeActor func testAnEvictedProofIsReportedAsNotCapturedWithNoTotalAndAnArbitraryCursorToo() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionProofs: 1))
        try publish(harness, revision: 1, hosts: ["a"])
        _ = page(harness)
        try publish(harness, revision: 2, hosts: ["b"])
        _ = page(harness)
        for cursor in [1, 9] {
            let source = page(harness, cursor: try ControlPageCursor(revision: rev(cursor), offset: ControlCount(0)))
            XCTAssertEqual(
                refusal(source),
                Refusal(reason: .notCaptured, knownTotal: nil),
                "cursor \(cursor) is not captured, and no total is borrowed from another revision"
            )
        }
    }

    @RuntimeActor func testAnOverBudgetCaptureIsRefusedWholeWithItsExactTotalAndNoProof() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionCaptureBytes: 60))
        try publish(harness, revision: 1, hosts: ["a", "b", "c"])
        let first = page(harness)
        XCTAssertEqual(refusal(first), Refusal(reason: .retentionBudgetExceeded, knownTotal: 3), "the snapshot's exact total, and no truncation")
        _ = page(harness)
        XCTAssertEqual(harness.owner.projectionCount, 2, "nothing was stored, so the next read captures again")
    }

    /// The exact total is checked before the owner projects a row. A total past the row bound is refused with its total, and the owner
    /// is never asked for rows.
    @RuntimeActor func testAnExactTotalPastTheRowBoundIsRefusedBeforeTheOwnerProjectsAnyRow() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        let hosts = (1...17).map { "h\($0).example" }
        try publish(harness, revision: 1, hosts: hosts)
        let source = page(harness)
        XCTAssertEqual(refusal(source), Refusal(reason: .retentionBudgetExceeded, knownTotal: 17))
        XCTAssertEqual(harness.owner.projectionCount, 0, "the owner is not asked to project a collection past the row bound")
        XCTAssertEqual(harness.core.collectionRetention(kind).proofs, 0, "nothing is stored")
    }

    /// A current revision the snapshot reports as unavailable names no revision, and its exact total is the snapshot's.
    @RuntimeActor func testAnUnavailableCurrentRevisionReportsTheSnapshotTotalAndNoRevision() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        harness.owner.dnsHostnames = ["a", "b"]
        harness.owner.snapshotValue = try RuntimeServiceFixtures.snapshot(
            incarnation: 1,
            collections: ControlCollectionRevisions(),
            dnsStatus: .active(hostnames: ["a", "b"])
        )
        XCTAssertEqual(refusal(page(harness)), Refusal(reason: .notCaptured, knownTotal: 2))
        XCTAssertEqual(harness.owner.projectionCount, 0)
    }

    @RuntimeActor func testTheCurrentRevisionIsCapturedAgainOnDemandAfterItsRowsAged() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionRowAge: .seconds(60)))
        try publish(harness, revision: 1, hosts: ["a"])
        _ = page(harness)
        XCTAssertEqual(harness.owner.projectionCount, 1)
        harness.timing.advance(by: .seconds(61))
        let source = page(harness)
        guard case .rows(_, let rows, _, let status) = source else { return XCTFail("expected rows, got \(source)") }
        XCTAssertEqual(rows.rowCount, 1)
        XCTAssertEqual(status, .current)
        XCTAssertEqual(harness.owner.projectionCount, 2, "the aged current revision was captured again, not served")
    }

    /// The owner's rows disagree with the snapshot's exact total in one turn. That is an owner invariant: the fault is reported once, the
    /// read is an internal failure, and the retained revision and its proof survive, including for a read the fault callback makes.
    @RuntimeActor func testACountMismatchIsAnOwnerInvariantFaultWithNoPartialCaptureAndPreservedRetention() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        try publish(harness, revision: 1, hosts: ["a"])
        _ = page(harness)
        let heldBytes = harness.core.collectionRetention(kind).retainedBytes
        try publish(harness, revision: 2, hosts: ["x", "y"])
        harness.owner.projectionOverride = { _, _ in
            .rows(.tunnelDNSHosts([ControlTunnelDNSHostRow(hostname: "x", outcome: .active)]), encodedBytes: 1)
        }
        var observedInCallback: (proofs: Int, rowSets: Int, retainedBytes: Int)?
        var reentrantRead: RuntimePageSource?
        let retainedCursor = try ControlPageCursor(revision: rev(1), offset: ControlCount(0))
        harness.owner.onFault = { _ in
            observedInCallback = harness.core.collectionRetention(self.kind)
            reentrantRead = harness.core.pageSource(ControlPageRequest(
                expectedIncarnation: RuntimeServiceFixtures.incarnation(1),
                collection: self.kind,
                cursor: retainedCursor
            ))
        }

        let source = page(harness)
        guard case .internalFailure = source else { return XCTFail("a count mismatch is an internal failure, got \(source)") }
        XCTAssertEqual(harness.owner.faults, [.projectionCountMismatch], "the owner is told once, with the closed case")
        XCTAssertEqual(observedInCallback?.proofs, 1, "the callback sees the held proof, and no proof of the mismatched capture")
        XCTAssertEqual(observedInCallback?.rowSets, 1)
        XCTAssertEqual(observedInCallback?.retainedBytes, heldBytes, "no bytes of the mismatched capture were accepted")
        guard let reentrantRead, case .rows(let revision, _, _, .staleRevision(current: rev(2))) = reentrantRead else {
            return XCTFail("a read made from the callback still serves the retained revision, got \(String(describing: reentrantRead))")
        }
        XCTAssertEqual(revision, rev(1))
        XCTAssertEqual(harness.core.collectionRetention(kind).proofs, 1)
    }

    /// The owner reports a different exact total for a revision the service already holds with its own total. A revision is immutable,
    /// so the owner broke its invariant: nothing is served, replaced or recaptured, and the owner is told once with a closed fault.
    @RuntimeActor func testAChangedTotalUnderAHeldRevisionIsAnOwnerInvariantFaultAndNothingIsRecaptured() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        try publish(harness, revision: 1, hosts: ["a", "b"])
        _ = page(harness)
        XCTAssertEqual(harness.owner.projectionCount, 1)
        try publish(harness, revision: 1, hosts: ["a", "b", "c"])
        let source = page(harness)
        guard case .internalFailure = source else { return XCTFail("a changed total under a held revision is an internal failure, got \(source)") }
        XCTAssertEqual(harness.owner.faults, [.revisionTotalChanged])
        XCTAssertEqual(harness.owner.projectionCount, 1, "nothing is recaptured from an immutable revision")
        XCTAssertEqual(harness.core.collectionRetention(kind).proofs, 1, "the held proof is neither replaced nor removed")
    }

    /// The current revision's rows aged out, so its proof is the only record of its total. The owner then reports the same revision with
    /// another exact total. The total is compared before any decision, so the aged revision is not recaptured or replaced, and the fault
    /// callback still sees the proof with the total it recorded.
    @RuntimeActor func testAChangedTotalUnderAnAgedCurrentRevisionIsAnOwnerInvariantFaultAndNothingIsRecaptured() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionRowAge: .seconds(60)))
        try publish(harness, revision: 1, hosts: ["a", "b"])
        _ = page(harness)
        harness.timing.advance(by: .seconds(61))
        try publish(harness, revision: 1, hosts: ["a", "b", "c"])
        var totalInCallback: Int?
        harness.owner.onFault = { _ in
            totalInCallback = harness.core.collectionProofTotal(self.kind, revision: self.rev(1))?.rawValue
        }
        let source = page(harness)
        guard case .internalFailure = source else {
            return XCTFail("a changed total under an aged revision is an internal failure, got \(source)")
        }
        XCTAssertEqual(harness.owner.faults, [.revisionTotalChanged])
        XCTAssertEqual(totalInCallback, 2, "the fault callback sees the aged proof with the total it recorded")
        XCTAssertEqual(harness.owner.projectionCount, 1, "nothing is recaptured from an immutable revision")
        XCTAssertEqual(harness.core.collectionRetention(kind).rowSets, 1, "the aged rows are neither released nor replaced")
    }

    /// Capturing the next revision released the current revision's rows, and its proof stayed. The owner then reports that revision again
    /// with another exact total. A released proof answers the same fault as a held one.
    @RuntimeActor func testAChangedTotalUnderAReleasedCurrentRevisionIsAnOwnerInvariantFault() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionRowSets: 1))
        try publish(harness, revision: 1, hosts: ["a", "b"])
        _ = page(harness)
        try publish(harness, revision: 2, hosts: ["x"])
        _ = page(harness)
        XCTAssertEqual(harness.core.collectionRetention(kind).rowSets, 1, "the capture of revision two released revision one's rows")
        try publish(harness, revision: 1, hosts: ["a", "b", "c"])
        let source = page(harness)
        guard case .internalFailure = source else {
            return XCTFail("a changed total under a released revision is an internal failure, got \(source)")
        }
        XCTAssertEqual(harness.owner.faults, [.revisionTotalChanged])
        XCTAssertEqual(harness.owner.projectionCount, 2, "nothing is recaptured from an immutable revision")
        XCTAssertEqual(harness.core.collectionProofTotal(kind, revision: rev(1))?.rawValue, 2, "the released proof keeps the total it recorded")
    }

    /// Eviction forgot the proof of the current revision, so no old total exists to compare. The revision is captured again, with the
    /// owner's rows and total, and no fault is raised.
    @RuntimeActor func testAForgottenProofLeavesNoOldTotalToCompareSoTheCurrentRevisionIsCapturedAgain() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(collectionProofs: 1))
        try publish(harness, revision: 1, hosts: ["a"])
        _ = page(harness)
        try publish(harness, revision: 2, hosts: ["b"])
        _ = page(harness)
        XCTAssertNil(harness.core.collectionProofTotal(kind, revision: rev(1)), "the proof of revision one was evicted")
        try publish(harness, revision: 1, hosts: ["a", "b", "c"])
        let source = page(harness)
        guard case .rows(let revision, let rows, _, .current) = source else {
            return XCTFail("a revision whose proof was forgotten is captured again, got \(source)")
        }
        XCTAssertEqual(revision, rev(1))
        XCTAssertEqual(rows.rowCount, 3)
        XCTAssertEqual(harness.owner.faults, [])
        XCTAssertEqual(harness.owner.projectionCount, 3)
    }

    /// The owner's snapshot names another incarnation than the service. Nothing is read, and the owner is told as a closed fault.
    @RuntimeActor func testASnapshotFromAnotherIncarnationIsAClosedInternalFailureNotAnInvalidValue() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        harness.owner.snapshotValue = try RuntimeServiceFixtures.snapshot(incarnation: 2)
        let source = page(harness)
        guard case .internalFailure = source else { return XCTFail("the owner's invariant failure is internal, got \(source)") }
        XCTAssertEqual(harness.owner.faults, [.snapshotIncarnationMismatch])
        XCTAssertEqual(harness.owner.projectionCount, 0, "nothing was projected from the other incarnation")
    }

    // MARK: - Encoding failure at the shared measure

    /// A row whose encoding fails. The shared measure reports it as an internal failure, which is never a capacity refusal.
    private struct UnencodableRow: ControlCollectionRow {
        init() {}

        init(from decoder: any Decoder) throws {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "not decodable in this fixture"))
        }

        func encode(to encoder: any Encoder) throws {
            throw EncodingError.invalidValue(0, .init(codingPath: [], debugDescription: "not encodable in this fixture"))
        }

        func measure(into budget: inout ControlFrameBudget) throws {}
    }

    @RuntimeActor func testAnEncodingFailureIsAnInternalFailureNotACapacityRefusal() async {
        let result = ControlRowBudget(maxRows: 16, maxBytes: 1 << 20).measure([0], { _ in UnencodableRow() })
        guard case .internalFailure = result else { return XCTFail("an unencodable row is a closed internal failure, got \(result)") }
    }

    // MARK: - Cross-kind byte eviction

    /// The two kinds the cross-kind model uses, by index. Their `allCases` order is the tie order of the eviction.
    private static let crossKinds: [ControlCollectionKind] = [.upstreamHealth, .tunnelDNSHosts]

    /// The name length of each size class: one character, forty, and three hundred. The last class is larger than the capture bound.
    private static let crossNameLengths = [1, 40, 300]

    @RuntimeActor private func upstreamRow(named name: String) throws -> ControlUpstreamRow {
        ControlUpstreamRow(
            id: ControlUpstreamID(rawValue: UUID()), name: name, endpoint: "e:1", circuitState: .closed,
            ewmaLatencyMilliseconds: nil, consecutiveFailures: try ControlCount(0), openUntil: nil
        )
    }

    /// One row of a kind and size class, measured through the shared budget. Nil when the budget refuses it.
    @RuntimeActor private func crossRows(kind: Int, size: Int, budget: ControlRowBudget) -> (rows: ControlProjectedRows, bytes: Int)? {
        let name = String(repeating: "n", count: Self.crossNameLengths[size])
        switch Self.crossKinds[kind] {
        case .upstreamHealth:
            guard case .complete(let rows, let bytes) = budget.measure([name], { try self.upstreamRow(named: $0) }) else { return nil }
            return (.upstreamHealth(rows), bytes)
        case .tunnelDNSHosts:
            guard case .complete(let rows, let bytes) = budget.measure([name], { ControlTunnelDNSHostRow(hostname: $0, outcome: .active) }) else {
                return nil
            }
            return (.tunnelDNSHosts(rows), bytes)
        case .activeConnections, .tunnelBindings:
            preconditionFailure("the cross-kind model uses two kinds")
        }
    }

    /// The encoded size of each kind and size class, as the shared budget measures it. The setup checks the shape the model depends on.
    @RuntimeActor private func crossKindBytes() throws -> [[Int]] {
        var bytes = [[Int]](repeating: [], count: Self.crossKinds.count)
        for kind in 0..<Self.crossKinds.count {
            for size in 0..<Self.crossNameLengths.count {
                let measured = try XCTUnwrap(crossRows(kind: kind, size: size, budget: ControlRowBudget(maxRows: 16, maxBytes: 1 << 20)))
                bytes[kind].append(measured.bytes)
            }
        }
        let captureCap = max(bytes[0][1], bytes[1][1])
        XCTAssertNotEqual(bytes[0][1], bytes[1][1], "the two kinds have unequal row sizes")
        XCTAssertLessThan(bytes[0][0], bytes[0][1], "a longer name is a larger row")
        XCTAssertGreaterThan(bytes[0][2], captureCap, "the largest class is refused by the capture bound")
        XCTAssertGreaterThan(bytes[1][2], captureCap, "the largest class is refused by the capture bound")
        return bytes
    }

    /// The deterministic witness for the global byte bound. The upstream set is the oldest of any kind, and the tunnel DNS set is the kind
    /// being captured. Freeing room has to release the upstream set, which is the oldest set of any kind. Scanning only the requested
    /// kind would release the DNS set of revision one instead, and then the third capture would not fit. The witness is written to fail
    /// that way, but no source mutant has been run against it.
    @RuntimeActor func testAByteBoundReleasesTheOldestRowSetOfAnyKindNotOnlyOfTheKindBeingCaptured() async throws {
        let upstreamName = String(repeating: "n", count: 40)
        let upstreamBytes = try RuntimeWireSize.bytes(of: upstreamRow(named: upstreamName))
        let firstDNSBytes = try RuntimeWireSize.bytes(of: ControlTunnelDNSHostRow(hostname: "n", outcome: .active))
        let secondName = String(repeating: "n", count: 20)
        let secondDNSBytes = try RuntimeWireSize.bytes(of: ControlTunnelDNSHostRow(hostname: secondName, outcome: .active))
        XCTAssertLessThan(firstDNSBytes, secondDNSBytes)
        XCTAssertLessThan(secondDNSBytes, upstreamBytes, "the third set is larger than the DNS set it leaves beside, and smaller than the upstream set")
        var ledger = RuntimeCollectionLedger(limits: try RuntimeServiceFixtures.limits(
            collectionCaptureBytes: upstreamBytes,
            collectionRetainedBytes: upstreamBytes + firstDNSBytes,
            collectionProofs: 4,
            collectionRowSets: 2
        ))
        let now = ContinuousClock.now
        XCTAssertEqual(ledger.capture(
            .upstreamHealth, revision: rev(1), total: try ControlCount(1),
            rows: .upstreamHealth([try upstreamRow(named: upstreamName)]), encodedBytes: upstreamBytes, at: now
        ), .stored)
        XCTAssertEqual(ledger.capture(
            .tunnelDNSHosts, revision: rev(1), total: try ControlCount(1),
            rows: .tunnelDNSHosts([ControlTunnelDNSHostRow(hostname: "n", outcome: .active)]), encodedBytes: firstDNSBytes,
            at: now.advanced(by: .seconds(1))
        ), .stored)
        XCTAssertEqual(ledger.capture(
            .tunnelDNSHosts, revision: rev(2), total: try ControlCount(1),
            rows: .tunnelDNSHosts([ControlTunnelDNSHostRow(hostname: secondName, outcome: .active)]), encodedBytes: secondDNSBytes,
            at: now.advanced(by: .seconds(2))
        ), .stored, "the third set fits once the oldest set of any kind is released")
        let later = now.advanced(by: .seconds(2))
        guard case .expired = ledger.decision(kind: .upstreamHealth, cursor: rev(1), current: rev(2), at: later) else {
            return XCTFail("the oldest set of any kind is the one released, and its proof reports expiry")
        }
        guard case .stale = ledger.decision(kind: .tunnelDNSHosts, cursor: rev(1), current: rev(2), at: later) else {
            return XCTFail("the tunnel DNS set of revision one is still retained, because it was not the oldest")
        }
        XCTAssertEqual(ledger.retainedRowBytes, firstDNSBytes + secondDNSBytes)
    }

    /// One action of the cross-kind model. A capture names its kind by index, its revision and its size class. A janitor turn names its batch.
    private enum CrossAction: CustomStringConvertible {
        case capture(kind: Int, revision: Int, size: Int)
        case advance(Int)
        case janitor(batch: Int)

        var description: String {
            switch self {
            case .capture(let kind, let revision, let size): "capture(kind \(kind), revision \(revision), size \(size))"
            case .advance(let seconds): "advance(\(seconds)s)"
            case .janitor(let batch): "janitor(batch \(batch))"
            }
        }
    }

    /// Two kinds, two revisions and three size classes give 12 captures. With two advances that straddle the age and two janitor batches,
    /// the alphabet has 16 actions.
    private static let crossAlphabet: [CrossAction] = {
        var actions: [CrossAction] = []
        for kind in 0..<2 {
            for revision in 1...2 {
                for size in 0..<3 {
                    actions.append(.capture(kind: kind, revision: revision, size: size))
                }
            }
        }
        actions += [.advance(30), .advance(60), .janitor(batch: 1), .janitor(batch: 3)]
        return actions
    }()

    /// A second, smaller logical model for two kinds. It is one flat list in capture order, and every total is recomputed from that list. It has no
    /// per-kind table, no running counter and no janitor rotation. Physical release is modelled only by the logical rules. The drain checks the end state.
    private struct CrossKindModel {
        struct Entry {
            let kind: Int
            let revision: Int
            let capturedAt: Int
            var held: Bool
            let bytes: Int
        }

        let bytes: [[Int]]
        let captureCap: Int
        let retainedCap: Int
        let rowSets: Int
        let proofs: Int
        let age: Int
        var clock = 0
        var entries: [Entry] = []

        func expired(_ entry: Entry) -> Bool {
            clock - entry.capturedAt >= age
        }

        var heldBytes: Int {
            entries.reduce(0) { $0 + ($1.held ? $1.bytes : 0) }
        }

        var liveBytes: Int {
            entries.reduce(0) { $0 + (($1.held && !expired($1)) ? $1.bytes : 0) }
        }

        func heldCount(_ kind: Int) -> Int {
            entries.filter { $0.kind == kind && $0.held }.count
        }

        /// The oldest held set: the earliest capture instant, then the earlier kind, then the earlier capture.
        func oldestHeld() -> Int? {
            var oldest: Int?
            for index in entries.indices where entries[index].held {
                guard let current = oldest else {
                    oldest = index
                    continue
                }
                let candidate = entries[index]
                let incumbent = entries[current]
                if candidate.capturedAt < incumbent.capturedAt || (candidate.capturedAt == incumbent.capturedAt && candidate.kind < incumbent.kind) {
                    oldest = index
                }
            }
            return oldest
        }

        mutating func capture(kind: Int, revision: Int, size: Int) -> Bool {
            let cost = bytes[kind][size]
            guard cost <= captureCap, cost <= retainedCap else { return false }
            entries.removeAll { $0.kind == kind && $0.revision == revision }
            for index in entries.indices where entries[index].held && expired(entries[index]) {
                entries[index].held = false
            }
            while heldCount(kind) >= rowSets, let index = entries.firstIndex(where: { $0.kind == kind && $0.held }) {
                entries[index].held = false
            }
            while cost > retainedCap - heldBytes {
                guard let index = oldestHeld() else { return false }
                entries[index].held = false
            }
            entries.append(Entry(kind: kind, revision: revision, capturedAt: clock, held: true, bytes: cost))
            while let index = entries.firstIndex(where: { $0.kind == kind }), entries.filter({ $0.kind == kind }).count > proofs {
                entries.remove(at: index)
            }
            return true
        }

        func decision(kind: Int, cursor: Int?, current: Int) -> String {
            if cursor == nil || cursor == current {
                guard let entry = entries.last(where: { $0.kind == kind && $0.revision == current }), entry.held, !expired(entry) else {
                    return "needsCapture"
                }
                return "current:1"
            }
            guard let target = cursor, let entry = entries.last(where: { $0.kind == kind && $0.revision == target }) else {
                return "notCaptured"
            }
            guard entry.held, !expired(entry) else { return "expired" }
            return "stale:\(target):1"
        }
    }

    @RuntimeActor private func compareCrossKind(
        _ ledger: RuntimeCollectionLedger,
        _ model: CrossKindModel,
        current: Int,
        limits: RuntimeServiceLimits,
        base: ContinuousClock.Instant
    ) -> String? {
        let now = base.advanced(by: .seconds(model.clock))
        for kind in 0..<Self.crossKinds.count {
            let producedCount = ledger.proofCount(Self.crossKinds[kind])
            let modelCount = model.entries.filter { $0.kind == kind }.count
            if producedCount != modelCount { return "kind \(kind) proofs \(producedCount), model \(modelCount)" }
            for cursor in [nil, 1, 2, 9] as [Int?] {
                let produced = describe(ledger.decision(
                    kind: Self.crossKinds[kind],
                    cursor: cursor.map { rev($0) },
                    current: rev(current),
                    at: now
                ))
                let expected = model.decision(kind: kind, cursor: cursor, current: current)
                if produced != expected {
                    return "kind \(kind) cursor \(cursor.map { String($0) } ?? "nil"): produced \(produced), model \(expected)"
                }
            }
        }
        let physical = ledger.retainedRowBytes
        if physical < model.liveBytes || physical > model.heldBytes || physical > limits.collectionRetainedByteCapacity {
            return "physical \(physical) is outside live \(model.liveBytes) ... held \(model.heldBytes)"
        }
        return nil
    }

    /// Replays one cross-kind sequence against the production ledger and the model, and compares after every action. It returns the first
    /// disagreement, or nil. A drain of one full rotation, at batch one, must leave the physical total equal to the live total.
    @RuntimeActor private func replayCrossKind(_ sequence: [CrossAction], limits: RuntimeServiceLimits, bytes: [[Int]]) throws -> String? {
        var ledger = RuntimeCollectionLedger(limits: limits)
        var model = CrossKindModel(
            bytes: bytes,
            captureCap: limits.collectionByteCapacity,
            retainedCap: limits.collectionRetainedByteCapacity,
            rowSets: limits.collectionRowRevisionsPerKind,
            proofs: limits.collectionProofCapacityPerKind,
            age: 60
        )
        let base = ContinuousClock.now
        let current = 2
        let budget = ControlRowBudget(maxRows: limits.collectionRowCapacity, maxBytes: limits.collectionByteCapacity)
        for (step, action) in sequence.enumerated() {
            switch action {
            case .capture(let kind, let revision, let size):
                var productionStored = false
                if let captured = crossRows(kind: kind, size: size, budget: budget) {
                    guard captured.bytes == bytes[kind][size] else {
                        return "step \(step) (\(action)): measured \(captured.bytes) bytes, the codec size is \(bytes[kind][size])"
                    }
                    productionStored = ledger.capture(
                        Self.crossKinds[kind], revision: rev(revision), total: try ControlCount(1), rows: captured.rows,
                        encodedBytes: captured.bytes, at: base.advanced(by: .seconds(model.clock))
                    ) == .stored
                }
                let modelStored = model.capture(kind: kind, revision: revision, size: size)
                if productionStored != modelStored {
                    return "step \(step) (\(action)): stored \(productionStored), model \(modelStored)"
                }
            case .advance(let seconds):
                model.clock += seconds
            case .janitor(let batch):
                ledger.sweep(now: base.advanced(by: .seconds(model.clock)), batch: batch)
                if ledger.inspectedSlotsInLastSweep > batch {
                    return "step \(step) (\(action)): the janitor inspected \(ledger.inspectedSlotsInLastSweep) slots"
                }
            }
            if let mismatch = compareCrossKind(ledger, model, current: current, limits: limits, base: base) {
                return "step \(step) (\(action)): \(mismatch)"
            }
        }
        // The janitor rotates over every slot of every `ControlCollectionKind`, including the kinds this model does not use. A full
        // rotation therefore takes `allCases × proofs` turns, not `modelledKinds × proofs`. This is a harness budget, not a logical rule.
        let slots = ControlCollectionKind.allCases.count * limits.collectionProofCapacityPerKind
        for _ in 0..<slots {
            ledger.sweep(now: base.advanced(by: .seconds(model.clock)), batch: 1)
        }
        if ledger.retainedRowBytes != model.liveBytes {
            return "after the drain, physical \(ledger.retainedRowBytes) differs from the live \(model.liveBytes)"
        }
        return nil
    }

    /// The cross-kind model's exploration, stated exactly: every sequence of depth 1 to 4 over its 16 actions, which is 16 + 256 + 4,096 + 65,536
    /// = 69,904, and then 100 seeded walks of 25 actions. Its bounds are two kinds, two revisions per kind, three size classes with one refused,
    /// a retained bound of two accepted sets, three proofs per kind, a row age of 60 seconds, and janitor batches of one and three. It claims those
    /// bounds only. It does not claim more kinds, more sizes, more revisions, or longer walks.
    @RuntimeActor func testTheCrossKindLedgerMatchesItsModelOnEveryBoundedSequenceAndSeededWalk() async throws {
        let bytes = try crossKindBytes()
        let captureCap = max(bytes[0][1], bytes[1][1])
        let limits = try RuntimeServiceFixtures.limits(
            collectionCaptureBytes: captureCap,
            collectionRetainedBytes: 2 * captureCap - 1,
            collectionProofs: 3,
            collectionRowSets: 2,
            collectionRowAge: .seconds(60)
        )
        let alphabet = Self.crossAlphabet
        var checked = 0
        for depth in 1...4 {
            var indices = Array(repeating: 0, count: depth)
            repeat {
                let sequence = indices.map { alphabet[$0] }
                if let failure = try replayCrossKind(sequence, limits: limits, bytes: bytes) {
                    let text = sequence.map { "\($0)" }.joined(separator: ", ")
                    return XCTFail("shortest cross-kind counterexample at depth \(depth): [\(text)]: \(failure)")
                }
                checked += 1
            } while nextIndices(&indices, base: alphabet.count)
        }
        for seed in 1...100 {
            var random = SplitMix64(state: UInt64(seed))
            let sequence = (0..<25).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }
            if let failure = try replayCrossKind(sequence, limits: limits, bytes: bytes) {
                return XCTFail("cross-kind walk seed \(seed): \(failure)")
            }
            checked += 1
        }
        XCTAssertEqual(checked, 69_904 + 100, "every planned cross-kind sequence was checked")
    }

    // MARK: - Bounded logical model

    /// One action of the bounded model. `janitor` is a physical step only: it never changes a logical answer.
    private enum LedgerAction: CustomStringConvertible {
        case setCurrent(Int)
        case capture(Int, Int)
        case advance(Int)
        case janitor

        var description: String {
            switch self {
            case .setCurrent(let revision): "setCurrent(\(revision))"
            case .capture(let revision, let rows): "capture(\(revision), rows \(rows))"
            case .advance(let seconds): "advance(\(seconds)s)"
            case .janitor: "janitor"
            }
        }
    }

    /// The alphabet: three revisions, one or two rows, two advances that straddle the age, and the janitor. It has 12 actions.
    private static let alphabet: [LedgerAction] = {
        var actions: [LedgerAction] = [.setCurrent(1), .setCurrent(2), .setCurrent(3)]
        for revision in 1...3 {
            for rows in 1...2 {
                actions.append(.capture(revision, rows))
            }
        }
        actions += [.advance(30), .advance(60), .janitor]
        return actions
    }()

    /// A second implementation of the logical rules, written from the same design, for one kind only. It does not share the production
    /// representation: it keeps one flat list in capture order, recomputes every byte total by a reduction at each use, and has no per-kind
    /// table, no running counter and no janitor rotation. `held` is a row set that a capture has not released. Expiry is computed at each
    /// read from the model's clock, so it never depends on a janitor step.
    private struct LedgerModel {
        struct Entry {
            let revision: Int
            let capturedAt: Int
            var held: Int?
            let bytes: Int
        }

        let rowBytes: Int
        let captureCap: Int
        let retainedCap: Int
        let rowSets: Int
        let proofs: Int
        let age: Int
        var clock = 0
        var entries: [Entry] = []

        func expired(_ entry: Entry) -> Bool {
            clock - entry.capturedAt >= age
        }

        var heldBytes: Int {
            entries.reduce(0) { $0 + ($1.held == nil ? 0 : $1.bytes) }
        }

        var liveBytes: Int {
            entries.reduce(0) { $0 + (($1.held == nil || expired($1)) ? 0 : $1.bytes) }
        }

        mutating func capture(_ revision: Int, _ rows: Int) -> Bool {
            let bytes = rows * rowBytes
            guard bytes <= captureCap else { return false }
            entries.removeAll { $0.revision == revision }
            for index in entries.indices where entries[index].held != nil && expired(entries[index]) {
                entries[index].held = nil
            }
            while entries.filter({ $0.held != nil }).count >= rowSets {
                guard let index = entries.firstIndex(where: { $0.held != nil }) else { break }
                entries[index].held = nil
            }
            while bytes > retainedCap - heldBytes {
                guard let index = entries.firstIndex(where: { $0.held != nil }) else { return false }
                entries[index].held = nil
            }
            entries.append(Entry(revision: revision, capturedAt: clock, held: rows, bytes: bytes))
            while entries.count > proofs {
                entries.removeFirst()
            }
            return true
        }

        func decision(_ cursor: Int?, current: Int) -> String {
            if cursor == nil || cursor == current {
                guard let entry = entries.last(where: { $0.revision == current }), let rows = entry.held, !expired(entry) else {
                    return "needsCapture"
                }
                return "current:\(rows)"
            }
            guard let target = cursor, let entry = entries.last(where: { $0.revision == target }) else { return "notCaptured" }
            guard let rows = entry.held, !expired(entry) else { return "expired" }
            return "stale:\(target):\(rows)"
        }
    }

    @RuntimeActor private func describe(_ decision: RuntimePageDecision) -> String {
        switch decision {
        case .current(let rows, _): "current:\(rows.rowCount)"
        case .stale(let revision, let rows): "stale:\(revision.rawValue):\(rows.rowCount)"
        case .needsCapture: "needsCapture"
        case .expired: "expired"
        case .notCaptured: "notCaptured"
        }
    }

    /// Replays one sequence against the production ledger and the model, and it compares after every action. It returns the first
    /// disagreement, or nil. A drain at the end runs enough janitor turns to visit every slot, then the physical total must equal the
    /// live total.
    @RuntimeActor private func replay(_ sequence: [LedgerAction], limits: RuntimeServiceLimits, rowBytes: Int) throws -> String? {
        var ledger = RuntimeCollectionLedger(limits: limits)
        var model = LedgerModel(
            rowBytes: rowBytes,
            captureCap: limits.collectionByteCapacity,
            retainedCap: limits.collectionRetainedByteCapacity,
            rowSets: limits.collectionRowRevisionsPerKind,
            proofs: limits.collectionProofCapacityPerKind,
            age: 60
        )
        let base = ContinuousClock.now
        let batch = 2
        var current: Int?
        for (step, action) in sequence.enumerated() {
            switch action {
            case .setCurrent(let revision):
                current = revision
            case .capture(let revision, let rows):
                var productionStored = false
                let budget = ControlRowBudget(maxRows: limits.collectionRowCapacity, maxBytes: limits.collectionByteCapacity)
                if case .complete(let measured, let bytes) = budget.measure(
                    Array(repeating: "a", count: rows), { ControlTunnelDNSHostRow(hostname: $0, outcome: .active) }
                ) {
                    productionStored = ledger.capture(
                        kind,
                        revision: rev(revision),
                        total: try ControlCount(rows),
                        rows: .tunnelDNSHosts(measured),
                        encodedBytes: bytes,
                        at: base.advanced(by: .seconds(model.clock))
                    ) == .stored
                }
                let modelResult = model.capture(revision, rows)
                if productionStored != modelResult {
                    return "step \(step) (\(action)): capture stored \(productionStored), model \(modelResult)"
                }
            case .advance(let seconds):
                model.clock += seconds
            case .janitor:
                ledger.sweep(now: base.advanced(by: .seconds(model.clock)), batch: batch)
            }
            if let mismatch = compare(ledger, model, current: current, limits: limits, base: base) {
                return "step \(step) (\(action)): \(mismatch)"
            }
        }
        let slots = ControlCollectionKind.allCases.count * limits.collectionProofCapacityPerKind
        for _ in 0..<((slots + batch - 1) / batch) {
            ledger.sweep(now: base.advanced(by: .seconds(model.clock)), batch: batch)
        }
        if ledger.retainedRowBytes != model.liveBytes {
            return "after the drain, physical \(ledger.retainedRowBytes) differs from the live \(model.liveBytes)"
        }
        return nil
    }

    @RuntimeActor private func compare(
        _ ledger: RuntimeCollectionLedger,
        _ model: LedgerModel,
        current: Int?,
        limits: RuntimeServiceLimits,
        base: ContinuousClock.Instant
    ) -> String? {
        let now = base.advanced(by: .seconds(model.clock))
        if ledger.proofCount(.tunnelDNSHosts) != model.entries.count {
            return "proofs \(ledger.proofCount(.tunnelDNSHosts)), model \(model.entries.count)"
        }
        let physical = ledger.retainedRowBytes
        if physical < model.liveBytes || physical > model.heldBytes || physical > limits.collectionRetainedByteCapacity {
            return "physical \(physical) is outside live \(model.liveBytes) ... held \(model.heldBytes)"
        }
        guard let current else { return nil }
        for cursor in [nil, 1, 2, 3, 9] as [Int?] {
            let produced = describe(ledger.decision(
                kind: .tunnelDNSHosts,
                cursor: cursor.map { rev($0) },
                current: rev(current),
                at: now
            ))
            let expected = model.decision(cursor, current: current)
            if produced != expected {
                return "cursor \(cursor.map { String($0) } ?? "nil"): produced \(produced), model \(expected)"
            }
        }
        return nil
    }

    /// Advances an odometer over the alphabet. It returns false after the last sequence of this length.
    @RuntimeActor private func nextIndices(_ indices: inout [Int], base: Int) -> Bool {
        var position = indices.count - 1
        while position >= 0 {
            indices[position] += 1
            if indices[position] < base { return true }
            indices[position] = 0
            position -= 1
        }
        return false
    }

    /// Every sequence of depth 1 to 4 over the 12-action alphabet is checked exhaustively: 12 + 144 + 1,728 + 20,736 = 22,620. Then
    /// 100 seeded walks of 25 actions are checked. The first failure is reported as the shortest one found, because the depth is
    /// increased one at a time. Any budget shortfall would be a failure, since the loop never stops early.
    @RuntimeActor func testTheLedgerMatchesItsLogicalModelOnEveryBoundedSequenceAndSeededWalk() async throws {
        let rowBytes = try RuntimeWireSize.bytes(of: ControlTunnelDNSHostRow(hostname: "a", outcome: .active))
        let limits = try RuntimeServiceFixtures.limits(
            collectionCaptureBytes: 2 * rowBytes,
            collectionRetainedBytes: 4 * rowBytes - 1,
            collectionProofs: 3,
            collectionRowSets: 2,
            collectionRowAge: .seconds(60)
        )
        let alphabet = Self.alphabet
        var checked = 0
        for depth in 1...4 {
            var indices = Array(repeating: 0, count: depth)
            repeat {
                let sequence = indices.map { alphabet[$0] }
                if let failure = try replay(sequence, limits: limits, rowBytes: rowBytes) {
                    let text = sequence.map { "\($0)" }.joined(separator: ", ")
                    return XCTFail("shortest counterexample at depth \(depth): [\(text)]: \(failure)")
                }
                checked += 1
            } while nextIndices(&indices, base: alphabet.count)
        }
        for seed in 1...100 {
            var random = SplitMix64(state: UInt64(seed))
            let sequence = (0..<25).map { _ in alphabet[Int(random.next() % UInt64(alphabet.count))] }
            if let failure = try replay(sequence, limits: limits, rowBytes: rowBytes) {
                return XCTFail("walk seed \(seed): \(failure)")
            }
            checked += 1
        }
        XCTAssertEqual(checked, 22_620 + 100, "every planned sequence was checked")
    }
}

/// A fixed, seeded generator, so a walk is reproducible from its seed.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension RuntimePageDecision {
    /// Whether the decision asks for a capture, for readable assertions.
    var needsCapture: Bool {
        if case .needsCapture = self { return true }
        return false
    }
}
