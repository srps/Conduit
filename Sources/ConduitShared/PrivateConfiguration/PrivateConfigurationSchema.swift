// SPDX-License-Identifier: Apache-2.0

// The schema of one private request body (decision 0021). The scanner walks the body against these
// tables before Foundation decodes anything: every key must be named here, every array carries its
// approved count, and every string carries the decoded-UTF-8 ceiling of its place. The names match the
// `Keys` of the wire mirrors in `PrivateConfigurationDecoder.swift`, and a test pins that they agree.
// The tables are built once. Nothing about a key is allocated while the scanner matches it.

/// The shape of one JSON value position.
indirect enum PrivateValueShape: Sendable {
    /// A non-null string under the ceiling of its field.
    case string(DomainResourceField)
    /// A string or `null`, under the ceiling of its field.
    case nullableString(DomainResourceField)
    /// `true` or `false`.
    case bool
    /// Any JSON number. Foundation decides whether it is an integer or a finite double.
    case number
    case object(PrivateObjectShape)
    /// An array of at most the field's approved count, each element of the given shape.
    case array(DomainResourceField, PrivateValueShape)
}

/// The members of one object, in a fixed order. A member's position is its bit in the scanner's
/// duplicate mask, so an object has at most 63 members.
struct PrivateObjectShape: Sendable {
    struct Member: Sendable {
        /// The member's name as ASCII bytes. Every name the schema uses is ASCII.
        let name: [UInt8]
        let shape: PrivateValueShape
    }

    let members: [Member]

    init(_ members: [(String, PrivateValueShape)]) {
        precondition(members.count <= 63, "a private object has at most 63 members")
        self.members = members.map { Member(name: Array($0.0.utf8), shape: $0.1) }
    }

    /// The mask with every member's bit set.
    var allMembers: UInt64 {
        (1 << UInt64(members.count)) - 1
    }

    /// The candidates whose name still matches the decoded key at `index`, with `byte` as that byte.
    func narrow(_ candidates: UInt64, at index: Int, to byte: UInt8) -> UInt64 {
        var result: UInt64 = 0
        for (position, member) in members.enumerated() where candidates & (1 << UInt64(position)) != 0 {
            if index < member.name.count, member.name[index] == byte {
                result |= 1 << UInt64(position)
            }
        }
        return result
    }

    /// The one candidate whose whole name is `length` bytes long, or nil when a candidate is only a prefix.
    func member(among candidates: UInt64, length: Int) -> Int? {
        members.indices.first { position in
            candidates & (1 << UInt64(position)) != 0 && members[position].name.count == length
        }
    }
}

/// The schema of the private request. The root object is the request, and each nested object is named
/// by the wire mirror that decodes it.
enum PrivateConfigurationSchema {
    private static let tokenValue = PrivateValueShape.string(.token)
    private static let numberValue = PrivateValueShape.number
    private static let boolValue = PrivateValueShape.bool

    static let request = PrivateObjectShape([
        ("requestID", tokenValue),
        ("incarnation", tokenValue),
        ("budgetMilliseconds", numberValue),
        ("expectedConfigRevision", numberValue),
        ("expectedPlatformRevision", numberValue),
        ("expectedOwnerGeneration", numberValue),
        ("runtime", .object(runtime)),
        ("platform", .object(platform)),
    ])

    static let runtime = PrivateObjectShape([
        ("profileName", .string(.profileName)),
        ("proxy", .object(proxy)),
        ("auth", .object(auth)),
        ("upstreams", .array(.upstreams, .object(upstream))),
        ("routing", .object(routing)),
        ("dns", .object(dns)),
        ("tunnels", .object(tunnels)),
        ("health", .object(health)),
        ("logging", .object(logging)),
    ])

    static let proxy = PrivateObjectShape([
        ("host", .string(.proxyHost)),
        ("port", numberValue),
        ("socksEnabled", boolValue),
        ("socksPort", numberValue),
        ("gatewayMode", boolValue),
        ("allowedClients", .array(.allowedClients, .string(.allowedClient))),
        ("maxConnections", numberValue),
        ("stalledConnectionTimeoutSeconds", numberValue),
        ("maxBufferedBodyBytes", numberValue),
        ("maxSpooledBodyBytes", numberValue),
        ("inboundConnectionWarnThreshold", numberValue),
        ("inboundConnectionMaxLimit", numberValue),
        ("strictMode", boolValue),
    ])

