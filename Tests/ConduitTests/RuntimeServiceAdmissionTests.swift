// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
import ProxyKernel

/// The admission path, driven through the production service against a fake owner and a manual hop queue. Every
/// decision is the service's: recovery, conflict, incarnation, bounds, supersession and aging. Every fence is the owner's.
final class RuntimeServiceAdmissionTests: XCTestCase {
    private let lifecycle = ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!

    @RuntimeActor func testRecoveredRequestRecoversItsAdmissionWithoutAFreshFence() async throws {
        let harness = try RuntimeServiceHarness()

        let first = harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.dns)))
        guard case .accepted = first else { return XCTFail("expected an accepted stop, got \(first)") }
        XCTAssertEqual(harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.dns))), first)
        XCTAssertEqual(harness.owner.fenceLog.count, 1, "a recovered request is never fenced again")
    }

    @RuntimeActor func testSamePayloadConflictIsRefusedAndTheEarlierAdmissionIsNotReused() async throws {
        let harness = try RuntimeServiceHarness()

        _ = harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.dns)))
        XCTAssertEqual(harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.proxy))), .rejected(.requestConflict))
        XCTAssertEqual(harness.owner.fenceLog.count, 1)
    }

    @RuntimeActor func testAnotherIncarnationIsRefusedAndNothingIsRecorded() async throws {
        let harness = try RuntimeServiceHarness()

        let other = RuntimeServiceFixtures.incarnation(7)
        XCTAssertEqual(
            harness.core.submit(try RuntimeServiceFixtures.request(2, .refreshPreflight(helperReplaced: false), in: other)),
            .rejected(.changedIncarnation)
        )
        XCTAssertEqual(harness.core.aliasCount, 0)
        XCTAssertTrue(harness.owner.fenceLog.isEmpty, "a refused incarnation never reaches the owner")
    }

    @RuntimeActor func testEveryStopReachesTheOwnerIncludingACoalescingOne() async throws {
        let harness = try RuntimeServiceHarness()

        guard case .accepted(let first) = harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.dns))) else {
            return XCTFail("the first stop must be accepted")
        }
        XCTAssertEqual(harness.core.submit(try RuntimeServiceFixtures.request(2, .stop(.dns))), .joined(first))
        XCTAssertEqual(harness.owner.fenceLog.map { $0.candidate }, [nil, first], "the owner decides the join, with the candidate")
    }

    @RuntimeActor func testAFreshStopSupersedesACandidateTheOwnerReplaces() async throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.answer = { _, _ in .admitted }

        guard case .accepted(let first) = harness.core.submit(try RuntimeServiceFixtures.request(1, .stop(.dns))),
              case .accepted(let second) = harness.core.submit(try RuntimeServiceFixtures.request(2, .stop(.dns)))
        else {
            return XCTFail("both stops must be accepted")
        }
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, first), .finished(.superseded(by: second)))
        XCTAssertEqual(harness.core.pendingOperationCount, 1, "the stop slot moves to the newer operation")
    }

    @RuntimeActor func testAStopFloodStaysInsideItsPartitionAndAnotherModuleStillAdmits() async throws {
        let harness = try RuntimeServiceHarness(aliases: 8)

        for id in 1...40 {
            _ = harness.core.submit(try RuntimeServiceFixtures.request(id, .stop(.dns)))
        }
        XCTAssertLessThanOrEqual(harness.core.aliasCount, 8, "joins are charged against their partition's alias bound")
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(100, .stop(.proxy))) else {
            return XCTFail("a distinct module keeps its own stop slot after a dns flood")
        }
    }

    @RuntimeActor func testOrdinaryQueueFullIsNotRecordedSoARetryIsAdmittedLater() async throws {
        let harness = try RuntimeServiceHarness(ordinaryPending: 1)

        guard case .accepted(let first) = harness.core.submit(try RuntimeServiceFixtures.request(1, .restart(.proxy, ifLifecycleRevision: lifecycle))) else {
            return XCTFail("the first restart must be accepted")
        }
        harness.scheduling.drainAll()
        XCTAssertEqual(
            harness.core.submit(try RuntimeServiceFixtures.request(2, .restart(.dns, ifLifecycleRevision: lifecycle))),
            .rejected(.queueFull)
        )
        XCTAssertEqual(try RuntimeServiceFixtures.lookupRequest(harness.core, 2), .unknown(.notRecorded), "a capacity refusal is not recorded")

        harness.owner.settle(first, with: .failed(.effectFailed))
        harness.owner.quiesce(first)
        guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(2, .restart(.dns, ifLifecycleRevision: lifecycle))) else {
            return XCTFail("the retry is admitted once the owner has quiesced the first operation")
        }
    }

    /// A rejected stop is recorded as its rejection, and a retry of the same payload recovers that rejection without a fresh
    /// fence. A rejection takes no stop slot, so a later stop for the module is fenced on its own. This covers both modules,
    /// and the bounded model's join and reject alphabet covers `.dns` only.
    @RuntimeActor func testARejectedStopIsRecordedAndRecoversItsRejectionWithoutAFreshFence() async throws {
        for module in [ControlModule.dns, .proxy] {
            let harness = try RuntimeServiceHarness()
            harness.owner.answer = { _, _ in .rejected(.hostStopping) }
            let request = try RuntimeServiceFixtures.request(1, .stop(module))

            XCTAssertEqual(harness.core.submit(request), .rejected(.hostStopping), "\(module): the owner's rejection is the admission")
            XCTAssertEqual(harness.core.submit(request), .rejected(.hostStopping), "\(module): the recorded rejection is recovered")
            XCTAssertEqual(harness.owner.fenceLog.count, 1, "\(module): a recovered rejection is never fenced again")
            XCTAssertEqual(harness.core.stopSlotState(module).queued, false, "\(module): a rejected stop takes no stop slot")
            XCTAssertEqual(harness.core.liveOperationCount, 0, "\(module): a rejected stop creates no operation")
            XCTAssertTrue(harness.owner.startedOperations.isEmpty, "\(module): no effect is started for a rejection")

            harness.owner.answer = { _, _ in .admitted }
            guard case .accepted = harness.core.submit(try RuntimeServiceFixtures.request(2, .stop(module))) else {
                return XCTFail("\(module): a later stop is fenced on its own, after a rejection")
            }
        }
    }

    @RuntimeActor func testSynchronousCompletionFindsTheFinalRecord() async throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.completesSynchronously = true

        guard case .accepted(let operation) = harness.core.submit(try RuntimeServiceFixtures.request(1, .restart(.proxy, ifLifecycleRevision: lifecycle))) else {
            return XCTFail("the restart must be accepted")
        }
        harness.scheduling.drainAll()
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, operation), .finished(.failed(.effectFailed)))
        XCTAssertEqual(harness.core.pendingOperationCount, 0)
        XCTAssertEqual(harness.core.liveOperationCount, 0, "a synchronously quiesced operation holds nothing")
    }

    @RuntimeActor func testPendingNeverAgesAndAFinishedRecordExpiresFromItsSettlement() async throws {
        let harness = try RuntimeServiceHarness()

        guard case .accepted(let operation) = harness.core.submit(try RuntimeServiceFixtures.request(1, .restart(.proxy, ifLifecycleRevision: lifecycle))) else {
            return XCTFail("the restart must be accepted")
        }
        harness.scheduling.drainAll()
        harness.timing.advance(by: .seconds(120))
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, operation), .pending, "a pending operation is never aged into a finished one")
        XCTAssertEqual(
            try RuntimeServiceFixtures.lookupRequest(harness.core, 1),
            .unknown(.notRecorded),
            "an alias ages from its admission, so it is gone while its operation is still pending"
        )

        harness.owner.settle(operation, with: .failed(.effectFailed))
        harness.timing.advance(by: .seconds(61))
        XCTAssertEqual(RuntimeServiceFixtures.lookup(harness.core, operation), .unknown(.notRecorded), "the outcome expires from its settlement")
    }
}
