// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import ConduitShared
@testable import Conduit
@testable import ProxyKernel

/// Frames a test hands the observer's one subscription, one at a time.
private final class FrameFeed: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [ControlRuntimeFrame] = []
    private var waiting: CheckedContinuation<ControlRuntimeFrame, Error>?

    func push(_ frame: ControlRuntimeFrame) {
        let resumed = lock.withLock { () -> CheckedContinuation<ControlRuntimeFrame, Error>? in
            if let waiting {
                self.waiting = nil
                return waiting
            }
            frames.append(frame)
            return nil
        }
        resumed?.resume(returning: frame)
    }

    func next() async throws -> ControlRuntimeFrame {
        try await withCheckedThrowingContinuation { continuation in
            let ready = lock.withLock { () -> ControlRuntimeFrame? in
                if !frames.isEmpty { return frames.removeFirst() }
                waiting = continuation
                return nil
            }
            if let ready { continuation.resume(returning: ready) }
        }
    }

    func end() {
        let resumed = lock.withLock { () -> CheckedContinuation<ControlRuntimeFrame, Error>? in
            defer { waiting = nil }
            return waiting
        }
        resumed?.resume(throwing: RuntimeClientError.readAborted(.cancelled))
    }

    /// Whether every pushed frame was handed to the reader.
    var isDrained: Bool { lock.withLock { frames.isEmpty && waiting != nil } }

    /// The stream fails as a lost transport does: the observer clears its claims and subscribes again.
    func lose() {
        let resumed = lock.withLock { () -> CheckedContinuation<ControlRuntimeFrame, Error>? in
            defer { waiting = nil }
            return waiting
        }
        resumed?.resume(throwing: RuntimeClientError.notSent(.transportBusy))
    }
}

/// The answers the stub's operation lookups give, in order; `.pending` once the script is spent. A nil entry is a lookup the transport
/// refused, as a busy read lane does. Counts every lookup.
private final class LookupScript: @unchecked Sendable {
    private let lock = NSLock()
    private var answers: [ControlOperationLookup?]
    private var made = 0

    init(_ answers: [ControlOperationLookup?] = []) {
        self.answers = answers
    }

    var lookups: Int { lock.withLock { made } }

    func next() throws -> ControlOperationLookup {
        let answer = lock.withLock { () -> ControlOperationLookup?? in
            made += 1
            return answers.isEmpty ? .some(.pending) : answers.removeFirst()
        }
        guard case .some(.some(let lookup)) = answer else { throw RuntimeClientError.notSent(.transportBusy) }
        return lookup
    }
}

/// A client whose lookups answer as the script says and whose one subscription delivers what the test pushes. Nothing else is called.
private struct StubClient: RuntimeClient {
    let feed: FrameFeed
    var script = LookupScript()

    func submit(_ command: ControlRuntimeCommand, requestID: ControlRequestID, expectedIncarnation: ControlHostIncarnation,
                deadline: RuntimeDeadline) async throws -> ControlAdmission { .rejected(.notImplemented) }
    func lookupAdmission(of requestID: ControlRequestID, expectedIncarnation: ControlHostIncarnation,
                         deadline: RuntimeDeadline) async throws -> ControlRequestLookup { .unknown(.notRecorded) }
    func outcome(of operation: ControlOperationID, expectedIncarnation: ControlHostIncarnation,
                 deadline: RuntimeDeadline) async throws -> ControlOperationLookup { try script.next() }
    func subscribe(_ request: ControlSubscriptionRequest, deadline: RuntimeDeadline) async throws -> RuntimeSubscription {
        RuntimeSubscription(next: { [feed] _ in try await feed.next() }, cancel: { [feed] in feed.end() })
    }
    func readPage(_ request: ControlPageRequest, deadline: RuntimeDeadline) async throws -> ControlPageReply {
        .unavailable(request.collection, .notCaptured, knownTotal: nil)
    }
    func readSnapshot(deadline: RuntimeDeadline) async throws -> ControlRuntimeSnapshot {
        throw RuntimeClientError.notSent(.transportBusy)
    }
}

