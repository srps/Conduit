// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
import ProxyControlBridge
import ConduitShared

/// The framed client over a bounded scripted transport. Each test decides what the wire did,
/// and the adapter's claims are checked against the exact bytes it sent and the exact frames it
/// accepted. These are adapter contract tests. They say nothing about host fences or retention.
final class FramedRuntimeClientTests: XCTestCase {
    private let limits = try! ControlFrameLimits(maxFrameBytes: 64 * 1024)
    private let minted = ControlRequestID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!)

    // MARK: - Fixtures

    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    private func requestID(_ value: Int) -> ControlRequestID {
        ControlRequestID(rawValue: uuid(value))
    }

    private func incarnation(_ value: Int) -> ControlHostIncarnation {
        ControlHostIncarnation(rawValue: uuid(value))
    }

    private func operation(_ value: Int) -> ControlOperationID {
        ControlOperationID(rawValue: uuid(value))
    }

    private func cursor(_ value: Int) -> ControlEventCursor {
        ControlEventCursor(rawValue: value)!
    }

    private func deadline(_ epoch: ContinuousClock.Instant) -> RuntimeDeadline {
        RuntimeDeadline.after(.seconds(5), from: epoch)
    }

    /// The budget a five-second deadline carries at its own epoch: the whole five seconds, in milliseconds.
    private func fiveSecondBudget() throws -> ControlWireBudget {
        try ControlWireBudget(5_000)
    }

    private func snapshot(incarnation value: Int = 1) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(
            ProxyOrchestratorSnapshot(),
            stamp: ControlRuntimeStamp(
                incarnation: incarnation(value),
                presentationRevision: ControlPresentationRevision(rawValue: 9)!,
                configRevision: ControlConfigRevision(rawValue: 2)!,
                lifecycleRevision: ControlLifecycleRevision(rawValue: 5)!
            ),
            profileName: "Corp",
            collectionRevisions: ControlCollectionRevisions()
        )
    }

    private func baseline() throws -> ControlBaseline {
        try ControlBaseline(
            incarnation: incarnation(1),
            snapshot: try snapshot(),
            highWater: cursor(0),
            replay: .live
        )
    }

    /// One complete frame with its line feed, encoded under the test limits.
    private func frame(_ body: ControlRuntimeBody, correlation: ControlRequestID) throws -> Data {
        try ControlRuntimeCodec.encodeFrame(ControlRuntimeMessage(correlation: correlation, body: body), limits: limits)
    }

    private func baselineFrame(correlation: ControlRequestID? = nil) throws -> Data {
        try frame(.frame(.baseline(try baseline())), correlation: correlation ?? minted)
    }

    private func makeClient(
        _ transport: ScriptedTransport,
        limits: ControlFrameLimits? = nil,
        wireBudgetCap: Duration = .seconds(60),
        epoch: ContinuousClock.Instant,
        now: (@Sendable () -> ContinuousClock.Instant)? = nil
    ) throws -> any RuntimeClient {
        let minted = self.minted
        return try makeFramedRuntimeClient(
            transport: transport,
            limits: limits ?? self.limits,
            wireBudgetCap: wireBudgetCap,
            now: now ?? { epoch },
            makeCorrelation: { minted }
        )
    }

    /// The `RuntimeClientError` a call throws, or nil when it returns.
    private func thrownError<T>(_ body: () async throws -> T) async -> RuntimeClientError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeClientError
        }
    }

    /// The `RuntimeClientError` a call throws when its task is already cancelled as the call starts.
    private func errorWhenCancelled(_ body: @escaping @Sendable () async throws -> Void) async -> RuntimeClientError? {
        await Task { () -> RuntimeClientError? in
            withUnsafeCurrentTask { task in
                if let task { task.cancel() }
            }
            do {
                try await body()
                return nil
            } catch {
                return error as? RuntimeClientError
            }
        }.value
    }

    /// Waits until the scripted stream has a `next` parked on it. No sleeping is involved.
    private func awaitParked(_ stream: ScriptedStream) async {
        var parked = stream.parked.makeAsyncIterator()
        _ = await parked.next()
    }

    // MARK: - Local refusal and the send

    func testAnOversizeRequestIsRefusedLocallyAndNeverSent() async throws {
        let epoch = ContinuousClock.now
        let transport = ScriptedTransport()
        let tiny = try ControlFrameLimits(maxFrameBytes: 64)
        let client = try makeClient(transport, limits: tiny, epoch: epoch)

        let error = await thrownError {
            try await client.submit(.stop(.dns), requestID: requestID(1), expectedIncarnation: incarnation(1), deadline: deadline(epoch))
        }

        XCTAssertEqual(error, .localRefusal(.frameTooLarge))
        XCTAssertEqual(transport.callCount, 0, "a refused request must not reach the transport")
    }

    func testSubmitSendsOneFrameCarryingTheCallersIdentityIncarnationAndCorrelation() async throws {
        let epoch = ContinuousClock.now
        let id = requestID(7)
        let transport = ScriptedTransport(steps: [
            .reply(try frame(.response(.admission(.accepted(operation(9)))), correlation: id)),
        ])
        let client = try makeClient(transport, epoch: epoch)

        let admission = try await client.submit(
            .stop(.dns), requestID: id, expectedIncarnation: incarnation(3), deadline: deadline(epoch)
        )

        XCTAssertEqual(admission, .accepted(operation(9)))
        XCTAssertEqual(transport.callCount, 1)
        let call = try XCTUnwrap(transport.recordedCalls.first)
        XCTAssertEqual(call.limits, limits)
        XCTAssertEqual(call.deadline, deadline(epoch))
        let sent = try ControlRuntimeCodec.decodeFullFrame(call.frame, limits: limits)
        XCTAssertEqual(sent.correlation, id, "a submit is correlated by its request ID")
        let expected = ControlRuntimeBody.request(ControlRuntimeRequest(budget: try fiveSecondBudget(), call: .submit(ControlOperationRequest(
            requestID: id,
            expectedIncarnation: incarnation(3),
            command: .stop(.dns)
        ))))
        XCTAssertEqual(sent.body, expected)
    }

    func testAPossibleSendFailureSendsExactlyOnceAndIsAdmissionUnknownForThatRequest() async throws {
        let epoch = ContinuousClock.now
        let id = requestID(11)
        var oversize = Data(repeating: 0x61, count: limits.maxFrameBytes)
        oversize.append(0x0A)
        var twoFrames = try frame(.response(.admission(.accepted(operation(9)))), correlation: id)
        twoFrames += try frame(.response(.admission(.accepted(operation(9)))), correlation: id)
        var incomplete = try frame(.response(.admission(.accepted(operation(9)))), correlation: id)
        incomplete.removeLast()
        let wrongCorrelation = try frame(.response(.admission(.accepted(operation(9)))), correlation: requestID(12))
        let wrongKind = try frame(.request(ControlRuntimeRequest(budget: try ControlWireBudget(1), call: .readSnapshot)), correlation: id)

        let cases: [(label: String, step: ScriptedTransport.Step, end: RuntimeWaitEnd)] = [
            ("disconnect", .fail(.sent(.disconnected)), .disconnected),
            ("deadline", .fail(.sent(.deadlineExpired)), .deadlineExpired),
            ("cancel", .fail(.sent(.cancelled)), .cancelled),
            ("untyped error", .untyped, .disconnected),
            ("raw deadline", .rawWaitEnd(.deadlineExpired), .deadlineExpired),
            ("raw cancel", .rawWaitEnd(.cancelled), .cancelled),
            ("raw disconnect", .rawWaitEnd(.disconnected), .disconnected),
            ("malformed", .reply(Data("not a frame\n".utf8)), .invalidReply),
            ("incomplete", .reply(incomplete), .invalidReply),
            ("overlimit", .reply(oversize), .invalidReply),
            ("two frames", .reply(twoFrames), .invalidReply),
            ("wrong correlation", .reply(wrongCorrelation), .invalidReply),
            ("wrong kind", .reply(wrongKind), .invalidReply),
        ]
        for testCase in cases {
            let transport = ScriptedTransport(steps: [testCase.step])
            let client = try makeClient(transport, epoch: epoch)
            let error = await thrownError {
                try await client.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(3), deadline: deadline(epoch))
            }
            XCTAssertEqual(error, .admissionUnknown(id, testCase.end), testCase.label)
            XCTAssertEqual(transport.callCount, 1, "\(testCase.label) must not be resent")
        }
    }

    func testANotSentFailureIsNotSentAndAnExpiredDeadlineNeverReachesTheTransport() async throws {
        let epoch = ContinuousClock.now
        let refused = ScriptedTransport(steps: [.fail(.notSent(.disconnected))])
        let refusedClient = try makeClient(refused, epoch: epoch)
        let notSent = await thrownError {
            try await refusedClient.submit(.stop(.dns), requestID: requestID(2), expectedIncarnation: incarnation(1), deadline: deadline(epoch))
        }
        XCTAssertEqual(notSent, .notSent(.disconnected))

        let unused = ScriptedTransport()
        let client = try makeClient(unused, epoch: epoch)
        let expired = RuntimeDeadline.after(.zero, from: epoch)
        let lapsed = await thrownError {
            try await client.submit(.stop(.dns), requestID: requestID(2), expectedIncarnation: incarnation(1), deadline: expired)
        }
        XCTAssertEqual(lapsed, .notSent(.deadlineExpired))
        XCTAssertEqual(unused.callCount, 0, "an expired call is refused before any send")
    }

    func testACancelledTaskIsRefusedBeforeItIsSent() async throws {
        let epoch = ContinuousClock.now
        let transport = ScriptedTransport()
        let client = try makeClient(transport, epoch: epoch)
        let dl = deadline(epoch)
        let result = await Task { () -> RuntimeClientError? in
            withUnsafeCurrentTask { task in
                if let task { task.cancel() }
            }
            do {
                _ = try await client.readSnapshot(deadline: dl)
                return nil
            } catch {
                return error as? RuntimeClientError
            }
        }.value
        XCTAssertEqual(result, .notSent(.cancelled))
        XCTAssertEqual(transport.callCount, 0)
    }

    // MARK: - Raw wait ends and typed refusals

    func testARawWaitEndFromTheTransportKeepsItsReasonForMutationsAndReads() async throws {
        let epoch = ContinuousClock.now
        for end in [RuntimeWaitEnd.deadlineExpired, .cancelled] {
            let id = requestID(20)

            let submitting = ScriptedTransport(steps: [.rawWaitEnd(end)])
            let submitClient = try makeClient(submitting, epoch: epoch)
            let submitError = await thrownError {
                try await submitClient.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(1), deadline: deadline(epoch))
            }
            XCTAssertEqual(submitError, .admissionUnknown(id, end), "\(end): a mutation keeps its request ID and its reason")
            XCTAssertEqual(submitting.callCount, 1, "\(end): a mutation is sent once")

            let looking = ScriptedTransport(steps: [.rawWaitEnd(end)])
            let lookupClient = try makeClient(looking, epoch: epoch)
            let lookupError = await thrownError {
                try await lookupClient.lookupAdmission(of: id, expectedIncarnation: incarnation(1), deadline: deadline(epoch))
            }
            XCTAssertEqual(lookupError, .readAborted(end), "\(end): a lookup is a read")

            let outcomeTransport = ScriptedTransport(steps: [.rawWaitEnd(end)])
            let outcomeClient = try makeClient(outcomeTransport, epoch: epoch)
            let outcomeError = await thrownError {
                try await outcomeClient.outcome(of: operation(9), expectedIncarnation: incarnation(1), deadline: deadline(epoch))
            }
            XCTAssertEqual(outcomeError, .readAborted(end), "\(end): an outcome is a read")

            let pageTransport = ScriptedTransport(steps: [.rawWaitEnd(end)])
            let pageClient = try makeClient(pageTransport, epoch: epoch)
            let pageRequest = ControlPageRequest(expectedIncarnation: incarnation(1), collection: .activeConnections)
            let pageError = await thrownError {
                try await pageClient.readPage(pageRequest, deadline: deadline(epoch))
            }
            XCTAssertEqual(pageError, .readAborted(end), "\(end): a page read is a read")

            let snapshotTransport = ScriptedTransport(steps: [.rawWaitEnd(end)])
            let snapshotClient = try makeClient(snapshotTransport, epoch: epoch)
            let snapshotError = await thrownError { try await snapshotClient.readSnapshot(deadline: deadline(epoch)) }
            XCTAssertEqual(snapshotError, .readAborted(end), "\(end): a snapshot read is a read")
        }
    }

    func testOpeningAStreamKeepsARawWaitReasonAndATypedRefusalAndSendsOnce() async throws {
        let epoch = ContinuousClock.now
        let cases: [(label: String, failure: any Error, expected: RuntimeClientError)] = [
            ("raw deadline", RuntimeWaitEnd.deadlineExpired, .readAborted(.deadlineExpired)),
            ("raw cancel", RuntimeWaitEnd.cancelled, .readAborted(.cancelled)),
            ("typed not sent", ControlRuntimeTransportFailure.notSent(.deadlineExpired), .notSent(.deadlineExpired)),
            ("typed sent", ControlRuntimeTransportFailure.sent(.disconnected), .readAborted(.disconnected)),
            ("untyped", ScriptedTransportError.untyped, .readAborted(.disconnected)),
        ]
        for testCase in cases {
            let transport = ScriptedTransport(openFailure: testCase.failure)
            let client = try makeClient(transport, epoch: epoch)
            let error = await thrownError { try await client.subscribe(.live, deadline: deadline(epoch)) }
            XCTAssertEqual(error, testCase.expected, testCase.label)
            XCTAssertEqual(transport.callCount, 1, "\(testCase.label): the open is sent once and never resent")
        }
    }

    // MARK: - Wire budget

    func testABudgetThatRoundsToZeroSendsNoBytesFromAnyBudgetedCall() async throws {
        let epoch = ContinuousClock.now
        let refused: [(label: String, remaining: Duration, cap: Duration)] = [
            ("no time left", .zero, .seconds(60)),
            ("half a millisecond left", .nanoseconds(500_000), .seconds(60)),
            ("999999 nanoseconds left", .nanoseconds(999_999), .seconds(60)),
            ("a cap of 999999 nanoseconds", .seconds(5), .nanoseconds(999_999)),
        ]
        for testCase in refused {
            let transport = ScriptedTransport()
            let client = try makeClient(transport, wireBudgetCap: testCase.cap, epoch: epoch)
            let lapsing = RuntimeDeadline.after(testCase.remaining, from: epoch)

            let submitError = await thrownError {
                try await client.submit(.stop(.dns), requestID: requestID(30), expectedIncarnation: incarnation(1), deadline: lapsing)
            }
            let lookupError = await thrownError {
                try await client.lookupAdmission(of: requestID(30), expectedIncarnation: incarnation(1), deadline: lapsing)
            }
            let outcomeError = await thrownError {
                try await client.outcome(of: operation(9), expectedIncarnation: incarnation(1), deadline: lapsing)
            }

            XCTAssertEqual(submitError, .notSent(.deadlineExpired), testCase.label)
            XCTAssertEqual(lookupError, .notSent(.deadlineExpired), testCase.label)
            XCTAssertEqual(outcomeError, .notSent(.deadlineExpired), testCase.label)
            XCTAssertEqual(transport.callCount, 0, "\(testCase.label): a zero budget is never sent")
        }
    }

    func testABudgetOfAtLeastOneMillisecondIsSentAndAFractionRoundsDown() async throws {
        let epoch = ContinuousClock.now
        let id = requestID(31)
        let sent: [(label: String, remaining: Duration, cap: Duration, milliseconds: Int)] = [
            ("exactly one millisecond", .milliseconds(1), .seconds(60), 1),
            ("1.9 milliseconds", .nanoseconds(1_900_000), .seconds(60), 1),
            ("a cap of exactly one millisecond", .seconds(5), .milliseconds(1), 1),
        ]
        for testCase in sent {
            let transport = ScriptedTransport(steps: [
                .reply(try frame(.response(.admission(.accepted(operation(9)))), correlation: id)),
            ])
            let client = try makeClient(transport, wireBudgetCap: testCase.cap, epoch: epoch)
            _ = try await client.submit(
                .stop(.dns),
                requestID: id,
                expectedIncarnation: incarnation(3),
                deadline: RuntimeDeadline.after(testCase.remaining, from: epoch)
            )

            let call = try XCTUnwrap(transport.recordedCalls.first)
            let sentFrame = try ControlRuntimeCodec.decodeFullFrame(call.frame, limits: limits)
            let expected = ControlRuntimeBody.request(ControlRuntimeRequest(budget: try ControlWireBudget(testCase.milliseconds), call: .submit(ControlOperationRequest(
                requestID: id,
                expectedIncarnation: incarnation(3),
                command: .stop(.dns)
            ))))
            XCTAssertEqual(sentFrame.body, expected, testCase.label)
        }
    }

    func testACancelledTaskWithAZeroBudgetIsReportedAsCancelledNotAsAnExpiredDeadline() async throws {
        let epoch = ContinuousClock.now
        let transport = ScriptedTransport()
        let client = try makeClient(transport, epoch: epoch)
        let lapsing = RuntimeDeadline.after(.nanoseconds(1), from: epoch)
        let id = requestID(34)
        let expectedIncarnation = incarnation(1)

        let error = await errorWhenCancelled {
            _ = try await client.submit(.stop(.dns), requestID: id, expectedIncarnation: expectedIncarnation, deadline: lapsing)
        }

        XCTAssertEqual(error, .notSent(.cancelled), "cancellation is checked before the budget is read")
        XCTAssertEqual(transport.callCount, 0)
    }

    func testTheBudgetIsReadOnceAndAnExpiryAfterEncodingStillSendsNothing() async throws {
        let epoch = ContinuousClock.now
        let id = requestID(33)
        let oneMillisecond = RuntimeDeadline(instant: epoch.advanced(by: .milliseconds(1)))

        // The clock reads the epoch both for the budget and for the live check, so one millisecond is sent.
        let sending = ScriptedTransport(steps: [
            .reply(try frame(.response(.admission(.accepted(operation(9)))), correlation: id)),
        ])
        let sendingClock = ClockSequence(first: epoch, then: epoch)
        let sendingClient = try makeClient(sending, epoch: epoch, now: { sendingClock.read() })
        _ = try await sendingClient.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(3), deadline: oneMillisecond)
        let sentFrame = try ControlRuntimeCodec.decodeFullFrame(try XCTUnwrap(sending.recordedCalls.first).frame, limits: limits)
        XCTAssertEqual(sentFrame.body, .request(ControlRuntimeRequest(budget: try ControlWireBudget(1), call: .submit(ControlOperationRequest(
            requestID: id,
            expectedIncarnation: incarnation(3),
            command: .stop(.dns)
        )))))

        // The budget reads the epoch and sees one millisecond. The live check reads one millisecond later, after
        // encoding, and sees none. The frame is refused before the transport is called.
        let lapsing = ScriptedTransport()
        let lapsingClock = ClockSequence(first: epoch, then: epoch.advanced(by: .milliseconds(1)))
        let lapsingClient = try makeClient(lapsing, epoch: epoch, now: { lapsingClock.read() })
        let error = await thrownError {
            try await lapsingClient.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(3), deadline: oneMillisecond)
        }
        XCTAssertEqual(error, .notSent(.deadlineExpired))
        XCTAssertEqual(lapsing.callCount, 0, "an expiry after encoding is caught by the live check before any send")
    }

    // MARK: - Replies

    func testAHostFailureWithItsCorrelationIsAWireAnswerAndAnAdmissionRejectionIsAnAnswer() async throws {
        let epoch = ContinuousClock.now
        let id = requestID(4)
        let transport = ScriptedTransport(steps: [
            .reply(try frame(.response(.failure(.invalidValue)), correlation: id)),
            .reply(try frame(.response(.failure(.invalidValue)), correlation: requestID(5))),
            .reply(try frame(.response(.admission(.rejected(.queueFull))), correlation: id)),
        ])
        let client = try makeClient(transport, epoch: epoch)

        let wire = await thrownError {
            try await client.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(1), deadline: deadline(epoch))
        }
        XCTAssertEqual(wire, .wire(.invalidValue), "a failure with the request's correlation is the host's answer")

        let mismatched = await thrownError {
            try await client.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(1), deadline: deadline(epoch))
        }
        XCTAssertEqual(mismatched, .admissionUnknown(id, .invalidReply), "a failure for another correlation is not an answer")

        let rejected = try await client.submit(.stop(.dns), requestID: id, expectedIncarnation: incarnation(1), deadline: deadline(epoch))
        XCTAssertEqual(rejected, .rejected(.queueFull))
    }

    func testAReadAfterAPossibleSendIsReadAbortedWithOneCallAndNoRetry() async throws {
        let epoch = ContinuousClock.now
        let id = requestID(8)
        let transport = ScriptedTransport(steps: [.fail(.sent(.disconnected))])
        let client = try makeClient(transport, epoch: epoch)

        let error = await thrownError {
            try await client.lookupAdmission(of: id, expectedIncarnation: incarnation(4), deadline: deadline(epoch))
        }

        XCTAssertEqual(error, .readAborted(.disconnected))
        XCTAssertEqual(transport.callCount, 1, "a lookup is repeated by its caller, never by the client")
        let call = try XCTUnwrap(transport.recordedCalls.first)
        let sent = try ControlRuntimeCodec.decodeFullFrame(call.frame, limits: limits)
        XCTAssertEqual(sent.correlation, minted, "a lookup is correlated with a minted value, not the request ID")
        let expected = ControlRuntimeBody.request(ControlRuntimeRequest(budget: try fiveSecondBudget(), call: .requestLookup(ControlRequestQuery(
            expectedIncarnation: incarnation(4),
            requestID: id
        ))))
        XCTAssertEqual(sent.body, expected, "the lookup names the incarnation it expects")
    }

    func testAMalformedReadReplyIsUnexpectedAndALocalReadRefusalNeverReachesTheTransport() async throws {
        let epoch = ContinuousClock.now
        let garbled = ScriptedTransport(steps: [.reply(Data("nope\n".utf8))])
        let garbledClient = try makeClient(garbled, epoch: epoch)
        let unexpected = await thrownError {
            try await garbledClient.outcome(of: operation(9), expectedIncarnation: incarnation(4), deadline: deadline(epoch))
        }
        XCTAssertEqual(unexpected, .unexpectedReply)

        let unused = ScriptedTransport()
        let tiny = try makeClient(unused, limits: try ControlFrameLimits(maxFrameBytes: 64), epoch: epoch)
        let refused = await thrownError { try await tiny.readSnapshot(deadline: deadline(epoch)) }
        XCTAssertEqual(refused, .localRefusal(.frameTooLarge))
        XCTAssertEqual(unused.callCount, 0)
    }

    func testASnapshotReadAcceptsOnlyTheSnapshotKind() async throws {
        let epoch = ContinuousClock.now
        let expected = try snapshot()
        let good = ScriptedTransport(steps: [.reply(try frame(.response(.snapshot(expected)), correlation: minted))])
        let returned = try await makeClient(good, epoch: epoch).readSnapshot(deadline: deadline(epoch))
        XCTAssertEqual(returned, expected)

        let wrong = ScriptedTransport(steps: [
            .reply(try frame(.response(.admission(.accepted(operation(1)))), correlation: minted)),
        ])
        let error = await thrownError { try await makeClient(wrong, epoch: epoch).readSnapshot(deadline: deadline(epoch)) }
        XCTAssertEqual(error, .unexpectedReply)
    }

    // MARK: - Subscription

    func testTheFirstStreamFrameMustBeABaselineOrATypedEnd() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let transport = ScriptedTransport(stream: stream)
        let client = try makeClient(transport, epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        stream.deliver(try frame(.frame(.replayCaughtUp(cursor(3))), correlation: minted))

        let early = await thrownError { try await subscription.next(RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)) }
        XCTAssertEqual(early, .unexpectedReply, "a frame before the baseline breaks the stream")
        XCTAssertEqual(stream.cancelCount, 1, "a broken stream is released")
        let again = await thrownError { try await subscription.next(RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)) }
        XCTAssertEqual(again, .unexpectedReply, "a broken stream stays broken")
        XCTAssertEqual(stream.cancelCount, 1)
    }

    func testTheBaselineComesFirstThenFramesInOrderThenATypedEndReleasesOnce() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)
        stream.deliver(try baselineFrame())
        stream.deliver(try frame(.frame(.replayCaughtUp(cursor(3))), correlation: minted))
        stream.deliver(try frame(.frame(.end(ControlStreamEnd(reason: .slowConsumer))), correlation: minted))

        let expectedBaseline = ControlRuntimeFrame.baseline(try baseline())
        let first = try await subscription.next(live)
        XCTAssertEqual(first, expectedBaseline)
        let second = try await subscription.next(live)
        XCTAssertEqual(second, .replayCaughtUp(cursor(3)))
        let closing = await thrownError { try await subscription.next(live) }
        XCTAssertEqual(closing, .streamClosed(.slowConsumer))
        XCTAssertEqual(stream.cancelCount, 1, "a typed end releases the stream")

        subscription.cancel()
        XCTAssertEqual(stream.cancelCount, 1, "a cancel after the end releases nothing again")
        let repeated = await thrownError { try await subscription.next(live) }
        XCTAssertEqual(repeated, .streamClosed(.slowConsumer), "the end is repeated, not replaced")
    }

    func testASnapshotFromAnotherIncarnationEndsTheStreamEvenWithItsCorrelation() async throws {
        let epoch = ContinuousClock.now
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let owned = ScriptedStream()
        let ownedClient = try makeClient(ScriptedTransport(stream: owned), epoch: epoch)
        let ownedSubscription = try await ownedClient.subscribe(.live, deadline: deadline(epoch))
        owned.deliver(try baselineFrame())
        owned.deliver(try frame(.frame(.snapshot(try snapshot(incarnation: 1))), correlation: minted))
        let baselineFirst = try await ownedSubscription.next(live)
        XCTAssertEqual(baselineFirst.kind, .baseline)
        let sameIncarnation = try await ownedSubscription.next(live)
        XCTAssertEqual(sameIncarnation.kind, .snapshot, "a snapshot from the baseline's incarnation is delivered")
        XCTAssertEqual(owned.cancelCount, 0)

        let foreign = ScriptedStream()
        let foreignClient = try makeClient(ScriptedTransport(stream: foreign), epoch: epoch)
        let foreignSubscription = try await foreignClient.subscribe(.live, deadline: deadline(epoch))
        foreign.deliver(try baselineFrame())
        foreign.deliver(try frame(.frame(.snapshot(try snapshot(incarnation: 2))), correlation: minted))
        _ = try await foreignSubscription.next(live)
        let error = await thrownError { try await foreignSubscription.next(live) }
        XCTAssertEqual(error, .unexpectedReply, "a snapshot from another incarnation is refused despite its correlation")
        XCTAssertEqual(foreign.cancelCount, 1, "the stream is released")
        let again = await thrownError { try await foreignSubscription.next(live) }
        XCTAssertEqual(again, .unexpectedReply)
    }

    func testAnExplicitCancelWinsOverATimeoutThatEndsTheWaitAfterIt() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        stream.setWakesOnCancel(false)
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        subscription.cancel()
        stream.fireDeadline()

        let error = await thrownError { try await waiting.value }
        XCTAssertEqual(error, .readAborted(.cancelled), "the first terminal state is the cancel, not the later timeout")
        XCTAssertEqual(stream.cancelCount, 1)
    }

    func testACancellationErrorIsACancelledWaitAndKeepsTheStreamAndItsNextFrame() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)
        stream.deliver(try baselineFrame())
        let first = try await subscription.next(live)
        XCTAssertEqual(first.kind, .baseline)

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        stream.fail(with: CancellationError())
        let error = await thrownError { try await waiting.value }
        XCTAssertEqual(error, .readAborted(.cancelled), "a cancelled task is a cancelled wait, not a disconnect")
        XCTAssertEqual(stream.cancelCount, 0, "a cancelled wait does not release a valid stream")

        stream.deliver(try frame(.frame(.replayCaughtUp(cursor(3))), correlation: minted))
        let next = try await subscription.next(live)
        XCTAssertEqual(next, .replayCaughtUp(cursor(3)), "the frame after the cancelled wait is still delivered")
        XCTAssertEqual(stream.cancelCount, 0)
    }

    func testADisconnectAfterAnExplicitCancelKeepsTheCancelAsTheFirstTerminal() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        stream.setWakesOnCancel(false)
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        subscription.cancel()
        stream.fail(with: RuntimeWaitEnd.disconnected)

        let error = await thrownError { try await waiting.value }
        XCTAssertEqual(error, .readAborted(.cancelled))
        XCTAssertEqual(stream.cancelCount, 1, "the cancel released the stream once, and the disconnect released nothing more")
    }

    func testAnUncancelledDisconnectIsTerminalAndReleasesTheStreamOnce() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        stream.fail(with: RuntimeWaitEnd.disconnected)

        let error = await thrownError { try await waiting.value }
        XCTAssertEqual(error, .readAborted(.disconnected))
        XCTAssertEqual(stream.cancelCount, 1)
        let again = await thrownError { try await subscription.next(live) }
        XCTAssertEqual(again, .readAborted(.disconnected), "the terminal error is repeated")
        XCTAssertEqual(stream.cancelCount, 1)
    }

    func testAStreamFrameWithAnotherCorrelationBreaksAndCancelsTheStream() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        stream.deliver(try baselineFrame(correlation: requestID(99)))

        let error = await thrownError { try await subscription.next(RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)) }

        XCTAssertEqual(error, .unexpectedReply)
        XCTAssertEqual(stream.cancelCount, 1)
    }

    func testAnOversizeOrConcatenatedStreamFrameBreaksTheStream() async throws {
        let epoch = ContinuousClock.now
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        var oversize = Data(repeating: 0x61, count: limits.maxFrameBytes)
        oversize.append(0x0A)
        let overStream = ScriptedStream()
        let overClient = try makeClient(ScriptedTransport(stream: overStream), epoch: epoch)
        let overSubscription = try await overClient.subscribe(.live, deadline: deadline(epoch))
        overStream.deliver(oversize)
        let overError = await thrownError { try await overSubscription.next(live) }
        XCTAssertEqual(overError, .unexpectedReply)
        XCTAssertEqual(overStream.cancelCount, 1)

        let twoStream = ScriptedStream()
        let twoClient = try makeClient(ScriptedTransport(stream: twoStream), epoch: epoch)
        let twoSubscription = try await twoClient.subscribe(.live, deadline: deadline(epoch))
        twoStream.deliver(try baselineFrame() + baselineFrame())
        let twoError = await thrownError { try await twoSubscription.next(live) }
        XCTAssertEqual(twoError, .unexpectedReply, "a concatenated frame is never split and accepted")
        XCTAssertEqual(twoStream.cancelCount, 1)
    }

    func testANextDeadlineLeavesTheFrameAvailableWhetherItExpiresBeforeOrDuringTheWait() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)
        stream.deliver(try baselineFrame())

        let lapsed = await thrownError { try await subscription.next(RuntimeDeadline.after(.zero, from: epoch)) }
        XCTAssertEqual(lapsed, .readAborted(.deadlineExpired))
        XCTAssertEqual(stream.cancelCount, 0, "a deadline does not close a valid stream")
        let first = try await subscription.next(live)
        XCTAssertEqual(first.kind, .baseline, "the frame the lapsed wait did not take is still there")

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        stream.fireDeadline()
        let timedOut = await thrownError { try await waiting.value }
        XCTAssertEqual(timedOut, .readAborted(.deadlineExpired))
        stream.deliver(try frame(.frame(.replayCaughtUp(cursor(4))), correlation: minted))
        let next = try await subscription.next(live)
        XCTAssertEqual(next, .replayCaughtUp(cursor(4)))
        XCTAssertEqual(stream.cancelCount, 0)
    }

    func testCancelReleasesTheStreamOnceAndNeverReachesTheHost() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let transport = ScriptedTransport(stream: stream)
        let client = try makeClient(transport, epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))

        subscription.cancel()
        subscription.cancel()

        XCTAssertEqual(stream.cancelCount, 1)
        XCTAssertEqual(transport.callCount, 1, "only the subscribe was sent; a cancel is local")
        let after = await thrownError { try await subscription.next(RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)) }
        XCTAssertEqual(after, .readAborted(.cancelled))
    }

    func testDroppingTheLastHandleReleasesTheStreamOnce() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)

        _ = try await client.subscribe(.live, deadline: deadline(epoch))

        XCTAssertEqual(stream.cancelCount, 1, "dropping the handle is the same release as cancelling it")
    }

    func testAConcurrentNextIsRefusedAsReadInProgressWithoutTouchingTheStream() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let first = Task { try await subscription.next(live) }
        await awaitParked(stream)
        let refused = await thrownError { try await subscription.next(live) }
        XCTAssertEqual(refused, .readInProgress)

        stream.deliver(try baselineFrame())
        let delivered = try await first.value
        XCTAssertEqual(delivered.kind, .baseline, "the first read still gets the frame")
        XCTAssertEqual(stream.cancelCount, 0)
    }

    func testCancelWhileANextIsWaitingWakesItAsCancelledAndReleasesOnce() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        subscription.cancel()

        let error = await thrownError { try await waiting.value }
        XCTAssertEqual(error, .readAborted(.cancelled))
        XCTAssertEqual(stream.cancelCount, 1)
        subscription.cancel()
        XCTAssertEqual(stream.cancelCount, 1)
    }

    func testAFrameThatLandsAfterCancelIsDroppedAndNeverDelivered() async throws {
        let epoch = ContinuousClock.now
        let stream = ScriptedStream()
        stream.setWakesOnCancel(false)
        let client = try makeClient(ScriptedTransport(stream: stream), epoch: epoch)
        let subscription = try await client.subscribe(.live, deadline: deadline(epoch))
        let live = RuntimeDeadline.after(.seconds(60), from: ContinuousClock.now)

        let waiting = Task { try await subscription.next(live) }
        await awaitParked(stream)
        subscription.cancel()
        stream.deliver(try baselineFrame())

        let error = await thrownError { try await waiting.value }
        XCTAssertEqual(error, .readAborted(.cancelled), "the frame that raced the cancel is not handed to the caller")
        XCTAssertEqual(stream.cancelCount, 1)
    }

    // MARK: - Full-frame codec

    func testAFullFrameDecodesOnlyAsOneFrameWithItsLineFeed() throws {
        let valid = try frame(.request(ControlRuntimeRequest(budget: try ControlWireBudget(1), call: .readSnapshot)), correlation: requestID(1))
        XCTAssertNoThrow(try ControlRuntimeCodec.decodeFullFrame(valid, limits: limits))

        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(valid + valid, limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage, "a concatenated frame is never split")
        }
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(Data(valid.dropLast()), limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameIncomplete)
        }
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(Data(), limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameIncomplete)
        }
        let tiny = try ControlFrameLimits(maxFrameBytes: 64)
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(valid, limits: tiny)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge, "size is checked before anything parses")
        }
    }

    func testAnInteriorLineFeedIsRefusedByThePayloadCheckAfterSizeAndTheTrailingFeed() throws {
        let valid = try frame(.request(ControlRuntimeRequest(budget: try ControlWireBudget(1), call: .readSnapshot)), correlation: requestID(1))
        var split = valid
        split.insert(0x0A, at: 1)
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(split, limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage, "a raw line feed inside the payload is never parsed")
        }

        // The payload check runs before the version is read, so a version this build does not speak is still malformed here.
        let unsupported = Data("{\"version\":99,\n\"kind\":\"request\"}\n".utf8)
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(unsupported, limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage)
        }

        var oversize = Data(repeating: 0x61, count: limits.maxFrameBytes)
        oversize[10] = 0x0A
        oversize.append(0x0A)
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(oversize, limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge, "size still comes before the line feed checks")
        }

        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFullFrame(Data("{\n}".utf8), limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameIncomplete, "a missing trailing feed is reported before an interior one")
        }
    }

    func testConstructionRefusesABudgetCapThatIsNotPositive() throws {
        XCTAssertThrowsError(try makeFramedRuntimeClient(transport: ScriptedTransport(), limits: limits, wireBudgetCap: .zero))
        XCTAssertThrowsError(try makeFramedRuntimeClient(transport: ScriptedTransport(), limits: limits, wireBudgetCap: .seconds(-1)))
        XCTAssertThrowsError(try ControlFrameLimits(maxFrameBytes: 1))
    }
}

