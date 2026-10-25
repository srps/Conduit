// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// Replay through the production core and its owner turns: the order of events and outcomes, eviction during a catch-up in either log,
/// the explicit refusals of a replay that could miss history, and the typed end of a stream. Each test states its one rule.
@MainActor
final class RuntimeServiceReplayTests: XCTestCase {
    /// Publishes one event, then runs the drain hop it queued.
    private func ingest(_ harness: RuntimeServiceHarness) {
        harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event"))
        harness.scheduling.drainAll()
    }

    /// Admits one ordinary command, runs its launch, settles it and quiesces it. The outcome is appended at the current high-water mark.
    /// Nil when the command is not admitted.
    private func finishOperation(_ harness: RuntimeServiceHarness, request: Int) throws -> ControlOperationID? {
        guard case .accepted(let operation) = harness.core.submit(try RuntimeServiceFixtures.request(request, .testDNS)) else {
            return nil
        }
        harness.scheduling.drainAll()
        harness.owner.settle(operation, with: .failed(.internalFailure))
        harness.owner.quiesce(operation)
        return operation
    }

    /// Opens a replay from one event position, and returns the subscriber with its baseline's replay answer.
    private func openReplay(_ core: RuntimeServiceCore, from position: Int) throws -> (subscriber: Int, replay: ControlReplayAvailability)? {
        let cursor = try XCTUnwrap(ControlEventCursor(rawValue: position))
        let request = ControlSubscriptionRequest.resume(incarnation: RuntimeServiceFixtures.incarnation(1), from: cursor)
        guard case .opened(let subscriber, .baseline(let baseline)) = core.openSubscription(request) else { return nil }
        return (subscriber, baseline.replay)
    }

