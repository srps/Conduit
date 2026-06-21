// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum AuthenticationMode: String, Codable, CaseIterable, Identifiable {
    case ntlmv2
    case systemNegotiated

    package var id: String { rawValue }

    package var title: String {
        switch self {
        case .ntlmv2:
            return "NTLMv2"
        case .systemNegotiated:
            return "System Negotiated"
        }
    }
}

package enum SystemProxyMode: String, Codable, CaseIterable, Identifiable {
    case manual
    case pac

    package var id: String { rawValue }
}

package struct UpstreamProxy: Codable, Hashable, Identifiable {
    package var id: UUID
    package var name: String
    package var host: String
    package var port: Int
    package var enabled: Bool
    package var priority: Int

    package init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int,
        enabled: Bool = true,
        priority: Int
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.enabled = enabled
        self.priority = priority
    }

    package var displayName: String {
        "\(host):\(port)"
    }

    package var endpoint: String {
        displayName
    }
}

package struct DomainDNSEntry: Codable, Hashable, Identifiable {
    package var id: UUID
    package var domain: String
    package var servers: [String]
    package var enabled: Bool

    package init(
        id: UUID = UUID(),
        domain: String,
        servers: [String],
        enabled: Bool = true
    ) {
        self.id = id
        self.domain = domain
        self.servers = servers
        self.enabled = enabled
    }
}
