// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct ProxyConfig: Codable, Equatable {
    package static let currentSchemaVersion = 1

    // MARK: - Section Storage

    package var schemaVersion: Int
    package var profileName: String
    package var proxy: ProxySection
    package var auth: AuthSection
    package var upstreams: [UpstreamProxy]
    package var routing: RoutingSection
    package var dns: DNSSection
    package var tunnels: TunnelSection
    package var health: HealthSection
    package var logging: LoggingSection

    // MARK: - Section-Based Init

    package init(
        schemaVersion: Int = ProxyConfig.currentSchemaVersion,
        profileName: String = GenericDefaults.shared.profileName,
        proxy: ProxySection = ProxySection(),
        auth: AuthSection = AuthSection(),
        upstreams: [UpstreamProxy] = [],
        routing: RoutingSection = RoutingSection(),
        dns: DNSSection = DNSSection(),
        tunnels: TunnelSection = TunnelSection(),
        health: HealthSection = HealthSection(),
        logging: LoggingSection = LoggingSection()
    ) {
        self.schemaVersion = schemaVersion
        self.profileName = profileName
        self.proxy = proxy
        self.auth = auth
        self.upstreams = upstreams
        self.routing = routing
        self.dns = dns
        self.tunnels = tunnels
        self.health = health
        self.logging = logging
    }

    // MARK: - Backward-Compatible Flat Aliases (proxy)

    package var localHost: String {
        get { proxy.host }
        set { proxy.host = newValue }
    }

    package var localPort: Int {
        get { proxy.port }
        set { proxy.port = newValue }
    }

    package var socksEnabled: Bool {
        get { proxy.socksEnabled }
        set { proxy.socksEnabled = newValue }
    }

    package var socksPort: Int {
        get { proxy.socksPort }
        set { proxy.socksPort = newValue }
    }

    package var gatewayMode: Bool {
        get { proxy.gatewayMode }
        set { proxy.gatewayMode = newValue }
    }

    package var allowedClients: [String] {
        get { proxy.allowedClients }
        set { proxy.allowedClients = newValue }
    }

    package var maxConnections: Int {
        get { proxy.maxConnections }
        set { proxy.maxConnections = newValue }
    }

    package var stalledConnectionTimeoutSeconds: TimeInterval {
        get { proxy.stalledConnectionTimeout }
        set { proxy.stalledConnectionTimeout = newValue }
    }

    package var maxBufferedBodyBytes: Int {
        get { proxy.maxBufferedBodyBytes }
        set { proxy.maxBufferedBodyBytes = newValue }
    }

    package var maxSpooledBodyBytes: Int {
        get { proxy.maxSpooledBodyBytes }
        set { proxy.maxSpooledBodyBytes = newValue }
    }

    package var inboundConnectionWarnThreshold: Int {
        get { proxy.inboundConnectionWarnThreshold }
        set { proxy.inboundConnectionWarnThreshold = newValue }
    }

    package var inboundConnectionMaxLimit: Int {
        get { proxy.inboundConnectionMaxLimit }
        set { proxy.inboundConnectionMaxLimit = newValue }
    }

    package var strictMode: Bool {
        get { proxy.strictMode }
        set { proxy.strictMode = newValue }
    }

    // MARK: - Backward-Compatible Flat Aliases (auth)

    package var authMode: AuthenticationMode {
        get { auth.mode }
        set { auth.mode = newValue }
    }

    package var username: String {
        get { auth.username }
        set { auth.username = newValue }
    }

    package var domain: String {
        get { auth.domain }
        set { auth.domain = newValue }
    }

    package var workstation: String {
        get { auth.workstation }
        set { auth.workstation = newValue }
    }

    package var pendingAuthHandshakeGlobalLimit: Int {
        get { auth.pendingHandshakeGlobalLimit }
        set { auth.pendingHandshakeGlobalLimit = newValue }
    }

    package var pendingAuthHandshakesPerSource: Int {
        get { auth.pendingHandshakesPerSource }
        set { auth.pendingHandshakesPerSource = newValue }
    }

    // MARK: - Backward-Compatible Flat Aliases (routing)

    package var pacURL: String {
        get { routing.pacURL }
        set { routing.pacURL = newValue }
    }

    package var localPACEnabled: Bool {
        get { routing.localPACEnabled }
        set { routing.localPACEnabled = newValue }
    }

    package var localPACPort: Int {
        get { routing.localPACPort }
        set { routing.localPACPort = newValue }
    }

    package var pacRoutingEnabled: Bool {
        get { routing.pacRoutingEnabled }
        set { routing.pacRoutingEnabled = newValue }
    }

    package var noProxyHosts: [String] {
        get { routing.noProxyHosts }
        set { routing.noProxyHosts = newValue }
    }

    package var forceProxyHosts: [String] {
        get { routing.forceProxyHosts }
        set { routing.forceProxyHosts = newValue }
    }

    // MARK: - Backward-Compatible Flat Aliases (dns)

    package var dnsForwarderEnabled: Bool {
        get { dns.forwarderEnabled }
        set { dns.forwarderEnabled = newValue }
    }

    package var dnsForwarderPort: Int {
        get { dns.forwarderPort }
        set { dns.forwarderPort = newValue }
    }

    package var dohProviders: [String] {
        get { dns.dohProviders }
        set { dns.dohProviders = newValue }
    }

    package var dnsEntries: [DomainDNSEntry] {
        get { dns.entries }
        set { dns.entries = newValue }
    }

    package var dnsInterceptRules: [DNSInterceptRule] {
        get { dns.interceptRules }
        set { dns.interceptRules = newValue }
    }

    package var transparentProxyEnabled: Bool {
        get { dns.transparentProxyEnabled }
        set { dns.transparentProxyEnabled = newValue }
    }

    package var transparentProxyIP: String {
        get { dns.transparentProxyIP }
        set { dns.transparentProxyIP = newValue }
    }

    package var transparentProxyPort: Int {
        get { dns.transparentProxyPort }
        set { dns.transparentProxyPort = newValue }
    }

    // MARK: - Backward-Compatible Flat Aliases (tunnels)

    package var tunnelDefinitions: [TunnelDefinition] {
        get { tunnels.definitions }
        set { tunnels.definitions = newValue }
    }

    package var maxTunnelSessions: Int {
        get { tunnels.maxSessions }
        set { tunnels.maxSessions = newValue }
    }

    package var maxSessionsPerTunnel: Int {
        get { tunnels.maxSessionsPerTunnel }
        set { tunnels.maxSessionsPerTunnel = newValue }
    }

    // MARK: - Backward-Compatible Flat Aliases (health)

    package var healthCheckURL: String {
        get { health.checkURL }
        set { health.checkURL = newValue }
    }

    package var healthCheckIntervalSeconds: TimeInterval {
        get { health.checkInterval }
        set { health.checkInterval = newValue }
    }

    /// Legacy accessor: milliseconds as Int. Canonical storage is seconds in `health.connectionCheckTimeout`.
    package var connectionCheckTimeoutMS: Int {
        get { Int(health.connectionCheckTimeout * 1000) }
        set { health.connectionCheckTimeout = TimeInterval(newValue) / 1000.0 }
    }

    /// How long to wait for an upstream proxy response after a request/CONNECT
    /// attempt has been written. Separate from `stalledConnectionTimeoutSeconds`,
    /// which only reaps unused pooled connections.
    package var upstreamResponseTimeoutSeconds: TimeInterval {
        get { health.upstreamResponseTimeout }
        set { health.upstreamResponseTimeout = newValue }
    }

    /// Legacy accessor: minutes as Int. Canonical storage is seconds in `health.directConnectTTL`.
    package var directConnectTTLMinutes: Int {
        get { Int(health.directConnectTTL / 60) }
        set { health.directConnectTTL = TimeInterval(newValue) * 60 }
    }

    /// Phase 5: minimum elapsed time between an upstream's first failure and a
    /// circuit-breaker trip. See `HealthSection.circuitBreakerWindowSeconds`.
    package var circuitBreakerWindowSeconds: TimeInterval {
        get { health.circuitBreakerWindowSeconds }
        set { health.circuitBreakerWindowSeconds = newValue }
    }

    /// Consecutive-failure threshold before the upstream's
    /// circuit breaker trips. See `HealthSection.circuitFailureThreshold`.
    package var circuitFailureThreshold: Int {
        get { health.circuitFailureThreshold }
        set { health.circuitFailureThreshold = newValue }
    }

    /// Initial open-interval seconds applied on a circuit trip.
    /// See `HealthSection.circuitBaseOpenIntervalSeconds`.
    package var circuitBaseOpenIntervalSeconds: TimeInterval {
        get { health.circuitBaseOpenIntervalSeconds }
        set { health.circuitBaseOpenIntervalSeconds = newValue }
    }

    /// Maximum open-interval seconds the exponential backoff
    /// caps at. See `HealthSection.circuitMaxOpenIntervalSeconds`.
    package var circuitMaxOpenIntervalSeconds: TimeInterval {
        get { health.circuitMaxOpenIntervalSeconds }
        set { health.circuitMaxOpenIntervalSeconds = newValue }
    }

    /// Phase 6: VPN flap grace window. See `HealthSection.vpnFlapGraceSeconds`.
    package var vpnFlapGraceSeconds: TimeInterval {
        get { health.vpnFlapGraceSeconds }
        set { health.vpnFlapGraceSeconds = newValue }
    }

    /// Phase 6 (revised): minimum Link-inactive duration before a flap becomes
    /// user-visible. See `HealthSection.vpnFlapMinVisibleSeconds`.
    package var vpnFlapMinVisibleSeconds: TimeInterval {
        get { health.vpnFlapMinVisibleSeconds }
        set { health.vpnFlapMinVisibleSeconds = newValue }
    }

    // MARK: - Backward-Compatible Flat Aliases (logging)

    package var verboseLogging: Bool {
        get { logging.verbose }
        set { logging.verbose = newValue }
    }

    /// Opt-in per-connection audit log.
    /// See `LoggingSection.auditLogEnabled`.
    package var auditLogEnabled: Bool {
        get { logging.auditLogEnabled }
        set { logging.auditLogEnabled = newValue }
    }

    /// Max bytes the audit log file may occupy.
    /// See `LoggingSection.auditLogMaxBytes`.
    package var auditLogMaxBytes: Int {
        get { logging.auditLogMaxBytes }
        set { logging.auditLogMaxBytes = newValue }
    }

    /// Optional override for the audit log path.
    /// See `LoggingSection.auditLogPath`.
    package var auditLogPath: String? {
        get { logging.auditLogPath }
        set { logging.auditLogPath = newValue }
    }

    // MARK: - Vendor-Neutral Test Fixture

    /// Vendor-neutral populated `ProxyConfig` for tests that need a valid
    /// config but don't depend on any bundled preset.
    ///
    /// The fixture targets `.example.test` hosts (RFC 6761 reserved) so
    /// accidental network egress in tests fails loudly instead of touching a
    /// real host.
    package static func testFixture() -> ProxyConfig {
        var config = ProxyConfig()
        config.profileName = "test-fixture"
        config.upstreams = [
            UpstreamProxy(
                name: "test-upstream-a",
                host: "proxy-a.example.test",
                port: 8080,
                priority: 0
            ),
            UpstreamProxy(
                name: "test-upstream-b",
                host: "proxy-b.example.test",
                port: 8080,
                priority: 1
            ),
            UpstreamProxy(
                name: "test-upstream-c",
                host: "proxy-c.example.test",
                port: 8080,
                priority: 2
            ),
        ]
        return config
    }

    // MARK: - Flat JSON Codable (backward-compatible)

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case profileName
        case localHost, localPort
        case socksPort, socksEnabled
        case authMode, username, domain, workstation
        case pendingAuthHandshakeGlobalLimit, pendingAuthHandshakesPerSource
        case upstreams
        case pacURL, localPACEnabled, localPACPort, pacRoutingEnabled
        case dnsEntries, noProxyHosts, forceProxyHosts
        case healthCheckURL, healthCheckIntervalSeconds
        case stalledConnectionTimeoutSeconds
        case maxConnections, connectionCheckTimeoutMS, upstreamResponseTimeoutSeconds, directConnectTTLMinutes
        case circuitBreakerWindowSeconds
        case circuitFailureThreshold
        case circuitBaseOpenIntervalSeconds
        case circuitMaxOpenIntervalSeconds
        case vpnFlapGraceSeconds, vpnFlapMinVisibleSeconds
        case maxBufferedBodyBytes, maxSpooledBodyBytes
        case inboundConnectionWarnThreshold, inboundConnectionMaxLimit
        case strictMode, verboseLogging
        case auditLogEnabled, auditLogMaxBytes, auditLogPath
        case gatewayMode, allowedClients
        case dnsForwarderEnabled, dnsForwarderPort
        case dohProviders
        case maxTunnelSessions, maxSessionsPerTunnel
        case tunnelDefinitions
        case dnsInterceptRules
        case transparentProxyEnabled, transparentProxyIP, transparentProxyPort
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let g = GenericDefaults.shared

        schemaVersion = try c.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? Self.currentSchemaVersion
        profileName = try c.decodeIfPresent(String.self, forKey: .profileName) ?? g.profileName

        proxy = ProxySection(
            host: try c.decodeIfPresent(String.self, forKey: .localHost) ?? g.proxy.host,
            port: try c.decodeIfPresent(Int.self, forKey: .localPort) ?? g.proxy.port,
            socksEnabled: try c.decodeIfPresent(Bool.self, forKey: .socksEnabled) ?? g.proxy.socksEnabled,
            socksPort: try c.decodeIfPresent(Int.self, forKey: .socksPort) ?? g.proxy.socksPort,
            gatewayMode: try c.decodeIfPresent(Bool.self, forKey: .gatewayMode) ?? g.proxy.gatewayMode,
            allowedClients: try c.decodeIfPresent([String].self, forKey: .allowedClients) ?? g.proxy.allowedClients,
            maxConnections: try c.decodeIfPresent(Int.self, forKey: .maxConnections) ?? g.proxy.maxConnections,
            stalledConnectionTimeout: try c.decodeIfPresent(TimeInterval.self, forKey: .stalledConnectionTimeoutSeconds) ?? g.proxy.stalledConnectionTimeout,
            maxBufferedBodyBytes: try c.decodeIfPresent(Int.self, forKey: .maxBufferedBodyBytes) ?? g.proxy.maxBufferedBodyBytes,
            maxSpooledBodyBytes: try c.decodeIfPresent(Int.self, forKey: .maxSpooledBodyBytes) ?? g.proxy.maxSpooledBodyBytes,
            inboundConnectionWarnThreshold: try c.decodeIfPresent(Int.self, forKey: .inboundConnectionWarnThreshold) ?? g.proxy.inboundConnectionWarnThreshold,
            inboundConnectionMaxLimit: try c.decodeIfPresent(Int.self, forKey: .inboundConnectionMaxLimit) ?? g.proxy.inboundConnectionMaxLimit,
            strictMode: try c.decodeIfPresent(Bool.self, forKey: .strictMode) ?? g.proxy.strictMode
        )

        auth = AuthSection(
            mode: try c.decodeIfPresent(AuthenticationMode.self, forKey: .authMode) ?? g.auth.mode,
            username: try c.decodeIfPresent(String.self, forKey: .username) ?? g.auth.username,
            domain: try c.decodeIfPresent(String.self, forKey: .domain) ?? g.auth.domain,
            workstation: try c.decodeIfPresent(String.self, forKey: .workstation) ?? g.auth.workstation,
            pendingHandshakeGlobalLimit: try c.decodeIfPresent(Int.self, forKey: .pendingAuthHandshakeGlobalLimit) ?? g.auth.pendingHandshakeGlobalLimit,
            pendingHandshakesPerSource: try c.decodeIfPresent(Int.self, forKey: .pendingAuthHandshakesPerSource) ?? g.auth.pendingHandshakesPerSource
        )

        upstreams = try c.decodeIfPresent([UpstreamProxy].self, forKey: .upstreams) ?? g.upstreams

        routing = RoutingSection(
            pacURL: try c.decodeIfPresent(String.self, forKey: .pacURL) ?? g.routing.pacURL,
            localPACEnabled: try c.decodeIfPresent(Bool.self, forKey: .localPACEnabled) ?? g.routing.localPACEnabled,
            localPACPort: try c.decodeIfPresent(Int.self, forKey: .localPACPort) ?? g.routing.localPACPort,
            pacRoutingEnabled: try c.decodeIfPresent(Bool.self, forKey: .pacRoutingEnabled) ?? g.routing.pacRoutingEnabled,
            noProxyHosts: try c.decodeIfPresent([String].self, forKey: .noProxyHosts) ?? g.routing.noProxyHosts,
            forceProxyHosts: try c.decodeIfPresent([String].self, forKey: .forceProxyHosts) ?? g.routing.forceProxyHosts
        )

        let rawEntries = try c.decodeIfPresent([DomainDNSEntry].self, forKey: .dnsEntries) ?? g.dns.entries
        let rawInterceptRules = try c.decodeIfPresent([DNSInterceptRule].self, forKey: .dnsInterceptRules) ?? g.dns.interceptRules
        dns = DNSSection(
            forwarderEnabled: try c.decodeIfPresent(Bool.self, forKey: .dnsForwarderEnabled) ?? g.dns.forwarderEnabled,
            forwarderPort: try c.decodeIfPresent(Int.self, forKey: .dnsForwarderPort) ?? g.dns.forwarderPort,
            dohProviders: try c.decodeIfPresent([String].self, forKey: .dohProviders) ?? g.dns.dohProviders,
            entries: rawEntries,
            interceptRules: rawInterceptRules,
            transparentProxyEnabled: try c.decodeIfPresent(Bool.self, forKey: .transparentProxyEnabled) ?? g.dns.transparentProxyEnabled,
            transparentProxyIP: try c.decodeIfPresent(String.self, forKey: .transparentProxyIP) ?? g.dns.transparentProxyIP,
            transparentProxyPort: try c.decodeIfPresent(Int.self, forKey: .transparentProxyPort) ?? g.dns.transparentProxyPort
        )

        let rawDefs = try c.decodeIfPresent([TunnelDefinition].self, forKey: .tunnelDefinitions) ?? g.tunnels.definitions
        tunnels = TunnelSection(
            definitions: rawDefs,
            maxSessions: try c.decodeIfPresent(Int.self, forKey: .maxTunnelSessions) ?? g.tunnels.maxSessions,
            maxSessionsPerTunnel: try c.decodeIfPresent(Int.self, forKey: .maxSessionsPerTunnel) ?? g.tunnels.maxSessionsPerTunnel
        )

        let rawCheckTimeoutMS = try c.decodeIfPresent(Int.self, forKey: .connectionCheckTimeoutMS)
        let rawTTLMinutes = try c.decodeIfPresent(Int.self, forKey: .directConnectTTLMinutes)
        health = HealthSection(
            checkURL: try c.decodeIfPresent(String.self, forKey: .healthCheckURL) ?? g.health.checkURL,
            checkInterval: try c.decodeIfPresent(TimeInterval.self, forKey: .healthCheckIntervalSeconds) ?? g.health.checkInterval,
            connectionCheckTimeout: rawCheckTimeoutMS.map { TimeInterval($0) / 1000.0 } ?? g.health.connectionCheckTimeout,
            upstreamResponseTimeout: try c.decodeIfPresent(TimeInterval.self, forKey: .upstreamResponseTimeoutSeconds) ?? g.health.upstreamResponseTimeout,
            directConnectTTL: rawTTLMinutes.map { TimeInterval($0) * 60 } ?? g.health.directConnectTTL,
            circuitBreakerWindowSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .circuitBreakerWindowSeconds) ?? g.health.circuitBreakerWindowSeconds,
            circuitFailureThreshold: try c.decodeIfPresent(Int.self, forKey: .circuitFailureThreshold) ?? g.health.circuitFailureThreshold,
            circuitBaseOpenIntervalSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .circuitBaseOpenIntervalSeconds) ?? g.health.circuitBaseOpenIntervalSeconds,
            circuitMaxOpenIntervalSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .circuitMaxOpenIntervalSeconds) ?? g.health.circuitMaxOpenIntervalSeconds,
            vpnFlapGraceSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .vpnFlapGraceSeconds) ?? g.health.vpnFlapGraceSeconds,
            vpnFlapMinVisibleSeconds: try c.decodeIfPresent(TimeInterval.self, forKey: .vpnFlapMinVisibleSeconds) ?? g.health.vpnFlapMinVisibleSeconds
        )

        logging = LoggingSection(
            verbose: try c.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? g.logging.verbose,
            auditLogEnabled: try c.decodeIfPresent(Bool.self, forKey: .auditLogEnabled) ?? g.logging.auditLogEnabled,
            auditLogMaxBytes: try c.decodeIfPresent(Int.self, forKey: .auditLogMaxBytes) ?? g.logging.auditLogMaxBytes,
            auditLogPath: try c.decodeIfPresent(String.self, forKey: .auditLogPath) ?? g.logging.auditLogPath
        )
    }

    package func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)

        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(profileName, forKey: .profileName)

        // proxy
        try c.encode(proxy.host, forKey: .localHost)
        try c.encode(proxy.port, forKey: .localPort)
        try c.encode(proxy.socksEnabled, forKey: .socksEnabled)
        try c.encode(proxy.socksPort, forKey: .socksPort)
        try c.encode(proxy.gatewayMode, forKey: .gatewayMode)
        try c.encode(proxy.allowedClients, forKey: .allowedClients)
        try c.encode(proxy.maxConnections, forKey: .maxConnections)
        try c.encode(proxy.stalledConnectionTimeout, forKey: .stalledConnectionTimeoutSeconds)
        try c.encode(proxy.maxBufferedBodyBytes, forKey: .maxBufferedBodyBytes)
        try c.encode(proxy.maxSpooledBodyBytes, forKey: .maxSpooledBodyBytes)
        try c.encode(proxy.inboundConnectionWarnThreshold, forKey: .inboundConnectionWarnThreshold)
        try c.encode(proxy.inboundConnectionMaxLimit, forKey: .inboundConnectionMaxLimit)
        try c.encode(proxy.strictMode, forKey: .strictMode)

        // auth
        try c.encode(auth.mode, forKey: .authMode)
        try c.encode(auth.username, forKey: .username)
        try c.encode(auth.domain, forKey: .domain)
        try c.encode(auth.workstation, forKey: .workstation)
        try c.encode(auth.pendingHandshakeGlobalLimit, forKey: .pendingAuthHandshakeGlobalLimit)
        try c.encode(auth.pendingHandshakesPerSource, forKey: .pendingAuthHandshakesPerSource)

        // upstreams
        try c.encode(upstreams, forKey: .upstreams)

        // routing
        try c.encode(routing.pacURL, forKey: .pacURL)
        try c.encode(routing.localPACEnabled, forKey: .localPACEnabled)
        try c.encode(routing.localPACPort, forKey: .localPACPort)
        try c.encode(routing.pacRoutingEnabled, forKey: .pacRoutingEnabled)
        try c.encode(routing.noProxyHosts, forKey: .noProxyHosts)
        try c.encode(routing.forceProxyHosts, forKey: .forceProxyHosts)

        // dns
        try c.encode(dns.forwarderEnabled, forKey: .dnsForwarderEnabled)
        try c.encode(dns.forwarderPort, forKey: .dnsForwarderPort)
        try c.encode(dns.dohProviders, forKey: .dohProviders)
        try c.encode(dns.entries, forKey: .dnsEntries)
        try c.encode(dns.interceptRules, forKey: .dnsInterceptRules)
        try c.encode(dns.transparentProxyEnabled, forKey: .transparentProxyEnabled)
        try c.encode(dns.transparentProxyIP, forKey: .transparentProxyIP)
        try c.encode(dns.transparentProxyPort, forKey: .transparentProxyPort)

        // tunnels
        try c.encode(tunnels.definitions, forKey: .tunnelDefinitions)
        try c.encode(tunnels.maxSessions, forKey: .maxTunnelSessions)
        try c.encode(tunnels.maxSessionsPerTunnel, forKey: .maxSessionsPerTunnel)

        // health (encode in legacy units for backward compat)
        try c.encode(health.checkURL, forKey: .healthCheckURL)
        try c.encode(health.checkInterval, forKey: .healthCheckIntervalSeconds)
        try c.encode(Int(health.connectionCheckTimeout * 1000), forKey: .connectionCheckTimeoutMS)
        try c.encode(health.upstreamResponseTimeout, forKey: .upstreamResponseTimeoutSeconds)
        try c.encode(Int(health.directConnectTTL / 60), forKey: .directConnectTTLMinutes)
        try c.encode(health.circuitBreakerWindowSeconds, forKey: .circuitBreakerWindowSeconds)
        try c.encode(health.circuitFailureThreshold, forKey: .circuitFailureThreshold)
        try c.encode(health.circuitBaseOpenIntervalSeconds, forKey: .circuitBaseOpenIntervalSeconds)
        try c.encode(health.circuitMaxOpenIntervalSeconds, forKey: .circuitMaxOpenIntervalSeconds)
        try c.encode(health.vpnFlapGraceSeconds, forKey: .vpnFlapGraceSeconds)
        try c.encode(health.vpnFlapMinVisibleSeconds, forKey: .vpnFlapMinVisibleSeconds)

        // logging
        try c.encode(logging.verbose, forKey: .verboseLogging)
        try c.encode(logging.auditLogEnabled, forKey: .auditLogEnabled)
        try c.encode(logging.auditLogMaxBytes, forKey: .auditLogMaxBytes)
        try c.encodeIfPresent(logging.auditLogPath, forKey: .auditLogPath)
    }

    // MARK: - Computed Properties

    package var localProxyURL: String {
        "http://\(localHost):\(localPort)"
    }

    package var effectiveListenHost: String {
        gatewayMode ? "0.0.0.0" : localHost
    }

    package var effectiveTunnelListenHost: String {
        "127.0.0.1"
    }

    package var enabledUpstreams: [UpstreamProxy] {
        upstreams
            .filter(\.enabled)
            .sorted { $0.priority < $1.priority }
    }

    package var enabledInterceptRules: [DNSInterceptRule] {
        dnsInterceptRules.filter(\.enabled)
    }
}

