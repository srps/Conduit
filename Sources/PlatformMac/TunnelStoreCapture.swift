// SPDX-License-Identifier: Apache-2.0
import ConduitShared
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
    /// A value that is neither a string nor a number, written as JSON
    /// `null`. Read back it is neither, as the value it stands for was.
    case opaque

    package func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .integer(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .opaque: try container.encodeNil()
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
        case .opaque: NSNull()
        }
    }
}

/// Builds a public copy of the tunnel store keys from an allowlist. Nothing
/// is passed through because it looks harmless: a key, a field name or a
/// value reaches the output only if a rule here names it, and everything else
/// is a placeholder.
///
/// What detection reads survives with its type, so a masked capture parses
/// to the same detection as the store it came from: which tunnel keys exist,
/// the shape of each `Addresses` list, each `InterfaceName`, and each
/// `OverridePrimary`. No other value is kept.
///
/// One mask gives the same placeholder to the same input every time, so a
/// stream of captures shows an address or a service staying or changing.
///
/// - A `utun` interface key is kept. A service key is kept, under a
///   placeholder ID, if its `InterfaceName` is a `utun` or its ID is in
///   `knownServiceIDs`. Every other key is left out and counted: Wi-Fi and
///   Ethernet services never reach the output.
/// - A service ID becomes `service-N`, numbered in the order this mask met
///   them, unless it is in `knownServiceIDs`. The number says nothing about
///   the ID, so an ID cannot be confirmed by guessing it.
/// - In `Addresses`, an IPv4 literal becomes an RFC 5737 documentation
///   address. An IPv6 literal becomes `fe80::N` if it is link-local,
///   `2001:db8::N` if it is any other unicast address, and `ff00::N` if it is
///   multicast, loopback or unspecified. A zone index goes with the rest. Any
///   other string becomes `maskedPlaceholder`, and anything that is not a
///   string becomes `.opaque`, so a list that was not all strings still is
///   not.
/// - A `utun` `InterfaceName` is kept, any other string becomes
///   `maskedPlaceholder`, and a value that is not a string `.opaque`.
/// - An `OverridePrimary` number or boolean is kept, and any other value
///   becomes `.opaque`.
/// - Any other field named in `schema` keeps its name, and its value
///   becomes `maskedPlaceholder` whatever its structure. A field outside
///   `schema` becomes `<unknown-N>` with that value.
package struct TunnelStoreMask {
    /// Vendor service IDs that are the same on every machine.
    package static let knownServiceIDs: Set<String> = ["com.cisco.anyconnect"]
    package static let maskedPlaceholder = "<masked>"

    /// What a known field may hold.
    private enum Field {
        /// `Addresses`: IP literals, each replaced by a placeholder of its kind.
        case addresses
        /// `InterfaceName`: a `utun` name, kept.
        case interfaceName
        /// `OverridePrimary`: a number or boolean, kept.
        case flag
        /// Detection never reads it. The name is kept and the value never is.
        case opaque
    }

    /// The fields of `State:/Network/Interface/<utun>/IPv4|IPv6` and
    /// `State:/Network/Service/<id>/IPv4|IPv6`.
    private static let schema: [String: Field] = [
        "Addresses": .addresses,
        "InterfaceName": .interfaceName,
        "OverridePrimary": .flag,
        "DestAddresses": .opaque,
        "BroadcastAddresses": .opaque,
        "Router": .opaque,
        "ServerAddress": .opaque,
        "SubnetMasks": .opaque,
        "SubnetMask": .opaque,
        "ConfirmedInterfaceName": .opaque,
        "Flags": .opaque,
        "PrefixLength": .opaque,
        "AdditionalRoutes": .opaque,
        "ExcludedRoutes": .opaque,
        "IncludedRoutes": .opaque,
        "ARPResolvedHardwareAddress": .opaque,
        "ARPResolvedIPAddress": .opaque,
        "ConfigMethod": .opaque,
        "NetworkSignature": .opaque,
    ]

    /// The three RFC 5737 blocks, 254 hosts each. Every address past that
    /// many distinct ones shares `ipv4Overflow` and is not remembered.
    private static let ipv4Blocks = ["192.0.2.", "198.51.100.", "203.0.113."]
    private static let ipv4Capacity = ipv4Blocks.count * 254
    private static let ipv4Overflow = "192.0.2.255"
    /// One hextet of host numbers under each IPv6 prefix. Every address past
    /// that many of a kind shares `<prefix>1:0`, which is still of that kind.
    private static let ipv6Capacity = 0xffff
    /// Distinct service IDs one mask numbers. A service past that many is
    /// left out and counted.
    private static let serviceCapacity = 256

    private static let interfacePrefix = "State:/Network/Interface/"
    private static let servicePrefix = "State:/Network/Service/"

    private var ipv4: [String: String] = [:]
    private var ipv6: [TunnelSnapshot.IPv6Kind: [String: String]] = [:]
    private var services: [String: String] = [:]

    package init() {}

    /// The masked keys, and how many keys were left out.
    package mutating func mask(keys: [String: Any]) -> (keys: [String: MaskedStoreValue], omitted: Int) {
        var masked: [String: MaskedStoreValue] = [:]
        for key in keys.keys.sorted() {
            guard let fields = keys[key] as? [String: Any], let maskedKey = mask(key: key, fields: fields) else {
                continue
            }
            masked[maskedKey] = mask(fields: fields)
        }
        return (masked, keys.count - masked.count)
    }

    /// The placeholder for a service ID; nil once this mask has numbered
    /// `serviceCapacity` of them.
    package mutating func mask(serviceID: String) -> String? {
        if Self.knownServiceIDs.contains(serviceID) { return serviceID }
        if let known = services[serviceID] { return known }
        guard services.count < Self.serviceCapacity else { return nil }
        let made = "service-\(services.count + 1)"
        services[serviceID] = made
        return made
    }

    /// The key to publish `fields` under; nil for a key that is left out.
    private mutating func mask(key: String, fields: [String: Any]) -> String? {
        guard let family = ["/IPv4", "/IPv6"].first(where: key.hasSuffix) else { return nil }
        if key.hasPrefix(Self.interfacePrefix) {
            let interface = String(key.dropFirst(Self.interfacePrefix.count).dropLast(family.count))
            return PushedResolverReading.isTunnelInterface(interface) ? key : nil
        }
        guard key.hasPrefix(Self.servicePrefix) else { return nil }
        let serviceID = String(key.dropFirst(Self.servicePrefix.count).dropLast(family.count))
        guard !serviceID.isEmpty, !serviceID.contains("/") else { return nil }
        let namesTunnel = (fields["InterfaceName"] as? String).map(PushedResolverReading.isTunnelInterface) ?? false
        guard namesTunnel || Self.knownServiceIDs.contains(serviceID) else { return nil }
        return mask(serviceID: serviceID).map { Self.servicePrefix + $0 + family }
    }

    private mutating func mask(fields: [String: Any]) -> MaskedStoreValue {
        var masked: [String: MaskedStoreValue] = [:]
        var unknown = 0
        for name in fields.keys.sorted() {
            if let field = Self.schema[name] {
                masked[name] = mask(fields[name] as Any, as: field)
            } else {
                unknown += 1
                masked["<unknown-\(unknown)>"] = .string(Self.maskedPlaceholder)
            }
        }
        return .dictionary(masked)
    }

    private mutating func mask(_ value: Any, as field: Field) -> MaskedStoreValue {
        switch field {
        case .addresses:
            guard let list = value as? [Any] else { return mask(address: value) }
            return .array(list.map { mask(address: $0) })
        case .interfaceName:
            guard let text = value as? String else { return .opaque }
            return .string(PushedResolverReading.isTunnelInterface(text) ? text : Self.maskedPlaceholder)
        case .flag:
            guard let number = value as? NSNumber else { return .opaque }
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return .bool(number.boolValue) }
            if !CFNumberIsFloatType(number) { return .integer(number.int64Value) }
            // JSON has no infinity or NaN, and detection reads only the truth.
            return number.doubleValue.isFinite ? .number(number.doubleValue) : .bool(number.boolValue)
        case .opaque:
            return .string(Self.maskedPlaceholder)
        }
    }

    private mutating func mask(address value: Any) -> MaskedStoreValue {
        guard let text = value as? String else { return .opaque }
        return .string(address(text) ?? Self.maskedPlaceholder)
    }

    /// The placeholder for an IP literal; nil when `text` is not one.
    private mutating func address(_ text: String) -> String? {
        if IPAddressSyntax.isIPv4(text) {
            return Self.placeholder(for: text, in: &ipv4, capacity: Self.ipv4Capacity, overflow: Self.ipv4Overflow) {
                Self.ipv4Blocks[$0 / 254] + String($0 % 254 + 1)
            }
        }
        guard let kind = TunnelSnapshot.ipv6Kind(text) else { return nil }
        // `ff00::/16` is reserved multicast: it parses as neither link-local
        // nor routable, as the address it stands for did.
        let prefix = switch kind {
        case .linkLocal: "fe80::"
        case .routable: "2001:db8::"
        case .other: "ff00::"
        }
        return Self.placeholder(
            for: text, in: &ipv6[kind, default: [:]], capacity: Self.ipv6Capacity, overflow: prefix + "1:0"
        ) { prefix + String($0 + 1, radix: 16) }
    }

    private static func placeholder(
        for text: String, in table: inout [String: String], capacity: Int, overflow: String, _ make: (Int) -> String
    ) -> String {
        if let known = table[text] { return known }
        guard table.count < capacity else { return overflow }
        let made = make(table.count)
        table[text] = made
        return made
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

    /// Seconds since the capture began on a monotonic clock that keeps
    /// counting while the machine sleeps, as `ContinuousClock` does. No line
    /// holds a date or a time of day.
    package let offset: TimeInterval
    /// Seconds since the capture began on a clock that stops while the
    /// machine sleeps, as `systemUptime` does.
    package let elapsed: TimeInterval
    package let keys: [String: MaskedStoreValue]?
    package let tunnels: [Tunnel]?
    /// Whether `VPNUpPredicate.anyIPv4Tunnel` holds for `tunnels`.
    package let up: Bool?
    /// Keys read and left out: anything that is not a tunnel's.
    package let omittedKeys: Int?
    package let failure: String?
    /// The store's `SCError()` for `failure`.
    package let failureCode: Int32?

    package init(
        reading: Result<[String: Any], TunnelReading.Failure>,
        offset: TimeInterval,
        elapsed: TimeInterval,
        mask: inout TunnelStoreMask
    ) {
        self.offset = Self.milliseconds(offset)
        self.elapsed = Self.milliseconds(elapsed)
        switch reading {
        case .failure(let failure):
            keys = nil
            tunnels = nil
            up = nil
            omittedKeys = nil
            self.failure = failure.step.rawValue
            failureCode = failure.code
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
            omittedKeys = masked.omitted
            failure = nil
            failureCode = nil
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> TimeInterval {
        (seconds * 1000).rounded() / 1000
    }

    /// One line of JSON with sorted keys.
    package func line() throws -> String {
        String(decoding: try CanonicalJSON.encoder().encode(self), as: UTF8.self)
    }
}
