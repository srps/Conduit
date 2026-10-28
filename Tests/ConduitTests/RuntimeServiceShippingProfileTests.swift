// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import ConduitRuntime
import ConduitShared
import ProxyControlBridge

/// The one shipping profile (`RuntimeServiceProfile.inProcessApp`) against the codec and the actual initializer: every stated byte term is
/// re-derived from the measured worst record it holds, the retained-byte ceiling is exactly the initializer's own budget, and every call
/// and settlement frames within the selected caps. A term that grows fails here rather than widening the profile silently.
@MainActor
final class RuntimeServiceShippingProfileTests: XCTestCase {
    private typealias Profile = RuntimeServiceProfile

    func testTheProfileConstructsAtExactlyItsMeasuredBudgetAndRefusesOneByteLess() throws {
        let limits = try Profile.inProcessApp().limits
        print("RUNTIME-SHIPPING-PROFILE retainedByteBudget=\(limits.retainedByteBudget) ceiling=\(limits.retainedByteCeiling)")
        XCTAssertEqual(limits.retainedByteBudget, 17_082_600, "the measured candidate's budget")
        XCTAssertEqual(limits.retainedByteBudget, limits.retainedByteCeiling, "no headroom hides a grown term")
        XCTAssertThrowsError(try RuntimeServiceLimits(
            maxRequestBytes: Profile.maxRequestBytes, maxReplyBytes: Profile.maxReplyBytes,
            aliasCapacityPerPartition: Profile.aliasCapacityPerPartition, aliasByteCapacityPerPartition: Profile.aliasBytesPerPartition,
            ordinaryPendingCapacity: Profile.ordinaryPendingCapacity, outcomeCapacity: Profile.outcomeCapacity,
            outcomeByteCapacity: Profile.outcomeBytes, retentionAge: .seconds(Profile.retentionSeconds), janitorBatch: 16,
            ordinaryLaneCapacity: Profile.laneCapacity, readLaneCapacity: Profile.laneCapacity, streamLaneCapacity: Profile.laneCapacity,
            stopLaneCapacityPerModule: Profile.stopLaneCapacityPerModule, subscriberLimit: Profile.subscriberLimit,
            ringCapacity: Profile.ringCapacity, ringByteCapacity: Profile.ringBytes, maxEventBytes: Profile.maxEventBytes,
            ingressCapacity: Profile.ringCapacity, ingressByteCapacity: Profile.ringBytes, drainItemsPerTurn: Profile.drainItems,
            drainBytesPerTurn: Profile.drainBytes, controlLogCapacity: Profile.controlLogCapacity,
            controlLogByteCapacity: Profile.controlLogBytes, replayChunkItems: Profile.replayItems, replayChunkBytes: Profile.replayBytes,
            collectionRowCapacity: Profile.collectionRows, collectionByteCapacity: Profile.collectionCaptureBytes,
            collectionProofCapacityPerKind: Profile.collectionProofsPerKind,
            collectionRowRevisionsPerKind: Profile.collectionRowRevisionsPerKind,
            collectionRetainedByteCapacity: Profile.collectionRetainedBytes,
            collectionRowRetentionAge: .seconds(Profile.collectionRowRetentionSeconds),
            latestSnapshotByteCapacity: Profile.latestSnapshotBytes, subscriberRecordBytes: Profile.subscriberRecordBytes,
            retainedByteCeiling: Profile.retainedByteCeiling - 1
        ))
    }

    /// The selected caps and the measured shape, as the owner selected and the probe measured them.
    func testTheSelectedCapsAndCapacitiesAreTheProfiles() throws {
        let profile = try Profile.inProcessApp()
        let limits = profile.limits
        XCTAssertEqual(limits.maxRequestBytes, 4_096)
        XCTAssertEqual(limits.maxReplyBytes, 65_536)
        XCTAssertEqual(profile.clientFrameLimits.maxFrameBytes, 65_536)
        XCTAssertEqual(limits.collectionRowCapacity, 10_000)
        XCTAssertEqual(limits.collectionByteCapacity, 4_194_304)
        XCTAssertEqual(limits.collectionRetainedByteCapacity, 8_388_608)
        XCTAssertEqual(profile.collectionRowBudget, ControlRowBudget(maxRows: 10_000, maxBytes: 4_194_304))
        XCTAssertEqual(limits.subscriberLimit, 4)
        XCTAssertEqual(limits.ordinaryPendingCapacity, 8)
        XCTAssertEqual([limits.ordinaryLaneCapacity, limits.readLaneCapacity, limits.streamLaneCapacity, limits.stopLaneCapacityPerModule], [4, 4, 4, 1])
        XCTAssertEqual(limits.retentionAge, .seconds(300))
        XCTAssertEqual(limits.collectionRowRetentionAge, .seconds(60))
        XCTAssertEqual(AppTiming.quitTotal, .seconds(10), "the owner's total Quit budget is the app's, not a request timeout")
        XCTAssertLessThan(AppTiming.quitTotal, profile.wireBudgetCap, "the Quit's total fits under the wire cap")
    }

    /// Each retained byte term holds its full count of the widest record the codec writes today.
    func testEveryRetainedTermHoldsItsCountOfTheWidestRecord() throws {
        let limits = try Profile.inProcessApp().limits
        XCTAssertGreaterThanOrEqual(limits.aliasByteCapacityPerPartition, limits.aliasCapacityPerPartition * limits.aliasRecordWorstBytes)
        let operation = ControlOperationID(rawValue: RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFF))
        var widestOutcome = 0
        var widestFinished = 0
        for (label, outcome) in try RuntimeServiceProfileEvidenceTests.widestOutcomes() {
            let sizes = try RuntimeServiceCore.measureRetained(outcome, operation)
            widestOutcome = max(widestOutcome, sizes.outcome)
            widestFinished = max(widestFinished, sizes.finished)
            XCTAssertLessThanOrEqual(sizes.finished + 200, limits.maxReplyBytes, label)
        }
        print("RUNTIME-SHIPPING-PROFILE aliasRecord=\(limits.aliasRecordWorstBytes) widestOutcome=\(widestOutcome) widestFinished=\(widestFinished)")
        XCTAssertGreaterThanOrEqual(limits.outcomeByteCapacity, limits.outcomeCapacity * widestOutcome)
        XCTAssertGreaterThanOrEqual(limits.controlLogByteCapacity, limits.controlLogCapacity * widestFinished)
    }

    /// The latest snapshot bound is the largest a baseline frame carries within the reply cap.
    func testTheLatestSnapshotIsTheLargestABaselineFrameCarries() throws {
        let limits = try Profile.inProcessApp().limits
        XCTAssertEqual(limits.latestSnapshotByteCapacity + limits.baselineFrameOverheadBytes, limits.maxReplyBytes)
    }

    /// Every current call frames within the shipping request cap at its widest legal form.
    func testEveryCallFramesWithinTheShippingRequestCap() throws {
        let limits = try Profile.inProcessApp().limits
        let cap = try ControlFrameLimits(maxFrameBytes: limits.maxRequestBytes)
        let requestID = ControlRequestID(rawValue: RuntimeServiceFixtures.uuid(0xFFFF_FFFF_FFFF))
        for (label, call) in try RuntimeServiceProfileEvidenceTests.widestCalls() {
            let message = ControlRuntimeMessage(
                correlation: requestID, body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(Int(Int32.max)), call: call))
            )
            XCTAssertLessThanOrEqual(try ControlRuntimeCodec.encodeFrame(message, limits: cap).count, limits.maxRequestBytes, label)
        }
    }
}
