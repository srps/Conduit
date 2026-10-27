// SPDX-License-Identifier: Apache-2.0

// The schema of the private bodies (decision 0021). Each frame kind has one root table, and the scanner
// walks a body against it before Foundation decodes anything: every key must be named here, every array
// carries its approved count, and every string carries the decoded-UTF-8 ceiling of its place. The names
// match the `Keys` of the wire mirrors in `PrivateConfigurationDecoder.swift`, and a test pins that they
// agree. The tables are built once. Nothing about a key is allocated while the scanner matches it.

/// The shape of one JSON value position.
indirect enum PrivateValueShape: Sendable {
    /// A non-null string under the ceiling of its field.
    case string(DomainResourceField)
    /// `null`, or one value of the wrapped shape. The member is still required: an absent key is refused.
    case nullable(PrivateValueShape)
    /// `true` or `false`.
    case bool
    /// Any JSON number. Foundation decides whether it is an integer or a finite double.
    case number
    /// An exact `UInt64` spelled as plain decimal digits: no sign, fraction or exponent, no leading zero, at most 20
    /// digits and no more than `UInt64.max`. The scanner refuses any other spelling, so no Foundation number rule can
    /// round, widen or narrow it.
    case unsignedDecimal
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

/// The schema of the private bodies. `request`, `preferencesRequest`, `readRequest` and `editorReply` are the roots of the
/// four frame kinds, and each nested object is named by the wire mirror that decodes it.
enum PrivateConfigurationSchema {
    private static let tokenValue = PrivateValueShape.string(.token)
    private static let numberValue = PrivateValueShape.number
    private static let boolValue = PrivateValueShape.bool

    static let request = PrivateObjectShape([
        ("requestID", tokenValue),
        ("incarnation", tokenValue),
        ("budgetMilliseconds", numberValue),
        ("runtimeBaseline", .object(baseline)),
        ("platformBaseline", .object(baseline)),
        ("modules", .object(moduleIntents)),
        ("runtime", .object(runtime)),
        ("platform", .object(platform)),
    ])

    /// The preferences update: identity, budget, the preferences file's exact baseline and its full frozen values.
    static let preferencesRequest = PrivateObjectShape([
        ("requestID", tokenValue),
        ("incarnation", tokenValue),
        ("budgetMilliseconds", numberValue),
        ("preferencesBaseline", .object(baseline)),
        ("preferences", .object(preferences)),
    ])

    /// The read request: identity and budget only.
    static let readRequest = PrivateObjectShape([
        ("requestID", tokenValue),
        ("incarnation", tokenValue),
        ("budgetMilliseconds", numberValue),
    ])

    /// The editor reply. All three answers are required members, and exactly one is not null; the decoder refuses any
    /// other combination.
    static let editorReply = PrivateObjectShape([
        ("requestID", tokenValue),
        ("hostIncarnation", tokenValue),
        ("admission", .nullable(.object(admission))),
        ("observation", .nullable(.object(observation))),
        ("refusal", .nullable(tokenValue)),
    ])

    /// The members `ControlAdmission`'s own `Codable` writes. Which of them a variant carries is that type's rule: the
    /// decoder compares the member set with the one its own encoding writes, so this table only names the keys.
    static let admission = PrivateObjectShape([
        ("type", tokenValue),
        ("operation", tokenValue),
        ("rejection", tokenValue),
    ])

    static let observation = PrivateObjectShape([
        ("terminal", boolValue),
        ("runtime", .object(runtime)),
        ("platform", .object(platform)),
        ("preferences", .object(preferences)),
        ("launchAtLogin", boolValue),
        ("components", .object(componentStates)),
        ("modules", .object(moduleStates)),
    ])

    static let preferences = PrivateObjectShape([
        ("showMenuBarIcon", boolValue),
        ("floatingWindowEnabled", boolValue),
        ("globalShortcutEnabled", boolValue),
        ("preferredBrowserTestURL", .string(.browserTestURL)),
        ("fileLoggingEnabled", boolValue),
        ("automaticUpdateChecks", boolValue),
    ])

    static let componentStates = PrivateObjectShape([
        ("runtime", .object(componentState)),
        ("platform", .object(componentState)),
        ("preferences", .object(componentState)),
    ])

    /// `state` is a `PrivateComponentStateKind` raw value. `baseline` is present for verified and absent and null for
    /// retained; `reason`, a `PrivateRetainedReason` raw value, is the reverse. The decoder refuses any other pairing.
    static let componentState = PrivateObjectShape([
        ("state", tokenValue),
        ("baseline", .nullable(.object(baseline))),
        ("reason", .nullable(tokenValue)),
    ])

    static let moduleStates = PrivateObjectShape([
        ("proxy", .object(moduleState)),
        ("dns", .object(moduleState)),
        ("tunnels", .object(moduleState)),
    ])

    static let moduleState = PrivateObjectShape([
        ("lifecycleRevision", numberValue),
        ("enabled", boolValue),
        ("fenced", boolValue),
    ])

    /// One exact store baseline. `component` is a `ControlConfigWorkflowFile` raw value.
    static let baseline = PrivateObjectShape([
        ("namespace", tokenValue),
        ("component", tokenValue),
        ("version", .unsignedDecimal),
    ])

    static let moduleIntents = PrivateObjectShape([
        ("proxy", .object(moduleIntent)),
        ("dns", .object(moduleIntent)),
        ("tunnels", .object(moduleIntent)),
    ])

    /// `action` is a `PrivateModuleIntentAction` raw value. `lifecycleRevision` is null for a save-only intent and a
    /// revision for the others; the decoder refuses any other pairing.
    static let moduleIntent = PrivateObjectShape([
        ("action", tokenValue),
        ("lifecycleRevision", .nullable(numberValue)),
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
        ("preset", .nullable(tokenValue)),
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
        ("auditLogPath", .nullable(.string(.auditLogPath))),
    ])

    static let platform = PrivateObjectShape([
        ("manageSystemProxy", boolValue),
        ("manageEnvironmentVariables", boolValue),
        ("manageDNSResolvers", boolValue),
        ("manageSystemDNS", boolValue),
        ("systemProxyMode", tokenValue),
    ])
}

/// The wire spelling of a `PrivateModuleIntent` case. The encoder and the decoder share it, so neither spells it alone.
enum PrivateModuleIntentAction: String, CaseIterable {
    case saveOnly
    case applyWhileRunning
    case start
}

/// The wire spelling of a `PrivateComponentState` case.
enum PrivateComponentStateKind: String, CaseIterable {
    case verified
    case absent
    case retained
}
