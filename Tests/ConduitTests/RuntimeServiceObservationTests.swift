// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
@testable import ProxyKernel
import ProxyControlBridge

/// What one pull of a subscriber delivered, in the terms the tests compare. A pull that is not committed is never recorded here.
enum ObservedPull: Equatable {
    case snapshot(revision: Int)
    case events(count: Int, firstCursor: Int)
    case replayCaughtUp(Int)
    case operation(ControlOperationID)
    /// A frame the observation tests never produce, such as a baseline.
    case other
    case idle
    case end(ControlStreamEndReason)
    /// The subscriber is not open, so the pull consumed nothing.
    case gone
}

/// A projected snapshot whose presentation revision and body the test chooses. Every other scalar is the projection's default.
func observationSnapshot(
    presentation: Int,
    profile: String = "Corp",
    incarnation: Int = 1
) throws -> ControlRuntimeSnapshot {
    try RuntimeSnapshotControlProjection.snapshot(
        ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .notNeeded),
        stamp: ControlRuntimeStamp(
            incarnation: RuntimeServiceFixtures.incarnation(incarnation),
            presentationRevision: try XCTUnwrap(ControlPresentationRevision(rawValue: presentation)),
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 2)),
            lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 5))
        ),
        profileName: profile,
        collectionRevisions: ControlCollectionRevisions()
    )
}

/// One pull, peeked and committed only when it delivers a frame, as the transport's winning gate does. A stream end removes the
/// subscriber in the same turn, as the transport does.
@RuntimeActor
func observePull(_ core: RuntimeServiceCore, _ subscriber: Int) throws -> ObservedPull {
    guard let peeked = try core.peekFrame(subscriber, fits: { _ in true }) else { return .gone }
    switch peeked.pull {
    case .frame(let frame):
        core.commitCursor(subscriber, peeked.after)
        switch frame {
        case .snapshot(let snapshot):
            return .snapshot(revision: snapshot.stamp.presentationRevision.rawValue)
        case .events(let batch):
            return .events(count: batch.events.count, firstCursor: batch.firstCursor.rawValue)
        case .replayCaughtUp(let cursor):
            return .replayCaughtUp(cursor.rawValue)
        case .operationFinished(let finished):
            return .operation(finished.operationID)
        case .baseline, .end:
            return .other
        }
    case .idle:
        return .idle
    case .end(let reason):
        core.removeSubscriber(subscriber)
        return .end(reason)
    }
}

/// Opens one live subscription, and returns its identity with the revision its baseline names.
@RuntimeActor
func openLive(_ core: RuntimeServiceCore) -> (subscriber: Int, revision: Int)? {
    guard case .opened(let subscriber, .baseline(let baseline)) = core.openSubscription(.live) else { return nil }
    return (subscriber, baseline.snapshot.stamp.presentationRevision.rawValue)
}

/// A wake counter that the parked closures may share from any thread.
final class WakeCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var wakes = 0

    var count: Int {
        lock.withLock { wakes }
    }

    func bump() {
        lock.withLock { wakes += 1 }
    }
}

/// The observation rules of the service, driven through the production core and its owner turns: the baseline capture, the latest
/// snapshot slot, the invariant faults, generation exhaustion, exactly-once removal, the snapshot and log alternation, replay order,
/// and the framed reads. Each test states its one rule.
final class RuntimeServiceObservationTests: XCTestCase {
    /// Sets the owner's state and reports the change, as the owner does in its own turn.
    @RuntimeActor private func publish(_ harness: RuntimeServiceHarness, presentation: Int, profile: String = "Corp") throws {
        harness.owner.snapshotValue = try observationSnapshot(presentation: presentation, profile: profile)
        harness.core.ownerDidChange()
    }

    /// Publishes one event, then runs the one drain hop it queued, so the event is in the ring before the next step.
    @RuntimeActor private func ingest(_ harness: RuntimeServiceHarness) {
        harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event"))
        harness.scheduling.drainAll()
    }

