// SPDX-License-Identifier: Apache-2.0
// PR 5 of the post-investigation perf cleanup: the orchestrator throttles
// counter-tier `onSnapshotChange` emissions (per-connection / per-request
// callbacks) to ≤ 10 Hz. State-transition emissions (start/stop, vpn,
// errors, mutateSnapshot) bypass the throttle and fire instantly.
//
// These tests pin the contract:
//
//   1. A burst of counter-tier emit calls within the coalesce window
//      collapses to one emission (proves coalescing is doing its job).
//   2. State-transition emissions cancel a pending coalesced flush
//      (proves no double-emit when an immediate path follows a coalesced
//      mutation).
//   3. Multiple coalesce windows fire one emission each (proves the
//      throttle is per-window, not per-process).
//
// Drives via `triggerCoalescedSnapshotEmitForTesting()` /
// `mutateSnapshotForTesting(_:)` test seams on `ProxyOrchestrator` —
// those are the same entry points the production per-connection /
// per-request callbacks reach.

import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class SnapshotCoalescingTests: XCTestCase {

    // MARK: - Coalescing collapses bursts

    @RuntimeActor
    func testCounterTierBurstCoalescesIntoSingleEmission() async throws {
        let orchestrator = makeOrchestrator()

        // Hook the callback AFTER construction so the `didSet` initial
        // emission is captured separately and we can subtract it.
        let counter = NIOLockedValueBox<Int>(0)
        orchestrator.onSnapshotChange = { _ in
            counter.withLockedValue { $0 += 1 }
        }
        let initial = counter.withLockedValue { $0 }
        XCTAssertEqual(initial, 1, "didSet must emit once when the callback is wired.")

        // Burst: 100 coalesced emits within the same window. The throttle
        // schedules one timer on the first call and absorbs the rest.
        for _ in 0..<100 {
            orchestrator.triggerCoalescedSnapshotEmitForTesting()
        }

        // Wait past the 100ms coalesce window plus generous slack for the
        // dispatch timer to fire and its flush to hop to the owner.
        try await Task.sleep(for: .milliseconds(250))

        let total = counter.withLockedValue { $0 }
        let coalesced = total - initial
        XCTAssertEqual(coalesced, 1,
                       "100 counter-tier emits within a single coalesce window must produce exactly one emission (got \(coalesced)).")
    }

    // MARK: - Immediate cancels pending coalesced

    @RuntimeActor
    func testImmediateEmissionCancelsPendingCoalesced() async throws {
        let orchestrator = makeOrchestrator()

        let counter = NIOLockedValueBox<Int>(0)
        orchestrator.onSnapshotChange = { _ in
            counter.withLockedValue { $0 += 1 }
        }
        let initial = counter.withLockedValue { $0 }

        // Coalesced emit (timer scheduled, pending flush in 100ms).
        orchestrator.triggerCoalescedSnapshotEmitForTesting()

        // Immediate emit. Should fire NOW and cancel the pending coalesced
        // timer so the throttled flush no-ops when its 100ms elapses.
        orchestrator.mutateSnapshotForTesting { snapshot in
            snapshot.runtimeStatus.lastHealthSummary = "immediate change"
        }

        // Wait past the (now-cancelled) coalesce window.
        try await Task.sleep(for: .milliseconds(250))

        let total = counter.withLockedValue { $0 }
        let net = total - initial
        XCTAssertEqual(net, 1,
                       "Coalesced + immediate must collapse to a single emission. The immediate path must cancel the pending flush, not stack on top of it (got \(net)).")
    }

    @RuntimeActor
    func testCoalescedAfterImmediateSchedulesFreshFlush() async throws {
        // Symmetric to the test above: an immediate emission shouldn't
        // disable the throttle; the next coalesced emit must still
        // schedule a fresh flush within its window.
        let orchestrator = makeOrchestrator()

        let counter = NIOLockedValueBox<Int>(0)
        orchestrator.onSnapshotChange = { _ in
            counter.withLockedValue { $0 += 1 }
        }
        let initial = counter.withLockedValue { $0 }

        orchestrator.mutateSnapshotForTesting { snapshot in
            snapshot.runtimeStatus.lastHealthSummary = "immediate first"
        }
        // After the immediate emission, no timer is pending.

        orchestrator.triggerCoalescedSnapshotEmitForTesting()
        try await Task.sleep(for: .milliseconds(250))

        let total = counter.withLockedValue { $0 }
        let net = total - initial
        XCTAssertEqual(net, 2,
                       "Immediate + coalesced must produce two emissions: one immediate, one flushed at the end of the coalesce window (got \(net)).")
    }

    // MARK: - Per-window throttle, not one-shot

    @RuntimeActor
    func testTwoCoalesceWindowsProduceTwoEmissions() async throws {
        let orchestrator = makeOrchestrator()

        let counter = NIOLockedValueBox<Int>(0)
        orchestrator.onSnapshotChange = { _ in
            counter.withLockedValue { $0 += 1 }
        }
        let initial = counter.withLockedValue { $0 }

        // Window 1: trigger coalesced emit, wait for its emission.
        orchestrator.triggerCoalescedSnapshotEmitForTesting()
        try await waitUntil { counter.withLockedValue { $0 } - initial >= 1 }

        // Window 2: another emit, another wait.
        orchestrator.triggerCoalescedSnapshotEmitForTesting()
        try await waitUntil { counter.withLockedValue { $0 } - initial >= 2 }
        // Past one more 100 ms window: nothing further fires on its own.
        try await Task.sleep(for: .milliseconds(120))

        let total = counter.withLockedValue { $0 }
        let net = total - initial
        XCTAssertEqual(net, 2,
                       "Two coalesce windows must fire two emissions — the throttle is per-window, not a one-shot (got \(net)).")
    }

    // MARK: - Per-window absorption with mid-window immediate

    @RuntimeActor
    func testCoalescedAbsorbsMultipleEmitsAndOneImmediateMidWindow() async throws {
        // Ten coalesced emits + one immediate mid-burst + ten more
        // coalesced. Expected emissions: one from the immediate, one from
        // the second-half coalesce window. The first-half coalesced calls
        // were absorbed AND cancelled by the immediate.
        let orchestrator = makeOrchestrator()

        let counter = NIOLockedValueBox<Int>(0)
        orchestrator.onSnapshotChange = { _ in
            counter.withLockedValue { $0 += 1 }
        }
        let initial = counter.withLockedValue { $0 }

        for _ in 0..<10 {
            orchestrator.triggerCoalescedSnapshotEmitForTesting()
        }
        // Mid-window immediate. Cancels the pending flush; emits now.
        orchestrator.mutateSnapshotForTesting { snapshot in
            snapshot.runtimeStatus.lastHealthSummary = "mid-window state change"
        }
        for _ in 0..<10 {
            orchestrator.triggerCoalescedSnapshotEmitForTesting()
        }

        try await Task.sleep(for: .milliseconds(250))

        let total = counter.withLockedValue { $0 }
        let net = total - initial
        XCTAssertEqual(net, 2,
                       "Burst + immediate + burst must collapse to: 1 immediate + 1 coalesced flush = 2 emissions (got \(net)).")
    }

    // MARK: - Off-owner timer

    /// The owner is not the main thread: with main parked, a coalesced flush still lands within its window.
    func testACoalescedFlushLandsWhileTheMainThreadIsParked() async throws {
        XCTAssertFalse(Thread.isMainThread, "the test runs off the main thread, so it can park it")
        let park = MainThreadPark()
        defer { park.release() }
        await park.park(limit: .seconds(30))
        let counter = NIOLockedValueBox<Int>(0)
        let orchestrator = await Self.armedOrchestrator(counting: counter)
        let deadline = ContinuousClock.now + .seconds(5)
        while counter.withLockedValue({ $0 }) < 2, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        XCTAssertEqual(counter.withLockedValue { $0 }, 2, "the wiring's emission and the flush, with main parked throughout")
        XCTAssertTrue(park.isParked, "main stayed parked while the flush landed")
        withExtendedLifetime(orchestrator) {}
    }

    /// The coalesce timer fires on a global queue and hops to the owner, so its hop can land after an immediate emission cancelled it
    /// and a newer coalesced emission armed the next timer. That stale hop must flush nothing and leave the newer timer alone.
    ///
    /// No order of the owner's queue is assumed. One owner turn arms the first timer, holds the owner past that timer's window, so the
    /// timer fires on its queue and its hop can only queue behind the turn, and then emits immediately and re-arms. Whenever the owner
    /// runs the stale hop, it is after the re-arm. The newer timer cannot fire before its deadline, which it took after the re-arm's
    /// stamp, so a third emission sooner than one window after that stamp is the stale hop's flush.
    @RuntimeActor
    func testAStaleCoalesceHopAfterAnImmediateEmitAndRearmFlushesNothingEarly() async throws {
        let emissions = LockedLog<ContinuousClock.Instant>()
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        orchestrator.onSnapshotChange = { _ in emissions.append(.now) }

        let rearmed = armHoldEmitAndRearm(orchestrator)
        XCTAssertEqual(emissions.values.count, 2, "within the owner turn: the wiring's emission and the immediate one")

        let deadline = ContinuousClock.now + .seconds(5)
        while emissions.values.count < 3, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try await Task.sleep(for: .milliseconds(150))
        let values = emissions.values
        XCTAssertEqual(values.count, 3, "exactly one flush after the turn")
        if values.count == 3 {
            XCTAssertGreaterThanOrEqual(rearmed.duration(to: values[2]), .milliseconds(100),
                                        "the flush came no sooner than the newer timer's window, so the stale hop flushed nothing")
        }
    }

    /// One owner turn, synchronous so it cannot suspend: arms the first timer, holds the owner past its window with a wait that ends on
    /// its own and needs nothing from another task, then emits immediately and re-arms. Returns the instant taken just before the re-arm.
    @RuntimeActor
    private func armHoldEmitAndRearm(_ orchestrator: ProxyOrchestrator) -> ContinuousClock.Instant {
        orchestrator.triggerCoalescedSnapshotEmitForTesting()
        _ = DispatchSemaphore(value: 0).wait(timeout: .now() + .milliseconds(400))
        orchestrator.mutateSnapshotForTesting { $0.runtimeStatus.lastHealthSummary = "immediate" }
        let rearmed = ContinuousClock.now
        orchestrator.triggerCoalescedSnapshotEmitForTesting()
        return rearmed
    }

    @RuntimeActor
    private static func armedOrchestrator(counting counter: NIOLockedValueBox<Int>) -> ProxyOrchestrator {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        orchestrator.onSnapshotChange = { _ in counter.withLockedValue { $0 += 1 } }
        orchestrator.triggerCoalescedSnapshotEmitForTesting()
        return orchestrator
    }

    // MARK: - Helpers

    /// Returns once `condition` holds, or after five seconds; the caller's
    /// assertions say what was missing.
    @RuntimeActor
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Builds an orchestrator with a default-shape config but no upstreams
    /// and no proxy startup. Construction alone is enough — the throttle
    /// helpers exist on the type before `startProxy` is called.
    @RuntimeActor
    private func makeOrchestrator() -> ProxyOrchestrator {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }
}
