// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

/// Whether a string is a literal IP address, decided by the resolver rather
/// than by a pattern.
///
/// The only IP check this package had was `^[0-9a-fA-F:]+$`, which accepts
/// `::::::`, `ffff`, and `:` — anything spelled out of the right alphabet. That
/// is not a weak validator so much as a different one: it answers "are these
/// plausible IPv6 characters", which is not a question any caller was asking.
/// A new check layered on top of it would inherit the same blind spot, so this
/// calls `inet_pton`, which is the same parser that will later be asked to
/// interpret the value for real.
///
/// One family, one function, because "is this an IP address" turned out to be
/// nobody's question here either. The callers — the intercept-rule boundary and
/// its Settings field — need "can this be an A record", since
/// `DNSWireFormat.synthesizeDirectResponse` builds A records and nothing else.
/// A general `isValid` briefly existed and both callers reached for it, which
/// is how a config that blackholes its domain came to be certified as correct.
/// `isIPv6` and `isLiteral` arrived with the change that pointed
/// `HelperInputValidator.validateIPAddress` and `DNSManager.validateServer`
/// here — two DNS-server validators whose callers do ask "either family",
/// because `networksetup -setdnsservers` takes both. Each caller still names
/// the family it means; `isLiteral` is for the ones that mean both.
public enum IPAddressSyntax {
    /// Bracketed literals are **not** accepted for either family: brackets are
    /// URL authority syntax (RFC 3986 §3.2.2), not part of an address, and the
    /// callers that carry them — `routing.noProxyHosts`, the bypass list —
    /// carry whole host tokens rather than addresses. Stripping them here would
    /// make this quietly answer a different question for one caller than for
    /// the rest.
    public static func isIPv4(_ address: String) -> Bool {
        var buffer = in_addr()
        return inet_pton(AF_INET, address, &buffer) == 1
    }

    /// Unbracketed, and without a zone index. Darwin's `inet_pton` accepts
    /// `fe80::1%en0` (it is what `getaddrinfo` would hand back for a
    /// link-local scope), so the `%` is refused here explicitly: it is what a
    /// shell-adjacent consumer would misread, and no caller has a use for a
    /// link-local server.
    public static func isIPv6(_ address: String) -> Bool {
        guard !address.contains("%") else { return false }
        var buffer = in6_addr()
        return inet_pton(AF_INET6, address, &buffer) == 1
    }

    /// Either family. For the callers whose consumer takes both.
    public static func isLiteral(_ address: String) -> Bool {
        isIPv4(address) || isIPv6(address)
    }
}
