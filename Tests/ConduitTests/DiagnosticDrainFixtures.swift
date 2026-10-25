// SPDX-License-Identifier: Apache-2.0
import Dispatch
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// Holds the first physical attempt inside the destination guard, on the writer's drain queue, so a test
/// decides when the physical work proceeds. The hold is bounded: a test that never releases it fails
/// instead of hanging.
final class HeldDestinationGuard: RecordFileDestinationGuarding, @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    private let released = DispatchSemaphore(value: 0)
    private let holds = NIOLockedValueBox(1)
    private let admittedOnMain = NIOLockedValueBox<Bool?>(nil)

    /// Whether the first admission ran on the main thread. Nil until an attempt reaches the guard.
    var admittedOnMainThread: Bool? { admittedOnMain.withLockedValue { $0 } }

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
