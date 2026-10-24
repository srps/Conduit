// SPDX-License-Identifier: Apache-2.0
import Foundation

// The approved configuration resource ceilings (decisions 0021 and 0022). They are neutral values:
// the private codec, the bridge and the kernel's typed check read them from here, and none of them
// takes a kernel or control type. A ceiling counts stored values as they are: the entries of a list,
// or the raw UTF-8 bytes of a string, where an escape counts as the bytes it decodes to. Whitespace
// and disabled entries count. The stricter grammars (`DomainNameSyntax`, `IPAddressSyntax`,
// `ProxyBypassSyntax`) still apply on top of these.

/// What one ceiling counts.
package enum DomainResourceMeasure: Sendable, Equatable {
    /// The elements of one array.
    case entries
    /// The decoded UTF-8 bytes of one string.
    case utf8Bytes
    /// The JSON bytes of a list of strings, measured as `ProxyBypassSyntax` measures a bypass list.
    case encodedBytes
}

/// The approved ceilings. Each name is the value the decision records select.
package enum DomainResourceLimits {
    package static let upstreams = 32
    package static let tunnelDefinitions = 128
    package static let dnsEntries = 256
    package static let dnsServers = 8
    package static let interceptRules = 256
    package static let allowedClients = 256
    package static let forceProxyHosts = 256
    package static let noProxyHosts = ProxyBypassSyntax.maximumEntries
    package static let dohProviders = 8
    /// Display text: the profile name and the upstream and tunnel labels.
    package static let displayText = 1024
    /// Authentication identities: the username, domain and workstation.
    package static let identity = 1024
    package static let auditLogPath = 1023
    /// Host, domain and address values, the forced-proxy items, and the bypass items.
    package static let hostText = DomainNameSyntax.maxLength
    /// A wildcard intercept pattern. Its `*.` prefix is part of the value and counts.
    package static let wildcardInterceptPattern = 255
    /// URL-valued preferences: the PAC URL, the health check URL and each DoH provider.
    package static let urlText = 16_384
    /// Identifiers and enumeration tokens. This is a lexical guard of the token grammar, not a product ceiling:
    /// a valid identifier is a 36-byte UUID and every enumeration raw value is shorter, so no valid token exceeds
    /// it. The scanner refuses a longer token as malformed, never as a resource limit. `ConfigurationResourceCanonicalWidthTests`
    /// derives the 36-byte and enumeration widths from the decoder's own types.
    package static let token = 64
    package static let noProxyList = ProxyBypassSyntax.maximumJSONBytes
    /// The physical bytes of one runtime configuration file, read or refused (decision 0021). It is a file budget, not a
    /// field ceiling, and it is separate from the private frame cap even though both are 8 MiB today.
    package static let runtimeConfigurationFileBytes = 8_388_608
    /// The prefix a wildcard intercept pattern starts with, as UTF-8.
    package static let wildcardPrefix: [UInt8] = Array("*.".utf8)
}

/// Each approved ceiling, by the place its value sits. A case names a place, not a feature, so one
/// number can serve two places without their errors merging.
package enum DomainResourceField: CaseIterable, Sendable, Equatable {
    case upstreams, tunnelDefinitions, dnsEntries, dnsServers, interceptRules
    case allowedClients, forceProxyHosts, noProxyHosts, dohProviders
    case profileName, upstreamName, tunnelLabel
    case authUsername, authDomain, authWorkstation
    case auditLogPath
    case proxyHost, upstreamHost, tunnelRemoteHost, dnsDomain, dnsServer, interceptAddress
    case transparentProxyIP, allowedClient, forceProxyPattern, noProxyPattern, interceptPattern
    case pacURL, checkURL, dohProvider
    case token
    case noProxyList

    /// The ceiling for this field: entries for a list, UTF-8 bytes for a string. A wildcard intercept
    /// pattern has a larger ceiling, see `utf8Limit(wildcardPrefix:)`.
    package var limit: Int {
        switch self {
        case .upstreams: DomainResourceLimits.upstreams
        case .tunnelDefinitions: DomainResourceLimits.tunnelDefinitions
        case .dnsEntries: DomainResourceLimits.dnsEntries
        case .dnsServers: DomainResourceLimits.dnsServers
        case .interceptRules: DomainResourceLimits.interceptRules
        case .allowedClients: DomainResourceLimits.allowedClients
        case .forceProxyHosts: DomainResourceLimits.forceProxyHosts
        case .noProxyHosts: DomainResourceLimits.noProxyHosts
        case .dohProviders: DomainResourceLimits.dohProviders
        case .profileName, .upstreamName, .tunnelLabel: DomainResourceLimits.displayText
        case .authUsername, .authDomain, .authWorkstation: DomainResourceLimits.identity
        case .auditLogPath: DomainResourceLimits.auditLogPath
        case .proxyHost, .upstreamHost, .tunnelRemoteHost, .dnsDomain, .dnsServer, .interceptAddress,
             .transparentProxyIP, .allowedClient, .forceProxyPattern, .noProxyPattern, .interceptPattern:
            DomainResourceLimits.hostText
        case .pacURL, .checkURL, .dohProvider: DomainResourceLimits.urlText
        case .token: DomainResourceLimits.token
        case .noProxyList: DomainResourceLimits.noProxyList
        }
    }

    package var measure: DomainResourceMeasure {
        switch self {
        case .upstreams, .tunnelDefinitions, .dnsEntries, .dnsServers, .interceptRules, .allowedClients,
             .forceProxyHosts, .noProxyHosts, .dohProviders:
            .entries
        case .profileName, .upstreamName, .tunnelLabel, .authUsername, .authDomain, .authWorkstation,
             .auditLogPath, .proxyHost, .upstreamHost, .tunnelRemoteHost, .dnsDomain, .dnsServer,
             .interceptAddress, .transparentProxyIP, .allowedClient, .forceProxyPattern, .noProxyPattern,
             .interceptPattern, .pacURL, .checkURL, .dohProvider, .token:
            .utf8Bytes
        case .noProxyList:
            .encodedBytes
        }
    }

    /// The UTF-8 ceiling for one value. Only a wildcard intercept pattern depends on its value.
    package func utf8Limit(wildcardPrefix: Bool) -> Int {
        self == .interceptPattern && wildcardPrefix ? DomainResourceLimits.wildcardInterceptPattern : limit
    }

    /// The field whose ceiling bounds this list's canonical JSON width, when it has one. The list's own count and
    /// item ceilings still apply, and each item is charged once it closes (see `DomainResourceCheck.strings`).
    package var encodedListField: DomainResourceField? {
        self == .noProxyHosts ? DomainResourceField.noProxyList : nil
    }
}