// MARK: - DNS Intercept Rule

package struct DNSInterceptRule: Codable, Hashable, Identifiable, Sendable {
    package var id: UUID
    package var pattern: String
    package var interceptIP: String
    package var enabled: Bool

    package init(
        id: UUID = UUID(),
        pattern: String,
        interceptIP: String = "127.44.3.0",
        enabled: Bool = true
    ) {
        self.id = id
        self.pattern = pattern
        self.interceptIP = interceptIP
        self.enabled = enabled
    }

    package func matches(_ domain: String) -> Bool {
        let lower = domain.lowercased()
        let pat = pattern.lowercased()
        if pat.hasPrefix("*.") {
            let suffix = String(pat.dropFirst(1))
            return lower.hasSuffix(suffix) || lower == String(pat.dropFirst(2))
        }
        return lower == pat
    }
}

// MARK: - Tunnel Preset

package enum TunnelPreset: String, Codable, CaseIterable, Identifiable, Sendable {
    case cosmosDBMongo
    case mongoDBAtlas
    case postgresql
    case mysql
    case redis
    case amqp
    case custom

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .cosmosDBMongo: return "CosmosDB (MongoDB API)"
        case .mongoDBAtlas: return "MongoDB Atlas"
        case .postgresql: return "PostgreSQL"
        case .mysql: return "MySQL"
        case .redis: return "Redis"
        case .amqp: return "RabbitMQ / AMQP"
        case .custom: return "Custom"
        }
    }

    package var icon: String {
        switch self {
        case .cosmosDBMongo: return "leaf"
        case .mongoDBAtlas: return "leaf.fill"
        case .postgresql: return "cylinder"
        case .mysql: return "cylinder.split.1x2"
        case .redis: return "memorychip"
        case .amqp: return "arrow.left.arrow.right"
        case .custom: return "wrench"
        }
    }

    package var defaultRemotePort: Int {
        switch self {
        case .cosmosDBMongo: return 10255
        case .mongoDBAtlas: return 27017
        case .postgresql: return 5432
        case .mysql: return 3306
        case .redis: return 6379
        case .amqp: return 5672
        case .custom: return 0
        }
    }

    package var defaultLocalPort: Int { defaultRemotePort }

    package var hostPlaceholder: String {
        switch self {
        case .cosmosDBMongo: return "your-account.mongo.cosmos.azure.com"
        case .mongoDBAtlas: return "cluster0-shard-00-00.xxxxx.mongodb.net"
        case .postgresql: return "your-db.postgres.database.azure.com"
        case .mysql: return "your-db.mysql.database.azure.com"
        case .redis: return "your-cache.redis.cache.windows.net"
        case .amqp: return "your-broker.servicebus.windows.net"
        case .custom: return "host.example.com"
        }
    }

    package var helpText: String {
        switch self {
        case .cosmosDBMongo: return "Azure CosmosDB with MongoDB wire protocol (port 10255)."
        case .mongoDBAtlas: return "MongoDB Atlas cluster via direct connection (port 27017, TLS required)."
        case .postgresql: return "PostgreSQL database server (port 5432)."
        case .mysql: return "MySQL database server (port 3306)."
        case .redis: return "Redis cache or data store (port 6379)."
        case .amqp: return "AMQP message broker such as RabbitMQ (port 5672)."
        case .custom: return "Any TCP service reachable through the corporate proxy."
        }
    }

    package func makeDefinition() -> TunnelDefinition {
        TunnelDefinition(
            localPort: defaultLocalPort,
            remoteHost: "",
            remotePort: defaultRemotePort,
            proxied: true,
            label: displayName,
            preset: self
        )
    }
}

