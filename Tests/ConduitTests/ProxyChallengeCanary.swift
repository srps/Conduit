// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest

/// Asks a session's delegate what it would do with a proxy challenge, without
/// sending a request.
///
/// A test that lets a real proxy answer 407 to a Conduit session depends on
/// the session's delegate cancelling the challenge. If that guard regressed,
/// CFNetwork would ask macOS for a proxy credential and the machine running
/// the tests would get the proxy-password dialog. So every such test calls
/// `requireRefusal` on the session it is about to use, and sends nothing when
/// the answer is not a cancel.
enum ProxyChallengeCanary {
    struct NotGuarded: Error, CustomStringConvertible {
        let description: String
    }

    static let schemes: [(name: String, method: String)] = [
        ("negotiate", NSURLAuthenticationMethodNegotiate),
        ("ntlm", NSURLAuthenticationMethodNTLM),
        ("basic", NSURLAuthenticationMethodHTTPBasic),
        ("digest", NSURLAuthenticationMethodHTTPDigest),
    ]

    /// The canary's own proxy, so its challenges never share a report limit
    /// with a test's real proxy on 127.0.0.1.
    static let proxyHost = "canary.corp.example"
    static let proxyPort = 3128

    static func proxyChallenge(method: String) -> URLAuthenticationChallenge {
        challenge(in: URLProtectionSpace(
            proxyHost: proxyHost, port: proxyPort, type: "https", realm: nil, authenticationMethod: method
        ))
    }

    static func serverChallenge(method: String) -> URLAuthenticationChallenge {
        challenge(in: URLProtectionSpace(
            host: "origin.corp.example", port: 443, protocol: "https", realm: nil, authenticationMethod: method
        ))
    }

    /// Nil when the delegate has no task-level challenge handler, which leaves
    /// the challenge to CFNetwork.
    static func disposition(
        of delegate: (any URLSessionDelegate)?,
        in session: URLSession,
        for challenge: URLAuthenticationChallenge
    ) async -> URLSession.AuthChallengeDisposition? {
        guard let delegate = delegate as? any URLSessionTaskDelegate,
              delegate.responds(to: #selector(URLSessionTaskDelegate.urlSession(_:task:didReceive:completionHandler:))) else {
            return nil
        }
        let task = session.dataTask(with: URL(string: "https://192.0.2.10/")!)
        defer { task.cancel() }
        return await withCheckedContinuation { continuation in
            delegate.urlSession?(session, task: task, didReceive: challenge) { disposition, _ in
                continuation.resume(returning: disposition)
            }
        }
    }

    /// Throws unless `session`'s delegate cancels a proxy challenge of every scheme.
    static func requireRefusal(_ session: URLSession, delegate: (any URLSessionDelegate)? = nil) async throws {
        for scheme in schemes {
            let answer = await disposition(
                of: delegate ?? session.delegate, in: session, for: proxyChallenge(method: scheme.method)
            )
            guard answer == .cancelAuthenticationChallenge else {
                throw NotGuarded(description:
                    "the session would not cancel a \(scheme.name) proxy challenge (disposition \(String(describing: answer?.rawValue))); no request was sent")
            }
        }
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
