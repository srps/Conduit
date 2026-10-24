// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shared bounds for bypass host tokens consumed by routing and system settings.
package enum ProxyBypassSyntax {
    package static let maximumEntries = 256
    /// One bound for a host or domain token, shared with the domain grammar: a bypass entry is a host pattern.
    package static let maximumEntryBytes = DomainNameSyntax.maxLength
    // Leave room for both expected/prior settings and other fields in the bounded request.
    package static let maximumJSONBytes = 8_192

    package static func validationProblem(_ entries: [String]) -> String? {
        guard entries.count <= maximumEntries else { return "At most \(maximumEntries) bypass entries are supported." }
        guard entries.allSatisfy({ $0.utf8.count <= maximumEntryBytes && !$0.contains("\u{0}") }) else {
            return "Each bypass entry must fit \(maximumEntryBytes) UTF-8 bytes and contain no NUL characters."
        }
        // The size is the default `JSONEncoder` width of the list, counted without encoding it. It is checked last, so
        // the count and item diagnostics above keep precedence.
        var array = CanonicalJSONStringList()
        for entry in entries {
            array.append(quotedWidth: CanonicalJSONWidth.quotedWidth(entry))
        }
        guard DomainResourceCheck.encodedBytes(array.bytes, .noProxyList) == nil else {
            return "The encoded bypass list must fit \(maximumJSONBytes) bytes."
        }
        return nil
    }
}
