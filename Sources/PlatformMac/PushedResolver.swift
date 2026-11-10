// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// A resolver a tunnel pushed, as the dynamic store holds it: one per service
/// DNS key. See `docs/design-live-vpn-split-dns.md`.
package struct PushedResolver: Hashable, Sendable {
    /// The `<id>` in `State:/Network/Service/<id>/DNS`; not always a UUID.
    package let serviceID: String
    /// The DNS dictionary's `SearchOrder`; nil when absent.
    package let searchOrder: Int?
    /// The tunnel interface, `utun` and digits.
    package let interface: String
    /// Never empty. Lowercased, no trailing dot, valid under `DomainNameSyntax`,
    /// each once.
    package let domains: [String]
    /// IP literals in the order the store lists them, each once. Never empty.
    package let servers: [String]
    /// `OverridePrimary` is 1 on the IPv4 dictionary: a full tunnel whose servers are the machine's
    /// default resolver. Only the parser's full-tunnel domain rule reads it
    /// (owner decisions 8 and 9).
    package let overridesPrimary: Bool

    package init(
        serviceID: String,
        searchOrder: Int? = nil,
        interface: String,
        domains: [String],
        servers: [String],
        overridesPrimary: Bool = false
    ) {
        assert(!domains.isEmpty && !servers.isEmpty, "a pushed resolver names at least one domain and one server")
        self.serviceID = serviceID
        self.searchOrder = searchOrder
        self.interface = interface
        self.domains = domains
        self.servers = servers
        self.overridesPrimary = overridesPrimary
    }
}

/// Why a value was left out of a reading or of the table. The monitor has no
/// event sink; the host reports these (`dns.split_resolver_ignored`).
package struct PushedResolverRejection: Hashable, Sendable {
    package enum Reason: String, Hashable, Sendable {
        case invalidDomain = "invalid_domain"
        /// A server that is not an IP literal, or, with no `value`, a key
        /// left with no server at all.
        case invalidServer = "invalid_server"
        /// `local` or an `arpa` zone: the system resolves these itself.
        case systemDomain = "system_domain"
        /// Neither the IPv4 nor the IPv6 dictionary names an interface.
        case notTunnel = "not_tunnel"
        /// The key claims no domain: no `SupplementalMatchDomains`, and no
        /// `OverridePrimary` that would make its search domains count, or
        /// every domain it named was invalid.
        case noMatchDomains = "no_match_domains"
        /// Past `SplitDNSLimits`; from `LiveSplitDNSPolicy`, not the parser.
        case overLimit = "over_limit"
    }

    package let serviceID: String
    /// Nil when the key named none.
    package let interface: String?
    /// The dropped domain or server; nil when the whole key was rejected.
    package let value: String?
    package let reason: Reason

    package init(serviceID: String, interface: String?, value: String? = nil, reason: Reason) {
        self.serviceID = serviceID
        self.interface = interface
        self.value = value
        self.reason = reason
    }
}

/// One whole reading of the store: the resolvers it admitted, what it
/// rejected, and whether the store could be read at all.
package struct PushedResolverReading: Hashable, Sendable {
    package enum Failure: String, Hashable, Sendable {
        case storeCreate = "store_create"
        case storeSubscribe = "store_subscribe"
        case storeRead = "store_read"
    }

    package var resolvers: [PushedResolver]
    package var rejections: [PushedResolverRejection]
    /// Set when the store could not be created, subscribed to or read; `resolvers` is then empty.
    package var failure: Failure?

    package init(resolvers: [PushedResolver] = [], rejections: [PushedResolverRejection] = [], failure: Failure? = nil) {
        self.resolvers = resolvers
        self.rejections = rejections
        self.failure = failure
    }
}

extension PushedResolverReading {
    /// Store keys the reading is built from, as `SCDynamicStore` patterns.
    /// The service ID is `[^/]+`, never UUID-only.
    package static let dnsKeyPattern = "State:/Network/Service/[^/]+/DNS"
    package static let ipv4KeyPattern = "State:/Network/Service/[^/]+/IPv4"
    package static let ipv6KeyPattern = "State:/Network/Service/[^/]+/IPv6"

    private static let servicePrefix = "State:/Network/Service/"

