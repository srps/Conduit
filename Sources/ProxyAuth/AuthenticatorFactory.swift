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
/// `auth.kerberos_failed`, once per host and reason: a failing proxy fails
/// every request, and one event per request would push everything else out
/// of the bounded `RuntimeEventLog`. See `KerberosFailureEventGate`.
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
                    failureGate.clear(host: successHost)
                    outcomeHandler?(.kerberos, successHost, nil)
                },
                onKerberosFallback: { fallbackHost, reason in
                    failureGate.clear(host: fallbackHost)
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

/// Remembers, per host, the reason of the last `auth.kerberos_failed` event,
/// so the event marks the start of a failure (or a change in its reason)
/// rather than every request that meets it. A Kerberos success or an NTLM
/// fallback for the host ends the failure, and the next one is reported
/// again. Bounded at `maximumHosts`; past that the oldest entry goes, which
/// at worst repeats an event.
package final class KerberosFailureEventGate: @unchecked Sendable {
    package static let maximumHosts = 32

    private let lock = NSLock()
    /// Host to the reason last reported and the order it was recorded in.
    private var entries: [String: (reason: String, sequence: UInt64)] = [:]
    private var nextSequence: UInt64 = 0

    package init() {}

    package func shouldEmit(host: String, reason: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if entries[host]?.reason == reason { return false }
        if entries[host] == nil, entries.count >= Self.maximumHosts,
           let oldest = entries.min(by: { $0.value.sequence < $1.value.sequence })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[host] = (reason, nextSequence)
        nextSequence += 1
        return true
    }

    package func clear(host: String) {
        lock.lock()
        entries.removeValue(forKey: host)
        lock.unlock()
    }
}

package struct UpstreamAuthenticationDenied: Error, LocalizedError {
    package let endpoint: String

    package var errorDescription: String? {
        "Authentication refused for unconfigured or disabled upstream \(endpoint). Add the trusted endpoint to Upstreams before using credentials there."
    }
}