// MARK: - Test doubles

private enum ScriptedTransportError: Error {
    case unscripted
    case untyped
    case overCapacity
}

/// A clock whose first read returns `first` and whose later reads return `then`. A test uses it to decide
/// what the budget read and the live check each see.
private final class ClockSequence: @unchecked Sendable {
    private let lock = NSLock()
    private let first: ContinuousClock.Instant
    private let then: ContinuousClock.Instant
    private var didReadFirst = false

    init(first: ContinuousClock.Instant, then: ContinuousClock.Instant) {
        self.first = first
        self.then = then
    }

    func read() -> ContinuousClock.Instant {
        lock.withLock {
            if didReadFirst { return then }
            didReadFirst = true
            return first
        }
    }
}

/// A bounded scripted transport. Each exchange takes the next scripted step, so a test decides what
/// the wire did. Calls are recorded up to a fixed capacity, and a call beyond it is refused.
private final class ScriptedTransport: ControlRuntimeTransport, @unchecked Sendable {
    enum Step: Sendable {
        case reply(Data)
        case fail(ControlRuntimeTransportFailure)
        /// Throws a raw wait end, which is not a typed transport failure. The adapter keeps its reason as a possible send.
        case rawWaitEnd(RuntimeWaitEnd)
        /// Throws an error that is not typed, which the adapter must count as a possible send.
        case untyped
    }

