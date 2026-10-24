// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

// One strict pass over a configuration file's bytes, before any typed decode (decisions 0021, 0022, 0024 and 0026). The pass
// checks the grammar, UTF-8, escapes and controls over every byte. It keeps the first occurrence of each known key and copies
// that value's accepted span, and it skips unknown keys, later duplicates and unknown values without building them. A known
// value is checked against its shape and resource ceiling before its span is copied, so an over-limit value is refused and a
// wrong-kind value is refused before Foundation allocates it.
//
// A wrong-kind value under a legacy component of the runtime file is not refused: it marks that component refused, its value
// is skipped, and the loader falls back to that component's defaults with a warning, as the extraction always did. Every
// other wrong-kind value refuses the file, including every key of a sidecar (decision 0026). An over-limit legacy value is
// still refused, because the resource policy is selected for every boundary.

/// Why a file was refused at the format gate. It names no key or value.
package enum ConfigurationFileRefusal: Error, Sendable, Equatable {
    /// The bytes are not the strict grammar, or a known value has the wrong kind for its key. Foundation would refuse the
    /// same file, and this refusal is reached before any value is built.
    case malformed
    /// A value crossed its resource ceiling. The violation names the field and the limit, never the value.
    case resourceLimit(DomainResourceViolation)
}

/// The filter's output: the bytes a typed decode may read, and the legacy components the file refused.
package struct ConfigurationFileFiltered: Sendable {
    /// The filtered document, built in place so the typed decode reads it without another copy.
    package let bytes: Data
    package let refusedComponents: Set<ConfigurationComponent>
}

/// The one format gate for a configuration file: the root's physical budget, then the strict filter over its known keys. It
/// is shared by the runtime file, the platform sidecar and the preferences sidecar. A refusal is the loader's fixed reason,
/// with the source the loader names. Nothing is decoded or written here.
package enum ConfigurationFileGate {
    package static func filter(_ bytes: Data, root: ConfigurationFileRoot, source: String) throws -> ConfigurationFileFiltered {
        guard bytes.count <= root.maximumBytes else {
            throw ConfigurationLoadError(source: source, reason: "The configuration exceeds the file size limit.")
        }
        do {
            return try bytes.withUnsafeBytes { raw in
                try ConfigurationFileFilter.filter(
                    UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count),
                    root: root
                )
            }
        } catch let refusal as ConfigurationFileRefusal {
            throw ConfigurationLoadError(source: source, reason: refusal.reason)
        }
    }
}

extension ConfigurationFileRefusal {
    /// The fixed reason a loader reports. It names the limit, never the value that crossed it.
    var reason: String {
        switch self {
        case .malformed:
            "The configuration is not valid Conduit JSON."
        case .resourceLimit(let violation):
            "The configuration exceeds a resource limit. \(violation.description)."
        }
    }
}

/// The filter itself. It keeps one output buffer sized to the input and one key buffer and one container stack for the
/// whole file. Nothing is allocated per unknown element.
struct ConfigurationFileFilter {
    /// The absolute container depth a file may reach, known and unknown containers counted alike, with the root object as
    /// depth one. It is the depth the typed decoder accepts, not a schema bound. `RuntimeFileDepthParityTests` pins it.
    static let maximumDepth = 512

    private var cursor: JSONByteCursor
    /// The filtered document. Each append copies a span or punctuation of the input, so it grows to at most the input's
    /// size and never past it. Its growth is `Data`'s own amortized growth, not one reserved allocation.
    private var output = Data()
    private var containers = JSONContainerStack()
    private var keyBytes: [UInt8] = []
    private var refused: Set<ConfigurationComponent> = []
    /// Whether a wrong-kind legacy value falls back, which only the runtime file's root allows.
    private let fallsBackToLegacyComponents: Bool

    private init(cursor: JSONByteCursor, fallsBackToLegacyComponents: Bool) {
        self.cursor = cursor
        self.fallsBackToLegacyComponents = fallsBackToLegacyComponents
    }

    /// Filters `bytes` against `root`. The output is never longer than the input.
    static func filter(_ bytes: UnsafeBufferPointer<UInt8>, root: ConfigurationFileRoot) throws(ConfigurationFileRefusal) -> ConfigurationFileFiltered {
        var filter = ConfigurationFileFilter(
            cursor: JSONByteCursor(bytes),
            fallsBackToLegacyComponents: root.fallsBackToLegacyComponents
        )
        filter.keyBytes.reserveCapacity(root.object.longestName)
        do {
            filter.cursor.skipWhitespace()
            try filter.retainObject(root.object, depth: 1)
            try filter.cursor.expectEnd()
        } catch let refusal as ConfigurationFileRefusal {
            throw refusal
        } catch {
            // Every lexical fault is the same refusal. The fault names no byte, so none is echoed.
            throw ConfigurationFileRefusal.malformed
        }
        precondition(filter.output.count <= bytes.count, "a filtered file is never longer than its input")
        return ConfigurationFileFiltered(bytes: filter.output, refusedComponents: filter.refused)
    }

