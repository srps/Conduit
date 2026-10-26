// Synthetic sizing and lifetime experiment for the private editor reply cap decision. NOT product code, NOT a selected
// budget, NOT the future reply codec. It links the existing release objects with `-package-name conduit` and calls
// pure functions only: no RuntimeEnvironment, store, session, socket, helper, network, login item, keychain or file write.
// It prints numeric JSON records (labels, counts, metrics) to stdout and never prints a fixture string.
//
// Modes (one fresh process each): small | string-maximum | unique-maximum | repeat. Anything else fails.
//
//   small           every collection at its approved count, short valid strings, longest enums, every optional present,
//                   every Bool false. It calibrates the numeric/string/bool inventory against the production body.
//   string-maximum  every resource-bounded text at its decoded UTF-8 ceiling, every byte U+0001 (six wire bytes, the
//                   widest escape) except the required `*.` wildcard prefix and one ASCII byte the 8,192-byte bypass
//                   aggregate needs to land exactly. Equal strings share storage. A sizing superset of storable repair
//                   drafts, not an eligibility claim. Numbers stay at accepted schema-two defaults.
//   unique-maximum  the same counts and byte ceilings, but every text is distinct: a three-symbol tag drawn from the 26
//                   control bytes that also escape to six bytes, so the wire width equals string-maximum exactly.
//   repeat          20 sequential scoped unique-maximum pipelines, sampled after each release.
//
// The conservative request bound is the production `measureBody` of string-maximum, plus a numeric allowance: every
// numeric lexeme the production body actually contains (counted by a lexer that skips quoted strings) is charged at its
// widest form instead of its default bytes. The reply bound adds the exact widest preferences object, a lexeme-charged
// allowance over a probe-local MIRROR of the metadata (three component states with exact baselines, three module intents,
// incarnation, generation, launch-at-login and one causal receipt with draft identity) and an envelope allowance. See the
// numeric-allowance comment for the Double proof.
//
// Lifetime limits: the stages measure the REQUEST codec only (bridge, encode, read, decode, map back). The "previous" value
// is rebuilt after decode, so an owner value retained through encode/read/decode is not modelled. Live samples sit between
// stages; transient copies inside a stage show only in the monotonic high-water fields. None of this is a whole-host peak,
// a future reply codec measurement or Stop/status fairness evidence.

import Darwin
import Foundation
import ProxyKernel
import ProxyControlBridge
import ConduitShared

// `ProxyConfigPersistence.stagedFile` (its verification decode) and `ProxyConfigPersistence.decode` construct
// `ProxyConfig.init(from:)`, which initializes `GenericDefaults.shared` → `AuthSection()` → `NSUserName()` and
// `ProcessInfo.processInfo.hostName`. The parent approved that read-only default read (2026-10-26): every fixture sets
// every identity, host and configuration string explicitly, so no default value reaches a fixture, and nothing is logged.
// The staged byte count is also measured with stagedFile's own encoder call (`CanonicalJSON.encoder(prettyPrinted: true)`).
let defaultsInitializingDecodeAllowed = true

// MARK: - Modes and fixtures

enum ProbeMode: String {
    case small
    case stringMaximum = "string-maximum"
    case uniqueMaximum = "unique-maximum"
    case repeatMaximum = "repeat"
}

enum SyntheticFixture: String {
    case small
    case stringMaximum = "string-maximum"
    case uniqueMaximum = "unique-maximum"

    var isMaximum: Bool { self != .small }
}

let repeatIterations = 20
/// `String(Int.min)`, checked at run time. Covers every `Int` and `UInt64` the writers emit.
let intLexemeMaximumBytes = 20
/// Any finite IEEE 754 binary64 value is m·2^k with integer |m| < 2^53 and k ≥ −1074. For k ≥ 0 it is an integer below
/// 2^1024 < 10^309: at most 309 digits, plus sign and a `.0` suffix, 312 bytes. For k < 0 it is m·5^−k / 10^−k: at most
/// 1,074 fractional digits, and |x| < 2^53 gives at most 16 integer digits, so sign + 16 + `.` + 1,074 = 1,092 bytes for the
/// exact positional expansion. Any scientific spelling of that expansion has at most as many significant digits plus a
/// five-byte exponent. 1,100 therefore bounds the exact expansion without assuming Swift's shortest round-trip format.
/// It does not bound a writer that pads or repeats digits; the production writer is `String(value)`.
let doubleLexemeMaximumBytes = 1_100

func syntheticUUID(_ family: Int, _ index: Int) -> UUID {
    func hex(_ value: Int, _ width: Int) -> String {
        let digits = String(value, radix: 16, uppercase: true)
        return String(repeating: "0", count: width - digits.count) + digits
    }
    return UUID(uuidString: "\(hex(family, 8))-0000-4000-8000-\(hex(index, 12))")!
}

let longestAuthMode = AuthenticationMode.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!
let longestSystemProxyMode = SystemProxyMode.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!
let longestPreset = TunnelPreset.allCases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!

/// Control bytes the private writer and `CanonicalJSONWidth` both spell as `\u00XX`: 0x01...0x1F without the five short
/// escapes. NUL is excluded. 26 symbols.
let sixByteSymbols: [Unicode.Scalar] = (UInt8(0x01)...UInt8(0x1F))
    .filter { ![0x08, 0x09, 0x0A, 0x0C, 0x0D].contains($0) }
    .map { Unicode.Scalar($0) }

func isSixByteEscape(_ byte: UInt8) -> Bool {
    byte < 0x20 && ![0x08, 0x09, 0x0A, 0x0C, 0x0D].contains(byte)
}

/// Builds fixture text with exact decoded UTF-8 lengths. Shared mode returns one stored string per shape, so arrays share
/// storage. Unique mode gives every value its own tag and its own allocation.
final class SyntheticText {
    let unique: Bool
    private var nextTag = 0
    private var shared: [String: String] = [:]

    init(unique: Bool) {
        self.unique = unique
    }

    func text(_ bytes: Int, prefix: String = "") -> String {
        let fill = bytes - prefix.utf8.count
        let value: String
        if unique {
            precondition(fill >= 3, "a unique value needs room for its tag")
            var tag = nextTag
            nextTag += 1
            var scalars = String.UnicodeScalarView()
            for _ in 0..<3 {
                scalars.append(sixByteSymbols[tag % sixByteSymbols.count])
                tag /= sixByteSymbols.count
            }
            precondition(tag == 0, "tag space exhausted")
            value = prefix + String(scalars) + String(repeating: "\u{01}", count: fill - 3)
        } else {
            let key = "\(prefix)#\(bytes)"
            if let cached = shared[key] {
                value = cached
            } else {
                value = prefix + String(repeating: "\u{01}", count: fill)
                shared[key] = value
            }
        }
        precondition(value.utf8.count == bytes, "fixture text length")
        return value
    }
}

/// The bypass list content budget at the aggregate ceiling: brackets, commas and quotes are fixed, the rest is content.
func noProxyContentBudget() -> (symbols: Int, asciiBytes: Int) {
    let count = DomainResourceLimits.noProxyHosts
    let content = DomainResourceLimits.noProxyList - 2 - (count - 1) - 2 * count
    return (content / 6, content % 6)
}

/// 256 entries whose canonical JSON width is exactly the 8,192-byte aggregate. Every byte is a six-byte escape except the
/// remainder, which is ASCII on the first entry.
func maximumNoProxyHosts(_ text: SyntheticText) -> [String] {
    let count = DomainResourceLimits.noProxyHosts
    let budget = noProxyContentBudget()
    let base = budget.symbols / count
    let extra = budget.symbols % count
    return (0..<count).map { index in
        var host = text.text(base + (index < extra ? 1 : 0))
        if index == 0 {
            host += String(repeating: "x", count: budget.asciiBytes)
        }
        return host
    }
}

