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
/// `RuntimeEventRepeatGate`. A fallback reaches `outcomeHandler` every
/// time, with the failure's GSS codes as the fourth argument; the
/// orchestrator applies the same limit to the event and line it derives.
///
/// A credential read that fails (the Keychain refused, could not prompt,
/// holds a corrupt entry, or is still waiting on a prompt) goes to
/// `eventSink` as `auth.credentials_unavailable`, through a second
/// `RuntimeEventRepeatGate`, and the handshake carries on as if no password
/// were saved. How often the store is read is `credentialProvider`'s
/// business: `CredentialManager` caches, so a burst of fallbacks makes one
/// read. A 407 on the NTLM authenticate leg asks the provider to drop what
/// it cached (`auth.credentials_dropped` when it did).
///
/// `kerberosTokenProvider` and `now` are test seams.
package func credentialBasedAuthenticatorProvider(
    configProvider: @escaping @Sendable () -> ProxyConfig,
    credentialProvider: any CredentialProvider,
    kerberosTicketRecovery: (any KerberosTicketRecovering)? = nil,
    outcomeHandler: (@Sendable (RuntimeAuthOutcome, String, String?, String?) -> Void)? = nil,
    eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil,
    kerberosTokenProvider: (@Sendable () -> any GSSTokenProvider)? = nil,
    now: @escaping @Sendable () -> Date = { Date() }
) -> @Sendable (UpstreamProxy) throws -> ProxyAuthenticator {
    let failureGate = RuntimeEventRepeatGate(now: now)
    let unavailableGate = RuntimeEventRepeatGate(now: now)
    let kdcRecovery = kerberosTicketRecovery.map { KerberosKDCRecovery(recoverer: $0, now: now) }
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
        let reportUnavailable: @Sendable (String) -> Void = { reason in
            guard let suppressed = unavailableGate.admit(host: host, reason: reason) else { return }
            eventSink?(RuntimeEvent(kind: .auth, event: "auth.credentials_unavailable",
                                    detail: "host=\(host) reason=\(reason) source=handshake suppressed=\(suppressed)"))
        }
        let dropRejected: @Sendable (String) -> Void = { _ in
            guard credentialProvider.dropRejectedCredentials(for: upstream) else { return }
            eventSink?(RuntimeEvent(kind: .auth, event: "auth.credentials_dropped",
                                    detail: "host=\(host) reason=rejected"))
        }
        switch config.authMode {
        case .systemNegotiated:
            return NegotiateAuthenticator(
                kerberos: KerberosAuthenticator(tokenProvider: kerberosTokenProvider?()
                    ?? SystemGSSTokenProvider(kdcRecovery: kdcRecovery, eventSink: eventSink)),
                ntlmFallbackProvider: {
                    // A failed read is reported and answered like no saved
                    // password: Kerberos' own failure goes to the request.
                    let credentials: ProxyCredentials?
                    do {
                        credentials = try credentialProvider.credentials(for: upstream)
                    } catch {
                        reportUnavailable(error.credentialReadFailureReason)
                        return nil
                    }
                    return credentials.map { NTLMAuthenticator(credentials: $0, onCredentialsRejected: dropRejected) }
                },
                onKerberosSuccess: { successHost in
                    outcomeHandler?(.kerberos, successHost, nil, nil)
                },
                onKerberosFallback: { fallbackHost, reason, diagnostics in
                    outcomeHandler?(.ntlmFallback, fallbackHost, reason, diagnostics)
                },
                onKerberosFailure: { failedHost, reason, diagnostics in
                    guard let suppressed = failureGate.admit(host: failedHost, reason: reason) else { return }
                    let codes = diagnostics.map { " \($0)" } ?? ""
                    eventSink?(RuntimeEvent(kind: .auth, event: "auth.kerberos_failed",
                                            detail: "host=\(failedHost) reason=\(reason)\(codes) suppressed=\(suppressed)"))
                }
            )
        case .ntlmv2:
            let credentials: ProxyCredentials?
            do {
                credentials = try credentialProvider.credentials(for: upstream)
            } catch {
                reportUnavailable(error.credentialReadFailureReason)
                throw error
            }
            guard let credentials else {
                reportUnavailable(CredentialManagerError.missingCredentials.credentialReadFailureReason)
                throw CredentialManagerError.missingCredentials
            }
            outcomeHandler?(.ntlmDirect, host, nil, nil)
            return NTLMAuthenticator(credentials: credentials, onCredentialsRejected: dropRejected)
        }
    }
}

package struct UpstreamAuthenticationDenied: Error, LocalizedError {
    package let endpoint: String

    package var errorDescription: String? {
        "Authentication refused for unconfigured or disabled upstream \(endpoint). Add the trusted endpoint to Upstreams before using credentials there."
    }
}
