// SPDX-License-Identifier: Apache-2.0
import Foundation

// The private decoder runs in two passes over one body:
//
//   1. `PrivateJSONScanner` checks the grammar, the UTF-8 and the escapes before any value is
//      read. Foundation's JSON parser does not reliably reject a duplicate key, an unpaired
//      surrogate escape or a silently replaced byte, and any of those would change a URL without
//      notice. The scanner refuses all three. It also refuses nesting deeper than a fixed stack
//      bound, which is structural and not a size limit.
//   2. `JSONDecoder` reads the checked bytes into `Decodable` mirrors. Each mirror builds its
//      DTO directly, so the DTOs stay non-`Codable`. Every field is required. Unknown keys are
//      refused at every level. Nothing defaults.
//
// Errors are fixed text. Nothing here echoes a key, a value or a byte.

// MARK: - Scanner

/// A bounded, schema-directed check over the body (decisions 0018 and 0021). It walks the body against
/// `PrivateConfigurationSchema`, so every key must be named there, each duplicate is refused (even one
/// spelled with escapes), each approved array is refused at its count before its elements are read, and
/// each string is refused at the first byte past its ceiling. A bypass list is also refused once its
/// canonical JSON width passes 8,192 bytes, which is charged as each item closes, so no later byte is read.
/// It keeps no copy of the text and allocates nothing per key: names are matched from the fixed tables as
/// their bytes arrive. Nothing it reads is zeroed, because nothing it reads is copied.
private struct PrivateJSONScanner {
    /// The schema nests six levels deep at most: root, runtime, dns, entries, entry and servers.
    /// Eight is a stack bound, not a size limit.
    static let maxDepth = 8

    private let bytes: UnsafeBufferPointer<UInt8>
    private var index = 0

    private init(bytes: UnsafeBufferPointer<UInt8>) {
        self.bytes = bytes
    }

