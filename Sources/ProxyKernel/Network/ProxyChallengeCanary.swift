// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// Asks a session's delegate what it would do with a proxy challenge, without
/// sending a request (decision 0045).
///
/// A test or pm-sim scenario that lets a loopback proxy answer 407 to a
/// Conduit session depends on that session's delegate cancelling the
/// challenge. If the guard regressed, CFNetwork would ask macOS for a proxy
/// credential and the machine running the check would get the proxy-password
/// dialog. So each one calls `requireRefusal` on the sessions it is about to
/// use, and sends nothing when the answer is not a cancel.
package enum ProxyChallengeCanary {
    package struct NotGuarded: Error, CustomStringConvertible {
        package let description: String
    }

    package static let schemes: [(name: String, method: String)] = [
        ("negotiate", NSURLAuthenticationMethodNegotiate),
        ("ntlm", NSURLAuthenticationMethodNTLM),
        ("basic", NSURLAuthenticationMethodHTTPBasic),
        ("digest", NSURLAuthenticationMethodHTTPDigest),
    ]

    /// The canary's own proxy, so its challenges never share a report limit
    /// with a real proxy on 127.0.0.1.
    package static let proxyHost = "canary.corp.example"
    package static let proxyPort = 3128

    /// The methods URLSession hands to a session-level challenge handler when
    /// the delegate has one, and to the task-level handler otherwise.
    ///
    /// This models only the session's own delegate. A delegate set on a task
    /// (`task.delegate`, `data(for:delegate:)`) can answer a challenge in the
    /// session delegate's place, and the canary cannot see it, because it
    /// probes sessions before any task exists. Conduit's DoH and PAC requests
    /// set none.
    private static let connectionLevelMethods: Set<String> = [
        NSURLAuthenticationMethodNTLM,
        NSURLAuthenticationMethodNegotiate,
        NSURLAuthenticationMethodClientCertificate,
        NSURLAuthenticationMethodServerTrust,
    ]

    package static func proxyChallenge(method: String) -> URLAuthenticationChallenge {
        challenge(in: URLProtectionSpace(
            proxyHost: proxyHost, port: proxyPort, type: "https", realm: nil, authenticationMethod: method
        ))
    }

    package static func serverChallenge(method: String) -> URLAuthenticationChallenge {
        challenge(in: URLProtectionSpace(
            host: "origin.corp.example", port: 443, protocol: "https", realm: nil, authenticationMethod: method
        ))
    }

    /// The handler URLSession would call for `challenge`, and its answer.
    ///
    /// The probe's task comes from a session of the canary's own, never
    /// resumed, so `session` and its delegate see no task of theirs end. Nil
    /// when no handler would get the challenge, which leaves it to CFNetwork,
    /// or when the handler does not answer before it returns.
    package static func disposition(
        of delegate: (any URLSessionDelegate)?,
        in session: URLSession,
        for challenge: URLAuthenticationChallenge
    ) -> URLSession.AuthChallengeDisposition? {
        guard let delegate else { return nil }
        let answer = NIOLockedValueBox<URLSession.AuthChallengeDisposition?>(nil)
        let record: @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void = { disposition, _ in
            answer.withLockedValue { $0 = disposition }
        }
        if connectionLevelMethods.contains(challenge.protectionSpace.authenticationMethod),
           delegate.responds(to: #selector(URLSessionDelegate.urlSession(_:didReceive:completionHandler:))) {
            delegate.urlSession?(session, didReceive: challenge, completionHandler: record)
        } else if let taskDelegate = delegate as? any URLSessionTaskDelegate,
                  taskDelegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))) {
            let carrier = URLSession(configuration: .ephemeral)
            defer { carrier.invalidateAndCancel() }
            let task = carrier.dataTask(with: URL(string: "https://192.0.2.10/")!)
            taskDelegate.urlSession?(session, task: task, didReceive: challenge, completionHandler: record)
        } else {
            return nil
        }
        return answer.withLockedValue { $0 }
    }

    /// Throws unless every session in `sessions`, and there is at least one,
    /// has a delegate that cancels a proxy challenge of every scheme.
    ///
    /// It drives the real delegate, so each call adds to its `refusalCount`
    /// and emits a real `auth.proxy_challenge_refused` for `proxyHost`. Call
    /// it only while no lookup on those sessions is in flight, or the
    /// forwarder blames that lookup's failure on the canary's refusals.
    package static func requireRefusal(_ sessions: [URLSession]) throws {
        guard !sessions.isEmpty else {
            throw NotGuarded(description: "there was no session to check; no request was sent")
        }
        for session in sessions {
            for scheme in schemes {
                let answer = disposition(of: session.delegate, in: session, for: proxyChallenge(method: scheme.method))
                guard answer == .cancelAuthenticationChallenge else {
                    throw NotGuarded(description:
                        "the session would not cancel a \(scheme.name) proxy challenge (disposition \(answer.map { String($0.rawValue) } ?? "none")); no request was sent")
                }
            }
        }
    }

    package static func requireRefusal(_ session: URLSession) throws {
        try requireRefusal([session])
    }

    private static func challenge(in space: URLProtectionSpace) -> URLAuthenticationChallenge {
        URLAuthenticationChallenge(
            protectionSpace: space, proposedCredential: nil, previousFailureCount: 0,
            failureResponse: nil, error: nil, sender: Sender()
        )
    }

    private final class Sender: NSObject, URLAuthenticationChallengeSender {
        func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}
        func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}
        func cancel(_ challenge: URLAuthenticationChallenge) {}
    }
}
