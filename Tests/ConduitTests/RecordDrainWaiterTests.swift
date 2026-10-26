// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// The waiter alone, over a group the test enters and leaves. Each physical part (the group's notify and the
/// deadline timer) is observed through a seam, so no test polls or sleeps.
final class RecordDrainWaiterTests: XCTestCase {
    func testTimedOutDrainKeepsNotifyUntilTheGroupEmpties() async {
        let group = DispatchGroup()
        let cleaned = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let waiter = RecordDrainWaiter(group: group, onCleanup: { cleaned.signal() },
                                       onTimerReleased: { timerReleased.signal() })
        group.enter()
        let timedOut = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timedOut, .timedOut)
        // The timer's cancellation is acknowledged, but the group has not emptied: the notify is still held.
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        let busy = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(busy, .busy)

        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        let drained = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(drained, .drained)
    }

    func testRepeatedWaitsWhileHeldRegisterOneTimerAndNothingElse() async {
        let group = DispatchGroup()
        let cleaned = DispatchSemaphore(value: 0)
        let timersReleased = NIOLockedValueBox(0)
        let timerReleased = DispatchSemaphore(value: 0)
        let waiter = RecordDrainWaiter(group: group, onCleanup: { cleaned.signal() },
                                       onTimerReleased: {
                                           timersReleased.withLockedValue { $0 += 1 }
                                           timerReleased.signal()
                                       })
        group.enter()
        _ = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        for _ in 0..<20 {
            let outcome = await waiter.drain(until: deadline(in: 10))
            XCTAssertEqual(outcome, .busy)
        }
        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(timersReleased.withLockedValue { $0 }, 1, "twenty refused waits created no timer")
    }

    func testDeadlinePassedBeforeRegistrationSkipsWithoutAReservation() async {
        let group = DispatchGroup()
        let waiter = RecordDrainWaiter(group: group)
        group.enter()
        let skipped = await waiter.drain(until: ContinuousClock.now)
        XCTAssertEqual(skipped, .skippedBudget)
        // Nothing was registered by the skipped wait, so a later wait with time left is not busy.
        let timedOut = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timedOut, .timedOut)
        group.leave()
    }

    /// Cancellation before registration: the handler runs first, so nothing is registered at all.
    func testWaitCancelledBeforeRegistrationLeavesNoReservation() async {
        let group = DispatchGroup()
        let waiter = RecordDrainWaiter(group: group)
        group.enter()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await waiter.drain(until: deadline(in: 10))
        }
        let outcome = await cancelled.value
        XCTAssertEqual(outcome, .cancelled)
        let timedOut = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timedOut, .timedOut, "the cancelled wait registered nothing")
        group.leave()
    }

    /// Cancellation after registration. The seam proves the reservation exists before the cancel: the wait's
    /// timer is cancelled and acknowledged, but the group's notify stays held until the group empties.
    func testCancelAfterRegistrationKeepsNotifyHeldThenReturnsBusyUntilCleanup() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let waiter = RecordDrainWaiter(group: group, onCleanup: { cleaned.signal() },
                                       onTimerReleased: { timerReleased.signal() },
                                       onRegistered: { registered.signal() })
        group.enter()
        let waiting = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)

        waiting.cancel()
        let outcome = await waiting.value
        XCTAssertEqual(outcome, .cancelled)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "the cancelled wait's timer was acknowledged")
        let busy = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(busy, .busy, "the group has not emptied, so the notify is still held")

        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        let drained = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(drained, .drained)
    }

    /// Lifetime, cancelled after registration. Checked only after the cleanup seam has joined both parts. The
    /// cleanup block runs after the callbacks that released the last part, so the waiter is no longer held.
    func testCancelledWaitLeavesNoLiveWaiterOnceBothPartsJoin() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        var waiter: RecordDrainWaiter? = RecordDrainWaiter(
            group: group, onCleanup: { cleaned.signal() }, onTimerReleased: { timerReleased.signal() },
            onRegistered: { registered.signal() })
        weak var sentinel = waiter
        group.enter()
        let waiting = Task { [weak waiter] in await waiter?.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        waiting.cancel()
        _ = await waiting.value
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)

        waiter = nil
        XCTAssertNil(sentinel, "a joined waiter is released: no callback or timer holds it")
    }

    /// Lifetime, timed out. Same rule: the sentinel is read only after the cleanup seam joins both parts.
    func testTimedOutWaitLeavesNoLiveWaiterOnceBothPartsJoin() async {
        let group = DispatchGroup()
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        var waiter: RecordDrainWaiter? = RecordDrainWaiter(
            group: group, onCleanup: { cleaned.signal() }, onTimerReleased: { timerReleased.signal() })
        weak var sentinel = waiter
        group.enter()
        let timedOut = await waiter?.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)

        waiter = nil
        XCTAssertNil(sentinel, "a joined waiter is released: no callback or timer holds it")
    }

    /// The first caller resolves as drained while its timer body is still held. The held body keeps the one physical
    /// timer reserved, so a new non-empty wait is busy. Once the body ends, capacity returns and a new wait registers.
    func testDrainedCallerReturnsWhileAHeldTimerBodyKeepsCapacityBusyUntilItEnds() async {
        let group = DispatchGroup()
        let timer = HeldTimerBody()
        let timerReleased = DispatchSemaphore(value: 0)
        let registered = DispatchSemaphore(value: 0)
        let waiter = RecordDrainWaiter(
            group: group, onTimerReleased: { timerReleased.signal() }, onRegistered: { registered.signal() },
            sleep: { deadline in try await timer.sleep(until: deadline) })

        group.enter()
        let first = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(timer.entered.wait(timeout: .now() + 10), .success)
        group.leave()
        let drained = await first.value
        XCTAssertEqual(drained, .drained, "the caller resolves without waiting for the held body")

        group.enter()
        let busy = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(busy, .busy, "the held body still holds the one timer")

        timer.release()
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "the body ended and its reservation is released")
        group.leave()

        group.enter()
        let again = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success, "capacity returned: a new wait registers")
        group.leave()
        let final = await again.value
        XCTAssertEqual(final, .drained)
    }

    // MARK: - Timer slots

    /// One earlier wait in a probe's history. Each registers exactly one reservation.
    private enum Prior {
        /// Registered and still waiting: its notify and its timer are held.
        case pending
        /// Drained while its timer body is held: only that body is held.
        case drainedHeld
        /// Drained, and its timer body has ended: nothing is held.
        case drainedEnded
        /// Timed out: its body has ended, and its notify stays registered.
        case timedOut
    }

    /// Runs `prior` on a new waiter with `slots` timer slots, then probes with a non-empty 50 ms wait: `.busy` if it was
    /// refused, `.timedOut` if it registered. Every held part is released before this returns.
    private func probe(slots: Int, after prior: [Prior]) async -> RecordDrainOutcome {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let held = Set(prior.indices.filter { prior[$0] == .drainedHeld })
        let bodies = IndexedTimerBodies(held: held)
        let waiter = RecordDrainWaiter(group: group, timerSlots: slots, onTimerReleased: { timerReleased.signal() },
                                       onRegistered: { registered.signal() },
                                       sleep: { try await bodies.sleep(until: $0) })
        var entered = 0
        var waiting: [Task<RecordDrainOutcome, Never>] = []
        for step in prior {
            group.enter()
            switch step {
            case .pending:
                entered += 1
                waiting.append(Task { await waiter.drain(until: deadline(in: 10)) })
                XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
            case .drainedHeld, .drainedEnded:
                let wait = Task { await waiter.drain(until: deadline(in: 10)) }
                XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
                if step == .drainedHeld { XCTAssertEqual(bodies.entered.wait(timeout: .now() + 10), .success) }
                group.leave()
                let outcome = await wait.value
                XCTAssertEqual(outcome, .drained)
                if step == .drainedEnded { XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success) }
            case .timedOut:
                entered += 1
                let outcome = await waiter.drain(until: deadline(in: 0.05))
                XCTAssertEqual(outcome, .timedOut)
                XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
            }
        }
        group.enter()
        entered += 1
        let outcome = await waiter.drain(until: deadline(in: 0.05))
        if outcome == .timedOut { XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success) }

        for index in held.sorted() { bodies.release(index) }
        for _ in held { XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success) }
        for _ in 0..<entered { group.leave() }
        for wait in waiting {
            let drained = await wait.value
            XCTAssertEqual(drained, .drained)
            XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        }
        return outcome
    }

    /// Each row is a history and the outcome a new non-empty wait gets after it, written out by hand: `.timedOut` means
    /// the wait registered, `.busy` that it was refused.
    func testProbeOutcomeAfterEachHistory() async {
        let rows: [(slots: Int, prior: [Prior], expected: RecordDrainOutcome, why: String)] = [
            (1, [], .timedOut, "an idle waiter registers"),
            (1, [.drainedHeld], .busy, "one slot, held by the drained wait's body"),
            (1, [.drainedEnded], .timedOut, "one slot, and its body ended"),
            (2, [], .timedOut, "an idle waiter registers"),
            (2, [.pending], .busy, "one caller waits at a time"),
            (2, [.drainedHeld], .timedOut, "the second slot takes the wait"),
            (2, [.drainedEnded], .timedOut, "nothing is held"),
            (2, [.drainedHeld, .drainedHeld], .busy, "both slots hold retired bodies"),
            (2, [.drainedHeld, .drainedEnded], .timedOut, "one retired body leaves a slot free"),
            (2, [.timedOut], .busy, "the timed-out wait's notify is still registered"),
            (2, [.drainedHeld, .timedOut], .busy, "a slot is free, but the one notify is held"),
            (2, [.drainedHeld, .pending], .busy, "a caller is waiting"),
        ]
        for row in rows {
            let outcome = await probe(slots: row.slots, after: row.prior)
            XCTAssertEqual(outcome, row.expected, "slots \(row.slots) after \(row.prior): \(row.why)")
        }
    }

    /// With two slots, a drained wait's held body leaves the second slot free, so the next wait registers and drains.
    /// Cleanup runs once, after the notify and both bodies end, and once more for the next idle transition.
    func testSecondSlotTakesAWaitBesideAHeldBodyAndCleanupRunsOncePerIdleTransition() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let cleanups = NIOLockedValueBox(0)
        let bodies = IndexedTimerBodies(held: [0])
        let waiter = RecordDrainWaiter(
            group: group, timerSlots: 2,
            onCleanup: {
                cleanups.withLockedValue { $0 += 1 }
                cleaned.signal()
            },
            onTimerReleased: { timerReleased.signal() }, onRegistered: { registered.signal() },
            sleep: { try await bodies.sleep(until: $0) })

        group.enter()
        let first = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(bodies.entered.wait(timeout: .now() + 10), .success)
        group.leave()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .drained)

        group.enter()
        let second = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success, "the second slot took the wait")
        group.leave()
        let secondOutcome = await second.value
        XCTAssertEqual(secondOutcome, .drained)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "the second wait's cancelled body ended")

        bodies.release(0)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "the held body ended")
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(cleanups.withLockedValue { $0 }, 1, "one idle transition, one cleanup")

        group.enter()
        let third = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        group.leave()
        let thirdOutcome = await third.value
        XCTAssertEqual(thirdOutcome, .drained)
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(cleanups.withLockedValue { $0 }, 2, "the next idle transition, one more cleanup")
        XCTAssertEqual(bodies.calls, 3)
    }

    /// Two drained waits whose bodies are held fill both slots. Twenty further non-empty waits are refused and create no
    /// timer. Releasing one body frees only its own slot; a third held body refills it beside the unreleased second body.
    func testTwoRetiredBodiesRefuseEveryFurtherWaitAndTheRefusalsCreateNoTimer() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let bodies = IndexedTimerBodies(held: [0, 1, 2])
        let waiter = RecordDrainWaiter(
            group: group, timerSlots: 2, onCleanup: { cleaned.signal() },
            onTimerReleased: { timerReleased.signal() }, onRegistered: { registered.signal() },
            sleep: { try await bodies.sleep(until: $0) })

        for _ in 0..<2 {
            group.enter()
            let wait = Task { await waiter.drain(until: deadline(in: 10)) }
            XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
            XCTAssertEqual(bodies.entered.wait(timeout: .now() + 10), .success)
            group.leave()
            let outcome = await wait.value
            XCTAssertEqual(outcome, .drained)
        }

        group.enter()
        for _ in 0..<20 {
            let outcome = await waiter.drain(until: deadline(in: 10))
            XCTAssertEqual(outcome, .busy)
        }
        XCTAssertEqual(bodies.calls, 2, "twenty refused waits created no timer")

        bodies.release(0)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        let again = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success, "the released slot takes the next wait")
        XCTAssertEqual(bodies.entered.wait(timeout: .now() + 10), .success, "the replacement timer body is held")
        group.leave()
        let againOutcome = await again.value
        XCTAssertEqual(againOutcome, .drained)

        group.enter()
        let fourth = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(fourth, .busy, "the unreleased second body and the replacement fill both slots")
        XCTAssertEqual(bodies.calls, 3, "releasing one reservation never releases another reservation's slot")
        group.leave()

        bodies.release(1)
        bodies.release(2)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(bodies.calls, 3)
    }

    /// A free timer slot never bypasses the one notify. A timed-out wait keeps its notify registered, so the next wait is
    /// refused until the group empties.
    func testWithTwoSlotsATimedOutWaitsNotifyStillRefusesTheNextWait() async {
        let group = DispatchGroup()
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let waiter = RecordDrainWaiter(group: group, timerSlots: 2, onCleanup: { cleaned.signal() },
                                       onTimerReleased: { timerReleased.signal() })
        group.enter()
        let timedOut = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timedOut, .timedOut)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "no timer body is held")
        let busy = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(busy, .busy, "a slot is free, but the notify is held")

        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        group.enter()
        let again = await waiter.drain(until: deadline(in: 0.05))
        XCTAssertEqual(again, .timedOut, "the notify fired, so the next wait registers")
        group.leave()
    }

    /// One caller waits at a time, and a cancelled wait keeps its notify, so neither leaves room for a second wait.
    func testWithTwoSlotsOneCallerWaitsAtATimeAndACancelledWaitsNotifyStillRefuses() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let waiter = RecordDrainWaiter(group: group, timerSlots: 2, onCleanup: { cleaned.signal() },
                                       onTimerReleased: { timerReleased.signal() },
                                       onRegistered: { registered.signal() })
        group.enter()
        let waiting = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        let second = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(second, .busy, "one caller waits at a time")

        waiting.cancel()
        let cancelled = await waiting.value
        XCTAssertEqual(cancelled, .cancelled)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        let afterCancel = await waiter.drain(until: deadline(in: 10))
        XCTAssertEqual(afterCancel, .busy, "a slot is free, but the cancelled wait's notify is held")

        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
    }

    /// A held body from a drained wait returns normally while a newer wait is registered. It reaches the expiry path late
    /// and must settle nothing, and its release must leave the newer wait's timer in place: cancelling the newer wait
    /// then ends that timer at once, long before its deadline.
    func testALateTimerSettlesNothingAndTheNewerWaitsCancelEndsItsOwnTimer() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let bodies = IndexedTimerBodies(held: [0])
        let waiter = RecordDrainWaiter(
            group: group, timerSlots: 2, onCleanup: { cleaned.signal() },
            onTimerReleased: { timerReleased.signal() }, onRegistered: { registered.signal() },
            sleep: { try await bodies.sleep(until: $0) })

        group.enter()
        let first = Task { await waiter.drain(until: deadline(in: 10)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(bodies.entered.wait(timeout: .now() + 10), .success)
        group.leave()
        let firstOutcome = await first.value
        XCTAssertEqual(firstOutcome, .drained)

        group.enter()
        let newer = Task { await waiter.drain(until: deadline(in: 60)) }
        XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
        bodies.release(0)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "the late body released its own slot")

        newer.cancel()
        let outcome = await newer.value
        XCTAssertEqual(outcome, .cancelled, "the late timer did not settle the newer wait")
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success,
                       "the cancel ended the newer wait's own timer, well before its 60 s deadline")
        group.leave()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
    }

    /// Lifetime with two slots. Read only after cleanup joins the notify and both bodies.
    func testTwoSlotWaiterIsReleasedOnceItsNotifyAndBothBodiesEnd() async {
        let group = DispatchGroup()
        let registered = DispatchSemaphore(value: 0)
        let timerReleased = DispatchSemaphore(value: 0)
        let cleaned = DispatchSemaphore(value: 0)
        let bodies = IndexedTimerBodies(held: [0])
        var waiter: RecordDrainWaiter? = RecordDrainWaiter(
            group: group, timerSlots: 2, onCleanup: { cleaned.signal() },
            onTimerReleased: { timerReleased.signal() }, onRegistered: { registered.signal() },
            sleep: { try await bodies.sleep(until: $0) })
        weak var sentinel = waiter

        for _ in 0..<2 {
            group.enter()
            let wait = Task { [weak waiter] in await waiter?.drain(until: deadline(in: 10)) }
            XCTAssertEqual(registered.wait(timeout: .now() + 10), .success)
            group.leave()
            let outcome = await wait.value
            XCTAssertEqual(outcome, .drained)
        }
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success, "the second wait's cancelled body ended")
        bodies.release(0)
        XCTAssertEqual(timerReleased.wait(timeout: .now() + 10), .success)
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)

        waiter = nil
        XCTAssertNil(sentinel, "a joined waiter is released: no callback or timer holds it")
    }
}
