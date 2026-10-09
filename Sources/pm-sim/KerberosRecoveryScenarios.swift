// SPDX-License-Identifier: Apache-2.0
import Foundation
import GSS
import NIOConcurrencyHelpers
import ProxyAuth
import ProxyKernel

enum KerberosRecoveryScenarios {
    private struct Recoverer: KerberosTicketRecovering {
        let prime: @Sendable (String) throws -> Void
        func primeServiceTicket(host: String) throws { try prime(host) }
    }
    private struct Offline: Error {}

    static func negativeCache() throws -> ScenarioResult {
        let started = Date()
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1000))
        // A process-local negative cache stays pinned even after the network
        // recovers. Only the successful independent ticket acquisition clears
        // it, modeling Apple's credential-cache notification.
        let state = NIOLockedValueBox((online: false, pinned: true, primes: 0, attempts: 0))
        let events = RuntimeEventLog(capacity: 16)
        let host = "proxy.corp.sim.example"
        let failure = KerberosAuthError.serviceTicketUnavailable(host: host, major: OM_uint32(GSS_S_BAD_MECH), minor: 0,
            mech: .status(major: OM_uint32(GSS_S_FAILURE), minor: UInt32(bitPattern: -1_765_328_228)))
        let recovery = KerberosKDCRecovery(recoverer: Recoverer { _ in
            try state.withLockedValue {
                $0.primes += 1
                guard $0.online else { throw Offline() }
                $0.pinned = false
            }
        }, now: { clock.withLockedValue { $0 } })
        let provider = SystemGSSTokenProvider(
            gate: GSSInitiatorGate(cooldown: 5, now: { clock.withLockedValue { $0 } }),
            kdcRecovery: recovery, eventSink: { events.append($0) }, gssAttempt: { _, _ in
                try state.withLockedValue {
                    $0.attempts += 1
                    guard !$0.pinned else { throw failure }
                    return Data([0x60, 1, 0])
                }
            }
        )
        func handshake() throws -> String {
            try NegotiateAuthenticator(kerberos: KerberosAuthenticator(tokenProvider: provider),
                ntlmFallback: NTLMAuthenticator(credentials: ProxyCredentials(
                    username: "sim", domain: "SIM", workstation: "WS", ntHash: SecretBytes.repeating(0xAA, count: 16))))
                .initialToken(for: host)
        }
        let offlineFallback = try handshake().hasPrefix("NTLM ")
        state.withLockedValue { $0.online = true }
        clock.withLockedValue { $0.addTimeInterval(6) }
        let heldFallback = try handshake().hasPrefix("NTLM ")
        let boundedPrimes = state.withLockedValue { $0.primes == 1 }
        clock.withLockedValue { $0.addTimeInterval(54) }
        let recovered = try handshake().hasPrefix("Negotiate ")
        let continuation = try provider.generateToken(host: host, inputToken: Data([1])) != nil
        let healthy = try handshake().hasPrefix("Negotiate ")
        let outcomes = events.events.map(\.event)
        return ScenarioResult(
            name: "kerberos-kdc-recovery", clientCount: 5, clientsOpened: 5, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("offline KDC retains NTLM fallback", offlineFallback),
                .init("parent negative cache remains pinned when only the network recovers", heldFallback),
                .init("recovery is limited across queued handshakes", boundedPrimes),
                .init("independent ticket acquisition recovers the same parent without restart", recovered),
                .init("continuation and later handshakes keep Kerberos", continuation && healthy),
                .init("only two priming attempts were needed", state.withLockedValue { $0.primes == 2 }),
                .init("recovery decisions and outcomes are structured", outcomes == [
                    "auth.kerberos_recovery_started", "auth.kerberos_recovery_failed",
                    "auth.kerberos_recovery_started", "auth.kerberos_recovery_succeeded"])
            ],
            notes: ["primes=\(state.withLockedValue { $0.primes }) attempts=\(state.withLockedValue { $0.attempts })"]
        )
    }
}