    static func validate(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        var scanner = PrivateJSONScanner(bytes: bytes)
        scanner.skipWhitespace()
        try scanner.scanValue(.object(PrivateConfigurationSchema.request), depth: 0)
        scanner.skipWhitespace()
        guard scanner.index == bytes.count else {
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private mutating func skipWhitespace() {
        while let byte = current, byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D {
            index += 1
        }
    }

    private mutating func expect(_ byte: UInt8) throws {
        guard current == byte else {
            throw PrivateConfigurationWireError.malformedBody
        }
        index += 1
    }

    /// Scans one value of the given shape. A token that the shape does not allow is refused here, which
    /// is the same refusal Foundation would give for that type, reached before any value is decoded.
    private mutating func scanValue(_ shape: PrivateValueShape, depth: Int) throws {
        guard let byte = current else {
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
            try scanLiteral("null")
        case (.bool, UInt8(ascii: "t")):
            try scanLiteral("true")
        case (.bool, UInt8(ascii: "f")):
            try scanLiteral("false")
        case (.number, UInt8(ascii: "-")), (.number, UInt8(ascii: "0")...UInt8(ascii: "9")):
            try scanNumber()
        default:
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    private mutating func scanObject(_ object: PrivateObjectShape, depth: Int) throws {
        guard depth < Self.maxDepth else {
            throw PrivateConfigurationWireError.malformedBody
        }
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return
        }
        // One bit per member position. A repeated key, even one spelled with escapes, makes the object
        // ambiguous, so its bit is already set and the repeat is refused.
        var seen: UInt64 = 0
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else {
                throw PrivateConfigurationWireError.malformedBody
            }
            let position = try scanKey(of: object)
            let bit: UInt64 = 1 << UInt64(position)
            guard seen & bit == 0 else {
                throw PrivateConfigurationWireError.malformedBody
            }
            seen |= bit
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            try scanValue(object.members[position].shape, depth: depth + 1)
            skipWhitespace()
            guard let next = current else {
                throw PrivateConfigurationWireError.malformedBody
            }
            index += 1
            if next == UInt8(ascii: ",") {
                continue
            }
            guard next == UInt8(ascii: "}") else {
                throw PrivateConfigurationWireError.malformedBody
            }
            return
        }
    }

    /// Reads one member name and returns its position in `object`. The name's decoded bytes are matched
    /// against the member names as they arrive, so no key is copied. A byte that no name can match
    /// refuses the key at once, which is before its value and before any later key. Every member name is
    /// ASCII, so a non-ASCII byte or escape refuses the key.
    private mutating func scanKey(of object: PrivateObjectShape) throws -> Int {
        try expect(UInt8(ascii: "\""))
        var candidates = object.allMembers
        var length = 0
        while true {
            guard let byte = current else {
                throw PrivateConfigurationWireError.malformedBody
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                break
            }
            let decoded: UInt8
            if byte == UInt8(ascii: "\\") {
                index += 1
                let scalar = try scanEscape()
                guard scalar.value < 0x80 else {
                    throw PrivateConfigurationWireError.malformedBody
                }
                decoded = UInt8(scalar.value)
            } else if byte < 0x20 || byte >= 0x80 {
                throw PrivateConfigurationWireError.malformedBody
            } else {
                index += 1
                decoded = byte
            }
            candidates = object.narrow(candidates, at: length, to: decoded)
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
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return
        }
        var count = 0
        // A list with a canonical-width ceiling is charged as each item closes. That is the same order the typed
        // check uses, so the first ceiling crossed in item order is the one refused.
        var encoded = CanonicalJSONStringList()
        while true {
            skipWhitespace()
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
            skipWhitespace()
            guard let next = current else {
                throw PrivateConfigurationWireError.malformedBody
            }
            index += 1
            if next == UInt8(ascii: ",") {
                continue
            }
            guard next == UInt8(ascii: "]") else {
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

        /// One ASCII scalar, raw or decoded from an escape.
        mutating func append(_ byte: UInt8) {
            switch byteCount {
            case 0: wildcardCandidate = byte == UInt8(ascii: "*")
            case 1: wildcardCandidate = wildcardCandidate && byte == UInt8(ascii: ".")
            default: break
            }
            byteCount += 1
            canonicalBytes += CanonicalJSONWidth.scalarWidth(UInt32(byte))
        }

        /// A multibyte scalar is never part of the ASCII prefix, so it rules the prefix out.
        mutating func appendMultibyte(_ width: Int, scalar: UInt32) {
            if byteCount < 2 {
                wildcardCandidate = false
            }
            byteCount += width
            canonicalBytes += CanonicalJSONWidth.scalarWidth(scalar)
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
        try expect(UInt8(ascii: "\""))
        var text = DecodedText()
        while true {
            guard let byte = current else {
                throw PrivateConfigurationWireError.malformedBody
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                return text
            }
            if byte < 0x20 {
                throw PrivateConfigurationWireError.malformedBody
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                let scalar = try scanEscape()
                if scalar.value < 0x80 {
                    text.append(UInt8(scalar.value))
                } else {
                    text.appendMultibyte(DecodedText.width(of: scalar), scalar: scalar.value)
                }
            } else if byte < 0x80 {
                text.append(byte)
                index += 1
            } else {
                let length = try utf8SequenceLength()
                text.appendMultibyte(length, scalar: scalarValue(at: index, length: length))
                index += length
            }
            try enforce(field, text)
        }
    }

    /// Refuses the string once its decoded length passes the field's ceiling for its prefix. A token past its
    /// lexical guard is not a token under the grammar, so it is malformed and not a resource refusal.
    private func enforce(_ field: DomainResourceField, _ text: DecodedText) throws {
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

    /// The scalar value of the validated multibyte sequence at `start`, read from its bytes without a copy.
    private func scalarValue(at start: Int, length: Int) -> UInt32 {
        let leadMask: UInt8 = length == 2 ? 0x1F : (length == 3 ? 0x0F : 0x07)
        var value = UInt32(bytes[start] & leadMask)
        for offset in 1..<length {
            value = (value << 6) | UInt32(bytes[start + offset] & 0x3F)
        }
        return value
    }

    private mutating func scanEscape() throws -> Unicode.Scalar {
        guard let letter = current else {
            throw PrivateConfigurationWireError.malformedBody
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
        case UInt8(ascii: "u"):
            let unit = try scanHex4()
            if (0xD800...0xDBFF).contains(unit) {
                // A high surrogate must be followed at once by an escaped low surrogate.
                try expect(UInt8(ascii: "\\"))
                try expect(UInt8(ascii: "u"))
                let low = try scanHex4()
                guard (0xDC00...0xDFFF).contains(low),
                      let scalar = Unicode.Scalar(0x10000 + ((unit - 0xD800) << 10) + (low - 0xDC00))
                else {
                    throw PrivateConfigurationWireError.malformedBody
                }
                return scalar
            }
            // A lone low surrogate is not a scalar value, so it is refused rather than replaced.
            guard let scalar = Unicode.Scalar(unit) else {
                throw PrivateConfigurationWireError.malformedBody
            }
            return scalar
        default:
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    private mutating func scanHex4() throws -> UInt32 {
        var value: UInt32 = 0
        for _ in 0..<4 {
            guard let byte = current, let digit = Self.hexValue(byte) else {
                throw PrivateConfigurationWireError.malformedBody
            }
            value = (value << 4) | digit
            index += 1
        }
        return value
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

    /// The length of the well-formed UTF-8 sequence at `index`, which starts with a byte of 0x80 or
    /// more. Overlong forms, surrogate code points and values past U+10FFFF are refused.
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
            throw PrivateConfigurationWireError.malformedBody
        }
        return length
    }

    private mutating func scanLiteral(_ text: String) throws {
        for byte in text.utf8 {
            guard current == byte else {
                throw PrivateConfigurationWireError.malformedBody
            }
            index += 1
        }
    }

    /// The JSON number grammar: an optional minus, an integer part with no leading zero,
    /// an optional fraction, and an optional exponent.
    private mutating func scanNumber() throws {
        if current == UInt8(ascii: "-") {
            index += 1
        }
        guard let first = current, Self.isDigit(first) else {
            throw PrivateConfigurationWireError.malformedBody
        }
        if first == UInt8(ascii: "0") {
            index += 1
        } else {
            while let byte = current, Self.isDigit(byte) {
                index += 1
            }
        }
        if current == UInt8(ascii: ".") {
            index += 1
            try scanDigits()
        }
        if current == UInt8(ascii: "e") || current == UInt8(ascii: "E") {
            index += 1
            if current == UInt8(ascii: "+") || current == UInt8(ascii: "-") {
                index += 1
            }
            try scanDigits()
        }
    }

    private mutating func scanDigits() throws {
        guard let first = current, Self.isDigit(first) else {
            throw PrivateConfigurationWireError.malformedBody
        }
        while let byte = current, Self.isDigit(byte) {
            index += 1
        }
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }
}

// MARK: - Decoding

/// Decodes one checked frame body into a request. The result carries no `Codable` path, so a
/// decoded value cannot be encoded by accident.
package enum PrivateConfigurationDecoder {
    package static func decode(_ body: PrivateConfigurationFrameBody) throws -> PrivateConfigurationRequest {
        try body.bytes.withUnsafeBytes { bytes in
            // The cap is checked here as well as in the reader. A body held in memory, such as one built
            // by a caller, never passed the reader's header check. This runs before the scanner, before
            // the `Data` copy and before any allocation, and it counts the whole frame, not the body alone.
            guard PrivateConfigurationFrame.frameByteCount(bodyCount: bytes.count) <= PrivateConfigurationFrame.maxFrameBytes else {
                throw PrivateConfigurationWireError.frameTooLarge
            }
            try PrivateJSONScanner.validate(bytes)
            // A temporary `Data` copy of the checked bytes. The codec is the only place that
            // makes one, and 0018 §3 records it.
            let data = Data(bytes)
            do {
                return try JSONDecoder().decode(WireRequest.self, from: data).request
            } catch {
                // Deliberate: every decode failure, including a `WireValue` refusal such as an out-of-range
                // port, is reported as one fixed `malformedBody`. The error names no field, so a caller learns
                // only that the body was refused. The tests pin this, and no finer taxonomy is claimed.
                throw PrivateConfigurationWireError.malformedBody
            }
        }
    }
}

// MARK: - Wire mirrors

/// Every member name of one JSON object. Its values are not read, so each one decodes to nothing.
///
/// Why this exists: a keyed container's `allKeys` drops any name that matches no `CodingKey`, so an
/// unknown key would pass a check built on it. Decoding the same object as a dictionary keeps every name.
private struct PrivateMemberNames: Decodable {
    private struct Unread: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    let names: [String]

    init(from decoder: any Decoder) throws {
        names = Array(try [String: Unread](from: decoder).keys)
    }
}

/// Opens an object's keyed container and refuses any key the schema does not name.
private extension Decoder {
    func strictContainer<Key: CodingKey>(_ keys: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let open = try container(keyedBy: keys)
        for name in try PrivateMemberNames(from: self).names where Key(stringValue: name) == nil {
            throw PrivateConfigurationWireError.malformedBody
        }
        return open
    }
}

/// Helpers that refuse a value the typed domain cannot represent.
private enum WireValue {
    static func uuid(_ text: String) throws -> UUID {
        guard let value = UUID(uuidString: text) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }

    static func port(_ value: Int) throws -> Int {
        guard (0...65_535).contains(value) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }

    static func finite(_ value: Double) throws -> Double {
        guard value.isFinite else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }

    static func ordinal<Domain: ControlIdentityDomain>(_ value: Int) throws -> ControlOrdinal<Domain> {
        guard let ordinal = ControlOrdinal<Domain>(rawValue: value) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return ordinal
    }

    static func budget(_ value: Int) throws -> ControlWireBudget {
        do {
            return try ControlWireBudget(value)
        } catch {
            throw PrivateConfigurationWireError.invalidValue
        }
    }

    static func enumValue<Value: RawRepresentable>(_ raw: String, _ type: Value.Type) throws -> Value
        where Value.RawValue == String
    {
        guard let value = Value(rawValue: raw) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }
}

private struct WireRequest: Decodable {
    let request: PrivateConfigurationRequest

    private enum Keys: String, CodingKey {
        case requestID, incarnation, budgetMilliseconds, expectedConfigRevision
        case expectedPlatformRevision, expectedOwnerGeneration, runtime, platform
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        request = PrivateConfigurationRequest(
            requestID: ControlRequestID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .requestID))),
            incarnation: ControlHostIncarnation(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .incarnation))),
            budget: try WireValue.budget(c.decode(Int.self, forKey: .budgetMilliseconds)),
            expectedConfigRevision: try WireValue.ordinal(c.decode(Int.self, forKey: .expectedConfigRevision)),
            expectedPlatformRevision: try WireValue.ordinal(c.decode(Int.self, forKey: .expectedPlatformRevision)),
            expectedOwnerGeneration: try WireValue.ordinal(c.decode(Int.self, forKey: .expectedOwnerGeneration)),
            runtime: try c.decode(WireRuntime.self, forKey: .runtime).value,
            platform: try c.decode(WirePlatform.self, forKey: .platform).value
        )
    }
}

private struct WireRuntime: Decodable {
    let value: PrivateRuntimeConfiguration

    private enum Keys: String, CodingKey {
        case profileName, proxy, auth, upstreams, routing, dns, tunnels, health, logging
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateRuntimeConfiguration(
            profileName: try c.decode(String.self, forKey: .profileName),
            proxy: try c.decode(WireProxy.self, forKey: .proxy).value,
            auth: try c.decode(WireAuth.self, forKey: .auth).value,
            upstreams: try c.decode([WireUpstream].self, forKey: .upstreams).map(\.value),
            routing: try c.decode(WireRouting.self, forKey: .routing).value,
            dns: try c.decode(WireDNS.self, forKey: .dns).value,
            tunnels: try c.decode(WireTunnels.self, forKey: .tunnels).value,
            health: try c.decode(WireHealth.self, forKey: .health).value,
            logging: try c.decode(WireLogging.self, forKey: .logging).value
        )
    }
}

private struct WireProxy: Decodable {
    let value: PrivateProxySettings

    private enum Keys: String, CodingKey {
        case host, port, socksEnabled, socksPort, gatewayMode, allowedClients, maxConnections
        case stalledConnectionTimeoutSeconds, maxBufferedBodyBytes, maxSpooledBodyBytes
        case inboundConnectionWarnThreshold, inboundConnectionMaxLimit, strictMode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateProxySettings(
            host: try c.decode(String.self, forKey: .host),
            port: try WireValue.port(c.decode(Int.self, forKey: .port)),
            socksEnabled: try c.decode(Bool.self, forKey: .socksEnabled),
            socksPort: try WireValue.port(c.decode(Int.self, forKey: .socksPort)),
            gatewayMode: try c.decode(Bool.self, forKey: .gatewayMode),
            allowedClients: try c.decode([String].self, forKey: .allowedClients),
            maxConnections: try c.decode(Int.self, forKey: .maxConnections),
            stalledConnectionTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .stalledConnectionTimeoutSeconds)),
            maxBufferedBodyBytes: try c.decode(Int.self, forKey: .maxBufferedBodyBytes),
            maxSpooledBodyBytes: try c.decode(Int.self, forKey: .maxSpooledBodyBytes),
            inboundConnectionWarnThreshold: try c.decode(Int.self, forKey: .inboundConnectionWarnThreshold),
            inboundConnectionMaxLimit: try c.decode(Int.self, forKey: .inboundConnectionMaxLimit),
            strictMode: try c.decode(Bool.self, forKey: .strictMode)
        )
    }
}

