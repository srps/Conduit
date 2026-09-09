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
package func credentialBasedAuthenticatorProvider(
    configProvider: @escaping @Sendable () -> ProxyConfig,
    credentialProvider: any CredentialProvider,
    outcomeHandler: (@Sendable (RuntimeAuthOutcome, String, String?) -> Void)? = nil,
    eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
) -> @Sendable (UpstreamProxy) throws -> ProxyAuthenticator {
    { destination in
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

package struct UpstreamAuthenticationDenied: Error, LocalizedError {
    package let endpoint: String

    package var errorDescription: String? {
        "Authentication refused for unconfigured or disabled upstream \(endpoint). Add the trusted endpoint to Upstreams before using credentials there."
    }
}
