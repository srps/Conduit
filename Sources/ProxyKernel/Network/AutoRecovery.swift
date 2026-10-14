// SPDX-License-Identifier: Apache-2.0
import Foundation

package protocol RecoverableProxyService: AnyObject {
    func closeStalledConnections() async throws -> Int
    func reauthenticate() async throws
    func switchToNextUpstream() async throws -> String?
    func performHealthCheck() async -> HealthCheckResult
    /// Recycle the HTTP listener accept socket while preserving the connection pool,
    /// CONNECT coordinator, SOCKS5 server, and accepted child connections. Replaces
    /// the previous `restartLocalProxy` semantics (which nuked the pool, killing
    /// in-flight HTTPS streams). See `docs/design-vpn-flap-resilience.md`.
    func recycleListener() async throws
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
    package func recover(trigger: HealthCheckFailure? = nil) async -> Bool {
        guard let service else { return false }
        var latestFailure = trigger

        for step in RecoveryStep.allCases {
            if step == .reauthenticate, case .unreachable(let detail) = latestFailure {
                emit("recovery.step_skipped", detail: "step=\(step.rawValue) reason=upstream_unreachable summary=\(detail)")
                logger.log(.notice, "Recovery step skipped: \(step.description) (no upstream answered: \(detail)).", category: .network)
                continue
            }
            do {
                let detail: String?
                switch step {
                case .closeStalledConnections:
                    let closedCount = try await service.closeStalledConnections()
                    detail = "\(closedCount) stale connection\(closedCount == 1 ? "" : "s") closed"
                case .reauthenticate:
                    try await service.reauthenticate()
                    detail = nil
                case .switchUpstream:
                    let next = try await service.switchToNextUpstream()
                    logger.log(.notice, "Switched upstream proxy to \(next ?? "next candidate").", category: .network)
                    detail = next.map { "next=\($0)" }
                case .recycleListener:
                    try await service.recycleListener()
                    detail = nil
                }

                let health = await service.performHealthCheck()
                if health.healthy {
                    let suffix = detail.map { " (\($0))" } ?? ""
                    logger.log(.notice, "Recovery step succeeded: \(step.description)\(suffix).", category: .network)
                    return true
                }
                if let failure = health.failure { latestFailure = failure }
                let suffix = detail.map { " \($0);" } ?? ""
                logger.log(.warning, "Recovery step completed but health check still failing: \(step.description).\(suffix) \(health.summary)", category: .network)
            } catch {
                logger.log(.warning, "Recovery step failed: \(step.description) (\(error.displayDescription)).", category: .network)
            }
        }

        let exhausted = Self.exhaustion(for: latestFailure)
        emit("recovery.exhausted", detail: "failure=\(exhausted.failure) summary=\(latestFailure?.summary ?? "unknown")")
        logger.log(.error, exhausted.message, category: .network)
        return false
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
