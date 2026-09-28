// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Issue #99: SPNEGO reports a service-ticket failure as `BAD_MECH, minor 0`,
/// which says nothing about why. `KerberosMechDiagnoser` asks the Kerberos
/// mech directly, at most once per host a minute, and never changes the
/// handshake's outcome.
final class KerberosMechDiagnoserTests: XCTestCase {
    private let badMech: OM_uint32 = 0x0001_0000
    private let failure: OM_uint32 = 0x000D_0000
    private let principalUnknown = OM_uint32(bitPattern: -1_765_328_377)
    private let de = "rb-proxy-de.corp.example"

    private final class ProbeRecorder: @unchecked Sendable {
        private let lock = NIOLock()
        private var hosts: [String] = []
        let answer: KerberosMechStatus
        init(answer: KerberosMechStatus) { self.answer = answer }
        var calls: [String] { lock.withLock { hosts } }
        func probe(_ host: String) -> KerberosMechStatus {
            lock.withLock { hosts.append(host) }
            return answer
        }
    }

    private func serviceTicketFailure(_ host: String) -> KerberosAuthError {
        .serviceTicketUnavailable(host: host, major: badMech, minor: 0)
    }

    private func mech(of error: KerberosAuthError) -> KerberosMechStatus? {
        if case .serviceTicketUnavailable(_, _, _, let mech) = error { return mech }
        return nil
    }

    // MARK: - Rate limit

    func testProbesEachFailingHostAtMostOnceAMinute() {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let recorder = ProbeRecorder(answer: .status(major: failure, minor: principalUnknown))
        let diagnoser = KerberosMechDiagnoser(interval: 60, now: { clock.withLockedValue { $0 } }, probe: recorder.probe)

        XCTAssertNotNil(mech(of: diagnoser.annotate(serviceTicketFailure(de))))
        clock.withLockedValue { $0.addTimeInterval(30) }
        XCTAssertNil(mech(of: diagnoser.annotate(serviceTicketFailure(de))), "within the interval: no TGS request")
        XCTAssertNotNil(mech(of: diagnoser.annotate(serviceTicketFailure("rb-proxy-tr.corp.example"))),
                        "each host has its own interval")
        clock.withLockedValue { $0.addTimeInterval(29) }
        XCTAssertNil(mech(of: diagnoser.annotate(serviceTicketFailure(de))))
        clock.withLockedValue { $0.addTimeInterval(1) }
        XCTAssertNotNil(mech(of: diagnoser.annotate(serviceTicketFailure(de))), "a failure that lasts is probed again")

        XCTAssertEqual(recorder.calls, [de, "rb-proxy-tr.corp.example", de])
    }

    func testOnlyServiceTicketFailuresAreProbed() {
        let recorder = ProbeRecorder(answer: .status(major: failure, minor: principalUnknown))
        let diagnoser = KerberosMechDiagnoser(probe: recorder.probe)

        _ = diagnoser.annotate(.initSecContextFailed(badMech, 0))
        _ = diagnoser.annotate(.noTicket)
        _ = diagnoser.annotate(.importNameFailed(failure, 1))
        _ = diagnoser.annotate(.emptyToken)

        XCTAssertEqual(recorder.calls, [], "credential absence and local failures send no TGS request")
    }

    // MARK: - Detail

    func testTheMechStatusNamesTheRealKerberosError() {
        let answer = KerberosMechStatus.status(major: failure, minor: principalUnknown)
        let diagnoser = KerberosMechDiagnoser(probe: { _ in answer })
        XCTAssertEqual(
            diagnoser.annotate(serviceTicketFailure(de)).diagnosticDetail,
            "major=65536 minor=0 krb5_major=851968 krb5_minor=-1765328377 krb5_error=KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN"
        )
    }

    func testAProbeThatCouldNotRunSaysSo() {
        let diagnoser = KerberosMechDiagnoser(probe: { _ in .probeFailed })
        XCTAssertEqual(diagnoser.annotate(serviceTicketFailure(de)).diagnosticDetail, "major=65536 minor=0 krb5_probe=failed")
    }

    // MARK: - Outcome is unchanged

