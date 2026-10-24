// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyControlBridge
@testable import ProxyKernel

/// Mapping tests for the private configuration bridge. They compare the real `ProxyConfig`
/// against the DTOs, through the real encoder, reader and decoder, so every field goes through
/// the same bytes a transfer would carry.
final class PrivateConfigBridgeTests: XCTestCase {
    private struct Failure: Error {
        let message: String
    }

    /// Every legacy flat key `ProxyConfig` encodes, mapped to the DTO field that carries it.
    /// The inventory test ties this table to the keys the real encoder writes.
    private static let legacyKeyPaths: [String: String] = [
        "profileName": "runtime.profileName",
        "localHost": "runtime.proxy.host", "localPort": "runtime.proxy.port",
        "socksEnabled": "runtime.proxy.socksEnabled", "socksPort": "runtime.proxy.socksPort",
        "gatewayMode": "runtime.proxy.gatewayMode", "allowedClients": "runtime.proxy.allowedClients",
        "maxConnections": "runtime.proxy.maxConnections",
        "stalledConnectionTimeoutSeconds": "runtime.proxy.stalledConnectionTimeoutSeconds",
        "maxBufferedBodyBytes": "runtime.proxy.maxBufferedBodyBytes",
        "maxSpooledBodyBytes": "runtime.proxy.maxSpooledBodyBytes",
        "inboundConnectionWarnThreshold": "runtime.proxy.inboundConnectionWarnThreshold",
        "inboundConnectionMaxLimit": "runtime.proxy.inboundConnectionMaxLimit",
        "strictMode": "runtime.proxy.strictMode",
        "authMode": "runtime.auth.mode", "username": "runtime.auth.username", "domain": "runtime.auth.domain",
        "workstation": "runtime.auth.workstation",
        "pendingAuthHandshakeGlobalLimit": "runtime.auth.pendingHandshakeGlobalLimit",
        "pendingAuthHandshakesPerSource": "runtime.auth.pendingHandshakesPerSource",
        "upstreams": "runtime.upstreams",
        "pacURL": "runtime.routing.pacURL", "localPACEnabled": "runtime.routing.localPACEnabled",
        "localPACPort": "runtime.routing.localPACPort", "pacRoutingEnabled": "runtime.routing.pacRoutingEnabled",
        "pacUsableRouteLimit": "runtime.routing.pacUsableRouteLimit",
        "noProxyHosts": "runtime.routing.noProxyHosts", "forceProxyHosts": "runtime.routing.forceProxyHosts",
        "dnsForwarderEnabled": "runtime.dns.forwarderEnabled", "dnsForwarderPort": "runtime.dns.forwarderPort",
        "dohProviders": "runtime.dns.dohProviders", "dnsEntries": "runtime.dns.entries",
        "dnsInterceptRules": "runtime.dns.interceptRules",
        "transparentProxyEnabled": "runtime.dns.transparentProxyEnabled",
        "transparentProxyIP": "runtime.dns.transparentProxyIP", "transparentProxyPort": "runtime.dns.transparentProxyPort",
        "tunnelDefinitions": "runtime.tunnels.definitions", "maxTunnelSessions": "runtime.tunnels.maxSessions",
        "maxSessionsPerTunnel": "runtime.tunnels.maxSessionsPerTunnel",
        "healthCheckURL": "runtime.health.checkURL", "healthCheckIntervalSeconds": "runtime.health.checkIntervalSeconds",
        // The legacy millisecond and minute keys truncate. The DTO carries the canonical seconds.
        "connectionCheckTimeoutMS": "runtime.health.connectionCheckTimeoutSeconds",
        "upstreamResponseTimeoutSeconds": "runtime.health.upstreamResponseTimeoutSeconds",
        "upstreamConnectTimeoutSeconds": "runtime.health.upstreamConnectTimeoutSeconds",
        "directConnectTTLMinutes": "runtime.health.directConnectTTLSeconds",
        "circuitBreakerWindowSeconds": "runtime.health.circuitBreakerWindowSeconds",
        "circuitFailureThreshold": "runtime.health.circuitFailureThreshold",
        "circuitBaseOpenIntervalSeconds": "runtime.health.circuitBaseOpenIntervalSeconds",
        "circuitMaxOpenIntervalSeconds": "runtime.health.circuitMaxOpenIntervalSeconds",
        "vpnFlapGraceSeconds": "runtime.health.vpnFlapGraceSeconds",
        "vpnFlapMinVisibleSeconds": "runtime.health.vpnFlapMinVisibleSeconds",
        "verboseLogging": "runtime.logging.verbose", "auditLogEnabled": "runtime.logging.auditLogEnabled",
        "auditLogMaxBytes": "runtime.logging.auditLogMaxBytes", "auditLogPath": "runtime.logging.auditLogPath",
    ]

