// SPDX-License-Identifier: Apache-2.0
import Foundation

// The private encoder writes each body by hand, with no generic `JSONValue` tree
// and no `JSONEncoder`. Every frame kind runs the same writer twice:
//
//   1. a counting pass that writes into a sink that only counts. It stops as soon as the
//      body alone cannot fit the cap, so an oversize value is refused before any buffer
//      is allocated;
//   2. an emission pass that writes into a buffer of exactly the counted size.
//
// Both passes call the same code, so the count is exact by construction. The escapes
// (quotes, backslashes, control bytes) and the number formatting are counted the way
// they are written, not estimated. The writer refuses a value it cannot represent
// (a non-finite number); it never truncates. A port is an `Int` like every other integer
// here: the wire does not range-check it, because an out-of-range port is an editable
// draft that the save stages and the runtime eligibility gate holds, not a format error.

/// Bytes of the smallest possible frame around a body: `PCV1 <kind> 1\n`, the body, and `\n`.
private let minimumFrameOverhead = 10

/// A value the encoder writes as the whole body of one frame of its kind. Each conformer is one root of the
/// schema, and its writer emits exactly the members of that root's table.
protocol PrivateFrameRoot {
    static var frameKind: PrivateConfigurationFrame.Kind { get }
    /// The first approved resource ceiling the value crosses, or nil. It runs before the writer walks the value.
    func resourceViolation() -> DomainResourceViolation?
    func writeBody<Sink: PrivateFrameSink>(to emitter: PrivateJSONEmitter<Sink>) throws
}

/// Receives the body bytes one at a time. Counting and emission are two implementations.
protocol PrivateFrameSink {
    mutating func put(_ byte: UInt8) throws
}

/// Counts bytes and refuses once the count passes `limit`, so a count pass stops early.
private struct PrivateCountingSink: PrivateFrameSink {
    let limit: Int
    private(set) var count = 0

    init(limit: Int) {
        self.limit = limit
    }

    mutating func put(_ byte: UInt8) throws {
        count += 1
        guard count <= limit else {
            throw PrivateConfigurationWireError.frameTooLarge
        }
    }
}

/// Writes bytes into a buffer that was sized by the counting pass. It refuses a write past
/// the buffer's ceiling, so a disagreement between the passes fails instead of overflowing.
private struct PrivateBufferSink: PrivateFrameSink {
    let buffer: PrivateFrameBuffer

    mutating func put(_ byte: UInt8) throws {
        guard buffer.count < buffer.ceiling else {
            throw PrivateConfigurationWireError.invalidValue
        }
        buffer.append(byte)
    }
}

/// Writes JSON structure and values through a sink. A class, so the nested-object
/// bookkeeping of separators is shared between the helpers that call each other.
final class PrivateJSONEmitter<Sink: PrivateFrameSink> {
    var sink: Sink
    /// Whether the next member of the open object needs a comma before it.
    private var needsSeparator = false

    init(sink: Sink) {
        self.sink = sink
    }

    private static var hexDigits: [UInt8] { Array("0123456789abcdef".utf8) }

    // MARK: - Primitives

    /// Writes a static ASCII token. `withUTF8Buffer` takes a non-throwing closure, so the sink's
    /// error is captured as a `Result` inside the pointer's scope and rethrown after that scope ends.
    /// The pointer never leaves the closure, and no error is dropped.
    private func keyword(_ text: StaticString) throws {
        let outcome = text.withUTF8Buffer { buffer -> Result<Void, any Error> in
            Result {
                for byte in buffer {
                    try sink.put(byte)
                }
            }
        }
        try outcome.get()
    }

    private func ascii(_ text: String) throws {
        for byte in text.utf8 {
            try sink.put(byte)
        }
    }

    /// Writes a JSON string. Quotes, backslashes and control bytes are escaped. Every other
    /// byte is written as UTF-8, including emoji and non-ASCII text. Escaped output is never
    /// truncated.
    private func quoted(_ bytes: UnsafeBufferPointer<UInt8>) throws {
        try sink.put(UInt8(ascii: "\""))
        for byte in bytes {
            try escape(byte)
        }
        try sink.put(UInt8(ascii: "\""))
    }

