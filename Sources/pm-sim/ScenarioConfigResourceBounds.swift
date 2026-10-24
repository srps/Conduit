// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import ProxyControlBridge
import ProxyKernel

/// The approved configuration resource ceilings (decisions 0021 and 0022), headless. It drives the kernel's
/// typed check, the bridge, the codec's count pass and the decoder's scanner, with no server, no socket and
/// no machine effect. The full field-by-field matrix is in `ConfigurationResourceLimitsTests`; this scenario
/// covers one place per kind and the scanner's refusal order.
enum ConfigResourceBoundsScenario {
    private struct Failure: Error { let message: String }

    /// A string place, the prefix its values start with, and how a value sets on a fixture config.
    private struct StringPlace: Sendable {
        let field: DomainResourceField
        let prefix: String
        let set: @Sendable (inout ProxyConfig, String) -> Void
    }

    private static let stringPlaces: [StringPlace] = [
        StringPlace(field: .profileName, prefix: "", set: { $0.profileName = $1 }),
        StringPlace(field: .authUsername, prefix: "", set: { $0.auth.username = $1 }),
        StringPlace(field: .auditLogPath, prefix: "/", set: { $0.logging.auditLogPath = $1 }),
        StringPlace(field: .proxyHost, prefix: "", set: { $0.proxy.host = $1 }),
        StringPlace(field: .upstreamHost, prefix: "", set: { $0.upstreams = [UpstreamProxy(name: "Upstream", host: $1, port: 8_080, priority: 0)] }),
        StringPlace(field: .pacURL, prefix: "https://", set: { $0.routing.pacURL = $1 }),
        StringPlace(field: .checkURL, prefix: "https://", set: { $0.health.checkURL = $1 }),
        StringPlace(field: .dohProvider, prefix: "https://", set: { $0.dns.dohProviders = [$1] }),
        StringPlace(field: .noProxyPattern, prefix: "", set: { $0.routing.noProxyHosts = [$1] }),
        StringPlace(field: .forceProxyPattern, prefix: "", set: { $0.routing.forceProxyHosts = [$1] }),
        StringPlace(field: .allowedClient, prefix: "", set: { $0.proxy.allowedClients = [$1] }),
        StringPlace(field: .transparentProxyIP, prefix: "", set: { $0.dns.transparentProxyIP = $1 }),
        StringPlace(field: .interceptPattern, prefix: "*.", set: {
            $0.dns.interceptRules = [DNSInterceptRule(id: UUID(), pattern: $1, interceptIP: "127.0.0.2", enabled: false)]
        }),
    ]

    static func run() throws -> ScenarioResult {
        let started = Date()
        let platform = PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac, launchAtLogin: true)
        var checks: [ScenarioAssertion] = []

        // Each string place: the exact ceiling is accepted by the kernel check, and one byte over is refused by it
        // and by the bridge, before validation or mapping, with the same field and ceiling.
        for place in stringPlaces {
            let limit = place.field.utf8Limit(wildcardPrefix: place.prefix.hasPrefix("*."))
            let exact = place.prefix + String(repeating: "a", count: limit - place.prefix.utf8.count)
            let over = exact + "a"
            var accepted = fixture()
            place.set(&accepted, exact)
            var refused = fixture()
            place.set(&refused, over)
            let expected = DomainResourceViolation(place.field, limit)
            let kernelAccepts = accepted.resourceViolation() == nil
            let kernelRefuses = refused.resourceViolation() == expected
            let bridgeRefuses = bridgeRefusal(of: { try makeBridgeRequest(config: refused, platform: platform) })
                == .resourceLimit(expected)
            checks.append(.init("\(place.field) accepts its exact ceiling", kernelAccepts))
            checks.append(.init("\(place.field) refuses one byte over, by field and ceiling, in kernel and bridge", kernelRefuses && bridgeRefuses))
        }

        // Every list is refused by its count, including a list of zero-byte items.
        var upstreams = fixture()
        upstreams.upstreams = Array(
            repeating: UpstreamProxy(name: "Upstream", host: "p.example.test", port: 8_080, priority: 0),
            count: 33
        )
        checks.append(.init("upstreams refuse 33 items by count", upstreams.resourceViolation() == DomainResourceViolation(.upstreams, 32)))
        var bypass = fixture()
        bypass.routing.noProxyHosts = Array(repeating: "", count: 257)
        checks.append(.init("zero-byte bypass entries are counted, 257 refused", bypass.resourceViolation() == DomainResourceViolation(.noProxyHosts, 256)))
        var rules = fixture()
        rules.dns.interceptRules = Array(
            repeating: DNSInterceptRule(id: UUID(), pattern: "", interceptIP: "", enabled: false),
            count: 257
        )
        checks.append(.init("intercept rules refuse 257 disabled rules", rules.resourceViolation() == DomainResourceViolation(.interceptRules, 256)))

