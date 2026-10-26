// SPDX-License-Identifier: Apache-2.0
import Foundation

// The frozen private configuration values one update carries (decisions 0018 and
// 0019). They are `Sendable` and deliberately not `Codable`: only
// `PrivateConfigurationCodec` writes or reads them, so no generic encoder can
// reach URL plaintext. Every field mirrors a stored field of `ProxyConfig` or
// `PlatformIntegrationConfig`, except `schemaVersion` (a file-format marker) and
// `PlatformIntegrationConfig.launchAtLogin` (app-owned, per login item).
//
// The mapping to and from `ProxyConfig` lives in `ProxyControlBridge`, not here,
// so this target keeps no kernel dependency.

/// The workflow intent generation a store operation context echoes. It never
/// crosses the private wire: an update names exact store baselines and one
/// lifecycle revision per module instead.
package enum PrivateConfigIntentDomain: ControlIdentityDomain {}
package enum PrivateDNSEntryDomain: ControlIdentityDomain {}
package enum PrivateInterceptRuleDomain: ControlIdentityDomain {}

package typealias PrivateConfigExpectedGeneration = ControlOrdinal<PrivateConfigIntentDomain>
package typealias PrivateDNSEntryID = ControlIdentifier<PrivateDNSEntryDomain>
package typealias PrivateInterceptRuleID = ControlIdentifier<PrivateInterceptRuleDomain>

/// A URL that may carry a token. The plaintext lives only in `SecretBytes`, and
/// every reflection path returns the redacted form. No `Codable` conformance:
/// the private codec is the only writer of these bytes.
package struct PrivateURLValue: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    private let bytes: SecretBytes

    /// Copies the exact UTF-8 of `string`. Nothing is trimmed, normalized or re-encoded.
    package init(_ string: String) {
        self.bytes = SecretBytes(utf8: string)
    }

    /// Codec use only. The codec calls this after its UTF-8 validation has passed.
    package init(validatedUTF8 bytes: SecretBytes) {
        self.bytes = bytes
    }

    package var byteCount: Int { bytes.count }

    /// The exact text. This is the only route back to plaintext, and the bridge uses it
    /// to build a `ProxyConfig`. Never pass it to a log, event, status or error.
    package var text: String {
        bytes.withUnsafeBytes { String(decoding: $0, as: UTF8.self) }
    }

    /// Scoped access to the UTF-8 bytes. The codec uses this to write them out.
    package func withUTF8<Result>(_ body: (UnsafeBufferPointer<UInt8>) throws -> Result) rethrows -> Result {
        try bytes.withUnsafeBytes(body)
    }

    package var description: String { "PrivateURLValue(<redacted, \(bytes.count) bytes>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror {
        Mirror(self, children: [("description", description)], displayStyle: .struct)
    }

    package static func == (lhs: PrivateURLValue, rhs: PrivateURLValue) -> Bool {
        lhs.bytes == rhs.bytes
    }
}

// MARK: - Enum mirrors

/// Mirrors `AuthenticationMode`. The raw values are identical, and a bridge test
/// checks that both sides still name the same cases.
package enum PrivateAuthenticationMode: String, Sendable, CaseIterable {
    case ntlmv2
    case systemNegotiated
}

/// Mirrors `SystemProxyMode`.
package enum PrivateSystemProxyMode: String, Sendable, CaseIterable {
    case manual
    case pac
}

/// Mirrors `TunnelPreset`.
package enum PrivateTunnelPreset: String, Sendable, CaseIterable {
    case cosmosDBMongo
    case mongoDBAtlas
    case postgresql
    case mysql
    case redis
    case amqp
    case custom
}

// MARK: - Runtime values

/// `ProxyConfig.proxy`. Durations are canonical seconds.
package struct PrivateProxySettings: Sendable, Equatable {
    package var host: String
    package var port: Int
    package var socksEnabled: Bool
    package var socksPort: Int
    package var gatewayMode: Bool
    package var allowedClients: [String]
    package var maxConnections: Int
    package var stalledConnectionTimeoutSeconds: Double
    package var maxBufferedBodyBytes: Int
    package var maxSpooledBodyBytes: Int
    package var inboundConnectionWarnThreshold: Int
    package var inboundConnectionMaxLimit: Int
    package var strictMode: Bool

    package init(
        host: String, port: Int, socksEnabled: Bool, socksPort: Int, gatewayMode: Bool,
        allowedClients: [String], maxConnections: Int, stalledConnectionTimeoutSeconds: Double,
        maxBufferedBodyBytes: Int, maxSpooledBodyBytes: Int, inboundConnectionWarnThreshold: Int,
        inboundConnectionMaxLimit: Int, strictMode: Bool
    ) {
        self.host = host
        self.port = port
        self.socksEnabled = socksEnabled
        self.socksPort = socksPort
        self.gatewayMode = gatewayMode
        self.allowedClients = allowedClients
        self.maxConnections = maxConnections
        self.stalledConnectionTimeoutSeconds = stalledConnectionTimeoutSeconds
        self.maxBufferedBodyBytes = maxBufferedBodyBytes
        self.maxSpooledBodyBytes = maxSpooledBodyBytes
        self.inboundConnectionWarnThreshold = inboundConnectionWarnThreshold
        self.inboundConnectionMaxLimit = inboundConnectionMaxLimit
        self.strictMode = strictMode
    }
}