    private func escape(_ byte: UInt8) throws {
        switch byte {
        case UInt8(ascii: "\""):
            try sink.put(UInt8(ascii: "\\"))
            try sink.put(UInt8(ascii: "\""))
        case UInt8(ascii: "\\"):
            try sink.put(UInt8(ascii: "\\"))
            try sink.put(UInt8(ascii: "\\"))
        case 0x08:
            try emitEscape(UInt8(ascii: "b"))
        case 0x0C:
            try emitEscape(UInt8(ascii: "f"))
        case 0x0A:
            try emitEscape(UInt8(ascii: "n"))
        case 0x0D:
            try emitEscape(UInt8(ascii: "r"))
        case 0x09:
            try emitEscape(UInt8(ascii: "t"))
        case 0x00..<0x20:
            // Other control bytes are written as \u00XX with lowercase hex digits.
            try emitEscape(UInt8(ascii: "u"))
            try sink.put(UInt8(ascii: "0"))
            try sink.put(UInt8(ascii: "0"))
            try sink.put(Self.hexDigits[Int(byte >> 4)])
            try sink.put(Self.hexDigits[Int(byte & 0x0F)])
        default:
            try sink.put(byte)
        }
    }

    private func emitEscape(_ letter: UInt8) throws {
        try sink.put(UInt8(ascii: "\\"))
        try sink.put(letter)
    }

    func writeString(_ text: String) throws {
        var copy = text
        try copy.withUTF8 { buffer in
            try quoted(buffer)
        }
    }

    func writeURL(_ value: PrivateURLValue) throws {
        try value.withUTF8 { buffer in
            try quoted(buffer)
        }
    }

    func writeOptionalString(_ text: String?) throws {
        if let text {
            try writeString(text)
        } else {
            try keyword("null")
        }
    }

    /// Writes bytes that are already one complete JSON value. Only `PrivateSafeControlJSON` supplies them.
    func embedded(_ bytes: [UInt8]) throws {
        for byte in bytes {
            try sink.put(byte)
        }
    }

    func writeUUID(_ identifier: UUID) throws {
        try writeString(identifier.uuidString)
    }

    func writeInt(_ value: Int) throws {
        try ascii(String(value))
    }

    func writeBool(_ value: Bool) throws {
        try keyword(value ? "true" : "false")
    }

    /// A finite number, written in the shortest form that reads back exactly.
    func writeDouble(_ value: Double) throws {
        guard value.isFinite else {
            throw PrivateConfigurationWireError.invalidValue
        }
        try ascii(String(value))
    }

    // MARK: - Structure

    /// Writes one object. Its members come from `body`, which calls `member`.
    func object(_ body: () throws -> Void) throws {
        let outer = needsSeparator
        needsSeparator = false
        try keyword("{")
        try body()
        try keyword("}")
        needsSeparator = outer
    }

    /// Writes one `"key":` followed by its value. A comma goes first, unless this is the first member.
    func member(_ key: StaticString, _ value: () throws -> Void) throws {
        if needsSeparator {
            try keyword(",")
        }
        needsSeparator = true
        try keyword("\"")
        try keyword(key)
        try keyword("\":")
        try value()
    }

    func array<Element>(_ elements: [Element], _ element: (Element) throws -> Void) throws {
        try keyword("[")
        for (index, value) in elements.enumerated() {
            if index > 0 {
                try keyword(",")
            }
            try element(value)
        }
        try keyword("]")
    }
}

// MARK: - Schema

extension PrivateConfigurationRequest: PrivateFrameRoot {
    static var frameKind: PrivateConfigurationFrame.Kind { .update }

    func writeBody<Sink: PrivateFrameSink>(to emitter: PrivateJSONEmitter<Sink>) throws {
        try emitter.writeRequest(self)
    }
}

extension PrivatePreferencesRequest: PrivateFrameRoot {
    static var frameKind: PrivateConfigurationFrame.Kind { .preferences }

    func writeBody<Sink: PrivateFrameSink>(to emitter: PrivateJSONEmitter<Sink>) throws {
        try emitter.writePreferencesRequest(self)
    }
}

