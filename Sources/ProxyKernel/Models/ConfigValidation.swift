// SPDX-License-Identifier: Apache-2.0
import Foundation

package enum ConfigValidationError: Error, LocalizedError, Sendable {
    case invalidPort(field: String, value: Int)
    case invalidLimit(field: String, value: Int, min: Int)
    case invalidDuration(field: String, value: TimeInterval)
    case invalidHost(field: String, value: String)
    case conflict(description: String)

    package var errorDescription: String? {
        switch self {
        case .invalidPort(let field, let value):
            return "\(field): port \(value) is out of range (0-65535)"
        case .invalidLimit(let field, let value, let min):
            return "\(field): \(value) is below minimum (\(min))"
        case .invalidDuration(let field, let value):
            return "\(field): \(value)s is not a valid duration"
        case .invalidHost(let field, let value):
            return "\(field): '\(value)' is not a valid host"
        case .conflict(let description):
            return description
        }
    }
}

extension ProxyConfig {
    package func validate() -> [ConfigValidationError] {
        var errors: [ConfigValidationError] = []

        validatePort("proxy.port", proxy.port, into: &errors)
        validatePort("proxy.socksPort", proxy.socksPort, into: &errors)
        validatePort("dns.forwarderPort", dns.forwarderPort, into: &errors)
        validatePort("dns.transparentProxyPort", dns.transparentProxyPort, into: &errors)
        validatePort("routing.localPACPort", routing.localPACPort, into: &errors)

        validateMinimum("proxy.maxConnections", proxy.maxConnections, min: 1, into: &errors)
        validateMinimum("proxy.inboundConnectionMaxLimit", proxy.inboundConnectionMaxLimit, min: 1, into: &errors)
        validateMinimum("proxy.maxBufferedBodyBytes", proxy.maxBufferedBodyBytes, min: 1, into: &errors)
        validateMinimum("proxy.maxSpooledBodyBytes", proxy.maxSpooledBodyBytes, min: proxy.maxBufferedBodyBytes, into: &errors)
        validateMinimum("auth.pendingHandshakeGlobalLimit", auth.pendingHandshakeGlobalLimit, min: 1, into: &errors)
        validateMinimum("auth.pendingHandshakesPerSource", auth.pendingHandshakesPerSource, min: 1, into: &errors)
        validateMinimum("tunnels.maxSessions", tunnels.maxSessions, min: 1, into: &errors)
        validateMinimum("tunnels.maxSessionsPerTunnel", tunnels.maxSessionsPerTunnel, min: 1, into: &errors)

        // Validate fields that the kernel turns into
        // `precondition` checks downstream (`UpstreamCircuitBreaker`,
        // `FileConnectionAuditSink`). Per AGENTS.md "validate at the
        // boundary, trust inside" — daemon must not crash on bad config.
        validateMinimum("health.circuitFailureThreshold", health.circuitFailureThreshold, min: 1, into: &errors)
        validateMinimum("logging.auditLogMaxBytes", logging.auditLogMaxBytes, min: 1, into: &errors)

        validateNonNegative("proxy.stalledConnectionTimeout", proxy.stalledConnectionTimeout, into: &errors)
        validateNonNegative("health.checkInterval", health.checkInterval, into: &errors)
        validateNonNegative("health.connectionCheckTimeout", health.connectionCheckTimeout, into: &errors)
        validateNonNegative("health.upstreamResponseTimeout", health.upstreamResponseTimeout, into: &errors)
        validateNonNegative("health.directConnectTTL", health.directConnectTTL, into: &errors)
        validatePositive("health.circuitBaseOpenIntervalSeconds", health.circuitBaseOpenIntervalSeconds, into: &errors)
        validatePositive("health.circuitMaxOpenIntervalSeconds", health.circuitMaxOpenIntervalSeconds, into: &errors)
        if health.circuitMaxOpenIntervalSeconds < health.circuitBaseOpenIntervalSeconds {
            errors.append(.conflict(description: "health.circuitMaxOpenIntervalSeconds (\(health.circuitMaxOpenIntervalSeconds)s) must be ≥ health.circuitBaseOpenIntervalSeconds (\(health.circuitBaseOpenIntervalSeconds)s)"))
        }

        if !Self.isSafeHostToken(proxy.host, allowWildcard: false) {
            errors.append(.invalidHost(field: "proxy.host", value: proxy.host))
        }
        if !proxy.gatewayMode && Self.isWildcardBindHost(proxy.host) {
            errors.append(.conflict(description: "proxy.host \(proxy.host) requires gatewayMode so ClientIPFilter/allowedClients are active"))
        }
        if dns.forwarderEnabled && Self.isWildcardBindHost(proxy.host) {
            errors.append(.conflict(description: "dns.forwarderEnabled cannot bind through wildcard proxy.host without a DNS client allowlist"))
        }
        for (i, host) in routing.noProxyHosts.enumerated() where !Self.isSafeHostToken(host, allowWildcard: true) {
            errors.append(.invalidHost(field: "routing.noProxyHosts[\(i)]", value: host))
        }
        for (i, host) in routing.forceProxyHosts.enumerated() where !Self.isSafeHostToken(host, allowWildcard: true) {
            errors.append(.invalidHost(field: "routing.forceProxyHosts[\(i)]", value: host))
        }
        if !routing.pacURL.isEmpty, Self.urlContainsUserInfo(routing.pacURL) {
            errors.append(.invalidHost(field: "routing.pacURL", value: routing.pacURL))
        }

        for (i, tunnel) in tunnels.definitions.enumerated() {
            let label = tunnel.effectiveLabel
            validatePort("tunnels.definitions[\(i)](\(label)).localPort", tunnel.localPort, into: &errors)
            validatePort("tunnels.definitions[\(i)](\(label)).remotePort", tunnel.remotePort, into: &errors)
        }

        if proxy.socksEnabled && proxy.socksPort == proxy.port && proxy.port != 0 {
            errors.append(.conflict(description: "SOCKS port (\(proxy.socksPort)) conflicts with proxy port (\(proxy.port))"))
        }

        // Local PAC port must not collide with any other bound port when the
        // local PAC server is enabled. An idle port is harmless (nothing binds
        // it), so we only enforce uniqueness under `localPACEnabled = true` —
        // users with the feature off don't get spurious errors for their
        // default `63145` sitting next to a third-party service.
        if routing.localPACEnabled {
            let pacPort = routing.localPACPort
            if pacPort != 0 && pacPort == proxy.port {
                errors.append(.conflict(description: "Local PAC port (\(pacPort)) conflicts with proxy port (\(proxy.port))"))
            }
            if proxy.socksEnabled && pacPort != 0 && pacPort == proxy.socksPort {
                errors.append(.conflict(description: "Local PAC port (\(pacPort)) conflicts with SOCKS port (\(proxy.socksPort))"))
            }
            if dns.forwarderEnabled && pacPort != 0 && pacPort == dns.forwarderPort {
                errors.append(.conflict(description: "Local PAC port (\(pacPort)) conflicts with DNS forwarder port (\(dns.forwarderPort))"))
            }
            if dns.transparentProxyEnabled && pacPort != 0 && pacPort == dns.transparentProxyPort {
                errors.append(.conflict(description: "Local PAC port (\(pacPort)) conflicts with transparent proxy port (\(dns.transparentProxyPort))"))
            }
            for tunnel in tunnels.definitions where tunnel.enabled {
                if pacPort != 0 && pacPort == tunnel.localPort {
                    errors.append(.conflict(description: "Local PAC port (\(pacPort)) conflicts with tunnel \(tunnel.effectiveLabel) localPort (\(tunnel.localPort))"))
                }
            }
        }

        return errors
    }

