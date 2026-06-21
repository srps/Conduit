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
// The provider protocol is keyed `credentials(for: UpstreamProxy)`
// (per-upstream lookup, Optional return). This factory resolves the
// host string the orchestrator passes into a matching `UpstreamProxy` from
// the live config and forwards that to the provider.

import Foundation
import ProxyKernel

/// Returns the same `(host) -> ProxyAuthenticator` closure that
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
    outcomeHandler: (@Sendable (RuntimeAuthOutcome, String, String?) -> Void)? = nil
) -> @Sendable (String) throws -> ProxyAuthenticator {
    { host in
        let config = configProvider()
        // Find the upstream the orchestrator routed this handshake to.
        // The orchestrator's host parameter is the upstream's `host:port`
        // string; if no match is found, fall back to the first configured
        // upstream (matches the prior behaviour where the credential lookup
        // ignored the upstream entirely).
        let upstream = matchingUpstream(host: host, in: config)
            ?? config.upstreams.first
        switch config.authMode {
        case .systemNegotiated:
            return NegotiateAuthenticator(
                ntlmFallbackProvider: {
                    guard
                        let upstream,
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
            guard let upstream else {
                throw CredentialManagerError.missingCredentials
            }
            guard let credentials = try credentialProvider.credentials(for: upstream) else {
                throw CredentialManagerError.missingCredentials
            }
            outcomeHandler?(.ntlmDirect, host, nil)
            return NTLMAuthenticator(credentials: credentials)
        }
    }
}

/// Match the orchestrator's `host:port` (or bare `host`) string against
/// the configured upstreams. Returns `nil` when no upstream matches —
/// callers fall back to the first configured upstream so the
/// "ignore upstream identity" behaviour stays the default.
private func matchingUpstream(host: String, in config: ProxyConfig) -> UpstreamProxy? {
    // Try host:port match first (orchestrator's typical format).
    for upstream in config.upstreams {
        let key = "\(upstream.host):\(upstream.port)"
        if key == host { return upstream }
    }
    // Fall back to host-only match — handles callers that pass just the host.
    for upstream in config.upstreams where upstream.host == host {
        return upstream
    }
    return nil
}
