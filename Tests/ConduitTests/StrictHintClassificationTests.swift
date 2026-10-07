// SPDX-License-Identifier: Apache-2.0
import NIOCore
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Which strict-mode upstream failures may suggest a No-proxy entry: only
/// those that say the upstream could not get to the target.
final class StrictHintClassificationTests: XCTestCase {
    func testFailuresThatSayTheUpstreamCouldNotReachTheTargetEarnAHint() {
        let hinted: [Error] = [
            ConnectionPoolError.upstreamReturnedStatus(502, target: "intranet.example:443"),
            ConnectionPoolError.upstreamReturnedStatus(503, target: "intranet.example:443"),
            ConnectionPoolError.upstreamReturnedStatus(504, target: "intranet.example:443"),
            ConnectionPoolError.upstreamResponseTimedOut,
            ConnectionPoolError.invalidResponse,
            ConnectionPoolError.streamingResponseInterrupted,
            ChannelError.connectTimeout(.seconds(5)),
            ChannelError.eof,
        ]
        for error in hinted {
            XCTAssertTrue(HTTPProxyHandler.strictHintApplies(to: error), "\(error)")
        }
    }

    func testRefusalsAuthFailuresAndLocalFailuresEarnNoHint() {
        let quiet: [ConnectionPoolError] = [
            .upstreamReturnedStatus(403, target: "blocked.example:443"),
            .upstreamReturnedStatus(400, target: "blocked.example:443"),
            .upstreamReturnedStatus(404, target: "blocked.example:443"),
            .authenticationRejected,
            .authenticationUnavailable,
            .noUpstreamsConfigured,
            .poolExhausted,
            .authHandshakeLimitExceeded,
            .bodyTooLargeForReplay,
            .clientClosedDuringResponse,
        ]
        for error in quiet {
            XCTAssertFalse(HTTPProxyHandler.strictHintApplies(to: error), "\(error)")
        }
    }

    /// The authenticator's own errors reach the hint unwrapped: no saved
    /// NTLM credential, no Kerberos ticket, a malformed NTLM challenge.
    func testAuthenticatorFailuresEarnNoHint() {
        let quiet: [Error] = [
            CredentialManagerError.missingCredentials,
            NTLMAuthError.invalidChallenge,
            NTLMAuthError.cryptoFailure,
        ]
        for error in quiet {
            XCTAssertFalse(HTTPProxyHandler.strictHintApplies(to: error), "\(error)")
        }
    }
}