    // MARK: - Objects and members

    /// Filters one object whose cursor is at `{`. `depth` is the object's own absolute depth.
    private mutating func retainObject(_ schema: ConfigurationObjectSchema, depth: Int) throws {
        try checkDepth(depth)
        try cursor.expect(UInt8(ascii: "{"))
        output.append(UInt8(ascii: "{"))
        var seen = [Bool](repeating: false, count: schema.members.count)
        var emitted = 0
        cursor.skipWhitespace()
        if cursor.consumeIf(UInt8(ascii: "}")) {
            output.append(UInt8(ascii: "}"))
            return
        }
        while true {
            cursor.skipWhitespace()
            guard cursor.current == UInt8(ascii: "\"") else {
                throw ConfigurationFileRefusal.malformed
            }
            let keyStart = cursor.position
            let slot = try matchKey(schema)
            let keySpan = cursor.span(from: keyStart)
            cursor.skipWhitespace()
            try cursor.expect(UInt8(ascii: ":"))
            cursor.skipWhitespace()
            if let slot, !seen[slot] {
                seen[slot] = true
                let member = schema.members[slot]
                if try retainOrRefuse(member, depth: depth) {
                    if emitted > 0 {
                        output.append(UInt8(ascii: ","))
                    }
                    emitted += 1
                    output.append(contentsOf: keySpan)
                    output.append(UInt8(ascii: ":"))
                    try retainValue(member.shape, depth: depth)
                }
            } else {
                try skipUnknown(depth: depth)
            }
            cursor.skipWhitespace()
            if cursor.consumeIf(UInt8(ascii: ",")) {
                continue
            }
            guard cursor.consumeIf(UInt8(ascii: "}")) else {
                throw ConfigurationFileRefusal.malformed
            }
            output.append(UInt8(ascii: "}"))
            return
        }
    }

    /// Decides whether a known member's value is emitted. A wrong-kind value refuses the file, except a legacy value of the
    /// runtime file: that marks its component refused and is skipped, so Foundation never sees it. A sidecar's keys never fall
    /// back. The component is not required, and its key is not in the table, so the value is never reached here.
    private mutating func retainOrRefuse(_ member: ConfigurationMember, depth: Int) throws -> Bool {
        guard let byte = cursor.current else {
            throw ConfigurationFileRefusal.malformed
        }
        if byte == UInt8(ascii: "n") || member.shape.accepts(byte) {
            return true
        }
        guard fallsBackToLegacyComponents, member.component != .runtime else {
            throw ConfigurationFileRefusal.malformed
        }
        refused.insert(member.component)
        try skipUnknown(depth: depth)
        return false
    }

    /// Matches one key against the table. Its bytes are collected into the reused buffer up to the longest name. Any
    /// scalar past ASCII, or a key past that length, is unknown: it is still validated, and it matches nothing.
    private mutating func matchKey(_ schema: ConfigurationObjectSchema) throws -> Int? {
        var key = keyBytes
        keyBytes = []
        key.removeAll(keepingCapacity: true)
        defer { keyBytes = key }
        var overflow = false
        let limit = schema.longestName
        try cursor.scanString { scalar in
            guard scalar.value < 0x80, key.count < limit else {
                overflow = true
                return
            }
            key.append(UInt8(scalar.value))
        }
        return overflow ? nil : schema.slot(for: key)
    }

    // MARK: - Values

    /// Copies one known value's accepted span, or filters an array of objects. The value's kind was checked by the caller
    /// (`retainOrRefuse`), and null is copied as it is.
    private mutating func retainValue(_ shape: ConfigurationValueShape, depth: Int) throws {
        guard let byte = cursor.current else {
            throw ConfigurationFileRefusal.malformed
        }
        if byte == UInt8(ascii: "n") {
            let start = cursor.position
            try cursor.scanLiteral("null")
            output.append(contentsOf: cursor.span(from: start))
            return
        }
        switch shape {
        case .string(let field):
            try retainString(field)
        case .decodedString:
            try retainString(nil)
        case .number:
            let start = cursor.position
            try cursor.scanNumber()
            output.append(contentsOf: cursor.span(from: start))
        case .bool:
            let start = cursor.position
            try cursor.scanLiteral(byte == UInt8(ascii: "t") ? "true" : "false")
            output.append(contentsOf: cursor.span(from: start))
        case .stringArray(let count, let item):
            try retainStringArray(count: count, item: item)
        case .objectArray(let count, let members):
            try retainObjectArray(count: count, members: members, depth: depth)
        }
    }