/// The source's default `AuthSection` numbers, given explicitly: `AuthSection()` would read `NSUserName()` and the host name.
func syntheticAuth(username: String, domain: String, workstation: String) -> AuthSection {
    AuthSection(mode: longestAuthMode, username: username, domain: domain, workstation: workstation,
                pendingHandshakeGlobalLimit: 512, pendingHandshakesPerSource: 128)
}

func makeSmallConfig() -> ProxyConfig {
    let limits = DomainResourceLimits.self
    var proxy = ProxySection()
    proxy.host = "127.0.0.1"
    proxy.socksEnabled = false
    proxy.gatewayMode = false
    proxy.strictMode = false
    proxy.allowedClients = (0..<limits.allowedClients).map { "10.0.\($0 / 256).\($0 % 256)" }
    let upstreams = (0..<limits.upstreams).map { index in
        UpstreamProxy(id: syntheticUUID(1, index), name: "u\(index)", host: "proxy\(index).example.test",
                      port: 3128, enabled: false, priority: index)
    }
    var routing = RoutingSection()
    routing.pacURL = "https://pac.example.test/proxy.pac"
    routing.localPACEnabled = false
    routing.pacRoutingEnabled = false
    routing.noProxyHosts = (0..<limits.noProxyHosts).map { "np\($0).example" }
    routing.forceProxyHosts = (0..<limits.forceProxyHosts).map { "fp\($0).example" }
    var dns = DNSSection()
    dns.forwarderEnabled = false
    dns.transparentProxyEnabled = false
    dns.dohProviders = (0..<limits.dohProviders).map { "https://192.0.2.\($0 + 1)/dns-query" }
    dns.entries = (0..<limits.dnsEntries).map { index in
        DomainDNSEntry(id: syntheticUUID(2, index), domain: "d\(index).example",
                       servers: (0..<limits.dnsServers).map { "192.0.2.\($0 + 1)" }, enabled: false)
    }
    dns.interceptRules = (0..<limits.interceptRules).map { index in
        DNSInterceptRule(id: syntheticUUID(3, index), pattern: "*.i\(index).example", interceptIP: "127.44.3.0", enabled: false)
    }
    var tunnels = TunnelSection()
    tunnels.definitions = (0..<limits.tunnelDefinitions).map { index in
        TunnelDefinition(id: syntheticUUID(4, index), localPort: 12000 + index, remoteHost: "t\(index).example",
                         remotePort: 443, enabled: false, proxied: false, label: "t\(index)", preset: longestPreset)
    }
    var logging = LoggingSection()
    logging.verbose = false
    logging.auditLogEnabled = false
    logging.auditLogPath = "/nonexistent/conduit-synthetic/audit.ndjson"
    return ProxyConfig(
        schemaVersion: ProxyConfig.currentSchemaVersion, profileName: "small-synthetic", proxy: proxy,
        auth: syntheticAuth(username: "synthetic-user", domain: "SYNTHETIC", workstation: "synthetic-ws"),
        upstreams: upstreams, routing: routing, dns: dns, tunnels: tunnels, health: HealthSection(), logging: logging
    )
}

func makeMaximumConfig(_ text: SyntheticText) -> ProxyConfig {
    let limits = DomainResourceLimits.self
    let wildcard = String(decoding: limits.wildcardPrefix, as: UTF8.self)
    let profileName = text.text(limits.displayText)
    var proxy = ProxySection()
    proxy.socksEnabled = false
    proxy.gatewayMode = false
    proxy.strictMode = false
    proxy.host = text.text(limits.hostText)
    proxy.allowedClients = (0..<limits.allowedClients).map { _ in text.text(limits.hostText) }
    let auth = syntheticAuth(username: text.text(limits.identity), domain: text.text(limits.identity),
                             workstation: text.text(limits.identity))
    let upstreams = (0..<limits.upstreams).map { index in
        UpstreamProxy(id: syntheticUUID(1, index), name: text.text(limits.displayText), host: text.text(limits.hostText),
                      port: 3128, enabled: false, priority: index)
    }
    var routing = RoutingSection()
    routing.localPACEnabled = false
    routing.pacRoutingEnabled = false
    routing.pacURL = text.text(limits.urlText)
    routing.noProxyHosts = maximumNoProxyHosts(text)
    routing.forceProxyHosts = (0..<limits.forceProxyHosts).map { _ in text.text(limits.hostText) }
    var dns = DNSSection()
    dns.forwarderEnabled = false
    dns.transparentProxyEnabled = false
    dns.dohProviders = (0..<limits.dohProviders).map { _ in text.text(limits.urlText) }
    dns.entries = (0..<limits.dnsEntries).map { index in
        DomainDNSEntry(id: syntheticUUID(2, index), domain: text.text(limits.hostText),
                       servers: (0..<limits.dnsServers).map { _ in text.text(limits.hostText) }, enabled: false)
    }
    dns.interceptRules = (0..<limits.interceptRules).map { index in
        DNSInterceptRule(id: syntheticUUID(3, index), pattern: text.text(limits.wildcardInterceptPattern, prefix: wildcard),
                         interceptIP: text.text(limits.hostText), enabled: false)
    }
    dns.transparentProxyIP = text.text(limits.hostText)
    var tunnels = TunnelSection()
    tunnels.definitions = (0..<limits.tunnelDefinitions).map { index in
        TunnelDefinition(id: syntheticUUID(4, index), localPort: 12000 + index, remoteHost: text.text(limits.hostText),
                         remotePort: 443, enabled: false, proxied: false, label: text.text(limits.displayText),
                         preset: longestPreset)
    }
    var health = HealthSection()
    health.checkURL = text.text(limits.urlText)
    var logging = LoggingSection()
    logging.verbose = false
    logging.auditLogEnabled = false
    logging.auditLogPath = text.text(limits.auditLogPath)
    return ProxyConfig(
        schemaVersion: ProxyConfig.currentSchemaVersion, profileName: profileName, proxy: proxy, auth: auth,
        upstreams: upstreams, routing: routing, dns: dns, tunnels: tunnels, health: health, logging: logging
    )
}

func makeConfig(_ fixture: SyntheticFixture) -> ProxyConfig {
    switch fixture {
    case .small: makeSmallConfig()
    case .stringMaximum: makeMaximumConfig(SyntheticText(unique: false))
    case .uniqueMaximum: makeMaximumConfig(SyntheticText(unique: true))
    }
}

func makePlatform() -> PlatformIntegrationConfig {
    PlatformIntegrationConfig(manageSystemProxy: false, manageEnvironmentVariables: false, manageDNSResolvers: false,
                              manageSystemDNS: false, systemProxyMode: longestSystemProxyMode, launchAtLogin: false)
}

func makeRequest(_ config: ProxyConfig, _ platform: PlatformIntegrationConfig) throws -> PrivateConfigurationRequest {
    try PrivateConfigurationBridge.makeRequest(
        config: config, platform: platform,
        requestID: ControlRequestID(rawValue: syntheticUUID(90, 1)),
        incarnation: ControlHostIncarnation(rawValue: syntheticUUID(91, 1)),
        budget: try ControlWireBudget(5000),
        expectedConfigRevision: ControlConfigRevision(rawValue: 1)!,
        expectedPlatformRevision: PrivatePlatformRevision(rawValue: 1)!,
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )
}