extension PrivateEditorReadRequest: PrivateFrameRoot {
    static var frameKind: PrivateConfigurationFrame.Kind { .read }

    /// A read carries no value, so no resource ceiling applies.
    func resourceViolation() -> DomainResourceViolation? { nil }

    func writeBody<Sink: PrivateFrameSink>(to emitter: PrivateJSONEmitter<Sink>) throws {
        try emitter.writeReadRequest(self)
    }
}

extension PrivateEditorReply: PrivateFrameRoot {
    static var frameKind: PrivateConfigurationFrame.Kind { .editorReply }

    func resourceViolation() -> DomainResourceViolation? {
        guard case .observation(let observation) = answer else { return nil }
        return observation.resourceViolation()
    }

    func writeBody<Sink: PrivateFrameSink>(to emitter: PrivateJSONEmitter<Sink>) throws {
        try emitter.writeReply(self)
    }
}

/// The bytes of the safe control values a private reply carries, written by their own `Codable`. Sorted keys make the
/// bytes the same on the counting and the emitting pass. Only these closed, secret-free control types pass here; a
/// private value has no `Encodable` path at all.
enum PrivateSafeControlJSON {
    static func bytes(_ admission: ControlAdmission) throws -> [UInt8] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do {
            return Array(try encoder.encode(admission))
        } catch {
            throw PrivateConfigurationWireError.invalidValue
        }
    }
}

extension PrivateJSONEmitter {
    func writeReadRequest(_ request: PrivateEditorReadRequest) throws {
        try object {
            try member("requestID") { try writeUUID(request.requestID.rawValue) }
            try member("incarnation") { try writeUUID(request.incarnation.rawValue) }
            try member("budgetMilliseconds") { try writeInt(request.budget.rawValue) }
        }
    }

    func writePreferencesRequest(_ request: PrivatePreferencesRequest) throws {
        try object {
            try member("requestID") { try writeUUID(request.requestID.rawValue) }
            try member("incarnation") { try writeUUID(request.incarnation.rawValue) }
            try member("budgetMilliseconds") { try writeInt(request.budget.rawValue) }
            try member("preferencesBaseline") { try writeBaseline(request.preferencesBaseline) }
            try member("preferences") { try writePreferences(request.preferences) }
        }
    }

    /// Every answer member is written, and all but the one answer are null.
    func writeReply(_ reply: PrivateEditorReply) throws {
        try object {
            try member("requestID") { try writeUUID(reply.requestID.rawValue) }
            try member("hostIncarnation") { try writeUUID(reply.hostIncarnation.rawValue) }
            try member("admission") {
                if case .admission(let admission) = reply.answer {
                    try embedded(PrivateSafeControlJSON.bytes(admission))
                } else {
                    try keyword("null")
                }
            }
            try member("observation") {
                if case .observation(let observation) = reply.answer {
                    try writeObservation(observation)
                } else {
                    try keyword("null")
                }
            }
            try member("refusal") {
                if case .refused(let code) = reply.answer {
                    try writeString(code.rawValue)
                } else {
                    try keyword("null")
                }
            }
        }
    }

    func writeObservation(_ value: PrivateEditorObservation) throws {
        try object {
            try member("terminal") { try writeBool(value.terminal) }
            try member("runtime") { try writeRuntime(value.runtime) }
            try member("platform") { try writePlatform(value.platform) }
            try member("preferences") { try writePreferences(value.preferences) }
            try member("launchAtLogin") { try writeBool(value.launchAtLogin) }
            try member("components") {
                try object {
                    try member("runtime") { try writeComponentState(value.components.runtime) }
                    try member("platform") { try writeComponentState(value.components.platform) }
                    try member("preferences") { try writeComponentState(value.components.preferences) }
                }
            }
            try member("modules") {
                try object {
                    try member("proxy") { try writeModuleState(value.modules.proxy) }
                    try member("dns") { try writeModuleState(value.modules.dns) }
                    try member("tunnels") { try writeModuleState(value.modules.tunnels) }
                }
            }
        }
    }