    struct Call: Sendable {
        let frame: Data
        let limits: ControlFrameLimits
        let deadline: RuntimeDeadline
    }

    private static let callCapacity = 8
    private let lock = NSLock()
    private var steps: [Step]
    private var calls: [Call] = []
    private let openFailure: (any Error)?
    private let stream: ScriptedStream

    init(
        steps: [Step] = [],
        openFailure: (any Error)? = nil,
        stream: ScriptedStream = ScriptedStream()
    ) {
        self.steps = steps
        self.openFailure = openFailure
        self.stream = stream
    }

    var callCount: Int { lock.withLock { calls.count } }
    var recordedCalls: [Call] { lock.withLock { calls } }

    func exchange(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> Data {
        let step = try lock.withLock { () throws -> Step in
            guard calls.count < Self.callCapacity else { throw ScriptedTransportError.overCapacity }
            calls.append(Call(frame: request, limits: limits, deadline: deadline))
            guard !steps.isEmpty else { throw ScriptedTransportError.unscripted }
            return steps.removeFirst()
        }
        switch step {
        case .reply(let bytes): return bytes
        case .fail(let failure): throw failure
        case .rawWaitEnd(let end): throw end
        case .untyped: throw ScriptedTransportError.untyped
        }
    }

    func openStream(_ request: Data, limits: ControlFrameLimits, deadline: RuntimeDeadline) async throws -> ControlRuntimeStream {
        try lock.withLock { () throws -> Void in
            guard calls.count < Self.callCapacity else { throw ScriptedTransportError.overCapacity }
            calls.append(Call(frame: request, limits: limits, deadline: deadline))
        }
        if let openFailure { throw openFailure }
        let stream = self.stream
        return ControlRuntimeStream(
            next: { waitDeadline in try await stream.next(waitDeadline) },
            cancel: { stream.cancel() }
        )
    }
}

/// A scripted stream whose waits the test controls. A `next` parks until the test delivers a frame,
/// fires the deadline, or cancels, which is how a transport's timer and cancellation would act.
private final class ScriptedStream: @unchecked Sendable {
    /// One signal per parked wait, so a test can see that a `next` is in flight without sleeping.
    let parked: AsyncStream<Void>
    private let parkedSignal: AsyncStream<Void>.Continuation
    private let lock = NSLock()
    private var queued: [Data] = []
    private var waiter: CheckedContinuation<Data, any Error>?
    private var cancels = 0
    private var wakesOnCancel = true

