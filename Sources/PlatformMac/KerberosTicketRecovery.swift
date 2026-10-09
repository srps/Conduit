// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package enum KerberosTicketRecoveryError: Error, LocalizedError {
    case executableUnavailable
    case workerFailed(Int32)
    case workerGSSFailure(UInt32, UInt32)
    case invalidReply

    package var errorDescription: String? {
        switch self {
        case .executableUnavailable: return "kerberos_worker_unavailable"
        case .workerFailed(let status): return "kerberos_worker_exit_\(status)"
        case .workerGSSFailure(let major, let minor):
            return "kerberos_worker_gss_failed major=\(major) minor=\(Int32(bitPattern: minor))"
        case .invalidReply: return "kerberos_worker_invalid_reply"
        }
    }
}

/// Re-exec preserves the signed caller identity and SSO credential access.
/// Only status codes leave the worker; stdout/stderr never enter a log.
package struct SystemKerberosTicketRecovery: KerberosTicketRecovering {
    private let executable: URL?
    private let run: @Sendable (String, [String], TimeInterval, Int) throws -> CommandResult

    package init(
        executable: URL? = Bundle.main.executableURL,
        run: @escaping @Sendable (String, [String], TimeInterval, Int) throws -> CommandResult = {
            try CommandRunner.run(launchPath: $0, arguments: $1, timeout: $2, maxOutputBytes: $3)
        }
    ) {
        self.executable = executable
        self.run = run
    }

    package func primeServiceTicket(host: String) throws {
        guard let executable else { throw KerberosTicketRecoveryError.executableUnavailable }
        // CommandRunner additionally bounds termination and pipe-drain waits.
        let result = try run(executable.path, [KerberosTicketRecoveryReply.argument, host], 10, 512)
        let reply: KerberosTicketRecoveryReply
        do {
            reply = try CanonicalJSON.decoder().decode(KerberosTicketRecoveryReply.self, from: Data(result.standardOutput.utf8))
        } catch {
            // Report the protocol failure category, never echo worker output.
            if result.exitCode != 0 { throw KerberosTicketRecoveryError.workerFailed(result.exitCode) }
            throw KerberosTicketRecoveryError.invalidReply
        }
        if result.exitCode != 0 {
            if reply.major & 0xFFFF_0000 != 0 {
                throw KerberosTicketRecoveryError.workerGSSFailure(reply.major, reply.minor)
            }
            throw KerberosTicketRecoveryError.workerFailed(result.exitCode)
        }
        guard reply.major & 0xFFFF_0000 == 0 else { throw KerberosTicketRecoveryError.invalidReply }
    }
}
