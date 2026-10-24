// SPDX-License-Identifier: Apache-2.0
import Foundation

// The private decoder runs in two passes over one body:
//
//   1. `PrivateJSONScanner` walks the body against the schema, and `JSONByteCursor` checks the grammar, the UTF-8 and the
//      escapes, before any value is read. Foundation's JSON parser does not reliably reject a duplicate key, an unpaired
//      surrogate escape or a silently replaced byte, and any of those would change a URL without notice. The scanner
//      refuses all three. It also refuses nesting deeper than a fixed stack bound, which is structural and not a size limit.
//   2. `JSONDecoder` reads the checked bytes into `Decodable` mirrors. Each mirror builds its
//      DTO directly, so the DTOs stay non-`Codable`. Every field is required. Unknown keys are
//      refused at every level. Nothing defaults.
//
// Errors are fixed text. Nothing here echoes a key, a value or a byte.

// MARK: - Decoding

/// Decodes one checked frame body into a request. The result carries no `Codable` path, so a
/// decoded value cannot be encoded by accident.
package enum PrivateConfigurationDecoder {
    package static func decode(_ body: PrivateConfigurationFrameBody) throws -> PrivateConfigurationRequest {
        try body.bytes.withUnsafeBytes { bytes in
            // The cap is checked here as well as in the reader. A body held in memory, such as one built
            // by a caller, never passed the reader's header check. This runs before the scanner, before
            // the `Data` copy and before any allocation, and it counts the whole frame, not the body alone.
            guard PrivateConfigurationFrame.frameByteCount(bodyCount: bytes.count) <= PrivateConfigurationFrame.maxFrameBytes else {
                throw PrivateConfigurationWireError.frameTooLarge
            }
            try PrivateJSONScanner.validate(bytes)
            // A temporary `Data` copy of the checked bytes. The codec is the only place that
            // makes one, and 0018 §3 records it.
            let data = Data(bytes)
            do {
                return try JSONDecoder().decode(WireRequest.self, from: data).request
            } catch {
                // Deliberate: every decode failure, including a `WireValue` refusal such as a non-finite
                // or non-UUID value, or a number that is not an `Int`, is reported as one fixed `malformedBody`. The error names no field, so a caller learns
                // only that the body was refused. The tests pin this, and no finer taxonomy is claimed.
                throw PrivateConfigurationWireError.malformedBody
            }
        }
    }
}

// MARK: - Wire mirrors

/// Every member name of one JSON object. Its values are not read, so each one decodes to nothing.
///
/// Why this exists: a keyed container's `allKeys` drops any name that matches no `CodingKey`, so an
/// unknown key would pass a check built on it. Decoding the same object as a dictionary keeps every name.
private struct PrivateMemberNames: Decodable {
    private struct Unread: Decodable {
        init(from decoder: any Decoder) throws {}
    }

    let names: [String]

    init(from decoder: any Decoder) throws {
        names = Array(try [String: Unread](from: decoder).keys)
    }
}

/// Opens an object's keyed container and refuses any key the schema does not name.
private extension Decoder {
    func strictContainer<Key: CodingKey>(_ keys: Key.Type) throws -> KeyedDecodingContainer<Key> {
        let open = try container(keyedBy: keys)
        for name in try PrivateMemberNames(from: self).names where Key(stringValue: name) == nil {
            throw PrivateConfigurationWireError.malformedBody
        }
        return open
    }
}

/// Helpers that refuse a value the typed domain cannot represent.
private enum WireValue {
    static func uuid(_ text: String) throws -> UUID {
        guard let value = UUID(uuidString: text) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }

    static func finite(_ value: Double) throws -> Double {
        guard value.isFinite else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }

    static func ordinal<Domain: ControlIdentityDomain>(_ value: Int) throws -> ControlOrdinal<Domain> {
        guard let ordinal = ControlOrdinal<Domain>(rawValue: value) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return ordinal
    }

    static func budget(_ value: Int) throws -> ControlWireBudget {
        do {
            return try ControlWireBudget(value)
        } catch {
            throw PrivateConfigurationWireError.invalidValue
        }
    }

    static func enumValue<Value: RawRepresentable>(_ raw: String, _ type: Value.Type) throws -> Value
        where Value.RawValue == String
    {
        guard let value = Value(rawValue: raw) else {
            throw PrivateConfigurationWireError.invalidValue
        }
        return value
    }
}

