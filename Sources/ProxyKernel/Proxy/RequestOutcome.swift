// SPDX-License-Identifier: Apache-2.0
import Foundation

/// How a proxied request ended, as `onRequestCompleted` reports it.
///
/// Every failure still counts in the request metrics; only one that
/// implicates an upstream feeds the orchestrator's error-rate alarm. A
/// direct route whose origin does not resolve, refuses or times out says
/// nothing about the upstream pool, and re-probing the pool for it only
/// adds load (#100: 1,667 NXDOMAIN failures for one PAC-DIRECT host raised
/// the alarm and a re-probe).
package enum RequestOutcome: Sendable, Equatable {
    case succeeded
    case failed(RequestFailureClass)

    package var succeeded: Bool { self == .succeeded }

    /// `true` only for a failure the upstream pool is responsible for.
    package var implicatesUpstream: Bool { self == .failed(.upstream) }
}

/// Whose failure a failed request was, decided where the request completes.
package enum RequestFailureClass: String, Sendable {
    /// The upstream proxy: connect, handshake, auth or timeout to it, a
    /// refused CONNECT, or an exchange through it that broke.
    case upstream
    /// The origin on a direct route: DNS, refused, unreachable, timed out, or
    /// the relay to it failed.
    case origin
    /// The client hung up before the request could complete.
    case client
    /// Conduit refused the request itself: policy, the metadata blocklist,
    /// the body spool, pool exhaustion or the auth-handshake limit.
    case local
}