    /// Whatever the probe answers — a Kerberos error, success, or nothing —
    /// the failure keeps its case, codes and every classification the
    /// fallback, the retry policy and the gate cooldown read.
    func testTheProbeNeverChangesTheClassification() {
        let answers: [KerberosMechStatus] = [
            .status(major: failure, minor: principalUnknown),
            .status(major: 0, minor: 0),
            .status(major: failure, minor: 0),
            .probeFailed,
        ]
        let original = serviceTicketFailure(de)
        for answer in answers {
            let annotated = KerberosMechDiagnoser(probe: { _ in answer }).annotate(original)
            guard case .serviceTicketUnavailable(let host, let major, let minor, let mech) = annotated else {
                return XCTFail("expected .serviceTicketUnavailable, got \(annotated)")
            }
            XCTAssertEqual([host, "\(major)", "\(minor)"], [de, "\(badMech)", "0"], "\(answer)")
            XCTAssertEqual(mech, answer)
            XCTAssertEqual(annotated.fallbackReasonCode, original.fallbackReasonCode, "\(answer)")
            XCTAssertEqual(annotated.permitsNTLMFallback, original.permitsNTLMFallback, "\(answer)")
            XCTAssertEqual(annotated.isCredentialUnavailable, original.isCredentialUnavailable, "\(answer)")
            XCTAssertEqual(annotated.isCredentialRetryable, original.isCredentialRetryable, "\(answer)")
            XCTAssertEqual(SystemGSSTokenProvider.startsGateCooldown(annotated),
                           SystemGSSTokenProvider.startsGateCooldown(original), "\(answer)")
        }
    }

    /// A token provider shaped like `SystemGSSTokenProvider`: the failure is
    /// annotated inside the gate, then thrown.
    private final class DiagnosedProvider: GSSTokenProvider, @unchecked Sendable {
        let gate = GSSInitiatorGate(cooldown: 0)
        let diagnoser: KerberosMechDiagnoser
        let failure: KerberosAuthError
        init(diagnoser: KerberosMechDiagnoser, failure: KerberosAuthError) {
            self.diagnoser = diagnoser
            self.failure = failure
        }

        func generateToken(host: String, inputToken: Data?) throws -> Data? {
            try gate.run(target: host, shouldCoolDown: SystemGSSTokenProvider.startsGateCooldown) {
                throw diagnoser.annotate(failure)
            }
        }

        func resetContext() {}
    }

    func testTheHandshakeFallsBackToNTLMWhateverTheProbeAnswers() throws {
        let answers: [KerberosMechStatus] = [.status(major: failure, minor: principalUnknown), .status(major: 0, minor: 0), .probeFailed]
        for answer in answers {
            let reasons = NIOLockedValueBox<[String]>([])
            let provider = DiagnosedProvider(
                diagnoser: KerberosMechDiagnoser(probe: { _ in answer }), failure: serviceTicketFailure(de)
            )
            let auth = NegotiateAuthenticator(
                kerberos: KerberosAuthenticator(tokenProvider: provider),
                ntlmFallback: NTLMAuthenticator(credentials: ProxyCredentials(
                    username: "user", domain: "DOMAIN", workstation: "WS",
                    ntHash: SecretBytes.repeating(0xAA, count: 16)
                )),
                onKerberosFallback: { _, reason, _ in reasons.withLockedValue { $0.append(reason) } }
            )
            let result = try auth.initialToken(for: de, allowFallback: false)
            XCTAssertTrue(result.token.hasPrefix("NTLM "), "\(answer): \(result.token)")
            XCTAssertEqual(reasons.withLockedValue { $0 }, ["service_ticket_unavailable"], "\(answer)")

            let withoutNTLM = NegotiateAuthenticator(kerberos: KerberosAuthenticator(tokenProvider: provider))
            XCTAssertThrowsError(try withoutNTLM.initialToken(for: de, allowFallback: true)) { error in
                guard case KerberosAuthError.serviceTicketUnavailable = error else {
                    return XCTFail("\(answer): expected .serviceTicketUnavailable, got \(error)")
                }
            }
        }
    }

    // MARK: - Live GSS

    /// The real probe against a name no KDC will ticket answers with a
    /// status and releases what it made; it must not crash or hang.
    func testLiveProbeAnswersWithAStatus() {
        let status = SystemGSSTokenProvider.probeKerberosMech(host: "no-spn.conduit-test.invalid")
        guard case .status(let major, _) = status else {
            return XCTFail("expected a status, got \(status)")
        }
        XCTAssertNotEqual(major, 0, "no ticket can be had for an .invalid name")
    }

    /// `SystemGSSTokenProvider` attaches the mech status to a service-ticket
    /// failure it classifies.
    func testLiveServiceTicketFailureIsAnnotated() throws {
        let recorder = ProbeRecorder(answer: .status(major: failure, minor: principalUnknown))
        let provider = SystemGSSTokenProvider(
            gate: GSSInitiatorGate(cooldown: 60),
            hasInitiatorCredential: { true },
            mechDiagnoser: KerberosMechDiagnoser(probe: recorder.probe)
        )
        let result = Result { try provider.generateToken(host: "no-spn.conduit-test.invalid", inputToken: nil) }
        guard case .failure(KerberosAuthError.serviceTicketUnavailable(_, _, _, let mech)) = result else {
            throw XCTSkip("GSS did not answer with an ambiguous code for an unticketable name here: \(result)")
        }
        XCTAssertEqual(mech, .status(major: failure, minor: principalUnknown))
        XCTAssertEqual(recorder.calls, ["no-spn.conduit-test.invalid"])
    }
}