private struct WireRequest: Decodable {
    let request: PrivateConfigurationRequest

    private enum Keys: String, CodingKey {
        case requestID, incarnation, budgetMilliseconds, expectedConfigRevision
        case expectedPlatformRevision, expectedOwnerGeneration, runtime, platform
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        request = PrivateConfigurationRequest(
            requestID: ControlRequestID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .requestID))),
            incarnation: ControlHostIncarnation(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .incarnation))),
            budget: try WireValue.budget(c.decode(Int.self, forKey: .budgetMilliseconds)),
            expectedConfigRevision: try WireValue.ordinal(c.decode(Int.self, forKey: .expectedConfigRevision)),
            expectedPlatformRevision: try WireValue.ordinal(c.decode(Int.self, forKey: .expectedPlatformRevision)),
            expectedOwnerGeneration: try WireValue.ordinal(c.decode(Int.self, forKey: .expectedOwnerGeneration)),
            runtime: try c.decode(WireRuntime.self, forKey: .runtime).value,
            platform: try c.decode(WirePlatform.self, forKey: .platform).value
        )
    }
}

private struct WireRuntime: Decodable {
    let value: PrivateRuntimeConfiguration

    private enum Keys: String, CodingKey {
        case profileName, proxy, auth, upstreams, routing, dns, tunnels, health, logging
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateRuntimeConfiguration(
            profileName: try c.decode(String.self, forKey: .profileName),
            proxy: try c.decode(WireProxy.self, forKey: .proxy).value,
            auth: try c.decode(WireAuth.self, forKey: .auth).value,
            upstreams: try c.decode([WireUpstream].self, forKey: .upstreams).map(\.value),
            routing: try c.decode(WireRouting.self, forKey: .routing).value,
            dns: try c.decode(WireDNS.self, forKey: .dns).value,
            tunnels: try c.decode(WireTunnels.self, forKey: .tunnels).value,
            health: try c.decode(WireHealth.self, forKey: .health).value,
            logging: try c.decode(WireLogging.self, forKey: .logging).value
        )
    }
}

private struct WireProxy: Decodable {
    let value: PrivateProxySettings

    private enum Keys: String, CodingKey {
        case host, port, socksEnabled, socksPort, gatewayMode, allowedClients, maxConnections
        case stalledConnectionTimeoutSeconds, maxBufferedBodyBytes, maxSpooledBodyBytes
        case inboundConnectionWarnThreshold, inboundConnectionMaxLimit, strictMode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateProxySettings(
            host: try c.decode(String.self, forKey: .host),
            port: try c.decode(Int.self, forKey: .port),
            socksEnabled: try c.decode(Bool.self, forKey: .socksEnabled),
            socksPort: try c.decode(Int.self, forKey: .socksPort),
            gatewayMode: try c.decode(Bool.self, forKey: .gatewayMode),
            allowedClients: try c.decode([String].self, forKey: .allowedClients),
            maxConnections: try c.decode(Int.self, forKey: .maxConnections),
            stalledConnectionTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .stalledConnectionTimeoutSeconds)),
            maxBufferedBodyBytes: try c.decode(Int.self, forKey: .maxBufferedBodyBytes),
            maxSpooledBodyBytes: try c.decode(Int.self, forKey: .maxSpooledBodyBytes),
            inboundConnectionWarnThreshold: try c.decode(Int.self, forKey: .inboundConnectionWarnThreshold),
            inboundConnectionMaxLimit: try c.decode(Int.self, forKey: .inboundConnectionMaxLimit),
            strictMode: try c.decode(Bool.self, forKey: .strictMode)
        )
    }
}

private struct WireAuth: Decodable {
    let value: PrivateAuthSettings

    private enum Keys: String, CodingKey {
        case mode, username, domain, workstation, pendingHandshakeGlobalLimit, pendingHandshakesPerSource
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateAuthSettings(
            mode: try WireValue.enumValue(c.decode(String.self, forKey: .mode), PrivateAuthenticationMode.self),
            username: try c.decode(String.self, forKey: .username),
            domain: try c.decode(String.self, forKey: .domain),
            workstation: try c.decode(String.self, forKey: .workstation),
            pendingHandshakeGlobalLimit: try c.decode(Int.self, forKey: .pendingHandshakeGlobalLimit),
            pendingHandshakesPerSource: try c.decode(Int.self, forKey: .pendingHandshakesPerSource)
        )
    }
}