    init() {
        let made = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(4))
        parked = made.stream
        parkedSignal = made.continuation
    }

    var cancelCount: Int { lock.withLock { cancels } }

    func setWakesOnCancel(_ value: Bool) {
        lock.withLock { wakesOnCancel = value }
    }

    /// Returns the next frame, or waits for one. A passed deadline or a prior cancel ends the call
    /// without taking a queued frame.
    func next(_ deadline: RuntimeDeadline) async throws -> Data {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
            let immediate = lock.withLock { () -> Result<Data, any Error>? in
                if cancels > 0 { return .failure(RuntimeWaitEnd.cancelled) }
                if deadline.remaining(at: ContinuousClock.now) <= .zero { return .failure(RuntimeWaitEnd.deadlineExpired) }
                if !queued.isEmpty { return .success(queued.removeFirst()) }
                waiter = continuation
                return nil
            }
            guard let immediate else {
                parkedSignal.yield(())
                return
            }
            continuation.resume(with: immediate)
        }
    }

    /// Hands a frame to the parked wait, or queues it for the next one.
    func deliver(_ frame: Data) {
        let parked = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            guard let parked = waiter else {
                queued.append(frame)
                return nil
            }
            waiter = nil
            return parked
        }
        parked?.resume(returning: frame)
    }

    /// The transport's deadline fires for a parked wait. No frame is consumed.
    func fireDeadline() {
        fail(with: RuntimeWaitEnd.deadlineExpired)
    }

    /// Ends a parked wait with the given error, as a transport would for a timer, a cancelled task or a disconnect.
    func fail(with error: any Error) {
        let parked = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume(throwing: error)
    }

    /// The transport's release. It counts every call, and it wakes a parked wait unless the test
    /// has turned that off to model a frame that lands just as the handle is cancelled.
    func cancel() {
        let parked = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            cancels += 1
            guard wakesOnCancel else { return nil }
            let parked = waiter
            waiter = nil
            return parked
        }
        parked?.resume(throwing: RuntimeWaitEnd.cancelled)
    }
}