private struct WireAuth: Decodable {
    let value: PrivateAuthSettings

    private enum Keys: String, CodingKey {
        case mode, username, domain, workstation, pendingHandshakeGlobalLimit, pendingHandshakesPerSource
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateAuthSettings(
            mode: try WireValue.enumValue(c.decode(String.self, forKey: .mode), PrivateAuthenticationMode.self),
            username: try c.decode(String.self, forKey: .username),
            domain: try c.decode(String.self, forKey: .domain),
            workstation: try c.decode(String.self, forKey: .workstation),
            pendingHandshakeGlobalLimit: try c.decode(Int.self, forKey: .pendingHandshakeGlobalLimit),
            pendingHandshakesPerSource: try c.decode(Int.self, forKey: .pendingHandshakesPerSource)
        )
    }
}

private struct WireUpstream: Decodable {
    let value: PrivateUpstreamSettings

    private enum Keys: String, CodingKey {
        case id, name, host, port, enabled, priority
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateUpstreamSettings(
            id: ControlUpstreamID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            name: try c.decode(String.self, forKey: .name),
            host: try c.decode(String.self, forKey: .host),
            port: try WireValue.port(c.decode(Int.self, forKey: .port)),
            enabled: try c.decode(Bool.self, forKey: .enabled),
            priority: try c.decode(Int.self, forKey: .priority)
        )
    }
}

