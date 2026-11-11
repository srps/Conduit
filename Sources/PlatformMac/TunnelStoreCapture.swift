// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import CryptoKit
import Foundation
import ProxyKernel

/// A store value after masking: only what JSON can carry.
package indirect enum MaskedStoreValue: Equatable, Encodable, Sendable {
    case string(String)
    case integer(Int64)
    case number(Double)
    case bool(Bool)
    case array([MaskedStoreValue])
    case dictionary([String: MaskedStoreValue])

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        }
    }

    /// The value as `SCDynamicStoreCopyMultiple` would hold it, so a masked
    /// capture parses like the store it came from.
    package var storeValue: Any {
        switch self {
        case .string(let value): value
        case .integer(let value): NSNumber(value: value)
        case .number(let value): NSNumber(value: value)
        case .bool(let value): NSNumber(value: value)
        case .array(let value): value.map(\.storeValue)
        case .dictionary(let value): value.mapValues(\.storeValue)
        }
    }
}

/// Replaces what identifies a machine or a network in the tunnel store keys,
/// and keeps what detection reads: which keys exist, which fields they have,
/// how many addresses, and whether an IPv6 address is link-local.
///
/// One mask gives the same placeholder to the same address every time, so a
/// stream of captures shows an address staying or changing.
///
/// - An IPv4 address becomes an RFC 5737 documentation address.
/// - An IPv6 address becomes `fe80::N` if it is link-local and `2001:db8::N`
///   otherwise. Loopback, unspecified and multicast addresses are kept.
/// - A service ID becomes `service-` and eight hex digits of its SHA-256,
///   unless it is in `knownServiceIDs`.
/// - Numbers, booleans, subnet masks and interface names are kept.
/// - Every other string, and every value of another type, becomes
///   `maskedPlaceholder`. Field names are kept.
package struct TunnelStoreMask {
    /// Vendor service IDs that are the same on every machine.
    package static let knownServiceIDs: Set<String> = ["com.cisco.anyconnect"]
    package static let maskedPlaceholder = "<masked>"

    /// The three RFC 5737 blocks, 254 hosts each. An address past that many
    /// distinct ones becomes `maskedPlaceholder` and is not remembered.
    private static let ipv4Blocks = ["192.0.2.", "198.51.100.", "203.0.113."]
    private static let ipv4Capacity = ipv4Blocks.count * 254
    /// One hextet of host numbers under each IPv6 prefix.
    private static let ipv6Capacity = 0xffff

    private static let interfacePrefix = "State:/Network/Interface/"
    private static let servicePrefix = "State:/Network/Service/"
    private static let verbatimAddressFields: Set<String> = ["SubnetMasks", "SubnetMask"]
    private static let interfaceNameFields: Set<String> = ["InterfaceName", "ConfirmedInterfaceName"]

    private var ipv4: [String: String] = [:]
    private var linkLocalIPv6: [String: String] = [:]
    private var routableIPv6: [String: String] = [:]

    package init() {}

    /// The masked keys, and how many keys were left out because they are not
    /// a tunnel interface key or a service key.
    package mutating func mask(keys: [String: Any]) -> (keys: [String: MaskedStoreValue], unrecognized: Int) {
        var masked: [String: MaskedStoreValue] = [:]
        var unrecognized = 0
        for key in keys.keys.sorted() {
            guard let maskedKey = Self.mask(key: key) else {
                unrecognized += 1
                continue
            }
            masked[maskedKey] = mask(keys[key] as Any, field: nil)
        }
        return (masked, unrecognized)
    }

    package static func mask(serviceID: String) -> String {
        if knownServiceIDs.contains(serviceID) { return serviceID }
        let digest = SHA256.hash(data: Data(serviceID.utf8))
        return "service-" + digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func mask(key: String) -> String? {
        guard let family = ["/IPv4", "/IPv6"].first(where: key.hasSuffix) else { return nil }
        if key.hasPrefix(interfacePrefix) {
            let interface = String(key.dropFirst(interfacePrefix.count).dropLast(family.count))
            return PushedResolverReading.isTunnelInterface(interface) ? key : nil
        }
        if key.hasPrefix(servicePrefix) {
            let serviceID = String(key.dropFirst(servicePrefix.count).dropLast(family.count))
            guard !serviceID.isEmpty, !serviceID.contains("/") else { return nil }
            return servicePrefix + mask(serviceID: serviceID) + family
        }
        return nil
    }

    private mutating func mask(_ value: Any, field: String?) -> MaskedStoreValue {
        switch value {
        case let text as String:
            return .string(mask(text: text, field: field))
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            return CFNumberIsFloatType(number) ? .number(number.doubleValue) : .integer(number.int64Value)
        case let list as [Any]:
            return .array(list.map { mask($0, field: field) })
        case let dictionary as [String: Any]:
            var masked: [String: MaskedStoreValue] = [:]
            for name in dictionary.keys.sorted() {
                // A field named by an address would leak it as a name.
                let maskedName = address(name) ?? name
                masked[maskedName] = mask(dictionary[name] as Any, field: name)
            }
            return .dictionary(masked)
        default:
            return .string(Self.maskedPlaceholder)
        }
    }

    private mutating func mask(text: String, field: String?) -> String {
        if let field, Self.interfaceNameFields.contains(field) {
            return Self.isInterfaceName(text) ? text : Self.maskedPlaceholder
        }
        if let field, Self.verbatimAddressFields.contains(field), IPAddressSyntax.isIPv4(text) {
            return text
        }
        return address(text) ?? Self.maskedPlaceholder
    }

    /// The placeholder for an IP literal; nil when `text` is not one.
    private mutating func address(_ text: String) -> String? {
        if IPAddressSyntax.isIPv4(text) {
            return Self.placeholder(for: text, in: &ipv4, capacity: Self.ipv4Capacity) { index in
                Self.ipv4Blocks[index / 254] + String(index % 254 + 1)
            }
        }
        guard let kind = TunnelSnapshot.ipv6Kind(text) else { return nil }
        switch kind {
        case .linkLocal:
            return Self.placeholder(for: text, in: &linkLocalIPv6, capacity: Self.ipv6Capacity) {
                "fe80::" + String($0 + 1, radix: 16)
            }
        case .routable:
            return Self.placeholder(for: text, in: &routableIPv6, capacity: Self.ipv6Capacity) {
                "2001:db8::" + String($0 + 1, radix: 16)
            }
        case .other:
            return text
        }
    }

    private static func placeholder(
        for text: String, in table: inout [String: String], capacity: Int, _ make: (Int) -> String
    ) -> String {
        if let known = table[text] { return known }
        guard table.count < capacity else { return maskedPlaceholder }
        let made = make(table.count)
        table[text] = made
        return made
    }

    /// Lowercase letters then digits, as `en0`, `utun6` or `bridge100`.
    private static func isInterfaceName(_ text: String) -> Bool {
        let letters = text.prefix { $0.isASCII && $0.isLowercase }
        let digits = text.dropFirst(letters.count)
        return !letters.isEmpty && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }
}

/// One line of a capture: the masked tunnel keys at one instant and the
/// snapshot they parse to, or the failure that left nothing to show.
package struct TunnelStoreCapture: Encodable, Equatable {
    package struct Tunnel: Encodable, Equatable {
        package let interface: String
        package let hasInterfaceKey: Bool
        package let ipv4Addresses: [String]
        package let hasRoutableIPv6: Bool
        package let serviceID: String?
        package let overridesPrimary: Bool
    }

    /// Wall-clock time of the reading.
    package let at: Date
    /// Seconds since the capture began, on a clock that stops while the
    /// machine sleeps.
    package let elapsed: TimeInterval
    package let keys: [String: MaskedStoreValue]?
    package let tunnels: [Tunnel]?
    /// Whether `VPNUpPredicate.anyIPv4Tunnel` holds for `tunnels`.
    package let up: Bool?
    package let unrecognizedKeys: Int?
    package let failure: String?

    package init(
        reading: Result<[String: Any], TunnelReading.Failure>,
        at: Date,
        elapsed: TimeInterval,
        mask: inout TunnelStoreMask
    ) {
        self.at = at
        self.elapsed = elapsed
        switch reading {
        case .failure(let failure):
            keys = nil
            tunnels = nil
            up = nil
            unrecognizedKeys = nil
            self.failure = failure.step.rawValue
        case .success(let raw):
            let masked = mask.mask(keys: raw)
            // Parsed from the masked keys, so the line is consistent with
            // itself and holds nothing the mask did not pass.
            let snapshot = TunnelSnapshot.parse(store: masked.keys.mapValues(\.storeValue))
            keys = masked.keys
            tunnels = snapshot.tunnels.map {
                Tunnel(
                    interface: $0.interface, hasInterfaceKey: $0.hasInterfaceKey, ipv4Addresses: $0.ipv4Addresses,
                    hasRoutableIPv6: $0.hasRoutableIPv6, serviceID: $0.serviceID, overridesPrimary: $0.overridesPrimary
                )
            }
            up = VPNUpPredicate.anyIPv4Tunnel.holds(for: snapshot)
            unrecognizedKeys = masked.unrecognized
            failure = nil
        }
    }

    /// One line of JSON with sorted keys and Unix-epoch timestamps.
    package func line() throws -> String {
        String(decoding: try CanonicalJSON.encoder().encode(self), as: UTF8.self)
    }
}