    /// Copies one string's span. A ceiling is checked as each scalar is read, so the first byte past it is the last one
    /// read. A decoded-only string has no ceiling and is copied whole.
    private mutating func retainString(_ field: DomainResourceField?) throws {
        let start = cursor.position
        var text = DomainResourceStringBudget()
        try cursor.scanString { scalar in
            text.append(scalar)
            if let field, let violation = text.violation(field) {
                throw ConfigurationFileRefusal.resourceLimit(violation)
            }
        }
        output.append(contentsOf: cursor.span(from: start))
    }

    /// Copies an array of strings. Its count is charged before each item, and each item to its ceiling and, for a list with
    /// one, the list's canonical width. The item is copied only after it is charged.
    private mutating func retainStringArray(count: DomainResourceField, item: DomainResourceField) throws {
        try cursor.expect(UInt8(ascii: "["))
        output.append(UInt8(ascii: "["))
        cursor.skipWhitespace()
        if cursor.consumeIf(UInt8(ascii: "]")) {
            output.append(UInt8(ascii: "]"))
            return
        }
        var list = DomainResourceListBudget()
        var first = true
        while true {
            cursor.skipWhitespace()
            if let violation = list.admitElement(count) {
                throw ConfigurationFileRefusal.resourceLimit(violation)
            }
            if !first {
                output.append(UInt8(ascii: ","))
            }
            first = false
            guard cursor.current == UInt8(ascii: "\"") else {
                throw ConfigurationFileRefusal.malformed
            }
            let start = cursor.position
            var text = DomainResourceStringBudget()
            try cursor.scanString { scalar in
                text.append(scalar)
                if let violation = text.violation(item) {
                    throw ConfigurationFileRefusal.resourceLimit(violation)
                }
            }
            if let encodedField = count.encodedListField,
               let violation = list.closeStringItem(canonicalWidth: text.canonicalBytes, list: encodedField) {
                throw ConfigurationFileRefusal.resourceLimit(violation)
            }
            output.append(contentsOf: cursor.span(from: start))
            cursor.skipWhitespace()
            if cursor.consumeIf(UInt8(ascii: ",")) {
                continue
            }
            guard cursor.consumeIf(UInt8(ascii: "]")) else {
                throw ConfigurationFileRefusal.malformed
            }
            output.append(UInt8(ascii: "]"))
            return
        }
    }

    /// Filters an array of objects, one filtered object per element, under the array's count.
    private mutating func retainObjectArray(count: DomainResourceField, members: ConfigurationObjectSchema, depth: Int) throws {
        try checkDepth(depth + 1)
        try cursor.expect(UInt8(ascii: "["))
        output.append(UInt8(ascii: "["))
        cursor.skipWhitespace()
        if cursor.consumeIf(UInt8(ascii: "]")) {
            output.append(UInt8(ascii: "]"))
            return
        }
        var list = DomainResourceListBudget()
        var first = true
        while true {
            cursor.skipWhitespace()
            if let violation = list.admitElement(count) {
                throw ConfigurationFileRefusal.resourceLimit(violation)
            }
            if !first {
                output.append(UInt8(ascii: ","))
            }
            first = false
            guard cursor.current == UInt8(ascii: "{") else {
                throw ConfigurationFileRefusal.malformed
            }
            try retainObject(members, depth: depth + 2)
            cursor.skipWhitespace()
            if cursor.consumeIf(UInt8(ascii: ",")) {
                continue
            }
            guard cursor.consumeIf(UInt8(ascii: "]")) else {
                throw ConfigurationFileRefusal.malformed
            }
            output.append(UInt8(ascii: "]"))
            return
        }
    }

    // MARK: - Skipping and depth

    /// Skips one unknown value strictly, without building it. Its containers count against the same absolute depth.
    private mutating func skipUnknown(depth: Int) throws {
        try cursor.skipValue(maxDepth: Self.maximumDepth - depth, containers: &containers)
    }

    private func checkDepth(_ depth: Int) throws {
        guard depth <= Self.maximumDepth else {
            throw ConfigurationFileRefusal.malformed
        }
    }
}