    @RuntimeActor private func thrownError<T>(_ body: () async throws -> T) async -> RuntimeClientError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeClientError
        }
    }

    // MARK: - Baseline and the latest snapshot

    /// An open reads the owner's state in its own turn, so an owner change nobody reported is in the new baseline, and the old
    /// subscriber still receives that change once, as the latest snapshot.
    @RuntimeActor func testAnOpenCapturesAnOwnerChangeThatNoOneReported() async throws {
        let harness = try RuntimeServiceHarness()
        let first = try XCTUnwrap(openLive(harness.core))
        XCTAssertEqual(first.revision, 9, "the fixture owner state is the first baseline")
        harness.owner.snapshotValue = try observationSnapshot(presentation: 10)
        let second = try XCTUnwrap(openLive(harness.core))
        XCTAssertEqual(second.revision, 10, "a silent change is captured by the next open in its own turn")
        XCTAssertEqual(try observePull(harness.core, first.subscriber), .snapshot(revision: 10))
        XCTAssertEqual(try observePull(harness.core, second.subscriber), .idle, "the new baseline already holds the latest state")
    }

    /// Several owner changes between two pulls deliver one latest snapshot to each subscriber, and never one per change.
    @RuntimeActor func testOwnerChangesCoalesceIntoTheLatestSnapshotForEverySubscriber() async throws {
        let harness = try RuntimeServiceHarness()
        let first = try XCTUnwrap(openLive(harness.core))
        XCTAssertEqual(harness.core.snapshotGeneration, 1)
        try publish(harness, presentation: 10)
        try publish(harness, presentation: 11)
        try publish(harness, presentation: 12)
        XCTAssertEqual(harness.core.snapshotGeneration, 4, "each real change advances the private generation once")
        XCTAssertEqual(try observePull(harness.core, first.subscriber), .snapshot(revision: 12))
        XCTAssertEqual(try observePull(harness.core, first.subscriber), .idle)
        let second = try XCTUnwrap(openLive(harness.core))
        XCTAssertEqual(second.revision, 12)
        XCTAssertEqual(try observePull(harness.core, second.subscriber), .idle, "a late subscriber starts at the held generation")
        try publish(harness, presentation: 13)
        XCTAssertEqual(try observePull(harness.core, second.subscriber), .snapshot(revision: 13))
        XCTAssertEqual(try observePull(harness.core, first.subscriber), .snapshot(revision: 13))
    }

    /// An identical owner state advances nothing and delivers nothing.
    @RuntimeActor func testAnIdenticalOwnerStateAdvancesNothing() async throws {
        let harness = try RuntimeServiceHarness()
        try publish(harness, presentation: 10)
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        XCTAssertEqual(harness.core.snapshotGeneration, 1)
        try publish(harness, presentation: 10)
        XCTAssertEqual(harness.core.snapshotGeneration, 1)
        XCTAssertEqual(try observePull(harness.core, subscriber), .idle)
        XCTAssertTrue(harness.owner.faults.isEmpty)
    }

    /// Two different bodies under one presentation revision break the owner's invariant. The slot keeps the held snapshot, the fault
    /// names the conflict, and the open and the read fail closed.
    @RuntimeActor func testSameRevisionWithAnotherBodyIsAnInvariantFaultAndRetainsNothing() async throws {
        let harness = try RuntimeServiceHarness()
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        harness.owner.snapshotValue = try observationSnapshot(presentation: 9, profile: "Other")
        harness.core.ownerDidChange()
        XCTAssertEqual(harness.owner.faults, [.snapshotRevisionConflict])
        XCTAssertEqual(harness.core.snapshotGeneration, 1, "the held snapshot and its generation are unchanged")
        XCTAssertEqual(try observePull(harness.core, subscriber), .idle)
        guard case .refused(let openCode) = harness.core.openSubscription(.live) else {
            return XCTFail("an open over a broken owner state must fail closed")
        }
        XCTAssertEqual(openCode, .internalFailure)
        guard case .internalFailure = harness.core.readSnapshot() else {
            return XCTFail("a read over a broken owner state must fail closed")
        }
    }

    /// A presentation revision older than the held one is an invariant fault, and nothing is retained.
    @RuntimeActor func testARegressedPresentationRevisionIsAnInvariantFault() async throws {
        let harness = try RuntimeServiceHarness()
        try publish(harness, presentation: 10)
        XCTAssertEqual(harness.core.snapshotGeneration, 1)
        try publish(harness, presentation: 8)
        XCTAssertEqual(harness.owner.faults, [.snapshotRevisionRegressed])
        XCTAssertEqual(harness.core.snapshotGeneration, 1, "a regressed revision is never retained")
    }

    /// A snapshot that names another incarnation is never retained, and the fault says so.
    @RuntimeActor func testAnotherIncarnationIsAnInvariantFaultAndRetainsNothing() async throws {
        let harness = try RuntimeServiceHarness()
        harness.owner.snapshotValue = try observationSnapshot(presentation: 10, incarnation: 2)
        harness.core.ownerDidChange()
        XCTAssertEqual(harness.owner.faults, [.snapshotIncarnationMismatch])
        XCTAssertEqual(harness.core.snapshotGeneration, 0, "nothing from another incarnation is retained")
    }

    /// A snapshot over the slot's declared bound is an invariant fault, never a capacity answer. The open fails closed.
    @RuntimeActor func testAnOversizedSnapshotIsAnInvariantFaultNotACapacityAnswer() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(snapshotBytes: 100))
        guard case .refused(let code) = harness.core.openSubscription(.live) else {
            return XCTFail("an oversized baseline must not open")
        }
        XCTAssertEqual(code, .internalFailure)
        XCTAssertEqual(harness.owner.faults, [.snapshotOverBound])
        XCTAssertEqual(harness.core.snapshotGeneration, 0, "nothing is retained for an oversized snapshot")
    }

    // MARK: - Generation exhaustion

    /// When the private generation cannot advance, the slot is sticky: no newer state is shown, every subscriber ends with a resync,
    /// and a new open or read fails closed. Nothing wraps, and no fake generation is invented.
    @RuntimeActor func testGenerationExhaustionIsAStickyTerminalAndNewerStateIsNeverShown() async throws {
        let harness = try RuntimeServiceHarness(snapshotGenerationSeed: Int.max - 1)
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        let held = harness.owner.snapshotValue
        XCTAssertEqual(harness.core.snapshotGeneration, Int.max, "one replacement remains before exhaustion")
        try publish(harness, presentation: 10)
        XCTAssertTrue(harness.core.isSnapshotSlotExhausted)
        XCTAssertTrue(harness.owner.faults.isEmpty, "exhaustion is an ordinary terminal, not an owner fault")
        XCTAssertEqual(try observePull(harness.core, subscriber), .end(.resyncRequired))
        XCTAssertEqual(harness.core.openSubscriberCount, 0)
        // The owner returning the held state does not recover the sticky slot: a read still fails closed, not as the stale snapshot.
        harness.owner.snapshotValue = held
        guard case .internalFailure = harness.core.readSnapshot() else {
            return XCTFail("a read of the held state after exhaustion must still fail closed")
        }
        guard case .refused(let code) = harness.core.openSubscription(.live) else {
            return XCTFail("an open after exhaustion must fail closed")
        }
        XCTAssertEqual(code, .internalFailure)
        guard case .internalFailure = harness.core.readSnapshot() else {
            return XCTFail("a read after exhaustion must fail closed")
        }
        XCTAssertEqual(harness.core.snapshotGeneration, Int.max, "the counter stays at its maximum")
    }

    // MARK: - Removal and parked waits

    /// A subscriber leaves the table once, and its parked wait is woken once. A second removal changes nothing.
    @RuntimeActor func testRemovingASubscriberIsExactlyOnceAndItsParkedWaitIsWokenOnce() async throws {
        let harness = try RuntimeServiceHarness()
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        let wakes = WakeCounter()
        XCTAssertEqual(harness.core.parkWaiter(subscriber, token: RuntimeWaiterToken(), wake: { wakes.bump() }), .parked)
        XCTAssertEqual(harness.core.parkedWaiterCount, 1)
        harness.core.removeSubscriber(subscriber)
        harness.core.removeSubscriber(subscriber)
        XCTAssertEqual(wakes.count, 1)
        XCTAssertEqual(harness.core.openSubscriberCount, 0)
        XCTAssertEqual(harness.core.parkedWaiterCount, 0)
    }

    /// The subscription limit is the only refusal of an open that is a capacity answer, and a refused open changes no state.
    @RuntimeActor func testTheSubscriberLimitRefusesOnlyTheOpenThatExceedsIt() async throws {
        let harness = try RuntimeServiceHarness(subscribers: 1)
        _ = try XCTUnwrap(openLive(harness.core))
        let generation = harness.core.snapshotGeneration
        guard case .refused(let code) = harness.core.openSubscription(.live) else {
            return XCTFail("the second open must be refused")
        }
        XCTAssertEqual(code, .subscriberLimit)
        XCTAssertEqual(harness.core.snapshotGeneration, generation)
        XCTAssertTrue(harness.owner.faults.isEmpty)
    }

    // MARK: - Pulls and fairness

    /// A pull that is not committed consumes neither the snapshot generation nor the event cursor, so the same frame comes back.
    @RuntimeActor func testAnUncommittedPullConsumesNothing() async throws {
        let harness = try RuntimeServiceHarness()
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        try publish(harness, presentation: 10)
        let first = try XCTUnwrap(try harness.core.peekFrame(subscriber, fits: { _ in true }))
        let second = try XCTUnwrap(try harness.core.peekFrame(subscriber, fits: { _ in true }))
        XCTAssertEqual(first.pull, second.pull)
        XCTAssertEqual(try observePull(harness.core, subscriber), .snapshot(revision: 10), "the peeked frame is delivered once committed")
        XCTAssertEqual(try observePull(harness.core, subscriber), .idle)
    }

    /// With a snapshot and an ordered frame both waiting, they alternate: a snapshot never goes twice in a row while a log frame waits,
    /// and a log frame never waits behind a flood of snapshots.
    @RuntimeActor func testSnapshotsAndOrderedFramesAlternateUnderAConstantFlood() async throws {
        let harness = try RuntimeServiceHarness()
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        var observed: [ObservedPull] = []
        var expected: [ObservedPull] = []
        for cycle in 1...6 {
            try publish(harness, presentation: 9 + cycle)
            ingest(harness)
            observed.append(try observePull(harness.core, subscriber))
            observed.append(try observePull(harness.core, subscriber))
            expected.append(.snapshot(revision: 9 + cycle))
            expected.append(.events(count: 1, firstCursor: cycle))
        }
        XCTAssertEqual(observed, expected)
    }

    /// A snapshot alone is delivered at once, and ordered events alone are delivered at once. Neither waits for the other.
    @RuntimeActor func testAWaitingKindIsDeliveredAtOnceWhenTheOtherIsAbsent() async throws {
        let harness = try RuntimeServiceHarness()
        let subscriber = try XCTUnwrap(openLive(harness.core)).subscriber
        try publish(harness, presentation: 10)
        XCTAssertEqual(try observePull(harness.core, subscriber), .snapshot(revision: 10))
        ingest(harness)
        XCTAssertEqual(try observePull(harness.core, subscriber), .events(count: 1, firstCursor: 1))
        XCTAssertEqual(try observePull(harness.core, subscriber), .idle)
    }

    /// Two subscribers that saw different generations each receive the right latest snapshot, and none of the intermediate ones.
    @RuntimeActor func testTwoSubscribersAtDifferentGenerationsEachReceiveTheLatestAtTheirOwnPace() async throws {
        let harness = try RuntimeServiceHarness()
        let early = try XCTUnwrap(openLive(harness.core)).subscriber
        try publish(harness, presentation: 10)
        let late = try XCTUnwrap(openLive(harness.core)).subscriber
        XCTAssertEqual(try observePull(harness.core, early), .snapshot(revision: 10))
        try publish(harness, presentation: 11)
        XCTAssertEqual(try observePull(harness.core, late), .snapshot(revision: 11), "the late subscriber skips the revision it never saw")
        XCTAssertEqual(try observePull(harness.core, early), .snapshot(revision: 11), "the early subscriber gets the latest once, not 10 and 11")
        XCTAssertEqual(try observePull(harness.core, early), .idle)
    }

    // MARK: - Replay order

    /// During a replay, the replayed events come first, then the caught-up mark, and only then a snapshot, even when the owner changed.
    @RuntimeActor func testAReplayDeliversItsOrderedFramesBeforeAnySnapshot() async throws {
        let harness = try RuntimeServiceHarness()
        ingest(harness)
        ingest(harness)
        let resume = ControlSubscriptionRequest.resume(
            incarnation: RuntimeServiceFixtures.incarnation(1),
            from: try XCTUnwrap(ControlEventCursor(rawValue: 1))
        )
        guard case .opened(let subscriber, _) = harness.core.openSubscription(resume) else {
            return XCTFail("the resume must open")
        }
        try publish(harness, presentation: 10)
        XCTAssertEqual(try observePull(harness.core, subscriber), .events(count: 2, firstCursor: 1))
        XCTAssertEqual(try observePull(harness.core, subscriber), .replayCaughtUp(2))
        XCTAssertEqual(try observePull(harness.core, subscriber), .snapshot(revision: 10))
        XCTAssertEqual(try observePull(harness.core, subscriber), .idle)
    }

    // MARK: - Framed reads

    /// A baseline larger than the caller's frame is a typed refusal as the first frame, and the subscriber is released. It is never an
    /// invalid reply, and no subscriber is left behind.
    @RuntimeActor func testABaselineThatDoesNotFitTheCallersFrameIsARefusedFirstFrame() async throws {
        let harness = try RuntimeServiceHarness()
        let narrow = try ControlFrameLimits(maxFrameBytes: 512)
        let epoch = harness.timing.now
        let client = try makeFramedRuntimeClient(
            transport: harness.transport(),
            limits: narrow,
            wireBudgetCap: .seconds(60),
            now: { epoch },
            makeCorrelation: { ControlRequestID(rawValue: UUID()) }
        )
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        let refused = await thrownError { try await subscription.next(deadline) }
        XCTAssertEqual(refused, .wire(.frameTooLarge))
        XCTAssertEqual(harness.core.openSubscriberCount, 0)
    }

    /// A framed snapshot read answers the owner's state in its own turn, and a broken owner state is a stable internal failure.
    @RuntimeActor func testTheFramedSnapshotReadAnswersTheOwnersStateAndAnInvariantBreakIsInternalFailure() async throws {
        let harness = try RuntimeServiceHarness()
        let epoch = harness.timing.now
        let client = try makeFramedRuntimeClient(
            transport: harness.transport(),
            limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .seconds(60),
            now: { epoch },
            makeCorrelation: { ControlRequestID(rawValue: UUID()) }
        )
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let first = try await runCall(harness.scheduling) { try await client.readSnapshot(deadline: deadline) }
        XCTAssertEqual(first.stamp.presentationRevision.rawValue, 9)

        harness.owner.snapshotValue = try observationSnapshot(presentation: 10)
        let second = try await runCall(harness.scheduling) { try await client.readSnapshot(deadline: deadline) }
        XCTAssertEqual(second.stamp.presentationRevision.rawValue, 10, "a silent change is captured by the read in its own turn")

        harness.owner.snapshotValue = try observationSnapshot(presentation: 10, profile: "Other")
        let failure = await thrownError { try await runCall(harness.scheduling) { try await client.readSnapshot(deadline: deadline) } }
        XCTAssertEqual(failure, .wire(.internalFailure))
    }

    // MARK: - Ingress

    /// An event whose own text is past the event bound is a loss, and a live subscriber resyncs. The text is refused before its encoding.
    /// An ordinary event published after the loss still reaches a subscriber opened after it, at the next position.
    @RuntimeActor func testAnEventWhoseTextIsPastTheEventBoundIsALossAndAnOrdinaryEventStillArrives() async throws {
        let harness = try RuntimeServiceHarness()
        let first = try XCTUnwrap(openLive(harness.core)).subscriber
        let oversize = ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            kind: "proxy",
            event: "test.event",
            detail: String(repeating: "d", count: harness.limits.maxEventBytes + 1)
        )
        harness.core.ingest(oversize)
        harness.scheduling.drainAll()
        XCTAssertEqual(try observePull(harness.core, first), .end(.resyncRequired))

        let second = try XCTUnwrap(openLive(harness.core)).subscriber
        ingest(harness)
        XCTAssertEqual(try observePull(harness.core, second), .events(count: 1, firstCursor: 2), "the gap took position one")
    }

    // MARK: - Lanes

    /// A full read lane, which carries the pulls and the reads, leaves every stop and the ordinary lane reservable.
    @RuntimeActor func testAFullReadLaneLeavesEveryStopAndTheOrdinaryLaneReservable() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        for _ in 0..<harness.limits.readLaneCapacity {
            XCTAssertNotNil(transport.lanes.reserve(.read, onQuiesced: nil))
        }
        XCTAssertNil(transport.lanes.reserve(.read, onQuiesced: nil), "the read lane is full")
        for module in ControlModule.allCases {
            XCTAssertNotNil(transport.lanes.reserve(.stop(module), onQuiesced: nil), "a stop lane is independent of the read lane")
        }
        XCTAssertNotNil(transport.lanes.reserve(.ordinary, onQuiesced: nil))
    }
}
