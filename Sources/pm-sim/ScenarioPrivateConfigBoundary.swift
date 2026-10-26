// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import ProxyControlBridge
import ProxyKernel

/// The private configuration frame and its bridge, headless: map, encode, cap, split reads,
/// refusals and decode back, with no server, no socket and no machine effect. It drives the real
/// bridge, encoder, reader and decoder.
enum PrivateConfigBoundaryScenario {
    private struct Failure: Error { let message: String }

    static func run() throws -> ScenarioResult {
        let started = Date()
        let token = "SIM-TOKEN-42"
        let request = try sampleRequest(pacURL: "https://pac.example.test/p.pac?token=\(token)")
        let frame = try PrivateConfigurationEncoder.encode(request)
        let bytes = frame.withUnsafeBytes { Array($0) }

        // The reader accepts the frame in every schedule, and each schedule decodes to the same request.
        var segmentationsMatch = true
        for chunk in [1, 7, 613, 4_096, 16_384] {
            let decoded = try decodeFrame(bytes, chunk: chunk)
            segmentationsMatch = segmentationsMatch && decoded == request
        }

        // The token is absent from every reflection path. The values are not Encodable.
        let described = String(describing: request) + String(reflecting: request)
            + String(describing: request.runtime.routing.pacURL) + String(reflecting: request.runtime.routing.pacURL)
        let mirrored = Mirror(reflecting: request).children.map { "\($0.value)" }.joined()
        let redacted = !described.contains(token) && !mirrored.contains(token)
        let notEncodable = (request as Any) as? any Encodable == nil

        // The cap is the whole frame. The frame is at most the cap. A raw body one byte past it is refused by the
        // decoder before any value is scanned. An approved ceiling refuses a name one byte over its limit first.
        let withinCap = frame.count <= PrivateConfigurationFrame.maxRequestFrameBytes
        let overCeiling = try sampleRequest(pacURL: "https://pac.example.test/p.pac", profileName: String(repeating: "a", count: 1_025))
        let refusesOversize = refusal(of: { try PrivateConfigurationEncoder.encode(overCeiling) })
            == .resourceLimitExceeded(DomainResourceViolation(.profileName, 1_024))
        let headerEnd = (bytes.firstIndex(of: 0x0A) ?? 0) + 1
        let frameBody = Array(bytes[headerEnd..<(bytes.count - 1)])
        let padded = frameBody + Array(repeating: UInt8(ascii: " "), count: PrivateConfigurationFrame.maxRequestFrameBytes - 15 - frameBody.count)
        let capPlusOneRefused = refusal(of: {
            try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(kind: .update, bytes: SecretBytes(padded)))
        }) == .frameTooLarge

        // The header refusals happen before a body is read, and they leave nothing buffered.
        let versionReader = PrivateConfigurationFrameReader(expecting: .update)
        let versionRefused = refusal(of: { try versionReader.consume(Array("PCV2 Q 5\n".utf8)) }) == .unsupportedVersion
        let lengthReader = PrivateConfigurationFrameReader(expecting: .update)
        let lengthRefused = refusal(of: { try lengthReader.consume(Array("PCV1 Q 8388593\n".utf8)) }) == .frameTooLarge
        let nothingBuffered = lengthReader.retainedByteCount == 0

        // A duplicate key is refused by the decoder before any value is read.
        let duplicate = String(decoding: bytes[(bytes.firstIndex(of: 0x0A)! + 1)..<(bytes.count - 1)], as: UTF8.self)
            .replacingOccurrences(of: "\"strictMode\":true", with: "\"strictMode\":true,\"strictMode\":false")
        let duplicateFrame = Array("PCV1 Q \(duplicate.utf8.count)\n".utf8) + Array(duplicate.utf8) + [0x0A]
        let duplicateRefused = refusal(of: {
            let reader = PrivateConfigurationFrameReader(expecting: .update)
            guard case .frame(let body) = try reader.consume(duplicateFrame).step else {
                throw Failure(message: "the duplicate-key reference frame did not complete")
            }
            _ = try PrivateConfigurationDecoder.decode(body)
        }) == .malformedBody

