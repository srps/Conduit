// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
import ProxyKernel

/// The transport's wait lifetimes: parked pulls, timers, waiter cleanup, the single pull slot, first frames and terminal
/// cleanup. The owner, the timers and the hops are all manual, so each state is reached by an explicit step, and every
/// wait for an asynchronous end is bounded on an observable state.
final class RuntimeServiceLifetimeTests: XCTestCase {
    private let lifecycle = ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!
    private let frameLimits = try! ControlFrameLimits(maxFrameBytes: 64 * 1024)

    @RuntimeActor private func makeClient(_ harness: RuntimeServiceHarness, _ transport: RuntimeInMemoryTransport) throws -> any RuntimeClient {
        let epoch = harness.timing.now
        return try makeFramedRuntimeClient(
            transport: transport,
            limits: frameLimits,
            wireBudgetCap: .seconds(60),
            now: { epoch },
            makeCorrelation: { ControlRequestID(rawValue: UUID()) }
        )
    }

    /// The error a call ended with, when it ended with one.
    @RuntimeActor private func thrownError<T>(_ body: () async throws -> T) async -> RuntimeClientError? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeClientError
        }
    }

    /// The transport-level end of a direct stream call, when it ended with one.
    @RuntimeActor private func thrownWaitEnd<T>(_ body: () async throws -> T) async -> RuntimeWaitEnd? {
        do {
            _ = try await body()
            return nil
        } catch {
            return error as? RuntimeWaitEnd
        }
    }

    /// Ends what a failed step left pending, without awaiting it. The manual clock never fires a deadline and a held cancellation never
    /// completes on its own, so awaiting the caller after a failed step could hang the suite instead of failing the test.
    @RuntimeActor private func abandonAfterFailure(_ harness: RuntimeServiceHarness, cancel: () -> Void) {
        cancel()
        harness.timing.releaseHeldCancellations()
        harness.timing.fireAll()
        harness.scheduling.drainAll()
        harness.timing.releaseHeldCancellations()
    }

    /// Opens one live subscription directly on the transport, and runs the open's owner hop.
    @RuntimeActor private func openStreamDirectly(_ harness: RuntimeServiceHarness, _ transport: RuntimeInMemoryTransport) async throws -> ControlRuntimeStream {
        let frame = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(7),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(5_000), call: .subscribe(.live)))
            ),
            limits: frameLimits
        )
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let limits = frameLimits
        return try await runCall(harness.scheduling) {
            try await transport.openStream(frame, limits: limits, deadline: deadline)
        }
    }

    // MARK: - Park, timeout, refill

    @RuntimeActor func testAParkedPullTimesOutThenItsRegistrationIsCleanedBeforeTheNextPullParks() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        _ = try await subscription.next(deadline)

        let parked = Task { try await subscription.next(deadline) }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 1, "the pull parked on its registration")
        let armed = await awaitState { harness.timing.armedTimerCount == 1 }
        XCTAssertTrue(armed)
        guard queued, armed else { return abandonAfterFailure(harness) { parked.cancel(); subscription.cancel() } }

        harness.timing.fireAll()
        let timedOut = await thrownError { try await parked.value }
        XCTAssertEqual(timedOut, .readAborted(.deadlineExpired))
        XCTAssertEqual(harness.scheduling.pendingCount, 1, "the registration's cleanup is queued")
        XCTAssertEqual(harness.core.parkedWaiterCount, 1, "the registration is held until its cleanup hop runs")
        let refill = await thrownError { try await subscription.next(deadline) }
        XCTAssertEqual(refill, .readAborted(.transportBusy), "a refill while the registration is held is busy, and it consumes nothing")

        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 0, "the cleanup removed exactly this pull's registration")
        // The timer part ends at the end of its task body, which runs after the caller resumed. The pull is refused until then.
        let released = await awaitState { transport.lanes.inFlight(.stream) == 0 }
        XCTAssertTrue(released, "the reservation releases once the timer task has ended")
        let again = Task { try await subscription.next(deadline) }
        let againQueued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(againQueued)
        guard againQueued else { return abandonAfterFailure(harness) { again.cancel(); subscription.cancel() } }
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 1, "the next pull parks instead of reporting busy")

        subscription.cancel()
        harness.scheduling.drainAll()
        _ = await thrownError { try await again.value }
    }

    // MARK: - Abandoning after a failed gate

    /// A guard that returns after a failed gate leaves no suspended pull, so its test fails instead of hanging the suite. A pull whose
    /// task has not started is still abandoned: the task inherits this actor, so it cannot start before the test suspends.
    @RuntimeActor func testAPullAbandonedBeforeItStartedEnds() async throws {
        final class Answered: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var value: Bool { lock.withLock { done } }
            func set() { lock.withLock { done = true } }
        }
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        _ = try await subscription.next(deadline)

        let started = Answered()
        let ended = Answered()
        let parked = Task {
            started.set()
            defer { ended.set() }
            _ = try await subscription.next(deadline)
        }
        XCTAssertFalse(started.value, "the pull has not started: its task inherits this actor, which the test still holds")

        abandonAfterFailure(harness) {
            parked.cancel()
            subscription.cancel()
        }
        let pullEnded = await awaitState { ended.value }
        XCTAssertTrue(pullEnded, "the abandoned pull ends instead of staying suspended")
    }

    /// The state a missed `fireAll` leaves: the pull is parked on its registration and its timer is armed, and nothing fires it.
    @RuntimeActor func testAParkedPullAbandonedWithItsTimerUnfiredEnds() async throws {
        final class Answered: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var value: Bool { lock.withLock { done } }
            func set() { lock.withLock { done = true } }
        }
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        _ = try await subscription.next(deadline)

        let ended = Answered()
        let parked = Task {
            defer { ended.set() }
            _ = try await subscription.next(deadline)
        }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 1, "the pull parked on its registration")
        let armed = await awaitState { harness.timing.armedTimerCount == 1 }
        XCTAssertTrue(armed)
        guard queued, armed else { return abandonAfterFailure(harness) { parked.cancel(); subscription.cancel() } }

        // No `fireAll`: a timer that armed just after its gate leaves exactly this state.
        abandonAfterFailure(harness) {
            parked.cancel()
            subscription.cancel()
        }
        let pullEnded = await awaitState { ended.value }
        XCTAssertTrue(pullEnded, "the abandoned pull ends although its timer was never fired")
    }

    @RuntimeActor func testAStalledOwnerHoldsItsReservationsAndRefillsAreBoundedByTheLane() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let lifecycle = self.lifecycle
        let incarnation = RuntimeServiceFixtures.incarnation(1)

        for id in 1...2 {
            let deadline = RuntimeDeadline.after(.seconds(1), from: harness.timing.now)
            let call = Task {
                try await client.submit(.restart(.proxy, ifLifecycleRevision: lifecycle), requestID: RuntimeServiceFixtures.requestID(id), expectedIncarnation: incarnation, deadline: deadline)
            }
            let armed = await awaitState { harness.timing.armedTimerCount == 1 }
            XCTAssertTrue(armed)
            guard armed else { return abandonAfterFailure(harness) { call.cancel() } }
            harness.timing.fireAll()
            let outcome = await thrownError { try await call.value }
            XCTAssertEqual(outcome, .notSent(.deadlineExpired), "the owner never claimed the call")
        }
        XCTAssertEqual(transport.lanes.inFlight(.ordinary), 2, "each timed-out call still holds its queued hop")
        XCTAssertEqual(harness.scheduling.pendingCount, 2, "queued hops are bounded by the lane")

        let refusedDeadline = RuntimeDeadline.after(.seconds(1), from: harness.timing.now)
        let refused = await thrownError {
            try await client.submit(.restart(.dns, ifLifecycleRevision: lifecycle), requestID: RuntimeServiceFixtures.requestID(3), expectedIncarnation: incarnation, deadline: refusedDeadline)
        }
        XCTAssertEqual(refused, .notSent(.transportBusy), "a full lane refuses before any hop or timer is made")
        XCTAssertEqual(harness.scheduling.pendingCount, 2, "the refusal queued nothing")

        harness.timing.advance(by: .seconds(2))
        harness.scheduling.drainAll()
        let laneFree = await awaitState { transport.lanes.inFlight(.ordinary) == 0 }
        XCTAssertTrue(laneFree, "expired hops release their lane once their timers have ended")
        XCTAssertEqual(harness.owner.fenceLog.count, 0, "an expired hop never reached the owner")

        let liveDeadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let live = try await runCall(harness.scheduling) {
            try await client.submit(.restart(.dns, ifLifecycleRevision: lifecycle), requestID: RuntimeServiceFixtures.requestID(4), expectedIncarnation: incarnation, deadline: liveDeadline)
        }
        guard case .accepted = live else { return XCTFail("a fresh call with a live deadline is admitted, got \(live)") }
    }

    // MARK: - Budget refusal under a stalled owner

    /// One budgeted call whose budget, shorter than the caller's deadline, ends while the owner is stalled: its round's hop is queued and
    /// left un-run. The timer makes the typed refusal before any claim, so it reaches the caller at once while the hop still holds the
    /// lane; draining the hop then runs the round unclaimed and releases the lane. It returns the caller's bytes, or nil after a failed
    /// step, having ended what that step left pending instead of awaiting it.
    @RuntimeActor private func budgetRefusalUnderAStalledOwner(
        _ harness: RuntimeServiceHarness,
        _ transport: RuntimeInMemoryTransport,
        lane: RuntimeLane,
        _ call: @escaping @Sendable () async throws -> Data
    ) async throws -> Data? {
        final class Answered: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var value: Bool { lock.withLock { done } }
            func set() { lock.withLock { done = true } }
        }
        let answered = Answered()
        let caller = Task {
            let bytes = try await call()
            answered.set()
            return bytes
        }
        // The call's own signals: its budget timer armed, and its one round queued in the seam.
        let queued = await awaitState { harness.timing.armedTimerCount == 1 && harness.scheduling.pendingCount == 1 }
        XCTAssertTrue(queued, "the call armed its budget timer and queued its round")
        guard queued else {
            abandonAfterFailure(harness) { caller.cancel() }
            return nil
        }

        // Past the budget and short of the caller's deadline. The round stays in the seam: the owner is stalled.
        harness.timing.advance(by: .seconds(1))
        harness.timing.fireAll()
        let detached = await awaitState { answered.value }
        XCTAssertTrue(detached, "the typed budget refusal returns while the stalled owner still holds the round")
        XCTAssertEqual(harness.scheduling.pendingCount, 1, "the round's hop has not run")
        XCTAssertEqual(transport.lanes.inFlight(lane), 1, "the queued hop still holds the lane")
        guard detached else {
            abandonAfterFailure(harness) { caller.cancel() }
            return nil
        }
        let refusal = try await caller.value

        harness.scheduling.drainAll()
        let released = await awaitState { transport.lanes.inFlight(lane) == 0 }
        XCTAssertTrue(released, "the lane releases once the round has run unclaimed and the timer has ended")
        return refusal
    }

    @RuntimeActor func testASubmitBudgetRefusalReturnsWhileTheStalledOwnerStillHoldsItsRound() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let limits = frameLimits
        let id = 21
        let frame = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(id),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(500), call: .submit(ControlOperationRequest(
                    requestID: RuntimeServiceFixtures.requestID(id),
                    expectedIncarnation: RuntimeServiceFixtures.incarnation(1),
                    command: .restart(.proxy, ifLifecycleRevision: lifecycle)
                ))))
            ),
            limits: limits
        )
        // The caller's deadline is past the request's budget, so the budget is the bound and its end is the typed refusal.
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let answer = try await budgetRefusalUnderAStalledOwner(harness, transport, lane: .ordinary) {
            try await transport.exchange(frame, limits: limits, deadline: deadline)
        }
        guard let refusal = answer else { return }

        let decoded = try ControlRuntimeCodec.decodeFullFrame(refusal, limits: limits)
        XCTAssertEqual(decoded.body, .response(.admission(.rejected(.deadlineExpired))), "the submit's typed budget refusal")
        XCTAssertTrue(harness.owner.fenceLog.isEmpty, "the drained round ran unclaimed and never reached the owner")
        let lookup = try RuntimeServiceFixtures.lookupRequest(harness.core, id)
        XCTAssertEqual(lookup, .unknown(.notRecorded), "nothing was admitted")
    }

    @RuntimeActor func testAnOpenBudgetRefusalReturnsWhileTheStalledOwnerStillHoldsItsRound() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let limits = frameLimits
        let frame = try ControlRuntimeCodec.encodeFrame(
            ControlRuntimeMessage(
                correlation: RuntimeServiceFixtures.requestID(22),
                body: .request(ControlRuntimeRequest(budget: try ControlWireBudget(500), call: .subscribe(.live)))
            ),
            limits: limits
        )
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        // An open's budget refusal is its stream's first frame, which the caller takes without an owner hop.
        let answer = try await budgetRefusalUnderAStalledOwner(harness, transport, lane: .read) {
            let stream = try await transport.openStream(frame, limits: limits, deadline: deadline)
            return try await stream.next(deadline)
        }
        guard let refusal = answer else { return }

        let decoded = try ControlRuntimeCodec.decodeFullFrame(refusal, limits: limits)
        XCTAssertEqual(decoded.body, .response(.failure(.deadlineExpired)), "the open's typed budget refusal")
        XCTAssertEqual(harness.core.openSubscriberCount, 0, "the drained round ran unclaimed and registered no subscriber")
    }

    // MARK: - Cancelled timers and cleanup

    @RuntimeActor func testACancelledWaitKeepsItsReservationUntilItsTimerAndItsCleanupQuiesce() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        _ = try await subscription.next(deadline)
        harness.timing.holdCancelledCompletions()

        let parked = Task { try await subscription.next(deadline) }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 1)
        let armed = await awaitState { harness.timing.armedTimerCount == 1 }
        XCTAssertTrue(armed)
        guard queued, armed else { return abandonAfterFailure(harness) { parked.cancel(); subscription.cancel() } }

        parked.cancel()
        let cancelled = await thrownError { try await parked.value }
        XCTAssertEqual(cancelled, .readAborted(.cancelled))
        let held = await awaitState { harness.timing.heldCancellationCount == 1 }
        XCTAssertTrue(held, "the cancelled timer's completion is held")
        XCTAssertEqual(harness.scheduling.pendingCount, 1, "the registration's cleanup is queued")
        XCTAssertEqual(transport.lanes.inFlight(.stream), 1, "the timer and the cleanup still hold the reservation")
        guard held else { return abandonAfterFailure(harness) { subscription.cancel() } }
        let refusedWhileHeld = await thrownError { try await subscription.next(deadline) }
        XCTAssertEqual(refusedWhileHeld, .readAborted(.transportBusy))

        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 0, "the cleanup ran")
        XCTAssertEqual(transport.lanes.inFlight(.stream), 1, "the held cancellation still holds the timer part")
        let refusedAfterCleanup = await thrownError { try await subscription.next(deadline) }
        XCTAssertEqual(refusedAfterCleanup, .readAborted(.transportBusy))

        harness.timing.releaseHeldCancellations()
        let released = await awaitState { transport.lanes.inFlight(.stream) == 0 }
        XCTAssertTrue(released, "the reservation releases once the timer ends")
        subscription.cancel()
        harness.scheduling.drainAll()
    }

    /// The same successful handoff on a capacity-one lane: an answered Stop returns only once its reservation has released, so the next
    /// Stop of the module is admitted at once, not refused busy. A Stop's lane holds one slot per module.
    @RuntimeActor func testAnAnsweredStopReturnsOnlyAfterItsReservationReleasedSoTheNextStopIsNotBusy() async throws {
        final class Answered: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var value: Bool { lock.withLock { done } }
            func set() { lock.withLock { done = true } }
        }
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let incarnation = RuntimeServiceFixtures.incarnation(1)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        XCTAssertEqual(harness.limits.stopLaneCapacityPerModule, 1)
        harness.timing.holdCancelledCompletions()

        let answered = Answered()
        let first = Task {
            let admission = try await client.submit(.stop(.proxy), requestID: RuntimeServiceFixtures.requestID(11), expectedIncarnation: incarnation, deadline: deadline)
            answered.set()
            return admission
        }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        harness.scheduling.drainAll()
        let held = await awaitState { harness.timing.heldCancellationCount == 1 }
        XCTAssertTrue(held, "the answered Stop cancelled its timer, whose completion is held")
        XCTAssertFalse(answered.value, "the caller is not answered while the timer still holds the Stop's slot")
        XCTAssertEqual(transport.lanes.inFlight(.stop(.proxy)), 1)
        guard queued, held else { return abandonAfterFailure(harness) { first.cancel() } }

        harness.timing.releaseHeldCancellations()
        _ = try await first.value
        XCTAssertEqual(transport.lanes.inFlight(.stop(.proxy)), 0, "the slot was returned before the caller was answered")

        let second = Task {
            try await client.submit(.stop(.proxy), requestID: RuntimeServiceFixtures.requestID(12), expectedIncarnation: incarnation, deadline: deadline)
        }
        let secondQueued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(secondQueued, "the next Stop reserved the slot and queued its round, not refused busy")
        harness.scheduling.drainAll()
        let secondHeld = await awaitState { harness.timing.heldCancellationCount == 1 }
        XCTAssertTrue(secondHeld)
        guard secondQueued, secondHeld else { return abandonAfterFailure(harness) { second.cancel() } }
        harness.timing.releaseHeldCancellations()
        _ = try await second.value
        harness.scheduling.drainAll()
    }

    /// The ticket's complete release: a waiter that named no part to keep resumes only after the final end has returned the lane slot
    /// and its release callback has returned, whether it registered before that end or arrived while the release was in progress. The
    /// callback is held on a bounded gate; the gate is always opened, so a failure cannot strand the callback's thread.
    @RuntimeActor func testSettledWaitsUntilTheReleaseCallbackHasReturned() async throws {
        final class Flag: @unchecked Sendable {
            private let lock = NSLock()
            private var set = false
            var value: Bool { lock.withLock { set } }
            func mark() { lock.withLock { set = true } }
        }
        let harness = try RuntimeServiceHarness()
        let lanes = RuntimeLaneCounter(limits: harness.limits)
        for arrivesDuringRelease in [false, true] {
            let entered = DispatchSemaphore(value: 0)
            let gate = DispatchSemaphore(value: 0)
            defer { gate.signal() }
            let callbackReturned = Flag()
            let ticket = try XCTUnwrap(lanes.reserve(.read, onQuiesced: {
                entered.signal()
                _ = gate.wait(timeout: .now() + 5)
                callbackReturned.mark()
            }))
            let resumed = Flag()
            var waiter: Task<Void, Never>?
            if !arrivesDuringRelease {
                waiter = Task { await ticket.settled(leaving: []); resumed.mark() }
                for _ in 0..<100 { await Task.yield() }
            }
            DispatchQueue.global().async { ticket.end(.timer) }
            XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the final end began the release and entered its callback")
            if arrivesDuringRelease {
                waiter = Task { await ticket.settled(leaving: []); resumed.mark() }
            }
            for _ in 0..<100 { await Task.yield() }
            XCTAssertFalse(resumed.value, "settled stays suspended while the release callback runs (arrives during release: \(arrivesDuringRelease))")
            XCTAssertFalse(ticket.isReleased, "the release is not complete until its callback has returned")
            XCTAssertEqual(lanes.inFlight(.read), 0, "the lane slot was returned before the callback")

            gate.signal()
            await waiter?.value
            XCTAssertTrue(callbackReturned.value, "the waiter resumed only after the callback returned")
            XCTAssertTrue(resumed.value)
            XCTAssertTrue(ticket.isReleased)
        }
    }

    /// A pull that delivers returns only once its reservation has fully released, as an answered private exchange does: with its
    /// cancelled timer's completion held, its caller is not answered; once that completes, the answer arrives with the lane slot already
    /// returned and the pull slot free, so the next pull succeeds at once, with no wait or retry in the caller.
    @RuntimeActor func testADeliveredPullReturnsOnlyAfterItsReservationReleasedSoTheNextPullSucceeds() async throws {
        final class Answered: @unchecked Sendable {
            private let lock = NSLock()
            private var done = false
            var value: Bool { lock.withLock { done } }
            func set() { lock.withLock { done = true } }
        }
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let client = try makeClient(harness, transport)
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let subscription = try await runCall(harness.scheduling) { try await client.subscribe(.live, deadline: deadline) }
        _ = try await subscription.next(deadline)
        harness.timing.holdCancelledCompletions()

        // One published event, so the first pull has a frame ready and delivers in its first round.
        harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 0), kind: "proxy", event: "test.first"))
        harness.scheduling.drainAll()
        let answered = Answered()
        let first = Task {
            let frame = try await subscription.next(deadline)
            answered.set()
            return frame
        }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        harness.scheduling.drainAll()
        let held = await awaitState { harness.timing.heldCancellationCount == 1 }
        XCTAssertTrue(held, "the delivered pull cancelled its timer, whose completion is held")
        XCTAssertFalse(answered.value, "the caller is not answered while the timer still holds the reservation")
        XCTAssertEqual(transport.lanes.inFlight(.stream), 1, "the timer still holds the lane")
        guard queued, held else {
            return abandonAfterFailure(harness) {
                first.cancel()
                subscription.cancel()
            }
        }

        harness.timing.releaseHeldCancellations()
        guard case .events = try await first.value else { return XCTFail("the first pull delivers the published event") }
        XCTAssertEqual(transport.lanes.inFlight(.stream), 0, "the lane slot was returned before the caller was answered")

        // The next pull starts at once: no busy refusal, and no wait or retry in the caller.
        harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.second"))
        harness.scheduling.drainAll()
        let second = Task { try await subscription.next(deadline) }
        let secondQueued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(secondQueued, "the next pull was admitted and queued its round, not refused busy")
        harness.scheduling.drainAll()
        let secondHeld = await awaitState { harness.timing.heldCancellationCount == 1 }
        XCTAssertTrue(secondHeld)
        guard secondQueued, secondHeld else {
            return abandonAfterFailure(harness) {
                second.cancel()
                subscription.cancel()
            }
        }
        harness.timing.releaseHeldCancellations()
        guard case .events = try await second.value else { return XCTFail("the next pull delivers the next event") }
        XCTAssertEqual(transport.lanes.inFlight(.stream), 0)

        subscription.cancel()
        harness.scheduling.drainAll()
    }

    // MARK: - Open cancelled after registration

    @RuntimeActor func testAnOpenCancelledAfterItsSubscriberRegisteredRemovesIt() async throws {
        let harness = try RuntimeServiceHarness()
        let lanes = RuntimeLaneCounter(limits: harness.limits)
        let ticket = try XCTUnwrap(lanes.reserve(.read, onQuiesced: nil))
        let core = harness.core
        // The attempt registers a subscriber, and the wait is ended before the round can finish it. A caller that cancels
        // mid-round takes exactly this path, because expiry is safe from any thread while the round holds the claim.
        let gate = RuntimeWaitGate(
            ticket: ticket,
            deadline: RuntimeDeadline.after(.seconds(5), from: harness.timing.now),
            timing: harness.timing.timing,
            scheduling: harness.scheduling,
            attempt: { gate in
                switch core.openSubscription(.live) {
                case .opened(let subscriber, _):
                    gate.expire(.cancelled)
                    return .opened(subscriber: subscriber, first: Data())
                case .refused:
                    return nil
                }
            },
            abandoned: { outcome in
                if case .opened(let subscriber?, _) = outcome {
                    core.removeSubscriber(subscriber)
                }
            }
        )
        let waiter = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<RuntimeWaitOutcome, Never>) in
                gate.start(continuation)
            }
        }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        guard queued else { return abandonAfterFailure(harness) { waiter.cancel() } }
        harness.scheduling.drainAll()

        XCTAssertEqual(core.openSubscriberCount, 0, "the subscriber registered inside the lost open is removed")
        let outcome = await waiter.value
        guard case .failed(.sent(.cancelled)) = outcome else {
            return XCTFail("the caller ends as sent and cancelled, because the round had claimed the work")
        }
        let released = await awaitState { ticket.isReleased }
        XCTAssertTrue(released, "the reservation is released once the round and the timer have ended")
    }

    // MARK: - First frame

    @RuntimeActor func testAnExpiredFirstPullConsumesNothingAndTheBaselineIsStillThere() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let stream = try await openStreamDirectly(harness, transport)
        XCTAssertEqual(harness.core.openSubscriberCount, 1)

        let expired = RuntimeDeadline(instant: harness.timing.now.advanced(by: .seconds(-1)))
        let expiredEnd = await thrownWaitEnd { try await stream.next(expired) }
        XCTAssertEqual(expiredEnd, .deadlineExpired)

        let live = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        let frame = try await stream.next(live)
        let decoded = try ControlRuntimeCodec.decodeFullFrame(frame, limits: frameLimits)
        guard case .frame(let first) = decoded.body else { return XCTFail("the baseline frame was not delivered") }
        XCTAssertEqual(first.kind, .baseline, "the baseline is delivered to the first live call")
    }

    // MARK: - Single pull on the direct transport

    @RuntimeActor func testTheDirectTransportRefusesASecondPullWhileTheFirstHoldsTheSlot() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let stream = try await openStreamDirectly(harness, transport)
        let live = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        _ = try await stream.next(live)

        let first = Task { try await stream.next(live) }
        let queued = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(queued)
        let second = await thrownWaitEnd { try await stream.next(live) }
        XCTAssertEqual(second, .transportBusy, "a second pull on the same handle is refused while the first holds the slot")

        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.parkedWaiterCount, 1, "the first pull parked")
        stream.cancel()
        harness.scheduling.drainAll()
        let firstEnd = await thrownWaitEnd { try await first.value }
        XCTAssertEqual(firstEnd, .disconnected)
    }

    // MARK: - Registration resolved between install and park

    /// The production registration path, with a cancel landing after the registration is installed and before the wait parks.
    /// The cleanup hop is queued and the waiter part holds the reservation until that hop runs. The pull slot, which the lane's
    /// release callback frees, stays held until the timer part ends too.
    @RuntimeActor func testARegistrationResolvedBeforeItParksKeepsItsReservationUntilItsCleanupRuns() async throws {
        final class ReleaseFlag: @unchecked Sendable {
            var released = false
        }
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        guard case .opened(let subscriber, _) = harness.core.openSubscription(.live) else {
            return XCTFail("the subscription must open")
        }
        let flag = ReleaseFlag()
        let ticket = try XCTUnwrap(transport.lanes.reserve(.stream, onQuiesced: { flag.released = true }))
        let token = RuntimeWaiterToken()
        let gate = RuntimeWaitGate(
            ticket: ticket,
            deadline: RuntimeDeadline.after(.seconds(5), from: harness.timing.now),
            timing: harness.timing.timing,
            scheduling: harness.scheduling,
            attempt: { gate in
                _ = transport.installRegistration(subscriber, token: token, gate: gate) {
                    gate.expire(.cancelled)
                }
                return nil
            },
            abandoned: { _ in }
        )

        gate.queueRound()
        XCTAssertTrue(harness.scheduling.runNext(), "the round runs: it installs the registration, and the cancel lands before the park")
        XCTAssertEqual(gate.currentPhase, .resolved)
        XCTAssertEqual(harness.core.parkedWaiterCount, 1, "the registration is installed until its cleanup runs")
        XCTAssertEqual(harness.scheduling.pendingCount, 1, "exactly the cleanup is queued")
        XCTAssertEqual(transport.lanes.inFlight(.stream), 1, "the waiter part holds the reservation, not only the hop")
        XCTAssertFalse(flag.released)

        XCTAssertTrue(harness.scheduling.runNext(), "the cleanup runs")
        XCTAssertEqual(harness.core.parkedWaiterCount, 0, "the registration is removed by its own cleanup")
        XCTAssertEqual(transport.lanes.inFlight(.stream), 1, "the timer part still holds the reservation")
        XCTAssertFalse(flag.released, "the pull slot is still held")

        // This gate was never started, so its timer part is ended here, as its timer task would end it.
        ticket.end(.timer)
        XCTAssertEqual(transport.lanes.inFlight(.stream), 0)
        XCTAssertTrue(flag.released, "the release callback frees the pull slot only once every part has ended")
    }

    // MARK: - Stream end is terminal

    /// A subscriber the ring evicted past gets a stream end. The end is terminal in the same owner turn: the subscription leaves
    /// the service and the handle releases, so a later cancel queues nothing, and a further pull is disconnected.
    @RuntimeActor func testAStreamEndReleasesTheSubscriberInTheSameOwnerTurn() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let stream = try await openStreamDirectly(harness, transport)
        XCTAssertEqual(harness.core.openSubscriberCount, 1)
        let live = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        _ = try await stream.next(live)

        // Publish more events than the ring retains, one owner turn each, while this subscriber does not pull.
        for index in 0..<40 {
            harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: Double(index)), kind: "proxy", event: "test.event"))
            harness.scheduling.drainAll()
        }
        XCTAssertGreaterThan(harness.core.observedFirstRetained, 1, "the ring evicted the subscriber's next position")

        let frame = try await runCall(harness.scheduling) { try await stream.next(live) }
        let decoded = try ControlRuntimeCodec.decodeFullFrame(frame, limits: frameLimits)
        guard case .frame(.end) = decoded.body else { return XCTFail("the pull answers with a stream end") }
        XCTAssertEqual(harness.core.openSubscriberCount, 0, "the end removed the subscription in the same owner turn")

        let afterEnd = await thrownWaitEnd { try await stream.next(live) }
        XCTAssertEqual(afterEnd, .disconnected, "the handle is terminal after its end")
        let queuedBeforeCancel = harness.scheduling.pendingCount
        stream.cancel()
        XCTAssertEqual(harness.scheduling.pendingCount, queuedBeforeCancel, "a cancel after the end queues no second removal")
    }

    // MARK: - Payload release while the timer is held

    /// A resolved wait releases the closure that captured its request, while its timer is still held. The lane keeps its slot
    /// until that timer ends, so the release is of payload only, and no capacity is freed early.
    @RuntimeActor func testAResolvedWaitReleasesItsCapturedRequestWhileItsHeldTimerKeepsTheLane() async throws {
        final class Freed: @unchecked Sendable {
            var value = false
        }
        final class Captured: @unchecked Sendable {
            private let freed: Freed

            init(_ freed: Freed) {
                self.freed = freed
            }

            deinit {
                freed.value = true
            }
        }
        let harness = try RuntimeServiceHarness()
        harness.timing.holdCancelledCompletions()
        let lanes = RuntimeLaneCounter(limits: harness.limits)
        let ticket = try XCTUnwrap(lanes.reserve(.read, onQuiesced: nil))
        let freed = Freed()
        // The closure is the only holder of the captured object, so the object is freed exactly when the gate lets the closure go.
        func makeGate() -> RuntimeWaitGate {
            let captured = Captured(freed)
            return RuntimeWaitGate(
                ticket: ticket,
                deadline: RuntimeDeadline.after(.seconds(5), from: harness.timing.now),
                timing: harness.timing.timing,
                scheduling: harness.scheduling,
                attempt: { [captured] _ in
                    _ = captured
                    return .reply(Data(repeating: 0x2A, count: 256))
                },
                abandoned: { _ in }
            )
        }
        let gate = makeGate()

        let waiter = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<RuntimeWaitOutcome, Never>) in
                gate.start(continuation)
            }
        }
        let armed = await awaitState { harness.timing.armedTimerCount == 1 }
        XCTAssertTrue(armed)
        let queued = await awaitState { harness.scheduling.pendingCount == 1 }
        XCTAssertTrue(queued)
        guard armed, queued else { return abandonAfterFailure(harness) { waiter.cancel() } }
        let ran = harness.scheduling.runNext()
        XCTAssertTrue(ran, "the round runs and resolves the wait")
        guard ran else { return abandonAfterFailure(harness) { waiter.cancel() } }
        XCTAssertTrue(freed.value, "the resolved wait released the closure that captured its request")
        XCTAssertEqual(lanes.inFlight(.read), 1, "the held timer still holds the lane")

        let outcome = await waiter.value
        guard case .reply(let bytes) = outcome, bytes.count == 256 else {
            return XCTFail("the caller received the reply, got \(outcome)")
        }
        harness.timing.releaseHeldCancellations()
        let released = await awaitState { lanes.inFlight(.read) == 0 }
        XCTAssertTrue(released, "the lane releases once the timer has ended")
    }

    /// The closure a parked wait holds is released after the gate's lock is free, and before the caller resumes. The probe is
    /// the closure's only holder, and its destructor tries the gate's lock. A destructor that ran under the lock would find it held,
    /// and the test would fail at once: `try` never waits, so no regression can hang the suite. The deadline ends a parked wait,
    /// which is the path where the gate itself is the last holder.
    @RuntimeActor func testTheParkedClosureIsReleasedAfterTheGateLockIsFreeAndBeforeTheCallerResumes() async throws {
        final class Verdict: @unchecked Sendable {
            var lockWasFree: Bool?
        }
        final class Probe: @unchecked Sendable {
            weak var gate: RuntimeWaitGate?
            let verdict: Verdict

            init(_ verdict: Verdict) {
                self.verdict = verdict
            }

            deinit {
                verdict.lockWasFree = gate?.isLockFreeForTesting
            }
        }
        let harness = try RuntimeServiceHarness()
        let lanes = RuntimeLaneCounter(limits: harness.limits)
        let ticket = try XCTUnwrap(lanes.reserve(.read, onQuiesced: nil))
        let verdict = Verdict()
        // The round parks, so the closure stays in the gate until resolution. It is the only holder of the probe.
        func makeGate() -> RuntimeWaitGate {
            let probe = Probe(verdict)
            let gate = RuntimeWaitGate(
                ticket: ticket,
                deadline: RuntimeDeadline.after(.seconds(5), from: harness.timing.now),
                timing: harness.timing.timing,
                scheduling: harness.scheduling,
                attempt: { [probe] wait in
                    _ = probe
                    wait.park { _ in }
                    return nil
                },
                abandoned: { _ in }
            )
            probe.gate = gate
            return gate
        }
        let gate = makeGate()

        let waiter = Task {
            await withCheckedContinuation { (continuation: CheckedContinuation<RuntimeWaitOutcome, Never>) in
                gate.start(continuation)
            }
        }
        let armed = await awaitState { harness.timing.armedTimerCount == 1 }
        XCTAssertTrue(armed)
        let queued = await awaitState { harness.scheduling.pendingCount == 1 }
        XCTAssertTrue(queued)
        guard armed, queued else { return abandonAfterFailure(harness) { waiter.cancel() } }
        let ran = harness.scheduling.runNext()
        XCTAssertTrue(ran, "the round runs and parks")
        guard ran else { return abandonAfterFailure(harness) { waiter.cancel() } }
        XCTAssertNil(verdict.lockWasFree, "a parked wait still holds its closure")

        harness.timing.fireAll()
        let outcome = await waiter.value
        guard case .failed(.notSent(.deadlineExpired)) = outcome else {
            return XCTFail("the deadline resolves the parked wait as not sent, got \(outcome)")
        }
        XCTAssertEqual(verdict.lockWasFree, true, "the closure was released while the gate's lock was free")
    }

    // MARK: - Dropping a framed subscription

    /// A framed subscription dropped without a cancel releases its subscriber once, through the framed client's own cleanup.
    @RuntimeActor func testADroppedFramedSubscriptionReleasesItsSubscriberWithoutACancel() async throws {
        let harness = try RuntimeServiceHarness()
        let client = try makeClient(harness, harness.transport())
        let deadline = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)
        var subscription: RuntimeSubscription? = try await runCall(harness.scheduling) {
            try await client.subscribe(.live, deadline: deadline)
        }
        _ = try await subscription?.next(deadline)
        XCTAssertEqual(harness.core.openSubscriberCount, 1)

        subscription = nil
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.openSubscriberCount, 0, "dropping the last reference cancelled the stream once")
    }

    // MARK: - Terminal cleanup

    @RuntimeActor func testCancelIsTerminalAndTheSubscriberIsRemovedExactlyOnce() async throws {
        let harness = try RuntimeServiceHarness()
        let transport = harness.transport()
        let stream = try await openStreamDirectly(harness, transport)
        let live = RuntimeDeadline.after(.seconds(5), from: harness.timing.now)

        stream.cancel()
        stream.cancel()
        XCTAssertEqual(harness.scheduling.pendingCount, 1, "one removal is queued, however often the stream is cancelled")
        harness.scheduling.drainAll()
        XCTAssertEqual(harness.core.openSubscriberCount, 0)
        let end = await thrownWaitEnd { try await stream.next(live) }
        XCTAssertEqual(end, .disconnected, "after a cancel the buffered baseline is gone, and the stream is disconnected")
    }
}