    private func validatePort(_ field: String, _ value: Int, into errors: inout [ConfigValidationError]) {
        if !(0...65535).contains(value) {
            errors.append(.invalidPort(field: field, value: value))
        }
    }

    private func validateMinimum(_ field: String, _ value: Int, min: Int, into errors: inout [ConfigValidationError]) {
        if value < min {
            errors.append(.invalidLimit(field: field, value: value, min: min))
        }
    }

    private func validateNonNegative(_ field: String, _ value: TimeInterval, into errors: inout [ConfigValidationError]) {
        if value < 0 {
            errors.append(.invalidDuration(field: field, value: value))
        }
    }

    /// Strictly positive (`> 0`). Use for durations the kernel hard-asserts
    /// must be positive (e.g. circuit-breaker open intervals — a zero
    /// interval would let a tripped breaker re-probe immediately, defeating
    /// the backoff).
    private func validatePositive(_ field: String, _ value: TimeInterval, into errors: inout [ConfigValidationError]) {
        if value <= 0 {
            errors.append(.invalidDuration(field: field, value: value))
        }
    }

    private static func isSafeHostToken(_ value: String, allowWildcard: Bool) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 253 else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-_[]:")
            .union(allowWildcard ? CharacterSet(charactersIn: "*") : CharacterSet())
        return trimmed.unicodeScalars.allSatisfy { scalar in
            allowed.contains(scalar)
        }
    }

    private static func urlContainsUserInfo(_ value: String) -> Bool {
        guard let components = URLComponents(string: value) else { return false }
        return components.user != nil || components.password != nil
    }

    private static func isWildcardBindHost(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed == "0.0.0.0" || trimmed == "::" || trimmed == "[::]"
    }
}
