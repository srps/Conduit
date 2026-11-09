// SPDX-License-Identifier: Apache-2.0
import Foundation

/// One split-DNS domain and the servers asked for names at or under it, in
/// the order they are tried.
package struct SplitDNSRule: Hashable, Sendable {
    /// Lowercased, no trailing dot.
    package let domain: String
    /// IP literals in the order they are asked. Empty when the entry names
    /// none: its names are still split-DNS names, with no server to ask.
    package let servers: [String]

    package init(domain: String, servers: [String]) {
        self.domain = domain
        self.servers = servers
    }
}

/// What the forwarder consults for a name: built whole from the enabled
/// `dnsEntries`, one rule per domain, never mutated in place. The live table
/// of `docs/design-live-vpn-split-dns.md` builds on this value.
package struct SplitDNSTable: Hashable, Sendable {
    package static let empty = SplitDNSTable(rules: [])

    package let rules: [SplitDNSRule]

    package init(rules: [SplitDNSRule]) {
        self.rules = rules
    }

    /// The enabled entries, merged per lowercased domain in configuration
    /// order. Two entries for one domain contribute their servers in that
    /// order, each server once.
    package init(entries: [DomainDNSEntry]) {
        var order: [String] = []
        var servers: [String: [String]] = [:]
        for entry in entries where entry.enabled {
            let domain = Self.normalize(entry.domain)
            guard !domain.isEmpty else { continue }
            if servers[domain] == nil { order.append(domain) }
            var list = servers[domain] ?? []
            for server in entry.servers where !list.contains(server) {
                list.append(server)
            }
            servers[domain] = list
        }
        rules = order.map { SplitDNSRule(domain: $0, servers: servers[$0] ?? []) }
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
