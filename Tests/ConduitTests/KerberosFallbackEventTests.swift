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
final class KerberosFallbackEventTests: XCTestCase {
    private let badMech: OM_uint32 = 0x0001_0000
    private let host = "rb-proxy-de.corp.example:8080"
    private let codes = "major=65536 minor=-1765328377 krb5_error=KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN"
    /// The orchestrator's snapshot emissions: one when the callback is wired, then one per `reportAuthOutcome` hop.
    private let emissions = NIOLockedValueBox(0)

    /// `withTunnel` adds one unproxied tunnel on an ephemeral loopback port, so the tunnels can run beside a stopped proxy.
    @RuntimeActor
    private func makeOrchestrator(
        clock: NIOLockedValueBox<Date>,
        logger: RecordingLogSink,
        withTunnel: Bool = false
    ) -> ProxyOrchestrator {
        var config = ProxyConfig.testFixture()
        if withTunnel {
            config.tunnels.definitions = [
                TunnelDefinition(localPort: 0, remoteHost: "db.example.test", remotePort: 5432, proxied: false, label: "T")
            ]
        }
        let orchestrator = ProxyOrchestrator(
            config: config,
            logger: logger,
            authFallbackEventGate: RuntimeEventRepeatGate(repeatInterval: 60, now: { clock.withLockedValue { $0 } })
        )
        orchestrator.onSnapshotChange = { [emissions] _ in emissions.withLockedValue { $0 += 1 } }
        return orchestrator
    }

