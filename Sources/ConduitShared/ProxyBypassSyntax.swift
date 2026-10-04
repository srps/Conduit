// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Shared bounds for bypass host tokens consumed by routing and system settings.
package enum ProxyBypassSyntax {
    package static let maximumEntries = 256
    package static let maximumEntryBytes = 253
    // Leave room for both expected/prior settings and other fields in the bounded request.
    package static let maximumJSONBytes = 8_192

    package static func validationProblem(_ entries: [String]) -> String? {
        guard entries.count <= maximumEntries else { return "At most \(maximumEntries) bypass entries are supported." }
        guard entries.allSatisfy({ $0.utf8.count <= maximumEntryBytes && !$0.contains("\u{0}") }) else {
            return "Each bypass entry must fit \(maximumEntryBytes) UTF-8 bytes and contain no NUL characters."
        }
        do {
            guard try JSONEncoder().encode(entries).count <= maximumJSONBytes else {
                return "The encoded bypass list must fit \(maximumJSONBytes) bytes."
            }
        } catch { return "The bypass list could not be encoded." }
        return nil
    }
}