    /// Parses the store's `State:/Network/Service/<id>/DNS`, `/IPv4` and
    /// `/IPv6` dictionaries, keyed by store key as `SCDynamicStoreCopyMultiple`
    /// returns them. Other keys are ignored. The interface is the IPv4
    /// `InterfaceName`, else the IPv6 one; a service on a non-`utun` interface
    /// is not a pushed resolver and is skipped.
    ///
    /// Domains (owner decision 8): `SupplementalMatchDomains` when it has
    /// any; otherwise, for a full tunnel (`OverridePrimary` 1), `DomainName`
    /// then `SearchDomains`; otherwise the key is rejected as
    /// `no_match_domains`.
    package static func parse(store: [String: Any]) -> PushedResolverReading {
        var reading = PushedResolverReading()
        for serviceID in serviceIDs(in: store) {
            let dns = store[servicePrefix + serviceID + "/DNS"] as? [String: Any] ?? [:]
            let addressing = ["IPv4", "IPv6"].compactMap { store[servicePrefix + serviceID + "/" + $0] as? [String: Any] }
            guard let interface = addressing.lazy.compactMap({ $0["InterfaceName"] as? String }).first else {
                reading.rejections.append(.init(serviceID: serviceID, interface: nil, reason: .notTunnel))
                continue
            }
            guard isTunnelInterface(interface) else { continue }
            let ipv4 = store[servicePrefix + serviceID + "/IPv4"] as? [String: Any]
            let overridesPrimary = (ipv4?["OverridePrimary"] as? NSNumber)?.boolValue == true
            parseResolver(
                serviceID: serviceID, interface: interface, dns: dns, overridesPrimary: overridesPrimary, into: &reading
            )
        }
        return reading
    }

    package static func isTunnelInterface(_ name: String) -> Bool {
        let digits = name.dropFirst(4)
        return name.hasPrefix("utun") && !digits.isEmpty && digits.allSatisfy { $0.isASCII && $0.isNumber }
    }

    private static func serviceIDs(in store: [String: Any]) -> [String] {
        store.keys.compactMap { key in
            guard key.hasPrefix(servicePrefix), key.hasSuffix("/DNS") else { return nil }
            let id = key.dropFirst(servicePrefix.count).dropLast("/DNS".count)
            return id.isEmpty || id.contains("/") ? nil : String(id)
        }.sorted()
    }

    private static func parseResolver(
        serviceID: String,
        interface: String,
        dns: [String: Any],
        overridesPrimary: Bool,
        into reading: inout PushedResolverReading
    ) {
        func reject(_ reason: PushedResolverRejection.Reason, _ value: String? = nil) {
            reading.rejections.append(.init(serviceID: serviceID, interface: interface, value: value, reason: reason))
        }
        /// A list field as strings. An element of another type is rejected
        /// under `reason` with its description, never dropped silently.
        func strings(_ field: String, _ reason: PushedResolverRejection.Reason) -> [String] {
            switch dns[field] {
            case nil: return []
            case let single as String: return [single]
            case let list as [Any]:
                return list.compactMap { element in
                    if let text = element as? String { return text }
                    reject(reason, String(describing: element))
                    return nil
                }
            case let other?:
                reject(reason, String(describing: other))
                return []
            }
        }

        let match = strings("SupplementalMatchDomains", .invalidDomain)
        let rawDomains: [String]
        if !match.isEmpty {
            rawDomains = match
        } else if overridesPrimary {
            rawDomains = strings("DomainName", .invalidDomain) + strings("SearchDomains", .invalidDomain)
        } else {
            rawDomains = []
        }
        var domains: [String] = []
        for raw in rawDomains {
            var domain = raw.lowercased()
            while domain.hasSuffix(".") { domain.removeLast() }
            if isSystemDomain(domain) {
                reject(.systemDomain, domain)
            } else if !DomainNameSyntax.isValid(domain) {
                reject(.invalidDomain, raw)
            } else if !domains.contains(domain) {
                domains.append(domain)
            }
        }

        var servers: [String] = []
        for server in strings("ServerAddresses", .invalidServer) {
            if !IPAddressSyntax.isLiteral(server) {
                reject(.invalidServer, server)
            } else if !servers.contains(server) {
                servers.append(server)
            }
        }

        guard !domains.isEmpty else { return reject(.noMatchDomains) }
        guard !servers.isEmpty else { return reject(.invalidServer) }
        reading.resolvers.append(PushedResolver(
            serviceID: serviceID,
            searchOrder: (dns["SearchOrder"] as? NSNumber)?.intValue,
            interface: interface,
            domains: domains,
            servers: servers,
            overridesPrimary: overridesPrimary
        ))
    }

    private static func isSystemDomain(_ domain: String) -> Bool {
        ["local", "arpa"].contains { domain == $0 || domain.hasSuffix(".\($0)") }
    }
}
