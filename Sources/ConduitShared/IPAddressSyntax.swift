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
public enum IPAddressSyntax {
    public static func isValid(_ address: String) -> Bool {
        isIPv4(address) || isIPv6(address)
    }

    public static func isIPv4(_ address: String) -> Bool {
        var buffer = in_addr()
        return inet_pton(AF_INET, address, &buffer) == 1
    }

    /// Bracketed literals (`[::1]`) are **not** accepted: the brackets are URL
    /// authority syntax (RFC 3986 §3.2.2), not part of the address, and the
    /// callers that need them — `routing.noProxyHosts`, the bypass list — carry
    /// whole host tokens rather than addresses. Stripping them here would make
    /// this quietly answer a different question for one caller than for the
    /// rest.
    public static func isIPv6(_ address: String) -> Bool {
        var buffer = in6_addr()
        return inet_pton(AF_INET6, address, &buffer) == 1
    }
}
