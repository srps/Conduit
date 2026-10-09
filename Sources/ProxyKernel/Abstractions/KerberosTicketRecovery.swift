// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared

/// Obtains one service ticket outside the runtime's process-local GSS cache.
/// PlatformMac owns process launch; headless compositions leave this absent.
package protocol KerberosTicketRecovering: Sendable {
    func primeServiceTicket(host: String) throws
}

/// Codes only: the worker discards its token and never transports credentials.
package struct KerberosTicketRecoveryReply: Codable, Sendable {
    package static let argument = "--conduit-kerberos-ticket"
    package let major: UInt32
    package let minor: UInt32

    package init(major: UInt32, minor: UInt32) {
        self.major = major
        self.minor = minor
    }

    package static func isValidHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= DomainNameSyntax.maxLength else { return false }
        let literal = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
        if IPAddressSyntax.isLiteral(literal) { return true }
        // Validate a rooted DNS name without changing the SPN we pass to GSS.
        let domain = host.hasSuffix(".") ? String(host.dropLast()) : host
        do { try DomainNameSyntax.validate(domain); return true }
        catch { return false }
    }
}
