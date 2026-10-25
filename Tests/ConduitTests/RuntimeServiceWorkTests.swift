// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// Actual work and its quiescence, driven through the production service with a parked fake owner. Logical settlement and
/// physical quiescence are separate reports, and each test states which one it delivers.
@MainActor
final class RuntimeServiceWorkTests: XCTestCase {
    private let lifecycle = ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!

    /// A request that must be accepted. Its operation is returned, and a refusal fails the test.
    private func admitted(_ harness: RuntimeServiceHarness, _ id: Int, _ command: ControlRuntimeCommand) throws -> ControlOperationID {
        let admission = harness.core.submit(try RuntimeServiceFixtures.request(id, command))
        guard case .accepted(let operation) = admission else {
            XCTFail("request \(id) must be accepted, got \(admission)")
            throw RuntimeServiceTestError.notAccepted
        }
        return operation
    }

    // MARK: - Stop, restart, stop, with the old work held

    func testStopRestartStopKeepsTheOldPhysicalWorkHeldAndNeverLaunchesASupersededStop() throws {
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

    func testAStopFloodNeverRunsMoreThanOneActiveAndOneQueuedPerModule() throws {
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

    func testAnUnstartedSupersededStopNeverStarts() throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.answer = { _, _ in .admitted }

        _ = try admitted(harness, 1, .stop(.dns))
        let second = try admitted(harness, 2, .stop(.dns))
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.owner.startedOperations, [second], "only the newest of two queued stops launches")
    }

    // MARK: - Capacity is released only by quiescence

    func testOrdinaryCapacityIsReleasedOnlyByActualQuiescence() throws {
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

    func testAStopIsFencedBeforeItsAckEvenWhileOrdinaryCapacityIsFull() throws {
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

    func testQuiesceWithoutSettleClosesTheOperationAsAnInternalFailure() throws {
        let harness = try RuntimeServiceHarness()
        let operation = try admitted(harness, 1, .restart(.proxy, ifLifecycleRevision: lifecycle))
        harness.scheduling.drainAll()

        harness.owner.quiesce(operation)
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, operation), .finished(.failed(.internalFailure)))
        XCTAssertEqual(harness.core.liveOperationCount, 0)
    }

