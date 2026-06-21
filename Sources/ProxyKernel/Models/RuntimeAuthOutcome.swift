// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Runtime auth outcome observed by the authenticator when a handshake runs.
///
/// This is distinct from `AuthenticationMode` (config-level intent). The
/// config says "use Kerberos with NTLM fallback" (`systemNegotiated`) or
/// "use NTLM directly" (`ntlmv2`). The *runtime* outcome says what actually
/// happened on the wire — which is what the UI chip, the auth-category log,
/// and the event stream need to reflect so a silent Kerberos→NTLM fallback
/// is no longer invisible.
///
/// Emitted by `NegotiateAuthenticator` (via the factory-supplied handler in
/// `credentialBasedAuthenticatorProvider`) and by the `NTLMAuthenticator`
/// construction path when the config is explicitly `ntlmv2`. Consumed by
/// `ProxyOrchestrator.reportAuthOutcome(_:host:reason:)`, which emits the
/// `.auth` event, logs a derived line, and updates the snapshot.
package enum RuntimeAuthOutcome: String, Sendable, Codable, Equatable {
    /// `systemNegotiated` config: Kerberos (SPNEGO) handshake produced a
    /// token. This is the expected path when the user has a TGT reachable
    /// by the proxy's service realm.
    case kerberos
    /// `systemNegotiated` config: Kerberos returned a credential-unavailable
    /// error (e.g. `BAD_MECH`, `NO_CRED`, expired TGT) and the authenticator
    /// fell back to NTLMv2 using stored Keychain credentials. The Keychain
    /// prompt a user may see comes from this path.
    case ntlmFallback
    /// `ntlmv2` config: NTLMv2 was used directly, no Kerberos attempt. Not a
    /// fallback — the user explicitly configured NTLM.
    case ntlmDirect

    /// Stable string used in `ConnectionAuditRecord.authMethod` and other
    /// compliance / log surfaces. Distinct from the raw `rawValue` because
    /// the audit log is a pinned wire contract (consumed by Splunk /
    /// Datadog dashboards) and shouldn't shift if we ever rename a case.
    package var auditTag: String {
        switch self {
        case .kerberos: return "Negotiate"
        case .ntlmFallback: return "NTLM"
        case .ntlmDirect: return "NTLM"
        }
    }
}