/// Expected decoded bytes of every resource-bounded text in a maximum fixture, from the approved ceilings.
func expectedMaximumBoundedText(noProxyDecodedBytes: Int) -> (bytes: Int, values: Int) {
    let limits = DomainResourceLimits.self
    let hostValues = 1 + limits.allowedClients + limits.upstreams + limits.forceProxyHosts
        + limits.dnsEntries * (1 + limits.dnsServers) + limits.interceptRules + 1 + limits.tunnelDefinitions
    let displayValues = 1 + limits.upstreams + limits.tunnelDefinitions
    let urlValues = 2 + limits.dohProviders
    let bytes = limits.displayText * displayValues + limits.identity * 3 + limits.hostText * hostValues
        + limits.wildcardInterceptPattern * limits.interceptRules + limits.urlText * urlValues + limits.auditLogPath
        + noProxyDecodedBytes
    let values = hostValues + displayValues + 3 + limits.interceptRules + urlValues + 1 + limits.noProxyHosts
    return (bytes, values)
}

// MARK: - Inventory of the DTO the writer walks

/// Every field `PrivateJSONEmitter.writeRequest` writes, read from the DTO values, by JSON lexeme class. The lexer count of
/// the production body must equal it, so a field missing here (or a new writer field) fails calibration.
struct DTOInventory {
    var ints = 0, intBytes = 0
    var doubles = 0, doubleBytes = 0
    var bools = 0, trues = 0, nulls = 0
    var valueStrings = 0, uuids = 0, enumTokens = 0
    var boundedTexts = 0, boundedTextBytes = 0, sixByteEscapeBytes = 0

    mutating func int(_ value: Int) { ints += 1; intBytes += String(value).utf8.count }
    mutating func double(_ value: Double) { doubles += 1; doubleBytes += String(value).utf8.count }
    mutating func bool(_ value: Bool) { bools += 1; if value { trues += 1 } }
    mutating func uuid() { valueStrings += 1; uuids += 1 }
    mutating func token() { valueStrings += 1; enumTokens += 1 }
    mutating func null() { nulls += 1 }

    mutating func text(_ value: String) {
        valueStrings += 1
        boundedTexts += 1
        boundedTextBytes += value.utf8.count
        sixByteEscapeBytes += value.utf8.reduce(0) { $0 + (isSixByteEscape($1) ? 1 : 0) }
    }

    mutating func url(_ value: PrivateURLValue) {
        valueStrings += 1
        boundedTexts += 1
        boundedTextBytes += value.byteCount
        sixByteEscapeBytes += value.withUTF8 { bytes in
            bytes.reduce(0) { total, byte in total + (isSixByteEscape(byte) ? 1 : 0) }
        }
    }

    init(_ request: PrivateConfigurationRequest) {
        uuid(); uuid()
        int(request.budget.rawValue)
        int(request.expectedConfigRevision.rawValue)
        int(request.expectedPlatformRevision.rawValue)
        int(request.expectedOwnerGeneration.rawValue)
        let runtime = request.runtime
        text(runtime.profileName)
        let proxy = runtime.proxy
        text(proxy.host); int(proxy.port); bool(proxy.socksEnabled); int(proxy.socksPort); bool(proxy.gatewayMode)
        for client in proxy.allowedClients { text(client) }
        int(proxy.maxConnections); double(proxy.stalledConnectionTimeoutSeconds); int(proxy.maxBufferedBodyBytes)
        int(proxy.maxSpooledBodyBytes); int(proxy.inboundConnectionWarnThreshold); int(proxy.inboundConnectionMaxLimit)
        bool(proxy.strictMode)
        let auth = runtime.auth
        token(); text(auth.username); text(auth.domain); text(auth.workstation)
        int(auth.pendingHandshakeGlobalLimit); int(auth.pendingHandshakesPerSource)
        for upstream in runtime.upstreams {
            uuid(); text(upstream.name); text(upstream.host); int(upstream.port); bool(upstream.enabled); int(upstream.priority)
        }
        let routing = runtime.routing
        url(routing.pacURL); bool(routing.localPACEnabled); int(routing.localPACPort); bool(routing.pacRoutingEnabled)
        int(routing.pacUsableRouteLimit)
        for host in routing.noProxyHosts { text(host) }
        for host in routing.forceProxyHosts { text(host) }
        let dns = runtime.dns
        bool(dns.forwarderEnabled); int(dns.forwarderPort)
        for provider in dns.dohProviders { url(provider) }
        for entry in dns.entries {
            uuid(); text(entry.domain)
            for server in entry.servers { text(server) }
            bool(entry.enabled)
        }
        for rule in dns.interceptRules {
            uuid(); text(rule.pattern); text(rule.interceptIP); bool(rule.enabled)
        }
        bool(dns.transparentProxyEnabled); text(dns.transparentProxyIP); int(dns.transparentProxyPort)
        let tunnels = runtime.tunnels
        for definition in tunnels.definitions {
            uuid(); int(definition.localPort); text(definition.remoteHost); int(definition.remotePort)
            bool(definition.enabled); bool(definition.proxied); text(definition.label)
            if definition.preset != nil { token() } else { null() }
        }
        int(tunnels.maxSessions); int(tunnels.maxSessionsPerTunnel)
        let health = runtime.health
        url(health.checkURL)
        for value in [health.checkIntervalSeconds, health.connectionCheckTimeoutSeconds, health.upstreamResponseTimeoutSeconds,
                      health.upstreamConnectTimeoutSeconds, health.directConnectTTLSeconds, health.circuitBreakerWindowSeconds] {
            double(value)
        }
        int(health.circuitFailureThreshold)
        for value in [health.circuitBaseOpenIntervalSeconds, health.circuitMaxOpenIntervalSeconds,
                      health.vpnFlapGraceSeconds, health.vpnFlapMinVisibleSeconds] {
            double(value)
        }
        let logging = runtime.logging
        bool(logging.verbose); bool(logging.auditLogEnabled); int(logging.auditLogMaxBytes)
        if let path = logging.auditLogPath { text(path) } else { null() }
        let platform = request.platform
        bool(platform.manageSystemProxy); bool(platform.manageEnvironmentVariables)
        bool(platform.manageDNSResolvers); bool(platform.manageSystemDNS); token()
    }
}

// MARK: - Lexer over the production body

/// JSON lexeme classes of one compact body. Quoted strings are skipped whole (a backslash skips the byte after it), and a
/// string followed by `:` is a key. A number containing `.`, `e` or `E` is a Double lexeme; the production writer spells
/// every Double with one of them and no Int with any.
struct BodyLexemes {
    var intLexemes = 0, intBytes = 0, widestIntBytes = 0
    var doubleLexemes = 0, doubleBytes = 0, widestDoubleBytes = 0
    var trueLexemes = 0, falseLexemes = 0, nullLexemes = 0
    var keyStrings = 0, keyBytes = 0, valueStrings = 0, valueBytes = 0
    var otherBytes = 0
    var wellFormed = true

    var accountedBytes: Int {
        intBytes + doubleBytes + 4 * trueLexemes + 5 * falseLexemes + 4 * nullLexemes + keyBytes + valueBytes + otherBytes
    }
}

