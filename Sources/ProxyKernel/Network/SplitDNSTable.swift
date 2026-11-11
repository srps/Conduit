// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// Where a rule's server came from. The forwarder does not branch on it;
/// events and the UI do.
package enum SplitDNSOrigin: Hashable, Sendable {
    /// An enabled `DomainDNSEntry`.
    case manual
    /// Pushed by the tunnel on this interface.
    case detected(interface: String)
}

/// One split-DNS domain and the servers asked for names at or under it, in
/// the order they are tried.
package struct SplitDNSRule: Hashable, Sendable {
    /// Lowercased, no trailing dot.
    package let domain: String
    /// IP literals in the order they are asked. Empty when the entry names
    /// none: its names are still split-DNS names, with no server to ask.
    package let servers: [String]
    /// One per server, parallel to `servers`; `[.manual]` for a manual entry
    /// that names no server.
    package let origins: [SplitDNSOrigin]

    package init(domain: String, servers: [String], origins: [SplitDNSOrigin]) {
        assert(servers.isEmpty ? origins == [.manual] : origins.count == servers.count)
        self.domain = domain
        self.servers = servers
        self.origins = origins
    }
}

/// What the forwarder consults for a name: built whole from the enabled
/// `dnsEntries` and the rules a tunnel pushed, one rule per domain, never
/// mutated in place. See `docs/design-live-vpn-split-dns.md`.
package struct SplitDNSTable: Hashable, Sendable {
    package static let empty = SplitDNSTable(rules: [])

    package let rules: [SplitDNSRule]

    package init(rules: [SplitDNSRule]) {
        self.rules = rules
    }

    /// The one merge of manual and detected split DNS.
    ///
    /// The enabled `manual` entries come first, merged per lowercased domain
    /// in configuration order, each server once; then the domains only
    /// `detected` names, in `detected` order. Rule order decides
    /// `firstServers`, so configuration keeps the first server it gives. A
    /// domain in both asks its detected servers first, then the manual ones
    /// not already listed, and a server both name counts as detected. Detected
    /// rules arrive capped at `DomainResourceLimits.dnsServers` servers
    /// (`LiveSplitDNSPolicy` cuts them); manual servers are appended uncounted.
    /// With `detected` empty, every origin is `.manual`.
    package init(manual: [DomainDNSEntry], detected: [SplitDNSRule]) {
        var order: [String] = []
        var servers: [String: [String]] = [:]
        for (domain, entry) in Self.enabled(manual) {
            if servers[domain] == nil { order.append(domain) }
            var list = servers[domain] ?? []
            for server in entry.servers where !list.contains(server) {
                list.append(server)
            }
            servers[domain] = list
        }
        var detectedOrder: [String] = []
        var detectedByDomain: [String: SplitDNSRule] = [:]
        for rule in detected where detectedByDomain[rule.domain] == nil {
            assert(rule.servers.count <= DomainResourceLimits.dnsServers, "detected rules arrive capped")
            detectedOrder.append(rule.domain)
            detectedByDomain[rule.domain] = rule
        }
        let manualRules = order.map { domain -> SplitDNSRule in
            let list = servers[domain] ?? []
            guard let pushed = detectedByDomain[domain] else {
                return SplitDNSRule(domain: domain, servers: list, origins: Array(repeating: .manual, count: max(list.count, 1)))
            }
            let manualOnly = list.filter { !pushed.servers.contains($0) }
            return SplitDNSRule(
                domain: domain,
                servers: pushed.servers + manualOnly,
                origins: pushed.origins + manualOnly.map { _ in .manual }
            )
        }
        rules = manualRules + detectedOrder.filter { servers[$0] == nil }.compactMap { detectedByDomain[$0] }
    }

    /// How many rules of `init(manual:detected:)` have an enabled entry of `manual` behind them. A rule's
    /// `origins` cannot say: when a tunnel pushes every server the entry names, they all count as detected.
    package static func manualDomainCount(in manual: [DomainDNSEntry]) -> Int {
        Set(enabled(manual).map(\.domain)).count
    }

    /// The enabled entries that name a domain, each with that domain normalized, in configuration order.
    private static func enabled(_ manual: [DomainDNSEntry]) -> [(domain: String, entry: DomainDNSEntry)] {
        manual.compactMap { entry in
            let domain = normalize(entry.domain)
            return entry.enabled && !domain.isEmpty ? (domain, entry) : nil
        }
    }

    /// The rule whose domain is `name` or the longest suffix of `name` on a
    /// label boundary, or nil for a public name.
    package func rule(matching name: String) -> SplitDNSRule? {
        let lower = Self.normalize(name)
        var best: SplitDNSRule?
        for rule in rules where lower == rule.domain || lower.hasSuffix(".\(rule.domain)") {
            if best.map({ rule.domain.count > $0.domain.count }) ?? true {
                best = rule
            }
        }
        return best
    }

    /// The servers of the first rule that has any, the ones a name under no
    /// rule is tried against before public DNS. An entry without servers
    /// claims its names but does not hide the next entry's servers. Empty
    /// when no rule has a server.
    package var firstServers: [String] {
        rules.first { !$0.servers.isEmpty }?.servers ?? []
    }

    private static func normalize(_ domain: String) -> String {
        var lower = domain.lowercased()
        while lower.hasSuffix(".") { lower.removeLast() }
        return lower
    }
}

/// What Settings shows of the detected set, built by `LiveSplitDNSPolicy`.
package struct DetectedSplitDNSDisplay: Hashable, Sendable, Codable {
    package enum State: String, Hashable, Sendable, Codable {
        /// The gate allows, and the last reading supplies a resolver in use or nothing is in use.
        case inUse
        /// The gate allows and the last reading supplies none of the resolvers in use: it was empty, or it
        /// named only tunnels that are not live. The set in use is kept from earlier readings.
        case held
        /// The gate withholds; the rows are the last reading, unused.
        case idle
    }

    package struct Row: Hashable, Sendable, Codable {
        package let interface: String
        package let domains: [String]
        package let servers: [String]

        package init(interface: String, domains: [String], servers: [String]) {
            self.interface = interface
            self.domains = domains
            self.servers = servers
        }
    }

    package static let none = DetectedSplitDNSDisplay(state: .idle, rows: [])

    package let state: State
    /// One per resolver the policy kept, in resolver order. Each kept domain
    /// appears once, under the first resolver that kept it, and a row left
    /// with no domain is omitted. A row's servers are the resolver's kept
    /// servers.
    package let rows: [Row]

    package init(state: State, rows: [Row]) {
        self.state = state
        self.rows = rows
    }
}