// MARK: - Tunnel Definition

package struct TunnelDefinition: Codable, Equatable, Hashable, Identifiable {
    package var id: UUID
    package var localPort: Int
    package var remoteHost: String
    package var remotePort: Int
    package var enabled: Bool
    package var proxied: Bool
    package var label: String
    package var preset: TunnelPreset?

    package init(
        id: UUID = UUID(),
        localPort: Int,
        remoteHost: String,
        remotePort: Int,
        enabled: Bool = true,
        proxied: Bool = false,
        label: String = "",
        preset: TunnelPreset? = nil
    ) {
        self.id = id
        self.localPort = localPort
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.enabled = enabled
        self.proxied = proxied
        self.label = label
        self.preset = preset
    }

    package var effectiveLabel: String {
        label.isEmpty ? "\(localPort)→\(remoteHost):\(remotePort)" : label
    }

    package var description: String {
        "\(localPort):\(remoteHost):\(remotePort)"
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        localPort = try container.decode(Int.self, forKey: .localPort)
        remoteHost = try container.decode(String.self, forKey: .remoteHost)
        remotePort = try container.decode(Int.self, forKey: .remotePort)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        proxied = try container.decodeIfPresent(Bool.self, forKey: .proxied) ?? false
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        preset = try container.decodeIfPresent(TunnelPreset.self, forKey: .preset)
    }
}