/// The observer's settlement table: callers of one joined operation share its outcome, a cancelled caller ends alone, the caller bound
/// refuses past it, and stopping resolves every caller unsettled.
@MainActor
final class RuntimeObserverSettlementTests: XCTestCase {
    private func observer(_ feed: FrameFeed) -> RuntimeObserver {
        RuntimeObserver(
            control: StubClient(feed: feed), presentation: RuntimePresentationAdapter(),
            incarnation: ControlHostIncarnation(rawValue: UUID()), rowBudget: ControlRowBudget(maxRows: 10, maxBytes: 1_024)
        )
    }

    private func waitForCallers(_ tasks: [Task<ControlOperationOutcome?, Never>]) async {
        // Each caller has made its one lookup and registered once the main actor has turned a few times.
        for _ in 0..<20 { await Task.yield() }
    }

    func testCallersOfOneJoinedOperationShareItsOutcome() async {
        let feed = FrameFeed()
        let observer = observer(feed)
        observer.start()
        let operation = ControlOperationID(rawValue: UUID())
        let first = Task { await observer.settlement(of: operation) }
        let second = Task { await observer.settlement(of: operation) }
        await waitForCallers([first, second])
        feed.push(.operationFinished(ControlOperationFinished(operationID: operation, outcome: .failed(.storeBusy))))
        let outcomes = [await first.value, await second.value]
        XCTAssertEqual(outcomes, [.failed(.storeBusy), .failed(.storeBusy)])
        observer.stop()
    }

    func testACancelledCallerEndsAloneAndTheOtherStillReceivesTheOutcome() async {
        let feed = FrameFeed()
        let observer = observer(feed)
        observer.start()
        let operation = ControlOperationID(rawValue: UUID())
        let cancelled = Task { await observer.settlement(of: operation) }
        let kept = Task { await observer.settlement(of: operation) }
        await waitForCallers([cancelled, kept])
        cancelled.cancel()
        let cancelledOutcome = await cancelled.value
        XCTAssertNil(cancelledOutcome)
        feed.push(.operationFinished(ControlOperationFinished(operationID: operation, outcome: .failed(.effectFailed))))
        let keptOutcome = await kept.value
        XCTAssertEqual(keptOutcome, .failed(.effectFailed))
        observer.stop()
    }

    func testTheCallerBoundRefusesPastItAndStopResolvesEveryCallerUnsettled() async {
        let feed = FrameFeed()
        let observer = observer(feed)
        observer.start()
        var callers: [Task<ControlOperationOutcome?, Never>] = []
        for _ in 0..<RuntimeObserver.maximumCallers {
            let operation = ControlOperationID(rawValue: UUID())
            callers.append(Task { await observer.settlement(of: operation) })
        }
        await waitForCallers(callers)
        let refused = await observer.settlement(of: ControlOperationID(rawValue: UUID()))
        XCTAssertNil(refused, "past the bound a caller is answered at once, unsettled")
        observer.stop()
        for caller in callers {
            let outcome = await caller.value
            XCTAssertNil(outcome)
        }
        let afterStop = await observer.settlement(of: ControlOperationID(rawValue: UUID()))
        XCTAssertNil(afterStop)
    }

    private func observer(_ feed: FrameFeed, script: LookupScript, relookup: Duration) -> RuntimeObserver {
        RuntimeObserver(
            control: StubClient(feed: feed, script: script), presentation: RuntimePresentationAdapter(),
            incarnation: WireSnapshotFixture.incarnation, rowBudget: ControlRowBudget(maxRows: 10, maxBytes: 1_024),
            relookupInterval: relookup
        )
    }

