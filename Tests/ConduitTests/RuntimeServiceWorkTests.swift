// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
import ProxyKernel

/// Actual work and its quiescence, driven through the production service with a parked fake owner. Logical settlement and
/// physical quiescence are separate reports, and each test states which one it delivers.
final class RuntimeServiceWorkTests: XCTestCase {
    private let lifecycle = ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!

    /// A request that must be accepted. Its operation is returned, and a refusal fails the test.
    @RuntimeActor private func admitted(_ harness: RuntimeServiceHarness, _ id: Int, _ command: ControlRuntimeCommand) throws -> ControlOperationID {
        let admission = harness.core.submit(try RuntimeServiceFixtures.request(id, command))
        guard case .accepted(let operation) = admission else {
            XCTFail("request \(id) must be accepted, got \(admission)")
            throw RuntimeServiceTestError.notAccepted
        }
        return operation
    }

    // MARK: - Stop, restart, stop, with the old work held

    @RuntimeActor func testStopRestartStopKeepsTheOldPhysicalWorkHeldAndNeverLaunchesASupersededStop() async throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.answer = { _, _ in .admitted }

        let stopA = try admitted(harness, 1, .stop(.dns))
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.owner.startedOperations, [stopA], "the first stop launches")

        let restart = try admitted(harness, 2, .restart(.proxy, ifLifecycleRevision: lifecycle))
        let stopB = try admitted(harness, 3, .stop(.dns))
        XCTAssertEqual(harness.owner.fenceLog.last?.candidate, stopA, "the owner fences the new stop against the running candidate")
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, stopA), .finished(.superseded(by: stopB)), "a running candidate settles as superseded")

        let stopC = try admitted(harness, 4, .stop(.dns))
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, stopB), .finished(.superseded(by: stopC)))
        harness.scheduling.drainAll()

        XCTAssertEqual(harness.owner.startedOperations, [stopA, restart], "only the running stop and the restart have launched")
        XCTAssertFalse(harness.owner.startedOperations.contains(stopB), "a superseded queued stop never launches")
        XCTAssertEqual(harness.core.stopSlotState(.dns).active, true, "the old effect still holds the module's active slot")
        XCTAssertEqual(harness.core.stopSlotState(.dns).queued, true, "only the newest stop waits behind it")
        XCTAssertEqual(harness.core.runningOperationCount, 2, "the old stop and the restart are still physically running")

        harness.owner.quiesce(stopA)
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.owner.startedOperations, [stopA, restart, stopC], "the newest stop launches after the old one quiesces")
        XCTAssertEqual(harness.core.stopSlotState(.dns).queued, false)
        XCTAssertEqual(harness.core.stopSlotState(.dns).active, true)
    }

    @RuntimeActor func testAStopFloodNeverRunsMoreThanOneActiveAndOneQueuedPerModule() async throws {
        let harness = try RuntimeServiceHarness(aliases: 8)
        harness.owner.answer = { _, _ in .admitted }

        let first = try admitted(harness, 1, .stop(.dns))
        harness.scheduling.drainAll()
        for id in 2...41 {
            _ = try admitted(harness, id, .stop(.dns))
            XCTAssertLessThanOrEqual(harness.scheduling.pendingCount, 1, "launch hops dedupe to one per module")
        }
        harness.scheduling.drainAll()

        XCTAssertEqual(harness.owner.startedOperations, [first], "only the running stop has started")
        XCTAssertEqual(harness.owner.fenceLog.count, 41, "every fresh stop reached the owner")
        XCTAssertEqual(harness.core.liveOperationCount, 2, "the running stop and the newest queued stop, and nothing else")
        XCTAssertEqual(harness.core.stopSlotState(.dns).queued, true)
    }

    @RuntimeActor func testAnUnstartedSupersededStopNeverStarts() async throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.answer = { _, _ in .admitted }

        _ = try admitted(harness, 1, .stop(.dns))
        let second = try admitted(harness, 2, .stop(.dns))
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.owner.startedOperations, [second], "only the newest of two queued stops launches")
    }

    // MARK: - Capacity is released only by quiescence

    @RuntimeActor func testOrdinaryCapacityIsReleasedOnlyByActualQuiescence() async throws {
        let harness = try RuntimeServiceHarness(ordinaryPending: 1)

        let first = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()
        harness.owner.settle(first, with: .failed(.effectFailed))
        XCTAssertEqual(harness.core.ordinaryUnquiescedCount, 1, "a logical settlement keeps the capacity")
        XCTAssertEqual(
            harness.core.submit(try RuntimeServiceFixtures.request(2, .restart(.dns, ifLifecycleRevision: lifecycle))),
            .rejected(.queueFull),
            "the settled but still running operation still holds the ordinary slot"
        )

        harness.owner.quiesce(first)
        XCTAssertEqual(harness.core.ordinaryUnquiescedCount, 0)
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(3, .restart(.dns, ifLifecycleRevision: lifecycle))) else {
            return XCTFail("the quiesced slot is available again")
        }
    }

    @RuntimeActor func testAStopIsFencedBeforeItsAckEvenWhileOrdinaryCapacityIsFull() async throws {
        let harness = try RuntimeServiceHarness(ordinaryPending: 2)
        harness.owner.answer = { _, _ in .admitted }

        _ = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        _ = try admitted(harness, 2, .restart(.tunnels, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()
        XCTAssertEqual(
            harness.core.submit(try RuntimeServiceFixtures.request(3, .restart(.dns, ifLifecycleRevision: lifecycle))),
            .rejected(.queueFull)
        )

        let fencesBefore = harness.owner.fenceLog.count
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(4, .stop(.dns))) else {
            return XCTFail("a fresh stop is admitted while ordinary work is full")
        }
        XCTAssertEqual(harness.owner.fenceLog.count, fencesBefore + 1, "the stop was fenced before its acknowledgement")
    }

    // MARK: - Reports: idempotent, closed, never resurrecting

    @RuntimeActor func testQuiesceWithoutSettleClosesTheOperationAsAnInternalFailure() async throws {
        let harness = try RuntimeServiceHarness()
        let operation = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()

        harness.owner.quiesce(operation)
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, operation), .finished(.failed(.internalFailure)))
        XCTAssertEqual(harness.core.liveOperationCount, 0)
    }

    @RuntimeActor func testDuplicateReportsAreIdempotentAndALateSettlementNeverResurrects() async throws {
        let harness = try RuntimeServiceHarness()
        let operation = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()

        harness.owner.settle(operation, with: .failed(.effectFailed))
        harness.owner.settle(operation, with: .failed(.internalFailure))
        harness.owner.quiesce(operation)
        harness.owner.quiesce(operation)
        harness.owner.settle(operation, with: .failed(.internalFailure))

        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, operation), .finished(.failed(.effectFailed)), "the first settlement is the one that counts")
        XCTAssertEqual(harness.core.ordinaryUnquiescedCount, 0, "a duplicate quiesce releases nothing twice")
        XCTAssertEqual(harness.core.liveOperationCount, 0)
    }

    @RuntimeActor func testALateSettlementAfterSupersessionChangesNothing() async throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.answer = { _, _ in .admitted }
        let first = try admitted(harness, 1, .stop(.dns))
        harness.scheduling.drainAll()
        let second = try admitted(harness, 2, .stop(.dns))

        harness.owner.settle(first, with: .failed(.effectFailed))
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, first), .finished(.superseded(by: second)))
        XCTAssertEqual(harness.core.stopSlotState(.dns).queued, true, "the newest stop still waits, untouched by the late report")
    }

    // MARK: - Alias floods never pin, and never block a fence

    @RuntimeActor func testAliasFloodNeverBlocksAFreshStopOrAnotherModuleAndNeverPinsTheOperation() async throws {
        let harness = try RuntimeServiceHarness(aliases: 8)
        let restartA = try admitted(harness, 90, .restart(.proxy, ifLifecycleRevision: lifecycle))
        let restartB = try admitted(harness, 91, .restart(.tunnels, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.ordinaryUnquiescedCount, 2, "ordinary work is full")

        let candidate = try admitted(harness, 1, .stop(.dns))
        for id in 2...41 {
            guard case .joined(let joined) = harness.core.submit(try RuntimeServiceFixtures.request(id, .stop(.dns))) else {
                return XCTFail("request \(id) must join the pending candidate")
            }
            XCTAssertEqual(joined, candidate)
        }
        XCTAssertLessThanOrEqual(harness.core.aliasCount, 8 + 2, "distinct joined aliases are bounded")
        XCTAssertEqual(
            try RuntimeServiceFixtures.lookupRequest(harness.core, 2),
            .unknown(.notRecorded),
            "an evicted join alias is not recorded, even though the operation it named is pending"
        )
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, candidate), .pending, "the operation itself is unaffected")

        harness.owner.answer = { _, _ in .admitted }
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(100, .stop(.dns))) else {
            return XCTFail("a fresh dns stop is fenced and admitted after the flood")
        }
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(101, .stop(.proxy))) else {
            return XCTFail("another module's stop is admitted after the flood")
        }
        XCTAssertEqual(
            harness.core.submit(try RuntimeServiceFixtures.request(102, .restart(.dns, ifLifecycleRevision: lifecycle))),
            .rejected(.queueFull),
            "ordinary capacity still refuses an ordinary command, and nothing else"
        )
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, restartA), .pending, "a launched ordinary operation stays pending")
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, restartB), .pending, "a launched ordinary operation stays pending")
    }

    /// The minimal ordinary and per-module alias partitions, with ordinary full and every module already holding a pending
    /// candidate. A fresh stop must still be fenced and admitted: aliases never block admission.
    @RuntimeActor func testMinimalAliasPartitionsStillFenceAFreshStopWithOrdinaryFullAndEveryModulePending() async throws {
        let harness = try RuntimeServiceHarness(aliases: 1, ordinaryPending: 2)
        harness.owner.answer = { _, _ in .admitted }

        _ = try admitted(harness, 90, .restart(.proxy, ifLifecycleRevision: lifecycle))
        _ = try admitted(harness, 91, .restart(.tunnels, ifLifecycleRevision: lifecycle))
        var id = 1
        for module in ControlModule.allCases {
            _ = try admitted(harness, id, .stop(module))
            id += 1
        }
        let fences = harness.owner.fenceLog.count
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(200, .stop(.dns))) else {
            return XCTFail("a fresh stop is admitted at the minimal alias bound")
        }
        XCTAssertEqual(harness.owner.fenceLog.count, fences + 1, "the fresh stop reached the owner")
        XCTAssertLessThanOrEqual(harness.core.aliasBytesTotal, harness.limits.aliasByteCapacityPerPartition * (ControlModule.allCases.count + 1))
    }

    // MARK: - Encoding failures are typed faults, reported through the owner

    /// A command that cannot be encoded is reported as the closed fault at its origin. Nothing is recorded or fenced, and no
    /// command body is part of the report, which is only the fault's case.
    @RuntimeActor func testAnEncodeFailureIsReportedAsATypedFaultWithItsOriginAndNoBody() async throws {
        let harness = try RuntimeServiceHarness(encodeCommand: { _ in throw RuntimeServiceTestError.refusedEncoding })
        let admission = harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.dns)))
        XCTAssertEqual(admission, .rejected(.internalFailure), "the refusal is a typed admission, never an accepted or unknown one")
        XCTAssertEqual(harness.owner.faults, [.submitCommandNotEncodable], "the origin is reported as its closed case")
        XCTAssertTrue(harness.owner.fenceLog.isEmpty, "nothing reached the owner's fence")
        XCTAssertEqual(harness.core.aliasCount, 0, "nothing was recorded")
    }

    /// An outcome that cannot be measured is staged as its closed fault, and the owner is called only after the settlement is
    /// complete. The fault callback reads the service from inside the call, and it sees the replacement outcome already retained,
    /// the operation settled and nothing pending. The measure is a fault-injection seam: the current codec encodes every outcome,
    /// so the production path cannot reach this fault without it.
    @RuntimeActor func testAnOutcomeEncodeFaultReachesTheOwnerOnlyAfterTheSettlementIsComplete() async throws {
        let harness = try RuntimeServiceHarness(measureOutcome: { _, _ in throw RuntimeServiceTestError.refusedEncoding })
        harness.owner.answer = { _, _ in .admitted }
        let operation = try admitted(harness, 1, .stop(.dns))
        harness.scheduling.drainAll()
        let core = harness.core
        let owner = harness.owner
        var lookupInCallback: ControlOperationLookup?
        var pendingInCallback: Int?
        var faultsInCallback: [ControlServiceFault] = []
        owner.onFault = { [weak core, weak owner] _ in
            guard let core, let owner else { return }
            lookupInCallback = RuntimeServiceFixtures.lookup(core, operation)
            pendingInCallback = core.pendingOperationCount
            faultsInCallback = owner.faults
        }

        owner.settle(operation, with: .failed(.effectFailed))

        XCTAssertEqual(lookupInCallback, .finished(.failed(.internalFailure)), "the callback sees the replacement outcome already retained")
        XCTAssertEqual(pendingInCallback, 0, "the settlement was complete when the owner was called")
        XCTAssertEqual(faultsInCallback, [.outcomeNotEncodable], "the fault is recorded before the callback runs")
        XCTAssertEqual(owner.faults, [.outcomeNotEncodable], "the owner is called once, with the closed case")
        XCTAssertEqual(RuntimeServiceFixtures.lookup(core, operation), .finished(.failed(.internalFailure)))
    }

    /// A superseded candidate whose outcome cannot be measured reports its fault only after the replacement is installed. The
    /// fault callback sees the replacement pending in its stop slot, and the dropped queued candidate already gone. Before the
    /// fix the owner was called inside the settlement, before the replacement existed.
    @RuntimeActor func testASupersessionFaultReachesTheOwnerOnlyAfterTheReplacementIsInstalled() async throws {
        let harness = try RuntimeServiceHarness(measureOutcome: { outcome, operation in
            if case .superseded = outcome { throw RuntimeServiceTestError.refusedEncoding }
            return try RuntimeServiceCore.measureRetained(outcome, operation)
        })
        harness.owner.answer = { _, _ in .admitted }
        let first = try admitted(harness, 1, .stop(.dns))
        let core = harness.core
        var pendingInCallback: Int?
        var queuedInCallback: Bool?
        var liveInCallback: Int?
        harness.owner.onFault = { [weak core] _ in
            guard let core else { return }
            pendingInCallback = core.pendingOperationCount
            queuedInCallback = core.stopSlotState(.dns).queued
            liveInCallback = core.liveOperationCount
        }

        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(2, .stop(.dns))) else {
            return XCTFail("the replacement stop must be accepted")
        }

        XCTAssertEqual(pendingInCallback, 1, "the callback sees only the replacement pending")
        XCTAssertEqual(queuedInCallback, true, "the callback sees the replacement in the stop slot")
        XCTAssertEqual(liveInCallback, 1, "the callback sees only the replacement live, because the dropped candidate has left the table")
        XCTAssertEqual(harness.owner.faults, [.outcomeNotEncodable])
        XCTAssertEqual(RuntimeServiceFixtures.lookup(core, first), .finished(.failed(.internalFailure)))
    }

    /// An unsettled operation that quiesces reports its closing fault only after its physical capacity is returned. The fault
    /// callback sees no live record, no pending operation and a free ordinary slot.
    @RuntimeActor func testAQuiescenceFaultReachesTheOwnerOnlyAfterTheCapacityIsReturned() async throws {
        let harness = try RuntimeServiceHarness(measureOutcome: { outcome, operation in
            if case .failed(.internalFailure) = outcome { throw RuntimeServiceTestError.refusedEncoding }
            return try RuntimeServiceCore.measureRetained(outcome, operation)
        })
        let lifecycle = ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!
        let operation = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()
        let core = harness.core
        var liveInCallback: Int?
        var ordinaryInCallback: Int?
        var pendingInCallback: Int?
        harness.owner.onFault = { [weak core] _ in
            guard let core else { return }
            liveInCallback = core.liveOperationCount
            ordinaryInCallback = core.ordinaryUnquiescedCount
            pendingInCallback = core.pendingOperationCount
        }

        harness.owner.quiesce(operation)

        XCTAssertEqual(liveInCallback, 0, "the callback sees the operation's record already removed")
        XCTAssertEqual(ordinaryInCallback, 0, "the callback sees its capacity already returned")
        XCTAssertEqual(pendingInCallback, 0, "the callback sees the operation settled")
        XCTAssertEqual(harness.owner.faults, [.outcomeNotEncodable])
        XCTAssertEqual(RuntimeServiceFixtures.lookup(core, operation), .finished(.failed(.internalFailure)))
    }

    /// A reply cap that cannot carry one maximal event in one frame is refused at construction, so every event stays deliverable.
    @RuntimeActor func testAReplyCapThatCannotCarryOneMaximalEventIsRefusedAtConstruction() async throws {
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(replyBytes: 1024))
        XCTAssertNoThrow(try RuntimeServiceFixtures.limits(replyBytes: 64 * 1024))
    }

    // MARK: - Finite history: an evicted accepted alias is not exactly-once

    /// Admission history is best-effort. A flood of rejected requests evicts an accepted request's alias, so its lookup is not
    /// recorded while its operation stays pending. A retry under that ID is a fresh request, and the owner fences it again. This
    /// is the selected contract: no exactly-once promise survives eviction, and no retry is replayed blindly.
    @RuntimeActor func testAnEvictedAcceptedAliasAnswersNotRecordedAndAFreshRetryIsFencedAgain() async throws {
        let harness = try RuntimeServiceHarness(aliases: 2)
        let first = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        harness.owner.answer = { _, _ in .rejected(.hostStopping) }
        for id in 2...3 {
            XCTAssertEqual(
                harness.core.submit(try RuntimeServiceFixtures.request(id, .restart(.dns, ifLifecycleRevision: lifecycle))),
                .rejected(.hostStopping)
            )
        }
        XCTAssertEqual(try RuntimeServiceFixtures.lookupRequest(harness.core, 1), .unknown(.notRecorded), "the rejected flood evicted the accepted alias")
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, first), .pending, "the evicted alias leaves its operation unaffected")

        harness.owner.answer = { _, _ in .admitted }
        let retry = harness.core.submit(try RuntimeServiceFixtures.request(1, .restart(.proxy, ifLifecycleRevision: lifecycle)))
        guard case .accepted(let second) = retry else { return XCTFail("a retry under the evicted ID is a fresh request, got \(retry)") }
        XCTAssertNotEqual(second, first, "the retry is a second operation, because no exactly-once promise survives eviction")
        XCTAssertEqual(harness.owner.fenceLog.count, 4, "the owner fenced the retry")
    }

    // MARK: - Counter exhaustion is safe

    @RuntimeActor func testObservationPositionStopsAtTheLimitWithoutWrapping() async throws {
        let limits = try RuntimeServiceFixtures.limits()
        var log = RuntimeObservationLog(limits: limits, positionSeed: RuntimeObservationLog.maximumPosition - 1)
        let record = ControlRuntimeEventRecord.known(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event"))
        let bytes = try XCTUnwrap(RuntimeServiceCore.encodedSize(record))

        log.apply([.event(record, bytes: bytes)])
        XCTAssertEqual(log.highWater, RuntimeObservationLog.maximumPosition, "the last issuable position is issued")
        XCTAssertFalse(log.exhausted)

        log.apply([.event(record, bytes: bytes)])
        XCTAssertEqual(log.highWater, RuntimeObservationLog.maximumPosition, "a position past the limit is never issued")
        XCTAssertTrue(log.exhausted, "the log is marked exhausted instead of wrapping")

        let end = try log.peek(RuntimeSubscriberCursor(
            nextEvent: 1,
            replayThrough: nil,
            nextControl: log.controlNext,
            seenSnapshotGeneration: 0,
            lastWasSnapshot: false
        )) { _ in true }
        XCTAssertEqual(end.pull, .end(.resyncRequired), "an exhausted log resyncs every reader")
    }

    @RuntimeActor func testMaximumPositionLeavesEveryNextPositionRepresentable() async {
        XCTAssertEqual(RuntimeObservationLog.maximumPosition, Int.max - 1)
        XCTAssertNotNil(RuntimeCounter.successor(RuntimeObservationLog.maximumPosition))
        XCTAssertNil(RuntimeCounter.successor(Int.max))
        XCTAssertNil(RuntimeCounter.advanced(Int.max, by: 1))
    }

    // MARK: - Limits: the byte bounds must hold one worst record

    @RuntimeActor func testAnAliasBoundThatCannotHoldOneWorstRecordIsRefused() async throws {
        XCTAssertThrowsError(try RuntimeServiceLimits(
            maxRequestBytes: 4096,
            maxReplyBytes: 4096,
            aliasCapacityPerPartition: 1,
            aliasByteCapacityPerPartition: 16,
            ordinaryPendingCapacity: 1,
            outcomeCapacity: 1,
            outcomeByteCapacity: 1,
            retentionAge: .seconds(1),
            janitorBatch: 1,
            ordinaryLaneCapacity: 1,
            readLaneCapacity: 1,
            streamLaneCapacity: 1,
            stopLaneCapacityPerModule: 1,
            subscriberLimit: 1,
            ringCapacity: 1,
            ringByteCapacity: 4096,
            maxEventBytes: 4096,
            ingressCapacity: 1,
            ingressByteCapacity: 4096,
            drainItemsPerTurn: 1,
            drainBytesPerTurn: 4096,
            controlLogCapacity: 1,
            controlLogByteCapacity: 1,
            replayChunkItems: 1,
            replayChunkBytes: 4096,
            collectionRowCapacity: 1,
            collectionByteCapacity: 1,
            collectionProofCapacityPerKind: 1,
            collectionRowRevisionsPerKind: 1,
            collectionRetainedByteCapacity: 1,
            collectionRowRetentionAge: .seconds(1),
            latestSnapshotByteCapacity: 1,
            subscriberRecordBytes: 1,
            retainedByteCeiling: 1 << 20
        ))
    }

    /// The budget is the exact sum of every term it names, computed here independently from the limit values.
    @RuntimeActor func testTheRetainedByteBudgetIsTheExactSumOfEveryTerm() async throws {
        let limits = try RuntimeServiceFixtures.limits()
        let modules = ControlModule.allCases.count
        // Ordinary, the quit's, and one per stop module.
        let partitions = 2 + modules
        let collectionKinds = ControlCollectionKind.allCases.count
        // Two slots per stop module, and the quit with its configuration and preferences final saves.
        let operations = limits.ordinaryPendingCapacity + 2 * modules + 3
        // The quit's own lane holds one ordinary-frame reservation.
        let laneCount = limits.ordinaryLaneCapacity + limits.readLaneCapacity + limits.streamLaneCapacity + limits.stopLaneCapacityPerModule * modules + 1
        XCTAssertEqual(limits.operationCapacity, operations)
        XCTAssertEqual(limits.laneCount, laneCount)
        XCTAssertEqual(limits.laneRetainedBytes, laneCount * (2 * limits.maxRequestBytes + 2 * limits.maxReplyBytes))
        XCTAssertEqual(limits.firstFrameRetainedBytes, limits.subscriberLimit * limits.maxReplyBytes)
        let expected = partitions * limits.aliasByteCapacityPerPartition
            + operations * (limits.operationRecordBytes + limits.maxRequestBytes)
            + limits.outcomeByteCapacity + limits.ringByteCapacity + limits.controlLogByteCapacity + limits.ingressByteCapacity
            + limits.collectionRetainedByteCapacity + collectionKinds * limits.collectionProofCapacityPerKind * limits.collectionProofBytes
            + limits.collectionByteCapacity
            + limits.laneRetainedBytes + limits.firstFrameRetainedBytes
            + 2 * limits.latestSnapshotByteCapacity + limits.subscriberLimit * limits.subscriberRecordBytes
        XCTAssertEqual(limits.retainedByteBudget, expected)
        XCTAssertLessThanOrEqual(limits.retainedByteBudget, limits.retainedByteCeiling)
    }

    /// The structural terms come from the structures that hold them: every alias partition the table keeps, the quit's partition with
    /// its reserved final saves, and the private custody's terms at the private frame caps, which stay outside the ordinary budget.
    @RuntimeActor func testTheStructuralTermsComeFromTheTableTheQuitAndThePrivateCustody() async throws {
        let limits = try RuntimeServiceFixtures.limits()
        XCTAssertEqual(RuntimePartition.all.count, ControlModule.allCases.count + 2)
        XCTAssertTrue(RuntimePartition.all.contains(.quit))
        XCTAssertEqual(RuntimeServiceLimits.quitPartitionOperations, 1 + RuntimeQuitFlush.Part.allCases.count)
        XCTAssertEqual(
            limits.privateTransferRetainedBytes,
            PrivateConfigurationFrame.maxRequestFrameBytes + PrivateConfigurationFrame.maxEditorReplyFrameBytes
        )
        XCTAssertEqual(limits.privateInputRetainedBytes, PrivateConfigurationFrame.maxRequestFrameBytes)
        let counter = RuntimeLaneCounter(limits: limits)
        let quit = try XCTUnwrap(counter.reserve(.quit, onQuiesced: nil))
        XCTAssertNil(counter.reserve(.quit, onQuiesced: nil), "the quit lane holds one reservation")
        let transfer = try XCTUnwrap(counter.reserve(.privateTransfer, onQuiesced: nil))
        XCTAssertNil(counter.reserve(.privateTransfer, onQuiesced: nil), "the private transfer holds one reservation")
        quit.end(.timer)
        transfer.end(.timer)
    }

    /// Doubling the reply cap moves the budget by exactly the reservation and first-frame terms that scale with it.
    @RuntimeActor func testDoublingTheReplyCapChangesTheBudgetByItsReservationAndFirstFrameTermsOnly() async throws {
        let small = try RuntimeServiceFixtures.limits(replyBytes: 64 * 1024)
        let large = try RuntimeServiceFixtures.limits(replyBytes: 128 * 1024)
        XCTAssertEqual(large.retainedByteBudget - small.retainedByteBudget, (2 * small.laneCount + small.subscriberLimit) * 64 * 1024)
    }

    /// Doubling the request cap moves the budget by the two request-sized lane terms and the operation records, and by nothing else.
    @RuntimeActor func testDoublingTheRequestCapChangesTheBudgetByItsCustodyTermsOnly() async throws {
        let small = try RuntimeServiceFixtures.limits(requestBytes: 4096)
        let large = try RuntimeServiceFixtures.limits(requestBytes: 8192)
        XCTAssertEqual(large.retainedByteBudget - small.retainedByteBudget, (2 * small.laneCount + small.operationCapacity) * 4096)
    }

    /// A configuration whose budget exceeds the owner's ceiling is refused when it is built.
    @RuntimeActor func testABudgetAboveTheOwnersCeilingIsRefusedAtConstruction() async throws {
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(retainedByteCeiling: 1 << 16))
    }

    /// The owner's ceiling is inclusive: the exact budget is accepted, and one byte less is refused at construction.
    @RuntimeActor func testTheCeilingAcceptsExactlyTheBudgetAndRefusesOneByteLess() async throws {
        let budget = try RuntimeServiceFixtures.limits().retainedByteBudget
        XCTAssertNoThrow(try RuntimeServiceFixtures.limits(retainedByteCeiling: budget))
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(retainedByteCeiling: budget - 1))
    }

    /// The codec's boundary for one maximal event at its maximal cursor is raw: a frame at its exact size encodes at that cap, and it
    /// fails one byte below. This is a codec fact, so it is checked without any service profile.
    @RuntimeActor func testAMaximalEventFrameHasAnExactRawCodecBoundary() async throws {
        let probe = try RuntimeServiceFixtures.limits()
        let (message, exact) = try maximalEventFrame(probe)
        XCTAssertNoThrow(try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: exact)))
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: exact - 1)))
    }

    /// The service's reply cap is the larger of two terms: one maximal event at its exact size, and one baseline that carries the
    /// largest snapshot bound. The snapshot bound is the largest one the event term allows, so both terms meet at one cap, and each side
    /// of it is decided by construction. The boundary is measured, so no term is guessed.
    @RuntimeActor func testTheServiceReplyCapIsTheExactBoundOfItsLargerTerm() async throws {
        let probe = try RuntimeServiceFixtures.limits()
        let (_, exact) = try maximalEventFrame(probe)
        let snapshotBound = exact - probe.baselineFrameOverheadBytes
        XCTAssertGreaterThan(snapshotBound, 0, "the event cap leaves room for a snapshot")
        XCTAssertNoThrow(try RuntimeServiceFixtures.limits(replyBytes: exact, snapshotBytes: snapshotBound), "both terms meet at the exact cap")
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(replyBytes: exact - 1, snapshotBytes: snapshotBound), "the event term refuses one byte less")
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(replyBytes: exact, snapshotBytes: snapshotBound + 1), "the baseline term refuses one byte more")
    }

    /// A maximal event frame at the largest cursor, and its exact encoded size.
    @RuntimeActor private func maximalEventFrame(_ probe: RuntimeServiceLimits) throws -> (ControlRuntimeMessage, Int) {
        let record = try maximalEventRecord(bytes: probe.maxEventBytes)
        let cursor = try XCTUnwrap(ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition))
        let message = ControlRuntimeMessage(
            correlation: RuntimeServiceFixtures.requestID(1),
            body: .frame(.events(try ControlEventBatch(firstCursor: cursor, events: [record])))
        )
        let exact = try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: 1 << 20)).count
        XCTAssertEqual(try RuntimeWireSize.bytes(of: record), probe.maxEventBytes, "the event is maximal")
        return (message, exact)
    }

    /// A record whose encoded size is exactly `bytes`. Only the event name varies, and it is plain ASCII, so its JSON size grows by
    /// one byte per character.
    @RuntimeActor private func maximalEventRecord(bytes: Int) throws -> ControlRuntimeEventRecord {
        func record(_ nameLength: Int) -> ControlRuntimeEventRecord {
            .known(ControlRuntimeEvent(
                timestamp: Date(timeIntervalSince1970: 0),
                kind: "proxy",
                event: String(repeating: "e", count: nameLength)
            ))
        }
        let empty = try RuntimeWireSize.bytes(of: record(0))
        return record(bytes - empty)
    }
}

/// A test-only failure for a request the suite needed admitted.
enum RuntimeServiceTestError: Error {
    case notAccepted
    /// The encoder refusal a test injects to exercise the typed encoding fault.
    case refusedEncoding
}
