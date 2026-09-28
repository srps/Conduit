// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Issue #99: a proxy Kerberos cannot ticket falls back to NTLM on every
/// handshake. The fallback event and its NOTICE line are reported once per
/// host and reason per minute, with the count held back in between, and
/// carry the GSS codes so the failure can be diagnosed from the log.
@MainActor
final class KerberosFallbackEventTests: XCTestCase {
    private let badMech: OM_uint32 = 0x0001_0000
    private let host = "rb-proxy-de.corp.example:8080"
    private let codes = "major=65536 minor=-1765328377 krb5_error=KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN"

    private func makeOrchestrator(
        clock: NIOLockedValueBox<Date>,
        logger: RecordingLogSink
    ) -> ProxyOrchestrator {
        ProxyOrchestrator(
            config: .testFixture(),
            logger: logger,
            authFallbackEventGate: RuntimeEventRepeatGate(repeatInterval: 60, now: { clock.withLockedValue { $0 } })
        )
    }

    /// `reportAuthOutcome` logs from a main-actor hop; one enqueued after
    /// them runs once they have.
    private func drainMainActor() async {
        await Task { @MainActor in }.value
    }

    private func fallbackEvents(_ orchestrator: ProxyOrchestrator) -> [RuntimeEvent] {
        orchestrator.eventLog.events.filter { $0.event == "auth.kerberos_fallback_ntlm" }
    }

    private func fallbackLines(_ logger: RecordingLogSink) -> [String] {
        logger.entries().map(\.message).filter { $0.contains("falling back to NTLMv2") }
    }

    func testHundredFallbacksInAMinuteProduceOneLineThenOneWithTheSuppressedCount() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let logger = RecordingLogSink()
        let orchestrator = makeOrchestrator(clock: clock, logger: logger)

        for _ in 0..<100 {
            orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable", diagnostics: codes)
            clock.withLockedValue { $0.addTimeInterval(0.5) }
        }
        await drainMainActor()
        XCTAssertEqual(fallbackEvents(orchestrator).count, 1)
        XCTAssertEqual(fallbackLines(logger).count, 1)
        XCTAssertEqual(
            fallbackEvents(orchestrator).first?.detail,
            "host=\(host) reason=service_ticket_unavailable \(codes) suppressed=0"
        )

        clock.withLockedValue { $0.addTimeInterval(60) }
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable", diagnostics: codes)
        await drainMainActor()