private struct WireUpstream: Decodable {
    let value: PrivateUpstreamSettings

    private enum Keys: String, CodingKey {
        case id, name, host, port, enabled, priority
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateUpstreamSettings(
            id: ControlUpstreamID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            name: try c.decode(String.self, forKey: .name),
            host: try c.decode(String.self, forKey: .host),
            port: try c.decode(Int.self, forKey: .port),
            enabled: try c.decode(Bool.self, forKey: .enabled),
            priority: try c.decode(Int.self, forKey: .priority)
        )
    }
}

private struct WireRouting: Decodable {
    let value: PrivateRoutingSettings

    private enum Keys: String, CodingKey {
        case pacURL, localPACEnabled, localPACPort, pacRoutingEnabled, pacUsableRouteLimit
        case noProxyHosts, forceProxyHosts
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateRoutingSettings(
            pacURL: try PrivateURLValue(c.decode(String.self, forKey: .pacURL)),
            localPACEnabled: try c.decode(Bool.self, forKey: .localPACEnabled),
            localPACPort: try c.decode(Int.self, forKey: .localPACPort),
            pacRoutingEnabled: try c.decode(Bool.self, forKey: .pacRoutingEnabled),
            pacUsableRouteLimit: try c.decode(Int.self, forKey: .pacUsableRouteLimit),
            noProxyHosts: try c.decode([String].self, forKey: .noProxyHosts),
            forceProxyHosts: try c.decode([String].self, forKey: .forceProxyHosts)
        )
    }
}

private struct WireDNS: Decodable {
    let value: PrivateDNSSettings

    private enum Keys: String, CodingKey {
        case forwarderEnabled, forwarderPort, dohProviders, entries, interceptRules
        case transparentProxyEnabled, transparentProxyIP, transparentProxyPort
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateDNSSettings(
            forwarderEnabled: try c.decode(Bool.self, forKey: .forwarderEnabled),
            forwarderPort: try c.decode(Int.self, forKey: .forwarderPort),
            dohProviders: try c.decode([String].self, forKey: .dohProviders).map { PrivateURLValue($0) },
            entries: try c.decode([WireDNSEntry].self, forKey: .entries).map(\.value),
            interceptRules: try c.decode([WireInterceptRule].self, forKey: .interceptRules).map(\.value),
            transparentProxyEnabled: try c.decode(Bool.self, forKey: .transparentProxyEnabled),
            transparentProxyIP: try c.decode(String.self, forKey: .transparentProxyIP),
            transparentProxyPort: try c.decode(Int.self, forKey: .transparentProxyPort)
        )
    }
}

private struct WireDNSEntry: Decodable {
    let value: PrivateDNSEntrySettings

    private enum Keys: String, CodingKey {
        case id, domain, servers, enabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateDNSEntrySettings(
            id: PrivateDNSEntryID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            domain: try c.decode(String.self, forKey: .domain),
            servers: try c.decode([String].self, forKey: .servers),
            enabled: try c.decode(Bool.self, forKey: .enabled)
        )
    }
}

private struct WireInterceptRule: Decodable {
    let value: PrivateInterceptRuleSettings

    private enum Keys: String, CodingKey {
        case id, pattern, interceptIP, enabled
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateInterceptRuleSettings(
            id: PrivateInterceptRuleID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            pattern: try c.decode(String.self, forKey: .pattern),
            interceptIP: try c.decode(String.self, forKey: .interceptIP),
            enabled: try c.decode(Bool.self, forKey: .enabled)
        )
    }
}

private struct WireTunnels: Decodable {
    let value: PrivateTunnelSettings

    private enum Keys: String, CodingKey {
        case definitions, maxSessions, maxSessionsPerTunnel
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateTunnelSettings(
            definitions: try c.decode([WireTunnelDefinition].self, forKey: .definitions).map(\.value),
            maxSessions: try c.decode(Int.self, forKey: .maxSessions),
            maxSessionsPerTunnel: try c.decode(Int.self, forKey: .maxSessionsPerTunnel)
        )
    }
}

private struct WireTunnelDefinition: Decodable {
    let value: PrivateTunnelDefinitionSettings

