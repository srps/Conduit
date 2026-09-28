// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Issue #99: one upstream kept falling back to NTLM for minutes after a new
/// TGT, while other upstreams in the same realm got service tickets. This
/// pins down how long Conduit's own per-process state can hold a failing
/// upstream on NTLM once the credential cache can ticket it again: one GSS
/// gate cooldown, nothing more. The pool builds a new authenticator, and so
/// a new `GSSTokenProvider`, for every handshake; the credential outage in
/// `AuthCredentialRetry` still tries Kerberos first; the gate's cooldown is
/// per target and expires. Whatever held the failure for minutes on the
/// real machine is outside this state.
final class KerberosTGTReplacementTests: XCTestCase {
    private let badMech: OM_uint32 = 0x0001_0000

    /// Stands in for the process-wide credential cache: whether a service
    /// ticket can be had for each host.
    private final class CredentialCache: @unchecked Sendable {
        private let lock = NIOLock()
        private var ticketable: Set<String> = []
        private var initiatorCalls: [String: Int] = [:]

        func setTicketable(_ host: String) { lock.withLock { _ = ticketable.insert(host) } }
        func isTicketable(_ host: String) -> Bool { lock.withLock { ticketable.contains(host) } }
        func recordCall(_ host: String) { lock.withLock { initiatorCalls[host, default: 0] += 1 } }
        func calls(_ host: String) -> Int { lock.withLock { initiatorCalls[host, default: 0] } }
    }

    /// `SystemGSSTokenProvider` with the `gss_init_sec_context` call
    /// replaced: the same gate, the same cooldown rule, and the production
    /// classification of SPNEGO's `BAD_MECH, minor 0` with a TGT present.
    private final class CacheBackedProvider: GSSTokenProvider, @unchecked Sendable {
        let cache: CredentialCache
        let gate: GSSInitiatorGate
        let badMech: OM_uint32

        init(cache: CredentialCache, gate: GSSInitiatorGate, badMech: OM_uint32) {
            self.cache = cache
            self.gate = gate
            self.badMech = badMech
        }

        func generateToken(host: String, inputToken: Data?) throws -> Data? {
            try gate.run(target: host, shouldCoolDown: SystemGSSTokenProvider.startsGateCooldown) {
                cache.recordCall(host)
                guard cache.isTicketable(host) else {
                    throw KerberosAuthError.initiatorFailure(
                        major: badMech, minor: 0, host: host, hasInitiatorCredential: { true }
                    )
                }
                return Data([0x60, 0x01, 0x00])
            }
        }

        func resetContext() {}
    }

    private func ntlm() -> NTLMAuthenticator {
        NTLMAuthenticator(credentials: ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        ))
    }

    func testANewTicketIsUsedByTheFirstHandshakeAfterTheGateCooldown() async throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let now: @Sendable () -> Date = { clock.withLockedValue { $0 } }
        let cooldown: TimeInterval = 5
        let gate = GSSInitiatorGate(cooldown: cooldown, now: now)
        let retry = AuthCredentialRetry(sleep: { _ in }, now: now)
        let cache = CredentialCache()
        cache.setTicketable("rb-proxy-tr.corp.example")

        /// One pooled-connection handshake: a fresh authenticator from the
        /// factory's shape, then the kernel's retry policy.
        func handshake(_ host: String) async throws -> String {
            let auth = NegotiateAuthenticator(
                kerberos: KerberosAuthenticator(tokenProvider: CacheBackedProvider(cache: cache, gate: gate, badMech: badMech)),
                ntlmFallback: ntlm()
            )
            return try await retry.initialToken(from: auth, host: host, outageKey: "\(host):8080")
        }

        let de = "rb-proxy-de.corp.example"
        let first = try await handshake(de)
        XCTAssertTrue(first.hasPrefix("NTLM "), first)
        XCTAssertTrue(retry.isInOutage(host: "\(de):8080"))
        let peer = try await handshake("rb-proxy-tr.corp.example")
        XCTAssertTrue(peer.hasPrefix("Negotiate "), "another upstream is not held by this one's failure")

        // The credential cache gains what `de` needed.
        cache.setTicketable(de)
        clock.withLockedValue { $0.addTimeInterval(1) }
        let duringCooldown = try await handshake(de)
        XCTAssertTrue(duringCooldown.hasPrefix("NTLM "), "inside the cooldown the gate answers without GSS")
        XCTAssertEqual(cache.calls(de), 1)

        clock.withLockedValue { $0.addTimeInterval(cooldown) }
        let afterCooldown = try await handshake(de)
        XCTAssertTrue(afterCooldown.hasPrefix("Negotiate "), afterCooldown)
        XCTAssertEqual(cache.calls(de), 2, "the first handshake after the cooldown asked GSS again")
        XCTAssertFalse(retry.isInOutage(host: "\(de):8080"), "a Kerberos success clears the outage")
    }
}