    /// Outcomes are delivered after the events they follow, and before the events that come later, so the order is the order the owner
    /// produced. The replay ends with its caught-up mark, and the live edge follows.
    func testAReplayDeliversEachOutcomeAfterTheEventsItFollows() throws {
        let harness = try RuntimeServiceHarness()
        ingest(harness)
        let operation = try XCTUnwrap(try finishOperation(harness, request: 1))
        ingest(harness)
        let replay = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(replay.replay, .replay(from: try XCTUnwrap(ControlEventCursor(rawValue: 1)), through: try XCTUnwrap(ControlEventCursor(rawValue: 2))))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .events(count: 1, firstCursor: 1))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .operation(operation))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .events(count: 1, firstCursor: 2))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .replayCaughtUp(2))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .idle)
    }

    /// A replay whose events have been evicted from the ring while it is catching up ends with a resync, not a silent gap. The subscriber is
    /// released in the same turn, and a replay opened afterwards is refused as expired history.
    func testEventEvictionDuringACatchUpEndsWithAResync() throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(
            ringCapacity: 3,
            replayChunkItems: 1
        ))
        ingest(harness)
        ingest(harness)
        ingest(harness)
        let replay = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .events(count: 1, firstCursor: 1))
        for _ in 0..<3 {
            ingest(harness)
        }
        XCTAssertEqual(harness.core.observedFirstRetained, 4)
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .end(.resyncRequired))
        XCTAssertEqual(harness.core.openSubscriberCount, 0)
        let late = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(late.replay, .unavailable(.expiredHistory), "history from before the ring is refused, never replayed partially")
    }

    /// An outcome evicted from the control log while a replay is catching up ends the replay with a resync. The replay that was opened
    /// before the eviction still held the outcome in range, so nothing in its range can be skipped silently.
    func testOutcomeEvictionDuringACatchUpEndsWithAResync() throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(controlLogCapacity: 2))
        ingest(harness)
        _ = try XCTUnwrap(try finishOperation(harness, request: 1))
        ingest(harness)
        let replay = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(replay.replay, .replay(from: try XCTUnwrap(ControlEventCursor(rawValue: 1)), through: try XCTUnwrap(ControlEventCursor(rawValue: 2))))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .events(count: 1, firstCursor: 1))
        _ = try XCTUnwrap(try finishOperation(harness, request: 2))
        _ = try XCTUnwrap(try finishOperation(harness, request: 3))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .end(.resyncRequired))
    }

    /// A replay whose range may hold an evicted outcome is refused at the baseline, as expired history. Its subscriber reads live from the
    /// high-water mark, so no outcome is replayed partially.
    func testAReplayThatMayHaveLostAnOutcomeIsRefusedAsExpiredHistory() throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(controlLogCapacity: 1))
        ingest(harness)
        _ = try XCTUnwrap(try finishOperation(harness, request: 1))
        ingest(harness)
        _ = try XCTUnwrap(try finishOperation(harness, request: 2))
        let refused = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(refused.replay, .unavailable(.expiredHistory))
        XCTAssertEqual(try observePull(harness.core, refused.subscriber), .idle, "the live reader starts after the high-water mark")
    }

    /// A replay across a loss is refused as an observation loss, and a replay that starts after the loss is clean. The loss is an event
    /// too large to retain, which the ingress refuses as a loss marker, so it reserves position two.
    func testAReplayAcrossALossIsRefusedAndAReplayAfterItIsClean() throws {
        let harness = try RuntimeServiceHarness()
        ingest(harness)
        harness.core.ingest(ControlRuntimeEvent(
            timestamp: Date(timeIntervalSince1970: 1),
            kind: "proxy",
            event: "test.event",
            detail: String(repeating: "d", count: harness.limits.maxEventBytes + 1)
        ))
        harness.scheduling.drainAll()
        ingest(harness)
        let across = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(across.replay, .unavailable(.observationLoss))

        let after = try XCTUnwrap(try openReplay(harness.core, from: 3))
        XCTAssertEqual(after.replay, .replay(from: try XCTUnwrap(ControlEventCursor(rawValue: 3)), through: try XCTUnwrap(ControlEventCursor(rawValue: 3))))
        XCTAssertEqual(try observePull(harness.core, after.subscriber), .events(count: 1, firstCursor: 3))
        XCTAssertEqual(try observePull(harness.core, after.subscriber), .replayCaughtUp(3))
    }

    // MARK: - Frames that do not fit

    /// A stream end that fits its caller's frame is the reply. One that does not fit ends the wait as a bounded disconnect, once, with no
    /// refusal substituted. The end is measured, not guessed. This is a direct seam: the real wire cannot reach it with the same cap,
    /// because the baseline that opened the stream is always larger than an end.
    func testAStreamEndThatDoesNotFitIsABoundedDisconnectAndAFittingEndIsTheReply() throws {
        let correlation = RuntimeServiceFixtures.requestID(9)
        let roomy = try ControlFrameLimits(maxFrameBytes: 1 << 20)
        let end = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(correlation: correlation, body: .frame(.end(ControlStreamEnd(reason: .resyncRequired)))),
            limits: roomy
        ).count
        let refusal = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(correlation: correlation, body: .response(.failure(.frameTooLarge))),
            limits: roomy
        ).count
        XCTAssertLessThanOrEqual(refusal, end, "a refusal is never larger than an end, so it cannot be the fallback")

        let fitting = try ControlFrameLimits(maxFrameBytes: end)
        guard case .reply(let endBytes) = RuntimeInMemoryTransport.streamEndOutcome(.resyncRequired, correlation: correlation, limits: fitting) else {
            return XCTFail("a fitting end is the reply")
        }
        XCTAssertEqual(
            try ControlRuntimeCodec.decodeFullFrame(endBytes, limits: fitting).body,
            .frame(.end(ControlStreamEnd(reason: .resyncRequired)))
        )

        let narrow = try ControlFrameLimits(maxFrameBytes: end - 1)
        guard case .failed(.sent(.disconnected)) = RuntimeInMemoryTransport.streamEndOutcome(.resyncRequired, correlation: correlation, limits: narrow) else {
            return XCTFail("an end that does not fit ends the wait as a bounded disconnect, once")
        }
    }

    // MARK: - A real outcome larger than the caller's frame

    private func thrownError<T>(_ body: () async throws -> T) async -> RuntimeClientError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeClientError
        }
    }

    private func makeClient(_ harness: RuntimeServiceHarness, frame: ControlFrameLimits) throws -> any RuntimeClient {
        let epoch = harness.timing.now
        return try makeFramedRuntimeClient(
            transport: harness.transport(),
            limits: frame,
            wireBudgetCap: .seconds(60),
            now: { epoch },
            makeCorrelation: { ControlRequestID(rawValue: UUID()) }
        )
    }

    /// Admits one upstream probe and runs its launch, so the owner holds the operation until the test settles it.
    private func launchProbe(_ harness: RuntimeServiceHarness) throws -> ControlOperationID {
        let reference = ControlUpstreamReference(
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 2)),
            upstreamID: ControlUpstreamID(rawValue: UUID())
        )
        let request = ControlOperationRequest(
            requestID: RuntimeServiceFixtures.requestID(1),
            expectedIncarnation: RuntimeServiceFixtures.incarnation(1),
            command: .testUpstream(reference)
        )
        guard case .accepted(let operation) = harness.core.submit(request) else {
            throw RuntimeClientError.unexpectedReply
        }
        harness.scheduling.drainAll()
        return operation
    }

    /// A completed upstream probe, built as the owner builds one: the probe's name and endpoint are owner text, carried as given.
    private func upstreamOutcome(_ harness: RuntimeServiceHarness, name: String, endpoint: String) throws -> ControlOperationOutcome {
        let probe = ControlUpstreamProbe(
            upstreamID: ControlUpstreamID(rawValue: UUID()),
            name: name,
            endpoint: endpoint,
            reachable: true,
            latencyMilliseconds: try ControlCount(12)
        )
        let completion = try ControlCompletion(
            command: .testUpstream,
            presentationRevision: harness.owner.snapshotValue.stamp.presentationRevision,
            result: .upstreamProbe(probe)
        )
        return .completed(completion)
    }

    /// The baseline fits the caller's 2 KiB frame, and a completed probe whose escaped name encodes far past it. The stream ends as an
    /// explicit resync, the subscription is released with the end, and the outcome stays recoverable through the framed lookup. Recovery is
    /// conditional: the outcome is retained, and the lookup's reply fits the caller's frame. A narrow caller learns the size instead. Nothing
    /// is lost silently, and the client never sees an invalid reply.
    func testAnOutcomeLargerThanTheCallersFrameEndsTheStreamAsAResyncAndTheOutcomeStaysRecoverable() async throws {
        let harness = try RuntimeServiceHarness()
        let operation = try launchProbe(harness)
        let client = try makeClient(harness, frame: try ControlFrameLimits(maxFrameBytes: 2048))
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        let baseline = try await subscription.next(deadline)
        XCTAssertEqual(baseline.kind, .baseline, "the baseline fits the caller's frame")

        // Each quote is two bytes and each NUL six, so 400 of them encode to more than 3 KiB before the endpoint is counted.
        let outcome = try upstreamOutcome(
            harness,
            name: String(repeating: "\"\u{0}", count: 400),
            endpoint: String(repeating: "h", count: 200)
        )
        harness.owner.settle(operation, with: outcome)
        let ended = await thrownError { try await runCall(harness.scheduling) { try await subscription.next(deadline) } }
        XCTAssertEqual(ended, .streamClosed(.resyncRequired), "the outcome that does not fit ends the stream explicitly")
        XCTAssertEqual(harness.core.openSubscriberCount, 0, "the subscription is released with the end")
        let narrow = await thrownError {
            try await runCall(harness.scheduling) {
                try await client.outcome(of: operation, expectedIncarnation: RuntimeServiceFixtures.incarnation(1), deadline: deadline)
            }
        }
        XCTAssertEqual(narrow, .wire(.frameTooLarge), "the retained outcome's lookup reply does not fit the 2 KiB frame")
        let wide = try makeClient(harness, frame: try ControlFrameLimits(maxFrameBytes: 1 << 16))
        let recovered = try await runCall(harness.scheduling) {
            try await wide.outcome(of: operation, expectedIncarnation: RuntimeServiceFixtures.incarnation(1), deadline: deadline)
        }
        XCTAssertEqual(recovered, .finished(outcome), "the same retained outcome is recovered when its reply fits")
    }

    /// The same stream delivers a probe that fits, so the frame cap is what separated the two outcomes.
    func testAnOutcomeThatFitsTheCallersFrameIsDeliveredOnTheSameStream() async throws {
        let harness = try RuntimeServiceHarness()
        let operation = try launchProbe(harness)
        let client = try makeClient(harness, frame: try ControlFrameLimits(maxFrameBytes: 2048))
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        _ = try await subscription.next(deadline)
        harness.owner.settle(operation, with: try upstreamOutcome(harness, name: "probe", endpoint: "https://example.test"))
        let frame = try await runCall(harness.scheduling) { try await subscription.next(deadline) }
        XCTAssertEqual(frame.kind, .operationFinished)
        XCTAssertEqual(harness.core.openSubscriberCount, 1, "the stream stays open after a delivered outcome")
    }

    // MARK: - An oversize outcome is skipped, and its loss is kept

    /// The fixture's control-log byte bound. An outcome of `oversizeBytes` is larger than it, so the log skips it instead of retaining it.
    private static let oversizeFixtureBound = 8_192
    private static let oversizeBytes = 9_000
    /// Each quote and NUL pair encodes to 8 bytes, so this name encodes to about 16.8 KB, far past the fixture bound.
    private static let oversizeName = String(repeating: "\"\u{0}", count: 2_100)

    private func logEvent(_ log: inout RuntimeObservationLog) {
        let record = ControlRuntimeEventRecord.known(
            ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event")
        )
        log.apply([.event(record, bytes: 100)])
    }

    private func finished(_ value: Int) -> ControlOperationFinished {
        ControlOperationFinished(operationID: RuntimeServiceFixtures.operation(value), outcome: .failed(.internalFailure))
    }

    /// A completed probe whose encoded outcome is larger than the fixture's control-log bound.
    private func oversizeOutcome(_ harness: RuntimeServiceHarness) throws -> ControlOperationOutcome {
        try upstreamOutcome(harness, name: Self.oversizeName, endpoint: "host")
    }

    /// The production log, with the replay gap at its own level. Event one, then a skipped outcome at boundary one, then event two.
    /// A replay from one would cross the skipped outcome, so it is refused, while a replay from two is clean.
    func testAReplayThatWouldCrossASkippedOutcomeIsRefused() throws {
        var log = RuntimeObservationLog(limits: try RuntimeServiceFixtures.limits(controlLogByteCapacity: Self.oversizeFixtureBound))
        logEvent(&log)
        log.appendControl(finished(1), bytes: Self.oversizeBytes)
        logEvent(&log)
        XCTAssertEqual(log.highWater, 2, "the skipped outcome consumes no event position")
        XCTAssertEqual(log.controlNext, 2, "the skipped sequence is consumed, and nothing is retained")
        XCTAssertNil(log.controlStart(forEvent: 1), "a replay from one holds the skipped outcome at boundary one, so it is refused")
        XCTAssertEqual(log.controlStart(forEvent: 2), 2, "a replay after the skipped boundary has no outcome in range, so it is accepted")
    }

    /// Two skips in a row. The newest lost boundary decides, and a replay that starts after both is clean.
    func testEverySkippedOutcomeRefusesTheReplaysThatReachIt() throws {
        var log = RuntimeObservationLog(limits: try RuntimeServiceFixtures.limits(controlLogByteCapacity: Self.oversizeFixtureBound))
        logEvent(&log)
        log.appendControl(finished(1), bytes: Self.oversizeBytes)
        logEvent(&log)
        log.appendControl(finished(2), bytes: Self.oversizeBytes)
        logEvent(&log)
        XCTAssertNil(log.controlStart(forEvent: 1))
        XCTAssertNil(log.controlStart(forEvent: 2), "the second skip, at boundary two, is in a replay from two")
        XCTAssertEqual(log.controlStart(forEvent: 3), 3, "a replay from three lies after both skipped boundaries")
    }

    /// A retained outcome after a skip is the first outcome of a replay that starts at its boundary. The skip before it is not in that range.
    func testANormalOutcomeAfterASkipIsReplayedFromItsBoundary() throws {
        var log = RuntimeObservationLog(limits: try RuntimeServiceFixtures.limits(controlLogByteCapacity: Self.oversizeFixtureBound))
        logEvent(&log)
        log.appendControl(finished(1), bytes: Self.oversizeBytes)
        logEvent(&log)
        log.appendControl(finished(2), bytes: 100)
        logEvent(&log)
        XCTAssertNil(log.controlStart(forEvent: 1))
        XCTAssertEqual(log.controlStart(forEvent: 2), 2, "the retained outcome at boundary two is the first outcome of this replay")
        XCTAssertEqual(log.controlStart(forEvent: 3), 3, "nothing retained lies at or after position three")
    }

    /// An ordinary eviction records its boundary the same way. Only a replay that reaches the evicted boundary is refused.
    func testAnEvictedOutcomeRefusesOnlyTheReplaysThatReachIt() throws {
        let limits = try RuntimeServiceFixtures.limits(controlLogCapacity: 1, controlLogByteCapacity: Self.oversizeFixtureBound)
        var log = RuntimeObservationLog(limits: limits)
        logEvent(&log)
        log.appendControl(finished(1), bytes: 100)
        logEvent(&log)
        log.appendControl(finished(2), bytes: 100)
        XCTAssertNil(log.controlStart(forEvent: 1), "the evicted outcome at boundary one is in a replay from one")
        XCTAssertEqual(log.controlStart(forEvent: 2), 2, "the evicted boundary is before position two, so the replay from two is clean")
    }

    /// Through the core: a replay that starts before a completed oversize outcome is refused as expired history, never accepted without it.
    /// The outcome itself is still recoverable by lookup, which is a separate path from replay.
    func testAReplayAcrossAnOversizedOutcomeIsRefusedAsExpiredHistory() throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(controlLogByteCapacity: Self.oversizeFixtureBound))
        ingest(harness)
        let operation = try launchProbe(harness)
        let outcome = try oversizeOutcome(harness)
        harness.owner.settle(operation, with: outcome)
        ingest(harness)
        let refused = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(refused.replay, .unavailable(.expiredHistory), "the skipped outcome at boundary one is in this replay's range")
        XCTAssertEqual(try observePull(harness.core, refused.subscriber), .idle, "the refused subscriber reads live from the high-water mark")
        guard case .finished(let recovered) = RuntimeServiceFixtures.lookup(harness.core, operation) else {
            return XCTFail("the skipped outcome stays recoverable by lookup")
        }
        XCTAssertEqual(recovered, outcome)
    }

    /// A replay that starts after a skipped outcome is accepted, and it delivers only the events after its boundary. No outcome is made up for the skip.
    func testAReplayAfterAnOversizedOutcomeDeliversOnlyTheEventsAfterIt() throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(controlLogByteCapacity: Self.oversizeFixtureBound))
        ingest(harness)
        let operation = try launchProbe(harness)
        harness.owner.settle(operation, with: try oversizeOutcome(harness))
        ingest(harness)
        let replay = try XCTUnwrap(try openReplay(harness.core, from: 2))
        XCTAssertEqual(replay.replay, .replay(from: try XCTUnwrap(ControlEventCursor(rawValue: 2)), through: try XCTUnwrap(ControlEventCursor(rawValue: 2))))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .events(count: 1, firstCursor: 2))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .replayCaughtUp(2))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .idle)
    }

    /// A replay that is catching up when a skip lands ends with a resync. Its reader still names the sequence the skip consumed, so it is stale.
    func testAReplayCatchingUpWhenAnOversizedOutcomeLandsEndsWithAResync() throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(
            controlLogByteCapacity: Self.oversizeFixtureBound,
            replayChunkItems: 1
        ))
        ingest(harness)
        ingest(harness)
        let replay = try XCTUnwrap(try openReplay(harness.core, from: 1))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .events(count: 1, firstCursor: 1))
        let operation = try launchProbe(harness)
        harness.owner.settle(operation, with: try oversizeOutcome(harness))
        XCTAssertEqual(try observePull(harness.core, replay.subscriber), .end(.resyncRequired))
        XCTAssertEqual(harness.core.openSubscriberCount, 0)
    }

    /// The same refusal on the framed wire: the baseline answers the replay as expired history, not as a replay without the skipped outcome.
    func testAReplayAcrossAnOversizedOutcomeIsRefusedOnTheFramedWire() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits(controlLogByteCapacity: Self.oversizeFixtureBound))
        ingest(harness)
        let operation = try launchProbe(harness)
        harness.owner.settle(operation, with: try oversizeOutcome(harness))
        ingest(harness)
        let client = try makeClient(harness, frame: try ControlFrameLimits(maxFrameBytes: 8192))
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let resume = ControlSubscriptionRequest.resume(
            incarnation: RuntimeServiceFixtures.incarnation(1),
            from: try XCTUnwrap(ControlEventCursor(rawValue: 1))
        )
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(resume, deadline: deadline) }
        let first = try await subscription.next(deadline)
        guard case .baseline(let baseline) = first else {
            return XCTFail("the first frame is the baseline, got \(first.kind)")
        }
        XCTAssertEqual(baseline.replay, .unavailable(.expiredHistory))
    }
}