private struct WireRouting: Decodable {
    let value: PrivateRoutingSettings

    private enum Keys: String, CodingKey {
        case pacURL, localPACEnabled, localPACPort, pacRoutingEnabled, pacUsableRouteLimit
        case noProxyHosts, forceProxyHosts
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateRoutingSettings(
            pacURL: try PrivateURLValue(c.decode(String.self, forKey: .pacURL)),
            localPACEnabled: try c.decode(Bool.self, forKey: .localPACEnabled),
            localPACPort: try WireValue.port(c.decode(Int.self, forKey: .localPACPort)),
            pacRoutingEnabled: try c.decode(Bool.self, forKey: .pacRoutingEnabled),
            pacUsableRouteLimit: try c.decode(Int.self, forKey: .pacUsableRouteLimit),
            noProxyHosts: try c.decode([String].self, forKey: .noProxyHosts),
            forceProxyHosts: try c.decode([String].self, forKey: .forceProxyHosts)
        )
    }
}

private struct WireDNS: Decodable {
    let value: PrivateDNSSettings

    private enum Keys: String, CodingKey {
        case forwarderEnabled, forwarderPort, dohProviders, entries, interceptRules
        case transparentProxyEnabled, transparentProxyIP, transparentProxyPort
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateDNSSettings(
            forwarderEnabled: try c.decode(Bool.self, forKey: .forwarderEnabled),
            forwarderPort: try WireValue.port(c.decode(Int.self, forKey: .forwarderPort)),
            dohProviders: try c.decode([String].self, forKey: .dohProviders).map { PrivateURLValue($0) },
            entries: try c.decode([WireDNSEntry].self, forKey: .entries).map(\.value),
            interceptRules: try c.decode([WireInterceptRule].self, forKey: .interceptRules).map(\.value),
            transparentProxyEnabled: try c.decode(Bool.self, forKey: .transparentProxyEnabled),
            transparentProxyIP: try c.decode(String.self, forKey: .transparentProxyIP),
            transparentProxyPort: try WireValue.port(c.decode(Int.self, forKey: .transparentProxyPort))
        )
    }
}

