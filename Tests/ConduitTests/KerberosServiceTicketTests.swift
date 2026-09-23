// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Issue #73: SPNEGO answers `GSS_S_BAD_MECH, minor 0` both when there is no
/// TGT and when a TGT is present but the service ticket cannot be obtained
/// (KDC unreachable, SPN not registered). Only the first is a missing
/// credential; the second is a network-class failure and must not skip
/// recovery, bypass the GSS gate's cooldown, or tell the user to run kinit.
final class KerberosServiceTicketTests: XCTestCase {
    private let badMech: OM_uint32 = 0x0001_0000
    private let noCred: OM_uint32 = 0x0007_0000
    private let failure: OM_uint32 = 0x000D_0000

    private final class ProbeCounter: @unchecked Sendable {
        private let lock = NIOLock()
        private var count = 0
        private let answer: Bool
        init(answer: Bool) { self.answer = answer }
        var calls: Int { lock.withLock { count } }
        func probe() -> Bool { lock.withLock { count += 1 }; return answer }
    }

    private func ntlm() -> NTLMAuthenticator {
        NTLMAuthenticator(credentials: ProxyCredentials(
            username: "user", domain: "DOMAIN", workstation: "WS",
            ntHash: SecretBytes.repeating(0xAA, count: 16)
        ))
    }

    // MARK: - Classification

