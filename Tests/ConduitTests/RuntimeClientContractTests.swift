// SPDX-License-Identifier: Apache-2.0
import XCTest
import Synchronization
import ConduitShared

/// The client contract: deadline hand-off, the approved command set, admission separate
/// from settlement, incarnation-scoped references and lookups, the pull subscription
/// handle, and byte-budgeted pages.
final class RuntimeClientContractTests: XCTestCase {
    private func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value))!
    }

    private func incarnation(_ value: Int) -> ControlHostIncarnation {
        ControlHostIncarnation(rawValue: uuid(value))
    }

    private func revision(_ value: Int) -> ControlCollectionRevision {
        ControlCollectionRevision(rawValue: value)!
    }

    private func row(_ index: Int, nameLength: Int = 12) -> ControlUpstreamRow {
        ControlUpstreamRow(
            id: ControlUpstreamID(rawValue: uuid(index)),
            name: "corp-\(index)" + String(repeating: "n", count: max(0, nameLength - 8)),
            endpoint: "proxy\(index).corp.example.test:8080",
            circuitState: .closed,
            ewmaLatencyMilliseconds: try! ControlNonNegativeNumber(12.5),
            consecutiveFailures: try! ControlCount(0),
            openUntil: nil
        )
    }

    private func upstreamReply(_ message: ControlRuntimeMessage) throws -> ControlCollectionPage<ControlUpstreamRow> {
        guard case .response(.page(.upstreamHealth(let page))) = message.body else {
            throw ControlRuntimeWireError.invalidValue
        }
        return page
    }

    // MARK: - Deadlines

    func testDeadlineHandsOverWhatRemainsNotAFreshBudget() throws {
        let start = ContinuousClock.now
        let deadline = RuntimeDeadline.after(.seconds(2), from: start)
        let later = start.advanced(by: .milliseconds(500))

        XCTAssertEqual(deadline.remaining(at: later), .milliseconds(1_500))
        XCTAssertEqual(try deadline.wireBudget(at: later, cappedAt: .seconds(60)).rawValue, 1_500)
    }

    func testWireBudgetIsCappedAndRoundsDownToWholeMilliseconds() throws {
        let start = ContinuousClock.now
        let deadline = RuntimeDeadline.after(.microseconds(1_234_999), from: start)
        XCTAssertEqual(try deadline.wireBudget(at: start, cappedAt: .seconds(60)).rawValue, 1_234)

        let long = RuntimeDeadline.after(.seconds(30), from: start)
        XCTAssertEqual(try long.wireBudget(at: start, cappedAt: .seconds(1)).rawValue, 1_000)
    }

    func testAnExpiredDeadlineSendsZeroAndAHugeOneClampsToTheWireRange() throws {
        let start = ContinuousClock.now
        let deadline = RuntimeDeadline.after(.seconds(1), from: start)
        XCTAssertEqual(try deadline.wireBudget(at: start.advanced(by: .seconds(5)), cappedAt: .seconds(60)).rawValue, 0)

        let huge = RuntimeDeadline.after(.seconds(4_000_000_000), from: start)
        XCTAssertEqual(
            try huge.wireBudget(at: start, cappedAt: .seconds(4_000_000_000)).rawValue,
            Int(Int32.max)
        )
    }

    func testANegativeCapIsRefusedBeforeItIsMultipliedEvenAfterTheDeadline() throws {
        let start = ContinuousClock.now
        let deadline = RuntimeDeadline.after(.seconds(10), from: start)
        // Seconds times a thousand would overflow for this cap, so it must be refused first.
        XCTAssertThrowsError(try deadline.wireBudget(at: start, cappedAt: .seconds(Int64.min))) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .invalidValue)
        }
        XCTAssertThrowsError(try deadline.wireBudget(at: start, cappedAt: .nanoseconds(-1)))
        XCTAssertThrowsError(try deadline.wireBudget(at: start.advanced(by: .seconds(20)), cappedAt: .seconds(Int64.min)))
    }

    func testWireBudgetBoundaryFixtures() throws {
        let start = ContinuousClock.now
        let deadline = RuntimeDeadline.after(.milliseconds(1), from: start)
        XCTAssertEqual(try deadline.wireBudget(at: start, cappedAt: .zero).rawValue, 0)
        XCTAssertEqual(try deadline.wireBudget(at: start, cappedAt: .microseconds(999)).rawValue, 0)
        XCTAssertEqual(try deadline.wireBudget(at: start, cappedAt: .milliseconds(1)).rawValue, 1)
        XCTAssertEqual(try deadline.wireBudget(at: start, cappedAt: .seconds(Int64.max)).rawValue, 1)
    }

    func testAWaitEndedBeforeASendIsNotSentAndAfterOneIsAdmissionUnknown() {
        let id = ControlRequestID(rawValue: uuid(12))
        // A disconnect before a send admitted nothing. The same disconnect after a possible
        // send leaves admission unknown, and neither reason turns into the other.
        XCTAssertNotEqual(RuntimeClientError.notSent(.disconnected), .admissionUnknown(id, .disconnected))
        XCTAssertNotEqual(RuntimeClientError.admissionUnknown(id, .deadlineExpired), .admissionUnknown(id, .disconnected))
        XCTAssertNotEqual(RuntimeClientError.admissionUnknown(id, .invalidReply), .admissionUnknown(id, .cancelled))
    }

    // MARK: - Commands and admission

    /// The ordinary commands, with the login-item administration as the one write: it saves a single platform flag and applies nothing.
    /// Start and configuration apply stay off this wire; they travel on the private editor request.
    func testTheApprovedCommandSetExcludesStartAndConfigApply() throws {
        XCTAssertEqual(
            ControlRuntimeCommandKind.allCases.map(\.rawValue),
            ["stop", "restart", "test-dns", "test-upstream", "refresh-preflight", "set-launch-at-login"]
        )
        let decoder = JSONDecoder()
        XCTAssertThrowsError(try decoder.decode(ControlRuntimeCommand.self, from: Data(#"{"type":"start","module":"proxy"}"#.utf8)))
        XCTAssertThrowsError(try decoder.decode(ControlRuntimeCommand.self, from: Data(#"{"type":"apply-config"}"#.utf8)))
    }

    func testAdmissionAndLookupStatesStayDistinctFromSettlement() throws {
        let operation = ControlOperationID(rawValue: uuid(5))
        let admissions: [ControlAdmission] = [
            .accepted(operation), .joined(operation), .rejected(.queueFull), .rejected(.hostStopping),
        ]
        for admission in admissions {
            let data = try JSONEncoder().encode(admission)
            XCTAssertEqual(try JSONDecoder().decode(ControlAdmission.self, from: data), admission)
        }

        let lookups: [ControlOperationLookup] = [
            .pending,
            .finished(.completed(try ControlCompletion(
                command: .stop,
                presentationRevision: ControlPresentationRevision(rawValue: 12)!,
                result: .settled
            ))),
            .finished(.superseded(by: ControlOperationID(rawValue: uuid(6)))),
            .finished(.failed(.cleanupIncomplete)),
            .unknown(.expiredHistory),
            .unknown(.changedIncarnation),
            .unknown(.notRecorded),
        ]
        for lookup in lookups {
            let data = try JSONEncoder().encode(lookup)
            XCTAssertEqual(try JSONDecoder().decode(ControlOperationLookup.self, from: data), lookup)
        }
    }

    func testARequestLookupRecoversALostAdmissionWithoutImplyingANewOne() throws {
        // After a lost ACK the caller learns the admission the host recorded. Each answer
        // keeps its meaning: an admission names the operation to read, while unknown is
        // never proof that nothing ran.
        let recovered: [ControlRequestLookup] = [
            .admission(.accepted(ControlOperationID(rawValue: uuid(8)))),
            .admission(.joined(ControlOperationID(rawValue: uuid(8)))),
            .admission(.rejected(.deadlineExpired)),
            .unknown(.expiredHistory),
            .unknown(.changedIncarnation),
            .unknown(.notRecorded),
        ]
        for lookup in recovered {
            let data = try JSONEncoder().encode(lookup)
            XCTAssertEqual(try JSONDecoder().decode(ControlRequestLookup.self, from: data), lookup)
        }
    }

    func testUnknownReasonsUseTheirStableSpellings() {
        XCTAssertEqual(ControlUnknownOutcomeReason.expiredHistory.rawValue, "expired_history")
        XCTAssertEqual(ControlUnknownOutcomeReason.changedIncarnation.rawValue, "changed_incarnation")
        XCTAssertEqual(ControlUnknownOutcomeReason.notRecorded.rawValue, "not_recorded")
    }

    func testEveryRejectionAndFailureCodeHasSanitizedDescriptionText() {
        for code in ControlRejectionCode.allCases {
            XCTAssertFalse(code.humanDescription.isEmpty)
        }
        for code in ControlFailureCode.allCases {
            XCTAssertFalse(code.humanDescription.isEmpty)
        }
    }

    func testAPartialOutcomeNamesModulesAndClaimsNoAppliedSurface() throws {
        let outcome = ControlOperationOutcome.partiallyCompleted(try ControlModuleOutcomes([
            ControlModuleOutcome(module: .dns, result: .succeeded),
            ControlModuleOutcome(module: .tunnels, result: .failed(.effectFailed)),
        ]))
        let text = String(decoding: try JSONEncoder().encode(outcome), as: UTF8.self)
        XCTAssertTrue(text.contains(#""type":"partiallyCompleted""#))
        XCTAssertTrue(text.contains(#""module":"dns""#))
        XCTAssertFalse(text.contains("surface"), "module results are not applied-surface evidence")
        XCTAssertFalse(text.contains("applied"), "module results are not applied-surface evidence")
        XCTAssertEqual(try JSONDecoder().decode(ControlOperationOutcome.self, from: Data(text.utf8)), outcome)
    }

    func testEachObservationCommandSettlesWithItsOwnResult() throws {
        let revision = try XCTUnwrap(ControlPresentationRevision(rawValue: 4))
        let dns = try ControlCompletion(
            command: .testDNS,
            presentationRevision: revision,
            result: .dnsLiveness(ControlDNSLivenessProbe(port: try ControlPort(53), answered: true))
        )
        let stamp = ControlRuntimeStamp(
            incarnation: incarnation(1),
            presentationRevision: revision,
            configRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 1)),
            lifecycleRevision: try XCTUnwrap(ControlLifecycleRevision(rawValue: 1))
        )
        let preflight = try ControlCompletion(
            command: .refreshPreflight,
            presentationRevision: revision,
            result: .preflight(ControlPreflightObservation(
                stamp: stamp,
                observedAt: try ControlTimestamp(1_700_000_000),
                reading: .unavailable(.busy)
            ))
        )
        for completion in [dns, preflight] {
            let data = try JSONEncoder().encode(completion)
            XCTAssertEqual(try JSONDecoder().decode(ControlCompletion.self, from: data), completion)
        }
    }

    // MARK: - Incarnation scope

    func testAPageRequestFromAnotherIncarnationIsNotThisOne() throws {
        // A restarted host's revisions and cursors can repeat. The incarnation is what tells
        // them apart, so a page request cannot be decoded without one.
        let old = ControlPageRequest(expectedIncarnation: incarnation(1), collection: .upstreamHealth)
        let new = ControlPageRequest(expectedIncarnation: incarnation(2), collection: .upstreamHealth)
        XCTAssertNotEqual(old, new)
        let withoutIncarnation = #"{"collection":"upstreamHealth"}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ControlPageRequest.self, from: Data(withoutIncarnation.utf8)))
    }

    func testALiveSubscriptionCarriesNoMutationOrIncarnation() throws {
        // A live subscription bootstraps the incarnation from its baseline, so it sends
        // nothing that could change host state.
        let text = String(decoding: try JSONEncoder().encode(ControlSubscriptionRequest.live), as: UTF8.self)
        XCTAssertEqual(text, #"{"type":"live"}"#)
    }

    // MARK: - Client protocol and subscription handle

    func testANoTransportClientRefusesEveryCallAsNotSent() async {
        // Compile conformance only: this stand-in shows the protocol can be met without a
        // transport. It is not production behaviour. It sends nothing, so every call is
        // refused as not sent and none carries a host's answer. A refused lookup says nothing
        // about whether an earlier submit ran; only a live host can answer that.
        let client: any RuntimeClient = NoTransportRuntimeClient()
        let deadline = RuntimeDeadline.after(.seconds(1), from: ContinuousClock.now)
        let requestID = ControlRequestID(rawValue: uuid(9))
        let operationID = ControlOperationID(rawValue: uuid(9))

        await assertNotSent {
            _ = try await client.submit(.stop(.dns), requestID: requestID, expectedIncarnation: incarnation(1), deadline: deadline)
        }
        await assertNotSent {
            _ = try await client.lookupAdmission(of: requestID, expectedIncarnation: incarnation(1), deadline: deadline)
        }
        await assertNotSent {
            _ = try await client.outcome(of: operationID, expectedIncarnation: incarnation(1), deadline: deadline)
        }
        await assertNotSent {
            _ = try await client.subscribe(.live, deadline: deadline)
        }
        await assertNotSent {
            _ = try await client.readPage(ControlPageRequest(expectedIncarnation: incarnation(1), collection: .upstreamHealth), deadline: deadline)
        }
        await assertNotSent {
            _ = try await client.readSnapshot(deadline: deadline)
        }
    }

    private func assertNotSent<T>(
        _ call: () async throws -> T,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await call()
            XCTFail("a client with no transport must not return an answer", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? RuntimeClientError, .notSent(.disconnected), file: file, line: line)
        }
    }

    func testSubscriptionIsAPullHandleWhoseCancelReleasesItsRegistration() async throws {
        let cancelled = Mutex(false)
        let subscription = RuntimeSubscription(
            next: { _ in .end(ControlStreamEnd(reason: .hostShutdown)) },
            cancel: { cancelled.withLock { $0 = true } }
        )
        let frame = try await subscription.next(RuntimeDeadline.after(.seconds(1), from: ContinuousClock.now))
        XCTAssertEqual(frame, .end(ControlStreamEnd(reason: .hostShutdown)))
        XCTAssertFalse(cancelled.withLock { $0 })

        subscription.cancel()
        XCTAssertTrue(cancelled.withLock { $0 })
    }

    // MARK: - Byte-budgeted pages

    func testPagesCoverEveryRowOnceInOrderAndEachFitsTheFrame() throws {
        let rows = (0..<40).map { row($0, nameLength: 60) }
        let frame = try ControlFrameLimits(maxFrameBytes: 2_048)
        var collected: [ControlUpstreamRow] = []
        var offset = 0
        var pages = 0

        while true {
            let message = try ControlPagePacker.page(
                of: rows,
                offset: offset,
                incarnation: incarnation(1),
                revision: revision(3),
                correlation: ControlRequestID(rawValue: uuid(10)),
                limits: frame,
                wrap: ControlPageReply.upstreamHealth
            )
            _ = try ControlRuntimeCodec.encodeFrame(message, limits: frame)
            let page = try upstreamReply(message)
            XCTAssertEqual(page.totalCount.rawValue, rows.count)
            XCTAssertEqual(page.offset.rawValue, offset)
            XCTAssertEqual(page.incarnation, incarnation(1))
            collected += page.rows
            pages += 1
            guard let next = page.nextCursor else { break }
            XCTAssertEqual(next.revision, revision(3))
            XCTAssertEqual(next.offset.rawValue, offset + page.rows.count)
            offset = next.offset.rawValue
        }

        XCTAssertEqual(collected, rows)
        XCTAssertGreaterThan(pages, 1, "a 2 KiB frame cannot hold 40 of these rows")
    }

    func testARowThatCannotFitAloneIsAnExplicitOversizeNotASkip() throws {
        let frame = try ControlFrameLimits(maxFrameBytes: 512)
        let huge = row(1, nameLength: 2_000)
        XCTAssertThrowsError(try ControlPagePacker.page(
            of: [huge],
            offset: 0,
            incarnation: incarnation(1),
            revision: revision(1),
            correlation: ControlRequestID(rawValue: uuid(10)),
            limits: frame,
            wrap: ControlPageReply.upstreamHealth
        )) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge)
        }
    }

    func testAPageAtTheEndIsEmptyCompleteAndHasNoCursor() throws {
        let rows = [row(1), row(2)]
        let frame = try ControlFrameLimits(maxFrameBytes: 16 * 1024)
        let message = try ControlPagePacker.page(
            of: rows,
            offset: 2,
            incarnation: incarnation(1),
            revision: revision(4),
            correlation: ControlRequestID(rawValue: uuid(10)),
            limits: frame,
            wrap: ControlPageReply.upstreamHealth
        )
        let page = try upstreamReply(message)
        XCTAssertEqual(page.rows, [])
        XCTAssertNil(page.nextCursor)
        XCTAssertEqual(page.status, .current)
        XCTAssertThrowsError(try ControlPagePacker.page(
            of: rows,
            offset: 3,
            incarnation: incarnation(1),
            revision: revision(4),
            correlation: ControlRequestID(rawValue: uuid(10)),
            limits: frame,
            wrap: ControlPageReply.upstreamHealth
        ))
    }

    func testAPageRefusesCountsThatDisagreeWithItsContinuation() throws {
        let rowValue = row(1)
        let one = try ControlCount(1)
        let two = try ControlCount(2)
        let zero = try ControlCount(0)

        XCTAssertThrowsError(try ControlCollectionPage(
            incarnation: incarnation(1), revision: revision(1), offset: zero, totalCount: two, rows: [rowValue],
            nextCursor: nil, status: .current
        ), "one row of two with no continuation is incomplete")

        XCTAssertThrowsError(try ControlCollectionPage(
            incarnation: incarnation(1), revision: revision(1), offset: zero, totalCount: two, rows: [rowValue],
            nextCursor: ControlPageCursor(revision: revision(2), offset: one), status: .current
        ), "a continuation must name the page's own revision")

        XCTAssertThrowsError(try ControlCollectionPage(
            incarnation: incarnation(1), revision: revision(1), offset: zero, totalCount: one, rows: [rowValue],
            nextCursor: ControlPageCursor(revision: revision(1), offset: one), status: .current
        ), "a continuation past the end has nothing to continue to")

        XCTAssertThrowsError(try ControlCollectionPage(
            incarnation: incarnation(1), revision: revision(1), offset: zero, totalCount: two, rows: [rowValue],
            nextCursor: nil, status: .unavailable(.notCaptured)
        ), "an unavailable page carries no rows")

        XCTAssertNoThrow(try ControlCollectionPage(
            incarnation: incarnation(1), revision: revision(1), offset: zero, totalCount: two, rows: [rowValue],
            nextCursor: ControlPageCursor(revision: revision(1), offset: one), status: .current
        ))
    }

    func testAPageDecodedFromInconsistentBytesIsRefused() {
        let json = #"{"incarnation":"00000000-0000-0000-0000-000000000001","revision":1,"offset":0,"totalCount":2,"rows":[],"status":{"type":"current"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ControlCollectionPage<ControlUpstreamRow>.self, from: Data(json.utf8)))
    }

    func testAPageWithoutItsIncarnationIsRefused() {
        let json = #"{"revision":1,"offset":0,"totalCount":0,"rows":[],"status":{"type":"current"}}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ControlCollectionPage<ControlUpstreamRow>.self, from: Data(json.utf8)))
    }
}

/// A client with no transport. Every call is refused as not sent, so it answers nothing. It
/// shows the protocol can be met without a transport; it is not production behaviour.
private struct NoTransportRuntimeClient: RuntimeClient {
    func submit(
        _ command: ControlRuntimeCommand,
        requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlAdmission {
        throw RuntimeClientError.notSent(.disconnected)
    }

    func lookupAdmission(
        of requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlRequestLookup {
        throw RuntimeClientError.notSent(.disconnected)
    }

    func outcome(
        of operation: ControlOperationID,
        expectedIncarnation: ControlHostIncarnation,
        deadline: RuntimeDeadline
    ) async throws -> ControlOperationLookup {
        throw RuntimeClientError.notSent(.disconnected)
    }

    func subscribe(_ request: ControlSubscriptionRequest, deadline: RuntimeDeadline) async throws -> RuntimeSubscription {
        throw RuntimeClientError.notSent(.disconnected)
    }

    func readPage(_ request: ControlPageRequest, deadline: RuntimeDeadline) async throws -> ControlPageReply {
        throw RuntimeClientError.notSent(.disconnected)
    }

    func readSnapshot(deadline: RuntimeDeadline) async throws -> ControlRuntimeSnapshot {
        throw RuntimeClientError.notSent(.disconnected)
    }
}
