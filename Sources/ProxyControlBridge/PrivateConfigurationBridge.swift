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
    /// The encoded frame is larger than the cap. Escapes can make approved values exceed it.
    case tooLarge
    /// A value crosses an approved resource ceiling (decision 0021). It names the field and the ceiling,
    /// never the value. This is refused before validation enumerates failures and before any value is mapped.
    case resourceLimit(DomainResourceViolation)
    /// The kernel's validation refused the values. `firstCheck` is the field code of the first
    /// failing check, as `ConfigValidationError.check` names it. `failureCount` is how many checks
    /// failed. Validation still runs in full; only the summary is carried out of it.
    case invalidConfiguration(firstCheck: String, failureCount: Int)
}

package enum PrivateConfigurationBridge {
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
        // The approved ceilings run before validation enumerates failures and before any value is mapped.
        if let violation = config.resourceViolation() {
            throw PrivateConfigurationBridgeError.resourceLimit(violation)
        }
        try requireValid(config)
        let request = PrivateConfigurationRequest(
            requestID: requestID,
            incarnation: incarnation,
            budget: budget,
            expectedConfigRevision: expectedConfigRevision,
            expectedPlatformRevision: expectedPlatformRevision,
            expectedOwnerGeneration: expectedOwnerGeneration,
            runtime: runtimeValues(config),
            platform: platformValues(platform)
        )
        // Escapes can make an approved value larger in the frame than its decoded size, so the exact count
        // runs on the mapped request before anything is encoded.
        try requireFrame(request)
        return request
    }

    /// Rebuilds the config and platform values from a decoded request. `localLaunchAtLogin` is this
    /// machine's own login-item state. It is an explicit input, so applying a transfer never resets it
    /// to a default. The result is validated before it is returned.
    package static func makeValues(
        from request: PrivateConfigurationRequest,
        localLaunchAtLogin: Bool
    ) throws -> (config: ProxyConfig, platform: PlatformIntegrationConfig) {
        // A decoded request was framed, so it is within the cap already. A request built in memory
        // was not, so its resource ceilings and exact body count are taken first. The count writes nothing
        // and copies nothing, and it refuses an unrepresentable value the same way the encoder does.
        try requireFrame(request)
        let config = proxyConfig(request.runtime)
        try requireValid(config)
        return (config, platformConfig(request.platform, launchAtLogin: localLaunchAtLogin))
    }

    /// The codec's exact count of a mapped request. It also runs the approved ceilings on the request, so a
    /// request that bypassed the kernel check is refused here too. A frame past the cap is `tooLarge`.
    private static func requireFrame(_ request: PrivateConfigurationRequest) throws {
        do {
            _ = try PrivateConfigurationEncoder.measureBody(request)
        } catch PrivateConfigurationWireError.frameTooLarge {
            throw PrivateConfigurationBridgeError.tooLarge
        } catch PrivateConfigurationWireError.resourceLimitExceeded(let violation) {
            throw PrivateConfigurationBridgeError.resourceLimit(violation)
        }
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
