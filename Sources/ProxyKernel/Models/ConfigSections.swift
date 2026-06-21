// SPDX-License-Identifier: Apache-2.0
import Foundation

// MARK: - Proxy Section

package struct ProxySection: Codable, Equatable, Sendable {
    package var host: String
    package var port: Int
    package var socksEnabled: Bool
    package var socksPort: Int
    package var gatewayMode: Bool
    package var allowedClients: [String]
    package var maxConnections: Int
    package var stalledConnectionTimeout: TimeInterval
    package var maxBufferedBodyBytes: Int
    package var maxSpooledBodyBytes: Int
    package var inboundConnectionWarnThreshold: Int
    package var inboundConnectionMaxLimit: Int
    package var strictMode: Bool

    package init(
        host: String = "127.0.0.1",
        port: Int = 3128,
        socksEnabled: Bool = false,
        socksPort: Int = 1080,
        gatewayMode: Bool = false,
        allowedClients: [String] = ["127.0.0.1", "::1"],
        maxConnections: Int = 5000,
        stalledConnectionTimeout: TimeInterval = 45,
        maxBufferedBodyBytes: Int = 16_777_216,
        maxSpooledBodyBytes: Int = 268_435_456,
        inboundConnectionWarnThreshold: Int = 1000,
        inboundConnectionMaxLimit: Int = 10000,
        strictMode: Bool = true
    ) {
        self.host = host
        self.port = port
        self.socksEnabled = socksEnabled
        self.socksPort = socksPort
        self.gatewayMode = gatewayMode
        self.allowedClients = allowedClients
        self.maxConnections = maxConnections
        self.stalledConnectionTimeout = stalledConnectionTimeout
        self.maxBufferedBodyBytes = maxBufferedBodyBytes
        self.maxSpooledBodyBytes = maxSpooledBodyBytes
        self.inboundConnectionWarnThreshold = inboundConnectionWarnThreshold
        self.inboundConnectionMaxLimit = inboundConnectionMaxLimit
        self.strictMode = strictMode
    }
}

// MARK: - Auth Section

package struct AuthSection: Codable, Equatable, Sendable {
    package var mode: AuthenticationMode
    package var username: String
    package var domain: String
    package var workstation: String
    package var pendingHandshakeGlobalLimit: Int
    package var pendingHandshakesPerSource: Int

    package init(
        mode: AuthenticationMode = .systemNegotiated,
        username: String = NSUserName(),
        domain: String = "",
        workstation: String = ProcessInfo.processInfo.hostName,
        pendingHandshakeGlobalLimit: Int = 512,
        pendingHandshakesPerSource: Int = 128
    ) {
        self.mode = mode
        self.username = username
        self.domain = domain
        self.workstation = workstation
        self.pendingHandshakeGlobalLimit = pendingHandshakeGlobalLimit
        self.pendingHandshakesPerSource = pendingHandshakesPerSource
    }
}

// MARK: - Routing Section

package struct RoutingSection: Codable, Equatable, Sendable {
    package var pacURL: String
    package var localPACEnabled: Bool
    /// Loopback-only port the `LocalPACServer` binds to when `localPACEnabled`
    /// is true. Separate from `proxy.port` (the HTTP/CONNECT listener) so
    /// `networksetup -setautoproxyurl http://<localHost>:<localPACPort>/proxy.pac`
    /// can point Chromium-based clients at an always-reachable PAC URL without
    /// colliding with the proxy itself. Default `63145` — distinctive 5-digit
    /// non-IANA port; IT admins rarely have firewall rules that touch it.
    /// ConfigValidation enforces uniqueness against every other bound port
    /// only when `localPACEnabled` is true (idle port is harmless).
    package var localPACPort: Int
    package var pacRoutingEnabled: Bool
    package var noProxyHosts: [String]
    package var forceProxyHosts: [String]

    package init(
        pacURL: String = "",
        localPACEnabled: Bool = false,
        localPACPort: Int = 63145,
        pacRoutingEnabled: Bool = true,
        noProxyHosts: [String] = ["localhost", "127.0.0.1", "127.0.0.*", "::1", "[::1]", "*.local", "10.*", "192.168.*", "172.16.*"],
        forceProxyHosts: [String] = []
    ) {
        self.pacURL = pacURL
        self.localPACEnabled = localPACEnabled
        self.localPACPort = localPACPort
        self.pacRoutingEnabled = pacRoutingEnabled
        self.noProxyHosts = noProxyHosts
        self.forceProxyHosts = forceProxyHosts
    }
}

