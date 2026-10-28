// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import PlatformMac

/// The fixtures the held-effect tests stand on, checked on the actual contexts before anything relies on them: which threads
/// `HeldCall` tells apart by their queue label, which calls it holds, records or ignores, that a release belongs to one arm, and that
/// `MainThreadPark` parks the main thread with other work still going on. Every hold here is released on every path, and no call is
/// ever held on a pool thread, so a failure fails the test instead of hanging it.
final class HeldCallTests: XCTestCase {
    private static let workLabel = "io.github.srps.Conduit.held-call-tests.platform-work"

    private actor LabelProbe {
        func label() -> String { HeldCall.currentQueueLabel() }
    }

    private func label(on queue: DispatchQueue) async -> String {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: HeldCall.currentQueueLabel()) }
        }
    }

    /// One matching call on `queue`, in a task of its own, so a test can wait for its hold without awaiting it.
    private func call(_ hold: HeldCall, on queue: DispatchQueue) -> Task<Void, Never> {
        Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.async {
                    hold.pass("call", [])
                    continuation.resume()
                }
            }
        }
    }

    private func callOnPlatformWork(_ hold: HeldCall) -> Task<Void, Never> {
        let work = PlatformWork(label: Self.workLabel)
        return Task.detached { await work.run { hold.pass("call", []) } }
    }

    /// The pool is the threads of tasks and of every actor but the main one; the queues the hosts send blocking work to, the global
    /// queues and the main thread are not in it.
    func testThePoolIsToldApartFromTheQueuesTheHostsUse() async {
        let detached = await Task.detached { HeldCall.currentQueueLabel() }.value
        let actor = await LabelProbe().label()
        let utility = await label(on: .global(qos: .utility))
        let userInitiated = await label(on: .global(qos: .userInitiated))
        let platformWork = await PlatformWork(label: Self.workLabel).run { HeldCall.currentQueueLabel() }
        let main = await MainActor.run { HeldCall.currentQueueLabel() }

        XCTAssertTrue(HeldCall.isCooperativePool(detached), "a detached task runs on the pool: \(detached)")
        XCTAssertTrue(HeldCall.isCooperativePool(actor), "an actor's default executor runs on the pool: \(actor)")
        XCTAssertEqual(platformWork, Self.workLabel)
        for queue in [utility, userInitiated, platformWork, main] {
            XCTAssertFalse(HeldCall.isCooperativePool(queue), "\(queue) is not the pool")
        }
    }

    /// An arm that names no queue holds a call on any queue off the main thread, as before, except the pool: there the call is taken,
    /// recorded and let through.
    func testACallOnThePoolIsRecordedAndLetThroughNeverHeld() async {
        let hold = HeldCall()
        hold.arm { name, _ in name == "call" }
        let call = Task.detached { hold.pass("call", []) }
        let reached = await hold.waitUntilReached(within: .seconds(5))
        XCTAssertTrue(reached)
        XCTAssertFalse(hold.isHolding, "no pool thread is held")
        hold.release()
        await call.value
        XCTAssertTrue(hold.reachedOnCooperativePool)
        XCTAssertFalse(hold.reachedOnArmedQueue)
        XCTAssertFalse(hold.reachedOnMainThread)

        hold.arm { name, _ in name == "call" }
        XCTAssertFalse(hold.reachedOnCooperativePool, "a new arm starts clean")
        XCTAssertTrue(hold.takenOnCooperativePool, "the hold still says a call was let through on the pool")
    }

    /// The legacy mode is unchanged off the pool: an arm that names no queue holds a call on a global queue, and one that names a queue
    /// ignores a call on any other, the pool included, so a host's preflight read on a global queue is never the call that counts.
    func testTheIgnoredModeHoldsAnyQueueOrOnlyTheNamedOne() async {
        let anyQueue = HeldCall()
        anyQueue.arm { name, _ in name == "call" }
        let global = call(anyQueue, on: .global(qos: .userInitiated))
        await anyQueue.waitUntilReached()
        XCTAssertTrue(anyQueue.isHolding)
        XCTAssertTrue(anyQueue.reachedOnArmedQueue)
        anyQueue.release()
        await global.value

        let named = HeldCall()
        named.arm(onQueueLabeled: ".platform-work") { name, _ in name == "call" }
        await call(named, on: .global(qos: .userInitiated)).value
        await Task.detached { named.pass("call", []) }.value
        let ignored = await named.waitUntilReached(within: .zero)
        XCTAssertFalse(ignored, "neither the global queue nor the pool counts")
        let work = callOnPlatformWork(named)
        await named.waitUntilReached()
        XCTAssertTrue(named.isHolding, "the named queue's call is held")
        named.release()
        await work.value
    }

    /// A recorded arm takes a call on an unnamed queue or on the pool and lets it through with its queue recorded, and holds the one on
    /// its own queue.
    func testARecordedArmRecordsTheWrongExecutorAndHoldsItsQueue() async {
        let hold = HeldCall()
        hold.arm(onQueueLabeled: ".platform-work", otherQueues: .recorded) { name, _ in name == "call" }
        await call(hold, on: .global(qos: .userInitiated)).value
        let userInitiated = await label(on: .global(qos: .userInitiated))
        XCTAssertEqual(hold.reachedQueueLabel, userInitiated)
        XCTAssertFalse(hold.reachedOnArmedQueue)
        XCTAssertFalse(hold.isHolding)

        hold.arm(onQueueLabeled: ".platform-work", otherQueues: .recorded) { name, _ in name == "call" }
        await Task.detached { hold.pass("call", []) }.value
        XCTAssertTrue(hold.reachedOnCooperativePool)
        XCTAssertFalse(hold.isHolding)

        hold.arm(onQueueLabeled: ".platform-work", otherQueues: .recorded) { name, _ in name == "call" }
        let work = callOnPlatformWork(hold)
        await hold.waitUntilReached()
        XCTAssertTrue(hold.isHolding)
        XCTAssertTrue(hold.reachedOnArmedQueue)
        hold.release()
        await work.value
    }

    /// A release with nothing armed or held leaves nothing behind; one before the armed call arrives lets that call through; and a
    /// call taken under an earlier arm does not count for the next.
    func testAReleaseBelongsToOneArm() async {
        let hold = HeldCall()
        hold.release()
        hold.arm { name, _ in name == "call" }
        let first = call(hold, on: .global(qos: .userInitiated))
        await hold.waitUntilReached()
        XCTAssertTrue(hold.isHolding, "the stray release let nothing through")
        hold.release()
        await first.value

        hold.arm { name, _ in name == "call" }
        hold.release()
        await call(hold, on: .global(qos: .userInitiated)).value
        XCTAssertTrue(hold.reachedOnArmedQueue, "the early release let this arm's call through")
        XCTAssertFalse(hold.isHolding)

        hold.arm { name, _ in name == "call" }
        let stale = await hold.waitUntilReached(within: .zero)
        XCTAssertFalse(stale, "the earlier arm's call does not count")
        let third = call(hold, on: .global(qos: .userInitiated))
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                hold.blockUntilReached()
                continuation.resume()
            }
        }
        XCTAssertTrue(hold.isHolding)
        hold.release()
        hold.release()
        await third.value
    }

    /// Re-arming while a call is held hands the hold on, as a test does to catch the call the held one leads to: the held call stays
    /// held while the new arm takes a call it lets through, the next release lets the held call go rather than pre-releasing the new
    /// arm, and the new arm's own call is then held until its own release.
    func testARearmWhileACallIsHeldHandsTheHoldOn() async {
        let hold = HeldCall()
        hold.arm { name, _ in name == "first" }
        let first = Task.detached {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    hold.pass("first", [])
                    continuation.resume()
                }
            }
        }
        await hold.waitUntilReached()
        XCTAssertTrue(hold.isHolding)

        hold.arm { name, _ in name == "call" }
        await Task.detached { hold.pass("call", []) }.value
        XCTAssertTrue(hold.reachedOnCooperativePool)
        XCTAssertTrue(hold.isHolding, "a call the new arm let through did not let the held one go")

        hold.arm { name, _ in name == "call" }
        hold.release()
        await first.value
        XCTAssertFalse(hold.isHolding, "the release let the earlier arm's held call go")
        let next = call(hold, on: .global(qos: .userInitiated))
        await hold.waitUntilReached()
        XCTAssertTrue(hold.isHolding, "that release did not pre-release the new arm: its call is held")
        hold.release()
        await next.value
    }

    /// While the main thread is parked, no main-actor job runs, and work on the platform queue and on the pool completes.
    func testTheParkStopsTheMainActorAndNothingElse() async {
        XCTAssertFalse(Thread.isMainThread, "the test runs off the main thread, so the main thread is free to take the park")
        let park = MainThreadPark()
        defer { park.release() }
        await park.park(limit: .seconds(30))
        XCTAssertTrue(park.isParked)
        let ranOnMain = LockedSlot<Bool>()
        Task { @MainActor in ranOnMain.set(true) }
        let fromWork = await PlatformWork(label: Self.workLabel).run { 7 }
        let fromPool = await Task.detached { 11 }.value
        XCTAssertEqual(fromWork + fromPool, 18)
        XCTAssertNil(ranOnMain.value, "no main-actor job ran while the main thread was parked")
        XCTAssertTrue(park.isParked)

        park.release()
        // The main thread runs this job only after the park's own block has returned, whatever order it takes its other jobs in.
        await MainActor.run {}
        XCTAssertFalse(park.isParked)
        for _ in 0..<5_000 where ranOnMain.value == nil {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(ranOnMain.value, true, "the main-actor job ran once the park ended")
    }
}