    /// `reportAuthOutcome` logs and updates the snapshot from an owner hop, one per report, and each hop emits once. Waits, bounded,
    /// until `reports` hops in all have run, rather than assuming the order the owner runs its jobs in.
    @RuntimeActor
    private func awaitHops(_ reports: Int) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while emissions.withLockedValue({ $0 }) < 1 + reports, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(emissions.withLockedValue { $0 }, 1 + reports, "every report's owner hop ran")
    }

    @RuntimeActor
    private func fallbackEvents(_ orchestrator: ProxyOrchestrator) -> [RuntimeEvent] {
        orchestrator.eventLog.events.filter { $0.event == "auth.kerberos_fallback_ntlm" }
    }

    private func fallbackLines(_ logger: RecordingLogSink) -> [String] {
        logger.entries().map(\.message).filter { $0.contains("falling back to NTLMv2") }
    }

    @RuntimeActor
    func testHundredFallbacksInAMinuteProduceOneLineThenOneWithTheSuppressedCount() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let logger = RecordingLogSink()
        let orchestrator = makeOrchestrator(clock: clock, logger: logger)

        for _ in 0..<100 {
            orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable", diagnostics: codes)
            clock.withLockedValue { $0.addTimeInterval(0.5) }
        }
        await awaitHops(100)
        XCTAssertEqual(fallbackEvents(orchestrator).count, 1)
        XCTAssertEqual(fallbackLines(logger).count, 1)
        XCTAssertEqual(
            fallbackEvents(orchestrator).first?.detail,
            "host=\(host) reason=service_ticket_unavailable \(codes) suppressed=0"
        )

        clock.withLockedValue { $0.addTimeInterval(60) }
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable", diagnostics: codes)
        await awaitHops(101)

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

    @RuntimeActor
    func testEachHostAndReasonHasItsOwnCooldown() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let logger = RecordingLogSink()
        let orchestrator = makeOrchestrator(clock: clock, logger: logger)

        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: "rb-proxy-tr.corp.example:8080", reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "bad_mech")
        await awaitHops(4)

        XCTAssertEqual(fallbackEvents(orchestrator).map(\.detail), [
            "host=\(host) reason=service_ticket_unavailable suppressed=0",
            "host=rb-proxy-tr.corp.example:8080 reason=service_ticket_unavailable suppressed=0",
            "host=\(host) reason=bad_mech suppressed=0",
        ])
        XCTAssertEqual(fallbackLines(logger).count, 3)
    }

    /// The gate limits the event and the log line, not the snapshot: the UI
    /// chip still shows the last handshake's outcome.
    @RuntimeActor
    func testASuppressedFallbackStillUpdatesTheSnapshot() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let orchestrator = makeOrchestrator(clock: clock, logger: RecordingLogSink())

        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        orchestrator.reportAuthOutcome(.kerberos, host: "rb-proxy-tr.corp.example:8080")
        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        await awaitHops(3)

        XCTAssertEqual(fallbackEvents(orchestrator).count, 1)
        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .ntlmFallback)
        XCTAssertEqual(orchestrator.snapshot.lastAuthFallbackReason, "service_ticket_unavailable")
    }

    /// A report whose owner hop lands after a stop keeps its event and its line but does not put the outcome the stop cleared back
    /// on the snapshot. The hop's own line says it ran, so the cleared outcome is read after it, not assumed.
    @RuntimeActor
    func testAnOutcomeHopLandingAfterAStopLeavesTheClearedOutcome() async {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let logger = RecordingLogSink()
        let orchestrator = makeOrchestrator(clock: clock, logger: logger)
        await orchestrator.stopProxy()
        XCTAssertNil(orchestrator.snapshot.lastAuthOutcome)

        orchestrator.reportAuthOutcome(.ntlmFallback, host: host, reason: "service_ticket_unavailable")
        let deadline = ContinuousClock.now + .seconds(5)
        while fallbackLines(logger).isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(fallbackLines(logger).count, 1, "the hop ran")
        XCTAssertEqual(fallbackEvents(orchestrator).count, 1)
        XCTAssertNil(orchestrator.snapshot.lastAuthOutcome, "the stop's cleared outcome stands")
        XCTAssertNil(orchestrator.snapshot.lastAuthFallbackReason)
    }

    /// Proxied tunnels authenticate through the same provider as the proxy. With the proxy stopped and the tunnels running, their outcome
    /// is the chip's, and a repeated success logs its transition line once, not once per handshake. Each hop's own write is its witness:
    /// the first publishes the outcome, and the second replaces a stamp written over the published one.
    @RuntimeActor
    func testATunnelOnlyOutcomeAfterAProxyStopIsPublishedAndLogsItsTransitionOnce() async throws {
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let logger = RecordingLogSink()
        let orchestrator = makeOrchestrator(clock: clock, logger: logger, withTunnel: true)
        addTeardownBlock { await orchestrator.stopTunnels() }
        await orchestrator.stopProxy()
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running, "the tunnels run beside the stopped proxy")

        orchestrator.reportAuthOutcome(.kerberos, host: host)
        await waitUntil { orchestrator.snapshot.lastAuthOutcome == .kerberos }
        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .kerberos, "the tunnel's outcome is the chip's")
        orchestrator.mutateSnapshotForTesting { $0.lastAuthOutcomeAt = .distantPast }
        orchestrator.reportAuthOutcome(.kerberos, host: host)
        await waitUntil { orchestrator.snapshot.lastAuthOutcomeAt != .distantPast }
        XCTAssertNotEqual(orchestrator.snapshot.lastAuthOutcomeAt, .distantPast, "the second hop ran")
        XCTAssertEqual(kerberosLines(logger).count, 1, "one transition line for two successes")
    }

    /// Once a producer has admitted anything and none admits running, a success publishes nothing and logs no transition the chip will not
    /// show, however often it repeats; its event is still recorded. Either producer's stop counts, so the escape before any admission means
    /// neither has admitted anything. A hop that does nothing has no output of its own: a fallback's hop, reported after the successes,
    /// is the positive control whose line says how long a hop takes to land here, and the negative is read after ten times that, at least
    /// 100 ms. That is a measured bound, not a proof that both no-op hops ran.
    @RuntimeActor
    func testRepeatedSuccessesWithEveryProducerStoppedPublishNothingAndLogNoTransition() async throws {
        for stoppedProducer in ["proxy", "tunnels"] {
            let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
            let logger = RecordingLogSink()
            let orchestrator = makeOrchestrator(clock: clock, logger: logger)
            if stoppedProducer == "proxy" { await orchestrator.stopProxy() } else { await orchestrator.stopTunnels() }

            let reported = ContinuousClock.now
            orchestrator.reportAuthOutcome(.kerberos, host: host)
            orchestrator.reportAuthOutcome(.kerberos, host: host)
            orchestrator.reportAuthOutcome(.ntlmFallback, host: "control.corp.example:8080", reason: "service_ticket_unavailable")
            await waitUntil { !fallbackLines(logger).isEmpty }
            XCTAssertEqual(fallbackLines(logger).count, 1, "\(stoppedProducer): the control's hop ran")
            try await Task.sleep(for: max(reported.duration(to: .now) * 10, .milliseconds(100)))

            XCTAssertTrue(kerberosLines(logger).isEmpty, "\(stoppedProducer): no transition line while nothing produces outcomes")
            XCTAssertNil(orchestrator.snapshot.lastAuthOutcome, "\(stoppedProducer): nothing published")
            let successes = orchestrator.eventLog.events.filter { $0.event == "auth.kerberos_succeeded" }
            XCTAssertEqual(successes.count, 2, "\(stoppedProducer): the events stay unconditional")
        }
    }

    private func kerberosLines(_ logger: RecordingLogSink) -> [String] {
        logger.entries().map(\.message).filter { $0.hasPrefix("Using Kerberos for") }
    }

    /// Waits, bounded, until `condition` holds; the caller's assertions say what was missing.
    @RuntimeActor
    private func waitUntil(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
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
        XCTAssertEqual(error.diagnosticDetail, "major=65536 minor=0 krb5_probe=unavailable")
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