        // The preconditions are exact. The sample's runtime baseline is `UInt64.max`, and every schedule above decoded it
        // and all three module intents unchanged. One past the maximum, a platform baseline in the runtime slot, and a
        // save-only intent that names a revision are each refused, never narrowed, swapped or defaulted.
        let bodyText = String(decoding: frameBody, as: UTF8.self)
        let maxBaselineKept = request.runtimeBaseline.version == UInt64.max
            && bodyText.contains("\"version\":18446744073709551615")
        let overMaxRefused = refusal(of: {
            try decodeText(bodyText.replacingOccurrences(
                of: "\"version\":18446744073709551615", with: "\"version\":18446744073709551616"))
        }) == .malformedBody
        let swappedRefused = refusal(of: {
            try decodeText(bodyText.replacingOccurrences(
                of: "\"component\":\"platform\"", with: "\"component\":\"runtime\""))
        }) == .malformedBody
        let saveOnlyRevisionRefused = refusal(of: {
            try decodeText(bodyText.replacingOccurrences(
                of: "\"action\":\"saveOnly\",\"lifecycleRevision\":null",
                with: "\"action\":\"saveOnly\",\"lifecycleRevision\":1"))
        }) == .malformedBody

        // The actual bridge: the kernel's stored values map to the request, the frame carries them,
        // and the decoded request maps back to the same config and platform.
        let config = ProxyConfig.testFixture()
        let platform = PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac, launchAtLogin: true)
        let bridgeFrame = try PrivateConfigurationEncoder.encode(try makeBridgeRequest(config: config, platform: platform))
        let restored = try PrivateConfigurationBridge.makeValues(
            from: try decodeFrame(bridgeFrame.withUnsafeBytes { Array($0) }, chunk: 613),
            localLaunchAtLogin: true
        )
        let bridgeRoundTrip = restored.config == config && restored.platform == platform

        // The bridge refuses an oversize name by its ceiling before any value is mapped.
        var oversizeConfig = config
        oversizeConfig.profileName = String(repeating: "a", count: 9_000_000)
        let bridgeRefusesOversize = bridgeRefusal(of: { try makeBridgeRequest(config: oversizeConfig, platform: platform) })
            == .resourceLimit(DomainResourceViolation(.profileName, 1_024))

        // The bridge does not refuse a semantic draft: it maps and round-trips, and the eligibility classification
        // names the field and never the URL token. This is pure mapping and classification, not a physical apply proof.
        let bridgeToken = "BRIDGE-TOKEN-5"
        var tokenDraft = config
        tokenDraft.routing.pacURL = "https://user:\(bridgeToken)@pac.example.test/p.pac"
        let tokenRequest = try makeBridgeRequest(config: tokenDraft, platform: platform)
        let tokenMapped = try throughFrame(tokenDraft, platform: platform)
        let tokenChecks = tokenMapped.startBlockingProblems.map(\.check)
        let semanticDraftMapped = tokenMapped == tokenDraft && tokenChecks == ["invalid_host field=routing.pacURL"]
        let tokenAbsent = !String(describing: tokenChecks).contains(bridgeToken)
            && !String(describing: tokenRequest).contains(bridgeToken)

        // An out-of-range port is an Int, so it crosses the frame and is held by classification, not refused.
        var portDraft = config
        portDraft.proxy.port = 70_000
        let portMapped = try throughFrame(portDraft, platform: platform)
        let portHeld = portMapped == portDraft && portMapped.startBlockingProblems.map(\.check) == ["invalid_port field=proxy.port"]

        // Intercept problems are non-blocking and stay inside every cap: they map, and classification never holds a start.
        var nonBlocking = config
        nonBlocking.dns.interceptRules = [
            DNSInterceptRule(id: uuid(52), pattern: "not a domain!!", interceptIP: "not-an-ip", enabled: true),
        ]
        let nonBlockingMapped = try throughFrame(nonBlocking, platform: platform)
        let nonBlockingHeld = nonBlockingMapped == nonBlocking
            && nonBlockingMapped.startBlockingProblems.isEmpty
            && !nonBlocking.validate().isEmpty

        // A bypass list past its count ceiling is a resource refusal before mapping, as bypass problems always are here.
        var longBypass = config
        longBypass.routing.noProxyHosts = Array(repeating: "short.example", count: 256) + ["another.example"]
        let bypassRefused = bridgeRefusal(of: { try makeBridgeRequest(config: longBypass, platform: platform) })
            == .resourceLimit(DomainResourceViolation(.noProxyHosts, 256))

        // A non-finite number is still the codec's refusal at the bridge.
        var nonFinite = config
        nonFinite.health.checkInterval = .infinity
        let nonFiniteRefused = refusal(of: { try makeBridgeRequest(config: nonFinite, platform: platform) }) == .invalidValue

        let checks: [ScenarioAssertion] = [
            .init("every read schedule decodes to the same request", segmentationsMatch),
            .init("the URL token is absent from every reflection path", redacted),
            .init("the private request is not Encodable", notEncodable),
            .init("the frame fits the cap", withinCap),
            .init("an approved ceiling refuses an oversize name before a frame exists", refusesOversize),
            .init("a body one byte past the cap is refused by the decoder before any value is scanned", capPlusOneRefused),
            .init("an unsupported version is refused in the header", versionRefused),
            .init("an oversize declared length is refused with no body byte buffered", lengthRefused && nothingBuffered),
            .init("a duplicate key is refused by the decoder", duplicateRefused),
            .init("a UInt64.max baseline version round-trips exactly", maxBaselineKept),
            .init("a baseline version one past UInt64.max is refused", overMaxRefused),
            .init("a baseline in the other file's slot is refused", swappedRefused),
            .init("a save-only intent that names a lifecycle revision is refused", saveOnlyRevisionRefused),
            .init("the bridge maps the fixture config and platform through the frame and back unchanged", bridgeRoundTrip),
            .init("the bridge refuses an oversize name by its ceiling before mapping", bridgeRefusesOversize),
            .init("a semantic draft with a URL token maps through the frame and is classified by field code, never by its token", semanticDraftMapped && tokenAbsent),
            .init("an out-of-range port maps through the frame and is held by classification, not refused", portHeld),
            .init("a non-blocking intercept draft maps through the frame and does not hold a start", nonBlockingHeld),
            .init("a bypass list past its count ceiling is refused by resource before mapping", bypassRefused),
            .init("a non-finite duration stays a codec refusal at the bridge", nonFiniteRefused),
        ]
        let passed = checks.allSatisfy(\.passed)
        guard passed else {
            throw Failure(message: "private configuration boundary assertions failed: \(checks.filter { !$0.passed }.map(\.name))")
        }
        return ScenarioResult(
            name: "private-config-boundary", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: frame.count, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["PASS: private request frame round-trips at every read schedule with exact UInt64 baselines and per-module intents, the bridge maps the fixture config through the frame, keeps URL tokens out of reflection, refuses oversize, unsupported and duplicate-key input, and maps semantic drafts with their eligibility classification (pure mapping, not a physical apply proof)"]
        )
    }

    /// Feeds `bytes` to a fresh reader in pieces of `chunk` and decodes the frame it yields.
    private static func decodeFrame(_ bytes: [UInt8], chunk: Int) throws -> PrivateConfigurationRequest {
        let reader = PrivateConfigurationFrameReader(expecting: .update)
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunk, bytes.count)
            let (step, consumed) = try reader.consume(bytes[offset..<end])
            offset += consumed
            if case .frame(let body) = step {
                guard offset == bytes.count else {
                    throw Failure(message: "bytes followed the frame")
                }
                return try PrivateConfigurationDecoder.decode(body)
            }
        }
        throw Failure(message: "the input ended inside the frame")
    }

    /// Decodes a raw update body through the production decoder, with no reader or encoder involved.
    private static func decodeText(_ text: String) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(kind: .update, bytes: SecretBytes(Array(text.utf8))))
    }

    /// The bridge's request for `config`, carried through the frame and decoded, then mapped back to values.
    private static func throughFrame(_ config: ProxyConfig, platform: PlatformIntegrationConfig) throws -> ProxyConfig {
        let frame = try PrivateConfigurationEncoder.encode(try makeBridgeRequest(config: config, platform: platform))
        let decoded = try decodeFrame(frame.withUnsafeBytes { Array($0) }, chunk: 613)
        return try PrivateConfigurationBridge.makeValues(from: decoded, localLaunchAtLogin: true).config
    }

    /// The wire error a throwing step produced, or nil when it succeeded.
    private static func refusal(of step: () throws -> some Any) -> PrivateConfigurationWireError? {
        do {
            _ = try step()
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }

    /// The bridge error a throwing step produced, or nil when it succeeded.
    private static func bridgeRefusal(of step: () throws -> some Any) -> PrivateConfigurationBridgeError? {
        do {
            _ = try step()
            return nil
        } catch {
            return error as? PrivateConfigurationBridgeError
        }
    }

    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number)) ?? UUID()
    }

    private static func makeBridgeRequest(
        config: ProxyConfig,
        platform: PlatformIntegrationConfig
    ) throws -> PrivateConfigurationRequest {
        let preconditions = try samplePreconditions()
        return try PrivateConfigurationBridge.makeRequest(
            config: config,
            platform: platform,
            requestID: ControlRequestID(rawValue: uuid(101)),
            incarnation: ControlHostIncarnation(rawValue: uuid(102)),
            budget: try ControlWireBudget(5_000),
            runtimeBaseline: preconditions.runtime,
            platformBaseline: preconditions.platform,
            modules: preconditions.modules
        )
    }

    /// The preconditions every sample carries: exact baselines in one store namespace, the runtime one at the widest
    /// version, and one module of each intent. Internal, not private: `ConfigResourceBoundsScenario` uses them too.
    static func samplePreconditions() throws -> (
        runtime: PrivateBaseline, platform: PrivateBaseline, modules: PrivateModuleSlots<PrivateModuleIntent>
    ) {
        guard let started = ControlLifecycleRevision(rawValue: 9), let running = ControlLifecycleRevision(rawValue: 7) else {
            throw Failure(message: "sample lifecycle revisions are not representable")
        }
        let namespace = PrivateBaselineNamespace(rawValue: uuid(3))
        return (
            PrivateBaseline(namespace: namespace, component: .runtime, version: .max),
            PrivateBaseline(namespace: namespace, component: .platform, version: 3),
            PrivateModuleSlots(
                proxy: .start(ifLifecycleRevision: started),
                dns: .applyWhileRunning(ifLifecycleRevision: running),
                tunnels: .saveOnly
            )
        )
    }

    /// Internal, not private: `ConfigResourceBoundsScenario` builds its raw bodies from the same sample.
    static func sampleRequest(
        pacURL: String,
        profileName: String = "sim-profile"
    ) throws -> PrivateConfigurationRequest {
        let preconditions = try samplePreconditions()
        return try PrivateConfigurationRequest(
            requestID: ControlRequestID(rawValue: uuid(1)),
            incarnation: ControlHostIncarnation(rawValue: uuid(2)),
            budget: try ControlWireBudget(5_000),
            runtimeBaseline: preconditions.runtime,
            platformBaseline: preconditions.platform,
            modules: preconditions.modules,
            runtime: PrivateRuntimeConfiguration(
                profileName: profileName,
                proxy: PrivateProxySettings(
                    host: "127.0.0.1", port: 0, socksEnabled: false, socksPort: 1080, gatewayMode: false,
                    allowedClients: ["127.0.0.1", "::1"], maxConnections: 5_000,
                    stalledConnectionTimeoutSeconds: 45, maxBufferedBodyBytes: 16_777_216,
                    maxSpooledBodyBytes: 268_435_456, inboundConnectionWarnThreshold: 1_000,
                    inboundConnectionMaxLimit: 10_000, strictMode: true
                ),
                auth: PrivateAuthSettings(
                    mode: .systemNegotiated, username: "u", domain: "", workstation: "w",
                    pendingHandshakeGlobalLimit: 512, pendingHandshakesPerSource: 128
                ),
                upstreams: [],
                routing: PrivateRoutingSettings(
                    pacURL: PrivateURLValue(pacURL), localPACEnabled: false, localPACPort: 63_145,
                    pacRoutingEnabled: true, pacUsableRouteLimit: 32, noProxyHosts: ["localhost"], forceProxyHosts: []
                ),
                dns: PrivateDNSSettings(
                    forwarderEnabled: false, forwarderPort: 5_053,
                    dohProviders: [PrivateURLValue("https://1.1.1.1/dns-query")], entries: [], interceptRules: [],
                    transparentProxyEnabled: false, transparentProxyIP: "127.44.3.0", transparentProxyPort: 10_443
                ),
                tunnels: PrivateTunnelSettings(definitions: [], maxSessions: 128, maxSessionsPerTunnel: 32),
                health: PrivateHealthSettings(
                    checkURL: PrivateURLValue("http://detectportal.firefox.com/success.txt"),
                    checkIntervalSeconds: 30, connectionCheckTimeoutSeconds: 0.25, upstreamResponseTimeoutSeconds: 45,
                    upstreamConnectTimeoutSeconds: 5, directConnectTTLSeconds: 90.5, circuitBreakerWindowSeconds: 10,
                    circuitFailureThreshold: 5, circuitBaseOpenIntervalSeconds: 30, circuitMaxOpenIntervalSeconds: 300,
                    vpnFlapGraceSeconds: 5, vpnFlapMinVisibleSeconds: 1
                ),
                logging: PrivateLoggingSettings(verbose: false, auditLogEnabled: false, auditLogMaxBytes: 10_485_760, auditLogPath: nil)
            ),
            platform: PrivatePlatformConfiguration(
                manageSystemProxy: true, manageEnvironmentVariables: false, manageDNSResolvers: false,
                manageSystemDNS: true, systemProxyMode: .pac
            )
        )
    }
}
