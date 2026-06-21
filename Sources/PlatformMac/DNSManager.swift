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

    // MARK: - State Detection

    package func isApplied(config: ProxyConfig) -> Bool {
        let enabledEntries = config.dnsEntries.filter(\.enabled).filter { !$0.servers.isEmpty }
        guard !enabledEntries.isEmpty else { return true }

        return enabledEntries.allSatisfy { entry in
            let expected = entry.servers.map { "nameserver \($0)" }.joined(separator: "\n")
            let filePath = "/etc/resolver/\(entry.domain)"
            guard let actual = try? String(contentsOfFile: filePath, encoding: .utf8) else { return false }
            return actual.trimmingCharacters(in: .whitespacesAndNewlines)
                == expected.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    package func isCleared(config: ProxyConfig) -> Bool {
        let enabledEntries = config.dnsEntries.filter(\.enabled)
        return enabledEntries.allSatisfy { entry in
            !FileManager.default.fileExists(atPath: "/etc/resolver/\(entry.domain)")
        }
    }

    // MARK: - Apply / Clear

    package func apply(config: ProxyConfig, logger: (any LogSink)?) throws {
        let enabledEntries = config.dnsEntries.filter(\.enabled).filter { !$0.servers.isEmpty }
        guard !enabledEntries.isEmpty else {
            logger?.log(.warning, "DNS resolver management skipped because no internal DNS servers are configured.", category: .system)
            return
        }

        for entry in enabledEntries {
            try Self.validateDomain(entry.domain)
            for server in entry.servers {
                try Self.validateServer(server)
            }
        }

        for entry in enabledEntries {
            try privilegeClient.execute(.applyDNS, values: [entry.domain, entry.servers.joined(separator: ",")])
        }
        logger?.log(.notice, "Applied split-DNS resolver files for \(enabledEntries.count) domain(s).", category: .system)
    }

    package func clear(config: ProxyConfig, logger: (any LogSink)?) throws {
        let enabledEntries = config.dnsEntries.filter(\.enabled)
        guard !enabledEntries.isEmpty else { return }

        for entry in enabledEntries {
            try Self.validateDomain(entry.domain)
        }

        for entry in enabledEntries {
            try privilegeClient.execute(.removeDNS, values: [entry.domain])
        }
        logger?.log(.notice, "Removed managed split-DNS resolver files.", category: .system)
    }
}