func scanLexemes(_ body: UnsafeBufferPointer<UInt8>) -> BodyLexemes {
    var result = BodyLexemes()
    let count = body.count
    var index = 0
    func matches(_ literal: StaticString) -> Bool {
        let length = literal.utf8CodeUnitCount
        guard index + length <= count else { return false }
        return literal.withUTF8Buffer { word in
            (0..<length).allSatisfy { body[index + $0] == word[$0] }
        }
    }
    func isNumberByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || byte == 0x2D || byte == 0x2B || byte == 0x2E || byte == 0x65 || byte == 0x45
    }
    while index < count {
        let byte = body[index]
        switch byte {
        case 0x22:
            let start = index
            index += 1
            while index < count, body[index] != 0x22 {
                index += body[index] == 0x5C ? 2 : 1
            }
            guard index < count else {
                result.wellFormed = false
                return result
            }
            index += 1
            let width = index - start
            if index < count, body[index] == 0x3A {
                result.keyStrings += 1
                result.keyBytes += width
            } else {
                result.valueStrings += 1
                result.valueBytes += width
            }
        case 0x2D, 0x30...0x39:
            let start = index
            var fractional = false
            while index < count, isNumberByte(body[index]) {
                if body[index] == 0x2E || body[index] == 0x65 || body[index] == 0x45 {
                    fractional = true
                }
                index += 1
            }
            let width = index - start
            if fractional {
                result.doubleLexemes += 1
                result.doubleBytes += width
                result.widestDoubleBytes = max(result.widestDoubleBytes, width)
            } else {
                result.intLexemes += 1
                result.intBytes += width
                result.widestIntBytes = max(result.widestIntBytes, width)
            }
        case 0x74:
            guard matches("true") else { result.wellFormed = false; return result }
            result.trueLexemes += 1
            index += 4
        case 0x66:
            guard matches("false") else { result.wellFormed = false; return result }
            result.falseLexemes += 1
            index += 5
        case 0x6E:
            guard matches("null") else { result.wellFormed = false; return result }
            result.nullLexemes += 1
            index += 4
        default:
            result.otherBytes += 1
            index += 1
        }
    }
    return result
}

// MARK: - Reply MIRROR (probe-local, NOT the production reply codec)

// A probe-local Encodable stand-in for the members a future private observation reply would add beyond the runtime and
// platform values the request body already carries. It is not an API proposal. Each member takes its widest bounded shape:
// UUID identities, Int.max ordinals, UInt64.max store versions, a 64-byte state token (`DomainResourceLimits.token`, the
// lexical guard every enum token stays under), the longest `ControlModule`, and the production `AppPreferences` value.
// `CanonicalJSON.encoder()` escapes `/` as two bytes, so its string widths are at least the private writer's.

// The worst candidate shape carries one runtime, one platform and one preferences value (never a second full configuration),
// and every metadata member below at once, every optional present: an observation and an update receipt in one reply.
// Every token is a closed set; the probe charges each at the 64-byte token guard.

/// The store's exact baseline: its namespace, the component and the UInt64 file version, never narrowed to an Int ordinal.
struct MirrorBaseline: Encodable {
    let namespace: String
    let component: String
    let version: UInt64
}

/// One component in the observation: verified, permitted absence, or retained last-known (no baseline, closed reason).
struct MirrorComponentState: Encodable {
    let component: String
    let state: String
    let baseline: MirrorBaseline?
    let migrationPending: Bool
    let fallback: String?
    let retainedReason: String?
}

/// One module's lifecycle intent and fence, for each of the three `ControlModule` cases.
struct MirrorModuleIntent: Encodable {
    let module: String
    let lifecycleRevision: Int
    let intent: String
    let fenced: Bool
}

/// One component's persistence outcome in a causal receipt; the receipt baseline exists only for a verified outcome.
struct MirrorComponentOutcome: Encodable {
    let component: String
    let outcome: String
    let cause: String?
    let hold: String?
    let reportedWriteError: Bool
    let receipt: MirrorBaseline?
}

/// The causal receipt of one submitted update, matched to the client's draft by request and draft identity.
struct MirrorReceipt: Encodable {
    let requestID: String
    let draftID: String
    let operationID: String
    let submittedGeneration: Int
    let outcomes: [MirrorComponentOutcome]
    let apply: String
    let applyReason: String?
}

struct MirrorMetadata: Encodable {
    let hostIncarnation: String
    let ownerGeneration: Int
    let terminal: Bool
    let components: [MirrorComponentState]
    let intents: [MirrorModuleIntent]
    let launchAtLogin: Bool?
    let receipt: MirrorReceipt?
}

/// The reply envelope around the request-shaped body, the preferences and the metadata, with placeholder values.
struct MirrorEnvelope: Encodable {
    static let memberCount = 3
    let runtimeAndPlatform = 0
    let preferences = 0
    let metadata = 0
}

// MARK: - Memory sampling

/// Live values (resident, footprint, malloc in use) are point samples between stages. The three high-water marks are
/// process-wide and monotonic: a rise between two stage records is the transient peak of the work in between, including
/// copies a stage boundary cannot see (the decoder's `Data`, the reader's buffer growth, the encoder's SecretBytes copy).
/// `mallocMaxInUseBytes` is the sum of every zone's own high-water mark, so it bounds, not equals, the simultaneous peak.
struct MemorySample {
    let seconds: Double
    let peakRSSBytes: Int
    let residentBytes: Int
    let physicalFootprintBytes: Int
    let footprintPeakBytes: Int
    let mallocInUseBytes: Int
    let mallocMaxInUseBytes: Int

    var record: [String: Any] {
        ["seconds": seconds, "peakRSSBytes": peakRSSBytes, "residentBytes": residentBytes,
         "physicalFootprintBytes": physicalFootprintBytes, "footprintPeakBytes": footprintPeakBytes,
         "mallocInUseBytes": mallocInUseBytes, "mallocMaxInUseBytes": mallocMaxInUseBytes]
    }
}

// MARK: - Probe

final class ReplyBoundProbe {
    let mode: ProbeMode
    let fixture: SyntheticFixture
    private let start = DispatchTime.now().uptimeNanoseconds
    private var failures: [String] = []
    private var inconclusive: [String] = []

    init(mode: ProbeMode) {
        self.mode = mode
        switch mode {
        case .small: fixture = .small
        case .stringMaximum: fixture = .stringMaximum
        case .uniqueMaximum, .repeatMaximum: fixture = .uniqueMaximum
        }
    }