/// The first approved ceiling a value crossed. It names the field and the ceiling and never the value,
/// so it can travel in an error without echoing configuration.
package struct DomainResourceViolation: Error, Sendable, Equatable, CustomStringConvertible {
    package let field: DomainResourceField
    package let limit: Int

    package init(_ field: DomainResourceField, _ limit: Int) {
        self.field = field
        self.limit = limit
    }

    package var description: String {
        "configuration resource limit exceeded: \(field), limit \(limit)"
    }
}

/// The shared checks. Each returns the violation, or nil. A list is refused by its count before any
/// item is read, so an oversize list costs no more than its ceiling.
package enum DomainResourceCheck {
    package static func entries(_ count: Int, _ field: DomainResourceField) -> DomainResourceViolation? {
        count <= field.limit ? nil : DomainResourceViolation(field, field.limit)
    }

    /// A UTF-8 length. `wildcardPrefix` says whether the value starts with `*.`.
    package static func utf8(
        _ count: Int,
        wildcardPrefix: Bool = false,
        _ field: DomainResourceField
    ) -> DomainResourceViolation? {
        let limit = field.utf8Limit(wildcardPrefix: wildcardPrefix)
        return count <= limit ? nil : DomainResourceViolation(field, limit)
    }

    package static func text(_ value: String, _ field: DomainResourceField) -> DomainResourceViolation? {
        utf8(value.utf8.count, wildcardPrefix: value.utf8.starts(with: DomainResourceLimits.wildcardPrefix), field)
    }

    /// A list: its count, then each item in order.
    package static func items<Item>(
        _ values: [Item],
        count field: DomainResourceField,
        each check: (Item) -> DomainResourceViolation?
    ) -> DomainResourceViolation? {
        if let violation = entries(values.count, field) {
            return violation
        }
        for value in values {
            if let violation = check(value) {
                return violation
            }
        }
        return nil
    }

    /// A list of strings, in order: its count, then each item's own ceiling, then the list's canonical JSON width
    /// once each item closes. The scanner charges the same way while it reads, so both report the same first
    /// ceiling. The width is counted without a buffer, so the list is never encoded.
    package static func strings(
        _ values: [String],
        count: DomainResourceField,
        item: DomainResourceField,
        encodedWithin list: DomainResourceField
    ) -> DomainResourceViolation? {
        if let violation = entries(values.count, count) {
            return violation
        }
        var array = CanonicalJSONStringList()
        for value in values {
            if let violation = text(value, item) {
                return violation
            }
            array.append(quotedWidth: CanonicalJSONWidth.quotedWidth(value))
            if let violation = encodedBytes(array.bytes, list) {
                return violation
            }
        }
        return nil
    }

    /// A canonical JSON width against its list ceiling. The scanner and `strings` charge the running width through
    /// this one check.
    package static func encodedBytes(_ bytes: Int, _ field: DomainResourceField) -> DomainResourceViolation? {
        bytes <= field.limit ? nil : DomainResourceViolation(field, field.limit)
    }
}

/// The bytes `JSONEncoder` writes for strings under its default output policy, counted instead of written. The
/// private scanner and the typed checks share this counter, so none allocates a JSON buffer. Its policy is pinned
/// by `ConfigurationResourceCanonicalWidthTests` against `JSONEncoder` for every Unicode scalar value. It is not the private wire
/// spelling, which may escape a value or write it raw: both spellings have the same canonical width.
package enum CanonicalJSONWidth {
    /// The bytes one scalar value takes inside a JSON string, quotes excluded.
    package static func scalarWidth(_ value: UInt32) -> Int {
        switch value {
        case 0x22, 0x2F, 0x5C, 0x08, 0x09, 0x0A, 0x0C, 0x0D:
            2 // `\"`, `\/` (the default escapes the solidus), `\\`, and the short escapes
        case 0..<0x20:
            6 // `\u00XX`
        case 0x20..<0x80:
            1
        case 0x80..<0x800:
            2
        case 0x800..<0x10000:
            3
        default:
            4
        }
    }

    /// A string with its two quotes.
    package static func quotedWidth(_ text: String) -> Int {
        var width = 2
        for scalar in text.unicodeScalars {
            width += scalarWidth(scalar.value)
        }
        return width
    }
}

/// A JSON array of strings, measured one item at a time. The brackets and the commas are counted with the items,
/// so `bytes` is the array's canonical width at every point. An empty array is `[]`.
package struct CanonicalJSONStringList: Sendable {
    package private(set) var bytes = 2
    private var items = 0

    /// Adds one item by its quoted width, with a comma before it unless it is the first.
    package mutating func append(quotedWidth: Int) {
        bytes += (items == 0 ? 0 : 1) + quotedWidth
        items += 1
    }
}