    /// The race the review named: the settlement frame is read before the caller watches, so the stream will never carry it again, and
    /// the caller's own lookup is refused busy. No later frame can help; the caller looks its own operation up again after an interval
    /// and gets the known outcome. Nothing polls status.
    func testASettlementReadBeforeTheWatchWithABusyLookupIsFoundByTheOperationsOwnRelookup() async {
        let feed = FrameFeed()
        let script = LookupScript([nil, .finished(.failed(.storeBusy))])
        let observer = observer(feed, script: script, relookup: .milliseconds(50))
        observer.start()
        let operation = ControlOperationID(rawValue: UUID())
        feed.push(.operationFinished(ControlOperationFinished(operationID: operation, outcome: .failed(.storeBusy))))
        // The reader took the frame and is waiting for the next one: the settlement was read, with no caller to keep it.
        for _ in 0..<2_000 where !feed.isDrained { try? await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(feed.isDrained)
        let outcome = await observer.settlement(of: operation)
        XCTAssertEqual(outcome, .failed(.storeBusy))
        XCTAssertEqual(script.lookups, 2, "one busy lookup, then the operation's own relookup")
        observer.stop()
    }

    /// A lookup that never answers ends the wait unsettled after a bounded number of relookups: the caller never hangs, and an unknown
    /// end is not a guess.
    func testAWaitWhoseLookupsNeverAnswerEndsUnsettledAfterItsBound() async {
        let feed = FrameFeed()
        let script = LookupScript(Array(repeating: nil, count: 1 + RuntimeObserver.relookupRounds))
        let observer = observer(feed, script: script, relookup: .milliseconds(20))
        observer.start()
        let begun = ContinuousClock.now
        let outcome = await observer.settlement(of: ControlOperationID(rawValue: UUID()))
        XCTAssertNil(outcome)
        XCTAssertEqual(script.lookups, 1 + RuntimeObserver.relookupRounds)
        XCTAssertLessThan(begun.duration(to: .now), .seconds(5))
        observer.stop()
    }

    /// A slow operation the host keeps answering `pending` for is waited for past the relookup bound, which counts only lookups that failed
    /// in a row: a pending answer starts that count again, so failures it separates never add up to the bound. The wait ends with the
    /// operation's own outcome.
    func testAnOperationTheHostReportsPendingIsWaitedForPastTheRelookupBound() async {
        let feed = FrameFeed()
        let failures = [ControlOperationLookup?](repeating: nil, count: RuntimeObserver.relookupRounds - 1)
        let pending = [ControlOperationLookup?](repeating: .pending, count: RuntimeObserver.relookupRounds + 1)
        let script = LookupScript([nil] + failures + pending + failures + [.finished(.failed(.effectFailed))])
        let observer = observer(feed, script: script, relookup: .milliseconds(20))
        observer.start()
        let outcome = await observer.settlement(of: ControlOperationID(rawValue: UUID()))
        XCTAssertEqual(outcome, .failed(.effectFailed), "pending is the host still holding the operation, not a lookup that failed")
        XCTAssertEqual(script.lookups, 1 + 2 * failures.count + pending.count + 1)
        observer.stop()
    }

    /// The stream is lost while a caller waits: the observer clears its claims, subscribes again, and after the new baseline looks every
    /// waiting operation up, so a settlement published while no stream was open is not missed.
    func testAfterAStreamLossTheNewBaselineLooksUpEveryWaitingOperation() async throws {
        let feed = FrameFeed()
        let script = LookupScript([.pending, .finished(.failed(.effectFailed))])
        let presentation = RuntimePresentationAdapter()
        let observer = RuntimeObserver(
            control: StubClient(feed: feed, script: script), presentation: presentation,
            incarnation: WireSnapshotFixture.incarnation, rowBudget: ControlRowBudget(maxRows: 10, maxBytes: 1_024)
        )
        observer.start()
        let operation = ControlOperationID(rawValue: UUID())
        let caller = Task { await observer.settlement(of: operation) }
        for _ in 0..<20 { await Task.yield() }
        feed.lose()
        for _ in 0..<20 { await Task.yield() }
        XCTAssertNotEqual(presentation.observation, .live, "a lost stream claims nothing")
        feed.push(.baseline(try ControlBaseline(
            incarnation: WireSnapshotFixture.incarnation, snapshot: try WireSnapshotFixture.snapshot(ProxyOrchestratorSnapshot()),
            highWater: ControlEventCursor(rawValue: 0)!, replay: .live
        )))
        let outcome = await caller.value
        XCTAssertEqual(outcome, .failed(.effectFailed))
        XCTAssertEqual(presentation.observation, .live)
        observer.stop()
    }
}
