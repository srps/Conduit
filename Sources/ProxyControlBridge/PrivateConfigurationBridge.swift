// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import ConduitShared

// Maps the kernel's configuration to the private request values and back (decisions 0018
// and 0019). The mapping is explicit and field by field, from the real stored sections. It
// does not round-trip the legacy flat JSON, because that JSON truncates fractional seconds
// (`connectionCheckTimeoutMS`, `directConnectTTLMinutes`). Every duration here is the
// canonical seconds stored in `health`.
//
// Validation runs in this boundary, through `ProxyConfig.validate()`. The codec checks only
// that a value can be represented. The errors are fixed and safe: they carry the first failing
// check's field code and a count, never a value or a URL.

/// Failures of the mapping. Each case is fixed text or a bounded summary. None carries a value,
/// a URL or a token, and none carries a collection, so the error stays small however many checks fail.
package enum PrivateConfigurationBridgeError: Error, Sendable, Equatable {
    /// The values are too large for one frame. Refused before any value is mapped.
    case tooLarge
    /// The kernel's validation refused the values. `firstCheck` is the field code of the first
    /// failing check, as `ConfigValidationError.check` names it. `failureCount` is how many checks
    /// failed. Validation still runs in full; only the summary is carried out of it.
    case invalidConfiguration(firstCheck: String, failureCount: Int)
}

/// Charges the preflight's lower bound against the frame cap. Every charge is checked before it is
/// subtracted, so no sum can overflow, and the first charge past the cap throws.
private struct PreflightBudget {
    /// The bytes the body may still take. It starts at the frame cap, which is the whole frame's
    /// bound, so a body that passes this walk cannot be larger than the cap.
    private(set) var remaining = PrivateConfigurationFrame.maxFrameBytes

    /// Smallest encoded member: `"k":` with a one-byte value. Real keys are longer, so this is a floor.
    static let memberFloor = 4

    mutating func spend(_ bytes: Int) throws {
        guard bytes <= remaining else {
            throw PrivateConfigurationBridgeError.tooLarge
        }
        remaining -= bytes
    }

    /// A JSON string: its raw UTF-8 bytes and its two quotes. Escapes can only add to this.
    mutating func spend(string text: String) throws {
        // `remaining` is never negative, so `remaining - 2` cannot overflow. A failed guard is a refusal.
        guard text.utf8.count <= remaining - 2 else {
            throw PrivateConfigurationBridgeError.tooLarge
        }
        remaining -= text.utf8.count + 2
    }

    /// A JSON object with `members` members: its two braces and a floor for each member. The member
    /// count is a constant at every call site, so the multiplication stays small.
    mutating func spend(object members: Int) throws {
        try spend(2 + members * Self.memberFloor)
    }
}