    // MARK: - Inventory

    func testInventoryMatchesTheKeysTheKernelEncodes() throws {
        let encoded = try JSONEncoder().encode(richConfig())
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        // `schemaVersion` is a file-format marker, so it is the one stored key the DTO omits.
        let expected = Set(Self.legacyKeyPaths.keys).union(["schemaVersion"])
        XCTAssertEqual(Set(object.keys), expected)
        // `Codable` omits a nil optional. `richConfig` sets `auditLogPath`, so the key is present here.
        // A config with no audit path would encode without the key, and the inventory would not see it.
        XCTAssertNotNil(object["auditLogPath"])
        // 55 stored keys, plus `schemaVersion`, which the encoder also writes and the DTO omits.
        XCTAssertEqual(Self.legacyKeyPaths.count, 55)
    }

    func testEnumMirrorsMatchTheKernelRawValues() {
        XCTAssertEqual(
            PrivateAuthenticationMode.allCases.map(\.rawValue),
            AuthenticationMode.allCases.map(\.rawValue)
        )
        XCTAssertEqual(
            PrivateSystemProxyMode.allCases.map(\.rawValue),
            SystemProxyMode.allCases.map(\.rawValue)
        )
        XCTAssertEqual(
            PrivateTunnelPreset.allCases.map(\.rawValue),
            TunnelPreset.allCases.map(\.rawValue)
        )
    }

    // MARK: - Mapping and round trip

    func testFullMappingRoundTripPreservesEveryValueThroughTheFrame() throws {
        let config = richConfig()
        XCTAssertEqual(config.validate().map(\.check), [], "the rich fixture must be a valid config")
        let platform = richPlatform(launchAtLogin: true)
        let request = try makeRequest(config: config, platform: platform)

        let frame = try PrivateConfigurationEncoder.encode(request)
        let body = try readOneByteAtATime(frame.bytes())
        let decoded = try PrivateConfigurationDecoder.decode(body)
        XCTAssertEqual(decoded, request)

        let restored = try PrivateConfigurationBridge.makeValues(from: decoded, localLaunchAtLogin: true)
        XCTAssertEqual(restored.config, config)
        XCTAssertEqual(restored.platform, platform)
    }

    func testFractionalDurationsSurviveWithoutLegacyTruncation() throws {
        let config = richConfig()
        let restored = try PrivateConfigurationBridge.makeValues(
            from: try makeRequest(config: config, platform: richPlatform(launchAtLogin: false)),
            localLaunchAtLogin: false
        )
        XCTAssertEqual(restored.config.health.connectionCheckTimeout, 0.25)
        XCTAssertEqual(restored.config.health.directConnectTTL, 90.5)
        XCTAssertEqual(restored.config.connectionCheckTimeoutMS, 250)
    }

    func testCollectionIdentifiersAndTunnelPresetsArePreserved() throws {
        let config = richConfig()
        let restored = try PrivateConfigurationBridge.makeValues(
            from: try makeRequest(config: config, platform: richPlatform(launchAtLogin: false)),
            localLaunchAtLogin: false
        )
        XCTAssertEqual(restored.config.upstreams.map(\.id), config.upstreams.map(\.id))
        XCTAssertEqual(restored.config.dnsEntries.map(\.id), config.dnsEntries.map(\.id))
        XCTAssertEqual(restored.config.dnsInterceptRules.map(\.id), config.dnsInterceptRules.map(\.id))
        XCTAssertEqual(restored.config.tunnelDefinitions.map(\.id), config.tunnelDefinitions.map(\.id))
        XCTAssertEqual(restored.config.tunnelDefinitions.map(\.preset), config.tunnelDefinitions.map(\.preset))
        XCTAssertEqual(restored.config.auditLogPath, "/tmp/conduit-audit-test.ndjson")
    }

