// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum NoProxyMatcher {
    /// Returns true if the host should go directly (bypass proxy).
    /// `forceProxy` overrides `bypass` -- if a host matches both, it goes through the proxy.
    package static func shouldBypass(host: String, patterns: [String], forceProxy: [String] = []) -> Bool {
        if matchesAny(host: host, patterns: forceProxy) {
            return false
        }
        return matchesAny(host: host, patterns: patterns)
    }

    package static func matchesAny(host: String, patterns: [String]) -> Bool {
        let lowerHost = host.lowercased()
        for raw in patterns {
            let pattern = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if pattern.isEmpty { continue }

            if pattern == lowerHost {
                return true
            }

            if pattern.hasPrefix("*.") {
                let suffix = String(pattern.dropFirst(1))
                if lowerHost.hasSuffix(suffix) || lowerHost == String(pattern.dropFirst(2)) {
                    return true
                }
            }

            if pattern.hasPrefix(".") {
                if lowerHost.hasSuffix(pattern) || lowerHost == String(pattern.dropFirst(1)) {
                    return true
                }
            }

            if pattern.hasSuffix(".*") {
                let prefix = String(pattern.dropLast(1))
                if lowerHost.hasPrefix(prefix) {
                    return true
                }
            }

            if pattern.hasSuffix("*") && !pattern.hasSuffix(".*") {
                let prefix = String(pattern.dropLast(1))
                if lowerHost.hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }

    /// Extract host from a request URI. For CONNECT it's "host:port", for HTTP it's the Host header or URL host.
    /// Handles IPv6 bracket notation like `[::1]:443`.
    package static func extractHost(from uri: String) -> String {
        if let url = URL(string: uri), url.scheme != nil, let host = url.host {
            return host
        }
        if let parsed = parseHostPort(from: uri) {
            return parsed.host
        }
        return uri
    }

    /// Parse a "host:port" string (CONNECT target, SOCKS5 target, etc.) into host and optional port.
    /// Handles IPv4, IPv6 bracket notation `[::1]:443`, and plain hostnames.
    package static func parseHostPort(from target: String) -> (host: String, port: Int?)? {
        guard let components = URLComponents(string: "//\(target)") else { return nil }
        guard var host = components.host, !host.isEmpty else { return nil }
        if host.hasPrefix("[") && host.hasSuffix("]") {
            host = String(host.dropFirst().dropLast())
        }
        return (host: host, port: components.port)
    }
}