// MARK: - DNS Section

package struct DNSSection: Codable, Equatable, Sendable {
    package var forwarderEnabled: Bool
    package var forwarderPort: Int
    package var dohProviders: [String]
    package var entries: [DomainDNSEntry]
    package var interceptRules: [DNSInterceptRule]
    package var transparentProxyEnabled: Bool
    package var transparentProxyIP: String
    package var transparentProxyPort: Int

    package init(
        forwarderEnabled: Bool = false,
        forwarderPort: Int = 5053,
        dohProviders: [String] = [
            "https://cloudflare-dns.com/dns-query",
            "https://dns.quad9.net/dns-query",
            "https://dns.google/dns-query",
        ],
        entries: [DomainDNSEntry] = [],
        interceptRules: [DNSInterceptRule] = [],
        transparentProxyEnabled: Bool = false,
        transparentProxyIP: String = "127.44.3.0",
        transparentProxyPort: Int = 10443
    ) {
        self.forwarderEnabled = forwarderEnabled
        self.forwarderPort = forwarderPort
        self.dohProviders = dohProviders
        self.entries = entries
        self.interceptRules = interceptRules
        self.transparentProxyEnabled = transparentProxyEnabled
        self.transparentProxyIP = transparentProxyIP
        self.transparentProxyPort = transparentProxyPort
    }
}

// MARK: - Tunnel Section

package struct TunnelSection: Codable, Equatable, Sendable {
    package var definitions: [TunnelDefinition]
    package var maxSessions: Int
    package var maxSessionsPerTunnel: Int

    package init(
        definitions: [TunnelDefinition] = [],
        maxSessions: Int = 128,
        maxSessionsPerTunnel: Int = 32
    ) {
        self.definitions = definitions
        self.maxSessions = maxSessions
        self.maxSessionsPerTunnel = maxSessionsPerTunnel
    }
}

// MARK: - Health Section