private struct WireDNSEntry: Decodable {
    let value: PrivateDNSEntrySettings

    private enum Keys: String, CodingKey {
        case id, domain, servers, enabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateDNSEntrySettings(
            id: PrivateDNSEntryID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            domain: try c.decode(String.self, forKey: .domain),
            servers: try c.decode([String].self, forKey: .servers),
            enabled: try c.decode(Bool.self, forKey: .enabled)
        )
    }
}

private struct WireInterceptRule: Decodable {
    let value: PrivateInterceptRuleSettings

    private enum Keys: String, CodingKey {
        case id, pattern, interceptIP, enabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateInterceptRuleSettings(
            id: PrivateInterceptRuleID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            pattern: try c.decode(String.self, forKey: .pattern),
            interceptIP: try c.decode(String.self, forKey: .interceptIP),
            enabled: try c.decode(Bool.self, forKey: .enabled)
        )
    }
}

private struct WireTunnels: Decodable {
    let value: PrivateTunnelSettings

    private enum Keys: String, CodingKey {
        case definitions, maxSessions, maxSessionsPerTunnel
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateTunnelSettings(
            definitions: try c.decode([WireTunnelDefinition].self, forKey: .definitions).map(\.value),
            maxSessions: try c.decode(Int.self, forKey: .maxSessions),
            maxSessionsPerTunnel: try c.decode(Int.self, forKey: .maxSessionsPerTunnel)
        )
    }
}

