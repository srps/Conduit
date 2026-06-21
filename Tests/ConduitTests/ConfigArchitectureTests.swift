// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class ConfigArchitectureTests: XCTestCase {

    // MARK: - Section Aliases

    func testFlatAliasesMatchSectionStorage() {
        var config = ProxyConfig.testFixture()
        config.proxy.port = 9999
        config.auth.mode = .ntlmv2
        config.routing.pacRoutingEnabled = false
        config.dns.forwarderPort = 7777
        config.tunnels.maxSessions = 32
        config.health.checkInterval = 60
        config.health.upstreamResponseTimeout = 12
        config.logging.verbose = true

        XCTAssertEqual(config.localPort, 9999)
        XCTAssertEqual(config.authMode, .ntlmv2)
        XCTAssertFalse(config.pacRoutingEnabled)
        XCTAssertEqual(config.dnsForwarderPort, 7777)
        XCTAssertEqual(config.maxTunnelSessions, 32)
        XCTAssertEqual(config.healthCheckIntervalSeconds, 60)
        XCTAssertEqual(config.upstreamResponseTimeoutSeconds, 12)
        XCTAssertTrue(config.verboseLogging)
    }

    func testFlatAliasWriteUpdatesSection() {
        var config = ProxyConfig()
        config.localPort = 4444
        config.authMode = .ntlmv2
        config.dnsForwarderPort = 8888
        config.upstreamResponseTimeoutSeconds = 9

        XCTAssertEqual(config.proxy.port, 4444)
        XCTAssertEqual(config.auth.mode, .ntlmv2)
        XCTAssertEqual(config.dns.forwarderPort, 8888)
        XCTAssertEqual(config.health.upstreamResponseTimeout, 9)
    }

    /// The SwiftUI sliders
    /// in `SettingsView` write through `config.vpnFlap…Seconds` flat
    /// accessors, then `AppState.saveConfig` round-trips the whole
    /// `ProxyConfig` through Codable. Verify the two new flat accessors
    /// behave like every other section alias — read/write through to
    /// `HealthSection` and round-trip through encode/decode without loss.
    func testVPNFlapFlatAliasesReadWriteAndRoundTrip() throws {
        var config = ProxyConfig.testFixture()
        config.health.vpnFlapMinVisibleSeconds = 2.5
        config.health.vpnFlapGraceSeconds = 12

        XCTAssertEqual(config.vpnFlapMinVisibleSeconds, 2.5)
        XCTAssertEqual(config.vpnFlapGraceSeconds, 12)

        config.vpnFlapMinVisibleSeconds = 0
        config.vpnFlapGraceSeconds = 7
        XCTAssertEqual(config.health.vpnFlapMinVisibleSeconds, 0)
        XCTAssertEqual(config.health.vpnFlapGraceSeconds, 7)

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        let data = try encoder.encode(config)
        let decoded = try decoder.decode(ProxyConfig.self, from: data)

        XCTAssertEqual(decoded.vpnFlapMinVisibleSeconds, 0)
        XCTAssertEqual(decoded.vpnFlapGraceSeconds, 7)
        XCTAssertEqual(decoded.health.vpnFlapMinVisibleSeconds, 0)
        XCTAssertEqual(decoded.health.vpnFlapGraceSeconds, 7)
    }

    /// Legacy `ProxyConfig` payloads (predating the two VPN flap
    /// fields) must decode cleanly with `HealthSection` defaults applied.
    /// `decodeIfPresent ?? default` keeps in-flight config-file reads
    /// forward-compatible even though we ship a single user.
    func testVPNFlapFlatKeysAbsentDecodesWithDefaults() throws {
        let legacyJSON = #"""
        {
            "localHost": "127.0.0.1",
            "localPort": 3128
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.vpnFlapGraceSeconds, 5,
                       "Default for vpnFlapGraceSeconds should match HealthSection's init default")
        XCTAssertEqual(decoded.vpnFlapMinVisibleSeconds, 1,
                       "Default for vpnFlapMinVisibleSeconds should match HealthSection's init default")
    }

    func testHealthTimeUnitConversion() {
        var config = ProxyConfig()
        config.connectionCheckTimeoutMS = 750
        XCTAssertEqual(config.health.connectionCheckTimeout, 0.75, accuracy: 0.001)
        config.upstreamResponseTimeoutSeconds = 8.5
        XCTAssertEqual(config.health.upstreamResponseTimeout, 8.5, accuracy: 0.001)

        config.directConnectTTLMinutes = 10
        XCTAssertEqual(config.health.directConnectTTL, 600, accuracy: 0.01)

        config.health.connectionCheckTimeout = 1.5
        XCTAssertEqual(config.connectionCheckTimeoutMS, 1500)
        config.health.upstreamResponseTimeout = 11
        XCTAssertEqual(config.upstreamResponseTimeoutSeconds, 11, accuracy: 0.001)

        config.health.directConnectTTL = 120
        XCTAssertEqual(config.directConnectTTLMinutes, 2)
    }

    func testUpstreamResponseTimeoutDefaultsIndependentlyFromStalledConnectionTimeout() throws {
        let legacyJSON = #"""
        {
            "stalledConnectionTimeoutSeconds": 5
        }
        """#.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: legacyJSON)

        XCTAssertEqual(decoded.stalledConnectionTimeoutSeconds, 5)
        XCTAssertEqual(decoded.upstreamResponseTimeoutSeconds, 45,
                       "Request response timeout must not inherit idle pooled-connection reap tuning")
    }

    // MARK: - ConfigDiff

    func testConfigDiffIdenticalConfigsHasNoChanges() {
        let config = ProxyConfig.testFixture()
        let diff = ConfigDiff(old: config, new: config)

        XCTAssertFalse(diff.hasChanges)
        XCTAssertFalse(diff.proxyChanged)
        XCTAssertFalse(diff.authChanged)
        XCTAssertFalse(diff.routingChanged)
        XCTAssertFalse(diff.dnsChanged)
        XCTAssertFalse(diff.tunnelsChanged)
        XCTAssertFalse(diff.healthChanged)
        XCTAssertFalse(diff.loggingChanged)
        XCTAssertFalse(diff.upstreamsChanged)
    }

    func testConfigDiffDetectsProxyChange() {
        let old = ProxyConfig.testFixture()
        var new = old
        new.proxy.port = 9999

        let diff = ConfigDiff(old: old, new: new)
        XCTAssertTrue(diff.proxyChanged)
        XCTAssertTrue(diff.hasChanges)
        XCTAssertFalse(diff.authChanged)
        XCTAssertFalse(diff.dnsChanged)
        XCTAssertFalse(diff.routingChanged)
    }

    func testConfigDiffDetectsRoutingChange() {
        let old = ProxyConfig.testFixture()
        var new = old
        new.routing.noProxyHosts.append("*.example.com")

        let diff = ConfigDiff(old: old, new: new)
        XCTAssertTrue(diff.routingChanged)
        XCTAssertTrue(diff.hasChanges)
        XCTAssertFalse(diff.proxyChanged)
    }

    func testConfigDiffDetectsMultipleChanges() {
        let old = ProxyConfig.testFixture()
        var new = old
        new.auth.domain = "APAC"
        new.logging.verbose = true

        let diff = ConfigDiff(old: old, new: new)
        XCTAssertTrue(diff.authChanged)
        XCTAssertTrue(diff.loggingChanged)
        XCTAssertTrue(diff.hasChanges)
        XCTAssertFalse(diff.proxyChanged)
        XCTAssertFalse(diff.dnsChanged)
    }

    func testConfigDiffDetectsUpstreamsChange() {
        let old = ProxyConfig.testFixture()
        var new = old
        new.upstreams.removeAll()

        let diff = ConfigDiff(old: old, new: new)
        XCTAssertTrue(diff.upstreamsChanged)
    }

    // MARK: - ConfigValidation

    func testValidConfigProducesNoErrors() {
        let config = ProxyConfig.testFixture()
        XCTAssertTrue(config.validate().isEmpty, "Test fixture config should be valid")
    }

    func testGenericDefaultConfigIsValid() {
        let config = GenericDefaults.shared.makeConfig()
        XCTAssertTrue(config.validate().isEmpty, "Generic default config should be valid")
    }

    func testInvalidPortDetected() {
        var config = ProxyConfig()
        config.proxy.port = 70000
        let errors = config.validate()
        XCTAssertTrue(errors.contains { if case .invalidPort(let f, _) = $0 { return f.contains("proxy.port") } else { return false } })
    }

    func testNegativePortDetected() {
        var config = ProxyConfig()
        config.proxy.port = -1
        let errors = config.validate()
        XCTAssertFalse(errors.isEmpty)
    }

    func testZeroPortIsValid() {
        var config = ProxyConfig()
        config.proxy.port = 0
        let errors = config.validate()
        XCTAssertTrue(errors.filter { if case .invalidPort(let f, _) = $0 { return f == "proxy.port" } else { return false } }.isEmpty)
    }

    func testInvalidConnectionLimitDetected() {
        var config = ProxyConfig()
        config.proxy.maxConnections = 0
        let errors = config.validate()
        XCTAssertTrue(errors.contains { if case .invalidLimit(let f, _, _) = $0 { return f.contains("maxConnections") } else { return false } })
    }

    func testNegativeDurationDetected() {
        var config = ProxyConfig()
        config.health.checkInterval = -1
        let errors = config.validate()
        XCTAssertTrue(errors.contains { if case .invalidDuration(let f, _) = $0 { return f.contains("checkInterval") } else { return false } })
    }

    func testNegativeUpstreamResponseTimeoutDetected() {
        var config = ProxyConfig()
        config.upstreamResponseTimeoutSeconds = -1
        let errors = config.validate()
        XCTAssertTrue(errors.contains { if case .invalidDuration(let f, _) = $0 { return f.contains("upstreamResponseTimeout") } else { return false } })
    }

    func testEmptyHostDetected() {
        var config = ProxyConfig()
        config.proxy.host = "   "
        let errors = config.validate()
        XCTAssertTrue(errors.contains { if case .invalidHost = $0 { return true } else { return false } })
    }

    func testLoopbackNoProxyFormsAreValid() {
        var config = ProxyConfig()
        config.noProxyHosts = ["localhost", "127.0.0.1", "127.0.0.*", "::1", "[::1]"]
        let errors = config.validate()
        XCTAssertFalse(errors.contains { error in
            if case .invalidHost(let field, _) = error {
                return field.contains("noProxyHosts")
            }
            return false
        })
    }

    func testSocksPortConflictDetected() {
        var config = ProxyConfig()
        config.proxy.port = 3128
        config.proxy.socksEnabled = true
        config.proxy.socksPort = 3128
        let errors = config.validate()
        XCTAssertTrue(errors.contains { if case .conflict = $0 { return true } else { return false } })
    }

    func testTunnelPortValidation() {
        var config = ProxyConfig()
        config.tunnels.definitions = [
            TunnelDefinition(localPort: 99999, remoteHost: "db.example.com", remotePort: 5432)
        ]
        let errors = config.validate()
        XCTAssertFalse(errors.isEmpty)
    }

    // MARK: - Validation for new fields

    func testCircuitFailureThresholdMustBePositive() {
        // Without validation, a malformed config
        // with `circuitFailureThreshold: 0` would let a closed-state trip
        // fire on the first failure, defeating the threshold entirely.
        var config = ProxyConfig()
        config.health.circuitFailureThreshold = 0
        let errors = config.validate()
        XCTAssertTrue(errors.contains { error in
            if case let .invalidLimit(field, _, _) = error {
                return field == "health.circuitFailureThreshold"
            }
            return false
        }, "circuitFailureThreshold = 0 must produce a validation error")
    }

    func testCircuitOpenIntervalsMustBePositive() {
        var config = ProxyConfig()
        config.health.circuitBaseOpenIntervalSeconds = 0
        config.health.circuitMaxOpenIntervalSeconds = 0
        let errors = config.validate()
        XCTAssertTrue(errors.contains { error in
            if case let .invalidDuration(field, _) = error {
                return field == "health.circuitBaseOpenIntervalSeconds"
            }
            return false
        }, "circuitBaseOpenIntervalSeconds = 0 must produce a validation error")
        XCTAssertTrue(errors.contains { error in
            if case let .invalidDuration(field, _) = error {
                return field == "health.circuitMaxOpenIntervalSeconds"
            }
            return false
        }, "circuitMaxOpenIntervalSeconds = 0 must produce a validation error")
    }

    func testCircuitMaxOpenIntervalCannotBeBelowBase() {
        var config = ProxyConfig()
        config.health.circuitBaseOpenIntervalSeconds = 60
        config.health.circuitMaxOpenIntervalSeconds = 30
        let errors = config.validate()
        XCTAssertTrue(errors.contains { error in
            if case let .conflict(description) = error {
                return description.contains("circuitMaxOpenIntervalSeconds")
                    && description.contains("circuitBaseOpenIntervalSeconds")
            }
            return false
        }, "max < base must produce a conflict validation error")
    }

    func testAuditLogMaxBytesMustBePositive() {
        // Without validation, `auditLogMaxBytes: 0` with
        // `auditLogEnabled: true` crashes the daemon at startup via
        // `FileConnectionAuditSink.init`'s precondition.
        var config = ProxyConfig()
        config.logging.auditLogMaxBytes = 0
        let errors = config.validate()
        XCTAssertTrue(errors.contains { error in
            if case let .invalidLimit(field, _, _) = error {
                return field == "logging.auditLogMaxBytes"
            }
            return false
        }, "auditLogMaxBytes = 0 must produce a validation error (would crash FileConnectionAuditSink.init precondition)")
    }

    // MARK: - Defaults

    func testGenericDefaultsMatchEmptyInit() {
        let fromInit = ProxyConfig()
        let fromDefaults = GenericDefaults.shared.makeConfig()
        XCTAssertEqual(fromInit, fromDefaults)
    }

    func testBundledPresetIndexLoads() {
        let descriptors = PresetLoader.availablePresets()
        XCTAssertGreaterThanOrEqual(descriptors.count, 3)
        XCTAssertTrue(descriptors.allSatisfy { !$0.id.isEmpty })
    }

    func testEveryIndexedPresetRecordLoads() {
        let descriptors = PresetLoader.availablePresets()
        XCTAssertFalse(descriptors.isEmpty)
        for descriptor in descriptors {
            XCTAssertNotNil(PresetLoader.load(descriptor.id), "Preset record should load: \(descriptor.id)")
        }
    }

    func testGenericDefaultsHaveNoUpstreams() {
        let config = GenericDefaults.shared.makeConfig()
        XCTAssertTrue(config.upstreams.isEmpty)
    }

    func testBundledGenericPresetLoads() throws {
        let preset = try XCTUnwrap(PresetLoader.load("generic"))
        XCTAssertEqual(preset.config.profileName, "Generic")
        XCTAssertTrue(preset.config.upstreams.isEmpty)
        XCTAssertEqual(preset.platform, PlatformIntegrationConfig())
        XCTAssertEqual(preset.preferences, AppPreferences())
    }

    func testBundledProxyPresetLoadsWithPlatformDefaults() throws {
        let preset = try XCTUnwrap(PresetLoader.load("squid"))
        XCTAssertEqual(preset.config.upstreams.count, 1)
        XCTAssertEqual(preset.config.upstreams[0].host, "squid.example.test")
        XCTAssertTrue(preset.platform.manageSystemProxy)
        XCTAssertTrue(preset.platform.manageEnvironmentVariables)
        XCTAssertEqual(preset.platform.systemProxyMode, .manual)
    }

    func testMissingPresetReturnsNil() {
        XCTAssertNil(PresetLoader.load("missing-\(UUID().uuidString)"))
    }

    // MARK: - ProxyConfig Round-Trip

    func testFullConfigRoundTrip() throws {
        let original = ProxyConfig.testFixture()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testGenericConfigRoundTrip() throws {
        let original = ProxyConfig()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertEqual(original, decoded)
    }

    func testHealthUnitsRoundTripViaJSON() throws {
        var config = ProxyConfig()
        config.health.connectionCheckTimeout = 0.75
        config.health.directConnectTTL = 600

        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["connectionCheckTimeoutMS"] as? Int, 750)
        XCTAssertEqual(json["upstreamResponseTimeoutSeconds"] as? Double, 45)
        XCTAssertEqual(json["directConnectTTLMinutes"] as? Int, 10)

        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertEqual(decoded.health.connectionCheckTimeout, 0.75, accuracy: 0.001)
        XCTAssertEqual(decoded.health.upstreamResponseTimeout, 45, accuracy: 0.001)
        XCTAssertEqual(decoded.health.directConnectTTL, 600, accuracy: 0.01)
    }

    func testConfigEncodingIncludesCurrentSchemaVersion() throws {
        let data = try JSONEncoder().encode(ProxyConfig.testFixture())
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(json["schemaVersion"] as? Int, ProxyConfig.currentSchemaVersion)
    }

    func testEmptyJSONDecodesToGenericDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: data)
        let generic = GenericDefaults.shared.makeConfig()

        XCTAssertEqual(config.proxy.port, generic.proxy.port)
        XCTAssertEqual(config.proxy.maxConnections, generic.proxy.maxConnections)
        XCTAssertEqual(config.routing.noProxyHosts, generic.routing.noProxyHosts)
        XCTAssertTrue(config.upstreams.isEmpty)
    }

    func testPlatformFieldsIgnoredInProxyConfigDecode() throws {
        let json = """
        {"manageSystemProxy": true, "launchAtLogin": true, "showMenuBarIcon": false, "localPort": 5555}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.localPort, 5555)
    }

    // MARK: - PlatformIntegrationConfig Codable

    func testPlatformConfigEmptyJSONDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let platform = try JSONDecoder().decode(PlatformIntegrationConfig.self, from: data)

        XCTAssertFalse(platform.manageSystemProxy)
        XCTAssertFalse(platform.manageEnvironmentVariables)
        XCTAssertFalse(platform.manageDNSResolvers)
        XCTAssertFalse(platform.manageSystemDNS)
        XCTAssertEqual(platform.systemProxyMode, .manual)
        XCTAssertFalse(platform.launchAtLogin)
    }

    func testPlatformConfigSilentlyDropsRetiredVPNToggleKeys() throws {
        // `autoEnableOnVPN` / `autoDisableOffVPN` were retired. Old config files with these
        // keys must decode cleanly (silently dropped). This test guards the
        // migration policy.
        let data = """
        {
            "manageSystemProxy": true,
            "autoEnableOnVPN": true,
            "autoDisableOffVPN": true,
            "launchAtLogin": false
        }
        """.data(using: .utf8)!
        let platform = try JSONDecoder().decode(PlatformIntegrationConfig.self, from: data)
        XCTAssertTrue(platform.manageSystemProxy, "Live fields decoded as expected")
        XCTAssertFalse(platform.launchAtLogin, "Live fields decoded as expected")
        // No assertion on the retired fields — they no longer exist on the type.
    }

    func testPlatformConfigRoundTrip() throws {
        var platform = PlatformIntegrationConfig()
        platform.manageSystemProxy = true
        platform.systemProxyMode = .pac
        platform.launchAtLogin = true

        let data = try JSONEncoder().encode(platform)
        let decoded = try JSONDecoder().decode(PlatformIntegrationConfig.self, from: data)
        XCTAssertEqual(platform, decoded)
    }

    // MARK: - AppPreferences Codable

    func testAppPreferencesEmptyJSONDefaults() throws {
        let data = "{}".data(using: .utf8)!
        let prefs = try JSONDecoder().decode(AppPreferences.self, from: data)

        XCTAssertTrue(prefs.showMenuBarIcon)
        XCTAssertFalse(prefs.floatingWindowEnabled)
        XCTAssertTrue(prefs.globalShortcutEnabled)
        XCTAssertEqual(prefs.preferredBrowserTestURL, "")
    }

    func testAppPreferencesRoundTrip() throws {
        var prefs = AppPreferences()
        prefs.showMenuBarIcon = false
        prefs.floatingWindowEnabled = true
        prefs.preferredBrowserTestURL = "https://example.com"

        let data = try JSONEncoder().encode(prefs)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: data)
        XCTAssertEqual(prefs, decoded)
    }

    // MARK: - Legacy Migration

    func testLegacyPlatformMigrationExtractsFields() throws {
        let json = """
        {"manageSystemProxy": true, "systemProxyMode": "pac", "launchAtLogin": true, "localPort": 3128}
        """.data(using: .utf8)!

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        try json.write(to: configURL)

        let platform = LegacyConfigMigration.extractPlatformConfig(from: configURL)
        XCTAssertNotNil(platform)
        XCTAssertTrue(platform!.manageSystemProxy)
        XCTAssertEqual(platform!.systemProxyMode, .pac)
        XCTAssertTrue(platform!.launchAtLogin)
        XCTAssertFalse(platform!.manageSystemDNS)
    }

    func testLegacyPreferencesMigrationExtractsFields() throws {
        let json = """
        {"showMenuBarIcon": false, "globalShortcutEnabled": false, "preferredBrowserTestURL": "https://example.test/"}
        """.data(using: .utf8)!

        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configURL = tempDir.appendingPathComponent("config.json")
        try json.write(to: configURL)

        let prefs = LegacyConfigMigration.extractAppPreferences(from: configURL)
        XCTAssertNotNil(prefs)
        XCTAssertFalse(prefs!.showMenuBarIcon)
        XCTAssertFalse(prefs!.globalShortcutEnabled)
        XCTAssertEqual(prefs!.preferredBrowserTestURL, "https://example.test/")
    }

    func testLegacyMigrationHandlesMissingFile() {
        let bogus = URL(fileURLWithPath: "/tmp/nonexistent-\(UUID().uuidString).json")
        XCTAssertNil(LegacyConfigMigration.extractPlatformConfig(from: bogus))
        XCTAssertNil(LegacyConfigMigration.extractAppPreferences(from: bogus))
    }

    // MARK: - Persistence Load Paths

    func testPlatformConfigPersistenceLoadsMigratedFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)

        let legacyJSON = """
        {"manageSystemProxy": true, "autoEnableOnVPN": true}
        """.data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let platform = PlatformConfigPersistence.load(in: env)
        XCTAssertTrue(platform.manageSystemProxy)
        // `autoEnableOnVPN` was retired — no longer asserted here.
        // The presence of the legacy key in the source JSON should not cause
        // decode to fail; this assertion verifies the live field still loads.

        XCTAssertTrue(FileManager.default.fileExists(atPath: env.platformConfigFile.path),
                       "Migration should write platform.json")
    }

    func testPreferencesPersistenceLoadsMigratedFile() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)

        let legacyJSON = """
        {"showMenuBarIcon": false, "preferredBrowserTestURL": "https://test.com"}
        """.data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let prefs = AppPreferencesPersistence.load(in: env)
        XCTAssertFalse(prefs.showMenuBarIcon)
        XCTAssertEqual(prefs.preferredBrowserTestURL, "https://test.com")

        XCTAssertTrue(FileManager.default.fileExists(atPath: env.preferencesFile.path),
                       "Migration should write preferences.json")
    }

    func testPersistenceLoadsDirectFileOverLegacy() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)

        let legacyJSON = "{\"manageSystemProxy\": true}".data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let directJSON = "{\"manageSystemProxy\": false}".data(using: .utf8)!
        try directJSON.write(to: env.platformConfigFile)

        let platform = PlatformConfigPersistence.load(in: env)
        XCTAssertFalse(platform.manageSystemProxy, "Direct file should take precedence over legacy")
    }

    func testRuntimeConfigPersistenceMigratesUnversionedConfig() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)
        let legacyJSON = """
        {
            "profileName": "Legacy",
            "localPort": 3129,
            "upstreams": [
                {"id": "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "name": "A", "host": "proxy-a.example.test", "port": 8080, "enabled": true, "priority": 0}
            ]
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let result = ProxyConfigPersistence.loadMigrating(from: env.configFile)

        XCTAssertTrue(result.migrated)
        XCTAssertEqual(result.config.profileName, "Legacy")
        XCTAssertEqual(result.config.localPort, 3129)
        XCTAssertEqual(result.config.schemaVersion, ProxyConfig.currentSchemaVersion)

        let storedData = try Data(contentsOf: env.configFile)
        let storedJSON = try JSONSerialization.jsonObject(with: storedData) as! [String: Any]
        XCTAssertEqual(storedJSON["schemaVersion"] as? Int, ProxyConfig.currentSchemaVersion)
    }

    func testRuntimeConfigMigrationExtractsSidecarsBeforeRewrite() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)
        let legacyJSON = """
        {
            "profileName": "Legacy Combined",
            "localPort": 3129,
            "manageSystemProxy": true,
            "systemProxyMode": "pac",
            "showMenuBarIcon": false,
            "preferredBrowserTestURL": "https://legacy.example.test/"
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let result = ProxyConfigPersistence.loadAllMigrating(in: env)

        XCTAssertTrue(result.migrated)
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(result.config.profileName, "Legacy Combined")
        XCTAssertEqual(result.platformConfig.manageSystemProxy, true)
        XCTAssertEqual(result.platformConfig.systemProxyMode, .pac)
        XCTAssertEqual(result.appPreferences.showMenuBarIcon, false)
        XCTAssertEqual(result.appPreferences.preferredBrowserTestURL, "https://legacy.example.test/")

        XCTAssertTrue(FileManager.default.fileExists(atPath: env.platformConfigFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.preferencesFile.path))
        let rewrittenConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: env.configFile)) as! [String: Any]
        XCTAssertEqual(rewrittenConfig["schemaVersion"] as? Int, ProxyConfig.currentSchemaVersion)
        XCTAssertNil(rewrittenConfig["manageSystemProxy"], "Runtime config rewrite should drop sidecar fields after extracting them")
        XCTAssertNil(rewrittenConfig["showMenuBarIcon"], "Runtime config rewrite should drop sidecar fields after extracting them")
    }

    func testRuntimeConfigMigrationPreservesLegacyFieldsWhenSidecarWriteFails() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let blockingPlatformPath = tempDir.appendingPathComponent("platform-blocker.json")
        try FileManager.default.createDirectory(at: blockingPlatformPath, withIntermediateDirectories: true)
        let env = RuntimeEnvironment(configDirectory: tempDir, platformConfigFile: blockingPlatformPath)
        let legacyJSON = """
        {
            "profileName": "Legacy Combined",
            "localPort": 3129,
            "manageSystemProxy": true,
            "systemProxyMode": "pac",
            "showMenuBarIcon": false,
            "preferredBrowserTestURL": "https://legacy.example.test/"
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let result = ProxyConfigPersistence.loadAllMigrating(in: env)

        XCTAssertTrue(result.migrated)
        XCTAssertFalse(result.warnings.isEmpty)
        XCTAssertEqual(result.config.schemaVersion, ProxyConfig.currentSchemaVersion)
        XCTAssertEqual(result.platformConfig.manageSystemProxy, true)
        XCTAssertEqual(result.appPreferences.showMenuBarIcon, false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: env.preferencesFile.path))

        let preservedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: env.configFile)) as! [String: Any]
        XCTAssertNil(preservedConfig["schemaVersion"], "Runtime rewrite must be skipped when sidecar migration failed")
        XCTAssertEqual(preservedConfig["manageSystemProxy"] as? Bool, true)
        XCTAssertEqual(preservedConfig["showMenuBarIcon"] as? Bool, false)
    }

    func testRuntimeOnlyLoadDoesNotRewriteConfigOrCreateSidecarFiles() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)
        let legacyJSON = """
        {
            "profileName": "Headless",
            "localPort": 3129,
            "manageSystemProxy": true,
            "showMenuBarIcon": false
        }
        """.data(using: .utf8)!
        try legacyJSON.write(to: env.configFile)

        let config = ProxyConfigPersistence.load(in: env)

        XCTAssertEqual(config.profileName, "Headless")
        XCTAssertEqual(config.schemaVersion, ProxyConfig.currentSchemaVersion)
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.platformConfigFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: env.preferencesFile.path))

        let storedConfig = try JSONSerialization.jsonObject(with: Data(contentsOf: env.configFile)) as! [String: Any]
        XCTAssertNil(storedConfig["schemaVersion"], "Headless load should not rewrite shared legacy config")
        XCTAssertEqual(storedConfig["manageSystemProxy"] as? Bool, true)
        XCTAssertEqual(storedConfig["showMenuBarIcon"] as? Bool, false)
    }

    func testRuntimeConfigPersistenceDoesNotRewriteCurrentSchema() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let env = RuntimeEnvironment(configDirectory: tempDir)
        try ProxyConfigPersistence.save(.testFixture(), in: env)

        let result = ProxyConfigPersistence.loadMigrating(from: env.configFile)

        XCTAssertFalse(result.migrated)
        XCTAssertEqual(result.config.schemaVersion, ProxyConfig.currentSchemaVersion)
    }

    // MARK: - Section Equatable (drives ConfigDiff)

    func testProxySectionEquality() {
        let a = ProxySection()
        var b = ProxySection()
        XCTAssertEqual(a, b)
        b.port = 9999
        XCTAssertNotEqual(a, b)
    }

    func testHealthSectionEquality() {
        let a = HealthSection()
        var b = HealthSection()
        XCTAssertEqual(a, b)
        b.connectionCheckTimeout = 3.0
        XCTAssertNotEqual(a, b)
    }
}
