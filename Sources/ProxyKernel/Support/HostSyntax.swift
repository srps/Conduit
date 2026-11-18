// SPDX-License-Identifier: Apache-2.0
import ConduitShared

/// A host that untrusted text names: an IP address, or a domain name in
/// `DomainNameSyntax` that may be rooted with one trailing dot. Text that
/// passes holds only letters, digits, `.`, `-`, `_` and an address's `:`,
/// so it can go into a log line, an event field or a CONNECT as it is.
package enum HostSyntax {
    /// Without brackets or a zone index (`IPAddressSyntax`). A caller whose
    /// text is a URL authority strips its brackets first.
    package static func isHost(_ text: String) -> Bool {
        if IPAddressSyntax.isLiteral(text) { return true }
        // A rooted name is the same host; the caller keeps its spelling.
        return DomainNameSyntax.isValid(text.hasSuffix(".") ? String(text.dropLast()) : text)
    }
}