private struct WireTunnelDefinition: Decodable {
    let value: PrivateTunnelDefinitionSettings

    private enum Keys: String, CodingKey {
        case id, localPort, remoteHost, remotePort, enabled, proxied, label, preset
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        // `preset` is nullable, not optional: an absent key is refused, a null key is no preset.
        let presetRaw = try c.decode(String?.self, forKey: .preset)
        value = PrivateTunnelDefinitionSettings(
            id: ControlTunnelID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            localPort: try WireValue.port(c.decode(Int.self, forKey: .localPort)),
            remoteHost: try c.decode(String.self, forKey: .remoteHost),
            remotePort: try WireValue.port(c.decode(Int.self, forKey: .remotePort)),
            enabled: try c.decode(Bool.self, forKey: .enabled),
            proxied: try c.decode(Bool.self, forKey: .proxied),
            label: try c.decode(String.self, forKey: .label),
            preset: try presetRaw.map { try WireValue.enumValue($0, PrivateTunnelPreset.self) }
        )
    }
}

private struct WireHealth: Decodable {
    let value: PrivateHealthSettings

    private enum Keys: String, CodingKey {
        case checkURL, checkIntervalSeconds, connectionCheckTimeoutSeconds, upstreamResponseTimeoutSeconds
        case upstreamConnectTimeoutSeconds, directConnectTTLSeconds, circuitBreakerWindowSeconds
        case circuitFailureThreshold, circuitBaseOpenIntervalSeconds, circuitMaxOpenIntervalSeconds
        case vpnFlapGraceSeconds, vpnFlapMinVisibleSeconds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateHealthSettings(
            checkURL: try PrivateURLValue(c.decode(String.self, forKey: .checkURL)),
            checkIntervalSeconds: try WireValue.finite(c.decode(Double.self, forKey: .checkIntervalSeconds)),
            connectionCheckTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .connectionCheckTimeoutSeconds)),
            upstreamResponseTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .upstreamResponseTimeoutSeconds)),
            upstreamConnectTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .upstreamConnectTimeoutSeconds)),
            directConnectTTLSeconds: try WireValue.finite(c.decode(Double.self, forKey: .directConnectTTLSeconds)),
            circuitBreakerWindowSeconds: try WireValue.finite(c.decode(Double.self, forKey: .circuitBreakerWindowSeconds)),
            circuitFailureThreshold: try c.decode(Int.self, forKey: .circuitFailureThreshold),
            circuitBaseOpenIntervalSeconds: try WireValue.finite(c.decode(Double.self, forKey: .circuitBaseOpenIntervalSeconds)),
            circuitMaxOpenIntervalSeconds: try WireValue.finite(c.decode(Double.self, forKey: .circuitMaxOpenIntervalSeconds)),
            vpnFlapGraceSeconds: try WireValue.finite(c.decode(Double.self, forKey: .vpnFlapGraceSeconds)),
            vpnFlapMinVisibleSeconds: try WireValue.finite(c.decode(Double.self, forKey: .vpnFlapMinVisibleSeconds))
        )
    }
}