    func testDuplicateReportsAreIdempotentAndALateSettlementNeverResurrects() throws {
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

    func testALateSettlementAfterSupersessionChangesNothing() throws {
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

    func testAliasFloodNeverBlocksAFreshStopOrAnotherModuleAndNeverPinsTheOperation() throws {
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
    func testMinimalAliasPartitionsStillFenceAFreshStopWithOrdinaryFullAndEveryModulePending() throws {
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
    func testAnEncodeFailureIsReportedAsATypedFaultWithItsOriginAndNoBody() throws {
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
    func testAnOutcomeEncodeFaultReachesTheOwnerOnlyAfterTheSettlementIsComplete() throws {
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

    /// A reply cap that cannot carry one maximal event in one frame is refused at construction, so every event stays deliverable.
    func testAReplyCapThatCannotCarryOneMaximalEventIsRefusedAtConstruction() throws {
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(replyBytes: 1024))
        XCTAssertNoThrow(try RuntimeServiceFixtures.limits(replyBytes: 64 * 1024))
    }

    // MARK: - Finite history: an evicted accepted alias is not exactly-once

    /// Admission history is best-effort. A flood of rejected requests evicts an accepted request's alias, so its lookup is not
    /// recorded while its operation stays pending. A retry under that ID is a fresh request, and the owner fences it again. This
    /// is the selected contract: no exactly-once promise survives eviction, and no retry is replayed blindly.
    func testAnEvictedAcceptedAliasAnswersNotRecordedAndAFreshRetryIsFencedAgain() throws {
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

    func testObservationPositionStopsAtTheLimitWithoutWrapping() throws {
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

        let end = try log.peek(RuntimeSubscriberCursor(nextEvent: 1, replayThrough: nil, nextControl: log.controlNext)) { _ in true }
        XCTAssertEqual(end.pull, .end(.resyncRequired), "an exhausted log resyncs every reader")
    }

    func testMaximumPositionLeavesEveryNextPositionRepresentable() {
        XCTAssertEqual(RuntimeObservationLog.maximumPosition, Int.max - 1)
        XCTAssertNotNil(RuntimeCounter.successor(RuntimeObservationLog.maximumPosition))
        XCTAssertNil(RuntimeCounter.successor(Int.max))
        XCTAssertNil(RuntimeCounter.advanced(Int.max, by: 1))
    }

    // MARK: - Limits: the byte bounds must hold one worst record

    func testAnAliasBoundThatCannotHoldOneWorstRecordIsRefused() throws {
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
            retainedByteCeiling: 1 << 20
        ))
    }

    /// The budget is the exact sum of every term it names, computed here independently from the limit values.
    func testTheRetainedByteBudgetIsTheExactSumOfEveryTerm() throws {
        let limits = try RuntimeServiceFixtures.limits()
        let modules = ControlModule.allCases.count
        let partitions = modules + 1
        let collectionKinds = ControlCollectionKind.allCases.count
        let operations = limits.ordinaryPendingCapacity + RuntimeServiceLimits.stopSlotsPerModule * modules
        let laneCount = limits.ordinaryLaneCapacity + limits.readLaneCapacity + limits.stopLaneCapacityPerModule * modules
        XCTAssertEqual(limits.laneCount, laneCount)
        XCTAssertEqual(limits.laneRetainedBytes, laneCount * (2 * limits.maxRequestBytes + 2 * limits.maxReplyBytes))
        XCTAssertEqual(limits.firstFrameRetainedBytes, limits.subscriberLimit * limits.maxReplyBytes)
        let expected = partitions * limits.aliasByteCapacityPerPartition
            + operations * (limits.operationRecordBytes + limits.maxRequestBytes)
            + limits.outcomeByteCapacity + limits.ringByteCapacity + limits.controlLogByteCapacity + limits.ingressByteCapacity
            + collectionKinds * limits.collectionByteCapacity
            + limits.laneRetainedBytes + limits.firstFrameRetainedBytes
        XCTAssertEqual(limits.retainedByteBudget, expected)
        XCTAssertLessThanOrEqual(limits.retainedByteBudget, limits.retainedByteCeiling)
    }

    /// Doubling the reply cap moves the budget by exactly the reservation and first-frame terms that scale with it.
    func testDoublingTheReplyCapChangesTheBudgetByItsReservationAndFirstFrameTermsOnly() throws {
        let small = try RuntimeServiceFixtures.limits(replyBytes: 64 * 1024)
        let large = try RuntimeServiceFixtures.limits(replyBytes: 128 * 1024)
        XCTAssertEqual(large.retainedByteBudget - small.retainedByteBudget, (2 * small.laneCount + small.subscriberLimit) * 64 * 1024)
    }

    /// Doubling the request cap moves the budget by the two request-sized lane terms and the operation records, and by nothing else.
    func testDoublingTheRequestCapChangesTheBudgetByItsCustodyTermsOnly() throws {
        let small = try RuntimeServiceFixtures.limits(requestBytes: 4096)
        let large = try RuntimeServiceFixtures.limits(requestBytes: 8192)
        XCTAssertEqual(large.retainedByteBudget - small.retainedByteBudget, (2 * small.laneCount + small.operationCapacity) * 4096)
    }

    /// A configuration whose budget exceeds the owner's ceiling is refused when it is built.
    func testABudgetAboveTheOwnersCeilingIsRefusedAtConstruction() throws {
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(retainedByteCeiling: 1 << 16))
    }

    /// The owner's ceiling is inclusive: the exact budget is accepted, and one byte less is refused at construction.
    func testTheCeilingAcceptsExactlyTheBudgetAndRefusesOneByteLess() throws {
        let budget = try RuntimeServiceFixtures.limits().retainedByteBudget
        XCTAssertNoThrow(try RuntimeServiceFixtures.limits(retainedByteCeiling: budget))
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(retainedByteCeiling: budget - 1))
    }

    /// A maximal event at its maximal cursor frames to exactly the smallest reply cap that construction accepts. The codec accepts
    /// that frame at that cap and refuses it at one byte less, and construction refuses the same one-byte-smaller cap. So the
    /// boundary is exact: the measured overhead is not an over-estimate for a maximal event.
    func testAMaximalEventFrameFitsTheSmallestAcceptedReplyCapExactly() throws {
        let probe = try RuntimeServiceFixtures.limits()
        let record = try maximalEventRecord(bytes: probe.maxEventBytes)
        let cursor = try XCTUnwrap(ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition))
        let message = ControlRuntimeMessage(
            correlation: RuntimeServiceFixtures.requestID(1),
            body: .frame(.events(try ControlEventBatch(firstCursor: cursor, events: [record])))
        )
        let exact = try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: 1 << 20)).count
        XCTAssertEqual(try RuntimeWireSize.bytes(of: record), probe.maxEventBytes, "the event is maximal")
        XCTAssertNoThrow(try RuntimeServiceFixtures.limits(replyBytes: exact), "the smallest accepted reply cap carries one maximal event")
        XCTAssertThrowsError(try RuntimeServiceFixtures.limits(replyBytes: exact - 1), "one byte less cannot carry it")
        XCTAssertNoThrow(try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: exact)))
        XCTAssertThrowsError(try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: exact - 1)))
    }

    /// A record whose encoded size is exactly `bytes`. Only the event name varies, and it is plain ASCII, so its JSON size grows by
    /// one byte per character.
    private func maximalEventRecord(bytes: Int) throws -> ControlRuntimeEventRecord {
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
