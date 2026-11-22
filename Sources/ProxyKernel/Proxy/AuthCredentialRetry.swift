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
/// The token calls themselves block (a GSS exchange, or the NTLM fallback
/// waiting on a Keychain read), so they run on `tokenQueue`, never on a
/// cooperative thread: a burst as wide as the pool would otherwise hold
/// every thread until the read's deadline (#327).
package final class AuthCredentialRetry: @unchecked Sendable {
    package static let shared = AuthCredentialRetry()

    /// Concurrent, outside the cooperative pool. Nothing that ends a call
    /// runs here: the credential read has its own serial queue.
    private static let tokenQueue = DispatchQueue(
        label: "io.github.srps.Conduit.auth-token", qos: .userInitiated, attributes: .concurrent
    )

    /// Token calls running or queued on `tokenQueue`, each holding a thread
    /// while it blocks. A slot frees when the call returns, not when its
    /// handshake goes away, so connection churn cannot stack calls past it.
    /// Past it a handshake fails as one past the pending-handshake limit.
    package static let maximumTokenCallsInFlight = 64
    private static let tokenCallsInFlight = NIOLockedValueBox(0)
    package static var tokenCallsInFlightCount: Int { tokenCallsInFlight.withLockedValue { $0 } }

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

    /// `auth.initialToken(for:)`, retried per the policy above. `host` is the
    /// authentication target (the SPN); `outageKey` scopes the outage, and
    /// callers pass the upstream endpoint so two proxies on one host with
    /// different ports do not share it. Defaults to `host`.
    package func initialToken(
        from auth: any ProxyAuthenticator,
        host: String,
        outageKey: String? = nil,
        logger: (any LogSink)? = nil,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) async throws -> String {
        let key = outageKey ?? host
        let deferring = auth as? any FallbackDeferringAuthenticator
        var attempt = 0
        while true {
            // The fallback scheme, if the authenticator has one, is withheld
            // until the last attempt so the primary gets its retries.
            let lastAttempt = attempt >= attempts || isInOutage(host: key)
            do {
                if let deferring {
                    let result = try await offPool(host: key, eventSink: eventSink) {
                        try deferring.initialToken(for: host, allowFallback: lastAttempt)
                    }
                    // A downgrade is the primary's outage: later handshakes go
                    // straight to the fallback until the hold expires.
                    if result.usedFallback {
                        markOutage(host: key)
                        eventSink?(RuntimeEvent(kind: .auth, event: "auth.credential_outage",
                                                detail: "upstream=\(key) holdSeconds=\(Int(outageHold))"))
                    } else {
                        clearOutage(host: key)
                    }
                    return result.token
                }
                let token = try await offPool(host: key, eventSink: eventSink) { try auth.initialToken(for: host) }
                clearOutage(host: key)
                return token
            } catch where error.isCredentialRetryable {
                guard !lastAttempt else {
                    markOutage(host: key)
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

    private func offPool<T: Sendable>(
        host: String,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        _ body: @escaping @Sendable () throws -> T
    ) async throws -> T {
        let limit = Self.maximumTokenCallsInFlight
        let admitted = Self.tokenCallsInFlight.withLockedValue { count in
            guard count < limit else { return false }
            count += 1
            return true
        }
        guard admitted else {
            eventSink?(RuntimeEvent(kind: .auth, event: "auth.handshake_rejected",
                                    detail: "host=\(host) scope=token_calls pending=\(limit) limit=\(limit)"))
            throw ConnectionPoolError.authHandshakeLimitExceeded
        }
        return try await withCheckedThrowingContinuation { continuation in
            Self.tokenQueue.async {
                let result = Result { try body() }
                Self.tokenCallsInFlight.withLockedValue { $0 -= 1 }
                continuation.resume(with: result)
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