    private func writePreferences(_ value: PrivatePreferences) throws {
        try object {
            try member("showMenuBarIcon") { try writeBool(value.showMenuBarIcon) }
            try member("floatingWindowEnabled") { try writeBool(value.floatingWindowEnabled) }
            try member("globalShortcutEnabled") { try writeBool(value.globalShortcutEnabled) }
            try member("preferredBrowserTestURL") { try writeURL(value.preferredBrowserTestURL) }
            try member("fileLoggingEnabled") { try writeBool(value.fileLoggingEnabled) }
            try member("automaticUpdateChecks") { try writeBool(value.automaticUpdateChecks) }
        }
    }

    private func writeComponentState(_ value: PrivateComponentState) throws {
        let (kind, baseline, reason): (PrivateComponentStateKind, PrivateBaseline?, PrivateRetainedReason?) = switch value {
        case .verified(let baseline): (.verified, baseline, nil)
        case .absent(let baseline): (.absent, baseline, nil)
        case .retained(let reason): (.retained, nil, reason)
        }
        try object {
            try member("state") { try writeString(kind.rawValue) }
            try member("baseline") {
                if let baseline {
                    try writeBaseline(baseline)
                } else {
                    try keyword("null")
                }
            }
            try member("reason") { try writeOptionalString(reason?.rawValue) }
        }
    }

    private func writeModuleState(_ value: PrivateModuleState) throws {
        try object {
            try member("lifecycleRevision") { try writeInt(value.lifecycleRevision.rawValue) }
            try member("enabled") { try writeBool(value.enabled) }
            try member("fenced") { try writeBool(value.fenced) }
        }
    }

    /// The whole request body. Keys are fixed ASCII names, and every value comes from a typed field.
    func writeRequest(_ request: PrivateConfigurationRequest) throws {
        try object {
            try member("requestID") { try writeUUID(request.requestID.rawValue) }
            try member("incarnation") { try writeUUID(request.incarnation.rawValue) }
            try member("budgetMilliseconds") { try writeInt(request.budget.rawValue) }
            try member("runtimeBaseline") { try writeBaseline(request.runtimeBaseline) }
            try member("platformBaseline") { try writeBaseline(request.platformBaseline) }
            try member("modules") { try writeModuleIntents(request.modules) }
            try member("runtime") { try writeRuntime(request.runtime) }
            try member("platform") { try writePlatform(request.platform) }
        }
    }

    /// The version is written as the exact decimal of the store's `UInt64`, never narrowed.
    func writeBaseline(_ value: PrivateBaseline) throws {
        try object {
            try member("namespace") { try writeUUID(value.namespace.rawValue) }
            try member("component") { try writeString(value.component.rawValue) }
            try member("version") { try ascii(String(value.version)) }
        }
    }

    private func writeModuleIntents(_ value: PrivateModuleSlots<PrivateModuleIntent>) throws {
        guard value.isWellFormed else { throw PrivateConfigurationWireError.invalidValue }
        try object {
            try member("proxy") { try writeModuleIntent(value.proxy) }
            try member("dns") { try writeModuleIntent(value.dns) }
            try member("tunnels") { try writeModuleIntent(value.tunnels) }
        }
    }

    private func writeModuleIntent(_ value: PrivateModuleIntent) throws {
        let (action, revision): (PrivateModuleIntentAction, ControlLifecycleRevision?) = switch value {
        case .saveOnly: (.saveOnly, nil)
        case .applyWhileRunning(let revision): (.applyWhileRunning, revision)
        case .start(let revision): (.start, revision)
        case .conditionalStart(let revision): (.conditionalStart, revision)
        }
        try object {
            try member("action") { try writeString(action.rawValue) }
            try member("lifecycleRevision") {
                if let revision {
                    try writeInt(revision.rawValue)
                } else {
                    try keyword("null")
                }
            }
        }
    }

    private func writeRuntime(_ value: PrivateRuntimeConfiguration) throws {
        try object {
            try member("profileName") { try writeString(value.profileName) }
            try member("proxy") { try writeProxy(value.proxy) }
            try member("auth") { try writeAuth(value.auth) }
            try member("upstreams") { try array(value.upstreams) { try writeUpstream($0) } }
            try member("routing") { try writeRouting(value.routing) }
            try member("dns") { try writeDNS(value.dns) }
            try member("tunnels") { try writeTunnels(value.tunnels) }
            try member("health") { try writeHealth(value.health) }
            try member("logging") { try writeLogging(value.logging) }
        }
    }

