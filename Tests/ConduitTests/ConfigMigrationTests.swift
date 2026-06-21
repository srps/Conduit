// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class ConfigMigrationTests: XCTestCase {

    // MARK: - Backward-compatible decoding

    func testOldConfigWithThreeUpstreamsDecodesSuccessfully() throws {
        let json = """
        {
            "profileName": "Example Corporate",
            "localHost": "127.0.0.1",
            "localPort": 3128,
            "socksPort": 1080,
            "authMode": "ntlmv2",
            "username": "testuser",
            "domain": "EMEA",
            "workstation": "Mac",
            "upstreams": [
                {"id": "A1A1A1A1-A1A1-A1A1-A1A1-A1A1A1A1A1A1", "name": "Germany", "host": "proxy-a.example.test", "port": 8080, "enabled": true, "priority": 0},
                {"id": "B2B2B2B2-B2B2-B2B2-B2B2-B2B2B2B2B2B2", "name": "North America", "host": "proxy-b.example.test", "port": 8080, "enabled": true, "priority": 1},
                {"id": "C3C3C3C3-C3C3-C3C3-C3C3-C3C3C3C3C3C3", "name": "APAC", "host": "proxy-c.example.test", "port": 8080, "enabled": true, "priority": 2}
            ],
            "pacURL": "",
            "localPACEnabled": false,
            "systemProxyMode": "manual",
            "manageSystemProxy": true,
            "manageEnvironmentVariables": true,
            "manageDNSResolvers": false,
            "dnsEntries": [],
            "noProxyHosts": ["localhost", "127.0.0.1"],
            "forceProxyHosts": ["aka.ms"],
            "healthCheckURL": "http://detectportal.firefox.com/success.txt",
            "healthCheckIntervalSeconds": 30,
            "stalledConnectionTimeoutSeconds": 45,
            "maxConnections": 5000,
            "gatewayMode": false,
            "allowedClients": ["127.0.0.1", "::1"],
            "socksEnabled": false,
            "autoEnableOnVPN": false,
            "autoDisableOffVPN": false,
            "launchAtLogin": false,
            "showMenuBarIcon": true,
            "floatingWindowEnabled": false,
            "globalShortcutEnabled": true,
            "preferredBrowserTestURL": "https://www.example.test/",
            "tunnelDefinitions": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.upstreams.count, 3)
        XCTAssertEqual(config.connectionCheckTimeoutMS, 2000)
        XCTAssertEqual(config.upstreamResponseTimeoutSeconds, 45)
        XCTAssertEqual(config.directConnectTTLMinutes, 5)
        XCTAssertTrue(config.strictMode)
        XCTAssertFalse(config.verboseLogging)
        XCTAssertTrue(config.pacRoutingEnabled)
    }

    func testNewFieldsPreservedWhenPresent() throws {
        let json = """
        {
            "profileName": "Custom",
            "localHost": "127.0.0.1",
            "localPort": 3128,
            "socksPort": 1080,
            "authMode": "ntlmv2",
            "username": "u",
            "domain": "D",
            "workstation": "W",
            "upstreams": [],
            "pacURL": "",
            "localPACEnabled": false,
            "pacRoutingEnabled": false,
            "systemProxyMode": "pac",
            "manageSystemProxy": false,
            "manageEnvironmentVariables": false,
            "manageDNSResolvers": false,
            "dnsEntries": [],
            "noProxyHosts": [],
            "forceProxyHosts": [],
            "healthCheckURL": "",
            "healthCheckIntervalSeconds": 60,
            "stalledConnectionTimeoutSeconds": 90,
            "maxConnections": 2000,
            "connectionCheckTimeoutMS": 1000,
            "upstreamResponseTimeoutSeconds": 12,
            "directConnectTTLMinutes": 15,
            "strictMode": false,
            "verboseLogging": true,
            "gatewayMode": true,
            "allowedClients": ["10.0.0.0/8"],
            "socksEnabled": true,
            "autoEnableOnVPN": true,
            "autoDisableOffVPN": true,
            "launchAtLogin": true,
            "showMenuBarIcon": false,
            "floatingWindowEnabled": true,
            "globalShortcutEnabled": false,
            "preferredBrowserTestURL": "https://custom.test/",
            "tunnelDefinitions": []
        }
        """.data(using: .utf8)!

        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.connectionCheckTimeoutMS, 1000)
        XCTAssertEqual(config.upstreamResponseTimeoutSeconds, 12)
        XCTAssertEqual(config.directConnectTTLMinutes, 15)
        XCTAssertFalse(config.strictMode)
        XCTAssertTrue(config.verboseLogging)
        XCTAssertFalse(config.pacRoutingEnabled)
        XCTAssertTrue(config.gatewayMode)
    }

    func testCompletelyEmptyJSONUsesAllDefaults() throws {
        let json = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        let defaults = ProxyConfig.testFixture()
        XCTAssertEqual(config.localPort, defaults.localPort)
        XCTAssertEqual(config.connectionCheckTimeoutMS, defaults.connectionCheckTimeoutMS)
        XCTAssertEqual(config.upstreamResponseTimeoutSeconds, defaults.upstreamResponseTimeoutSeconds)
        XCTAssertEqual(config.directConnectTTLMinutes, defaults.directConnectTTLMinutes)
        XCTAssertEqual(config.strictMode, defaults.strictMode)
        XCTAssertEqual(config.pacRoutingEnabled, defaults.pacRoutingEnabled)
        XCTAssertEqual(config.maxConnections, defaults.maxConnections)
    }

    // MARK: - Upstream merge logic

    func testMergeAddsNewUpstreamsToExisting() {
        var config = ProxyConfig.testFixture()
        config.upstreams = [
            UpstreamProxy(name: "Germany", host: "proxy-a.example.test", port: 8080, priority: 0),
            UpstreamProxy(name: "NA", host: "proxy-b.example.test", port: 8080, priority: 1)
        ]

        let existingCount = config.upstreams.count
        let defaults = ProxyConfig.testFixture()
        let existingHosts = Set(config.upstreams.map(\.host))
        let nextPriority = (config.upstreams.map(\.priority).max() ?? -1) + 1
        var added = 0
        for upstream in defaults.upstreams where !existingHosts.contains(upstream.host) {
            var newUpstream = upstream
            newUpstream.priority = nextPriority + added
            newUpstream.id = UUID()
            config.upstreams.append(newUpstream)
            added += 1
        }

        XCTAssertEqual(config.upstreams.count, 3)
        XCTAssertGreaterThan(added, 0)
        XCTAssertEqual(config.upstreams.count, existingCount + added)

        XCTAssertEqual(config.upstreams[0].host, "proxy-a.example.test")
        XCTAssertEqual(config.upstreams[0].priority, 0, "Existing proxy priorities should be preserved")
        XCTAssertEqual(config.upstreams[1].host, "proxy-b.example.test")
        XCTAssertEqual(config.upstreams[1].priority, 1, "Existing proxy priorities should be preserved")
    }

    func testMergeDoesNotDuplicateExistingUpstreams() {
        var config = ProxyConfig.testFixture()
        let originalCount = config.upstreams.count

        let defaults = ProxyConfig.testFixture()
        let existingHosts = Set(config.upstreams.map(\.host))
        for upstream in defaults.upstreams where !existingHosts.contains(upstream.host) {
            config.upstreams.append(upstream)
        }

        XCTAssertEqual(config.upstreams.count, originalCount, "No duplicates should be added when all upstreams already exist")
    }

    func testMergeWithEmptyConfigAddsAllDefaults() {
        var config = ProxyConfig.testFixture()
        config.upstreams = []

        let defaults = ProxyConfig.testFixture()
        let existingHosts = Set(config.upstreams.map(\.host))
        for upstream in defaults.upstreams where !existingHosts.contains(upstream.host) {
            config.upstreams.append(upstream)
        }

        XCTAssertEqual(config.upstreams.count, 3)
    }

    // MARK: - Test fixture upstreams

    func testAllFixtureUpstreamsPresent() {
        let config = ProxyConfig.testFixture()
        let hosts = config.upstreams.map(\.host)
        let expectedHosts = [
            "proxy-a.example.test",
            "proxy-b.example.test",
            "proxy-c.example.test"
        ]
        for expected in expectedHosts {
            XCTAssertTrue(hosts.contains(expected), "Missing upstream: \(expected)")
        }
    }

    func testAllUpstreamPrioritiesAreUnique() {
        let config = ProxyConfig.testFixture()
        let priorities = config.upstreams.map(\.priority)
        XCTAssertEqual(Set(priorities).count, priorities.count, "Each upstream should have a unique priority")
    }

    func testAllUpstreamsDefaultPort8080() {
        let config = ProxyConfig.testFixture()
        for upstream in config.upstreams {
            XCTAssertEqual(upstream.port, 8080, "\(upstream.name) should default to port 8080")
        }
    }
}
