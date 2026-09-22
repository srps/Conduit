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
}