    private func writeProxy(_ value: PrivateProxySettings) throws {
        try object {
            try member("host") { try writeString(value.host) }
            try member("port") { try writeInt(value.port) }
            try member("socksEnabled") { try writeBool(value.socksEnabled) }
            try member("socksPort") { try writeInt(value.socksPort) }
            try member("gatewayMode") { try writeBool(value.gatewayMode) }
            try member("allowedClients") { try array(value.allowedClients) { try writeString($0) } }
            try member("maxConnections") { try writeInt(value.maxConnections) }
            try member("stalledConnectionTimeoutSeconds") { try writeDouble(value.stalledConnectionTimeoutSeconds) }
            try member("maxBufferedBodyBytes") { try writeInt(value.maxBufferedBodyBytes) }
            try member("maxSpooledBodyBytes") { try writeInt(value.maxSpooledBodyBytes) }
            try member("inboundConnectionWarnThreshold") { try writeInt(value.inboundConnectionWarnThreshold) }
            try member("inboundConnectionMaxLimit") { try writeInt(value.inboundConnectionMaxLimit) }
            try member("strictMode") { try writeBool(value.strictMode) }
        }
    }

    private func writeAuth(_ value: PrivateAuthSettings) throws {
        try object {
            try member("mode") { try writeString(value.mode.rawValue) }
            try member("username") { try writeString(value.username) }
            try member("domain") { try writeString(value.domain) }
            try member("workstation") { try writeString(value.workstation) }
            try member("pendingHandshakeGlobalLimit") { try writeInt(value.pendingHandshakeGlobalLimit) }
            try member("pendingHandshakesPerSource") { try writeInt(value.pendingHandshakesPerSource) }
        }
    }

    private func writeUpstream(_ value: PrivateUpstreamSettings) throws {
        try object {
            try member("id") { try writeUUID(value.id.rawValue) }
            try member("name") { try writeString(value.name) }
            try member("host") { try writeString(value.host) }
            try member("port") { try writeInt(value.port) }
            try member("enabled") { try writeBool(value.enabled) }
            try member("priority") { try writeInt(value.priority) }
        }
    }

    private func writeRouting(_ value: PrivateRoutingSettings) throws {
        try object {
            try member("pacURL") { try writeURL(value.pacURL) }
            try member("localPACEnabled") { try writeBool(value.localPACEnabled) }
            try member("localPACPort") { try writeInt(value.localPACPort) }
            try member("pacRoutingEnabled") { try writeBool(value.pacRoutingEnabled) }
            try member("pacUsableRouteLimit") { try writeInt(value.pacUsableRouteLimit) }
            try member("noProxyHosts") { try array(value.noProxyHosts) { try writeString($0) } }
            try member("forceProxyHosts") { try array(value.forceProxyHosts) { try writeString($0) } }
        }
    }

    private func writeDNS(_ value: PrivateDNSSettings) throws {
        try object {
            try member("forwarderEnabled") { try writeBool(value.forwarderEnabled) }
            try member("forwarderPort") { try writeInt(value.forwarderPort) }
            try member("dohProviders") { try array(value.dohProviders) { try writeURL($0) } }
            try member("entries") { try array(value.entries) { try writeDNSEntry($0) } }
            try member("interceptRules") { try array(value.interceptRules) { try writeInterceptRule($0) } }
            try member("transparentProxyEnabled") { try writeBool(value.transparentProxyEnabled) }
            try member("transparentProxyIP") { try writeString(value.transparentProxyIP) }
            try member("transparentProxyPort") { try writeInt(value.transparentProxyPort) }
        }
    }

    private func writeDNSEntry(_ value: PrivateDNSEntrySettings) throws {
        try object {
            try member("id") { try writeUUID(value.id.rawValue) }
            try member("domain") { try writeString(value.domain) }
            try member("servers") { try array(value.servers) { try writeString($0) } }
            try member("enabled") { try writeBool(value.enabled) }
        }
    }

