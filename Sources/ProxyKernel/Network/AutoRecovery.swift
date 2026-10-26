// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What the recovery ladder acts on. Every step and check names the listener lifecycle the ladder was admitted under, and the service
/// resolves what it touches from that stamp in the same step as the check. Once a stop or start has moved the lifecycle on, the step
/// throws `CancellationError` and touches nothing, so a ladder that passed its own check before a newer start never reaches that start's
/// pool or listener.
package protocol RecoverableProxyService: AnyObject {
    /// The lifecycle the listener is under now. A ladder reads it before each step, so a stop or start that landed in the step ends the ladder.
    var listenerStamp: ListenerStamp { get }
    func closeStalledConnections(expecting stamp: ListenerStamp) async throws -> Int
    func reauthenticate(expecting stamp: ListenerStamp) async throws
    func switchToNextUpstream(expecting stamp: ListenerStamp) async throws -> String?
    func performHealthCheck(expecting stamp: ListenerStamp) async throws -> HealthCheckResult
    /// Recycle the HTTP listener accept socket while preserving the connection pool,
    /// CONNECT coordinator, SOCKS5 server, and accepted child connections. Replaces
    /// the previous `restartLocalProxy` semantics (which nuked the pool, killing
    /// in-flight HTTPS streams). See `docs/design-vpn-flap-resilience.md`.
    ///
    /// Binds nothing when `stamp` is no longer current. Returns the stamp the listener is now under.
    func recycleListener(expecting stamp: ListenerStamp) async throws -> ListenerStamp
}

enum RecoveryStep: String, CaseIterable, Identifiable {
    case closeStalledConnections
    case reauthenticate
    case switchUpstream
    case recycleListener

    package var id: String { rawValue }

    var description: String {
        switch self {
        case .closeStalledConnections:
            return "Close stalled connections"
        case .reauthenticate:
            return "Re-authenticate"
        case .switchUpstream:
            return "Switch upstream proxy"
        case .recycleListener:
            return "Recycle proxy listener"
        }
    }
}

