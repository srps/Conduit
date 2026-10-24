// SPDX-License-Identifier: Apache-2.0

// MARK: - Scanner

/// A bounded, schema-directed check over the private body (decisions 0018 and 0021). It walks the body against
/// `PrivateConfigurationSchema`, so every key must be named there, each duplicate is refused (even one spelled with
/// escapes), each approved array is refused at its count before its elements are read, and each string is refused at
/// the first byte past its ceiling. A bypass list is also refused once its canonical JSON width passes 8,192 bytes,
/// which is charged as each item closes, so no later byte is read.
///
/// The lexical rules (whitespace, literals, numbers, strings, escapes, UTF-8 and control characters) belong to
/// `JSONByteCursor`, which the runtime file reader shares. This walk adds only what the wire needs: the schema, the
/// duplicate mask, the approved counts and widths, and the token rule. A lexical `Fault` becomes the one wire refusal
/// here. The scanner keeps no copy of the text and allocates nothing per key: names are matched from the fixed tables
/// as their bytes arrive.
struct PrivateJSONScanner {
    /// The schema nests six levels deep at most: root, runtime, dns, entries, entry and servers.
    /// Eight is a stack bound, not a size limit.
    static let maxDepth = 8

    private var cursor: JSONByteCursor

    private init(cursor: JSONByteCursor) {
        self.cursor = cursor
    }

