// SPDX-License-Identifier: Apache-2.0
import ProxyKernel

/// Reports a failed write of an advertised surface (the system proxy, the
/// shell environment) after a config change or a switch turned on, and asks
/// for evidence again a bounded number of times (#194, narrow).
///
/// Before this, a re-apply that threw was a log warning and nothing else.
/// The reconciler's baseline had moved on, so no later save looked again,
/// and the system proxy, which has no periodic tick, kept pointing at the
/// old listener until the next wake, network, VPN or settings report.
///
/// A retry decides nothing on its own. When its delay runs out it reports
/// `config.reapply_retry` and runs the host's existing drift pass for that
/// surface once, which repairs only what it finds drifted and keeps its own
/// budgets and fences. The pass's verdict ends the episode
/// (`config.reapply_recovered`), or the next delay starts; past the last one
/// it is `config.reapply_abandoned reason=exhausted` and the surface is left
/// to the ordinary triggers. In STYLE rule 11 terms it is a backstop.
///
/// Bounded: one request and one worker per surface, so at most two of each.
/// A newer failure of the same surface replaces the request and starts its
/// schedule again; a verdict reached for the request it replaced is dropped.
/// A request carries the lifecycle token of the run it failed in: once a
/// start or stop has overtaken it, that operation owns the surface and the
/// request is abandoned (`reason=superseded`).
///
/// This is not per-surface applied state; that is the full #194, with #186
/// and #48.
@MainActor
package final class ConfigReapplyRetry {
    /// The raw value is the events' `surface=`.
    package enum Surface: String, CaseIterable, Sendable {
        case systemProxy = "system_proxy"
        case environment
    }

    /// What wrote the surface. The raw value is the events' `cause=`.
    package enum Cause: String, Sendable {
        /// A config change re-applied a surface whose contents it changed.
        case configChange = "config_change"
        /// A switch turned on applied its surface while the proxy runs.
        case switchOn = "switch_on"
        /// The system proxy switch stayed on and its mode changed, which
        /// rewrites the surface in the other shape.
        case modeChange = "mode_change"
    }

    /// One attempt's verdict, from the host.
    package enum Outcome: Equatable, Sendable {
        /// The surface holds what the committed config asks for.
        case applied
        /// It does not; `reason` says what the pass found.
        case failed(reason: String)
        /// Nothing to retry: the proxy stopped, the switch went off or
        /// moved, or a start or stop overtook the request.
        case notWanted(reason: String)
    }

    /// Successive delays before each attempt; their count is the number of
    /// attempts.
    package struct Schedule: Sendable {
        package let delays: [Duration]

        /// About 10 s, 70 s and 370 s after the failure. The first is long
        /// enough for a helper that refused a write to come back or a
        /// contended location to settle; the last is past the drift-repair
        /// budget windows, so a withheld repair has its window back. Three,
        /// because a failure that outlasts six minutes is not transient, and
        /// the ordinary triggers and the environment tick still apply.
        package static let standard = Schedule(delays: [.seconds(10), .seconds(60), .seconds(300)])

        package init(delays: [Duration]) {
            precondition(!delays.isEmpty && delays.count <= 8 && delays.allSatisfy { $0 >= .zero })
            self.delays = delays
        }
    }

    private struct Request {
        let id: UInt64
        let token: LifecycleLane.Token
    }

    private let schedule: Schedule
    private let emit: @MainActor (RuntimeEvent, LogLevel) -> Void
    /// Runs one drift pass for a surface and returns its verdict. Set by the
    /// host once it exists; holds the host weakly.
    package var attempt: (@MainActor (Surface, LifecycleLane.Token) async -> Outcome)?
    private var requests: [Surface: Request] = [:]
    private var workers: [Surface: (id: UInt64, task: Task<Void, Never>)] = [:]
    private var nextID: UInt64 = 0

    package init(schedule: Schedule = .standard, emit: @escaping @MainActor (RuntimeEvent, LogLevel) -> Void) {
        self.schedule = schedule
        self.emit = emit
    }

    /// Surfaces with a retry outstanding. For tests.
    package var pending: Set<Surface> { Set(requests.keys) }

    /// Waits until no retry is outstanding. For tests.
    package func drain() async {
        while let worker = workers.first?.value {
            await worker.task.value
        }
    }

    /// A write of `surface` failed during a run whose lifecycle token is
    /// `token`. Reports it and (re)starts that surface's retries.
    package func failed(_ surface: Surface, cause: Cause, reason: String, token: LifecycleLane.Token) {
        nextID &+= 1
        requests[surface] = Request(id: nextID, token: token)
        report("config.reapply_failed",
               "surface=\(surface.rawValue) cause=\(cause.rawValue) retry_in_seconds=\(Self.seconds(schedule.delays[0])) "
                   + "attempts=\(schedule.delays.count) reason=\(reason)",
               .warning)
        // A worker already out may be asleep on a long delay: the new
        // request starts its own schedule now. The old worker is cancelled
        // and the new one waits for it, so one attempt at most runs per
        // surface; one that is mid-attempt finishes it, and its verdict is
        // dropped with an event.
        let previous = workers[surface]?.task
        previous?.cancel()
        nextID &+= 1
        let workerID = nextID
        workers[surface] = (workerID, Task { [weak self] in
            await previous?.value
            await self?.work(surface)
            self?.finish(surface, worker: workerID)
        })
    }

    /// Drops every outstanding retry without an event: the host is going
    /// away, and its teardown reports itself.
    package func cancelAll() {
        requests = [:]
        for (_, worker) in workers { worker.task.cancel() }
        workers = [:]
    }

    private func finish(_ surface: Surface, worker: UInt64) {
        if workers[surface]?.id == worker { workers[surface] = nil }
    }

    /// One surface's retries, until its request is resolved or gone. Every
    /// suspension is followed by a check that the request is still the one
    /// this loop is serving.
    private func work(_ surface: Surface) async {
        var serving: UInt64?
        var attempt = 0
        while let request = requests[surface] {
            if serving != request.id { serving = request.id; attempt = 0 }
            do { try await Task.sleep(for: schedule.delays[attempt]) }
            catch { return } // Cancelled by `cancelAll`, or by a newer request's worker.
            guard requests[surface]?.id == request.id else { continue }
            if request.token.isSuperseded {
                resolve(surface, request, "config.reapply_abandoned", "reason=superseded attempts=\(attempt)", .info)
                continue
            }
            attempt += 1
            report("config.reapply_retry", "surface=\(surface.rawValue) attempt=\(attempt) of=\(schedule.delays.count)", .notice)
            guard let run = self.attempt else { return }
            let outcome = await run(surface, request.token)
            // Replaced or cancelled while the pass ran: its verdict belongs
            // to a request nobody is waiting on.
            guard requests[surface]?.id == request.id else {
                if requests[surface] != nil {
                    report("config.reapply_result_superseded",
                           "surface=\(surface.rawValue) attempt=\(attempt) outcome=\(Self.describe(outcome))", .info)
                }
                continue
            }
            switch outcome {
            case .notWanted(let reason):
                resolve(surface, request, "config.reapply_abandoned", "reason=\(reason) attempts=\(attempt)", .info)
            case .applied where request.token.isSuperseded:
                // A start or stop overtook the pass: the surface is that
                // operation's now, whatever the pass saw.
                resolve(surface, request, "config.reapply_abandoned", "reason=superseded attempts=\(attempt)", .info)
            case .applied:
                resolve(surface, request, "config.reapply_recovered", "attempts=\(attempt)", .notice)
            case .failed(let reason) where attempt >= schedule.delays.count:
                report("config.reapply_failed",
                       "surface=\(surface.rawValue) cause=retry attempt=\(attempt) of=\(schedule.delays.count) reason=\(reason)", .warning)
                resolve(surface, request, "config.reapply_abandoned", "reason=exhausted attempts=\(attempt)", .warning)
            case .failed(let reason):
                report("config.reapply_failed",
                       "surface=\(surface.rawValue) cause=retry attempt=\(attempt) of=\(schedule.delays.count) "
                           + "retry_in_seconds=\(Self.seconds(schedule.delays[attempt])) reason=\(reason)",
                       .warning)
            }
        }
    }

    private func resolve(_ surface: Surface, _ request: Request, _ name: String, _ detail: String, _ level: LogLevel) {
        requests[surface] = nil
        report(name, "surface=\(surface.rawValue) \(detail)", level)
    }

    private func report(_ name: String, _ detail: String, _ level: LogLevel) {
        emit(RuntimeEvent(kind: .config, event: name, detail: detail), level)
    }

    private static func describe(_ outcome: Outcome) -> String {
        switch outcome {
        case .applied: return "applied"
        case .failed: return "failed"
        case .notWanted: return "not_wanted"
        }
    }

    private static func seconds(_ duration: Duration) -> Int64 {
        let parts = duration.components
        return parts.seconds + (parts.attoseconds > 0 ? 1 : 0)
    }
}

