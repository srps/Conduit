// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

// The configuration files' known-key tables (decisions 0024 and 0026). Every table is built from the real `CodingKeys` of the
// decoder that reads it, through an exhaustive switch: a key added to a `CodingKeys` enum does not compile until it has a
// shape here. A shape says which JSON kind a key takes and which resource field charges its strings and lists. It never says
// what a value means: `ProxyConfig.validate` and the typed decoders keep that. A root names its file kind: its physical
// budget, its table and whether a wrong-kind legacy value falls back.

/// The decoder that owns a known key. Only the runtime file's own keys are always read. The legacy components are read
/// only when their sidecar is absent, so their keys are not in the table otherwise. A sidecar's keys carry its own component.
package enum ConfigurationComponent: Sendable, Hashable {
    case runtime
    case platform
    case preferences
}

/// Which required components a runtime read must keep, derived from the sidecars that exist.
package struct RuntimeFileRequirements: Sendable, Equatable {
    package var platform: Bool
    package var preferences: Bool

    /// Only the runtime file: import, argv and headless loads with no legacy component to extract.
    package static let runtimeOnly = RuntimeFileRequirements(platform: false, preferences: false)

    /// The decoder key that carries these requirements to the envelope, so it builds only the components this read keeps.
    static let userInfoKey = CodingUserInfoKey(rawValue: "conduit.runtimeFileRequirements")!

    package init(platform: Bool, preferences: Bool) {
        self.platform = platform
        self.preferences = preferences
    }
}

/// The JSON kind a known key accepts, and for a string the resource field that charges it. Null is accepted for every
/// shape: each typed decoder reads null as absent (`decodeIfPresent`), and a required key that is null is left to
/// Foundation to refuse.
indirect enum ConfigurationValueShape: Sendable {
    /// A string under its resource ceiling.
    case string(DomainResourceField)
    /// A string whose value its typed decoder judges: an enum raw value or a UUID. It has no product ceiling of its own.
    /// The physical file cap bounds it, and the decoder refuses a value it cannot read.
    case decodedString
    case number
    case bool
    /// An array of strings. Each item is charged to its ceiling and the list to its count and canonical width.
    case stringArray(count: DomainResourceField, item: DomainResourceField)
    /// An array of objects. The count is charged before each element, and each element is read against `members`.
    case objectArray(count: DomainResourceField, members: ConfigurationObjectSchema)

    /// Whether a value that starts with `byte` has this shape's JSON kind. Null is handled by the caller.
    func accepts(_ byte: UInt8) -> Bool {
        switch self {
        case .string, .decodedString:
            byte == UInt8(ascii: "\"")
        case .number:
            byte == UInt8(ascii: "-") || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
        case .bool:
            byte == UInt8(ascii: "t") || byte == UInt8(ascii: "f")
        case .stringArray, .objectArray:
            byte == UInt8(ascii: "[")
        }
    }
}

/// One known key of an object: its file name, the component that reads it and its shape.
package struct ConfigurationMember: Sendable {
    let name: String
    let component: ConfigurationComponent
    let shape: ConfigurationValueShape
}

/// The known members of one object. A member is matched by its name's UTF-8 bytes, so a key is found without building a
/// `String`. The first member for a name wins, and a later member with the same name is never reached.
package struct ConfigurationObjectSchema: Sendable {
    let members: [ConfigurationMember]
    /// The longest name, which bounds the buffer a key is matched into.
    let longestName: Int
    private let slots: [[UInt8]: Int]

    init(_ declared: [ConfigurationMember]) {
        var members: [ConfigurationMember] = []
        var slots: [[UInt8]: Int] = [:]
        for member in declared {
            let name = Array(member.name.utf8)
            guard slots[name] == nil else { continue }
            slots[name] = members.count
            members.append(member)
        }
        self.members = members
        self.slots = slots
        longestName = members.map { $0.name.utf8.count }.max() ?? 0
    }

    /// The member slot for a decoded key, or nil when the key is not known.
    func slot(for name: [UInt8]) -> Int? {
        slots[name]
    }
}