        // The scanner refuses a bound by its own error, before Foundation decodes. A malformed value after the
        // ceiling is still refused as a bound, not as a grammar error, so the scanner stopped at the ceiling.
        let sample = try PrivateConfigBoundaryScenario.sampleRequest(pacURL: "https://pac.example.test/p.pac")
        let body = try bodyText(of: sample)
        // `\u00e9` is two decoded bytes, so 512 of them are exactly 1,024. One more byte is refused by field.
        let escapedExact = String(repeating: "\\u00e9", count: 512)
        let escapedAccepted = wireRefusal(of: {
            try decodeBody(body.replacingOccurrences(of: "\"sim-profile\"", with: "\"\(escapedExact)\""))
        }) == nil
        checks.append(.init("an escaped name at exactly 1,024 decoded bytes is accepted", escapedAccepted))
        let escapedOver = wireRefusal(of: {
            try decodeBody(body.replacingOccurrences(of: "\"sim-profile\"", with: "\"\(escapedExact)a\""))
        })
        checks.append(.init(
            "an escaped name one byte past its ceiling is refused by the scanner, by field",
            escapedOver == .resourceLimitExceeded(DomainResourceViolation(.profileName, 1_024))
        ))
        // The ninth DoH provider is malformed, but the count refuses it first: the scanner never reads it.
        let nineProviders = "\"dohProviders\":[\"https://1.1.1.1/dns-query\",\"a\",\"a\",\"a\",\"a\",\"a\",\"a\",\"a\",@]"
        let countFirst = wireRefusal(of: {
            try decodeBody(body.replacingOccurrences(of: "\"dohProviders\":[\"https://1.1.1.1/dns-query\"]", with: nineProviders))
        })
        checks.append(.init(
            "a ninth DoH provider is refused by count before its malformed value is read",
            countFirst == .resourceLimitExceeded(DomainResourceViolation(.dohProviders, 8))
        ))
        // An unknown key is refused at its name, so the malformed value under it is never reached.
        let unknown = wireRefusal(of: {
            try decodeBody(body.replacingOccurrences(of: "\"strictMode\":true", with: "\"strictMode\":true,\"zz\":{\"a\":[@]}"))
        })
        checks.append(.init("an unknown key is refused by name, before its value", unknown == .malformedBody))
        // A duplicate spelled with an escape is still a duplicate.
        let escapedDuplicate = wireRefusal(of: {
            try decodeBody(body.replacingOccurrences(of: "\"strictMode\":true", with: "\"\\u0073trictMode\":false,\"strictMode\":true"))
        })
        checks.append(.init("an escaped duplicate key is refused", escapedDuplicate == .malformedBody))
        // The encoder refuses an overlimit DTO before it writes a frame, so a raw DTO cannot bypass the bridge.
        let overDTO = try PrivateConfigBoundaryScenario.sampleRequest(
            pacURL: "https://pac.example.test/p.pac",
            profileName: String(repeating: "a", count: 1_025)
        )
        let encoderRefuses = wireRefusal(of: { try PrivateConfigurationEncoder.encode(overDTO) })
        checks.append(.init(
            "the encoder refuses an overlimit DTO before writing a frame",
            encoderRefuses == .resourceLimitExceeded(DomainResourceViolation(.profileName, 1_024))
        ))
        return finish(started: started, checks: checks)
    }

    // MARK: - Helpers

    private static func fixture() -> ProxyConfig {
        ProxyConfig.testFixture()
    }

    private static func bridgeRefusal(of step: () throws -> some Any) -> PrivateConfigurationBridgeError? {
        do {
            _ = try step()
            return nil
        } catch {
            return error as? PrivateConfigurationBridgeError
        }
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
            requestID: ControlRequestID(rawValue: PrivateConfigBoundaryScenario.uuid(101)),
            incarnation: ControlHostIncarnation(rawValue: PrivateConfigBoundaryScenario.uuid(102)),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: configRevision,
            expectedPlatformRevision: platformRevision,
            expectedOwnerGeneration: generation
        )
    }

    /// The request body as text, without its header and terminator.
    private static func bodyText(of request: PrivateConfigurationRequest) throws -> String {
        let frame = try PrivateConfigurationEncoder.encode(request).withUnsafeBytes { Array($0) }
        let start = try firstLineFeed(frame) + 1
        return String(decoding: frame[start..<(frame.count - 1)], as: UTF8.self)
    }

    private static func firstLineFeed(_ bytes: [UInt8]) throws -> Int {
        guard let index = bytes.firstIndex(of: 0x0A) else {
            throw Failure(message: "the frame has no header line feed")
        }
        return index
    }

    /// The wire error a throwing step produced, or nil when it succeeded.
    private static func wireRefusal(of step: () throws -> some Any) -> PrivateConfigurationWireError? {
        do {
            _ = try step()
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }

    /// Decodes a raw body through the production decoder, as a frame body with no encoder involved.
    private static func decodeBody(_ text: String) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(bytes: SecretBytes(Array(text.utf8))))
    }

    private static func finish(started: Date, checks: [ScenarioAssertion]) -> ScenarioResult {
        ScenarioResult(
            name: "config-resource-bounds", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: checks,
            notes: ["PASS: approved ceilings accept exact values and refuse one byte over in the kernel check and the bridge; the scanner refuses by field before decode"]
        )
    }
}
