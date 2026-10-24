// SPDX-License-Identifier: Apache-2.0

// The strict lexical layer over the JSON that Conduit reads from its own inputs: the private request body and the
// runtime configuration file (decisions 0021, 0022 and 0024). It checks the JSON whitespace, the literals, the number
// grammar, the string escapes, the UTF-8 and the control characters, and it reports each decoded scalar. It knows no
// key, no field and no ceiling. A caller decides what a name means and what a value costs, and maps a `Fault` to its
// own refusal. The cursor reads the caller's bytes in place and copies none of them.

/// A forward-only position in one JSON text. A method either consumes its whole token or throws. A throw means the text
/// is not valid JSON at that point, and the cursor says nothing about what follows it. An error thrown by a scalar
/// visitor passes through unchanged, so a caller's refusal stops the scan at the byte that caused it.
///
/// The cursor is valid only inside the closure that supplies its buffer.
package struct JSONByteCursor {
    /// A lexical refusal. It carries no byte, key or value, so it can be returned or logged without echoing the input.
    package enum Fault: Error, Sendable, Equatable {
        /// The text ends where a token must continue.
        case truncated
        /// A byte the grammar does not allow at this position.
        case unexpectedByte
        case invalidLiteral
        case invalidNumber
        case invalidEscape
        /// A high surrogate escape not followed at once by an escaped low surrogate, or a lone low surrogate.
        case unpairedSurrogate
        /// Bytes that are not well-formed UTF-8: overlong forms, surrogate code points and values past U+10FFFF included.
        case invalidUTF8
        /// A raw control character (U+0000 through U+001F) inside a string. Only an escape may spell one.
        case controlCharacter
        /// Containers nest deeper than the caller allowed.
        case nestingTooDeep
        /// Bytes other than JSON whitespace follow the complete value.
        case trailingContent
    }

    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    package init(_ bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    /// The byte at the cursor, or nil at the end of the text.
    package var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    package var isAtEnd: Bool {
        index == bytes.count
    }

    /// Skips the JSON whitespace: space, tab, line feed and carriage return. Nothing else is whitespace.
    package mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    /// Consumes `byte` when it is the current byte, and reports whether it did.
    @discardableResult
    package mutating func consumeIf(_ byte: UInt8) -> Bool {
        guard current == byte else {
            return false
        }
        index += 1
        return true
    }

    /// Consumes `byte`, which must be the current byte.
    package mutating func expect(_ byte: UInt8) throws {
        guard let found = current else {
            throw Fault.truncated
        }
        guard found == byte else {
            throw Fault.unexpectedByte
        }
        index += 1
    }

    /// Consumes one of the literals `true`, `false` or `null`, spelled exactly.
    package mutating func scanLiteral(_ literal: String) throws {
        for byte in literal.utf8 {
            guard let found = current else {
                throw Fault.truncated
            }
            guard found == byte else {
                throw Fault.invalidLiteral
            }
            index += 1
        }
    }

    /// Consumes one JSON number: an optional minus, an integer part with no leading zero, an optional fraction, and an
    /// optional exponent. Foundation decides whether the lexeme is an integer or a finite double.
    package mutating func scanNumber() throws {
        consumeIf(UInt8(ascii: "-"))
        guard let first = current, Self.isDigit(first) else {
            throw Fault.invalidNumber
        }
        index += 1
        if first != UInt8(ascii: "0") {
            while let byte = current, Self.isDigit(byte) {
                index += 1
            }
        }
        if consumeIf(UInt8(ascii: ".")) {
            try scanDigits()
        }
        if consumeIf(UInt8(ascii: "e")) || consumeIf(UInt8(ascii: "E")) {
            if !consumeIf(UInt8(ascii: "+")) {
                consumeIf(UInt8(ascii: "-"))
            }
            try scanDigits()
        }
    }

    /// Consumes one string and calls `visit` with each scalar it decodes to, in order. Raw UTF-8 and escapes both reach
    /// `visit`, so a caller counts the decoded text. `visit` runs before the next byte is read, so a throw from it stops
    /// the scan at the scalar that caused it.
    package mutating func scanString(_ visit: (Unicode.Scalar) throws -> Void) throws {
        try expect(UInt8(ascii: "\""))
        while true {
            guard let byte = current else {
                throw Fault.truncated
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                return
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                try visit(try scanEscape())
            } else if byte < 0x20 {
                throw Fault.controlCharacter
            } else if byte < 0x80 {
                index += 1
                try visit(Unicode.Scalar(byte))
            } else {
                try visit(try scanMultibyteScalar())
            }
        }
    }

    /// The raw bytes from `start` up to the cursor, which a caller copies as an accepted span. Nothing is decoded.
    package func span(from start: Int) -> UnsafeBufferPointer<UInt8> {
        UnsafeBufferPointer(rebasing: bytes[start..<index])
    }

    /// The offset of the cursor from the start of the text.
    package var position: Int {
        index
    }

    /// `skipValue(maxDepth:containers:)` with a stack of its own, for a caller that skips once.
    package mutating func skipValue(maxDepth: Int) throws {
        var containers = JSONContainerStack()
        try skipValue(maxDepth: maxDepth, containers: &containers)
    }

    /// Consumes one value of any shape without materializing it. The walk uses an explicit stack, so depth costs heap
    /// bits rather than call frames. `maxDepth` bounds the open containers and is the caller's choice. The caller's
    /// stack is emptied first and keeps its storage, so one stack can serve a whole text without a new allocation per
    /// skipped value.
    package mutating func skipValue(maxDepth: Int, containers: inout JSONContainerStack) throws {
        containers.reset()
        valueStart: while true {
            skipWhitespace()
            guard let byte = current else {
                throw Fault.truncated
            }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                guard containers.count < maxDepth else {
                    throw Fault.nestingTooDeep
                }
                index += 1
                let isObject = byte == UInt8(ascii: "{")
                containers.push(isObject: isObject)
                skipWhitespace()
                if consumeIf(isObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) {
                    containers.pop()
                } else {
                    if isObject {
                        try skipMemberName()
                    }
                    continue valueStart
                }
            case UInt8(ascii: "\""):
                try scanString { _ in }
            case UInt8(ascii: "t"):
                try scanLiteral("true")
            case UInt8(ascii: "f"):
                try scanLiteral("false")
            case UInt8(ascii: "n"):
                try scanLiteral("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try scanNumber()
            default:
                throw Fault.unexpectedByte
            }
            // A value is complete. Close each container it ends, then continue the parent at its separator.
            while let innermostIsObject = containers.innermostIsObject {
                skipWhitespace()
                guard let separator = current else {
                    throw Fault.truncated
                }
                index += 1
                if separator == UInt8(ascii: ",") {
                    if innermostIsObject {
                        try skipMemberName()
                    }
                    continue valueStart
                }
                guard separator == (innermostIsObject ? UInt8(ascii: "}") : UInt8(ascii: "]")) else {
                    throw Fault.unexpectedByte
                }
                containers.pop()
            }
            return
        }
    }

    /// Consumes the trailing whitespace and requires the end of the text.
    package mutating func expectEnd() throws {
        skipWhitespace()
        guard isAtEnd else {
            throw Fault.trailingContent
        }
    }

    // MARK: - Private lexical rules

    private mutating func skipMemberName() throws {
        skipWhitespace()
        try scanString { _ in }
        skipWhitespace()
        try expect(UInt8(ascii: ":"))
    }

    private mutating func scanDigits() throws {
        guard let first = current, Self.isDigit(first) else {
            throw Fault.invalidNumber
        }
        while let byte = current, Self.isDigit(byte) {
            index += 1
        }
    }

    /// The scalar an escape decodes to. The index is past the backslash.
    private mutating func scanEscape() throws -> Unicode.Scalar {
        guard let letter = current else {
            throw Fault.truncated
        }
        index += 1
        switch letter {
        case UInt8(ascii: "\""): return "\""
        case UInt8(ascii: "\\"): return "\\"
        case UInt8(ascii: "/"): return "/"
        case UInt8(ascii: "b"): return "\u{08}"
        case UInt8(ascii: "f"): return "\u{0C}"
        case UInt8(ascii: "n"): return "\n"
        case UInt8(ascii: "r"): return "\r"
        case UInt8(ascii: "t"): return "\t"
        case UInt8(ascii: "u"): return try scanUnicodeEscape()
        default: throw Fault.invalidEscape
        }
    }

    private mutating func scanUnicodeEscape() throws -> Unicode.Scalar {
        let unit = try scanHex4()
        if (0xD800...0xDBFF).contains(unit) {
            // A high surrogate must be followed at once by an escaped low surrogate.
            guard current == UInt8(ascii: "\\") else {
                throw Fault.unpairedSurrogate
            }
            index += 1
            guard current == UInt8(ascii: "u") else {
                throw Fault.unpairedSurrogate
            }
            index += 1
            let low = try scanHex4()
            guard (0xDC00...0xDFFF).contains(low),
                  let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
            else {
                throw Fault.unpairedSurrogate
            }
            return scalar
        }
        // A lone low surrogate is not a scalar value, so it is refused rather than replaced.
        guard let scalar = Unicode.Scalar(unit) else {
            throw Fault.unpairedSurrogate
        }
        return scalar
    }

    private mutating func scanHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current else {
                throw Fault.truncated
            }
            guard let digit = Self.hexValue(byte) else {
                throw Fault.invalidEscape
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
    }

    /// The scalar of the well-formed multibyte sequence at the cursor. The index moves past it.
    private mutating func scanMultibyteScalar() throws -> Unicode.Scalar {
        let length = try utf8SequenceLength()
        let value = scalarValue(length: length)
        index += length
        guard let scalar = Unicode.Scalar(value) else {
            throw Fault.invalidUTF8
        }
        return scalar
    }

    /// The length of the well-formed UTF-8 sequence at the cursor, which starts with a byte of 0x80 or more. Overlong
    /// forms, surrogate code points and values past U+10FFFF are refused.
    private func utf8SequenceLength() throws -> Int {
        func continuation(_ offset: Int, _ low: UInt8 = 0x80, _ high: UInt8 = 0xBF) -> Bool {
            guard index + offset < bytes.count else { return false }
            let byte = bytes[index + offset]
            return byte >= low && byte <= high
        }
        let lead = bytes[index]
        let length: Int
        switch lead {
        case 0xC2...0xDF where continuation(1):
            length = 2
        case 0xE0 where continuation(1, 0xA0, 0xBF) && continuation(2):
            length = 3
        case 0xE1...0xEC where continuation(1) && continuation(2),
             0xEE...0xEF where continuation(1) && continuation(2):
            length = 3
        case 0xED where continuation(1, 0x80, 0x9F) && continuation(2):
            length = 3
        case 0xF0 where continuation(1, 0x90, 0xBF) && continuation(2) && continuation(3):
            length = 4
        case 0xF1...0xF3 where continuation(1) && continuation(2) && continuation(3):
            length = 4
        case 0xF4 where continuation(1, 0x80, 0x8F) && continuation(2) && continuation(3):
            length = 4
        default:
            throw Fault.invalidUTF8
        }
        return length
    }

    /// The scalar value of a sequence `utf8SequenceLength` has validated, read from its bytes without a copy.
    private func scalarValue(length: Int) -> UInt32 {
        let leadMask: UInt8 = length == 2 ? 0x1F : (length == 3 ? 0x0F : 0x07)
        var value = UInt32(bytes[index] & leadMask)
        for offset in 1..<length {
            value = (value << 6) | UInt32(bytes[index + offset] & 0x3F)
        }
        return value
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"):
            return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"):
            return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"):
            return UInt32(byte - UInt8(ascii: "A") + 10)
        default:
            return nil
        }
    }
}

/// The open containers of one skip, one bit each, true for an object. A 64-level word is added only when the nesting
/// reaches it, so the stack costs what the input's real depth costs and nothing for shallow input. A caller reuses one
/// stack across skips: `reset` empties it and keeps its words.
package struct JSONContainerStack {
    private var words: [UInt64] = []
    private(set) var count = 0

    package init() {}

    package mutating func reset() {
        count = 0
    }

    /// Whether the innermost open container is an object, or nil when none is open.
    var innermostIsObject: Bool? {
        guard count > 0 else {
            return nil
        }
        let level = count - 1
        return words[level >> 6] & (1 << UInt64(level & 63)) != 0
    }

    mutating func push(isObject: Bool) {
        let word = count >> 6
        if word == words.count {
            words.append(0)
        }
        let bit: UInt64 = 1 << UInt64(count & 63)
        if isObject {
            words[word] |= bit
        } else {
            words[word] &= ~bit
        }
        count += 1
    }

    mutating func pop() {
        count -= 1
    }
}