/// One file kind the gate reads. The reader bounds it by `maximumBytes` before any byte is filtered, and the filter reads it
/// against `object`.
package struct ConfigurationFileRoot: Sendable {
    /// The physical budget of the file, enforced by the reader on the bytes it takes.
    package let maximumBytes: Int
    /// The known keys of the file's top-level object.
    package let object: ConfigurationObjectSchema
    /// Whether a wrong-kind value under a legacy component falls back to that component's defaults. Only the runtime file has
    /// legacy components, and its extraction always fell back (decision 0021). A sidecar has no legacy source, so a wrong-kind
    /// value refuses its file explicitly, and nothing falls back (decision 0026).
    package let fallsBackToLegacyComponents: Bool
}

/// The configuration files' schemas: the runtime file, and each sidecar that holds its own settings.
package enum ConfigurationFileSchema {
    /// The runtime file's root: the runtime keys, plus each legacy component whose sidecar is absent.
    package static func runtime(_ requirements: RuntimeFileRequirements) -> ConfigurationFileRoot {
        var members = runtimeMembers
        if requirements.platform {
            members += platformMembers
        }
        if requirements.preferences {
            members += preferenceMembers
        }
        return ConfigurationFileRoot(
            maximumBytes: ConfigurationFileReader.maximumBytes,
            object: ConfigurationObjectSchema(members),
            fallsBackToLegacyComponents: true
        )
    }

    /// The platform sidecar's root: its own keys, read from its own file under the sidecar budget (decision 0026).
    package static let platformSidecar = ConfigurationFileRoot(
        maximumBytes: DomainResourceLimits.sidecarFileBytes,
        object: ConfigurationObjectSchema(platformMembers),
        fallsBackToLegacyComponents: false
    )

    /// The preferences sidecar's root, under the same budget as the platform sidecar.
    package static let preferencesSidecar = ConfigurationFileRoot(
        maximumBytes: DomainResourceLimits.sidecarFileBytes,
        object: ConfigurationObjectSchema(preferenceMembers),
        fallsBackToLegacyComponents: false
    )

    private static var runtimeMembers: [ConfigurationMember] {
        ProxyConfig.CodingKeys.allCases.map { key in
            ConfigurationMember(name: key.stringValue, component: .runtime, shape: runtimeShape(key))
        }
    }

    private static var platformMembers: [ConfigurationMember] {
        PlatformIntegrationConfig.CodingKeys.allCases.map { key in
            ConfigurationMember(name: key.stringValue, component: .platform, shape: platformShape(key))
        }
    }

    private static var preferenceMembers: [ConfigurationMember] {
        AppPreferences.CodingKeys.allCases.map { key in
            ConfigurationMember(name: key.stringValue, component: .preferences, shape: preferenceShape(key))
        }
    }

    private static let upstreamTable = ConfigurationObjectSchema(UpstreamProxy.CodingKeys.allCases.map { key in
        ConfigurationMember(name: key.stringValue, component: .runtime, shape: upstreamShape(key))
    })

    private static let dnsEntryTable = ConfigurationObjectSchema(DomainDNSEntry.CodingKeys.allCases.map { key in
        ConfigurationMember(name: key.stringValue, component: .runtime, shape: dnsEntryShape(key))
    })

    private static let interceptRuleTable = ConfigurationObjectSchema(DNSInterceptRule.CodingKeys.allCases.map { key in
        ConfigurationMember(name: key.stringValue, component: .runtime, shape: interceptRuleShape(key))
    })

    private static let tunnelTable = ConfigurationObjectSchema(TunnelDefinition.CodingKeys.allCases.map { key in
        ConfigurationMember(name: key.stringValue, component: .runtime, shape: tunnelShape(key))
    })

    // MARK: - Runtime keys

    private static func runtimeShape(_ key: ProxyConfig.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .schemaVersion, .localPort, .socksPort, .pendingAuthHandshakeGlobalLimit, .pendingAuthHandshakesPerSource,
             .localPACPort, .pacUsableRouteLimit, .healthCheckIntervalSeconds, .stalledConnectionTimeoutSeconds,
             .maxConnections, .connectionCheckTimeoutMS, .upstreamResponseTimeoutSeconds, .upstreamConnectTimeoutSeconds,
             .directConnectTTLMinutes, .circuitBreakerWindowSeconds, .circuitFailureThreshold,
             .circuitBaseOpenIntervalSeconds, .circuitMaxOpenIntervalSeconds, .vpnFlapGraceSeconds,
             .vpnFlapMinVisibleSeconds, .maxBufferedBodyBytes, .maxSpooledBodyBytes, .inboundConnectionWarnThreshold,
             .inboundConnectionMaxLimit, .auditLogMaxBytes, .dnsForwarderPort, .maxTunnelSessions,
             .maxSessionsPerTunnel, .transparentProxyPort:
            .number
        case .socksEnabled, .localPACEnabled, .pacRoutingEnabled, .strictMode, .verboseLogging, .auditLogEnabled,
             .gatewayMode, .dnsForwarderEnabled, .transparentProxyEnabled:
            .bool
        case .authMode:
            .decodedString
        case .profileName: .string(.profileName)
        case .localHost: .string(.proxyHost)
        case .username: .string(.authUsername)
        case .domain: .string(.authDomain)
        case .workstation: .string(.authWorkstation)
        case .pacURL: .string(.pacURL)
        case .healthCheckURL: .string(.checkURL)
        case .transparentProxyIP: .string(.transparentProxyIP)
        case .auditLogPath: .string(.auditLogPath)
        case .upstreams: .objectArray(count: .upstreams, members: upstreamTable)
        case .dnsEntries: .objectArray(count: .dnsEntries, members: dnsEntryTable)
        case .dnsInterceptRules: .objectArray(count: .interceptRules, members: interceptRuleTable)
        case .tunnelDefinitions: .objectArray(count: .tunnelDefinitions, members: tunnelTable)
        case .noProxyHosts: .stringArray(count: .noProxyHosts, item: .noProxyPattern)
        case .forceProxyHosts: .stringArray(count: .forceProxyHosts, item: .forceProxyPattern)
        case .allowedClients: .stringArray(count: .allowedClients, item: .allowedClient)
        case .dohProviders: .stringArray(count: .dohProviders, item: .dohProvider)
        }
    }

    private static func upstreamShape(_ key: UpstreamProxy.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .id: .decodedString
        case .name: .string(.upstreamName)
        case .host: .string(.upstreamHost)
        case .port, .priority: .number
        case .enabled: .bool
        }
    }

    private static func dnsEntryShape(_ key: DomainDNSEntry.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .id: .decodedString
        case .domain: .string(.dnsDomain)
        case .servers: .stringArray(count: .dnsServers, item: .dnsServer)
        case .enabled: .bool
        }
    }

    private static func interceptRuleShape(_ key: DNSInterceptRule.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .id: .decodedString
        case .pattern: .string(.interceptPattern)
        case .interceptIP: .string(.interceptAddress)
        case .enabled: .bool
        }
    }

    private static func tunnelShape(_ key: TunnelDefinition.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .id, .preset: .decodedString
        case .localPort, .remotePort: .number
        case .remoteHost: .string(.tunnelRemoteHost)
        case .enabled, .proxied: .bool
        case .label: .string(.tunnelLabel)
        }
    }

    // MARK: - Legacy components and sidecars

    private static func platformShape(_ key: PlatformIntegrationConfig.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .systemProxyMode: .decodedString
        case .manageSystemProxy, .manageEnvironmentVariables, .manageDNSResolvers, .manageSystemDNS, .launchAtLogin: .bool
        }
    }

    private static func preferenceShape(_ key: AppPreferences.CodingKeys) -> ConfigurationValueShape {
        switch key {
        case .preferredBrowserTestURL: .string(.browserTestURL)
        case .showMenuBarIcon, .floatingWindowEnabled, .globalShortcutEnabled, .fileLoggingEnabled, .automaticUpdateChecks:
            .bool
        }
    }
}
