// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class ConfigTests: XCTestCase {
    func testFixtureHasThreeUpstreams() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.upstreams.count, 3)
        XCTAssertEqual(config.upstreams[0].host, "proxy-a.example.test")
        XCTAssertEqual(config.upstreams[1].host, "proxy-b.example.test")
        XCTAssertEqual(config.upstreams[2].host, "proxy-c.example.test")
    }

    func testFixtureUsesGenericDefaultsForNewFields() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.pacURL, "")
        XCTAssertFalse(config.localPACEnabled)
        XCTAssertTrue(config.pacRoutingEnabled)
        XCTAssertEqual(config.dohProviders.count, 3)
        XCTAssertEqual(config.connectionCheckTimeoutMS, 2000)
        XCTAssertEqual(config.upstreamResponseTimeoutSeconds, 45)
        XCTAssertEqual(config.directConnectTTLMinutes, 5)
        XCTAssertTrue(config.strictMode)
        XCTAssertFalse(config.verboseLogging)
    }

    func testEffectiveListenHostInGatewayMode() {
        var config = ProxyConfig.testFixture()
        XCTAssertEqual(config.effectiveListenHost, "127.0.0.1")
        config.gatewayMode = true
        XCTAssertEqual(config.effectiveListenHost, "0.0.0.0")
    }

    func testForceProxyHostsDefaultIsEmpty() {
        let config = ProxyConfig.testFixture()
        XCTAssertTrue(config.forceProxyHosts.isEmpty)
    }

    func testEnabledUpstreamsSortedByPriority() {
        var config = ProxyConfig.testFixture()
        config.upstreams[0].priority = 99
        config.upstreams[1].priority = 0
        let sorted = config.enabledUpstreams
        XCTAssertEqual(sorted.first?.host, "proxy-b.example.test")
        XCTAssertEqual(sorted.last?.host, "proxy-a.example.test")
    }

    func testUpstreamOrderingMovesRowsAndRenumbersPriorities() {
        let config = ProxyConfig.testFixture()
        let moved = UpstreamOrdering.moving(
            config.upstreams,
            id: config.upstreams[2].id,
            before: config.upstreams[0].id
        )

        XCTAssertEqual(moved.map(\.host), [
            "proxy-c.example.test",
            "proxy-a.example.test",
            "proxy-b.example.test",
        ])
        XCTAssertEqual(moved.map(\.priority), [0, 1, 2])
    }

    func testUpstreamOrderingCanMoveRowsToEnd() {
        let config = ProxyConfig.testFixture()
        let moved = UpstreamOrdering.moving(config.upstreams, id: config.upstreams[0].id, before: nil)

        XCTAssertEqual(moved.map(\.host), [
            "proxy-b.example.test",
            "proxy-c.example.test",
            "proxy-a.example.test",
        ])
        XCTAssertEqual(moved.map(\.priority), [0, 1, 2])
    }

    func testDisabledUpstreamsExcluded() {
        var config = ProxyConfig.testFixture()
        config.upstreams[0].enabled = false
        XCTAssertEqual(config.enabledUpstreams.count, 2)
    }

    func testConfigRoundTrip() throws {
        let original = ProxyConfig.testFixture()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertEqual(original.profileName, decoded.profileName)
        XCTAssertEqual(original.localPort, decoded.localPort)
        XCTAssertEqual(original.socksPort, decoded.socksPort)
        XCTAssertEqual(original.maxConnections, decoded.maxConnections)
        XCTAssertEqual(original.gatewayMode, decoded.gatewayMode)
        XCTAssertEqual(original.tunnelDefinitions.count, decoded.tunnelDefinitions.count)
        XCTAssertEqual(original.connectionCheckTimeoutMS, decoded.connectionCheckTimeoutMS)
        XCTAssertEqual(original.upstreamResponseTimeoutSeconds, decoded.upstreamResponseTimeoutSeconds)
        XCTAssertEqual(original.directConnectTTLMinutes, decoded.directConnectTTLMinutes)
        XCTAssertEqual(original.strictMode, decoded.strictMode)
        XCTAssertEqual(original.verboseLogging, decoded.verboseLogging)
        XCTAssertEqual(original.pacRoutingEnabled, decoded.pacRoutingEnabled)
        XCTAssertEqual(original.upstreams.count, decoded.upstreams.count)
    }

    func testConfigDecodesWithMissingNewFields() throws {
        let json = """
        {
            "profileName": "Test",
            "localHost": "127.0.0.1",
            "localPort": 3128,
            "socksPort": 1080,
            "authMode": "ntlmv2",
            "username": "user",
            "domain": "DOM",
            "workstation": "WS",
            "upstreams": [],
            "pacURL": "",
            "localPACEnabled": false,
            "systemProxyMode": "manual",
            "manageSystemProxy": true,
            "manageEnvironmentVariables": false,
            "manageDNSResolvers": false,
            "dnsEntries": [],
            "noProxyHosts": ["localhost"],
            "forceProxyHosts": [],
            "healthCheckURL": "",
            "healthCheckIntervalSeconds": 30,
            "stalledConnectionTimeoutSeconds": 45,
            "maxConnections": 1000,
            "gatewayMode": false,
            "allowedClients": [],
            "socksEnabled": false,
            "autoEnableOnVPN": false,
            "autoDisableOffVPN": false,
            "launchAtLogin": false,
            "showMenuBarIcon": true,
            "floatingWindowEnabled": false,
            "globalShortcutEnabled": false,
            "preferredBrowserTestURL": "",
            "tunnelDefinitions": []
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(decoded.profileName, "Test")
        XCTAssertEqual(decoded.maxConnections, 1000)
        XCTAssertEqual(decoded.connectionCheckTimeoutMS, 2000, "Missing field should get default")
        XCTAssertEqual(decoded.upstreamResponseTimeoutSeconds, 45, "Missing field should get independent default")
        XCTAssertEqual(decoded.directConnectTTLMinutes, 5, "Missing field should get default")
        XCTAssertTrue(decoded.strictMode, "Missing field should get default")
        XCTAssertFalse(decoded.verboseLogging, "Missing field should get default")
        XCTAssertTrue(decoded.pacRoutingEnabled, "Missing field should get default")
    }

    func testTunnelDefinitionDescription() {
        let tunnel = TunnelDefinition(localPort: 5000, remoteHost: "example.com", remotePort: 22)
        XCTAssertEqual(tunnel.description, "5000:example.com:22")
    }

    func testNoProxyForceProxyInteraction() {
        let noProxy = ["10.*", "*.local"]
        let forceProxy = ["10.0.0.1"]

        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "10.0.0.2", patterns: noProxy, forceProxy: forceProxy))
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "10.0.0.1", patterns: noProxy, forceProxy: forceProxy),
                       "forceProxy should override noProxy")
    }

    func testLocalProxyURL() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.localProxyURL, "http://127.0.0.1:3128")
    }

    // MARK: - New security config fields

    func testNewSecurityFieldsDefaults() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.maxBufferedBodyBytes, 16_777_216)
        XCTAssertEqual(config.inboundConnectionWarnThreshold, 1000)
        XCTAssertEqual(config.inboundConnectionMaxLimit, 10000)
    }

    func testNewSecurityFieldsDecodeWhenMissing() throws {
        let json = #"{}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.maxBufferedBodyBytes, 16_777_216)
        XCTAssertEqual(config.inboundConnectionWarnThreshold, 1000)
        XCTAssertEqual(config.inboundConnectionMaxLimit, 10000)
    }

    func testNewSecurityFieldsDecodeExplicitValues() throws {
        let json = #"{"maxBufferedBodyBytes": 5242880, "inboundConnectionWarnThreshold": 500, "inboundConnectionMaxLimit": 5000}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.maxBufferedBodyBytes, 5_242_880)
        XCTAssertEqual(config.inboundConnectionWarnThreshold, 500)
        XCTAssertEqual(config.inboundConnectionMaxLimit, 5000)
    }

    func testValidationRejectsShellUnsafeProxyHostAndNoProxyEntries() {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1\"; touch /tmp/pwned #"
        config.noProxyHosts = ["example.com", "$(touch /tmp/pwned)"]

        let messages = config.validate().compactMap(\.errorDescription)

        XCTAssertTrue(messages.contains { $0.contains("proxy.host") })
        XCTAssertTrue(messages.contains { $0.contains("routing.noProxyHosts[1]") })
    }

    func testValidationRejectsPACURLUserInfo() {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://user:secret@example.com/proxy.pac"

        let messages = config.validate().compactMap(\.errorDescription)

        XCTAssertTrue(messages.contains { $0.contains("routing.pacURL") })
    }
}