/// `ProxyConfig.auth`.
package struct PrivateAuthSettings: Sendable, Equatable {
    package var mode: PrivateAuthenticationMode
    package var username: String
    package var domain: String
    package var workstation: String
    package var pendingHandshakeGlobalLimit: Int
    package var pendingHandshakesPerSource: Int

    package init(
        mode: PrivateAuthenticationMode, username: String, domain: String, workstation: String,
        pendingHandshakeGlobalLimit: Int, pendingHandshakesPerSource: Int
    ) {
        self.mode = mode
        self.username = username
        self.domain = domain
        self.workstation = workstation
        self.pendingHandshakeGlobalLimit = pendingHandshakeGlobalLimit
        self.pendingHandshakesPerSource = pendingHandshakesPerSource
    }
}

/// One `ProxyConfig.upstreams` element.
package struct PrivateUpstreamSettings: Sendable, Equatable {
    package var id: ControlUpstreamID
    package var name: String
    package var host: String
    package var port: Int
    package var enabled: Bool
    package var priority: Int

    package init(id: ControlUpstreamID, name: String, host: String, port: Int, enabled: Bool, priority: Int) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.enabled = enabled
        self.priority = priority
    }
}

/// `ProxyConfig.routing`. `pacURL` may carry a token.
package struct PrivateRoutingSettings: Sendable, Equatable {
    package var pacURL: PrivateURLValue
    package var localPACEnabled: Bool
    package var localPACPort: Int
    package var pacRoutingEnabled: Bool
    package var pacUsableRouteLimit: Int
    package var noProxyHosts: [String]
    package var forceProxyHosts: [String]

    package init(
        pacURL: PrivateURLValue, localPACEnabled: Bool, localPACPort: Int, pacRoutingEnabled: Bool,
        pacUsableRouteLimit: Int, noProxyHosts: [String], forceProxyHosts: [String]
    ) {
        self.pacURL = pacURL
        self.localPACEnabled = localPACEnabled
        self.localPACPort = localPACPort
        self.pacRoutingEnabled = pacRoutingEnabled
        self.pacUsableRouteLimit = pacUsableRouteLimit
        self.noProxyHosts = noProxyHosts
        self.forceProxyHosts = forceProxyHosts
    }
}

/// One `DomainDNSEntry`.
package struct PrivateDNSEntrySettings: Sendable, Equatable {
    package var id: PrivateDNSEntryID
    package var domain: String
    package var servers: [String]
    package var enabled: Bool

    package init(id: PrivateDNSEntryID, domain: String, servers: [String], enabled: Bool) {
        self.id = id
        self.domain = domain
        self.servers = servers
        self.enabled = enabled
    }
}

/// One `DNSInterceptRule`.
package struct PrivateInterceptRuleSettings: Sendable, Equatable {
    package var id: PrivateInterceptRuleID
    package var pattern: String
    package var interceptIP: String
    package var enabled: Bool

    package init(id: PrivateInterceptRuleID, pattern: String, interceptIP: String, enabled: Bool) {
        self.id = id
        self.pattern = pattern
        self.interceptIP = interceptIP
        self.enabled = enabled
    }
}