private struct WireLogging: Decodable {
    let value: PrivateLoggingSettings

    private enum Keys: String, CodingKey {
        case verbose, auditLogEnabled, auditLogMaxBytes, auditLogPath
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateLoggingSettings(
            verbose: try c.decode(Bool.self, forKey: .verbose),
            auditLogEnabled: try c.decode(Bool.self, forKey: .auditLogEnabled),
            auditLogMaxBytes: try c.decode(Int.self, forKey: .auditLogMaxBytes),
            auditLogPath: try c.decode(String?.self, forKey: .auditLogPath)
        )
    }
}

private struct WirePlatform: Decodable {
    let value: PrivatePlatformConfiguration

    private enum Keys: String, CodingKey {
        case manageSystemProxy, manageEnvironmentVariables, manageDNSResolvers, manageSystemDNS, systemProxyMode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivatePlatformConfiguration(
            manageSystemProxy: try c.decode(Bool.self, forKey: .manageSystemProxy),
            manageEnvironmentVariables: try c.decode(Bool.self, forKey: .manageEnvironmentVariables),
            manageDNSResolvers: try c.decode(Bool.self, forKey: .manageDNSResolvers),
            manageSystemDNS: try c.decode(Bool.self, forKey: .manageSystemDNS),
            systemProxyMode: try WireValue.enumValue(c.decode(String.self, forKey: .systemProxyMode), PrivateSystemProxyMode.self)
        )
    }
}
