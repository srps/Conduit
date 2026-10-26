// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// Holds the next `holds` physical attempts inside the destination guard, on the writer's drain queue, so a test
/// decides when the physical work proceeds. Each held attempt signals `entered` and waits for one `release()`. The hold
/// is bounded: a test that never releases it fails instead of hanging.
final class HeldDestinationGuard: RecordFileDestinationGuarding, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let holds: NIOLockedValueBox<Int>
    private let admittedOnMain = NIOLockedValueBox<Bool?>(nil)

    init(holds: Int = 1) {
        self.holds = NIOLockedValueBox(holds)
    }

    /// Whether the first admission ran on the main thread. Nil until an attempt reaches the guard.
    var admittedOnMainThread: Bool? { admittedOnMain.withLockedValue { $0 } }

    /// Holds the next `count` attempts, after earlier attempts passed unheld.
    func arm(_ count: Int) { holds.withLockedValue { $0 += count } }

    func admit(destination: URL) throws {
        admittedOnMain.withLockedValue { if $0 == nil { $0 = Thread.isMainThread } }
        let hold = holds.withLockedValue { remaining -> Bool in
            guard remaining > 0 else { return false }
            remaining -= 1
            return true
        }
        guard hold else { return }
        entered.signal()
        _ = released.wait(timeout: .now() + 10)
    }

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {}

    func release() { released.signal() }
}

/// A timer body that holds its first call until the test releases it, ignoring cancellation. Later calls signal
/// `joinLaterStart()`, then sleep until their deadline on the continuous clock, so cancellation ends them.
final class HeldTimerBody: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    /// One signal per call after the held one: each is a later reservation's timer.
    private let laterStarted = DispatchSemaphore(value: 0)
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
        laterStarted.signal()
        try await Task.sleep(until: deadline, clock: .continuous)
    }

    /// A synchronous function is where the blocking wait belongs: the compiler rejects it inside the async `sleep`.
    private func holdUntilReleased() {
        _ = released.wait(timeout: .now() + 10)
    }

    /// Waits, bounded, for the next timer after the held one to start.
    func joinLaterStart() -> DispatchTimeoutResult {
        laterStarted.wait(timeout: .now() + 10)
    }

    func release() {
        released.signal()
    }
}

/// Timer bodies numbered by call, from zero. A call in `held` signals `entered`, ignores cancellation, and returns normally
/// only when the test releases that call; it then reaches the waiter's expiry path as a late timer. Every other call
/// sleeps until its deadline on the continuous clock, so cancellation ends it. `calls` counts every timer created.
final class IndexedTimerBodies: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let gates: [Int: DispatchSemaphore]
    private let count = NIOLockedValueBox(0)

    init(held: Set<Int>) {
        gates = Dictionary(uniqueKeysWithValues: held.map { ($0, DispatchSemaphore(value: 0)) })
    }

    var calls: Int { count.withLockedValue { $0 } }

    func sleep(until deadline: ContinuousClock.Instant) async throws {
        let index = count.withLockedValue { value -> Int in
            defer { value += 1 }
            return value
        }
        guard let gate = gates[index] else {
            try await Task.sleep(until: deadline, clock: .continuous)
            return
        }
        entered.signal()
        hold(gate)
    }

    /// A synchronous function is where the blocking wait belongs: the compiler rejects it inside the async `sleep`.
    private func hold(_ gate: DispatchSemaphore) {
        _ = gate.wait(timeout: .now() + 10)
    }

    func release(_ index: Int) {
        gates[index]?.signal()
    }
}

/// A snapshot that differs from its neighbours by one field, so a test can tell generations apart.
func snapshotValue(_ queries: Int) -> ProxyOrchestratorSnapshot {
    var value = ProxyOrchestratorSnapshot()
    value.dnsQueryCount = queries
    return value
}

/// An absolute deadline `seconds` from now, the shape every writer takes.
func deadline(in seconds: Double) -> ContinuousClock.Instant {
    ContinuousClock.now.advanced(by: .milliseconds(Int(seconds * 1_000)))
}

/// A new scratch directory. Tests never name the machine's configuration paths.
func makeScratchDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("conduit-drain-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// The blocking join for a cleanup seam, in a synchronous function: the compiler rejects the wait inside async code.
func joinCleanup(_ cleaned: DispatchSemaphore) -> DispatchTimeoutResult {
    cleaned.wait(timeout: .now() + 10)
}

/// Drains a snapshot writer. A `busy` result means an earlier wait's physical reservation is still held, so this joins its
/// cleanup through the writer's `onDrainCleanup` seam, then waits again. Bounded to two joins. `busy` is never reported
/// as success: it is returned as it is when the joins run out.
func drainJoining(_ writer: any SnapshotArtifactWriting, cleaned: DispatchSemaphore) async -> SnapshotFlushOutcome {
    var outcome = await writer.drain(until: deadline(in: 10))
    for _ in 0..<2 where outcome == .busy {
        XCTAssertEqual(joinCleanup(cleaned), .success, "the held reservation's cleanup was joined")
        outcome = await writer.drain(until: deadline(in: 10))
    }
    return outcome
}

func decodeSnapshot(at url: URL) throws -> ProxyOrchestratorSnapshot {
    try CanonicalJSON.decoder().decode(ProxyOrchestratorSnapshot.self, from: Data(contentsOf: url))
}
