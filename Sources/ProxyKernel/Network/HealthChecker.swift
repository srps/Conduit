// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

package struct HealthCheckResult: Equatable {
    package var healthy: Bool
    package var summary: String
    package var activeUpstream: String?
    package var responseTimeMS: Int

    package init(healthy: Bool, summary: String, activeUpstream: String?, responseTimeMS: Int) {
        self.healthy = healthy
        self.summary = summary
        self.activeUpstream = activeUpstream
        self.responseTimeMS = responseTimeMS
    }
}

package final class HealthChecker {
    package init() {}
    private var timer: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.HealthChecker")
    private let checkInFlight = NIOLockedValueBox(false)
    private let generation = NIOLockedValueBox(0)

    package func start(
        interval: TimeInterval,
        operation: @escaping @Sendable () async -> HealthCheckResult,
        onResult: @escaping @Sendable (HealthCheckResult) -> Void
    ) {
        stop()
        let runGeneration = generation.withLockedValue { current in
            current += 1
            return current
        }
        let inFlight = self.checkInFlight
        let adaptiveState = AdaptiveScheduleController(baseInterval: interval)
        let queue = self.queue
        let generation = self.generation
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler {
            let alreadyRunning = inFlight.withLockedValue { running in
                if running { return true }
                running = true
                return false
            }
            guard !alreadyRunning else { return }
            Task {
                let result = await operation()
                inFlight.withLockedValue { $0 = false }
                onResult(result)
                let nextInterval = await adaptiveState.nextInterval(after: result)
                queue.async {
                    let stillActive = generation.withLockedValue { $0 == runGeneration }
                    guard stillActive else { return }
                    timer.schedule(deadline: .now() + nextInterval, repeating: nextInterval)
                }
            }
        }
        self.timer = timer
        timer.resume()
    }

    package func stop() {
        timer?.cancel()
        timer = nil
        generation.withLockedValue { $0 += 1 }
        checkInFlight.withLockedValue { $0 = false }
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
