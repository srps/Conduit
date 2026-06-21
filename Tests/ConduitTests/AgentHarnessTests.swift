// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class AgentHarnessTests: XCTestCase {

    // MARK: - Minimal Config (no Preset leakage)

    func testGenericDefaultsHaveNoUpstreams() {
        let config = GenericDefaults.shared.makeConfig()
        XCTAssertTrue(config.upstreams.isEmpty, "Minimal/generic config must not leak vendor upstreams")
    }

    func testGenericDefaultsHaveNoDNSEntries() {
        let config = GenericDefaults.shared.makeConfig()
        XCTAssertTrue(config.dnsEntries.isEmpty, "Generic defaults should have no DNS entries")
    }

    func testGenericDefaultsHaveNoForceProxy() {
        let config = GenericDefaults.shared.makeConfig()
        XCTAssertTrue(config.forceProxyHosts.isEmpty)
    }

    func testGenericDefaultProfileName() {
        let config = GenericDefaults.shared.makeConfig()
        XCTAssertEqual(config.profileName, "Default")
    }

    // MARK: - Ephemeral Tunnel Ports

    func testTunnelValidationAcceptsPortZero() {
        var config = ProxyConfig()
        config.tunnels.definitions = [
            TunnelDefinition(localPort: 0, remoteHost: "db.example.com", remotePort: 5432, proxied: true)
        ]
        let errors = config.validate()
        let portErrors = errors.filter {
            if case .invalidPort(let f, _) = $0 { return f.contains("localPort") }
            return false
        }
        XCTAssertTrue(portErrors.isEmpty, "Port 0 (ephemeral) should be valid for tunnel localPort")
    }

    func testTunnelValidationRejectsNegativePort() {
        var config = ProxyConfig()
        config.tunnels.definitions = [
            TunnelDefinition(localPort: -1, remoteHost: "db.example.com", remotePort: 5432)
        ]
        let errors = config.validate()
        XCTAssertFalse(errors.isEmpty, "Negative port should be invalid")
    }

    // MARK: - Ready File Path

    func testReadyFilePathInStateDirectory() {
        let tempDir = URL(fileURLWithPath: "/tmp/pm-test-ready")
        let env = RuntimeEnvironment(configDirectory: tempDir)
        let expected = tempDir.appendingPathComponent("ready.json")
        XCTAssertEqual(env.configDirectory.appendingPathComponent("ready.json").path, expected.path)
    }

    func testSnapshotFilePathInStateDirectory() {
        let tempDir = URL(fileURLWithPath: "/tmp/pm-test-snapshot")
        let env = RuntimeEnvironment(configDirectory: tempDir)
        XCTAssertEqual(env.snapshotFile.path, tempDir.appendingPathComponent("snapshot.json").path)
    }

    func testEventsFilePathInStateDirectory() {
        let tempDir = URL(fileURLWithPath: "/tmp/pm-test-events")
        let env = RuntimeEnvironment(configDirectory: tempDir)
        XCTAssertEqual(env.eventsFile.path, tempDir.appendingPathComponent("events.ndjson").path)
    }

    // MARK: - Config JSON Decode

    func testInlineConfigJSONDecode() throws {
        let json = """
        {"localPort": 0, "profileName": "Agent Test"}
        """.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.localPort, 0)
        XCTAssertEqual(config.profileName, "Agent Test")
        XCTAssertTrue(config.upstreams.isEmpty, "Inline JSON with no upstreams should decode to empty")
    }

    // MARK: - Persistence Falls Back to Generic Defaults

    func testPersistenceLoadFallsBackToGenericDefault() {
        let bogusDir = URL(fileURLWithPath: "/tmp/pm-test-\(UUID().uuidString)")
        let env = RuntimeEnvironment(configDirectory: bogusDir)
        let config = ProxyConfigPersistence.load(in: env)
        XCTAssertEqual(config.profileName, GenericDefaults.shared.profileName)
        XCTAssertTrue(config.upstreams.isEmpty)
    }

    // MARK: - Platform Config Not in ProxyConfig

    func testProxyConfigHasNoPlatformFields() throws {
        let config = ProxyConfig.testFixture()
        let data = try JSONEncoder().encode(config)
        let json = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(json["manageSystemProxy"], "Platform fields must not appear in ProxyConfig JSON")
        XCTAssertNil(json["manageSystemDNS"])
        XCTAssertNil(json["launchAtLogin"])
        XCTAssertNil(json["showMenuBarIcon"])
        XCTAssertNil(json["globalShortcutEnabled"])
    }

    // MARK: - Isolation Invariants

    @MainActor
    func testIsolatedOrchestratorHasNoSystemSideEffects() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(orchestrator.snapshot.directModeCause.isDirect, "No upstreams = direct mode")
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .noUpstreamsConfigured,
                       "Empty enabledUpstreams should yield .noUpstreamsConfigured cause, not .upstreamsUnreachable")
        XCTAssertNotNil(orchestrator.snapshot.bindings.proxyPort)
        XCTAssertNotEqual(orchestrator.snapshot.bindings.proxyPort, 0)

        await orchestrator.stopProxy()
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped)
    }
}