    static func validate(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        var scanner = PrivateJSONScanner(cursor: JSONByteCursor(bytes))
        do {
            scanner.cursor.skipWhitespace()
            try scanner.scanValue(.object(PrivateConfigurationSchema.request), depth: 0)
            try scanner.cursor.expectEnd()
        } catch is JSONByteCursor.Fault {
            // Every lexical refusal is the same wire refusal. The fault names no byte, and the wire names no field.
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    /// Scans one value of the given shape. A token that the shape does not allow is refused here, which
    /// is the same refusal Foundation would give for that type, reached before any value is decoded.
    private mutating func scanValue(_ shape: PrivateValueShape, depth: Int) throws {
        guard let byte = cursor.current else {
            throw PrivateConfigurationWireError.malformedBody
        }
        switch (shape, byte) {
        case (.object(let object), UInt8(ascii: "{")):
            try scanObject(object, depth: depth)
        case (.array(let field, let element), UInt8(ascii: "[")):
            try scanArray(field, element, depth: depth)
        case (.string(let field), UInt8(ascii: "\"")), (.nullableString(let field), UInt8(ascii: "\"")):
            try scanString(field)
        case (.nullableString, UInt8(ascii: "n")):
            try cursor.scanLiteral("null")
        case (.bool, UInt8(ascii: "t")):
            try cursor.scanLiteral("true")
        case (.bool, UInt8(ascii: "f")):
            try cursor.scanLiteral("false")
        case (.number, UInt8(ascii: "-")), (.number, UInt8(ascii: "0")...UInt8(ascii: "9")):
            try cursor.scanNumber()
        default:
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    private mutating func scanObject(_ object: PrivateObjectShape, depth: Int) throws {
        guard depth < Self.maxDepth else {
            throw PrivateConfigurationWireError.malformedBody
        }
        try cursor.expect(UInt8(ascii: "{"))
        cursor.skipWhitespace()
        if cursor.consumeIf(UInt8(ascii: "}")) {
            return
        }
        // One bit per member position. A repeated key, even one spelled with escapes, makes the object
        // ambiguous, so its bit is already set and the repeat is refused.
        var seen: UInt64 = 0
        while true {
            cursor.skipWhitespace()
            guard cursor.current == UInt8(ascii: "\"") else {
                throw PrivateConfigurationWireError.malformedBody
            }
            let position = try scanKey(of: object)
            let bit: UInt64 = 1 << UInt64(position)
            guard seen & bit == 0 else {
                throw PrivateConfigurationWireError.malformedBody
            }
            seen |= bit
            cursor.skipWhitespace()
            try cursor.expect(UInt8(ascii: ":"))
            cursor.skipWhitespace()
            try scanValue(object.members[position].shape, depth: depth + 1)
            cursor.skipWhitespace()
            if cursor.consumeIf(UInt8(ascii: ",")) {
                continue
            }
            guard cursor.consumeIf(UInt8(ascii: "}")) else {
                throw PrivateConfigurationWireError.malformedBody
            }
            return
        }
    }

    /// Reads one member name and returns its position in `object`. The name's decoded scalars are matched against the
    /// member names as they arrive, so no key is copied. A scalar that no name can match refuses the key at once, which
    /// is before its value and before any later key. Every member name is ASCII, so a non-ASCII scalar or escape
    /// refuses the key.
    private mutating func scanKey(of object: PrivateObjectShape) throws -> Int {
        var candidates = object.allMembers
        var length = 0
        try cursor.scanString { scalar in
            guard scalar.value < 0x80 else {
                throw PrivateConfigurationWireError.malformedBody
            }
            candidates = object.narrow(candidates, at: length, to: UInt8(scalar.value))
            guard candidates != 0 else {
                throw PrivateConfigurationWireError.malformedBody
            }
            length += 1
        }
        guard let position = object.member(among: candidates, length: length) else {
            throw PrivateConfigurationWireError.malformedBody
        }
        return position
    }

    /// Scans one array of at most the field's approved count. The count is checked before an element is
    /// read, so the element past the ceiling is never scanned, even when it is empty or malformed.
    private mutating func scanArray(_ field: DomainResourceField, _ element: PrivateValueShape, depth: Int) throws {
        guard depth < Self.maxDepth else {
            throw PrivateConfigurationWireError.malformedBody
        }
        try cursor.expect(UInt8(ascii: "["))
        cursor.skipWhitespace()
        if cursor.consumeIf(UInt8(ascii: "]")) {
            return
        }
        var count = 0
        // A list with a canonical-width ceiling is charged as each item closes. That is the same order the typed
        // check uses, so the first ceiling crossed in item order is the one refused.
        var encoded = CanonicalJSONStringList()
        while true {
            cursor.skipWhitespace()
            count += 1
            if let violation = DomainResourceCheck.entries(count, field) {
                throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
            }
            if let encodedField = field.encodedListField, case .string(let item) = element {
                encoded.append(quotedWidth: try scanString(item).canonicalBytes)
                if let violation = DomainResourceCheck.encodedBytes(encoded.bytes, encodedField) {
                    throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
                }
            } else {
                try scanValue(element, depth: depth + 1)
            }
            cursor.skipWhitespace()
            if cursor.consumeIf(UInt8(ascii: ",")) {
                continue
            }
            guard cursor.consumeIf(UInt8(ascii: "]")) else {
                throw PrivateConfigurationWireError.malformedBody
            }
            return
        }
    }

    /// The decoded UTF-8 length of one string as it is read, whether its first two bytes are the `*.`
    /// wildcard prefix, and its canonical JSON width with quotes (`CanonicalJSONWidth`). An escape counts as
    /// the bytes it decodes to, so `é` is two bytes. A raw byte and its escape have the same canonical width.
    private struct DecodedText {
        private(set) var byteCount = 0
        private(set) var canonicalBytes = 2
        /// True while every byte so far has matched the wildcard prefix.
        private var wildcardCandidate = true

        /// One decoded scalar, raw or escaped. An ASCII scalar counts one byte and may extend the wildcard prefix. A
        /// multibyte scalar is never part of that prefix, so it rules the prefix out.
        mutating func append(_ scalar: Unicode.Scalar) {
            if scalar.value < 0x80 {
                let byte = UInt8(scalar.value)
                switch byteCount {
                case 0: wildcardCandidate = byte == UInt8(ascii: "*")
                case 1: wildcardCandidate = wildcardCandidate && byte == UInt8(ascii: ".")
                default: break
                }
                byteCount += 1
            } else {
                if byteCount < 2 {
                    wildcardCandidate = false
                }
                byteCount += Self.width(of: scalar)
            }
            canonicalBytes += CanonicalJSONWidth.scalarWidth(scalar.value)
        }

        var hasWildcardPrefix: Bool {
            byteCount >= 2 && wildcardCandidate
        }

        static func width(of scalar: Unicode.Scalar) -> Int {
            switch scalar.value {
            case 0..<0x80: 1
            case 0x80..<0x800: 2
            case 0x800..<0x10000: 3
            default: 4
            }
        }
    }

    /// Scans one value string under its field's ceiling. Its decoded UTF-8 length is counted as it is read,
    /// and the first byte past the ceiling is refused, so the rest of the string is never scanned. Nothing
    /// is copied: the value is decoded later, and only from bytes this pass has accepted. The returned text
    /// carries the string's canonical width, which a list charges once the string closes.
    @discardableResult
    private mutating func scanString(_ field: DomainResourceField) throws -> DecodedText {
        var text = DecodedText()
        try cursor.scanString { scalar in
            text.append(scalar)
            try Self.enforce(field, text)
        }
        return text
    }

    /// Refuses the string once its decoded length passes the field's ceiling for its prefix. A token past its
    /// lexical guard is not a token under the grammar, so it is malformed and not a resource refusal.
    private static func enforce(_ field: DomainResourceField, _ text: DecodedText) throws {
        guard let violation = DomainResourceCheck.utf8(
            text.byteCount, wildcardPrefix: text.hasWildcardPrefix, field
        ) else {
            return
        }
        if field == .token {
            throw PrivateConfigurationWireError.malformedBody
        }
        throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
    }
}
