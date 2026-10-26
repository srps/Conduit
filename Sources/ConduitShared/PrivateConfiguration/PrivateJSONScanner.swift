// SPDX-License-Identifier: Apache-2.0

// MARK: - Scanner

/// A bounded, schema-directed check over a private body (decisions 0018 and 0021). It walks the body against the
/// root table of its frame kind in `PrivateConfigurationSchema`, so every key must be named there, each duplicate is refused (even one spelled with
/// escapes), each approved array is refused at its count before its elements are read, and each string is refused at
/// the first byte past its ceiling. A bypass list is also refused once its canonical JSON width passes 8,192 bytes,
/// which is charged as each item closes, so no later byte is read.
///
/// The lexical rules (whitespace, literals, numbers, strings, escapes, UTF-8 and control characters) belong to
/// `JSONByteCursor`. The scalar and list charges belong to `DomainResourceStringBudget` and
/// `DomainResourceListBudget`, which the runtime file filter shares. This walk adds only what the wire needs: the
/// schema, the duplicate mask and the token rule. A lexical `Fault` becomes the one wire refusal here. The scanner
/// keeps no copy of the text and allocates nothing per key: names are matched from the fixed tables as their bytes
/// arrive.
struct PrivateJSONScanner {
    /// The schema nests seven levels deep at most: the reply root, observation, runtime, dns, entries, entry and
    /// servers. Eight is a stack bound, not a size limit.
    static let maxDepth = 8

    private var cursor: JSONByteCursor

    private init(cursor: JSONByteCursor) {
        self.cursor = cursor
    }

    /// Walks one body against `root`, the root table of the body's frame kind.
    static func validate(_ bytes: UnsafeBufferPointer<UInt8>, root: PrivateObjectShape) throws {
        var scanner = PrivateJSONScanner(cursor: JSONByteCursor(bytes))
        do {
            scanner.cursor.skipWhitespace()
            try scanner.scanValue(.object(root), depth: 0)
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
        case (.string(let field), UInt8(ascii: "\"")):
            try scanString(field)
        case (.nullable, UInt8(ascii: "n")):
            try cursor.scanLiteral("null")
        case (.nullable(let inner), _):
            // Not a nesting level: the wrapped value sits in the same position.
            try scanValue(inner, depth: depth)
        case (.bool, UInt8(ascii: "t")):
            try cursor.scanLiteral("true")
        case (.bool, UInt8(ascii: "f")):
            try cursor.scanLiteral("false")
        case (.number, UInt8(ascii: "-")), (.number, UInt8(ascii: "0")...UInt8(ascii: "9")):
            try cursor.scanNumber()
        case (.unsignedDecimal, UInt8(ascii: "0")...UInt8(ascii: "9")):
            try scanUnsignedDecimal()
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
        var list = DomainResourceListBudget()
        while true {
            cursor.skipWhitespace()
            if let violation = list.admitElement(field) {
                throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
            }
            if let encodedField = field.encodedListField, case .string(let item) = element {
                let text = try scanString(item)
                if let violation = list.closeStringItem(canonicalWidth: text.canonicalBytes, list: encodedField) {
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

    /// `UInt64.max` in decimal: the widest unsigned lexeme, and the one a 20-digit lexeme is compared with.
    private static let maxUnsignedDecimal = Array(String(UInt64.max).utf8)

    /// Scans one exact `UInt64`. The cursor consumes one JSON number lexeme. That lexeme must then be digits only, so a
    /// fraction or an exponent is refused, and no wider than `UInt64.max`. Two digit strings of equal length compare as
    /// numbers byte by byte. A leading zero is not refused here: the cursor ends a number after an initial `0`, so in
    /// `01` the lexeme is `0`, and the enclosing object's grammar refuses the `1` that follows where it expects `,` or `}`.
    private mutating func scanUnsignedDecimal() throws {
        let start = cursor.position
        try cursor.scanNumber()
        let lexeme = cursor.span(from: start)
        let limit = Self.maxUnsignedDecimal
        guard lexeme.count <= limit.count,
              lexeme.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }),
              lexeme.count < limit.count || !limit.lexicographicallyPrecedes(lexeme)
        else {
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    /// Scans one value string under its field's ceiling. Its decoded UTF-8 length is counted as it is read,
    /// and the first byte past the ceiling is refused, so the rest of the string is never scanned. Nothing
    /// is copied: the value is decoded later, and only from bytes this pass has accepted. The returned budget
    /// carries the string's canonical width, which a list charges once the string closes.
    @discardableResult
    private mutating func scanString(_ field: DomainResourceField) throws -> DomainResourceStringBudget {
        var text = DomainResourceStringBudget()
        try cursor.scanString { scalar in
            text.append(scalar)
            try Self.enforce(field, text)
        }
        return text
    }

    /// Refuses the string once its decoded length passes the field's ceiling for its prefix. A token past its
    /// lexical guard is not a token under the grammar, so it is malformed and not a resource refusal.
    private static func enforce(_ field: DomainResourceField, _ text: DomainResourceStringBudget) throws {
        guard let violation = text.violation(field) else {
            return
        }
        if field == .token {
            throw PrivateConfigurationWireError.malformedBody
        }
        throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
    }
}
