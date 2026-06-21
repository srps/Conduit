// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum ProxyAuthError: Error, LocalizedError {
    case noSuitableScheme
    case ticketUnavailable
    case challengeFailed(String)

    package var errorDescription: String? {
        switch self {
        case .noSuitableScheme:
            return "The upstream proxy did not offer a supported authentication scheme."
        case .ticketUnavailable:
            return "No Kerberos ticket is available for the target proxy."
        case .challengeFailed(let detail):
            return "Proxy authentication challenge failed: \(detail)"
        }
    }
}

/// Strategy for generating Proxy-Authorization headers during the upstream 407 handshake.
/// Instances are per-connection and may hold mutable state (e.g. GSS context).
package protocol ProxyAuthenticator: AnyObject, Sendable {
    /// The HTTP auth scheme this authenticator produces (e.g. "NTLM", "Negotiate").
    var scheme: String { get }

    /// Generate the initial Proxy-Authorization header value (scheme + space + token).
    func initialToken(for host: String) throws -> String

    /// Process a 407 challenge. Returns the next `Proxy-Authorization` header value,
    /// or `nil` in two cases:
    /// - The challenge headers don't contain a scheme this authenticator handles
    ///   (e.g. NTLM authenticator receiving a Negotiate-only challenge).
    /// - The GSS context reached `GSS_S_COMPLETE` with zero-length output token,
    ///   meaning authentication is finished and no outgoing token is needed
    ///   (RFC 2744 §2.2.1: "If no token need be sent, gss_init_sec_context
    ///   will indicate this by setting the length field of the output_token to zero").
    ///
    /// In the handler 407 flow, `nil` means "no header to send" -- the handler treats
    /// this as a rejection because the proxy still expects auth. The successful
    /// mutual-auth completion leg arrives as a 200 OK (with an optional
    /// `Proxy-Authenticate` response header), not as another 407.
    func processChallenge(headerValues: [String], host: String) throws -> String?

    /// Whether this authenticator can handle a `Proxy-Authenticate` header with the given scheme.
    func canHandle(scheme: String) -> Bool

    /// Discard any connection-scoped state (called on pool eviction or reconnect).
    func reset()
}