    private enum Keys: String, CodingKey {
        case id, localPort, remoteHost, remotePort, enabled, proxied, label, preset
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        // `preset` is nullable, not optional: an absent key is refused, a null key is no preset.
        let presetRaw = try c.decode(String?.self, forKey: .preset)
        value = PrivateTunnelDefinitionSettings(
            id: ControlTunnelID(rawValue: try WireValue.uuid(c.decode(String.self, forKey: .id))),
            localPort: try c.decode(Int.self, forKey: .localPort),
            remoteHost: try c.decode(String.self, forKey: .remoteHost),
            remotePort: try c.decode(Int.self, forKey: .remotePort),
            enabled: try c.decode(Bool.self, forKey: .enabled),
            proxied: try c.decode(Bool.self, forKey: .proxied),
            label: try c.decode(String.self, forKey: .label),
            preset: try presetRaw.map { try WireValue.enumValue($0, PrivateTunnelPreset.self) }
        )
    }
}

private struct WireHealth: Decodable {
    let value: PrivateHealthSettings

    private enum Keys: String, CodingKey {
        case checkURL, checkIntervalSeconds, connectionCheckTimeoutSeconds, upstreamResponseTimeoutSeconds
        case upstreamConnectTimeoutSeconds, directConnectTTLSeconds, circuitBreakerWindowSeconds
        case circuitFailureThreshold, circuitBaseOpenIntervalSeconds, circuitMaxOpenIntervalSeconds
        case vpnFlapGraceSeconds, vpnFlapMinVisibleSeconds
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateHealthSettings(
            checkURL: try PrivateURLValue(c.decode(String.self, forKey: .checkURL)),
            checkIntervalSeconds: try WireValue.finite(c.decode(Double.self, forKey: .checkIntervalSeconds)),
            connectionCheckTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .connectionCheckTimeoutSeconds)),
            upstreamResponseTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .upstreamResponseTimeoutSeconds)),
            upstreamConnectTimeoutSeconds: try WireValue.finite(c.decode(Double.self, forKey: .upstreamConnectTimeoutSeconds)),
            directConnectTTLSeconds: try WireValue.finite(c.decode(Double.self, forKey: .directConnectTTLSeconds)),
            circuitBreakerWindowSeconds: try WireValue.finite(c.decode(Double.self, forKey: .circuitBreakerWindowSeconds)),
            circuitFailureThreshold: try c.decode(Int.self, forKey: .circuitFailureThreshold),
            circuitBaseOpenIntervalSeconds: try WireValue.finite(c.decode(Double.self, forKey: .circuitBaseOpenIntervalSeconds)),
            circuitMaxOpenIntervalSeconds: try WireValue.finite(c.decode(Double.self, forKey: .circuitMaxOpenIntervalSeconds)),
            vpnFlapGraceSeconds: try WireValue.finite(c.decode(Double.self, forKey: .vpnFlapGraceSeconds)),
            vpnFlapMinVisibleSeconds: try WireValue.finite(c.decode(Double.self, forKey: .vpnFlapMinVisibleSeconds))
        )
    }
}

private struct WireLogging: Decodable {
    let value: PrivateLoggingSettings

    private enum Keys: String, CodingKey {
        case verbose, auditLogEnabled, auditLogMaxBytes, auditLogPath
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivateLoggingSettings(
            verbose: try c.decode(Bool.self, forKey: .verbose),
            auditLogEnabled: try c.decode(Bool.self, forKey: .auditLogEnabled),
            auditLogMaxBytes: try c.decode(Int.self, forKey: .auditLogMaxBytes),
            auditLogPath: try c.decode(String?.self, forKey: .auditLogPath)
        )
    }
}

private struct WirePlatform: Decodable {
    let value: PrivatePlatformConfiguration

    private enum Keys: String, CodingKey {
        case manageSystemProxy, manageEnvironmentVariables, manageDNSResolvers, manageSystemDNS, systemProxyMode
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.strictContainer(Keys.self)
        value = PrivatePlatformConfiguration(
            manageSystemProxy: try c.decode(Bool.self, forKey: .manageSystemProxy),
            manageEnvironmentVariables: try c.decode(Bool.self, forKey: .manageEnvironmentVariables),
            manageDNSResolvers: try c.decode(Bool.self, forKey: .manageDNSResolvers),
            manageSystemDNS: try c.decode(Bool.self, forKey: .manageSystemDNS),
            systemProxyMode: try WireValue.enumValue(c.decode(String.self, forKey: .systemProxyMode), PrivateSystemProxyMode.self)
        )
    }
}
