// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The one redaction and bounding path for display text on the v2 wire (decision 0029). Only `bounded` sanitizes or cuts, and the projection
/// and the unknown-event display both reach text through it. The codec's checks (`ControlDisplayCheck`) never sanitize: they only measure
/// with `exceeds`, and refuse a value over its cap. The field caps live in `ControlDisplayField`, the closed table that also decides each
/// field's notice.
package enum ControlDisplayText {
    /// A value over this many UTF-8 bytes is replaced whole by `omittedValue`, before any redaction or other copy-heavy work.
    package static let inputLimitBytes = 16_384
    /// The fixed value of an omitted field. Its notice says why the value is this one, since the text alone does not.
    package static let omittedValue = "<omitted>"

    /// Whether `value` holds more than `limit` UTF-8 bytes. A native string is read at most `limit + 1` bytes before the answer is
    /// known, so an oversize value costs no more than that. A bridged NSString may materialize its UTF-8 on its first access, which is
    /// outside this bound, as `ControlFrameBudget.text` documents.
    package static func exceeds(_ value: String, limit: Int) -> Bool {
        var count = 0
        for _ in value.utf8 {
            count += 1
            if count > limit { return true }
        }
        return false
    }

    /// The display form of `value` within `maxBytes`. An input over `inputLimitBytes` is omitted whole and never sanitized. Any other
    /// input is redacted first and then cut at a character boundary, so a cut never leaves half of a redacted URL or credential behind.
    /// Redaction alone changes no notice.
    package static func bounded(_ value: String, maxBytes: Int) -> ControlDisplayed {
        guard !exceeds(value, limit: inputLimitBytes) else {
            return ControlDisplayed(text: omittedValue, treatment: .omitted)
        }
        // The sanitizer and the cut run in one synchronous scope. The scope bounds the transient autoreleased references the sanitizer creates.
        // A returned String keeps its own storage through ARC, so the result does not depend on the pool.
        return scoped { () -> ControlDisplayed in
            let sanitized = sanitize(value)
            guard exceeds(sanitized, limit: maxBytes) else {
                return ControlDisplayed(text: sanitized, treatment: nil)
            }
            var kept = ""
            var bytes = 0
            for character in sanitized {
                let width = character.utf8.count
                guard bytes + width <= maxBytes else { break }
                kept.append(character)
                bytes += width
            }
            return ControlDisplayed(text: kept, treatment: .shortened)
        }
    }

    /// A URL loses its query and fragment, and the diagnostics sanitizer then masks the credentials, headers and tokens it recognizes.
    private static func sanitize(_ value: String) -> String {
        var text = value
        if text.contains("://"), let start = text.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            text = String(text[..<start]) + "<redacted>"
        }
        return ControlDiagnostics.sanitizeString(text)
    }

    /// Runs `body` in a synchronous autorelease scope where the Objective-C runtime exists, and directly elsewhere. The scope bounds the
    /// transient autoreleased references created while `body` runs. It adds no state, no cache and no dependency, and the body's result is
    /// returned by value.
    private static func scoped<Result>(_ body: () -> Result) -> Result {
        #if canImport(ObjectiveC)
        return autoreleasepool { body() }
        #else
        return body()
        #endif
    }
}

/// Display text after the policy: the text the wire carries and the treatment it received, if any.
package struct ControlDisplayed: Sendable, Equatable {
    package let text: String
    package let treatment: ControlDisplayTreatment?
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
    /// True when any text was cut or omitted to its display bound.
    package let truncated: Bool

    package init(timestamp: Date, kind: String, event: String, detail: String?) {
        let shortKind = ControlDisplayText.bounded(kind, maxBytes: Self.maxKindBytes)
        let name = ControlDisplayText.bounded(event, maxBytes: Self.maxEventBytes)
        let text = detail.map { ControlDisplayText.bounded($0, maxBytes: Self.maxDetailBytes) }
        self.timestamp = timestamp
        self.kind = shortKind.text
        self.event = name.text
        self.detail = text?.text
        self.truncated = shortKind.treatment != nil || name.treatment != nil || text?.treatment != nil
    }
}