    private func writeInterceptRule(_ value: PrivateInterceptRuleSettings) throws {
        try object {
            try member("id") { try writeUUID(value.id.rawValue) }
            try member("pattern") { try writeString(value.pattern) }
            try member("interceptIP") { try writeString(value.interceptIP) }
            try member("enabled") { try writeBool(value.enabled) }
        }
    }

    private func writeTunnels(_ value: PrivateTunnelSettings) throws {
        try object {
            try member("definitions") { try array(value.definitions) { try writeTunnelDefinition($0) } }
            try member("maxSessions") { try writeInt(value.maxSessions) }
            try member("maxSessionsPerTunnel") { try writeInt(value.maxSessionsPerTunnel) }
        }
    }

    private func writeTunnelDefinition(_ value: PrivateTunnelDefinitionSettings) throws {
        try object {
            try member("id") { try writeUUID(value.id.rawValue) }
            try member("localPort") { try writeInt(value.localPort) }
            try member("remoteHost") { try writeString(value.remoteHost) }
            try member("remotePort") { try writeInt(value.remotePort) }
            try member("enabled") { try writeBool(value.enabled) }
            try member("proxied") { try writeBool(value.proxied) }
            try member("label") { try writeString(value.label) }
            try member("preset") { try writeOptionalString(value.preset?.rawValue) }
        }
    }

    private func writeHealth(_ value: PrivateHealthSettings) throws {
        try object {
            try member("checkURL") { try writeURL(value.checkURL) }
            try member("checkIntervalSeconds") { try writeDouble(value.checkIntervalSeconds) }
            try member("connectionCheckTimeoutSeconds") { try writeDouble(value.connectionCheckTimeoutSeconds) }
            try member("upstreamResponseTimeoutSeconds") { try writeDouble(value.upstreamResponseTimeoutSeconds) }
            try member("upstreamConnectTimeoutSeconds") { try writeDouble(value.upstreamConnectTimeoutSeconds) }
            try member("directConnectTTLSeconds") { try writeDouble(value.directConnectTTLSeconds) }
            try member("circuitBreakerWindowSeconds") { try writeDouble(value.circuitBreakerWindowSeconds) }
            try member("circuitFailureThreshold") { try writeInt(value.circuitFailureThreshold) }
            try member("circuitBaseOpenIntervalSeconds") { try writeDouble(value.circuitBaseOpenIntervalSeconds) }
            try member("circuitMaxOpenIntervalSeconds") { try writeDouble(value.circuitMaxOpenIntervalSeconds) }
            try member("vpnFlapGraceSeconds") { try writeDouble(value.vpnFlapGraceSeconds) }
            try member("vpnFlapMinVisibleSeconds") { try writeDouble(value.vpnFlapMinVisibleSeconds) }
        }
    }

    private func writeLogging(_ value: PrivateLoggingSettings) throws {
        try object {
            try member("verbose") { try writeBool(value.verbose) }
            try member("auditLogEnabled") { try writeBool(value.auditLogEnabled) }
            try member("auditLogMaxBytes") { try writeInt(value.auditLogMaxBytes) }
            try member("auditLogPath") { try writeOptionalString(value.auditLogPath) }
        }
    }

    private func writePlatform(_ value: PrivatePlatformConfiguration) throws {
        try object {
            try member("manageSystemProxy") { try writeBool(value.manageSystemProxy) }
            try member("manageEnvironmentVariables") { try writeBool(value.manageEnvironmentVariables) }
            try member("manageDNSResolvers") { try writeBool(value.manageDNSResolvers) }
            try member("manageSystemDNS") { try writeBool(value.manageSystemDNS) }
            try member("systemProxyMode") { try writeString(value.systemProxyMode.rawValue) }
        }
    }
}

// MARK: - Entry point

