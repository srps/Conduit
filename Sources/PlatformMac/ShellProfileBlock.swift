// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Conduit's region inside a shell profile it does not own, read strictly
/// (#175). The block is delimited by two marker lines; everything else in
/// the file is the user's and is never rewritten.
///
/// The previous editor matched the markers as substrings, anywhere. A start
/// marker without an end got a second block appended behind it, an end
/// before the start made the removal range invalid, and an unreadable file
/// was taken as empty and replaced. A profile is now either missing, ours to
/// edit, or left alone and reported.
package enum ShellProfileBlock {
    package static let startMarker = "# >>> Conduit >>>"
    package static let endMarker = "# <<< Conduit <<<"
    /// Larger than any real profile. A bigger file is reported, not loaded.
    package static let maximumFileBytes = 1 << 20

    /// Why a profile was left alone. The raw value is the event's `reason=`.
    package enum UnsafeReason: String, Sendable, Equatable {
        case unreadable
        case notUTF8 = "not_utf8"
        case oversized
        /// A start without an end, an end without a start, an end before
        /// the start, or more than one of either.
        case ambiguousMarkers = "ambiguous_markers"
        /// The file changed between the read and the write, twice.
        case changedDuringWrite = "changed_during_write"
    }

    package enum Contents: Equatable {
        /// No file. The only case `apply` may create one.
        case missing
        /// Readable, no markers.
        case unmanaged(String)
        /// Readable, one start line before one end line. `block` covers both
        /// marker lines and what lies between them, without a trailing newline.
        case managed(String, block: Range<String.Index>)
        case unsafe(UnsafeReason)
    }

    /// A line break. Swift reads `"\r\n"` as one `Character`, so matching
    /// `"\n"` alone misses every break in a CRLF file.
    private static func isLineBreak(_ character: Character) -> Bool { character == "\n" || character == "\r\n" }

    private static func endsWithLineBreak<S: StringProtocol>(_ text: S) -> Bool { text.last.map(isLineBreak) ?? false }

    /// Classifies a profile's text.
    package static func parse(_ text: String) -> Contents {
        var starts: [Range<String.Index>] = []
        var ends: [Range<String.Index>] = []
        var lineStart = text.startIndex
        while lineStart < text.endIndex {
            let lineEnd = text[lineStart...].firstIndex(where: isLineBreak) ?? text.endIndex
            let line = text[lineStart..<lineEnd].trimmingCharacters(in: .whitespaces)
            if line == startMarker { starts.append(lineStart..<lineEnd) }
            if line == endMarker { ends.append(lineStart..<lineEnd) }
            lineStart = lineEnd < text.endIndex ? text.index(after: lineEnd) : text.endIndex
        }
        switch (starts.count, ends.count) {
        case (0, 0):
            return .unmanaged(text)
        case (1, 1) where starts[0].upperBound <= ends[0].lowerBound:
            return .managed(text, block: starts[0].lowerBound..<ends[0].upperBound)
        default:
            return .unsafe(.ambiguousMarkers)
        }
    }

    /// The profile with `block` as Conduit's region, at the end of the file
    /// so its exports win over earlier ones; nil when the file cannot be
    /// edited. The user's text is kept byte for byte, apart from a missing
    /// final newline, which is added.
    package static func applying(_ block: String, to contents: Contents) -> String? {
        let base: String
        switch contents {
        case .missing: base = ""
        case .unmanaged(let text): base = text
        case .managed(let text, let range): base = removing(range, from: text)
        case .unsafe: return nil
        }
        if base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return block + "\n" }
        // Always exactly one blank line, which is what `removing` takes
        // back out; a file without a final newline gains one.
        return (endsWithLineBreak(base) ? base : base + "\n") + "\n" + block + "\n"
    }

    /// The profile without Conduit's region; nil when there is nothing to
    /// remove (no file, no block) or the file cannot be edited.
    package static func clearing(_ contents: Contents) -> String? {
        guard case .managed(let text, let range) = contents else { return nil }
        return removing(range, from: text)
    }

    /// Removes the block, its line break, and the one blank line `applying`
    /// put before it, and nothing else.
    private static func removing(_ range: Range<String.Index>, from text: String) -> String {
        var lower = range.lowerBound
        var upper = range.upperBound
        if upper < text.endIndex, isLineBreak(text[upper]) { upper = text.index(after: upper) }
        let before = text[..<lower]
        if endsWithLineBreak(before), endsWithLineBreak(before.dropLast()) { lower = text.index(before: lower) }
        return String(text[..<lower]) + String(text[upper...])
    }
}
