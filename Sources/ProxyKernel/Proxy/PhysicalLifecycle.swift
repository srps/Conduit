// SPDX-License-Identifier: Apache-2.0

/// The order of one module's listener work: the epoch that ranks its starts and stops, and the one physical effect, a bind or a teardown,
/// running now. `ProxyOrchestrator` keeps one each for the proxy listeners, the DNS forwarder and the tunnels.
///
/// Each start and each stop takes the next epoch, so the latest admitted operation owns the module's listeners and its part of the
/// snapshot. An effect waits for the one before it to end, then claims the slot only if its epoch is still the latest, with no suspension
/// between that check and the claim. An effect that has claimed the slot runs to its end, so a teardown never runs beside a bind and closes
/// everything that bind left. A restart or reconcile takes no epoch of its own: it captures the latest, so a stop admitted before or during
/// it supersedes it instead of being undone by it.
@MainActor
final class PhysicalLifecycle {
    private(set) var epoch = 0
    /// Whether the latest admitted operation is a start. A restart or reconcile acts only then: after a stop, the module stays stopped.
    private(set) var admitsRunning = false
    /// Only `run` sets it, once the effect owns the slot, and the effect clears it itself before it completes, so a waiter never awaits a
    /// finished handle.
    private var active: Task<Void, Error>?
    /// The one whole start in flight and its epoch: its preparation before the bind as well as the bind, up to what it publishes. A newer
    /// start, or a restart under the same epoch, replaces it, and a start clears it only while it holds that start's own completion, so a
    /// finished older one never clears a newer one.
    private var start: (epoch: Int, completion: Task<Void, Error>)?

    nonisolated init() {}

    /// The completion of the start that is the latest admitted operation, while it runs. An equivalent start joins it and gets its real
    /// result, rather than reading a `starting` snapshot as done. After a stop is admitted there is none: a start then runs after that stop.
    func joinableStart() -> Task<Void, Error>? {
        guard admitsRunning, let start, start.epoch == epoch else { return nil }
        return start.completion
    }

    /// Runs a whole start admitted at `epoch` as the joinable completion, and returns or throws its own result.
    func runStart(epoch: Int, _ body: @escaping @MainActor () async throws -> Void) async throws {
        let completion = Task<Void, Error> { try await body() }
        start = (epoch, completion)
        defer { if self.start?.completion == completion { self.start = nil } }
        try await completion.value
    }

    /// Admits a start (`running`) or a stop, superseding every operation admitted before it, and returns its epoch.
    func admit(running: Bool) -> Int {
        epoch += 1
        admitsRunning = running
        return epoch
    }

    func isCurrent(_ epoch: Int) -> Bool { epoch == self.epoch }

    /// Throws `CancellationError` once `epoch` is superseded.
    func ensureCurrent(_ epoch: Int) throws {
        guard isCurrent(epoch) else { throw CancellationError() }
    }

    /// Runs `body` as the effect for `epoch` once the active effect, if any, has ended. Returns `false`, having run nothing, when a newer
    /// operation was admitted meanwhile: that operation now owns the listeners. Rethrows what `body` throws.
    @discardableResult
    func run(epoch: Int, _ body: @escaping @MainActor () async throws -> Void) async throws -> Bool {
        while let active {
            _ = await active.result
        }
        guard isCurrent(epoch) else { return false }
        let effect = Task<Void, Error> {
            defer { self.active = nil }
            try await body()
        }
        active = effect
        try await effect.value
        return true
    }
}