/// Encodes one value as one complete private frame of its kind: header, body and line feed.
package enum PrivateConfigurationEncoder {
    /// Returns the exact body length of `request`, without building a frame or any buffer.
    package static func measureBody(_ request: PrivateConfigurationRequest) throws -> Int {
        try measure(request)
    }

    /// Returns the request's update frame as redacted bytes.
    package static func encode(_ request: PrivateConfigurationRequest) throws -> SecretBytes {
        try frame(request)
    }

    /// Returns the exact body length of a preferences update, without building a frame or any buffer.
    package static func measureBody(_ request: PrivatePreferencesRequest) throws -> Int {
        try measure(request)
    }

    /// Returns the preferences update frame as redacted bytes.
    package static func encode(_ request: PrivatePreferencesRequest) throws -> SecretBytes {
        try frame(request)
    }

    /// Returns the read frame.
    package static func encode(_ request: PrivateEditorReadRequest) throws -> SecretBytes {
        try frame(request)
    }

    /// Returns the exact body length of `reply`, without building a frame or any buffer.
    package static func measureBody(_ reply: PrivateEditorReply) throws -> Int {
        try measure(reply)
    }

    /// Checks one observation as the reply would carry it, without an envelope: the approved ceilings, then the same
    /// observation writer through a counting sink, so an unrepresentable value (a non-finite number) is refused exactly
    /// as the reply encoder refuses it. It returns the observation's own byte count and builds no buffer. It is a format
    /// preflight, not the reply cap: only `encode(_: PrivateEditorReply)`, with the real request ID and incarnation,
    /// counts and checks the complete frame.
    package static func measureObservation(_ observation: PrivateEditorObservation) throws -> Int {
        if let violation = observation.resourceViolation() {
            throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
        }
        let bodyLimit = PrivateConfigurationFrame.Kind.editorReply.maxFrameBytes - minimumFrameOverhead
        let counting = PrivateJSONEmitter(sink: PrivateCountingSink(limit: bodyLimit))
        try counting.writeObservation(observation)
        return counting.sink.count
    }

    /// Returns the editor reply frame. The reply cap is checked on the exact count before any buffer exists.
    package static func encode(_ reply: PrivateEditorReply) throws -> SecretBytes {
        try frame(reply)
    }

    /// The counting pass of every kind. The approved resource ceilings run first, so an overlimit value is
    /// refused before the writer walks it, and a raw DTO that bypasses the bridge is covered too. The same
    /// writer then runs with a counting sink, so the count is exact, and the pass stops at the first byte past
    /// the kind's body limit: its cap less the smallest header and terminator. It also refuses an
    /// unrepresentable value, exactly as `frame` does.
    static func measure<Root: PrivateFrameRoot>(_ root: Root) throws -> Int {
        if let violation = root.resourceViolation() {
            throw PrivateConfigurationWireError.resourceLimitExceeded(violation)
        }
        let bodyLimit = Root.frameKind.maxFrameBytes - minimumFrameOverhead
        let counting = PrivateJSONEmitter(sink: PrivateCountingSink(limit: bodyLimit))
        try root.writeBody(to: counting)
        return counting.sink.count
    }

    /// The emission pass of every kind. The frame is at most its kind's cap, header and terminator included,
    /// and it is never truncated. An oversize value throws `frameTooLarge` before any frame buffer is allocated.
    static func frame<Root: PrivateFrameRoot>(_ root: Root) throws -> SecretBytes {
        let kind = Root.frameKind
        let bodyCount = try measure(root)

        let header = kind.prefix + Array(String(bodyCount).utf8) + [PrivateConfigurationFrame.lineFeed]
        let total = header.count + bodyCount + 1
        guard total <= kind.maxFrameBytes else {
            throw PrivateConfigurationWireError.frameTooLarge
        }

        let buffer = PrivateFrameBuffer(initialCapacity: total, ceiling: total)
        for byte in header {
            buffer.append(byte)
        }
        let emitting = PrivateJSONEmitter(sink: PrivateBufferSink(buffer: buffer))
        try root.writeBody(to: emitting)
        guard buffer.count == header.count + bodyCount else {
            throw PrivateConfigurationWireError.invalidValue
        }
        buffer.append(PrivateConfigurationFrame.lineFeed)
        let frame = buffer.makeSecretBytes()
        buffer.release()
        return frame
    }
}