/// The system-proxy half of a retry attempt, the same for both hosts: the
/// drift repair the settings, wake, path and VPN triggers run, then a read
/// of whether the surface now holds what was asked.
package enum SystemProxyReapplyRetry {
    /// Returns the verdict, and when to run the host's contention retry if
    /// the location repair budget withheld the write.
    package static func run(
        manager: SystemProxyManager,
        work: PlatformWork,
        config: ProxyConfig,
        mode: SystemProxyMode,
        localPACURL: String?,
        token: LifecycleLane.Token,
        fence: PlatformRequestFence,
        events: RuntimeEventLog,
        logger: any LogSink
    ) async -> (ConfigReapplyRetry.Outcome, Duration?) {
        await work.run {
            manager.serialized { () -> (ConfigReapplyRetry.Outcome, Duration?) in
                // Under the manager's lock, as a clear takes it: a stop or a
                // switch moved since this was queued has cleared or will
                // clear, and must not be undone.
                guard !token.isSuperseded else { return (.notWanted(reason: "superseded"), nil) }
                let requested = fence.current
                guard requested.manageSystemProxy, requested.systemProxyMode == mode else {
                    return (.notWanted(reason: "switch_changed"), nil)
                }
                let retry: Duration?
                do {
                    retry = try manager.reconcileLocation(config: config, mode: mode, localPACURL: localPACURL, apply: true)
                } catch {
                    let event = RuntimeEvent(kind: .config, event: "platform.location_failed",
                                             detail: "operation=reconcile surface=systemProxy reason=\(error.localizedDescription)")
                    events.append(event)
                    logger.log(.warning, "Network location: \(event.detail ?? "")", category: .system)
                    return (.failed(reason: error.localizedDescription), nil)
                }
                if manager.isApplied(config: config, mode: mode, localPACURL: localPACURL) { return (.applied, nil) }
                return (.failed(reason: retry == nil ? "not_applied" : "repair_withheld"), retry)
            }
        }
    }
}