/// `ProxyConfig.dns`. `dohProviders` may carry tokens.
package struct PrivateDNSSettings: Sendable, Equatable {
    package var forwarderEnabled: Bool
    package var forwarderPort: Int
    package var dohProviders: [PrivateURLValue]
    package var entries: [PrivateDNSEntrySettings]
    package var interceptRules: [PrivateInterceptRuleSettings]
    package var transparentProxyEnabled: Bool
    package var transparentProxyIP: String
    package var transparentProxyPort: Int

    package init(
        forwarderEnabled: Bool, forwarderPort: Int, dohProviders: [PrivateURLValue],
        entries: [PrivateDNSEntrySettings], interceptRules: [PrivateInterceptRuleSettings],
        transparentProxyEnabled: Bool, transparentProxyIP: String, transparentProxyPort: Int
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

/// One `TunnelDefinition`.
package struct PrivateTunnelDefinitionSettings: Sendable, Equatable {
    package var id: ControlTunnelID
    package var localPort: Int
    package var remoteHost: String
    package var remotePort: Int
    package var enabled: Bool
    package var proxied: Bool
    package var label: String
    package var preset: PrivateTunnelPreset?

    package init(
        id: ControlTunnelID, localPort: Int, remoteHost: String, remotePort: Int, enabled: Bool,
        proxied: Bool, label: String, preset: PrivateTunnelPreset?
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
}

/// `ProxyConfig.tunnels`.
package struct PrivateTunnelSettings: Sendable, Equatable {
    package var definitions: [PrivateTunnelDefinitionSettings]
    package var maxSessions: Int
    package var maxSessionsPerTunnel: Int

    package init(definitions: [PrivateTunnelDefinitionSettings], maxSessions: Int, maxSessionsPerTunnel: Int) {
        self.definitions = definitions
        self.maxSessions = maxSessions
        self.maxSessionsPerTunnel = maxSessionsPerTunnel
    }
}

/// `ProxyConfig.health`. Every duration is canonical seconds, never the legacy
/// milliseconds or minutes, so fractional values survive. `checkURL` may carry a token.
package struct PrivateHealthSettings: Sendable, Equatable {
    package var checkURL: PrivateURLValue
    package var checkIntervalSeconds: Double
    package var connectionCheckTimeoutSeconds: Double
    package var upstreamResponseTimeoutSeconds: Double
    package var upstreamConnectTimeoutSeconds: Double
    package var directConnectTTLSeconds: Double
    package var circuitBreakerWindowSeconds: Double
    package var circuitFailureThreshold: Int
    package var circuitBaseOpenIntervalSeconds: Double
    package var circuitMaxOpenIntervalSeconds: Double
    package var vpnFlapGraceSeconds: Double
    package var vpnFlapMinVisibleSeconds: Double

    package init(
        checkURL: PrivateURLValue, checkIntervalSeconds: Double, connectionCheckTimeoutSeconds: Double,
        upstreamResponseTimeoutSeconds: Double, upstreamConnectTimeoutSeconds: Double,
        directConnectTTLSeconds: Double, circuitBreakerWindowSeconds: Double, circuitFailureThreshold: Int,
        circuitBaseOpenIntervalSeconds: Double, circuitMaxOpenIntervalSeconds: Double,
        vpnFlapGraceSeconds: Double, vpnFlapMinVisibleSeconds: Double
    ) {
        self.checkURL = checkURL
        self.checkIntervalSeconds = checkIntervalSeconds
        self.connectionCheckTimeoutSeconds = connectionCheckTimeoutSeconds
        self.upstreamResponseTimeoutSeconds = upstreamResponseTimeoutSeconds
        self.upstreamConnectTimeoutSeconds = upstreamConnectTimeoutSeconds
        self.directConnectTTLSeconds = directConnectTTLSeconds
        self.circuitBreakerWindowSeconds = circuitBreakerWindowSeconds
        self.circuitFailureThreshold = circuitFailureThreshold
        self.circuitBaseOpenIntervalSeconds = circuitBaseOpenIntervalSeconds
        self.circuitMaxOpenIntervalSeconds = circuitMaxOpenIntervalSeconds
        self.vpnFlapGraceSeconds = vpnFlapGraceSeconds
        self.vpnFlapMinVisibleSeconds = vpnFlapMinVisibleSeconds
    }
}

/// `ProxyConfig.logging`. `auditLogPath` is a file path, not a URL, so it is not wrapped.
package struct PrivateLoggingSettings: Sendable, Equatable {
    package var verbose: Bool
    package var auditLogEnabled: Bool
    package var auditLogMaxBytes: Int
    package var auditLogPath: String?

    package init(verbose: Bool, auditLogEnabled: Bool, auditLogMaxBytes: Int, auditLogPath: String?) {
        self.verbose = verbose
        self.auditLogEnabled = auditLogEnabled
        self.auditLogMaxBytes = auditLogMaxBytes
        self.auditLogPath = auditLogPath
    }
}

/// Every stored runtime field of `ProxyConfig` except `schemaVersion`.
package struct PrivateRuntimeConfiguration: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    package var profileName: String
    package var proxy: PrivateProxySettings
    package var auth: PrivateAuthSettings
    package var upstreams: [PrivateUpstreamSettings]
    package var routing: PrivateRoutingSettings
    package var dns: PrivateDNSSettings
    package var tunnels: PrivateTunnelSettings
    package var health: PrivateHealthSettings
    package var logging: PrivateLoggingSettings

    package init(
        profileName: String, proxy: PrivateProxySettings, auth: PrivateAuthSettings,
        upstreams: [PrivateUpstreamSettings], routing: PrivateRoutingSettings, dns: PrivateDNSSettings,
        tunnels: PrivateTunnelSettings, health: PrivateHealthSettings, logging: PrivateLoggingSettings
    ) {
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

    package var description: String { "PrivateRuntimeConfiguration(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}

// MARK: - Platform values

/// The machine-effect fields of `PlatformIntegrationConfig`, without `launchAtLogin`.
/// That setting belongs to the app's login item, so it never crosses this boundary.
package struct PrivatePlatformConfiguration: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    package var manageSystemProxy: Bool
    package var manageEnvironmentVariables: Bool
    package var manageDNSResolvers: Bool
    package var manageSystemDNS: Bool
    package var systemProxyMode: PrivateSystemProxyMode

    package init(
        manageSystemProxy: Bool, manageEnvironmentVariables: Bool, manageDNSResolvers: Bool,
        manageSystemDNS: Bool, systemProxyMode: PrivateSystemProxyMode
    ) {
        self.manageSystemProxy = manageSystemProxy
        self.manageEnvironmentVariables = manageEnvironmentVariables
        self.manageDNSResolvers = manageDNSResolvers
        self.manageSystemDNS = manageSystemDNS
        self.systemProxyMode = systemProxyMode
    }

    package var description: String { "PrivatePlatformConfiguration(<redacted>)" }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}

// MARK: - Request

/// One runtime and platform update, as one request (decisions 0018 and 0025). It carries
/// the full frozen values of both files, never a patch.
///
/// The baselines and intents are preconditions the caller observed. `runtimeBaseline` and
/// `platformBaseline` name the exact store baselines of the two files. `modules` names, per
/// module, whether the update only saves, applies while running, or explicitly starts, and
/// the lifecycle revision that applies or starts under. None of them allocates or supplies a
/// receipt: the store assigns new versions, and only the host's answer to this `requestID`
/// reports them. Lifecycle preconditions never use the presentation revision, which advances
/// on counter traffic. `launchAtLogin` is not carried: the host keeps the stored value.
package struct PrivateConfigurationRequest: Sendable, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible, CustomReflectable
{
    package var requestID: ControlRequestID
    package var incarnation: ControlHostIncarnation
    package var budget: ControlWireBudget
    /// Always a runtime baseline: the initializer refuses another component.
    package private(set) var runtimeBaseline: PrivateBaseline
    /// Always a platform baseline: the initializer refuses another component.
    package private(set) var platformBaseline: PrivateBaseline
    package var modules: PrivateModuleSlots<PrivateModuleIntent>
    package var runtime: PrivateRuntimeConfiguration
    package var platform: PrivatePlatformConfiguration

    /// Throws `invalidValue` when a baseline names another file than its slot.
    package init(
        requestID: ControlRequestID, incarnation: ControlHostIncarnation, budget: ControlWireBudget,
        runtimeBaseline: PrivateBaseline, platformBaseline: PrivateBaseline,
        modules: PrivateModuleSlots<PrivateModuleIntent>,
        runtime: PrivateRuntimeConfiguration, platform: PrivatePlatformConfiguration
    ) throws {
        guard runtimeBaseline.component == .runtime, platformBaseline.component == .platform else {
            throw PrivateConfigurationWireError.invalidValue
        }
        self.requestID = requestID
        self.incarnation = incarnation
        self.budget = budget
        self.runtimeBaseline = runtimeBaseline
        self.platformBaseline = platformBaseline
        self.modules = modules
        self.runtime = runtime
        self.platform = platform
    }

    /// Identifiers, baselines and intents only. The values never appear in a description.
    package var description: String {
        "PrivateConfigurationRequest(requestID: \(requestID), runtimeBaseline: \(runtimeBaseline), "
            + "platformBaseline: \(platformBaseline), modules: \(modules), <redacted values>)"
    }
    package var debugDescription: String { description }
    package var customMirror: Mirror { Mirror(self, children: [("description", description)], displayStyle: .struct) }
}
