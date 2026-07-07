// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package enum DNSValidationError: Error, LocalizedError {
    case invalidDomain(String)
    case invalidServer(String)

    package var errorDescription: String? {
        switch self {
        case .invalidDomain(let d):
            return "Invalid DNS domain name: \(d)"
        case .invalidServer(let s):
            return "Invalid DNS server address: \(s)"
        }
    }
}

package final class DNSManager: @unchecked Sendable {
    private static let domainRegex = try! NSRegularExpression(
        pattern: #"^[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?(\.[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?)*$"#
    )
    private static let ipv4Regex = try! NSRegularExpression(
        pattern: #"^(\d{1,3}\.){3}\d{1,3}$"#
    )
    private static let ipv6Regex = try! NSRegularExpression(
        pattern: #"^[0-9a-fA-F:]+$"#
    )

    private let privilegeClient: PrivilegeClient

    package init(privilegeClient: PrivilegeClient = AppleScriptPrivilegeClient()) {
        self.privilegeClient = privilegeClient
    }

    // MARK: - Validation

    package static func validateDomain(_ domain: String) throws {
        let range = NSRange(domain.startIndex..<domain.endIndex, in: domain)
        guard !domain.isEmpty,
              domain.count <= 253,
              domainRegex.firstMatch(in: domain, range: range) != nil else {
            throw DNSValidationError.invalidDomain(domain)
        }
    }

    package static func validateServer(_ server: String) throws {
        let range = NSRange(server.startIndex..<server.endIndex, in: server)
        let isIPv4 = ipv4Regex.firstMatch(in: server, range: range) != nil
        let isIPv6 = ipv6Regex.firstMatch(in: server, range: range) != nil
        guard isIPv4 || isIPv6 else {
            throw DNSValidationError.invalidServer(server)
        }
    }

    // MARK: - Intercept Rule Processing

    /// Domains whose `/etc/resolver/<domain>` file points the system resolver
    /// at the local DNS forwarder. Apply/isApplied gate the set on the
    /// forwarder + transparent proxy being enabled. Clear/isCleared pass
    /// `forCleanup: true`: cleanup must derive the set from the rules alone
    /// (including disabled ones), because by cleanup time the enable flags
    /// have typically already flipped false (`stopDNS` persists
    /// `dnsForwarderEnabled = false` before the proxy stops) — gating cleanup
    /// on them strands stale resolver files that keep routing e.g.
    /// `*.cursor.sh` at a forwarder that no longer exists.
    private func getInterceptDomains(from config: ProxyConfig, forCleanup: Bool = false) -> [String] {
        if !forCleanup {
            guard config.dnsForwarderEnabled, config.transparentProxyEnabled else { return [] }
        }
        let rules = forCleanup ? config.dnsInterceptRules : config.enabledInterceptRules
        return rules.map { rule in
            var base = rule.pattern
            if base.hasPrefix("*.") {
                base = String(base.dropFirst(2))
            } else if base.hasPrefix("*") {
                base = String(base.dropFirst(1))
            }
            return base
        }.filter { !$0.isEmpty }
    }

    // MARK: - Entry Processing

    /// Static split-DNS entries (`/etc/resolver/<domain>` → corporate DNS
    /// servers), gated on the VPN being up. The configured servers live
    /// inside the tunnel, but the resolver override applies to *everything*
    /// matching the domain — including the VPN gateway's own public hostname
    /// (e.g. `vpn-gw.corp.example` matched by a `corp.example` entry). With
    /// the VPN down the override sends those lookups to unreachable servers,
    /// so the VPN client cannot resolve its gateway to reconnect: a bootstrap
    /// deadlock only a file removal breaks. Entry files must therefore exist
    /// only while the tunnel that makes their servers reachable is up.
    private func getEntries(from config: ProxyConfig, vpnConnected: Bool) -> [DomainDNSEntry] {
        guard vpnConnected else { return [] }
        return config.dnsEntries.filter(\.enabled).filter { !$0.servers.isEmpty }
    }

    // MARK: - State Detection

    package func isApplied(config: ProxyConfig, vpnConnected: Bool = true) -> Bool {
        let enabledEntries = getEntries(from: config, vpnConnected: vpnConnected)
        let interceptDomains = getInterceptDomains(from: config)

        guard !enabledEntries.isEmpty || !interceptDomains.isEmpty else { return true }

        let entriesApplied = enabledEntries.allSatisfy { entry in
            let expected = entry.servers.map { "nameserver \($0)" }.joined(separator: "\n")
            let filePath = "/etc/resolver/\(entry.domain)"
            guard let actual = try? String(contentsOfFile: filePath, encoding: .utf8) else { return false }
            return actual.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let interceptApplied = interceptDomains.allSatisfy { domain in
            let expected = "nameserver 127.0.0.1\nport \(config.dnsForwarderPort)"
            let filePath = "/etc/resolver/\(domain)"
            guard let actual = try? String(contentsOfFile: filePath, encoding: .utf8) else { return false }
            return actual.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return entriesApplied && interceptApplied
    }

    package func isCleared(config: ProxyConfig) -> Bool {
        let enabledEntries = config.dnsEntries.filter(\.enabled)
        let interceptDomains = getInterceptDomains(from: config, forCleanup: true)

        let entriesCleared = enabledEntries.allSatisfy { entry in
            !FileManager.default.fileExists(atPath: "/etc/resolver/\(entry.domain)")
        }

        let interceptCleared = interceptDomains.allSatisfy { domain in
            !FileManager.default.fileExists(atPath: "/etc/resolver/\(domain)")
        }

        return entriesCleared && interceptCleared
    }

    // MARK: - Apply / Clear

    package func apply(config: ProxyConfig, logger: (any LogSink)?, vpnConnected: Bool = true) throws {
        let enabledEntries = getEntries(from: config, vpnConnected: vpnConnected)
        let interceptDomains = getInterceptDomains(from: config)

        if !vpnConnected, !config.dnsEntries.filter(\.enabled).isEmpty {
            logger?.log(.notice, "Split-DNS entry files deferred until the VPN connects (their servers are tunnel-internal).", category: .system)
        }

        guard !enabledEntries.isEmpty || !interceptDomains.isEmpty else {
            if vpnConnected || config.dnsEntries.filter(\.enabled).isEmpty {
                logger?.log(.warning, "DNS resolver management skipped because no internal DNS servers or intercept rules are configured.", category: .system)
            }
            return
        }

        for entry in enabledEntries {
            try Self.validateDomain(entry.domain)
            for server in entry.servers {
                try Self.validateServer(server)
            }
        }

        for domain in interceptDomains {
            try Self.validateDomain(domain)
        }

        for entry in enabledEntries {
            try privilegeClient.execute(.applyDNS, values: [entry.domain, entry.servers.joined(separator: ",")])
        }

        for domain in interceptDomains {
            try privilegeClient.execute(.applyDNS, values: [domain, "127.0.0.1", String(config.dnsForwarderPort)])
        }

        logger?.log(.notice, "Applied split-DNS resolver files for \(enabledEntries.count) domain(s) and \(interceptDomains.count) intercept rule(s).", category: .system)
    }

    package func clear(config: ProxyConfig, logger: (any LogSink)?) throws {
        let enabledEntries = config.dnsEntries.filter(\.enabled)
        let interceptDomains = getInterceptDomains(from: config, forCleanup: true)

        guard !enabledEntries.isEmpty || !interceptDomains.isEmpty else { return }

        for entry in enabledEntries {
            try Self.validateDomain(entry.domain)
        }

        for domain in interceptDomains {
            try Self.validateDomain(domain)
        }

        for entry in enabledEntries {
            try privilegeClient.execute(.removeDNS, values: [entry.domain])
        }

        for domain in interceptDomains {
            try privilegeClient.execute(.removeDNS, values: [domain])
        }

        logger?.log(.notice, "Removed managed split-DNS resolver files and intercept rules.", category: .system)
    }

    // MARK: - Reconcile (config edits while running)

    /// Applies the delta between two configs: removes resolver files that were
    /// (or may have been) managed under `old` but are no longer wanted under
    /// `new`, then applies `new`'s full set. Domains present in both configs
    /// are rewritten in place — never removed first — so a running system
    /// keeps resolving them throughout. This is what makes DNS config edits
    /// take effect without a Conduit restart.
    package func reconcile(old: ProxyConfig, new: ProxyConfig, logger: (any LogSink)?, vpnConnected: Bool = true) throws {
        let oldDomains = Set(
            old.dnsEntries.filter(\.enabled).map(\.domain)
                + getInterceptDomains(from: old, forCleanup: true)
        )
        let newDomains = Set(
            getEntries(from: new, vpnConnected: vpnConnected).map(\.domain)
                + getInterceptDomains(from: new)
        )

        let stale = oldDomains.subtracting(newDomains)
        for domain in stale {
            try Self.validateDomain(domain)
            try privilegeClient.execute(.removeDNS, values: [domain])
        }
        if !stale.isEmpty {
            logger?.log(.notice, "Removed \(stale.count) stale resolver file(s) after config change.", category: .system)
        }

        guard !newDomains.isEmpty else { return }
        try apply(config: new, logger: logger, vpnConnected: vpnConnected)
    }

    // MARK: - VPN-lifecycle entry files

    /// Writes only the static split-DNS entry files. Called when the VPN
    /// transitions to connected while the proxy is running: `apply` deferred
    /// them while the tunnel (and thus their servers) was unreachable.
    package func applyEntryFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let entries = getEntries(from: config, vpnConnected: true)
        guard !entries.isEmpty else { return }
        for entry in entries {
            try Self.validateDomain(entry.domain)
            for server in entry.servers {
                try Self.validateServer(server)
            }
        }
        for entry in entries {
            try privilegeClient.execute(.applyDNS, values: [entry.domain, entry.servers.joined(separator: ",")])
        }
        logger?.log(.notice, "Applied \(entries.count) split-DNS entry file(s) now that the VPN is connected.", category: .system)
    }

    /// Removes only the static split-DNS entry files. Called when the VPN
    /// disconnects: their servers are tunnel-internal, and leaving the
    /// override in place blackholes every lookup under those domains —
    /// including the VPN gateway's own public hostname when it falls under a
    /// managed domain, which deadlocks reconnection (see `getEntries`).
    package func clearEntryFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let entries = config.dnsEntries.filter(\.enabled)
        guard !entries.isEmpty else { return }
        for entry in entries {
            try Self.validateDomain(entry.domain)
        }
        for entry in entries {
            try privilegeClient.execute(.removeDNS, values: [entry.domain])
        }
        logger?.log(.notice, "Removed \(entries.count) split-DNS entry file(s) while the VPN is disconnected.", category: .system)
    }

    /// Writes only the intercept-rule resolver files. Called from the DNS
    /// start path: at proxy start `dnsForwarderEnabled` may still have been
    /// false, so `apply` skipped these — they can only be written once the
    /// forwarder is actually up.
    package func applyInterceptFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let interceptDomains = getInterceptDomains(from: config)
        guard !interceptDomains.isEmpty else { return }
        for domain in interceptDomains {
            try Self.validateDomain(domain)
        }
        for domain in interceptDomains {
            try privilegeClient.execute(.applyDNS, values: [domain, "127.0.0.1", String(config.dnsForwarderPort)])
        }
        logger?.log(.notice, "Applied \(interceptDomains.count) intercept resolver file(s) for the DNS forwarder.", category: .system)
    }

    /// Removes only the intercept-rule resolver files (all rules, enabled or
    /// not). Called from the DNS stop path so `*.cursor.sh`-style domains
    /// never keep pointing at a forwarder that is no longer listening, while
    /// the static split-DNS entry files (which do not depend on the
    /// forwarder) stay in place for the still-running proxy.
    package func clearInterceptFiles(config: ProxyConfig, logger: (any LogSink)?) throws {
        let interceptDomains = getInterceptDomains(from: config, forCleanup: true)
        guard !interceptDomains.isEmpty else { return }
        for domain in interceptDomains {
            try Self.validateDomain(domain)
        }
        for domain in interceptDomains {
            try privilegeClient.execute(.removeDNS, values: [domain])
        }
        logger?.log(.notice, "Removed \(interceptDomains.count) intercept resolver file(s).", category: .system)
    }
}
