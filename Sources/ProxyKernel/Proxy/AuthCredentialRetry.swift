// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// Retries the first leg of an upstream auth handshake while the credential
/// is momentarily unavailable, and stops retrying while it stays that way.
///
/// The Kerberos SSO extension needs a moment after a VPN reconnect before it
/// hands the ticket back; one wait covers that. Once a retried handshake
/// still fails, the host is in outage for `outageHold` and further
/// handshakes fail at once, so a credential that is really gone does not
/// cost every connection the retry budget. A success clears the outage.
///
/// Called from the auth `Task` off the event loop; the waits are `async`.
package final class AuthCredentialRetry: @unchecked Sendable {
    package static let shared = AuthCredentialRetry()

    /// Retries after the first failure.
    package let attempts: Int
    package let delay: TimeInterval
    package let outageHold: TimeInterval
    package static let maximumHosts = 32

    private let sleep: @Sendable (TimeInterval) async throws -> Void
    private let now: @Sendable () -> Date
    private let lock = NIOLock()
    private var outages: [String: Date] = [:]

    package init(
        attempts: Int = 2,
        delay: TimeInterval = 0.75,
        outageHold: TimeInterval = 30,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) },
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.attempts = attempts
        self.delay = delay
        self.outageHold = outageHold
        self.sleep = sleep
        self.now = now
    }

    /// `auth.initialToken(for:)`, retried per the policy above.
    package func initialToken(
        from auth: any ProxyAuthenticator,
        host: String,
        logger: (any LogSink)? = nil,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) async throws -> String {
        var attempt = 0
        while true {
            do {
                let token = try auth.initialToken(for: host)
                clearOutage(host: host)
                return token
            } catch where error.isCredentialRetryable {
                guard attempt < attempts, !isInOutage(host: host) else {
                    markOutage(host: host)
                    throw error
                }
                attempt += 1
                eventSink?(RuntimeEvent(kind: .auth, event: "auth.credential_retry",
                                        detail: "host=\(host) attempt=\(attempt) delayMs=\(Int(delay * 1000))"))
                logger?.log(.info, "Credential unavailable for \(host); retrying the handshake in \(Int(delay * 1000)) ms (attempt \(attempt) of \(attempts)).", category: .auth)
                try await sleep(delay)
            }
        }
    }

    package func isInOutage(host: String) -> Bool {
        let current = now()
        return lock.withLock {
            guard let since = outages[host] else { return false }
            if current.timeIntervalSince(since) >= outageHold {
                outages.removeValue(forKey: host)
                return false
            }
            return true
        }
    }

    private func markOutage(host: String) {
        let current = now()
        lock.withLock {
            if outages[host] != nil { return }
            if outages.count >= Self.maximumHosts,
               let oldest = outages.min(by: { $0.value < $1.value })?.key {
                outages.removeValue(forKey: oldest)
            }
            outages[host] = current
        }
    }

    private func clearOutage(host: String) {
        lock.withLock { _ = outages.removeValue(forKey: host) }
    }

    package func reset() {
        lock.withLock { outages.removeAll() }
    }
}
