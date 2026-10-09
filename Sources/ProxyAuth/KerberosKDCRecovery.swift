// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Caller holds the process-wide GSS gate throughout priming and retry.
/// Apple's negative service-ticket cache has no TTL and survives fresh GSS
/// contexts. Acquiring a new ticket in a fresh process can cause the real
/// credential-cache notification that invalidates it; retry confirms that.
package final class KerberosKDCRecovery: Sendable {
    private let recoverer: any KerberosTicketRecovering
    private let limiter: RuntimeEventRepeatGate

    package init(
        recoverer: any KerberosTicketRecovering,
        now: @escaping @Sendable () -> Date = Date.init
    ) {
        self.recoverer = recoverer
        // One attempt per minute across all targets of this runtime factory,
        // not one child per queued handshake or upstream. No pending queue.
        self.limiter = RuntimeEventRepeatGate(repeatInterval: 60, now: now)
    }

    package func run(
        host: String,
        inputToken: Data?,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        attempt: () throws -> Data?
    ) throws -> Data? {
        do {
            return try attempt()
        } catch let failure as KerberosAuthError {
            // Restart only an initial leg, never a stateful continuation or
            // an integrity/configuration failure. The raw mech confirms KDC
            // reachability: SPNEGO's BAD_MECH alone is insufficient.
            guard inputToken?.isEmpty ?? true,
                  failure.isKDCUnreachable,
                  limiter.shouldEmit(host: "runtime", reason: "kdc_recovery") else { throw failure }
            let codes = failure.diagnosticDetail.map { " \($0)" } ?? ""
            eventSink?(RuntimeEvent(kind: .auth, event: "auth.kerberos_recovery_started",
                                   detail: "host=\(host) reason=kdc_unreachable\(codes)"))
            do {
                try recoverer.primeServiceTicket(host: host)
            } catch {
                eventSink?(RuntimeEvent(kind: .auth, event: "auth.kerberos_recovery_failed",
                                       detail: "host=\(host) stage=prime reason=\(error.displayDescription)"))
                throw failure
            }
            do {
                let token = try attempt()
                guard let token, !token.isEmpty else { throw KerberosAuthError.emptyToken }
                eventSink?(RuntimeEvent(kind: .auth, event: "auth.kerberos_recovery_succeeded",
                                       detail: "host=\(host)"))
                return token
            } catch {
                let retryCodes = (error as? KerberosAuthError)?.diagnosticDetail.map { " \($0)" } ?? ""
                eventSink?(RuntimeEvent(kind: .auth, event: "auth.kerberos_recovery_failed",
                                       detail: "host=\(host) stage=retry\(retryCodes)"))
                throw error
            }
        }
    }
}

extension KerberosAuthError {
    package var isKDCUnreachable: Bool {
        let kdcUnreachable = UInt32(bitPattern: -1_765_328_228)
        switch self {
        case .initSecContextFailed(let major, let minor):
            return major & 0xFFFF_0000 != 0 && minor == kdcUnreachable
        case .serviceTicketUnavailable(_, _, _, .status(let major, let minor)):
            return major & 0xFFFF_0000 != 0 && minor == kdcUnreachable
        default:
            return false
        }
    }
}
