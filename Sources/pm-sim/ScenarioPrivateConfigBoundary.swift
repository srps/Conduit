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
        let withinCap = frame.count <= PrivateConfigurationFrame.maxFrameBytes
        let overCeiling = try sampleRequest(pacURL: "https://pac.example.test/p.pac", profileName: String(repeating: "a", count: 1_025))
        let refusesOversize = refusal(of: { try PrivateConfigurationEncoder.encode(overCeiling) })
            == .resourceLimitExceeded(DomainResourceViolation(.profileName, 1_024))
        let headerEnd = (bytes.firstIndex(of: 0x0A) ?? 0) + 1
        let frameBody = Array(bytes[headerEnd..<(bytes.count - 1)])
        let padded = frameBody + Array(repeating: UInt8(ascii: " "), count: PrivateConfigurationFrame.maxFrameBytes - 15 - frameBody.count)
        let capPlusOneRefused = refusal(of: {
            try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(bytes: SecretBytes(padded)))
        }) == .frameTooLarge

        // The header refusals happen before a body is read, and they leave nothing buffered.
        let versionReader = PrivateConfigurationFrameReader()
        let versionRefused = refusal(of: { try versionReader.consume(Array("PCV2 Q 5\n".utf8)) }) == .unsupportedVersion
        let lengthReader = PrivateConfigurationFrameReader()
        let lengthRefused = refusal(of: { try lengthReader.consume(Array("PCV1 Q 8388593\n".utf8)) }) == .frameTooLarge
        let nothingBuffered = lengthReader.retainedByteCount == 0

        // A duplicate key is refused by the decoder before any value is read.
        let duplicate = String(decoding: bytes[(bytes.firstIndex(of: 0x0A)! + 1)..<(bytes.count - 1)], as: UTF8.self)
            .replacingOccurrences(of: "\"strictMode\":true", with: "\"strictMode\":true,\"strictMode\":false")
        let duplicateFrame = Array("PCV1 Q \(duplicate.utf8.count)\n".utf8) + Array(duplicate.utf8) + [0x0A]
        let duplicateRefused = refusal(of: {
            let reader = PrivateConfigurationFrameReader()
            guard case .frame(let body) = try reader.consume(duplicateFrame).step else {
                throw Failure(message: "the duplicate-key reference frame did not complete")
            }
            _ = try PrivateConfigurationDecoder.decode(body)
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

        // The bridge refuses an invalid config with one field code and a count, never the URL token.
        let bridgeToken = "BRIDGE-TOKEN-5"
        var invalidConfig = config
        invalidConfig.routing.pacURL = "https://user:\(bridgeToken)@pac.example.test/p.pac"
        let invalid = bridgeRefusal(of: { try makeBridgeRequest(config: invalidConfig, platform: platform) })
        var invalidRefused = false
        if case .invalidConfiguration(let firstCheck, let failureCount)? = invalid {
            invalidRefused = failureCount > 0 && !firstCheck.contains(bridgeToken)
                && !String(describing: invalid).contains(bridgeToken)
        }

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
            .init("the bridge maps the fixture config and platform through the frame and back unchanged", bridgeRoundTrip),
            .init("the bridge refuses an oversize name by its ceiling before mapping", bridgeRefusesOversize),
            .init("the bridge refuses an invalid config by field code and count, never by its token", invalidRefused),
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
            notes: ["PASS: private request frame round-trips at every read schedule, the bridge maps the fixture config through the frame, keeps URL tokens out of reflection, and refuses oversize, unsupported, duplicate-key and invalid input"]
        )
    }

    /// Feeds `bytes` to a fresh reader in pieces of `chunk` and decodes the frame it yields.
    private static func decodeFrame(_ bytes: [UInt8], chunk: Int) throws -> PrivateConfigurationRequest {
        let reader = PrivateConfigurationFrameReader()
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
        guard let configRevision = ControlConfigRevision(rawValue: 7),
              let platformRevision = PrivatePlatformRevision(rawValue: 6),
              let generation = PrivateConfigExpectedGeneration(rawValue: 5)
        else {
            throw Failure(message: "bridge revisions are not representable")
        }
        return try PrivateConfigurationBridge.makeRequest(
            config: config,
            platform: platform,
            requestID: ControlRequestID(rawValue: uuid(101)),
            incarnation: ControlHostIncarnation(rawValue: uuid(102)),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: configRevision,
            expectedPlatformRevision: platformRevision,
            expectedOwnerGeneration: generation
        )
    }

    /// Internal, not private: `ConfigResourceBoundsScenario` builds its raw bodies from the same sample.
    static func sampleRequest(
        pacURL: String,
        profileName: String = "sim-profile"
    ) throws -> PrivateConfigurationRequest {
        guard let config = ControlConfigRevision(rawValue: 4),
              let platform = PrivatePlatformRevision(rawValue: 3),
              let generation = PrivateConfigExpectedGeneration(rawValue: 9)
        else {
            throw Failure(message: "sample revisions are not representable")
        }
        return PrivateConfigurationRequest(
            requestID: ControlRequestID(rawValue: uuid(1)),
            incarnation: ControlHostIncarnation(rawValue: uuid(2)),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: config,
            expectedPlatformRevision: platform,
            expectedOwnerGeneration: generation,
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
