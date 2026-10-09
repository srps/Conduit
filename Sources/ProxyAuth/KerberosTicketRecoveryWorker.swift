// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

/// Handled before any AppState/daemon composition: no listeners, helper,
/// configuration, Keychain password, platform settings or UI are touched.
package enum KerberosTicketRecoveryWorker {
    package static func run(
        arguments: [String],
        probe: (String) -> KerberosMechStatus = SystemGSSTokenProvider.probeKerberosMech(host:),
        write: (Data) -> Void = { FileHandle.standardOutput.write($0) }
    ) -> Int32? {
        guard arguments.contains(KerberosTicketRecoveryReply.argument) else { return nil }
        guard arguments.count == 2, arguments[0] == KerberosTicketRecoveryReply.argument,
              KerberosTicketRecoveryReply.isValidHost(arguments[1]) else { return EX_USAGE }
        guard case .status(let major, let minor) = probe(arguments[1]) else { return EX_UNAVAILABLE }
        do {
            var reply = try CanonicalJSON.encoder().encode(KerberosTicketRecoveryReply(major: major, minor: minor))
            reply.append(10)
            write(reply)
            return major & 0xFFFF_0000 == 0 ? 0 : EX_UNAVAILABLE
        } catch {
            // A failed encode is an explicit worker failure, never a success.
            return EX_SOFTWARE
        }
    }
}