    static let auth = PrivateObjectShape([
        ("mode", tokenValue),
        ("username", .string(.authUsername)),
        ("domain", .string(.authDomain)),
        ("workstation", .string(.authWorkstation)),
        ("pendingHandshakeGlobalLimit", numberValue),
        ("pendingHandshakesPerSource", numberValue),
    ])

    static let upstream = PrivateObjectShape([
        ("id", tokenValue),
        ("name", .string(.upstreamName)),
        ("host", .string(.upstreamHost)),
        ("port", numberValue),
        ("enabled", boolValue),
        ("priority", numberValue),
    ])

    static let routing = PrivateObjectShape([
        ("pacURL", .string(.pacURL)),
        ("localPACEnabled", boolValue),
        ("localPACPort", numberValue),
        ("pacRoutingEnabled", boolValue),
        ("pacUsableRouteLimit", numberValue),
        ("noProxyHosts", .array(.noProxyHosts, .string(.noProxyPattern))),
        ("forceProxyHosts", .array(.forceProxyHosts, .string(.forceProxyPattern))),
    ])

    static let dns = PrivateObjectShape([
        ("forwarderEnabled", boolValue),
        ("forwarderPort", numberValue),
        ("dohProviders", .array(.dohProviders, .string(.dohProvider))),
        ("entries", .array(.dnsEntries, .object(dnsEntry))),
        ("interceptRules", .array(.interceptRules, .object(interceptRule))),
        ("transparentProxyEnabled", boolValue),
        ("transparentProxyIP", .string(.transparentProxyIP)),
        ("transparentProxyPort", numberValue),
    ])

    static let dnsEntry = PrivateObjectShape([
        ("id", tokenValue),
        ("domain", .string(.dnsDomain)),
        ("servers", .array(.dnsServers, .string(.dnsServer))),
        ("enabled", boolValue),
    ])

    static let interceptRule = PrivateObjectShape([
        ("id", tokenValue),
        ("pattern", .string(.interceptPattern)),
        ("interceptIP", .string(.interceptAddress)),
        ("enabled", boolValue),
    ])

    static let tunnels = PrivateObjectShape([
        ("definitions", .array(.tunnelDefinitions, .object(tunnelDefinition))),
        ("maxSessions", numberValue),
        ("maxSessionsPerTunnel", numberValue),
    ])

    static let tunnelDefinition = PrivateObjectShape([
        ("id", tokenValue),
        ("localPort", numberValue),
        ("remoteHost", .string(.tunnelRemoteHost)),
        ("remotePort", numberValue),
        ("enabled", boolValue),
        ("proxied", boolValue),
        ("label", .string(.tunnelLabel)),
        ("preset", .nullableString(.token)),
    ])

    static let health = PrivateObjectShape([
        ("checkURL", .string(.checkURL)),
        ("checkIntervalSeconds", numberValue),
        ("connectionCheckTimeoutSeconds", numberValue),
        ("upstreamResponseTimeoutSeconds", numberValue),
        ("upstreamConnectTimeoutSeconds", numberValue),
        ("directConnectTTLSeconds", numberValue),
        ("circuitBreakerWindowSeconds", numberValue),
        ("circuitFailureThreshold", numberValue),
        ("circuitBaseOpenIntervalSeconds", numberValue),
        ("circuitMaxOpenIntervalSeconds", numberValue),
        ("vpnFlapGraceSeconds", numberValue),
        ("vpnFlapMinVisibleSeconds", numberValue),
    ])

    static let logging = PrivateObjectShape([
        ("verbose", boolValue),
        ("auditLogEnabled", boolValue),
        ("auditLogMaxBytes", numberValue),
        ("auditLogPath", .nullableString(.auditLogPath)),
    ])

    static let platform = PrivateObjectShape([
        ("manageSystemProxy", boolValue),
        ("manageEnvironmentVariables", boolValue),
        ("manageDNSResolvers", boolValue),
        ("manageSystemDNS", boolValue),
        ("systemProxyMode", tokenValue),
    ])
}
