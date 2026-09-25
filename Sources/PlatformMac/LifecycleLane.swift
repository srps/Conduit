// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// The starts and stops of one runtime — the app's proxy, the app's DNS
/// forwarder, the daemon's whole runtime — and which of them is the latest.
///
/// Both hosts send a start's and a stop's platform-surface work to the same
/// serial `PlatformWork` queue and suspend while it runs. The queue orders the
/// work: a stop issued while a start's apply is out queues its clear behind
/// that apply, so the machine ends cleared. The lane does the rest:
///
/// - **Supersession.** Every admitted start or stop advances the generation.
///   An earlier one still in flight checks its `Token` after each suspension
///   and, inside its platform block, before each manager step, and does
///   nothing more once superseded: the operation that overtook it owns the
///   surfaces and has queued its own work behind this one's. The check and
///   the next queueing happen in one turn of the host's actor (see
///   `PlatformWork.run`), so nothing slips between them.
/// - **Coalescing.** A start while a start is the latest and still running,
///   or a stop while a stop is, adds nothing: it joins that one instead of
///   queueing a second copy of its work. Without it every extra toggle while
///   a helper was slow put another teardown on the queue, unbounded.
/// - **Quiescence.** `waitUntilIdle()` returns once nothing is in flight, so
///   the config reconciler can order its passes after the lifecycle's work
///   rather than beside it.
@MainActor
package final class LifecycleLane {
    package enum Kind: String, Sendable {
        case start
        case stop
    }

    /// What an operation carries into its platform block: readable from any
    /// thread, so a block can stop between two manager steps once overtaken.
    package struct Token: Sendable {
        package let generation: Int
        fileprivate let latest: LatestGeneration

        package var isSuperseded: Bool { latest.value != generation }
    }

    package enum Admission {
        /// Run it, carrying this token, and `end(_:)` it when done.
        case run(Token)
        /// The same kind of operation is already the latest and running;
        /// `join(_:)` it instead.
        case coalesced(joining: Int)
    }

    /// Names the lane in events: `proxy`, `dns`, `runtime`.
    package let name: String
    private let latest = LatestGeneration()
    private var latestKind: Kind?
    private var latestRunning = false
    private var active = 0
    private var endWaiters: [Int: [CheckedContinuation<Void, Never>]] = [:]
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []

    package init(name: String) {
        self.name = name
    }

    /// How many generations have begun, termination's included.
    package var current: Int { latest.value }
    package var isIdle: Bool { active == 0 }
    /// How many callers are in `waitUntilIdle()`. For a test that has to
    /// know a reconcile pass is waiting, not time it.
    package var idleWaiterCount: Int { idleWaiters.count }

    /// - Parameter coalescing: `false` for an operation that must run even
    ///   when its twin is out — the daemon's stop on the way to `exit`, which
    ///   supersedes the one in flight rather than returning without exiting.
    package func begin(_ kind: Kind, coalescing: Bool = true) -> Admission {
        if coalescing, latestKind == kind, latestRunning {
            return .coalesced(joining: latest.value)
        }
        let generation = latest.advance()
        latestKind = kind
        latestRunning = true
        active += 1
        return .run(Token(generation: generation, latest: latest))
    }

    /// Every admitted operation ends exactly once, superseded or not.
    package func end(_ token: Token) {
        active -= 1
        if token.generation == latest.value { latestRunning = false }
        for waiter in endWaiters.removeValue(forKey: token.generation) ?? [] { waiter.resume() }
        if active == 0 {
            let waiters = idleWaiters
            idleWaiters = []
            for waiter in waiters { waiter.resume() }
        }
    }

    /// Waits for the operation holding `generation` to end. Called right
    /// after `begin` answered `.coalesced`, with no suspension between, so
    /// that operation is still running.
    package func join(_ generation: Int) async {
        await withCheckedContinuation { continuation in
            endWaiters[generation, default: []].append(continuation)
        }
    }

    /// Supersedes whatever is in flight without starting anything: for a
    /// quit, which is not an operation on the lane but must stop every
    /// block at its next step.
    package func supersedeAll() {
        _ = latest.advance()
        latestKind = nil
        latestRunning = false
    }

    package func waitUntilIdle() async {
        while active > 0 {
            await withCheckedContinuation { idleWaiters.append($0) }
        }
    }

    /// `lifecycle.superseded`: `operation` stopped after its last suspension
    /// instead of going on. `reason` is `superseded` when a later start or
    /// stop overtook it, or the runtime state that made its follow-ups moot.
    package func supersededEvent(operation: String, token: Token, reason: String = "superseded") -> RuntimeEvent {
        RuntimeEvent(
            kind: .lifecycle,
            event: "lifecycle.superseded",
            detail: "operation=\(operation) generation=\(token.generation) current=\(latest.value) reason=\(reason)"
        )
    }

    /// `lifecycle.coalesced`: `operation` joined the identical one in flight.
    package func coalescedEvent(operation: String, joining generation: Int) -> RuntimeEvent {
        RuntimeEvent(
            kind: .lifecycle,
            event: "lifecycle.coalesced",
            detail: "operation=\(operation) joined=\(generation)"
        )
    }
}

/// The lane's latest generation, readable off the host's actor.
private final class LatestGeneration: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0

    var value: Int { lock.withLock { stored } }

    func advance() -> Int {
        lock.withLock {
            stored += 1
            return stored
        }
    }
}
