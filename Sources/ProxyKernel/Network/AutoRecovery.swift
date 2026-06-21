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

    package init(service: RecoverableProxyService?, logger: any LogSink) {
        self.service = service
        self.logger = logger
    }

    package func recover() async -> Bool {
        guard let service else { return false }

        for step in RecoveryStep.allCases {
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
                let suffix = detail.map { " \($0);" } ?? ""
                logger.log(.warning, "Recovery step completed but health check still failing: \(step.description).\(suffix) \(health.summary)", category: .network)
            } catch {
                logger.log(.warning, "Recovery step failed: \(step.description) (\(error.localizedDescription)).", category: .network)
            }
        }

        logger.log(.error, "Automatic recovery exhausted all steps. If authentication was rejected, your password may have changed — re-enter it in Settings.", category: .network)
        return false
    }
}
