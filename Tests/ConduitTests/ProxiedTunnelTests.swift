// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

/// Value tests for proxied tunnel definitions, session limits and the tunnel listen host. The end-to-end wire protocol
/// test runs through the real forwarder in `TunnelForwarderTests`.
final class ProxiedTunnelTests: XCTestCase {

    // MARK: - TunnelDefinition backward compatibility

    func testTunnelDefinitionDefaultsProxiedFalse() {
        let def = TunnelDefinition(localPort: 27017, remoteHost: "cosmos.example.com", remotePort: 10255)
        XCTAssertFalse(def.proxied)
        XCTAssertEqual(def.label, "")
    }

    func testTunnelDefinitionProxiedTrue() {
        let def = TunnelDefinition(localPort: 27017, remoteHost: "cosmos.example.com", remotePort: 10255, proxied: true, label: "CosmosDB")
        XCTAssertTrue(def.proxied)
        XCTAssertEqual(def.effectiveLabel, "CosmosDB")
    }

    func testTunnelDefinitionEffectiveLabelFallback() {
        let def = TunnelDefinition(localPort: 5432, remoteHost: "pg.internal.corp", remotePort: 5432, proxied: true)
        XCTAssertEqual(def.effectiveLabel, "5432→pg.internal.corp:5432")
    }

    func testTunnelDefinitionDecodesWithoutProxiedField() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","localPort":27017,"remoteHost":"example.com","remotePort":10255,"enabled":true}
        """
        let def = try JSONDecoder().decode(TunnelDefinition.self, from: Data(json.utf8))
        XCTAssertFalse(def.proxied)
        XCTAssertEqual(def.label, "")
    }

    // MARK: - Session tracker

    func testSessionTrackerEnforcesGlobalLimit() {
        let tracker = TunnelSessionTracker(limits: .init(maxGlobal: 2, maxPerTunnel: 10))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 5432))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 27017))
        XCTAssertFalse(tracker.tryAcquire(tunnelPort: 6379), "Should reject when global limit reached")
        tracker.release(tunnelPort: 5432)
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 6379), "Should allow after release")
    }

    func testSessionTrackerEnforcesPerTunnelLimit() {
        let tracker = TunnelSessionTracker(limits: .init(maxGlobal: 100, maxPerTunnel: 2))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 5432))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 5432))
        XCTAssertFalse(tracker.tryAcquire(tunnelPort: 5432), "Should reject when per-tunnel limit reached")
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 27017), "Different tunnel should still work")
    }

    func testSessionTrackerTotalActiveSessions() {
        let tracker = TunnelSessionTracker(limits: .init(maxGlobal: 100, maxPerTunnel: 100))
        _ = tracker.tryAcquire(tunnelPort: 5432)
        _ = tracker.tryAcquire(tunnelPort: 5432)
        _ = tracker.tryAcquire(tunnelPort: 27017)
        XCTAssertEqual(tracker.totalActiveSessions, 3)
        tracker.release(tunnelPort: 5432)
        XCTAssertEqual(tracker.totalActiveSessions, 2)
    }

    // MARK: - Config tunnel limits

    func testTunnelSessionLimitsDefaults() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.maxTunnelSessions, 128)
        XCTAssertEqual(config.maxSessionsPerTunnel, 32)
    }

    func testTunnelSessionLimitsDecodeWhenMissing() throws {
        let json = #"{}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.maxTunnelSessions, 128)
        XCTAssertEqual(config.maxSessionsPerTunnel, 32)
    }

    // MARK: - Gateway mode tunnel listen host

    func testEffectiveTunnelListenHostAlwaysLoopback() {
        var config = ProxyConfig.testFixture()
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1")
        config.gatewayMode = true
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must stay loopback even in gateway mode")
        XCTAssertEqual(config.effectiveListenHost, "0.0.0.0",
                       "Main proxy listen host should still be 0.0.0.0 in gateway mode")
        config.gatewayMode = false
        config.localHost = "0.0.0.0"
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must stay loopback even when localHost is 0.0.0.0")
        config.localHost = "10.0.0.5"
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must stay loopback for any custom localHost")
    }
}
