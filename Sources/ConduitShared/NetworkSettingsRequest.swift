// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The bounded, credential-free subset of network preferences Conduit manages.
package enum NetworkSettingValue: Codable, Equatable, Sendable {
    case text(String)
    case number(Int)
    case list([String])
}

package enum NetworkSettingsKind: String, Codable, Sendable {
    case proxies
    case dns

    package var keys: Set<String> {
        switch self {
        case .proxies:
            ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
             "ProxyAutoConfigEnable", "ProxyAutoConfigURLString", "ExceptionsList"]
        case .dns: ["ServerAddresses"]
        }
    }
}

package struct NetworkSettingsRequest: Codable, Equatable, Sendable {
    package var locationID: String
    package var serviceID: String
    package var kind: NetworkSettingsKind
    package var expected: [String: NetworkSettingValue]
    package var replacement: [String: NetworkSettingValue]
    package var requireActive: Bool

    package init(locationID: String, serviceID: String, kind: NetworkSettingsKind,
                 expected: [String: NetworkSettingValue], replacement: [String: NetworkSettingValue], requireActive: Bool) {
        self.locationID = locationID
        self.serviceID = serviceID
        self.kind = kind
        self.expected = expected
        self.replacement = replacement
        self.requireActive = requireActive
    }

    package func validate() throws {
        guard UUID(uuidString: locationID) != nil, UUID(uuidString: serviceID) != nil else {
            throw NetworkSettingsError.invalidRequest
        }
        if requireActive && replacement["ProxyAutoConfigEnable"] == .number(1) {
            guard case .text(let url) = replacement["ProxyAutoConfigURLString"], !url.isEmpty else {
                throw NetworkSettingsError.invalidRequest
            }
        }
        for fields in [expected, replacement] {
            guard Set(fields.keys).isSubset(of: kind.keys) else { throw NetworkSettingsError.invalidRequest }
            for (key, value) in fields {
                switch value {
                case .number(let number):
                    guard key.hasSuffix("Enable") ? (0...1).contains(number) :
                        (key.hasSuffix("Port") && (0...65535).contains(number)) else {
                        throw NetworkSettingsError.invalidRequest
                    }
                case .text(let text):
                    guard text.utf8.count <= 4096, !text.contains("\u{0}"),
                          key.hasSuffix("Proxy") || key == "ProxyAutoConfigURLString" else {
                        throw NetworkSettingsError.invalidRequest
                    }
                    // PAC URLs must not persist embedded credentials.
                    if key == "ProxyAutoConfigURLString", !text.isEmpty {
                        guard let url = URLComponents(string: text),
                              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                              url.host != nil, url.user == nil, url.password == nil else {
                            throw NetworkSettingsError.invalidRequest
                        }
                    }
                case .list(let list):
                    guard ["ExceptionsList", "ServerAddresses"].contains(key), list.count <= 256,
                          list.allSatisfy({ $0.utf8.count <= 253 && !$0.contains("\u{0}") }) else {
                        throw NetworkSettingsError.invalidRequest
                    }
                    if key == "ServerAddresses", !list.allSatisfy(HelperInputValidator.validateIPAddress) {
                        throw NetworkSettingsError.invalidRequest
                    }
                }
            }
        }
        // Enforce the whole wire budget before callers durably capture prior state.
        guard try JSONEncoder().encode(self).count <= 65_536 else { throw NetworkSettingsError.invalidRequest }
    }

    /// Loginwindow may only remove loopback listener fields, never unrelated settings or prior values.
    package var isCleanup: Bool {
        let changed = Set(expected.keys).union(replacement.keys).filter { expected[$0] != replacement[$0] }
        return !requireActive && changed.isSubset(of: cleanupKeys) && replacement.allSatisfy { key, value in
            value == expected[key] || (key.hasSuffix("Enable") && value == .number(0))
        }
    }

    package var cleanupKeys: Set<String> {
        if kind == .dns { return expected["ServerAddresses"] == .list(["127.0.0.1"]) ? ["ServerAddresses"] : [] }
        var keys: Set<String> = []
        for prefix in ["HTTP", "HTTPS"] {
            if case .text(let host) = expected[prefix + "Proxy"], Self.isLoopback(host),
               case .number(let port) = expected[prefix + "Port"], (1...65535).contains(port) {
                keys.formUnion([prefix + "Proxy", prefix + "Port", prefix + "Enable"])
            }
        }
        if case .text(let text) = expected["ProxyAutoConfigURLString"], let url = URLComponents(string: text),
           Self.isLoopback(url.host ?? ""), url.path == "/proxy.pac" {
            keys.formUnion(["ProxyAutoConfigURLString", "ProxyAutoConfigEnable"])
        }
        return keys
    }

    private static func isLoopback(_ host: String) -> Bool {
        host.caseInsensitiveCompare("localhost") == .orderedSame || host == "::1" || host == "[::1]"
            || (host.hasPrefix("127.") && HelperInputValidator.validateIPAddress(host))
    }

    package func encoded() throws -> String {
        try validate()
        let data = try JSONEncoder().encode(self)
        guard data.count <= 65_536 else { throw NetworkSettingsError.invalidRequest }
        return String(decoding: data, as: UTF8.self)
    }

    package static func decode(_ text: String) throws -> Self {
        guard text.utf8.count <= 65_536 else { throw NetworkSettingsError.invalidRequest }
        let result = try JSONDecoder().decode(Self.self, from: Data(text.utf8))
        try result.validate()
        return result
    }
}

package enum NetworkSettingsError: Error, LocalizedError {
    case invalidRequest
    case changed
    case unavailable
    case persistenceFailed
    case capacityExceeded

    package var errorDescription: String? {
        switch self {
        case .invalidRequest: "Invalid network settings request."
        case .changed: "Network location or settings changed during the operation; reconcile again."
        case .unavailable: "Network preferences could not be read or committed."
        case .persistenceFailed: "Network prior state could not be saved; no settings were changed."
        case .capacityExceeded: "Network location recovery capacity exceeded; no settings were changed."
        }
    }
}