    func testPortZeroIsAcceptedByTheBridge() throws {
        let config = richConfig()
        XCTAssertEqual(config.proxy.port, 0)
        let restored = try PrivateConfigurationBridge.makeValues(
            from: try makeRequest(config: config, platform: richPlatform(launchAtLogin: false)),
            localLaunchAtLogin: false
        )
        XCTAssertEqual(restored.config.proxy.port, 0)
    }

    // MARK: - Local launch-at-login

    func testLaunchAtLoginIsTakenFromTheLocalInputNeverDefaulted() throws {
        let request = try makeRequest(config: richConfig(), platform: richPlatform(launchAtLogin: true))
        XCTAssertEqual(
            try PrivateConfigurationBridge.makeValues(from: request, localLaunchAtLogin: true).platform.launchAtLogin,
            true
        )
        XCTAssertEqual(
            try PrivateConfigurationBridge.makeValues(from: request, localLaunchAtLogin: false).platform.launchAtLogin,
            false
        )
    }

    // MARK: - Resource ceilings

    /// The display ceiling refuses a 9 MB name by its length, before validation or mapping.
    func testOversizeProfileNameIsRefusedByItsCeilingBeforeMapping() throws {
        var config = richConfig()
        config.profileName = String(repeating: "a", count: 9_000_000)
        XCTAssertThrowsError(try makeRequest(config: config, platform: richPlatform(launchAtLogin: false))) {
            XCTAssertEqual($0 as? PrivateConfigurationBridgeError, .resourceLimit(DomainResourceViolation(.profileName, 1_024)))
        }
    }

    /// A list is refused by its count, so 4,194,305 empty strings never reach a `PrivateURLValue` or `SecretBytes`.
    func testDenseEmptyStringsAreRefusedByCountBeforeMapping() throws {
        var config = richConfig()
        config.routing.noProxyHosts = Array(repeating: "", count: 4_194_305)
        XCTAssertThrowsError(try makeRequest(config: config, platform: richPlatform(launchAtLogin: false))) {
            XCTAssertEqual($0 as? PrivateConfigurationBridgeError, .resourceLimit(DomainResourceViolation(.noProxyHosts, 256)))
        }
    }

    /// The rule count is refused at 257 rules whatever they hold. The typed check alone accepts exactly 256.
    func testInterceptRuleCountIsCeilingNotCost() throws {
        var config = richConfig()
        let rule = DNSInterceptRule(id: uuid(900), pattern: "", interceptIP: "", enabled: false)
        config.dns.interceptRules = Array(repeating: rule, count: 257)
        XCTAssertEqual(
            config.resourceViolation(),
            DomainResourceViolation(.interceptRules, 256)
        )
        config.dns.interceptRules = Array(repeating: rule, count: 256)
        XCTAssertNil(config.resourceViolation())
    }

    /// Every item is checked, not only the first: a 254-byte bypass entry after 255 short ones is refused.
    func testOverlongLastBypassEntryIsRefusedNotOnlyTheFirst() throws {
        var config = richConfig()
        config.routing.noProxyHosts = Array(repeating: "a", count: 255) + [String(repeating: "b", count: 254)]
        XCTAssertEqual(config.resourceViolation(), DomainResourceViolation(.noProxyPattern, 253))
    }

    /// An approved value whose escapes make its frame several times its decoded size is accepted and reads back
    /// unchanged. The 1,024-byte ceiling holds for the decoded bytes, and the frame is counted exactly.
    func testEscapedApprovedValueIsAcceptedAndReadsBackUnchanged() throws {
        var config = richConfig()
        config.profileName = String(repeating: "\"\\\u{01}", count: 256) + "🙂é"
        XCTAssertLessThanOrEqual(config.profileName.utf8.count, 1_024)
        let request = try makeRequest(config: config, platform: richPlatform(launchAtLogin: false))
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        XCTAssertGreaterThan(try bodyCount(of: frame), config.profileName.utf8.count)
        let restored = try PrivateConfigurationBridge.makeValues(
            from: try PrivateConfigurationDecoder.decode(readFrameBody(frame)),
            localLaunchAtLogin: false
        )
        XCTAssertEqual(restored.config.profileName, config.profileName)
    }