package enum PrivateConfigurationBridge {
    /// A lower bound on the encoded body, or nil once the bound passes the frame cap.
    ///
    /// The walk reads each stored string once, for its UTF-8 count, and charges every array item
    /// and object at its minimum structure. Quotes, braces and member keys are counted, not only raw
    /// text, so a long run of empty strings or objects is charged. The walk stops at the first charge
    /// past the cap, so an oversize input costs no more than the cap. Escapes and separators only add
    /// to the real size, so the bound never exceeds the encoded body. It refuses by count, and the
    /// codec's exact count is still the final check.
    ///
    /// Cost of the walk itself: `String.utf8.count` is constant time for native strings. A bridged
    /// NSString may be copied to count its UTF-8. The stored values this walk does not copy are the
    /// caller's existing editor objects, whose memory this bound does not cover.
    package static func boundedLowerBound(_ config: ProxyConfig) -> Int? {
        var budget = PreflightBudget()
        do {
            try walkLowerBound(config, &budget)
        } catch {
            return nil
        }
        return PrivateConfigurationFrame.maxFrameBytes - budget.remaining
    }

    private static func walkLowerBound(_ config: ProxyConfig, _ budget: inout PreflightBudget) throws {
        try budget.spend(string: config.profileName)
        try budget.spend(string: config.localHost)
        try budget.spend(string: config.auth.username)
        try budget.spend(string: config.auth.domain)
        try budget.spend(string: config.auth.workstation)
        for client in config.proxy.allowedClients {
            try budget.spend(string: client)
        }
        for upstream in config.upstreams {
            try budget.spend(object: 6)
            try budget.spend(string: upstream.name)
            try budget.spend(string: upstream.host)
        }
        try budget.spend(string: config.routing.pacURL)
        for host in config.routing.noProxyHosts {
            try budget.spend(string: host)
        }
        for host in config.routing.forceProxyHosts {
            try budget.spend(string: host)
        }
        for provider in config.dns.dohProviders {
            try budget.spend(string: provider)
        }
        for entry in config.dns.entries {
            try budget.spend(object: 4)
            try budget.spend(string: entry.domain)
            for server in entry.servers {
                try budget.spend(string: server)
            }
        }
        for rule in config.dns.interceptRules {
            try budget.spend(object: 4)
            try budget.spend(string: rule.pattern)
            try budget.spend(string: rule.interceptIP)
        }
        try budget.spend(string: config.dns.transparentProxyIP)
        for definition in config.tunnels.definitions {
            try budget.spend(object: 8)
            try budget.spend(string: definition.remoteHost)
            try budget.spend(string: definition.label)
        }
        try budget.spend(string: config.health.checkURL)
        if let path = config.logging.auditLogPath {
            try budget.spend(string: path)
        }
    }

    /// Builds the request for one update. Its `launchAtLogin` is not carried; the local login item
    /// is app-owned.
    package static func makeRequest(
        config: ProxyConfig,
        platform: PlatformIntegrationConfig,
        requestID: ControlRequestID,
        incarnation: ControlHostIncarnation,
        budget: ControlWireBudget,
        expectedConfigRevision: ControlConfigRevision,
        expectedPlatformRevision: PrivatePlatformRevision,
        expectedOwnerGeneration: PrivateConfigExpectedGeneration
    ) throws -> PrivateConfigurationRequest {
        // The preflight runs before the mapping, so an oversize value is refused without mapping it.
        guard boundedLowerBound(config) != nil else {
            throw PrivateConfigurationBridgeError.tooLarge
        }
        try requireValid(config)
        return PrivateConfigurationRequest(
            requestID: requestID,
            incarnation: incarnation,
            budget: budget,
            expectedConfigRevision: expectedConfigRevision,
            expectedPlatformRevision: expectedPlatformRevision,
            expectedOwnerGeneration: expectedOwnerGeneration,
            runtime: runtimeValues(config),
            platform: platformValues(platform)
        )
    }

    /// Rebuilds the config and platform values from a decoded request. `localLaunchAtLogin` is this
    /// machine's own login-item state. It is an explicit input, so applying a transfer never resets it
    /// to a default. The result is validated before it is returned.
    package static func makeValues(
        from request: PrivateConfigurationRequest,
        localLaunchAtLogin: Bool
    ) throws -> (config: ProxyConfig, platform: PlatformIntegrationConfig) {
        // A decoded request was framed, so it is within the cap already. A request built in memory
        // was not, so its exact body count is taken first. The count writes nothing and copies nothing,
        // and it refuses an unrepresentable value the same way the encoder does.
        do {
            _ = try PrivateConfigurationEncoder.measureBody(request)
        } catch PrivateConfigurationWireError.frameTooLarge {
            throw PrivateConfigurationBridgeError.tooLarge
        }
        let config = proxyConfig(request.runtime)
        try requireValid(config)
        return (config, platformConfig(request.platform, launchAtLogin: localLaunchAtLogin))
    }

    /// Runs the kernel's validation in full. Only the first failing check's field code and the
    /// count leave this function, so no collection of checks is copied into the error.
    private static func requireValid(_ config: ProxyConfig) throws {
        let failures = config.validate()
        guard let first = failures.first else {
            return
        }
        throw PrivateConfigurationBridgeError.invalidConfiguration(
            firstCheck: first.check,
            failureCount: failures.count
        )
    }

    // MARK: - Kernel to values

    private static func runtimeValues(_ config: ProxyConfig) -> PrivateRuntimeConfiguration {
        let proxy = config.proxy
        let auth = config.auth
        let routing = config.routing
        let dns = config.dns
        let tunnels = config.tunnels
        let health = config.health
        let logging = config.logging
        return PrivateRuntimeConfiguration(
            profileName: config.profileName,
            proxy: PrivateProxySettings(
                host: proxy.host, port: proxy.port, socksEnabled: proxy.socksEnabled,
                socksPort: proxy.socksPort, gatewayMode: proxy.gatewayMode,
                allowedClients: proxy.allowedClients, maxConnections: proxy.maxConnections,
                stalledConnectionTimeoutSeconds: proxy.stalledConnectionTimeout,
                maxBufferedBodyBytes: proxy.maxBufferedBodyBytes,
                maxSpooledBodyBytes: proxy.maxSpooledBodyBytes,
                inboundConnectionWarnThreshold: proxy.inboundConnectionWarnThreshold,
                inboundConnectionMaxLimit: proxy.inboundConnectionMaxLimit,
                strictMode: proxy.strictMode
            ),
            auth: PrivateAuthSettings(
                mode: authenticationMode(auth.mode), username: auth.username, domain: auth.domain,
                workstation: auth.workstation, pendingHandshakeGlobalLimit: auth.pendingHandshakeGlobalLimit,
                pendingHandshakesPerSource: auth.pendingHandshakesPerSource
            ),
            upstreams: config.upstreams.map { upstream in
                PrivateUpstreamSettings(
                    id: ControlUpstreamID(rawValue: upstream.id), name: upstream.name, host: upstream.host,
                    port: upstream.port, enabled: upstream.enabled, priority: upstream.priority
                )
            },
            routing: PrivateRoutingSettings(
                pacURL: PrivateURLValue(routing.pacURL), localPACEnabled: routing.localPACEnabled,
                localPACPort: routing.localPACPort, pacRoutingEnabled: routing.pacRoutingEnabled,
                pacUsableRouteLimit: routing.pacUsableRouteLimit, noProxyHosts: routing.noProxyHosts,
                forceProxyHosts: routing.forceProxyHosts
            ),
            dns: PrivateDNSSettings(
                forwarderEnabled: dns.forwarderEnabled, forwarderPort: dns.forwarderPort,
                dohProviders: dns.dohProviders.map { PrivateURLValue($0) },
                entries: dns.entries.map { entry in
                    PrivateDNSEntrySettings(
                        id: PrivateDNSEntryID(rawValue: entry.id), domain: entry.domain,
                        servers: entry.servers, enabled: entry.enabled
                    )
                },
                interceptRules: dns.interceptRules.map { rule in
                    PrivateInterceptRuleSettings(
                        id: PrivateInterceptRuleID(rawValue: rule.id), pattern: rule.pattern,
                        interceptIP: rule.interceptIP, enabled: rule.enabled
                    )
                },
                transparentProxyEnabled: dns.transparentProxyEnabled,
                transparentProxyIP: dns.transparentProxyIP,
                transparentProxyPort: dns.transparentProxyPort
            ),
            tunnels: PrivateTunnelSettings(
                definitions: tunnels.definitions.map { definition in
                    PrivateTunnelDefinitionSettings(
                        id: ControlTunnelID(rawValue: definition.id), localPort: definition.localPort,
                        remoteHost: definition.remoteHost, remotePort: definition.remotePort,
                        enabled: definition.enabled, proxied: definition.proxied, label: definition.label,
                        preset: definition.preset.map(tunnelPreset)
                    )
                },
                maxSessions: tunnels.maxSessions,
                maxSessionsPerTunnel: tunnels.maxSessionsPerTunnel
            ),
            health: PrivateHealthSettings(
                checkURL: PrivateURLValue(health.checkURL),
                checkIntervalSeconds: health.checkInterval,
                connectionCheckTimeoutSeconds: health.connectionCheckTimeout,
                upstreamResponseTimeoutSeconds: health.upstreamResponseTimeout,
                upstreamConnectTimeoutSeconds: health.upstreamConnectTimeout,
                directConnectTTLSeconds: health.directConnectTTL,
                circuitBreakerWindowSeconds: health.circuitBreakerWindowSeconds,
                circuitFailureThreshold: health.circuitFailureThreshold,
                circuitBaseOpenIntervalSeconds: health.circuitBaseOpenIntervalSeconds,
                circuitMaxOpenIntervalSeconds: health.circuitMaxOpenIntervalSeconds,
                vpnFlapGraceSeconds: health.vpnFlapGraceSeconds,
                vpnFlapMinVisibleSeconds: health.vpnFlapMinVisibleSeconds
            ),
            logging: PrivateLoggingSettings(
                verbose: logging.verbose, auditLogEnabled: logging.auditLogEnabled,
                auditLogMaxBytes: logging.auditLogMaxBytes, auditLogPath: logging.auditLogPath
            )
        )
    }

    private static func platformValues(_ platform: PlatformIntegrationConfig) -> PrivatePlatformConfiguration {
        PrivatePlatformConfiguration(
            manageSystemProxy: platform.manageSystemProxy,
            manageEnvironmentVariables: platform.manageEnvironmentVariables,
            manageDNSResolvers: platform.manageDNSResolvers,
            manageSystemDNS: platform.manageSystemDNS,
            systemProxyMode: systemProxyMode(platform.systemProxyMode)
        )
    }

    // MARK: - Values to kernel

    private static func proxyConfig(_ runtime: PrivateRuntimeConfiguration) -> ProxyConfig {
        let proxy = runtime.proxy
        let auth = runtime.auth
        let routing = runtime.routing
        let dns = runtime.dns
        let tunnels = runtime.tunnels
        let health = runtime.health
        let logging = runtime.logging
        return ProxyConfig(
            schemaVersion: ProxyConfig.currentSchemaVersion,
            profileName: runtime.profileName,
            proxy: ProxySection(
                host: proxy.host, port: proxy.port, socksEnabled: proxy.socksEnabled,
                socksPort: proxy.socksPort, gatewayMode: proxy.gatewayMode,
                allowedClients: proxy.allowedClients, maxConnections: proxy.maxConnections,
                stalledConnectionTimeout: proxy.stalledConnectionTimeoutSeconds,
                maxBufferedBodyBytes: proxy.maxBufferedBodyBytes,
                maxSpooledBodyBytes: proxy.maxSpooledBodyBytes,
                inboundConnectionWarnThreshold: proxy.inboundConnectionWarnThreshold,
                inboundConnectionMaxLimit: proxy.inboundConnectionMaxLimit,
                strictMode: proxy.strictMode
            ),
            auth: AuthSection(
                mode: kernelAuthenticationMode(auth.mode), username: auth.username, domain: auth.domain,
                workstation: auth.workstation, pendingHandshakeGlobalLimit: auth.pendingHandshakeGlobalLimit,
                pendingHandshakesPerSource: auth.pendingHandshakesPerSource
            ),
            upstreams: runtime.upstreams.map { upstream in
                UpstreamProxy(
                    id: upstream.id.rawValue, name: upstream.name, host: upstream.host,
                    port: upstream.port, enabled: upstream.enabled, priority: upstream.priority
                )
            },
            routing: RoutingSection(
                pacURL: routing.pacURL.text, localPACEnabled: routing.localPACEnabled,
                localPACPort: routing.localPACPort, pacRoutingEnabled: routing.pacRoutingEnabled,
                pacUsableRouteLimit: routing.pacUsableRouteLimit, noProxyHosts: routing.noProxyHosts,
                forceProxyHosts: routing.forceProxyHosts
            ),
            dns: DNSSection(
                forwarderEnabled: dns.forwarderEnabled, forwarderPort: dns.forwarderPort,
                dohProviders: dns.dohProviders.map(\.text),
                entries: dns.entries.map { entry in
                    DomainDNSEntry(id: entry.id.rawValue, domain: entry.domain, servers: entry.servers, enabled: entry.enabled)
                },
                interceptRules: dns.interceptRules.map { rule in
                    DNSInterceptRule(
                        id: rule.id.rawValue, pattern: rule.pattern, interceptIP: rule.interceptIP,
                        enabled: rule.enabled
                    )
                },
                transparentProxyEnabled: dns.transparentProxyEnabled,
                transparentProxyIP: dns.transparentProxyIP,
                transparentProxyPort: dns.transparentProxyPort
            ),
            tunnels: TunnelSection(
                definitions: tunnels.definitions.map { definition in
                    TunnelDefinition(
                        id: definition.id.rawValue, localPort: definition.localPort,
                        remoteHost: definition.remoteHost, remotePort: definition.remotePort,
                        enabled: definition.enabled, proxied: definition.proxied, label: definition.label,
                        preset: definition.preset.map(kernelTunnelPreset)
                    )
                },
                maxSessions: tunnels.maxSessions,
                maxSessionsPerTunnel: tunnels.maxSessionsPerTunnel
            ),
            health: HealthSection(
                checkURL: health.checkURL.text,
                checkInterval: health.checkIntervalSeconds,
                connectionCheckTimeout: health.connectionCheckTimeoutSeconds,
                upstreamResponseTimeout: health.upstreamResponseTimeoutSeconds,
                upstreamConnectTimeout: health.upstreamConnectTimeoutSeconds,
                directConnectTTL: health.directConnectTTLSeconds,
                circuitBreakerWindowSeconds: health.circuitBreakerWindowSeconds,
                circuitFailureThreshold: health.circuitFailureThreshold,
                circuitBaseOpenIntervalSeconds: health.circuitBaseOpenIntervalSeconds,
                circuitMaxOpenIntervalSeconds: health.circuitMaxOpenIntervalSeconds,
                vpnFlapGraceSeconds: health.vpnFlapGraceSeconds,
                vpnFlapMinVisibleSeconds: health.vpnFlapMinVisibleSeconds
            ),
            logging: LoggingSection(
                verbose: logging.verbose, auditLogEnabled: logging.auditLogEnabled,
                auditLogMaxBytes: logging.auditLogMaxBytes, auditLogPath: logging.auditLogPath
            )
        )
    }

    private static func platformConfig(
        _ platform: PrivatePlatformConfiguration,
        launchAtLogin: Bool
    ) -> PlatformIntegrationConfig {
        PlatformIntegrationConfig(
            manageSystemProxy: platform.manageSystemProxy,
            manageEnvironmentVariables: platform.manageEnvironmentVariables,
            manageDNSResolvers: platform.manageDNSResolvers,
            manageSystemDNS: platform.manageSystemDNS,
            systemProxyMode: kernelSystemProxyMode(platform.systemProxyMode),
            launchAtLogin: launchAtLogin
        )
    }

    // MARK: - Enum mirrors
    // Each switch is exhaustive, with no `default`, so a new case on either side fails the build here.

    private static func authenticationMode(_ mode: AuthenticationMode) -> PrivateAuthenticationMode {
        switch mode {
        case .ntlmv2: .ntlmv2
        case .systemNegotiated: .systemNegotiated
        }
    }

    private static func kernelAuthenticationMode(_ mode: PrivateAuthenticationMode) -> AuthenticationMode {
        switch mode {
        case .ntlmv2: .ntlmv2
        case .systemNegotiated: .systemNegotiated
        }
    }

    private static func systemProxyMode(_ mode: SystemProxyMode) -> PrivateSystemProxyMode {
        switch mode {
        case .manual: .manual
        case .pac: .pac
        }
    }

    private static func kernelSystemProxyMode(_ mode: PrivateSystemProxyMode) -> SystemProxyMode {
        switch mode {
        case .manual: .manual
        case .pac: .pac
        }
    }

    private static func tunnelPreset(_ preset: TunnelPreset) -> PrivateTunnelPreset {
        switch preset {
        case .cosmosDBMongo: .cosmosDBMongo
        case .mongoDBAtlas: .mongoDBAtlas
        case .postgresql: .postgresql
        case .mysql: .mysql
        case .redis: .redis
        case .amqp: .amqp
        case .custom: .custom
        }
    }

    private static func kernelTunnelPreset(_ preset: PrivateTunnelPreset) -> TunnelPreset {
        switch preset {
        case .cosmosDBMongo: .cosmosDBMongo
        case .mongoDBAtlas: .mongoDBAtlas
        case .postgresql: .postgresql
        case .mysql: .mysql
        case .redis: .redis
        case .amqp: .amqp
        case .custom: .custom
        }
    }
}
