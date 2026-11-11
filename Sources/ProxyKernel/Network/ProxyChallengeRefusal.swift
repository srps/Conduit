// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Refuses the proxy-authentication challenges that reach a Conduit-owned
/// `URLSession` (decision 0045).
///
/// A session with no delegate answers a proxy's 407 itself: CFNetwork asks
/// macOS's `AuthBrokerAgent` for a saved proxy credential, and when that one
/// fails the user gets an "authenticate to the proxy server" dialog for
/// Conduit. Conduit authenticates to an upstream only on its own
/// Kerberos/NTLM path, so its sessions never let CFNetwork do it.
///
/// The disposition is `.cancelAuthenticationChallenge`: it ends the task at
/// once with `URLError.cancelled`, so CFNetwork never gets to its default
/// handling. `.rejectProtectionSpace` would only move it to the proxy's next
/// offered scheme, and after the last one leave the outcome to CFNetwork.
package enum ProxyChallengeRefusal {
    /// True for a proxy's challenge, whatever its scheme. Every other
    /// challenge (server trust, an origin's 401) keeps CFNetwork's default
    /// handling.
    package static func isProxyChallenge(_ challenge: URLAuthenticationChallenge) -> Bool {
        challenge.protectionSpace.isProxy()
    }

    /// `proxy=<host>:<port> method=<scheme>`, the tokens every refusal reports.
    package static func describe(_ challenge: URLAuthenticationChallenge) -> String {
        let space = challenge.protectionSpace
        return "proxy=\(space.host):\(space.port) method=\(methodName(space.authenticationMethod))"
    }

    package static func event(for challenge: URLAuthenticationChallenge, client: String, suppressed: Int) -> RuntimeEvent {
        RuntimeEvent(
            kind: .auth,
            event: "auth.proxy_challenge_refused",
            detail: "client=\(client) \(describe(challenge)) suppressed=\(suppressed)"
        )
    }

    private static func methodName(_ method: String) -> String {
        switch method {
        case NSURLAuthenticationMethodHTTPBasic: "basic"
        case NSURLAuthenticationMethodHTTPDigest: "digest"
        case NSURLAuthenticationMethodNegotiate: "negotiate"
        case NSURLAuthenticationMethodNTLM: "ntlm"
        case NSURLAuthenticationMethodDefault: "default"
        default: "other"
        }
    }
}

/// The delegate for a Conduit-owned `URLSession` that needs no other delegate
/// callback: it cancels every proxy challenge and reports it, at most once a
/// minute per proxy and scheme, and leaves every other challenge to CFNetwork.
package final class ProxyChallengeRefusingDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let client: String
    private let gate: RuntimeEventRepeatGate
    private let report: @Sendable (RuntimeEvent) -> Void

    /// `client` names the session's job in the event (`doh`, `origin_resolver`).
    /// Sessions that share a `gate` share its once-a-minute limit.
    package init(client: String, gate: RuntimeEventRepeatGate, report: @escaping @Sendable (RuntimeEvent) -> Void) {
        self.client = client
        self.gate = gate
        self.report = report
    }

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard ProxyChallengeRefusal.isProxyChallenge(challenge) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        let space = challenge.protectionSpace
        if let suppressed = gate.admit(host: "\(client) \(space.host):\(space.port)", reason: space.authenticationMethod) {
            report(ProxyChallengeRefusal.event(for: challenge, client: client, suppressed: suppressed))
        }
        completionHandler(.cancelAuthenticationChallenge, nil)
    }
}
