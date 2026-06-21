// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class ConfigHotReloadTests: XCTestCase {

    @MainActor
    private func makeRunningOrchestrator() async throws -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        return orchestrator
    }

    // MARK: - No-op when nothing changed

    @MainActor
    func testApplyConfigChangeNoOpWhenIdentical() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        let before = orchestrator.snapshot
        await orchestrator.applyConfigChange(orchestrator.config)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, before.runtimeStatus.state)
    }

    // MARK: - Routing changes don't restart proxy

    @MainActor
    func testRoutingChangeDoesNotRestartProxy() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        let portBefore = orchestrator.snapshot.bindings.proxyPort
        var newConfig = orchestrator.config
        newConfig.routing.noProxyHosts.append("*.newdomain.com")
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertEqual(orchestrator.snapshot.bindings.proxyPort, portBefore,
                       "Routing change should not change the bound port (no restart)")
    }

    // MARK: - Logging change is immediate

    @MainActor
    func testLoggingChangeAppliesWithoutRestart() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        var newConfig = orchestrator.config
        newConfig.logging.verbose = !newConfig.logging.verbose
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.config.logging.verbose, newConfig.logging.verbose)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
    }

    // MARK: - Health interval change restarts health loop

    @MainActor
    func testHealthChangeRestartsHealthLoop() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        var newConfig = orchestrator.config
        newConfig.health.checkInterval = 120
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.config.healthCheckIntervalSeconds, 120)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
    }

    // MARK: - Proxy port change triggers restart

    @MainActor
    func testProxyPortChangeRestartsProxy() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        let originalPort = orchestrator.snapshot.bindings.proxyPort
        XCTAssertNotNil(originalPort)

        var newConfig = orchestrator.config
        newConfig.proxy.port = 0
        newConfig.proxy.host = "127.0.0.1"
        newConfig.proxy.gatewayMode = !newConfig.proxy.gatewayMode
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
        await orchestrator.stopProxy()
    }

    // MARK: - Proxy limits change without restart

    @MainActor
    func testProxyLimitsChangeWithoutRestart() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        let portBefore = orchestrator.snapshot.bindings.proxyPort
        var newConfig = orchestrator.config
        newConfig.proxy.maxConnections = 9999
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.snapshot.bindings.proxyPort, portBefore,
                       "maxConnections change should not restart proxy")
        XCTAssertEqual(orchestrator.config.proxy.maxConnections, 9999)
    }

    // MARK: - Upstreams change triggers refresh

    @MainActor
    func testUpstreamsChangeRefreshesConnectivity() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        var newConfig = orchestrator.config
        newConfig.upstreams = [
            UpstreamProxy(name: "Test", host: "192.0.2.1", port: 8080, priority: 0)
        ]
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.config.upstreams.count, 1)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
    }

    // MARK: - ConfigDiff drives targeted reload

    func testConfigDiffOnlyFlagsChangedSections() {
        let old = ProxyConfig.testFixture()
        var new = old
        new.routing.forceProxyHosts.append("new.host.com")
        new.logging.verbose = true

        let diff = ConfigDiff(old: old, new: new)
        XCTAssertTrue(diff.routingChanged)
        XCTAssertTrue(diff.loggingChanged)
        XCTAssertFalse(diff.proxyChanged)
        XCTAssertFalse(diff.dnsChanged)
        XCTAssertFalse(diff.tunnelsChanged)
        XCTAssertFalse(diff.healthChanged)
        XCTAssertFalse(diff.authChanged)
        XCTAssertFalse(diff.upstreamsChanged)
    }

    // MARK: - Tunnel reconciliation via config change

    @MainActor
    func testTunnelChangeUsesReconciliation() async throws {
        // Tunnels must be running for `applyConfigChange` to route into `reconcileTunnels`;
        // without that precondition the test would pass even if the reconcile branch were
        // deleted (the unconditional `config = newConfig` assignment alone satisfied the
        // previous assertion). Start a tunnel first, then mutate the definition list and
        // verify the reconciled binding set reflects the change.
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        let initialTunnel = TunnelDefinition(
            localPort: 0, remoteHost: "db1.example.com", remotePort: 5432,
            proxied: false, label: "DB1"
        )
        config.tunnels.definitions = [initialTunnel]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()

        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1,
                       "Precondition: one tunnel bound so reconcile branch is reachable")
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running)

        var newConfig = orchestrator.config
        newConfig.tunnels.definitions.append(
            TunnelDefinition(
                localPort: 0, remoteHost: "db2.example.com", remotePort: 3306,
                proxied: false, label: "DB2"
            )
        )
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertEqual(orchestrator.config.tunnels.definitions.count, 2)
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 2,
                       "Reconcile should have bound the newly added tunnel definition")
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.count, 2)

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }

    // MARK: - DNS change with DNS not running is no-op

    @MainActor
    func testDNSChangeWhenNotRunningIsNoOp() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        XCTAssertNotEqual(orchestrator.snapshot.dnsRunState, .running)

        var newConfig = orchestrator.config
        newConfig.dns.forwarderPort = 9999
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertNotEqual(orchestrator.snapshot.dnsRunState, .running,
                          "DNS was not running, change should not start it")
    }

    // MARK: - Runtime auth outcome lifecycle

    /// `applyConfigChange` on the auth section must clear the runtime auth
    /// outcome so the UI chip (`MainView.authBadge`, which prefers runtime
    /// over configured intent) doesn't keep asserting the previous mode's
    /// last handshake against the new configuration. Without this reset,
    /// switching from `systemNegotiated` (last outcome `.kerberos`) to
    /// `ntlmv2` would leave the chip reading "Kerberos" until the first
    /// new-config handshake — a stale-state lie the snapshot is supposed
    /// to prevent. Mirrors the rationale on `stopProxy`'s VPN-flap reset.
    @MainActor
    func testApplyConfigChangeAuthChangedClearsRuntimeAuthOutcome() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        // Pre-populate the snapshot the way a real CONNECT handshake would.
        // `reportAuthOutcome` is `nonisolated` and hops to MainActor for the
        // mutation, so we yield once to let the Task land before reading.
        orchestrator.reportAuthOutcome(.kerberos, host: "proxy.example.com", reason: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .kerberos,
                       "Pre-condition: snapshot must reflect the simulated handshake")
        XCTAssertNotNil(orchestrator.snapshot.lastAuthOutcomeAt)

        var newConfig = orchestrator.config
        newConfig.auth.mode = newConfig.auth.mode == .systemNegotiated ? .ntlmv2 : .systemNegotiated
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertNil(orchestrator.snapshot.lastAuthOutcome,
                     "Auth-mode change must clear lastAuthOutcome so the UI chip stops mirroring the previous mode's handshake.")
        XCTAssertNil(orchestrator.snapshot.lastAuthOutcomeAt,
                     "Auth-mode change must clear lastAuthOutcomeAt alongside lastAuthOutcome.")
        XCTAssertNil(orchestrator.snapshot.lastAuthFallbackReason,
                     "Auth-mode change must clear lastAuthFallbackReason alongside lastAuthOutcome.")
    }

    /// Same fields must clear when the auth section changes for a *credential*
    /// edit (e.g. username/domain change), not just a mode flip — both
    /// branches of the `diff.authChanged` test must invalidate the cached
    /// outcome.
    @MainActor
    func testApplyConfigChangeAuthCredentialEditAlsoClearsRuntimeAuthOutcome() async throws {
        let orchestrator = try await makeRunningOrchestrator()
        defer { Task { await orchestrator.stopProxy() } }

        orchestrator.reportAuthOutcome(.ntlmFallback, host: "proxy.example.com", reason: "bad_mech")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .ntlmFallback)
        XCTAssertEqual(orchestrator.snapshot.lastAuthFallbackReason, "bad_mech")

        var newConfig = orchestrator.config
        newConfig.auth.username = newConfig.auth.username + "-edited"
        await orchestrator.applyConfigChange(newConfig)

        XCTAssertNil(orchestrator.snapshot.lastAuthOutcome)
        XCTAssertNil(orchestrator.snapshot.lastAuthOutcomeAt)
        XCTAssertNil(orchestrator.snapshot.lastAuthFallbackReason)
    }

    /// `stopProxy` must clear the runtime auth outcome alongside the VPN-flap
    /// telemetry — same rationale: on the next start the UI must not display
    /// stale activity from the previous session. Without this, a
    /// stop→start cycle briefly shows the prior outcome (e.g. "Kerberos →
    /// NTLM") until a fresh handshake lands. Mirrors
    /// `VPNTransitionTableTests.testStopProxyResetsFlapTelemetryCounters`.
    @MainActor
    func testStopProxyResetsRuntimeAuthOutcome() async throws {
        let orchestrator = try await makeRunningOrchestrator()

        orchestrator.reportAuthOutcome(.ntlmFallback, host: "proxy.example.com", reason: "bad_mech")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .ntlmFallback,
                       "Pre-condition: snapshot must hold the simulated outcome before stop")
        XCTAssertEqual(orchestrator.snapshot.lastAuthFallbackReason, "bad_mech")
        XCTAssertNotNil(orchestrator.snapshot.lastAuthOutcomeAt)

        await orchestrator.stopProxy()

        XCTAssertNil(orchestrator.snapshot.lastAuthOutcome,
                     "stopProxy must reset lastAuthOutcome so the next start does not carry stale auth state into the new cycle.")
        XCTAssertNil(orchestrator.snapshot.lastAuthOutcomeAt,
                     "stopProxy must clear lastAuthOutcomeAt alongside lastAuthOutcome.")
        XCTAssertNil(orchestrator.snapshot.lastAuthFallbackReason,
                     "stopProxy must clear lastAuthFallbackReason alongside lastAuthOutcome.")
    }
}