package struct HealthSection: Codable, Equatable, Sendable {
    package var checkURL: String
    /// Health check interval in seconds.
    package var checkInterval: TimeInterval
    /// Connection check timeout in seconds (stored canonically; legacy JSON uses milliseconds).
    package var connectionCheckTimeout: TimeInterval
    /// How long a request/CONNECT attempt may wait after it has been written
    /// to an upstream proxy before any upstream response bytes arrive.
    ///
    /// This is deliberately separate from `ProxySection.stalledConnectionTimeout`:
    /// that setting reaps unused pooled connections, while this one bounds the
    /// user-visible request wait on a blackholed but still-established upstream
    /// socket. Default 45 s. File-only config for now.
    package var upstreamResponseTimeout: TimeInterval
    /// Direct-connect TTL in seconds (stored canonically; legacy JSON uses minutes).
    package var directConnectTTL: TimeInterval
    /// Phase 5 of `docs/design-vpn-flap-resilience.md`. Minimum elapsed time
    /// between an upstream's *first* recorded failure and a circuit-breaker trip.
    /// A burst of synchronized failures (e.g. 5 in-flight requests all fail at
    /// the same VPN-flap instant) within this window does NOT trip the breaker
    /// — synchronized bursts are a transient-path signal, not an upstream-rot
    /// signal. The trip still requires `consecutiveFailures >= threshold`;
    /// the time-window guard is added on top.
    ///
    /// Half-open re-trips (one failed probe after a circuit was opened) are
    /// NOT gated by this window — re-tripping is the whole point of half-open.
    ///
    /// Default 10 s. Range 0...300 (0 disables the guard, restoring legacy
    /// burst-trip behavior). File-only config — not surfaced in the UI.
    package var circuitBreakerWindowSeconds: TimeInterval

    /// Per-upstream circuit-breaker failure threshold. The
    /// breaker trips after this many *consecutive* failed exchanges, gated
    /// by `circuitBreakerWindowSeconds`. Lower values trip faster (good
    /// for unreliable corporate proxies where failover is cheap); higher
    /// values tolerate transient spikes (good for low-redundancy setups
    /// where a tripped breaker means "no proxy at all"). Default 5
    /// preserves the legacy hardcoded value.
    package var circuitFailureThreshold: Int

    /// Initial open-interval (seconds) the breaker applies on
    /// the first trip. Each subsequent half-open re-trip doubles this up
    /// to `circuitMaxOpenIntervalSeconds`. Lowering it makes recovery
    /// faster for upstreams that flap briefly; raising it reduces
    /// re-probe traffic against an upstream that's been steadily failing.
    /// Default 30 s preserves the legacy hardcoded value.
    package var circuitBaseOpenIntervalSeconds: TimeInterval

    /// Cap on the exponentially-backed-off open interval.
    /// Default 300 s preserves the legacy hardcoded value.
    package var circuitMaxOpenIntervalSeconds: TimeInterval

    /// Phase 6 of `docs/design-vpn-flap-resilience.md`. How long after a Link
    /// goes inactive on a previously-connected utun before declaring the VPN
    /// `.disconnected(.networkLost)`. Within this window the state is
    /// `.reasserting` — silent grace, active streams ride out the flap via
    /// TCP keepalive, no routing decisions change.
    ///
    /// Default 5 s. Phase 7 will surface this in Settings UI; for now it's
    /// file-only. pm-sim sets it to a small value (e.g. 0.2) so flap
    /// scenarios don't take 30+ s wall time.
    package var vpnFlapGraceSeconds: TimeInterval

    /// Phase 6 (revised) of `docs/design-vpn-flap-resilience.md`. How long an
    /// utun Link must remain inactive before the orchestrator considers it a
    /// user-visible flap event. Sub-window blips are completely silent — no
    /// event, no `directModeCause` change, no UI flicker. The kernel's TCP
    /// retransmit handles the underlying network blip transparently; reporting
    /// the blip would be noise.
    ///
    /// Naturally produces "exactly one event pair per burst" (any burst of
    /// sub-window flaps is silent) without needing the post-recovery
    /// suppression policy that the original Phase 6 design used.
    ///
    /// Default 1 s. Range 0...30 (0 disables debounce, restoring legacy
    /// "every flap is immediately visible" behavior). File-only config —
    /// surfaced in Settings UI in Phase 7.
    package var vpnFlapMinVisibleSeconds: TimeInterval

    package init(
        checkURL: String = "http://detectportal.firefox.com/success.txt",
        checkInterval: TimeInterval = 30,
        connectionCheckTimeout: TimeInterval = 2,
        upstreamResponseTimeout: TimeInterval = 45,
        directConnectTTL: TimeInterval = 300,
        circuitBreakerWindowSeconds: TimeInterval = 10,
        circuitFailureThreshold: Int = 5,
        circuitBaseOpenIntervalSeconds: TimeInterval = 30,
        circuitMaxOpenIntervalSeconds: TimeInterval = 300,
        vpnFlapGraceSeconds: TimeInterval = 5,
        vpnFlapMinVisibleSeconds: TimeInterval = 1
    ) {
        self.checkURL = checkURL
        self.checkInterval = checkInterval
        self.connectionCheckTimeout = connectionCheckTimeout
        self.upstreamResponseTimeout = upstreamResponseTimeout
        self.directConnectTTL = directConnectTTL
        self.circuitBreakerWindowSeconds = circuitBreakerWindowSeconds
        self.circuitFailureThreshold = circuitFailureThreshold
        self.circuitBaseOpenIntervalSeconds = circuitBaseOpenIntervalSeconds
        self.circuitMaxOpenIntervalSeconds = circuitMaxOpenIntervalSeconds
        self.vpnFlapGraceSeconds = vpnFlapGraceSeconds
        self.vpnFlapMinVisibleSeconds = vpnFlapMinVisibleSeconds
    }
}

// MARK: - Logging Section

