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

/// A bounded structural check over the body. It keeps no copy of the text, and it captures only
/// the unescaped bytes of object keys, for the duplicate check. Those captured keys, and the
/// `String` built for each escape inside them, are ordinary Swift copies. They are not zeroed when
/// released, and a malformed key can hold token-like text (0018 §2–3).
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
        try scanner.scanValue(depth: 0)
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

    private mutating func scanValue(depth: Int) throws {
        guard let byte = current else {
            throw PrivateConfigurationWireError.malformedBody
        }
        switch byte {
        case UInt8(ascii: "{"):
            try scanObject(depth: depth)
        case UInt8(ascii: "["):
            try scanArray(depth: depth)
        case UInt8(ascii: "\""):
            _ = try scanString(captured: false)
        case UInt8(ascii: "t"):
            try scanLiteral("true")
        case UInt8(ascii: "f"):
            try scanLiteral("false")
        case UInt8(ascii: "n"):
            try scanLiteral("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
            try scanNumber()
        default:
            throw PrivateConfigurationWireError.malformedBody
        }
    }

    private mutating func scanObject(depth: Int) throws {
        guard depth < Self.maxDepth else {
            throw PrivateConfigurationWireError.malformedBody
        }
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "}") {
            index += 1
            return
        }
        // Each key is copied into an unscrubbed array, because the duplicate check needs its bytes.
        // The copies are not `PrivateFrameBuffer` allocations, so they are not zeroed (0018 §2–3).
        var keys = Set<[UInt8]>()
        while true {
            skipWhitespace()
            guard current == UInt8(ascii: "\"") else {
                throw PrivateConfigurationWireError.malformedBody
            }
            let key = try scanString(captured: true)
            // A repeated key, even one spelled with escapes, makes the object ambiguous. Refuse it.
            guard keys.insert(key).inserted else {
                throw PrivateConfigurationWireError.malformedBody
            }
            skipWhitespace()
            try expect(UInt8(ascii: ":"))
            skipWhitespace()
            try scanValue(depth: depth + 1)
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

    private mutating func scanArray(depth: Int) throws {
        guard depth < Self.maxDepth else {
            throw PrivateConfigurationWireError.malformedBody
        }
        index += 1
        skipWhitespace()
        if current == UInt8(ascii: "]") {
            index += 1
            return
        }
        while true {
            skipWhitespace()
            try scanValue(depth: depth + 1)
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

    /// Scans one string. With `captured`, returns its unescaped UTF-8 bytes. Without it, returns
    /// nothing, so a value string leaves no copy behind.
    private mutating func scanString(captured: Bool) throws -> [UInt8] {
        try expect(UInt8(ascii: "\""))
        var out: [UInt8] = []
        while true {
            guard let byte = current else {
                throw PrivateConfigurationWireError.malformedBody
            }
            if byte == UInt8(ascii: "\"") {
                index += 1
                return out
            }
            if byte < 0x20 {
                throw PrivateConfigurationWireError.malformedBody
            }
            if byte == UInt8(ascii: "\\") {
                index += 1
                let scalar = try scanEscape()
                if captured {
                    out.append(contentsOf: String(Character(scalar)).utf8)
                }
                continue
            }
            if byte < 0x80 {
                if captured {
                    out.append(byte)
                }
                index += 1
                continue
            }
            let length = try utf8SequenceLength()
            if captured {
                out.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[index..<(index + length)]))
            }
            index += length
        }
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