package final class AutoRecovery: @unchecked Sendable {
    weak var service: RecoverableProxyService?
    private let logger: any LogSink
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?

    package init(
        service: RecoverableProxyService?,
        logger: any LogSink,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.service = service
        self.logger = logger
        self.eventSink = eventSink
    }

    /// Runs the ladder until a step's health check passes.
    ///
    /// `trigger` is the failure that started the ladder; each step's failed
    /// health check replaces it. While the latest failure is `.unreachable`,
    /// re-authenticating cannot help (no upstream answered to challenge), so
    /// that step is skipped. The exhaustion line names the last failure
    /// rather than always suggesting a changed password (#147).
    ///
    /// `isCurrent` is asked before each step and after each step's outcome:
    /// once it says no (a VPN transition made the triggering evidence
    /// stale), the ladder stops with `recovery.abandoned` and returns `false`
    /// without declaring exhaustion (#155). A configuration refusal (`.configurationRefused`)
    /// stops the ladder before any step, or at the first check that returns it, with
    /// `recovery.skipped`; it is never reported as exhaustion. The ladder runs on the main
    /// actor, where the orchestrator advances its routing generation, so a
    /// check and the outcome it allows happen in one turn.
    ///
    /// `stamp` is the listener lifecycle the ladder began under; a caller that acts on a failure read earlier passes the stamp it read then.
    /// The ladder also stops once the service's stamp has moved, which a stop or start does even when routing did not change. A recycle that
    /// falls back to a cold start returns the stamp it published under, and the ladder carries that forward, so its own fallback is not refused.
    @MainActor
    package func recover(
        trigger: HealthCheckFailure? = nil,
        since stamp: ListenerStamp? = nil,
        isCurrent: @MainActor () -> Bool = { true }
    ) async -> Bool {
        guard let service else { return false }
        var expected = stamp ?? service.listenerStamp
        var latestFailure = trigger
        // A refused check is not an upstream outcome, and no step can supply a configured
        // duration. Refuse before any side effect, so no step runs for this trigger.
        if let detail = Self.configurationRefusal(latestFailure) {
            return refuse(detail: detail)
        }

        for step in RecoveryStep.allCases {
            guard isCurrent(), service.listenerStamp == expected else { return abandon(at: "next_step=\(step.rawValue)") }
            if step == .reauthenticate, case .unreachable(let detail) = latestFailure {
                emit("recovery.step_skipped", detail: "step=\(step.rawValue) reason=upstream_unreachable summary=\(detail)")
                logger.log(.notice, "Recovery step skipped: \(step.description) (no upstream answered: \(detail)).", category: .network)
                continue
            }
            do {
                let detail: String?
                switch step {
                case .closeStalledConnections:
                    let closedCount = try await service.closeStalledConnections(expecting: expected)
                    detail = "\(closedCount) stale connection\(closedCount == 1 ? "" : "s") closed"
                case .reauthenticate:
                    try await service.reauthenticate(expecting: expected)
                    detail = nil
                case .switchUpstream:
                    let next = try await service.switchToNextUpstream(expecting: expected)
                    logger.log(.notice, "Switched upstream proxy to \(next ?? "next candidate").", category: .network)
                    detail = next.map { "next=\($0)" }
                case .recycleListener:
                    expected = try await service.recycleListener(expecting: expected)
                    detail = nil
                }

                let health = try await service.performHealthCheck(expecting: expected)
                // The step's outcome is stale evidence once a transition or a stop ran.
                guard isCurrent(), service.listenerStamp == expected else { return abandon(at: "after_step=\(step.rawValue)") }
                if health.healthy {
                    let suffix = detail.map { " (\($0))" } ?? ""
                    logger.log(.notice, "Recovery step succeeded: \(step.description)\(suffix).", category: .network)
                    return true
                }
                if let failure = health.failure { latestFailure = failure }
                // The check did not run for a configured duration: stop here, with no later step.
                if let refusal = Self.configurationRefusal(health.failure) {
                    return refuse(detail: refusal)
                }
                let suffix = detail.map { " \($0);" } ?? ""
                logger.log(.warning, "Recovery step completed but health check still failing: \(step.description).\(suffix) \(health.summary)", category: .network)
            } catch {
                // A step or check refused because the lifecycle moved on lands here too, and the stamp check then ends the ladder.
                guard isCurrent(), service.listenerStamp == expected else { return abandon(at: "after_step=\(step.rawValue)") }
                logger.log(.warning, "Recovery step failed: \(step.description) (\(error.displayDescription)).", category: .network)
            }
        }

        let exhausted = Self.exhaustion(for: latestFailure)
        emit("recovery.exhausted", detail: "failure=\(exhausted.failure) summary=\(latestFailure?.summary ?? "unknown")")
        logger.log(.error, exhausted.message, category: .network)
        return false
    }

    private func abandon(at position: String) -> Bool {
        emit("recovery.abandoned", detail: "reason=superseded \(position)")
        logger.log(.notice, "Recovery stopped: the routing or the listener it began under has been superseded (\(position)).", category: .network)
        return false
    }

    /// The refusal's detail when `failure` says a configured duration is one the runtime
    /// cannot hold, or nil. Such a failure is a local configuration fact, not an upstream one.
    private static func configurationRefusal(_ failure: HealthCheckFailure?) -> String? {
        if case .configurationRefused(let detail)? = failure { return detail }
        return nil
    }

    /// Records the refusal as the existing `recovery.skipped` outcome and returns `false`.
    /// The ladder is not exhausted: no step ran, or it stopped at a refused check.
    private func refuse(detail: String) -> Bool {
        emit("recovery.skipped", detail: "reason=configuration_refused summary=\(detail)")
        logger.log(.error, Self.configurationRefusalMessage(detail), category: .network)
        return false
    }

    private static func configurationRefusalMessage(_ detail: String) -> String {
        "Automatic recovery stopped: a configured duration is one the runtime cannot hold (\(detail)). Correct the configuration; health checks continue."
    }

    /// The exhaustion event's `failure=` value and the log line derived from
    /// it. Only a credential failure or rejection points at the password; an unclassified
    /// failure keeps the conditional hint.
    static func exhaustion(for failure: HealthCheckFailure?) -> (failure: String, message: String) {
        switch failure {
        case .credentialUnavailable(let detail):
            return ("credential_unavailable",
                    "Automatic recovery exhausted all steps: no usable proxy credential (\(detail)). Re-enter your password in Settings.")
        case .authenticationRejected:
            return ("authentication_rejected",
                    "Automatic recovery exhausted all steps: the upstream rejected authentication. Your password may have changed — re-enter it in Settings.")
        case .configurationRefused(let detail):
            // `recover` never reaches exhaustion with this failure; this keeps the mapping total.
            return ("configuration_refused", configurationRefusalMessage(detail))
        case .unreachable(let detail):
            return ("unreachable",
                    "Automatic recovery exhausted all steps: no upstream proxy answered (\(detail)). Health checks continue and routing resumes when an upstream is reachable.")
        case .upstreamStatus(let code, let upstream):
            return ("upstream_status",
                    "Automatic recovery exhausted all steps: the upstream answered HTTP \(code) via \(upstream).")
        case nil:
            return ("unknown",
                    "Automatic recovery exhausted all steps. If authentication was rejected, your password may have changed — re-enter it in Settings.")
        }
    }

    private func emit(_ event: String, detail: String) {
        eventSink?(RuntimeEvent(kind: .health, event: event, detail: detail))
    }
}

/// Admission control for `AutoRecovery.recover()`.
///
/// Every failed health check used to start a ladder, and a ladder that
/// exhausted restarted the health loop with an immediate check — which
/// failed for the same reason and started the next ladder. proxy.log for
/// 2026-08-28 shows 47 ladders in six minutes, overlapping, with the
/// "switch upstream" steps of concurrent runs flipping the active upstream
/// back and forth several times a second. The gate admits one ladder at a
/// time and, after one exhausts, none for `cooldown`; a healthy result
/// clears the cooldown so a real recovery is acted on at once.
package struct RecoveryGate: Sendable {
    package enum Decision: Equatable, Sendable {
        case run
        case alreadyRunning
        case coolingDown(remaining: TimeInterval)
    }

    package let cooldown: TimeInterval
    package private(set) var inFlight = false
    private var exhaustedAt: Date?

    package init(cooldown: TimeInterval = 60) {
        self.cooldown = cooldown
    }

    /// Ask to start a ladder. `.run` marks it in flight; the caller must
    /// pair it with `end(recovered:)`.
    package mutating func begin(now: Date = Date()) -> Decision {
        if inFlight { return .alreadyRunning }
        if let exhaustedAt {
            let remaining = cooldown - now.timeIntervalSince(exhaustedAt)
            if remaining > 0 { return .coolingDown(remaining: remaining) }
            self.exhaustedAt = nil
        }
        inFlight = true
        return .run
    }

    package mutating func end(recovered: Bool, now: Date = Date()) {
        inFlight = false
        exhaustedAt = recovered ? nil : now
    }

    /// A healthy check: forget the last exhaustion so the next failure is
    /// acted on immediately.
    package mutating func reset() {
        exhaustedAt = nil
    }
}
