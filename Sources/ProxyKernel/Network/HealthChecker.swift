// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// Why a health check was unhealthy. Recovery branches on the case.
package enum HealthCheckFailure: Error, Equatable, Sendable {
    /// The upstream challenged and no usable credential answered; the
    /// recovery ladder cannot supply one. See `CredentialFailureClassifying`.
    case credentialUnavailable(detail: String)
    /// The upstream answered with a status outside 2xx–4xx.
    case upstreamStatus(code: Int, upstream: String)
    /// The upstream answered and refused the credential the ladder offered
    /// (a final 407). Re-authenticating can help, unlike `.unreachable`.
    case authenticationRejected(detail: String)
    /// No usable answer: unreachable, timed out, refused, or the proxy is stopped.
    case unreachable(detail: String)
    /// The check did not run: a configured duration is one the runtime cannot hold. This says
    /// nothing about any upstream, so it feeds neither the breaker nor recovery.
    case configurationRefused(detail: String)

    package var summary: String {
        switch self {
        case .credentialUnavailable(let detail), .authenticationRejected(let detail), .unreachable(let detail),
             .configurationRefused(let detail):
            return detail
        case .upstreamStatus(let code, let upstream):
            return "HTTP \(code) via \(upstream)"
        }
    }
}

package struct HealthCheckResult: Equatable {
    package var healthy: Bool
    package var summary: String
    package var activeUpstream: String?
    package var responseTimeMS: Int
    package var failure: HealthCheckFailure?

    package init(healthy: Bool, summary: String, activeUpstream: String?, responseTimeMS: Int) {
        self.healthy = healthy
        self.summary = summary
        self.activeUpstream = activeUpstream
        self.responseTimeMS = responseTimeMS
        self.failure = nil
    }

    package static func healthy(summary: String, activeUpstream: String?, responseTimeMS: Int) -> HealthCheckResult {
        HealthCheckResult(healthy: true, summary: summary, activeUpstream: activeUpstream, responseTimeMS: responseTimeMS)
    }

    package static func unhealthy(_ failure: HealthCheckFailure, activeUpstream: String? = nil, responseTimeMS: Int) -> HealthCheckResult {
        var result = HealthCheckResult(healthy: false, summary: failure.summary, activeUpstream: activeUpstream, responseTimeMS: responseTimeMS)
        result.failure = failure
        return result
    }
}

/// One `start` of a `HealthChecker`, handed to each check it runs. A check
/// that outlives its run (`stop`, or a `start` that replaced it) is stale:
/// its verdict measured under the old run and must not be applied. Check
/// `isCurrent` on the executor that applies the verdict, the one that also
/// calls `stop` and `start`, so nothing can replace the run in between.
package struct HealthCheckRun: Sendable {
    fileprivate let generation: UInt64
    fileprivate let state: NIOLockedValueBox<HealthCheckLoopState>

    package var isCurrent: Bool { state.withLockedValue { $0.generation == generation } }
}

/// The run generation and its one in-flight check. Only the current
/// generation's check may set or clear `inFlight`, so a check left over
/// from a stopped run cannot free the slot under a newer run's check (#181).
fileprivate struct HealthCheckLoopState: Sendable {
    var generation: UInt64 = 0
    var inFlight = false
}