package struct LoggingSection: Codable, Equatable, Sendable {
    package var verbose: Bool

    /// Per-connection audit log emission. When `true`, the
    /// daemon emits one `ConnectionAuditRecord` per completed client
    /// connection to `auditLogPath` (defaults to
    /// `$state-dir/audit.ndjson`). Off by default — opt-in for
    /// compliance / forensics use cases. The runtime event log
    /// (`events.ndjson`) is unaffected; audit complements it with a
    /// per-connection focus rather than per-decision.
    package var auditLogEnabled: Bool

    /// Maximum bytes the audit log file may occupy. When
    /// the post-append size exceeds this, the oldest records are
    /// trimmed (NDJSON-aware — trim aligns to a newline boundary). This
    /// is a *bound*, not a backup retention policy. Default 10 MiB.
    package var auditLogMaxBytes: Int

    /// Optional override for the audit log file location.
    /// When `nil`, defaults to `$state-dir/audit.ndjson` (resolved at
    /// runtime by `ProxyOrchestrator` against the active
    /// `RuntimeEnvironment`). Set explicitly when the audit file must
    /// live on a separate disk (e.g. shipped to a tamper-evident
    /// volume) without moving the rest of the state directory.
    package var auditLogPath: String?

    package init(
        verbose: Bool = false,
        auditLogEnabled: Bool = false,
        auditLogMaxBytes: Int = 10 * 1_048_576,
        auditLogPath: String? = nil
    ) {
        self.verbose = verbose
        self.auditLogEnabled = auditLogEnabled
        self.auditLogMaxBytes = auditLogMaxBytes
        self.auditLogPath = auditLogPath
    }
}

// MARK: - Platform Integration Config

package struct PlatformIntegrationConfig: Codable, Equatable, Sendable {
    package var manageSystemProxy: Bool
    package var manageEnvironmentVariables: Bool
    package var manageDNSResolvers: Bool
    package var manageSystemDNS: Bool
    package var systemProxyMode: SystemProxyMode
    package var launchAtLogin: Bool

    package init(
        manageSystemProxy: Bool = false,
        manageEnvironmentVariables: Bool = false,
        manageDNSResolvers: Bool = false,
        manageSystemDNS: Bool = false,
        systemProxyMode: SystemProxyMode = .manual,
        launchAtLogin: Bool = false
    ) {
        self.manageSystemProxy = manageSystemProxy
        self.manageEnvironmentVariables = manageEnvironmentVariables
        self.manageDNSResolvers = manageDNSResolvers
        self.manageSystemDNS = manageSystemDNS
        self.systemProxyMode = systemProxyMode
        self.launchAtLogin = launchAtLogin
    }

    /// Custom decoder that silently drops the retired `autoEnableOnVPN` /
    /// `autoDisableOffVPN` keys. They were retired in Phase 3 of
    /// `docs/design-vpn-flap-resilience.md` — the behavior they encoded
    /// ("toggle the whole proxy on VPN state change") is now subsumed by
    /// silent direct mode. Old config files with these keys decode cleanly.
    /// Unlike `decodeIfPresent` for live fields, we don't surface their value;
    /// the decoder just ignores the keys (CodingKeys lookup is by case name,
    /// missing cases are silently skipped).
    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        manageSystemProxy = try c.decodeIfPresent(Bool.self, forKey: .manageSystemProxy) ?? false
        manageEnvironmentVariables = try c.decodeIfPresent(Bool.self, forKey: .manageEnvironmentVariables) ?? false
        manageDNSResolvers = try c.decodeIfPresent(Bool.self, forKey: .manageDNSResolvers) ?? false
        manageSystemDNS = try c.decodeIfPresent(Bool.self, forKey: .manageSystemDNS) ?? false
        systemProxyMode = try c.decodeIfPresent(SystemProxyMode.self, forKey: .systemProxyMode) ?? .manual
        launchAtLogin = try c.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
    }
}

// MARK: - App Preferences

package struct AppPreferences: Codable, Equatable, Sendable {
    package var showMenuBarIcon: Bool
    package var floatingWindowEnabled: Bool
    package var globalShortcutEnabled: Bool
    package var preferredBrowserTestURL: String

    package init(
        showMenuBarIcon: Bool = true,
        floatingWindowEnabled: Bool = false,
        globalShortcutEnabled: Bool = true,
        preferredBrowserTestURL: String = ""
    ) {
        self.showMenuBarIcon = showMenuBarIcon
        self.floatingWindowEnabled = floatingWindowEnabled
        self.globalShortcutEnabled = globalShortcutEnabled
        self.preferredBrowserTestURL = preferredBrowserTestURL
    }

    package init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        showMenuBarIcon = try c.decodeIfPresent(Bool.self, forKey: .showMenuBarIcon) ?? true
        floatingWindowEnabled = try c.decodeIfPresent(Bool.self, forKey: .floatingWindowEnabled) ?? false
        globalShortcutEnabled = try c.decodeIfPresent(Bool.self, forKey: .globalShortcutEnabled) ?? true
        preferredBrowserTestURL = try c.decodeIfPresent(String.self, forKey: .preferredBrowserTestURL) ?? ""
    }
}