    /// Scoped in its own pool: the bridged dictionary is autoreleased, and a command-line main thread never drains, so an
    /// unscoped emit would show up as per-iteration growth in `repeat` that the codec did not cause.
    func emit(_ record: [String: Any]) {
        autoreleasepool {
            var labelled = record
            labelled["mode"] = mode.rawValue
            labelled["fixture"] = fixture.rawValue
            let data = try! JSONSerialization.data(withJSONObject: labelled, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    func check(_ condition: Bool, _ name: String) {
        emit(["record": "check", "name": name, "passed": condition])
        if !condition { failures.append(name) }
    }

    func sample() -> MemorySample {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0)
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        var info = task_vm_info_data_t()
        var infoCount = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let infoResult = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(infoCount)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &infoCount)
            }
        }
        precondition(infoResult == KERN_SUCCESS)
        return MemorySample(
            seconds: Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9,
            peakRSSBytes: Int(usage.ru_maxrss),
            residentBytes: Int(clamping: info.resident_size),
            physicalFootprintBytes: Int(clamping: info.phys_footprint),
            footprintPeakBytes: Int(clamping: info.ledger_phys_footprint_peak),
            mallocInUseBytes: Int(stats.size_in_use),
            mallocMaxInUseBytes: Int(stats.max_size_in_use)
        )
    }

    func mark(_ stage: String) {
        emit(sample().record.merging(["record": "stage", "stage": stage]) { _, new in new })
    }

    /// Fixed labels and bounded numbers only. No error here carries configuration text into this label.
    func errorLabel(_ error: any Error) -> String {
        switch error {
        case let error as PrivateConfigurationBridgeError:
            switch error {
            case .tooLarge: return "bridge.tooLarge"
            case .resourceLimit(let violation): return "bridge.resourceLimit.\(violation.field).\(violation.limit)"
            }
        case let error as PrivateConfigurationWireError:
            if case .resourceLimitExceeded(let violation) = error {
                return "wire.resourceLimitExceeded.\(violation.field).\(violation.limit)"
            }
            return "wire.\(error)"
        case let error as ConfigFileRepresentabilityError:
            return "representability.\(error.field).\(error.requirement)"
        case let error as ConfigurationFileSizeRefusal:
            return "fileSize.\(error.encodedBytes).\(error.limit)"
        case let error as ConfigurationResourceRefusal:
            return "resource.\(error.violation.field).\(error.violation.limit)"
        case let error as ConfigurationSidecarSaveRefusal:
            switch error.cause {
            case .resourceLimit(let violation): return "sidecar.resourceLimit.\(violation.field).\(violation.limit)"
            case .fileSize(let encodedBytes, let limit): return "sidecar.fileSize.\(encodedBytes).\(limit)"
            }
        case let error as ConfigurationLoadError:
            return "load.\(error.reason)"
        default:
            return "unexpected.\(type(of: error))"
        }
    }

    // MARK: Lifetime pipeline

    @inline(never) func senderFrame(sample stages: Bool) throws -> SecretBytes {
        let config = makeConfig(fixture)
        let platform = makePlatform()
        if stages { withExtendedLifetime(config) { mark("domain-input-only") } }
        let request = try makeRequest(config, platform)
        if stages { withExtendedLifetime((config, request)) { mark("frozen-plus-domain-input") } }
        let frame = try PrivateConfigurationEncoder.encode(request)
        if stages { withExtendedLifetime((config, request, frame)) { mark("sender-overlap") } }
        return frame
    }

    @inline(never) func readBody(_ frame: SecretBytes) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader()
        var delivered: PrivateConfigurationFrameBody?
        try frame.withUnsafeBytes { bytes in
            var index = 0
            while index < bytes.count {
                let result = try reader.consume(bytes[index...])
                precondition(result.consumed > 0)
                index += result.consumed
                if case .frame(let body) = result.step { delivered = body }
            }
        }
        try reader.finish()
        guard let delivered else { throw PrivateConfigurationWireError.malformedBody }
        return delivered
    }

    /// One scoped pipeline. Each form is released before the next stage is sampled, so only the forms named in a stage are
    /// live. The deterministic rebuild at the end stands for the previous live configuration an update keeps until replacement,
    /// and it is the round-trip oracle.
    @inline(never) func pipeline(sample stages: Bool) throws -> (frameBytes: Int, roundTripEqual: Bool) {
        var frame: SecretBytes? = try senderFrame(sample: stages)
        let frameBytes = frame!.count
        if stages { withExtendedLifetime(frame) { mark("wire-frame-only") } }
        var body: PrivateConfigurationFrameBody? = try readBody(frame!)
        frame = nil
        if stages { withExtendedLifetime(body) { mark("receiver-body-only") } }
        var decoded: PrivateConfigurationRequest? = try PrivateConfigurationDecoder.decode(body!)
        body = nil
        if stages { withExtendedLifetime(decoded) { mark("decoded-request-only") } }
        var output: (config: ProxyConfig, platform: PlatformIntegrationConfig)? =
            try PrivateConfigurationBridge.makeValues(from: decoded!, localLaunchAtLogin: false)
        decoded = nil
        if stages { withExtendedLifetime(output) { mark("domain-values-only") } }
        var previous: ProxyConfig? = makeConfig(fixture)
        let roundTripEqual = output!.config == previous! && output!.platform == makePlatform()
        if stages { withExtendedLifetime((output, previous)) { mark("previous-plus-domain-values") } }
        previous = nil
        output = nil
        return (frameBytes, roundTripEqual)
    }

    func runLifetime() {
        do {
            let result = try autoreleasepool { try pipeline(sample: true) }
            mark("final-released")
            emit(["record": "lifetime", "frameBytes": result.frameBytes, "roundTripEqual": result.roundTripEqual])
            check(result.roundTripEqual, "lifetime.roundTripEqual")
        } catch PrivateConfigurationBridgeError.tooLarge {
            mark("final-released")
            emit(["record": "lifetime", "outcome": "insufficient-evidence: production counter refused frameTooLarge"])
            inconclusive.append("lifetime.frameTooLarge")
        } catch {
            mark("final-released")
            emit(["record": "lifetime", "error": errorLabel(error)])
            failures.append("lifetime.error")
        }
    }

    func runRepeat() {
        var first: MemorySample?
        var last: MemorySample?
        var widestMalloc = 0
        var widestFootprint = 0
        for iteration in 1...repeatIterations {
            do {
                let result = try autoreleasepool { try pipeline(sample: false) }
                let after = sample()
                if first == nil { first = after }
                last = after
                widestMalloc = max(widestMalloc, after.mallocInUseBytes)
                widestFootprint = max(widestFootprint, after.physicalFootprintBytes)
                emit(after.record.merging(["record": "repeat", "iteration": iteration, "frameBytes": result.frameBytes,
                                           "roundTripEqual": result.roundTripEqual]) { _, new in new })
                if !result.roundTripEqual { failures.append("repeat.\(iteration).roundTripEqual") }
            } catch {
                emit(["record": "repeat", "iteration": iteration, "error": errorLabel(error)])
                failures.append("repeat.\(iteration).error")
            }
        }
        if let first, let last {
            emit(["record": "repeat-summary", "iterations": repeatIterations,
                  "firstReleasedMallocInUseBytes": first.mallocInUseBytes, "lastReleasedMallocInUseBytes": last.mallocInUseBytes,
                  "releasedMallocGrowthBytes": last.mallocInUseBytes - first.mallocInUseBytes,
                  "widestReleasedMallocInUseBytes": widestMalloc,
                  "firstReleasedFootprintBytes": first.physicalFootprintBytes,
                  "lastReleasedFootprintBytes": last.physicalFootprintBytes,
                  "widestReleasedFootprintBytes": widestFootprint, "peakRSSBytes": last.peakRSSBytes])
        }
    }

    // MARK: Analysis (after the lifetime samples, so it cannot disturb them)

    func analyze() {
        do {
            try analyzeFixture()
        } catch {
            emit(["record": "analysis", "error": errorLabel(error)])
            failures.append("analysis.error")
        }
    }

    private func analyzeFixture() throws {
        let limits = DomainResourceLimits.self
        let config = makeConfig(fixture)
        let platform = makePlatform()

        // Shape: every collection at its approved count; bypass aggregate by the production counter.
        // `CanonicalJSONStringList.init` is internal, so the same arithmetic is spelled here: brackets, one comma between items,
        // and each item's production `quotedWidth`. The package-visible shared check below confirms the aggregate is accepted.
        let noProxyHosts = config.routing.noProxyHosts
        let noProxyWidth = (bytes: 2 + max(noProxyHosts.count - 1, 0)
            + noProxyHosts.reduce(0) { $0 + CanonicalJSONWidth.quotedWidth($1) }, ())
        check(DomainResourceCheck.strings(noProxyHosts, count: .noProxyHosts, item: .noProxyPattern,
                                          encodedWithin: .noProxyList) == nil, "shape.noProxySharedCheckPasses")
        let serverCounts = config.dns.entries.map(\.servers.count)
        let presetsPresent = config.tunnels.definitions.filter { $0.preset != nil }.count
        let counts: [(name: String, actual: Int, ceiling: Int)] = [
            ("upstreams", config.upstreams.count, limits.upstreams),
            ("tunnelDefinitions", config.tunnels.definitions.count, limits.tunnelDefinitions),
            ("dnsEntries", config.dns.entries.count, limits.dnsEntries),
            ("dnsServersPerEntryMin", serverCounts.min() ?? 0, limits.dnsServers),
            ("dnsServersPerEntryMax", serverCounts.max() ?? 0, limits.dnsServers),
            ("interceptRules", config.dns.interceptRules.count, limits.interceptRules),
            ("allowedClients", config.proxy.allowedClients.count, limits.allowedClients),
            ("forceProxyHosts", config.routing.forceProxyHosts.count, limits.forceProxyHosts),
            ("noProxyHosts", config.routing.noProxyHosts.count, limits.noProxyHosts),
            ("dohProviders", config.dns.dohProviders.count, limits.dohProviders),
            ("presetsPresent", presetsPresent, limits.tunnelDefinitions),
        ]
        var shape: [String: Any] = ["record": "shape", "noProxyCanonicalJSONBytes": noProxyWidth.bytes,
                                    "noProxyCanonicalJSONLimit": limits.noProxyList]
        for count in counts {
            shape[count.name] = count.actual
        }
        shape["auditLogPathPresent"] = config.logging.auditLogPath != nil
        shape["authMode"] = longestAuthMode.rawValue
        shape["systemProxyMode"] = longestSystemProxyMode.rawValue
        shape["preset"] = longestPreset.rawValue
        emit(shape)
        check(counts.allSatisfy { $0.actual == $0.ceiling }, "shape.everyCountAtApprovedCeiling")
        check(config.logging.auditLogPath != nil, "shape.everyOptionalPresent")
        if fixture.isMaximum {
            check(noProxyWidth.bytes == limits.noProxyList, "shape.noProxyAggregateExactlyAtCeiling")
        } else {
            check(noProxyWidth.bytes <= limits.noProxyList, "shape.noProxyAggregateWithinCeiling")
        }

        // O1: the shared resource check, then the validation class (counts only; messages can carry values).
        let violation = config.resourceViolation()
        emit(["record": "resource", "violation": violation.map { "\($0.field).\($0.limit)" } ?? "none"])
        check(violation == nil, "resource.sharedCheckPasses")
        let problems = config.validate().count
        let startBlocking = config.startBlockingProblems.count
        emit(["record": "validation", "problems": problems, "startBlockingProblems": startBlocking])
        if fixture == .small { check(problems == 0, "small.validateHasNoProblems") }

        // O2 without its decode: stagedFile's representability predicates and its own encoder call.
        let finite = RuntimeDurationField.allCases.allSatisfy { $0.seconds(in: config).isFinite }
        let inRange = config.firstUnrepresentableDuration() == nil
        let wholeMilliseconds = DurationUnits.exactMilliseconds(config.health.connectionCheckTimeout) != nil
        let wholeMinutes = DurationUnits.exactMinutes(config.health.directConnectTTL) != nil
        var stagedBytes = -1
        var compactBytes = -1
        do {
            stagedBytes = try autoreleasepool { try CanonicalJSON.encoder(prettyPrinted: true).encode(config).count }
            compactBytes = try autoreleasepool { try CanonicalJSON.encoder(prettyPrinted: false).encode(config).count }
        } catch {
            emit(["record": "staging", "encodeError": errorLabel(error)])
        }
        let fileLimit = ConfigurationFileReader.maximumBytes
        let preconditionsPass = violation == nil && finite && inRange && wholeMilliseconds && wholeMinutes
        let stagedWithin = stagedBytes >= 0 && stagedBytes <= fileLimit
        let storability: String
        if !preconditionsPass || !stagedWithin {
            storability = "unsupported"
        } else if problems == 0 {
            storability = "eligible"
        } else if startBlocking > 0 {
            storability = "storable-repair-draft-start-blocking"
        } else {
            storability = "storable-repair-draft-non-blocking"
        }
        var storabilityRecord: [String: Any] = [
            "record": "storability", "class": storability,
            "basis": "resource check + stagedFile representability predicates + byte count of stagedFile's own encoder call; the staging-oracles record confirms or refutes it",
        ]
        storabilityRecord["durationsFinite"] = finite
        storabilityRecord["durationsInRuntimeRange"] = inRange
        storabilityRecord["connectionCheckWholeMilliseconds"] = wholeMilliseconds
        storabilityRecord["directConnectTTLWholeMinutes"] = wholeMinutes
        storabilityRecord["stagedPrettyBytes"] = stagedBytes
        storabilityRecord["compactBytes"] = compactBytes
        storabilityRecord["runtimeFileLimit"] = fileLimit
        storabilityRecord["stagedWithinFileLimit"] = stagedWithin
        storabilityRecord["compactWithinFileLimit"] = compactBytes >= 0 && compactBytes <= fileLimit
        emit(storabilityRecord)
        check(preconditionsPass, "staging.representabilityPredicatesPass")
        if defaultsInitializingDecodeAllowed {
            // A refusal here classifies a maximum fixture; only the small fixture must be accepted.
            do {
                try runStagingOracles(config, stagedBytes: stagedBytes)
                emit(["record": "staging-oracles", "outcome": "stagedFile accepted; startup decode of staged and compact bytes ran"])
            } catch {
                emit(["record": "staging-oracles", "outcome": "refused", "error": errorLabel(error)])
                if fixture == .small { failures.append("small.stagingOracles") }
            }
        } else {
            emit(["record": "staging-oracles", "outcome": "unmeasured: stagedFile decode-equality and startup decode initialize GenericDefaults.shared (NSUserName, ProcessInfo.hostName); awaiting parent approval"])
        }

        // O5: the production bridge and exact counter.
        let request: PrivateConfigurationRequest
        do {
            request = try makeRequest(config, platform)
        } catch PrivateConfigurationBridgeError.tooLarge {
            emit(["record": "measure", "outcome": "insufficient-evidence: measureBody refused frameTooLarge; no size claimed"])
            inconclusive.append("measure.frameTooLarge")
            return
        }
        let measuredBody = try PrivateConfigurationEncoder.measureBody(request)
        let frame = try PrivateConfigurationEncoder.encode(request)
        let lexemes = frame.withUnsafeBytes { bytes -> (BodyLexemes, Int) in
            let lineFeed = bytes.firstIndex(of: 0x0A)!
            let body = UnsafeBufferPointer(rebasing: bytes[(lineFeed + 1)..<(bytes.count - 1)])
            return (scanLexemes(body), body.count)
        }
        let scanned = lexemes.0
        emit(["record": "measure", "bodyBytes": measuredBody, "frameBytes": frame.count,
              "frameCap": PrivateConfigurationFrame.maxFrameBytes])
        check(frame.count == PrivateConfigurationFrame.frameByteCount(bodyCount: measuredBody), "measure.frameMatchesHeaderFormula")
        check(lexemes.1 == measuredBody, "measure.encodedBodyEqualsMeasureBody")

        // O6: exact round trip through the reader, decoder and bridge.
        let body = try readBody(frame)
        let decoded = try PrivateConfigurationDecoder.decode(body)
        check(decoded == request, "roundTrip.decodedRequestEqualsRequest")
        let values = try PrivateConfigurationBridge.makeValues(from: decoded, localLaunchAtLogin: false)
        check(values.config == config && values.platform == platform, "roundTrip.domainValuesEqualInput")

        // Calibration: the lexer over the production body against the DTO field inventory.
        let inventory = DTOInventory(request)
        emit(["record": "lexemes", "intLexemes": scanned.intLexemes, "intBytes": scanned.intBytes,
              "widestIntBytes": scanned.widestIntBytes, "doubleLexemes": scanned.doubleLexemes,
              "doubleBytes": scanned.doubleBytes, "widestDoubleBytes": scanned.widestDoubleBytes,
              "trueLexemes": scanned.trueLexemes, "falseLexemes": scanned.falseLexemes, "nullLexemes": scanned.nullLexemes,
              "keyStrings": scanned.keyStrings, "keyBytes": scanned.keyBytes, "valueStrings": scanned.valueStrings,
              "valueStringBytes": scanned.valueBytes, "otherStructuralBytes": scanned.otherBytes,
              "wellFormed": scanned.wellFormed])
        emit(["record": "inventory", "ints": inventory.ints, "intBytes": inventory.intBytes, "doubles": inventory.doubles,
              "doubleBytes": inventory.doubleBytes, "bools": inventory.bools, "trues": inventory.trues, "nulls": inventory.nulls,
              "valueStrings": inventory.valueStrings, "uuids": inventory.uuids, "enumTokens": inventory.enumTokens,
              "boundedTexts": inventory.boundedTexts, "boundedTextBytes": inventory.boundedTextBytes,
              "sixByteEscapeBytes": inventory.sixByteEscapeBytes])
        check(scanned.wellFormed && scanned.accountedBytes == measuredBody, "calibration.lexerAccountsForEveryBodyByte")
        check(scanned.intLexemes == inventory.ints && scanned.intBytes == inventory.intBytes, "calibration.intLexemes")
        check(scanned.doubleLexemes == inventory.doubles && scanned.doubleBytes == inventory.doubleBytes,
              "calibration.doubleLexemes")
        check(scanned.trueLexemes + scanned.falseLexemes == inventory.bools && scanned.trueLexemes == inventory.trues,
              "calibration.boolLexemes")
        check(scanned.nullLexemes == inventory.nulls, "calibration.nullLexemes")
        check(scanned.valueStrings == inventory.valueStrings, "calibration.valueStringLexemes")
        // Widest-choice accounting: false is the wider Bool, every optional is present, enums are the longest raw values.
        check(scanned.trueLexemes == 0 && scanned.nullLexemes == 0, "choices.allBoolsFalseAndAllOptionalsPresent")

        guard fixture.isMaximum else { return }

        // Every bounded text at its ceiling: the shared check passed (each ≤ ceiling) and the sum equals the ceilings' sum.
        let noProxyDecoded = config.routing.noProxyHosts.reduce(0) { $0 + $1.utf8.count }
        let expected = expectedMaximumBoundedText(noProxyDecodedBytes: noProxyDecoded)
        check(inventory.boundedTexts == expected.values, "maximum.boundedTextValueCount")
        check(inventory.boundedTextBytes == expected.bytes, "maximum.everyBoundedTextAtCeiling")
        let requiredASCII = limits.wildcardPrefix.count * limits.interceptRules + noProxyContentBudget().asciiBytes
        check(inventory.sixByteEscapeBytes == inventory.boundedTextBytes - requiredASCII,
              "maximum.everyOtherTextByteIsSixByteEscape")

        try conservativeBounds(measuredBody: measuredBody, scanned: scanned)
    }

    private func runStagingOracles(_ config: ProxyConfig, stagedBytes: Int) throws {
        let staged = try ProxyConfigPersistence.stagedFile(for: config)
        check(staged.bytes.count == stagedBytes, "staging.stagedFileBytesEqualEncoderCall")
        check(staged.value == config, "staging.stagedFileValueEqualsInput")
        let startup = try ProxyConfigPersistence.decode(staged.bytes, source: "synthetic-staged")
        check(startup == config, "staging.startupDecodeOfStagedEqualsInput")
        let compact = try CanonicalJSON.encoder(prettyPrinted: false).encode(config)
        let compactStartup = try ProxyConfigPersistence.decode(compact, source: "synthetic-compact")
        check(compactStartup == config, "staging.startupDecodeOfCompactEqualsInput")
    }

    // MARK: Bounds

    private func conservativeBounds(measuredBody: Int, scanned: BodyLexemes) throws {
        let limits = DomainResourceLimits.self
        let cap = PrivateConfigurationFrame.maxFrameBytes
        check(String(Int.min).utf8.count == intLexemeMaximumBytes && String(Int.max).utf8.count <= intLexemeMaximumBytes
              && String(UInt64.max).utf8.count <= intLexemeMaximumBytes, "numeric.intLexemeMaximumIsTwenty")
        // Observation only: Swift's shortest spellings of extreme Doubles. The bound does not depend on them.
        let extremes: [Double] = [-Double.greatestFiniteMagnitude, -Double.leastNonzeroMagnitude, -Double.leastNormalMagnitude,
                                  -0.1, -1.0 / 3.0, -9_007_199_254_740_993.0, -123_456_789.123_456_789]
        let widestSwiftDouble = extremes.map { String($0).utf8.count }.max() ?? 0

        let numericAllowance = scanned.intLexemes * intLexemeMaximumBytes + scanned.doubleLexemes * doubleLexemeMaximumBytes
            - (scanned.intBytes + scanned.doubleBytes)
        let requestBodyBound = measuredBody + numericAllowance
        let requestFrameBound = PrivateConfigurationFrame.frameByteCount(bodyCount: requestBodyBound)
        let requestWithinCap = requestFrameBound <= cap
        var requestRecord: [String: Any] = [
            "record": "request-bound",
            "label": "CONSERVATIVE UPPER BOUND for any request the shared resource check accepts; not a measured maximum",
            "measuredStringMaximumBody": measuredBody, "actualNumericBytes": scanned.intBytes + scanned.doubleBytes,
            "intLexemes": scanned.intLexemes, "doubleLexemes": scanned.doubleLexemes,
        ]
        requestRecord["intLexemeMaximumBytes"] = intLexemeMaximumBytes
        requestRecord["doubleLexemeMaximumBytes"] = doubleLexemeMaximumBytes
        requestRecord["observedWidestSwiftDoubleBytes"] = widestSwiftDouble
        requestRecord["numericAllowance"] = numericAllowance
        requestRecord["requestBodyBound"] = requestBodyBound
        requestRecord["requestFrameBound"] = requestFrameBound
        requestRecord["frameCap"] = cap
        requestRecord["requestFrameBoundWithinCap"] = requestWithinCap
        requestRecord["requestOutcome"] = requestWithinCap
            ? "bound-within-cap" : "conservative-inconclusive (bound above cap; not an observed overflow)"
        emit(requestRecord)

        // Sidecars: the widest preferences and platform values through their production staging and decode.
        let preferences = AppPreferences(showMenuBarIcon: false, floatingWindowEnabled: false, globalShortcutEnabled: false,
                                         preferredBrowserTestURL: String(repeating: "\u{01}", count: limits.urlText),
                                         fileLoggingEnabled: false, automaticUpdateChecks: false)
        check(DomainResourceCheck.text(preferences.preferredBrowserTestURL, .browserTestURL) == nil,
              "preferences.browserURLWithinCeiling")
        var preferencesSidecarBytes = -1
        do {
            let staged = try AppPreferencesPersistence.stagedData(for: preferences)
            preferencesSidecarBytes = staged.count
            let decoded = try AppPreferencesPersistence.decode(staged, source: "synthetic-preferences")
            check(decoded == preferences, "preferences.sidecarRoundTripUnnormalized")
        } catch {
            emit(["record": "preferences", "error": errorLabel(error)])
            failures.append("preferences.sidecar")
        }
        var platformSidecarBytes = -1
        do {
            let platform = makePlatform()
            let staged = try PlatformConfigPersistence.stagedData(for: platform)
            platformSidecarBytes = staged.count
            let decoded = try PlatformConfigPersistence.decode(staged, source: "synthetic-platform")
            check(decoded == platform, "platform.sidecarRoundTrip")
        } catch {
            emit(["record": "platform", "error": errorLabel(error)])
            failures.append("platform.sidecar")
        }

        // MIRROR of the extra reply members. Not the production reply codec. Every optional is present, every token is at the
        // 64-byte guard, every ordinal and version at its widest value.
        let token = String(repeating: "s", count: limits.token)
        let components = ConfigurationComponent.allCases.map { _ in
            ((), MirrorBaseline(namespace: syntheticUUID(92, 1).uuidString, component: token, version: UInt64.max))
        }
        let metadata = MirrorMetadata(
            hostIncarnation: syntheticUUID(91, 1).uuidString, ownerGeneration: Int.max, terminal: false,
            components: components.map { _, baseline in
                MirrorComponentState(component: token, state: token, baseline: baseline, migrationPending: false,
                                     fallback: token, retainedReason: token)
            },
            intents: ControlModule.allCases.map { _ in
                MirrorModuleIntent(module: token, lifecycleRevision: Int.max, intent: token, fenced: false)
            },
            launchAtLogin: false,
            receipt: MirrorReceipt(
                requestID: syntheticUUID(93, 1).uuidString, draftID: syntheticUUID(94, 1).uuidString,
                operationID: syntheticUUID(95, 1).uuidString, submittedGeneration: Int.max,
                outcomes: components.map { _, baseline in
                    MirrorComponentOutcome(component: token, outcome: token, cause: token, hold: token,
                                           reportedWriteError: false, receipt: baseline)
                },
                apply: token, applyReason: token
            )
        )
        let encoder = CanonicalJSON.encoder()
        let metadataData = try encoder.encode(metadata)
        let preferencesBytes = try encoder.encode(preferences).count
        let envelopeOverhead = try encoder.encode(MirrorEnvelope()).count - 2
        // Conservative allowance over the mirror's own lexemes: every key charged at the token guard (a future codec may pick
        // longer names than the mirror), every value string at the guard with every byte a six-byte escape, every integer at
        // 20 bytes, every Bool as `false`, every null as a present escaped token. Structure is charged as the mirror writes it.
        let metadataLexemes = metadataData.withUnsafeBytes { raw in
            scanLexemes(UnsafeBufferPointer(start: raw.bindMemory(to: UInt8.self).baseAddress, count: raw.count))
        }
        check(metadataLexemes.wellFormed && metadataLexemes.accountedBytes == metadataData.count,
              "mirror.lexerAccountsForEveryMetadataByte")
        check(metadataLexemes.doubleLexemes == 0 && metadataLexemes.nullLexemes == 0 && metadataLexemes.trueLexemes == 0,
              "mirror.noDoublesAllOptionalsPresentAllBoolsFalse")
        let quotedTokenCeiling = 6 * limits.token + 2
        let keyCeiling = limits.token + 2
        let metadataAllowance = metadataLexemes.keyStrings * keyCeiling + metadataLexemes.valueStrings * quotedTokenCeiling
            + metadataLexemes.intLexemes * intLexemeMaximumBytes + metadataLexemes.falseLexemes * 5
            + metadataLexemes.nullLexemes * quotedTokenCeiling + metadataLexemes.otherBytes
        let envelopeAllowance = MirrorEnvelope.memberCount * keyCeiling + envelopeOverhead
        let replyBodyBound = requestBodyBound + preferencesBytes + metadataAllowance + envelopeAllowance
        let replyFrameBound = PrivateConfigurationFrame.frameByteCount(bodyCount: replyBodyBound)
        let mirrorBodyBytes = requestBodyBound + preferencesBytes + metadataData.count + envelopeOverhead
        let replyWithinCap = replyFrameBound <= cap
        var replyRecord: [String: Any] = [
            "record": "reply-bound",
            "label": "CONSERVATIVE UPPER BOUND: whole request body bound (request-only members not subtracted) + exact widest preferences (canonical width >= private width) + lexeme-charged metadata allowance + envelope allowance; MIRROR, not the production reply codec; not an exact future frame",
            "requestBodyBound": requestBodyBound,
        ]
        replyRecord["preferencesObjectBytes"] = preferencesBytes
        replyRecord["mirrorMetadataBytes"] = metadataData.count
        replyRecord["mirrorMetadataKeys"] = metadataLexemes.keyStrings
        replyRecord["mirrorMetadataValueStrings"] = metadataLexemes.valueStrings
        replyRecord["mirrorMetadataIntegers"] = metadataLexemes.intLexemes
        replyRecord["mirrorMetadataBools"] = metadataLexemes.falseLexemes
        replyRecord["mirrorMetadataStructuralBytes"] = metadataLexemes.otherBytes
        replyRecord["metadataAllowanceBytes"] = metadataAllowance
        replyRecord["envelopeAllowanceBytes"] = envelopeAllowance
        replyRecord["mirrorFrameBytes"] = PrivateConfigurationFrame.frameByteCount(bodyCount: mirrorBodyBytes)
        replyRecord["replyBodyBound"] = replyBodyBound
        replyRecord["replyFrameBound"] = replyFrameBound
        replyRecord["existingFrameCap"] = cap
        replyRecord["replyFrameBoundWithinExistingCap"] = replyWithinCap
        replyRecord["replyHeadroomBytes"] = cap - replyFrameBound
        replyRecord["additionalWidestMembersInHeadroom"] = (cap - replyFrameBound) / (keyCeiling + quotedTokenCeiling + 1)
        replyRecord["replyOutcome"] = replyWithinCap
            ? "bound-within-existing-cap" : "conservative-inconclusive (bound above cap; not an observed overflow)"
        replyRecord["preferencesSidecarBytes"] = preferencesSidecarBytes
        replyRecord["platformSidecarBytes"] = platformSidecarBytes
        replyRecord["sidecarLimit"] = limits.sidecarFileBytes
        replyRecord["replyDecoderMeasured"] = false
        emit(replyRecord)
    }

    func finish() -> Never {
        emit(["record": "summary", "failedChecks": failures.count, "failures": failures,
              "inconclusive": inconclusive, "defaultsInitializingDecodeAllowed": defaultsInitializingDecodeAllowed])
        exit(failures.isEmpty ? (inconclusive.isEmpty ? 0 : 3) : 1)
    }
}

// MARK: - Entry

guard CommandLine.arguments.count == 2, let mode = ProbeMode(rawValue: CommandLine.arguments[1]) else {
    FileHandle.standardError.write(Data("usage: probe small|string-maximum|unique-maximum|repeat\n".utf8))
    exit(64)
}
let probe = ReplyBoundProbe(mode: mode)
probe.mark("baseline")
switch mode {
case .repeatMaximum:
    probe.runRepeat()
case .small, .stringMaximum, .uniqueMaximum:
    probe.runLifetime()
    probe.analyze()
}
probe.finish()