    /// The in-memory entry point takes a request that was never framed, so it counts the request exactly.
    func testMakeValuesRefusesAnOversizeInMemoryRequestBeforeMapping() throws {
        var request = try PrivateConfigSamples.request()
        request.runtime.profileName = String(repeating: "a", count: PrivateConfigurationFrame.maxFrameBytes)
        XCTAssertThrowsError(try PrivateConfigurationBridge.makeValues(from: request, localLaunchAtLogin: false)) {
            XCTAssertEqual(
                $0 as? PrivateConfigurationBridgeError,
                .resourceLimit(DomainResourceViolation(.profileName, 1_024))
            )
        }
    }

    /// The in-memory entry point refuses an unrepresentable value with the codec's fixed error.
    func testMakeValuesRefusesAnUnrepresentableInMemoryValue() throws {
        var request = try PrivateConfigSamples.request()
        request.runtime.health.checkIntervalSeconds = .infinity
        XCTAssertThrowsError(try PrivateConfigurationBridge.makeValues(from: request, localLaunchAtLogin: false)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidValue)
        }
    }

    // MARK: - Boundary errors

    func testValidationErrorsNameFieldsAndNeverEchoAToken() throws {
        var config = richConfig()
        config.routing.pacURL = "https://user:TOKEN-XYZ-9@pac.example.test/p.pac"
        do {
            _ = try makeRequest(config: config, platform: richPlatform(launchAtLogin: false))
            XCTFail("a URL with userinfo must not pass validation")
        } catch let error as PrivateConfigurationBridgeError {
            guard case .invalidConfiguration(let firstCheck, let failureCount) = error else {
                throw Failure(message: "expected invalidConfiguration")
            }
            XCTAssertGreaterThan(failureCount, 0)
            XCTAssertFalse(firstCheck.contains("TOKEN-XYZ-9"))
            XCTAssertFalse(String(describing: error).contains("TOKEN-XYZ-9"))
        }
    }

    /// Many checks fail, but the error carries one field code and a count, not a copy of each check.
    func testManyFailingChecksAreSummarisedAsOneCodeAndACount() throws {
        var config = richConfig()
        config.proxy.port = 70_000
        config.proxy.socksPort = 70_000
        config.dns.forwarderPort = 70_000
        do {
            _ = try makeRequest(config: config, platform: richPlatform(launchAtLogin: false))
            XCTFail("out-of-range ports must not pass validation")
        } catch let error as PrivateConfigurationBridgeError {
            guard case .invalidConfiguration(let firstCheck, let failureCount) = error else {
                throw Failure(message: "expected invalidConfiguration")
            }
            XCTAssertEqual(firstCheck, "invalid_port field=proxy.port")
            XCTAssertGreaterThanOrEqual(failureCount, 3)
        }
    }

    // MARK: - Helpers

    private func makeRequest(
        config: ProxyConfig,
        platform: PlatformIntegrationConfig
    ) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationBridge.makeRequest(
            config: config,
            platform: platform,
            requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(101)),
            incarnation: ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(102)),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 7)),
            expectedPlatformRevision: try XCTUnwrap(PrivatePlatformRevision(rawValue: 6)),
            expectedOwnerGeneration: try XCTUnwrap(PrivateConfigExpectedGeneration(rawValue: 5))
        )
    }

    /// The body of one complete frame, read through the real reader.
    private func readFrameBody(_ frame: [UInt8]) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader()
        guard case .frame(let body) = try reader.consume(frame).step else {
            throw Failure(message: "the frame did not complete")
        }
        return body
    }

    /// The body length a frame's header declares.
    private func bodyCount(of frame: [UInt8]) throws -> Int {
        let lineFeed = try XCTUnwrap(frame.firstIndex(of: 0x0A))
        let header = String(decoding: frame[..<lineFeed], as: UTF8.self)
        return try XCTUnwrap(Int(header.dropFirst("PCV1 Q ".count)))
    }

    /// Feeds one frame to the reader one byte at a time and returns its body.
    private func readOneByteAtATime(_ bytes: [UInt8]) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader()
        for (offset, byte) in bytes.enumerated() {
            let (step, consumed) = try reader.consume([byte])
            XCTAssertEqual(consumed, 1)
            if case .frame(let body) = step {
                XCTAssertEqual(offset, bytes.count - 1, "the frame ended before its last byte")
                return body
            }
        }
        throw Failure(message: "the frame never completed")
    }

    private func uuid(_ number: Int) -> UUID {
        PrivateConfigSamples.uuid(number)
    }

    private func richPlatform(launchAtLogin: Bool) -> PlatformIntegrationConfig {
        PlatformIntegrationConfig(
            manageSystemProxy: true,
            manageEnvironmentVariables: true,
            manageDNSResolvers: true,
            manageSystemDNS: false,
            systemProxyMode: .pac,
            launchAtLogin: launchAtLogin
        )
    }

    /// A valid config in which every stored field differs from its default.
    private func richConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.profileName = "Café 🙂 \"quoted\" \\ tab\t"
        config.proxy = ProxySection(
            host: "127.0.0.1", port: 0, socksEnabled: true, socksPort: 1081, gatewayMode: true,
            allowedClients: ["127.0.0.1", "::1", "10.0.0.5"], maxConnections: 321,
            stalledConnectionTimeout: 47.5, maxBufferedBodyBytes: 1_000_000, maxSpooledBodyBytes: 2_000_000,
            inboundConnectionWarnThreshold: 900, inboundConnectionMaxLimit: 9_000, strictMode: false
        )
        config.auth = AuthSection(
            mode: .ntlmv2, username: "alice", domain: "CORP", workstation: "WS-1",
            pendingHandshakeGlobalLimit: 400, pendingHandshakesPerSource: 100
        )
        config.upstreams = [
            UpstreamProxy(id: uuid(31), name: "primary", host: "proxy-a.example.test", port: 8080, enabled: false, priority: 2),
            UpstreamProxy(id: uuid(32), name: "secondary", host: "proxy-b.example.test", port: 8443, enabled: true, priority: 1),
        ]
        config.routing = RoutingSection(
            pacURL: "https://pac.example.test/proxy.pac?token=PAC-SECRET-1", localPACEnabled: false,
            localPACPort: 63_146, pacRoutingEnabled: false, pacUsableRouteLimit: 17,
            noProxyHosts: ["localhost", "*.corp.example.test"], forceProxyHosts: ["force.example.test"]
        )
        config.dns = DNSSection(
            forwarderEnabled: true, forwarderPort: 5_054,
            dohProviders: ["https://1.1.1.1/dns-query?key=DOH-SECRET-1", "https://9.9.9.9/dns-query"],
            entries: [DomainDNSEntry(id: uuid(41), domain: "corp.example.test", servers: ["10.1.2.3", "10.1.2.4"], enabled: true)],
            interceptRules: [DNSInterceptRule(id: uuid(51), pattern: "*.intercept.example.test", interceptIP: "127.44.3.9", enabled: false)],
            transparentProxyEnabled: true, transparentProxyIP: "127.44.3.1", transparentProxyPort: 10_444
        )
        config.tunnels = TunnelSection(
            definitions: [
                TunnelDefinition(id: uuid(61), localPort: 15_432, remoteHost: "db.example.test", remotePort: 5_432,
                                 enabled: true, proxied: true, label: "Orders DB", preset: .postgresql),
                TunnelDefinition(id: uuid(62), localPort: 16_379, remoteHost: "cache.example.test", remotePort: 6_379,
                                 enabled: false, proxied: false, label: "", preset: nil),
            ],
            maxSessions: 64, maxSessionsPerTunnel: 8
        )
        config.health = HealthSection(
            checkURL: "https://health.example.test/ok?token=HEALTH-SECRET-1",
            checkInterval: 31.5, connectionCheckTimeout: 0.25, upstreamResponseTimeout: 44.5,
            upstreamConnectTimeout: 5.5, directConnectTTL: 90.5, circuitBreakerWindowSeconds: 11.5,
            circuitFailureThreshold: 6, circuitBaseOpenIntervalSeconds: 31.5,
            circuitMaxOpenIntervalSeconds: 301.5, vpnFlapGraceSeconds: 5.5, vpnFlapMinVisibleSeconds: 1.5
        )
        config.logging = LoggingSection(
            verbose: true, auditLogEnabled: true, auditLogMaxBytes: 5_242_880,
            auditLogPath: "/tmp/conduit-audit-test.ndjson"
        )
        return config
    }
}
