// SPDX-License-Identifier: Apache-2.0
// Single source of truth for building the orchestrator's authenticator
// factory closure from a ProxyConfig + CredentialProvider. Lives in
// ProxyAuth because it references concrete NTLM / Negotiate authenticators;
// the kernel no longer references those types.
//
// Callers that previously relied on ProxyOrchestrator's internal factory
// (`makeAuthenticatorProvider`) use
// `credentialBasedAuthenticatorProvider(...)` and pass the result into
// `ProxyOrchestrator.init(authenticatorProvider:)`.
//
// The factory takes an `any CredentialProvider` so `pm-proxy` / `pm-tunnel`
// can inject `InMemoryCredentialProvider` without linking `PlatformMac`.
//
// Routing may discover new endpoints through PAC. Credential authority is
// narrower: only an enabled, explicitly configured host/port may authenticate.

import Foundation
import ProxyKernel

/// Returns the `(upstream) -> ProxyAuthenticator` closure that
/// `ProxyOrchestrator.makeAuthenticatorProvider` previously produced. Both
/// pm-proxy (headless daemon) and the SwiftUI app use this to avoid
/// duplicating the config-driven authenticator selection.
///
/// The `configProvider` closure re-reads the live config on every
/// invocation so that hot-reloaded auth mode changes take effect without
/// reconstructing the factory. `credentialProvider` is captured by
/// reference for the same reason.
///
/// `outcomeHandler` is the observability hook. When supplied, the
/// factory wires it into `NegotiateAuthenticator`'s success / fallback
/// callbacks (and fires it at `.ntlmDirect` when the config explicitly
/// selects NTLMv2). `AppState` and `pm-proxy` pass
/// `orchestrator.reportAuthOutcome(_:host:reason:)` so GUI and headless
/// snapshots observe the same runtime auth state. AGENTS.md:
/// "Always emit a RuntimeEvent first for any routing / auth / failover /
/// health / config decision."
///
/// A Kerberos failure with no NTLM answer goes to `eventSink` as
/// `auth.kerberos_failed`, at most once a minute per host and reason: a
/// failing proxy fails every request, and one event per request would push
/// everything else out of the bounded `RuntimeEventLog`. See
/// `KerberosFailureEventGate`.
package func credentialBasedAuthenticatorProvider(
    configProvider: @escaping @Sendable () -> ProxyConfig,
    credentialProvider: any CredentialProvider,
    outcomeHandler: (@Sendable (RuntimeAuthOutcome, String, String?) -> Void)? = nil,
    eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
) -> @Sendable (UpstreamProxy) throws -> ProxyAuthenticator {
    let failureGate = KerberosFailureEventGate()
    return { destination in
        let config = configProvider()
        guard let upstream = config.enabledUpstreams.first(where: {
            $0.host.caseInsensitiveCompare(destination.host) == .orderedSame
                && $0.port == destination.port
        }) else {
            eventSink?(RuntimeEvent(kind: .auth, event: "auth.upstream_not_trusted", detail: destination.endpoint))
            throw UpstreamAuthenticationDenied(endpoint: destination.endpoint)
        }
        let host = upstream.endpoint
        switch config.authMode {
        case .systemNegotiated:
            return NegotiateAuthenticator(
                ntlmFallbackProvider: {
                    guard
                        let credentials = try? credentialProvider.credentials(for: upstream)
                    else {
                        return nil
                    }
                    return NTLMAuthenticator(credentials: credentials)
                },
                onKerberosSuccess: { successHost in
                    outcomeHandler?(.kerberos, successHost, nil)
                },
                onKerberosFallback: { fallbackHost, reason in
                    outcomeHandler?(.ntlmFallback, fallbackHost, reason)
                },
                onKerberosFailure: { failedHost, reason in
                    guard failureGate.shouldEmit(host: failedHost, reason: reason) else { return }
                    eventSink?(RuntimeEvent(kind: .auth, event: "auth.kerberos_failed",
                                            detail: "host=\(failedHost) reason=\(reason)"))
                }
            )
        case .ntlmv2:
            guard let credentials = try credentialProvider.credentials(for: upstream) else {
                throw CredentialManagerError.missingCredentials
            }
            outcomeHandler?(.ntlmDirect, host, nil)
            return NTLMAuthenticator(credentials: credentials)
        }
    }
}

/// Limits `auth.kerberos_failed` to one event per host and reason per
/// `repeatInterval`. Each pair has its own cooldown, so a proxy that
/// alternates between two reasons still reports each at most once per
/// interval. Time rather than success re-arms it: a continuation leg can
/// fail on every request right after an initial leg that succeeded, so a
/// success says nothing about whether the failure is over. Bounded at
/// `maximumEntries` pairs; past that the oldest goes, which at worst repeats
/// an event.
package final class KerberosFailureEventGate: @unchecked Sendable {
    package static let maximumEntries = 64

    private struct Key: Hashable {
        let host: String
        let reason: String
    }

    private let repeatInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// When each host and reason was last reported.
    private var lastReported: [Key: Date] = [:]

    package init(repeatInterval: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.repeatInterval = repeatInterval
        self.now = now
    }

    package func shouldEmit(host: String, reason: String) -> Bool {
        let key = Key(host: host, reason: reason)
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        if let at = lastReported[key], current.timeIntervalSince(at) < repeatInterval {
            return false
        }
        if lastReported[key] == nil, lastReported.count >= Self.maximumEntries,
           let oldest = lastReported.min(by: { $0.value < $1.value })?.key {
            lastReported.removeValue(forKey: oldest)
        }
        lastReported[key] = current
        return true
    }
}

package struct UpstreamAuthenticationDenied: Error, LocalizedError {
    package let endpoint: String

    package var errorDescription: String? {
        "Authentication refused for unconfigured or disabled upstream \(endpoint). Add the trusted endpoint to Upstreams before using credentials there."
    }
}
