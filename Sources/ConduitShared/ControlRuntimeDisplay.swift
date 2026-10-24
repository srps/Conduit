// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Sanitized display text for values that cross the v2 wire as free text. The snapshot
/// projection and the unknown-event display records both use it, so one policy applies.
package enum ControlDisplayText {
    /// A URL loses its query and fragment. The diagnostics sanitizer then masks the
    /// credentials, headers and tokens it recognizes.
    package static func sanitize(_ value: String) -> String {
        var text = value
        if text.contains("://"), let start = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<start]) + "<redacted>"
        }
        return ControlDiagnostics.sanitizeString(text)
    }

    /// `sanitize`, then cut at a character boundary so the result is at most `maxBytes`
    /// UTF-8 bytes. Sanitizing first means a cut never leaves a half-redacted URL behind.
    package static func bounded(_ value: String, maxBytes: Int) -> (text: String, truncated: Bool) {
        let sanitized = sanitize(value)
        guard sanitized.utf8.count > maxBytes else { return (sanitized, false) }
        var kept = ""
        var bytes = 0
        for character in sanitized {
            let width = character.utf8.count
            guard bytes + width <= maxBytes else { break }
            kept.append(character)
            bytes += width
        }
        return (kept, true)
    }
}

/// A bounded, redacted record of a future informational event this build does not
/// define. It keeps the readable parts (time, kind, event name and detail) and drops
/// any structured payload, since such fields may carry secrets. The bounds are fixed
/// display limits of this wire, not configuration.
///
/// Decode-only: a host never sends one, so encoding a record that holds one fails.
package struct ControlUnknownEventDisplay: Sendable, Equatable {
    package static let maxKindBytes = 64
    package static let maxEventBytes = 128
    package static let maxDetailBytes = 512

    package let timestamp: Date
    package let kind: String
    package let event: String
    package let detail: String?
    /// True when any text was cut to its display bound.
    package let truncated: Bool

    package init(timestamp: Date, kind: String, event: String, detail: String?) {
        let shortKind = ControlDisplayText.bounded(kind, maxBytes: Self.maxKindBytes)
        let name = ControlDisplayText.bounded(event, maxBytes: Self.maxEventBytes)
        let text = detail.map { ControlDisplayText.bounded($0, maxBytes: Self.maxDetailBytes) }
        self.timestamp = timestamp
        self.kind = shortKind.text
        self.event = name.text
        self.detail = text?.text
        self.truncated = shortKind.truncated || name.truncated || (text?.truncated ?? false)
    }
}