    func testBadMechWithACredentialPresentIsAServiceTicketFailure() {
        let probe = ProbeCounter(answer: true)
        let error = KerberosAuthError.initiatorFailure(
            major: badMech, minor: 0, host: "proxy.corp.example", hasInitiatorCredential: probe.probe
        )
        guard case .serviceTicketUnavailable(let host, let major, let minor) = error else {
            return XCTFail("expected .serviceTicketUnavailable, got \(error)")
        }
        XCTAssertEqual(host, "proxy.corp.example")
        XCTAssertEqual(major, badMech)
        XCTAssertEqual(minor, 0)
        XCTAssertEqual(probe.calls, 1)

        XCTAssertFalse(error.isCredentialUnavailable, "the credential is there; recovery must not be skipped")
        XCTAssertFalse(error.isCredentialRetryable, "waiting does not make the KDC issue a ticket")
        XCTAssertTrue(error.permitsNTLMFallback)
        XCTAssertEqual(error.fallbackReasonCode, "service_ticket_unavailable")

        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("HTTP/proxy.corp.example"), description)
        XCTAssertTrue(description.contains("service ticket"), description)
        XCTAssertFalse(description.contains("kinit"), "a TGT is present; kinit is the wrong advice: \(description)")
        XCTAssertFalse(description.contains("credentialBundleIDACL"), description)
    }

    func testGenericFailureWithZeroMinorAndACredentialIsAServiceTicketFailure() {
        let error = KerberosAuthError.initiatorFailure(
            major: failure, minor: 0, host: "proxy.corp.example", hasInitiatorCredential: { true }
        )
        guard case .serviceTicketUnavailable = error else {
            return XCTFail("expected .serviceTicketUnavailable, got \(error)")
        }
    }

    func testBadMechWithoutACredentialStaysCredentialUnavailable() {
        let error = KerberosAuthError.initiatorFailure(
            major: badMech, minor: 0, host: "proxy.corp.example", hasInitiatorCredential: { false }
        )
        guard case .initSecContextFailed(let major, 0) = error, major == badMech else {
            return XCTFail("expected .initSecContextFailed(BAD_MECH, 0), got \(error)")
        }
        XCTAssertTrue(error.isCredentialUnavailable)
        XCTAssertTrue(error.isCredentialRetryable)
    }

    /// Only the ambiguous codes consult the cache: an explicit NO_CRED and a
    /// specific sub-error already say what happened.
    func testUnambiguousCodesDoNotConsultTheCredentialCache() {
        for (major, minor) in [(noCred, OM_uint32(0)), (failure, OM_uint32(42)), (OM_uint32(0x0002_0000), OM_uint32(0))] {
            let probe = ProbeCounter(answer: true)
            let error = KerberosAuthError.initiatorFailure(
                major: major, minor: minor, host: "proxy.corp.example", hasInitiatorCredential: probe.probe
            )
            guard case .initSecContextFailed(major, minor) = error else {
                return XCTFail("major=\(major) minor=\(minor) must stay unrefined, got \(error)")
            }
            XCTAssertEqual(probe.calls, 0, "major=\(major) minor=\(minor)")
        }
    }

    // MARK: - NTLM fallback

    /// The kernel's first attempt passes `allowFallback: false` and retries
    /// only retryable failures, so a service-ticket failure that waited for
    /// the last attempt would never reach NTLM.
    func testServiceTicketFailureFallsBackToNTLMWithoutWaitingForTheLastAttempt() throws {
        let provider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.serviceTicketUnavailable(host: "proxy.corp.example", major: badMech, minor: 0)
        )
        let reasons = NIOLockedValueBox<[String]>([])
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: provider),
            ntlmFallback: ntlm(),
            onKerberosFallback: { _, reason in reasons.withLockedValue { $0.append(reason) } }
        )

        let result = try auth.initialToken(for: "proxy.corp.example", allowFallback: false)

        XCTAssertTrue(result.token.hasPrefix("NTLM "), result.token)
        XCTAssertTrue(result.usedFallback)
        XCTAssertEqual(reasons.withLockedValue { $0 }, ["service_ticket_unavailable"])
    }

    /// A missing credential still defers the fallback, so a ticket the SSO
    /// extension hands back a moment later is used rather than downgraded past.
    func testMissingCredentialStillDefersTheFallback() {
        let provider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(badMech, 0)
        )
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: provider),
            ntlmFallback: ntlm()
        )
        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.example", allowFallback: false)) { error in
            XCTAssertTrue(error.isCredentialUnavailable)
        }
    }

    func testServiceTicketFailureWithoutNTLMIsRaisedOnceWithoutRetryWaits() async {
        let provider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.serviceTicketUnavailable(host: "proxy.corp.example", major: badMech, minor: 0)
        )
        let auth = NegotiateAuthenticator(kerberos: KerberosAuthenticator(tokenProvider: provider))
        let sleeps = NIOLockedValueBox(0)
        let retry = AuthCredentialRetry(attempts: 2, delay: 0.75, outageHold: 30, sleep: { _ in sleeps.withLockedValue { $0 += 1 } })

        do {
            _ = try await retry.initialToken(from: auth, host: "proxy.corp.example")
            XCTFail("expected the service-ticket failure to surface")
        } catch {
            guard case KerberosAuthError.serviceTicketUnavailable = error else {
                return XCTFail("expected .serviceTicketUnavailable, got \(error)")
            }
            XCTAssertFalse(error.isCredentialUnavailable)
        }
        XCTAssertEqual(provider.calls.count, 1)
        XCTAssertEqual(sleeps.withLockedValue { $0 }, 0)
    }

    // MARK: - Failure event

    /// Codex review of #74: a service-ticket failure with no NTLM to fall
    /// back to reached the caller without any `RuntimeEvent`.
    func testServiceTicketFailureWithoutNTLMReportsTheFailure() {
        let provider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.serviceTicketUnavailable(host: "proxy.corp.example", major: badMech, minor: 0)
        )
        let failures = NIOLockedValueBox<[String]>([])
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: provider),
            onKerberosFailure: { host, reason in failures.withLockedValue { $0.append("\(host) \(reason)") } }
        )

        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.example", allowFallback: false))
        XCTAssertEqual(failures.withLockedValue { $0 }, ["proxy.corp.example service_ticket_unavailable"])
    }

    /// A missing credential withheld for the kernel's retry is not yet a
    /// failure; `auth.credential_retry` covers the wait. The last attempt,
    /// still without NTLM, is.
    func testDeferredCredentialFailureIsReportedOnlyOnTheLastAttempt() {
        let provider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.initSecContextFailed(badMech, 0)
        )
        let failures = NIOLockedValueBox<[String]>([])
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: provider),
            onKerberosFailure: { _, reason in failures.withLockedValue { $0.append(reason) } }
        )

        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.example", allowFallback: false))
        XCTAssertEqual(failures.withLockedValue { $0 }, [])
        XCTAssertThrowsError(try auth.initialToken(for: "proxy.corp.example", allowFallback: true))
        XCTAssertEqual(failures.withLockedValue { $0 }, ["bad_mech"])
    }

    func testFallbackToNTLMIsNotReportedAsAFailure() throws {
        let provider = RecordingGSSTokenProvider(
            errorToThrow: KerberosAuthError.serviceTicketUnavailable(host: "proxy.corp.example", major: badMech, minor: 0)
        )
        let failures = NIOLockedValueBox(0)
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: provider),
            ntlmFallback: ntlm(),
            onKerberosFailure: { _, _ in failures.withLockedValue { $0 += 1 } }
        )

        _ = try auth.initialToken(for: "proxy.corp.example", allowFallback: false)
        XCTAssertEqual(failures.withLockedValue { $0 }, 0)
    }

    /// Codex review of #75: GSS can also reject the proxy's continuation
    /// token after an initial leg that succeeded.
    func testContinuationLegFailureIsReported() throws {
        final class RejectsContinuation: GSSTokenProvider, @unchecked Sendable {
            let failure: KerberosAuthError
            init(failure: KerberosAuthError) { self.failure = failure }
            func generateToken(host: String, inputToken: Data?) throws -> Data? {
                if inputToken == nil { return Data([1, 2, 3]) }
                throw failure
            }
            func resetContext() {}
        }
        let failures = NIOLockedValueBox<[String]>([])
        let auth = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: RejectsContinuation(failure: .initSecContextFailed(failure, 5))),
            onKerberosFailure: { host, reason in failures.withLockedValue { $0.append("\(host) \(reason)") } }
        )

        _ = try auth.initialToken(for: "proxy.corp.example", allowFallback: false)
        XCTAssertThrowsError(try auth.processChallenge(headerValues: ["Negotiate AAAA"], host: "proxy.corp.example"))
        XCTAssertEqual(failures.withLockedValue { $0 }, ["proxy.corp.example failure"])
    }

    /// Every request through a failing proxy fails; the event marks the
    /// failure's start, a change in its reason, and then at most one repeat
    /// per interval. A success does not re-arm it: the initial leg can
    /// succeed on every request whose continuation leg then fails.
    func testFailureEventGateReportsOncePerHostAndReasonPerInterval() {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let gate = KerberosFailureEventGate(repeatInterval: 60, now: { clock.withLockedValue { $0 } })

        XCTAssertTrue(gate.shouldEmit(host: "de", reason: "service_ticket_unavailable"))
        XCTAssertFalse(gate.shouldEmit(host: "de", reason: "service_ticket_unavailable"))
        XCTAssertTrue(gate.shouldEmit(host: "special", reason: "service_ticket_unavailable"))
        XCTAssertTrue(gate.shouldEmit(host: "de", reason: "bad_mech"), "a new reason is a new failure")

        XCTAssertFalse(gate.shouldEmit(host: "de", reason: "service_ticket_unavailable"),
                       "alternating reasons each keep their own cooldown")

        clock.withLockedValue { $0.addTimeInterval(59) }
        XCTAssertFalse(gate.shouldEmit(host: "de", reason: "bad_mech"))
        clock.withLockedValue { $0.addTimeInterval(1) }
        XCTAssertTrue(gate.shouldEmit(host: "de", reason: "bad_mech"), "a failure that lasts is reported again")
    }

    func testFailureEventGateIsBounded() {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let gate = KerberosFailureEventGate(now: { clock.withLockedValue { $0 } })
        for index in 0...KerberosFailureEventGate.maximumEntries {
            clock.withLockedValue { $0.addTimeInterval(1) }
            XCTAssertTrue(gate.shouldEmit(host: "host-\(index)", reason: "failure"))
        }
        XCTAssertTrue(gate.shouldEmit(host: "host-0", reason: "failure"), "the oldest entry was evicted")
        XCTAssertFalse(gate.shouldEmit(host: "host-\(KerberosFailureEventGate.maximumEntries)", reason: "failure"))
    }

    // MARK: - Live GSS

    /// Real GSS against a name no KDC will ticket. With a credential reported
    /// present, the failure is a service-ticket failure and cools the gate
    /// down, so the second handshake does not re-enter GSS; with none, it is
    /// credential absence, which the gate lets through every time.
    func testLiveGSSServiceTicketFailureCoolsTheGateDown() throws {
        let host = "no-spn.conduit-test.invalid"

        let present = ProbeCounter(answer: true)
        let provider = SystemGSSTokenProvider(gate: GSSInitiatorGate(cooldown: 60), hasInitiatorCredential: present.probe)
        let first = Result { try provider.generateToken(host: host, inputToken: nil) }
        guard present.calls == 1 else {
            throw XCTSkip("GSS did not answer with an ambiguous code for an unticketable name here: \(first)")
        }
        guard case .failure(KerberosAuthError.serviceTicketUnavailable(host, _, _)) = first else {
            return XCTFail("expected .serviceTicketUnavailable, got \(first)")
        }
        XCTAssertThrowsError(try provider.generateToken(host: host, inputToken: nil))
        XCTAssertEqual(present.calls, 1, "the cooldown answered the second handshake without GSS")

        let absent = ProbeCounter(answer: false)
        let noTGT = SystemGSSTokenProvider(gate: GSSInitiatorGate(cooldown: 60), hasInitiatorCredential: absent.probe)
        for _ in 0..<2 {
            XCTAssertThrowsError(try noTGT.generateToken(host: host, inputToken: nil)) { error in
                XCTAssertTrue(error.isCredentialUnavailable, "\(error)")
            }
        }
        XCTAssertEqual(absent.calls, 2, "credential absence is exempt from the cooldown")
    }
}
