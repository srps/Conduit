// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import ProxyAuth
import ProxyKernel

/// Issue #73. An upstream challenges with `Negotiate` and GSS answers the way
/// macOS SPNEGO does for any Kerberos-mech failure: `GSS_S_BAD_MECH`, minor
/// 0. With a TGT in the cache that is a service ticket the KDC would not
/// issue, and the health check must call it unreachable so recovery runs;
/// without one it is a missing credential, which recovery cannot supply.
enum KerberosScenarios {

    /// Stands in for `gss_init_sec_context` only; the classification is the
    /// production `KerberosAuthError.initiatorFailure`.
    private final class HeimdalBadMechProvider: GSSTokenProvider, @unchecked Sendable {
        let hasTGT: Bool
        init(hasTGT: Bool) { self.hasTGT = hasTGT }

        func generateToken(host: String, inputToken: Data?) throws -> Data? {
            let hasTGT = self.hasTGT
            throw KerberosAuthError.initiatorFailure(
                major: OM_uint32(GSS_S_BAD_MECH), minor: 0, host: host,
                hasInitiatorCredential: { hasTGT }
            )
        }

        func resetContext() {}
    }

    @MainActor
    static func serviceTicketUnavailable(verbose: Bool) async throws -> ScenarioResult {
        let name = "kerberos-service-ticket"
        let start = Date()
        var notes: [String] = []

        func healthFailure(hasTGT: Bool) async throws -> HealthCheckFailure? {
            let harness = SimHarness(verbose: verbose)
            ScenarioCleanup.register { await harness.stop() }
            try await harness.start(originBehavior: .silent, authenticatorProvider: { _ in
                NegotiateAuthenticator(kerberos: KerberosAuthenticator(tokenProvider: HeimdalBadMechProvider(hasTGT: hasTGT)))
            })
            guard let server = harness.server else {
                await harness.stop()
                return nil
            }
            let result = await server.performHealthCheck()
            await harness.stop()
            notes.append("hasTGT=\(hasTGT) healthy=\(result.healthy) failure=\(result.failure.map { "\($0)" } ?? "-")")
            return result.failure
        }

        let withTGT = try await healthFailure(hasTGT: true)
        let withoutTGT = try await healthFailure(hasTGT: false)

        var serviceTicketIsUnreachable = false
        if case .unreachable(let detail)? = withTGT {
            serviceTicketIsUnreachable = detail.contains("service ticket") && !detail.contains("kinit")
        }
        var missingTGTIsCredentialUnavailable = false
        if case .credentialUnavailable? = withoutTGT { missingTGTIsCredentialUnavailable = true }

        return ScenarioResult(
            name: name, clientCount: 2, clientsOpened: 2, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("TGT present, no service ticket: health check is unreachable, so recovery runs", serviceTicketIsUnreachable),
                .init("no TGT: health check is credential-unavailable, so recovery is skipped", missingTGTIsCredentialUnavailable),
            ],
            notes: notes
        )
    }

    private final class SimulatedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var current = Date(timeIntervalSince1970: 1_000)

        var now: Date { lock.withLock { current } }
        func advance(_ seconds: TimeInterval) { lock.withLock { current.addTimeInterval(seconds) } }
    }

    /// Fails with a fixed Kerberos minor until `ticketable` is set, the way a
    /// TGS request fails until the credential cache can ticket the proxy.
    private final class ServiceTicketProvider: GSSTokenProvider, @unchecked Sendable {
        static let principalUnknown = OM_uint32(bitPattern: -1_765_328_377)
        private let lock = NSLock()
        private var ticketable = false

        func makeTicketable() { lock.withLock { ticketable = true } }

        func generateToken(host: String, inputToken: Data?) throws -> Data? {
            guard lock.withLock({ ticketable }) else {
                throw KerberosAuthError.initiatorFailure(
                    major: OM_uint32(GSS_S_BAD_MECH), minor: Self.principalUnknown, host: host,
                    hasInitiatorCredential: { true }
                )
            }
            return Data([0x60, 0x01, 0x00])
        }

        func resetContext() {}
    }

    /// Issue #99. A proxy Kerberos cannot ticket falls back to NTLM on every
    /// handshake. A burst of 100 fallbacks is one `auth.kerberos_fallback_ntlm`
    /// event and one NOTICE line carrying the GSS codes; the next one after
    /// the interval reports `suppressed=99`. Once the ticket can be had, the
    /// next handshake uses Kerberos.
    @MainActor
    static func fallbackFlood() async throws -> ScenarioResult {
        let name = "kerberos-fallback-flood"
        let start = Date()
        let host = "rb-proxy-de.sim.example"
        let clock = SimulatedClock()
        let logger = RecordingLogSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig(),
            logger: logger,
            authFallbackEventGate: RuntimeEventRepeatGate(repeatInterval: 60, now: { clock.now })
        )
        let provider = ServiceTicketProvider()
        let ntlm = NTLMAuthenticator(credentials: ProxyCredentials(
            username: "sim", domain: "SIM", workstation: "WS", ntHash: SecretBytes.repeating(0xAA, count: 16)
        ))

        func handshake() throws -> String {
            let auth = NegotiateAuthenticator(
                kerberos: KerberosAuthenticator(tokenProvider: provider),
                ntlmFallback: ntlm,
                onKerberosFallback: { [weak orchestrator] fallbackHost, reason, diagnostics in
                    orchestrator?.reportAuthOutcome(.ntlmFallback, host: fallbackHost, reason: reason, diagnostics: diagnostics)
                }
            )
            return try auth.initialToken(for: host, allowFallback: true).token
        }

        var burstUsedNTLM = true
        for _ in 0..<100 {
            burstUsedNTLM = try handshake().hasPrefix("NTLM ") && burstUsedNTLM
            clock.advance(0.5)
        }
        await Task { @MainActor in }.value
        func fallbackEvents() -> [RuntimeEvent] {
            orchestrator.eventLog.events.filter { $0.event == "auth.kerberos_fallback_ntlm" }
        }
        func fallbackLines() -> [String] {
            logger.entries().map(\.message).filter { $0.contains("falling back to NTLMv2") }
        }
        let burstEvents = fallbackEvents().count
        let burstLines = fallbackLines().count
        let codes = "major=\(GSS_S_BAD_MECH) minor=-1765328377 krb5_error=KRB5KDC_ERR_S_PRINCIPAL_UNKNOWN"
        let firstCarriesCodes = fallbackEvents().first?.detail?.contains(codes) ?? false

        clock.advance(60)
        _ = try handshake()
        await Task { @MainActor in }.value
        let repeatDetail = fallbackEvents().last?.detail ?? ""
        let repeatLine = fallbackLines().last ?? ""

        provider.makeTicketable()
        let afterTicket = try handshake()

        return ScenarioResult(
            name: name, clientCount: 102, clientsOpened: 102, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every handshake in the burst fell back to NTLM", burstUsedNTLM),
                .init("100 fallbacks in a minute are one event", burstEvents == 1),
                .init("100 fallbacks in a minute are one log line", burstLines == 1),
                .init("the event carries the GSS major, minor and Kerberos error name", firstCarriesCodes),
                .init("the first fallback after the interval reports suppressed=99",
                      fallbackEvents().count == 2 && repeatDetail.hasSuffix("suppressed=99")),
                .init("its log line carries the codes and the count",
                      repeatLine.contains(codes) && repeatLine.contains("99 fallbacks")),
                .init("once the service ticket can be had, the next handshake uses Kerberos",
                      afterTicket.hasPrefix("Negotiate ")),
            ],
            notes: ["burstEvents=\(burstEvents) burstLines=\(burstLines)", "repeat: \(repeatDetail)"]
        )
    }
}