        let events = fallbackEvents(orchestrator)
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events.last?.detail, "host=\(host) reason=service_ticket_unavailable \(codes) suppressed=99")
        let lines = fallbackLines(logger)
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(
            lines.last,
            "Kerberos unavailable for \(host) (service_ticket_unavailable, \(codes)); falling back to NTLMv2. 99 fallbacks for this host and reason were not logged since the last line."
        )
    }

    func testEachHostAndReasonHasItsOwnCooldown() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let logger = RecordingLogSink()
        let orchestrator = makeOrchestrator(clock: clock, logger: logger)

        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: "rb-proxy-tr.corp.example:8080", reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "bad_mech")
        await drainMainActor()

        XCTAssertEqual(fallbackEvents(orchestrator).map(\.detail), [
            "host=\(host) reason=service_ticket_unavailable suppressed=0",
            "host=rb-proxy-tr.corp.example:8080 reason=service_ticket_unavailable suppressed=0",
            "host=\(host) reason=bad_mech suppressed=0",
        ])
        XCTAssertEqual(fallbackLines(logger).count, 3)
    }

    /// The gate limits the event and the log line, not the snapshot: the UI
    /// chip still shows the last handshake's outcome.
    func testASuppressedFallbackStillUpdatesTheSnapshot() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let orchestrator = makeOrchestrator(clock: clock, logger: RecordingLogSink())

        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.kerberos, host: "rb-proxy-tr.corp.example:8080")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        await drainMainActor()

        XCTAssertEqual(fallbackEvents(orchestrator).count, 1)
        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .ntlmFallback)
        XCTAssertEqual(orchestrator.snapshot.lastAuthFallbackReason, "service_ticket_unavailable")
    }

    // MARK: - GSS codes

    func testServiceTicketFailureCarriesTheGSSCodesAndTheKerberosErrorName() {
        let error = KerberosAuthError.serviceTicketUnavailable(
            host: "rb-proxy-de.corp.example", major: badMech, minor: OM_uint32(bitPattern: -1_765_328_377)
        )
        XCTAssertEqual(error.diagnosticDetail, codes)
    }

    func testMinorZeroCarriesTheCodesWithoutAName() {
        let error = KerberosAuthError.serviceTicketUnavailable(host: "rb-proxy-de.corp.example", major: badMech, minor: 0)
        XCTAssertEqual(error.diagnosticDetail, "major=65536 minor=0")
        XCTAssertEqual(
            KerberosAuthError.initSecContextFailed(0x000D_0000, 12345).diagnosticDetail,
            "major=851968 minor=12345",
            "a minor outside the krb5 table carries no name"
        )
    }

    func testNegotiateAuthenticatorHandsTheCodesToItsHandlers() throws {
        let minor = OM_uint32(bitPattern: -1_765_328_228)
        let fallbacks = NIOLockedValueBox<[String?]>([])
        let failures = NIOLockedValueBox<[String?]>([])
        let error = KerberosAuthError.serviceTicketUnavailable(host: "rb-proxy-de.corp.example", major: badMech, minor: minor)

        let withNTLM = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: RecordingGSSTokenProvider(errorToThrow: error)),
            ntlmFallback: NTLMAuthenticator(credentials: ProxyCredentials(
                username: "user", domain: "DOMAIN", workstation: "WS",
                ntHash: SecretBytes.repeating(0xAA, count: 16)
            )),
            onKerberosFallback: { _, _, diagnostics in fallbacks.withLockedValue { $0.append(diagnostics) } }
        )
        _ = try withNTLM.initialToken(for: "rb-proxy-de.corp.example", allowFallback: true)

        let withoutNTLM = NegotiateAuthenticator(
            kerberos: KerberosAuthenticator(tokenProvider: RecordingGSSTokenProvider(errorToThrow: error)),
            onKerberosFailure: { _, _, diagnostics in failures.withLockedValue { $0.append(diagnostics) } }
        )
        XCTAssertThrowsError(try withoutNTLM.initialToken(for: "rb-proxy-de.corp.example", allowFallback: true))

        let expected = "major=65536 minor=-1765328228 krb5_error=KRB5_KDC_UNREACH"
        XCTAssertEqual(fallbacks.withLockedValue { $0 }, [expected])
        XCTAssertEqual(failures.withLockedValue { $0 }, [expected])
    }

    func testErrorsWithoutGSSCodesCarryNoDetail() {
        XCTAssertNil(KerberosAuthError.noTicket.diagnosticDetail)
        XCTAssertNil(KerberosAuthError.emptyToken.diagnosticDetail)
    }

    /// Values from `krb5.h` in the macOS SDK; Heimdal's `krb5_err` table uses
    /// the same codes.
    func testKerberosErrorNamesMatchTheSDKHeader() {
        let expected: [Int32: String] = [
            -1_765_328_378: "KRB5KDC_ERR_C_PRINCIPAL_UNKNOWN",
            -1_765_328_377: "KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN",
            -1_765_328_352: "KRB5KRB_AP_ERR_TKT_EXPIRED",
            -1_765_328_347: "KRB5KRB_AP_ERR_SKEW",
            -1_765_328_243: "KRB5_CC_NOTFOUND",
            -1_765_328_228: "KRB5_KDC_UNREACH",
        ]
        for (code, name) in expected {
            XCTAssertEqual(KerberosAuthError.kerberosErrorName(minor: OM_uint32(bitPattern: code)), name)
        }
        XCTAssertNil(KerberosAuthError.kerberosErrorName(minor: 0))
    }
}
