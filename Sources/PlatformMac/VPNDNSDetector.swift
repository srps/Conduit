// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package struct DetectedDNSConfig: Equatable {
    package var searchDomain: String
    package var nameservers: [String]
    package var interfaceName: String

    package init(searchDomain: String, nameservers: [String], interfaceName: String) {
        self.searchDomain = searchDomain
        self.nameservers = nameservers
        self.interfaceName = interfaceName
    }

    package func toDNSEntries() -> [DomainDNSEntry] {
        var entries = [DomainDNSEntry(domain: searchDomain, servers: nameservers)]
        let parts = searchDomain.split(separator: ".")
        if parts.count > 2 {
            let parent = parts.dropFirst().joined(separator: ".")
            entries.append(DomainDNSEntry(domain: parent, servers: nameservers))
        }
        return entries
    }
}

package enum VPNDNSDetector {

    /// Parse `scutil --dns` output to find VPN-pushed DNS servers on utun* interfaces.
    package static func detect() -> [DetectedDNSConfig] {
        guard let output = runScutilDNS() else { return [] }
        return parse(output: output)
    }

    package static func parse(output: String) -> [DetectedDNSConfig] {
        // Only the "scoped queries" block carries per-utun resolvers; the
        // top-level "DNS configuration" block is the system fallback and
        // never names a utun interface. We skip parsing it entirely.
        let scopedHeader = "DNS configuration (for scoped queries)"
        guard let scopedStart = output.range(of: scopedHeader) else { return [] }
        let scopedText = String(output[scopedStart.lowerBound...])
        let scopedSections = splitResolverSections(scopedText)

        var results: [DetectedDNSConfig] = []

        for section in scopedSections {
            guard let iface = extractInterface(from: section),
                  iface.hasPrefix("utun") else { continue }
            guard section.contains("Reachable") else { continue }

            let nameservers = extractNameservers(from: section)
            guard !nameservers.isEmpty else { continue }

            let searchDomains = extractSearchDomains(from: section)
            let domain = extractDomain(from: section)

            if let sd = searchDomains.first, !sd.isEmpty, !isSystemDomain(sd) {
                results.append(DetectedDNSConfig(searchDomain: sd, nameservers: nameservers, interfaceName: iface))
            } else if let d = domain, !d.isEmpty, !isSystemDomain(d) {
                results.append(DetectedDNSConfig(searchDomain: d, nameservers: nameservers, interfaceName: iface))
            }
        }

        return results
    }

    // MARK: - Parsing helpers

    private static func splitResolverSections(_ text: String) -> [String] {
        let pattern = "resolver #\\d+"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))

        var sections: [String] = []
        for (i, match) in matches.enumerated() {
            let start = match.range.location
            let end = (i + 1 < matches.count) ? matches[i + 1].range.location : nsText.length
            sections.append(nsText.substring(with: NSRange(location: start, length: end - start)))
        }
        return sections
    }

    private static func extractInterface(from section: String) -> String? {
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("if_index") {
                if let openParen = trimmed.firstIndex(of: "("),
                   let closeParen = trimmed.firstIndex(of: ")"),
                   openParen < closeParen {
                    return String(trimmed[trimmed.index(after: openParen)..<closeParen])
                }
            }
        }
        return nil
    }

    private static func extractNameservers(from section: String) -> [String] {
        var servers: [String] = []
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("nameserver[") {
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let value = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { servers.append(value) }
                }
            }
        }
        return servers
    }

    private static func extractSearchDomains(from section: String) -> [String] {
        var domains: [String] = []
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("search domain[") {
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let value = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    if !value.isEmpty { domains.append(value) }
                }
            }
        }
        return domains
    }

    private static func extractDomain(from section: String) -> String? {
        for line in section.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("domain") && !trimmed.hasPrefix("domain[") {
                if let colonIdx = trimmed.firstIndex(of: ":") {
                    let value = trimmed[trimmed.index(after: colonIdx)...].trimmingCharacters(in: .whitespaces)
                    return value.isEmpty ? nil : value
                }
            }
        }
        return nil
    }

    private static func isSystemDomain(_ domain: String) -> Bool {
        let systemDomains = ["local", "254.169.in-addr.arpa"]
        let systemSuffixes = [".in-addr.arpa", ".ip6.arpa"]
        if systemDomains.contains(domain.lowercased()) { return true }
        return systemSuffixes.contains { domain.lowercased().hasSuffix($0) }
    }

    private static func runScutilDNS() -> String? {
        guard let result = try? CommandRunner.run(
            launchPath: "/usr/sbin/scutil",
            arguments: ["--dns"]
        ), result.exitCode == 0 else { return nil }
        return result.standardOutput
    }
}
