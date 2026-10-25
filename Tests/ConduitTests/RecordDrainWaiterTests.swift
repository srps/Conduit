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
}

/// A timer body that holds its first call until the test releases it, ignoring cancellation. Later calls sleep until
/// their deadline on the continuous clock, so cancellation ends them.
private final class HeldTimerBody: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let holdNext = NIOLockedValueBox(true)

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let hold = holdNext.withLockedValue { value -> Bool in
            let current = value
            value = false
            return current
        }
        if hold {
            entered.signal()
            holdUntilReleased()
            return
        }
        try await Task.sleep(until: deadline, clock: .continuous)
    }

    /// A synchronous function is where the blocking wait belongs: the compiler rejects it inside the async `sleep`.
    private func holdUntilReleased() {
        _ = released.wait(timeout: .now() + 10)
    }

    func release() {
        released.signal()
    }
}