package final class HealthChecker {
    package init() {}
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.HealthChecker")
    private let state = NIOLockedValueBox(HealthCheckLoopState())

    package func start(
        interval: TimeInterval,
        operation: @escaping @Sendable () async -> HealthCheckResult,
        onResult: @escaping @Sendable (HealthCheckResult) -> Void
    ) {
        start(interval: interval, operation: { _ in await operation() }, onResult: onResult)
    }

    /// Runs `operation` now and then on the adaptive interval, at most one
    /// check of this run at a time; a tick that finds one in flight is
    /// dropped. A check that finishes after its run was replaced or stopped
    /// is stale: it leaves the newer run's state alone, is not delivered to
    /// `onResult` and does not reschedule; `onSuperseded` gets it instead.
    /// The `onResult` fence is checked off the caller's executor, so a stop
    /// that lands between the check and the call can still see one late
    /// delivery. A caller whose state must not take a stale verdict checks
    /// `HealthCheckRun.isCurrent` where it applies it, as the orchestrator does.
    package func start(
        interval: TimeInterval,
        operation: @escaping @Sendable (HealthCheckRun) async -> HealthCheckResult,
        onResult: @escaping @Sendable (HealthCheckResult) -> Void,
        onSuperseded: @escaping @Sendable (HealthCheckResult) -> Void = { _ in }
    ) {
        stop()
        let state = self.state
        let run = HealthCheckRun(generation: state.withLockedValue { $0.generation }, state: state)
        let adaptiveState = AdaptiveScheduleController(baseInterval: interval)
        let queue = self.queue
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler {
            let claimed = state.withLockedValue { loop in
                guard loop.generation == run.generation, !loop.inFlight else { return false }
                loop.inFlight = true
                return true
            }
            guard claimed else { return }
            Task {
                let result = await operation(run)
                let current = state.withLockedValue { loop in
                    guard loop.generation == run.generation else { return false }
                    loop.inFlight = false
                    return true
                }
                guard current else {
                    onSuperseded(result)
                    return
                }
                onResult(result)
                let nextInterval = await adaptiveState.nextInterval(after: result)
                queue.async {
                    guard run.isCurrent else { return }
                    timer.schedule(deadline: .now() + nextInterval, repeating: nextInterval)
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// Whether a loop is scheduled. `start` restarts the loop with an
    /// immediate check, so callers that only need the loop to *exist* check
    /// this first instead of restarting it.
    package var isRunning: Bool { timer != nil }

    /// Whether the current run has a check in flight. A stale check from a
    /// stopped run does not count.
    package var isCheckInFlight: Bool { state.withLockedValue { $0.inFlight } }

    /// Ends the current run: its timer stops, and a check still in flight
    /// becomes stale (see `start`). The next run starts with no check in
    /// flight.
    package func stop() {
        timer?.cancel()
        timer = nil
        state.withLockedValue { loop in
            loop.generation &+= 1
            loop.inFlight = false
        }
    }
}

private final class AdaptiveScheduleState {
    private let baseInterval: TimeInterval
    private var currentInterval: TimeInterval
    private var consecutiveHealthy = 0
    private var consecutiveUnhealthy = 0
    private var postRecoveryChecksRemaining = 0

    init(baseInterval: TimeInterval) {
        self.baseInterval = baseInterval
        self.currentInterval = baseInterval
    }

    func nextInterval(after result: HealthCheckResult) -> TimeInterval {
        if result.healthy {
            consecutiveHealthy += 1
            let wasRecovering = consecutiveUnhealthy > 0
            consecutiveUnhealthy = 0
            if wasRecovering {
                postRecoveryChecksRemaining = 3
                currentInterval = baseInterval
                return currentInterval
            }
            if postRecoveryChecksRemaining > 0 {
                postRecoveryChecksRemaining -= 1
                currentInterval = baseInterval
                return currentInterval
            }
            currentInterval = consecutiveHealthy > 5 ? (baseInterval * 2) : baseInterval
            return currentInterval
        }

        consecutiveUnhealthy += 1
        consecutiveHealthy = 0
        postRecoveryChecksRemaining = 0
        if consecutiveUnhealthy > 2 {
            currentInterval = max(baseInterval * 0.25, 1)
        } else {
            currentInterval = max(baseInterval * 0.5, 1)
        }
        return currentInterval
    }
}

private actor AdaptiveScheduleController {
    private let state: AdaptiveScheduleState

    init(baseInterval: TimeInterval) {
        self.state = AdaptiveScheduleState(baseInterval: baseInterval)
    }

    func nextInterval(after result: HealthCheckResult) -> TimeInterval {
        state.nextInterval(after: result)
    }
}
