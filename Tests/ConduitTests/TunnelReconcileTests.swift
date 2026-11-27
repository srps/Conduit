// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class TunnelReconcileTests: XCTestCase {

    @RuntimeActor
    func testReconcileAddsNewTunnel() async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [
            TunnelDefinition(localPort: 0, remoteHost: "db1.example.com", remotePort: 5432, proxied: false, label: "DB1")
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1)

        var newConfig = config
        newConfig.tunnels.definitions.append(
            TunnelDefinition(localPort: 0, remoteHost: "db2.example.com", remotePort: 5432, proxied: false, label: "DB2")
        )
        orchestrator.config = newConfig
        await orchestrator.reconcileTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 2)

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }

    /// A refused tunnel was never bound, so the status names the refusal rather than a bind failure.
    @RuntimeActor
    func testATunnelRefusedForItsRemoteHostIsReportedAsRefused() async throws {
        let refused = TunnelDefinition(localPort: 0, remoteHost: "bücher.corp.example", remotePort: 5432, proxied: true, label: "DB")
        let direct = TunnelDefinition(localPort: 0, remoteHost: "db1.example.com", remotePort: 5432, proxied: false, label: "DB1")
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [refused]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .failed)
        XCTAssertEqual(
            orchestrator.snapshot.tunnelsError,
            "No tunnel started: 1 proxied tunnel(s) refused because the remote host is not a host name or IP address."
        )
        await orchestrator.stopTunnels()

        config.tunnels.definitions = [refused, direct]
        orchestrator.config = config
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1)
        XCTAssertEqual(
            orchestrator.snapshot.tunnelsError,
            "1 proxied tunnel(s) refused because the remote host is not a host name or IP address."
        )
        XCTAssertEqual(orchestrator.eventLog.events.filter { $0.event == "tunnel.start_refused" }.count, 2)

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }

    /// A whitespace-only host on a proxied row is a host the CONNECT cannot carry, not an empty draft: that row is refused
    /// alone, on the start and on a reload, and the healthy row beside it runs.
    @RuntimeActor
    func testAProxiedRowWithAWhitespaceOnlyHostIsRefusedAloneOnStartAndReload() async throws {
        let blank = TunnelDefinition(localPort: 0, remoteHost: "   ", remotePort: 5432, proxied: true, label: "BLANK")
        let healthy = TunnelDefinition(localPort: 0, remoteHost: "db1.example.com", remotePort: 5432, proxied: false, label: "DB1")
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [blank, healthy]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        addTeardownBlock { @RuntimeActor in
            await orchestrator.stopTunnels()
            await orchestrator.stopProxy()
        }
        try await orchestrator.startProxy()
        func refusals() -> Int { orchestrator.eventLog.events.filter { $0.event == "tunnel.start_refused" }.count }

        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.map(\.label), ["DB1"], "the healthy row starts beside the refused one")
        XCTAssertEqual(refusals(), 1)
        XCTAssertEqual(
            orchestrator.snapshot.tunnelsError,
            "1 proxied tunnel(s) refused because the remote host is not a host name or IP address."
        )

        await orchestrator.stopTunnels()
        config.tunnels.definitions = [healthy]
        orchestrator.config = config
        await orchestrator.startTunnels()
        config.tunnels.definitions = [healthy, blank]
        orchestrator.config = config
        await orchestrator.reconcileTunnels()
        XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "config.tunnels_reconcile_rejected" }, "the reload is not rejected")
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.map(\.label), ["DB1"])
        XCTAssertEqual(refusals(), 2, "the reload refuses the row again")
    }

    @RuntimeActor
    func testReconcileRemovesTunnel() async throws {
        let def1 = TunnelDefinition(localPort: 0, remoteHost: "db1.example.com", remotePort: 5432, proxied: false, label: "DB1")
        let def2 = TunnelDefinition(localPort: 0, remoteHost: "db2.example.com", remotePort: 3306, proxied: false, label: "DB2")
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [def1, def2]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 2)

        var newConfig = config
        newConfig.tunnels.definitions = [def1]
        orchestrator.config = newConfig
        await orchestrator.reconcileTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1)

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }

    @RuntimeActor
    func testReconcileRejectsInvalidDefinitionAndPreservesExistingBindings() async throws {
        // Reconcile must reject invalid edits at the boundary the same way `startTunnels`
        // does — but unlike a cold-start failure, the *currently bound* listener stays up
        // so an unrelated typo can't silently tear down a healthy tunnel. The rejection
        // surfaces via `tunnelsError`, an error log, and a `config.tunnels_reconcile_rejected`
        // event for machine subscribers.
        let validDef = TunnelDefinition(
            localPort: 0, remoteHost: "db.example.com", remotePort: 5432,
            proxied: false, label: "DB"
        )
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [validDef]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1)
        let boundIDBefore = orchestrator.snapshot.bindings.tunnels.first?.id
        let boundPortBefore = orchestrator.snapshot.bindings.tunnels.first?.localPort

        var newConfig = config
        // Empty remote host trips `validateTunnelDefinitions`.
        newConfig.tunnels.definitions.append(
            TunnelDefinition(localPort: 0, remoteHost: "  ", remotePort: 6379, proxied: false, label: "BAD")
        )
        orchestrator.config = newConfig
        await orchestrator.reconcileTunnels()

        XCTAssertEqual(orchestrator.snapshot.tunnelActiveCount, 1,
                       "Existing valid tunnel must remain bound after a rejected reload")
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.first?.id, boundIDBefore,
                       "Same binding (no rebind) — invalid edit must not disturb the running listener")
        XCTAssertEqual(orchestrator.snapshot.bindings.tunnels.first?.localPort, boundPortBefore)
        XCTAssertNotNil(orchestrator.snapshot.tunnelsError)
        XCTAssertTrue(orchestrator.snapshot.tunnelsError?.hasPrefix("Tunnel reload rejected:") == true,
                      "tunnelsError must mark the rejection so the UI can distinguish it from a bind failure")

        let names = orchestrator.eventLog.events.map(\.event)
        XCTAssertTrue(names.contains("config.tunnels_reconcile_rejected"),
                      "Rejection must emit a structured event so subscribers see the rejected reload")

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }

    @RuntimeActor
    func testReconcileKeepsUnchangedTunnel() async throws {
        let def = TunnelDefinition(localPort: 0, remoteHost: "db.example.com", remotePort: 5432, proxied: false, label: "DB")
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.port = 0
        config.tunnels.definitions = [def]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        await orchestrator.startTunnels()

        let portBefore = orchestrator.snapshot.bindings.tunnels.first?.localPort

        orchestrator.config = config
        await orchestrator.reconcileTunnels()

        let portAfter = orchestrator.snapshot.bindings.tunnels.first?.localPort
        XCTAssertEqual(portBefore, portAfter, "Unchanged tunnel should keep same port")

        await orchestrator.stopTunnels()
        await orchestrator.stopProxy()
    }
}
