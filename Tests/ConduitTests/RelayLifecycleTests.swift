// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import ConduitShared

/// The helper's relay was rebuilt on every start — 48 DNS and 31 TCP starts
/// in the field log, every one with the parameters already running — and the
/// TCP rebuild pulled the lo0 alias out from under the app's own listener.
/// The decision is factored into `TCPRelayPlan` so it can be pinned here.
final class RelayLifecycleTests: XCTestCase {

    private let running = TCPRelayParameters(listenPort: 443, targetPort: 10443, host: "127.44.3.0")

    func testTheSameParametersAreANoOp() {
        XCTAssertEqual(TCPRelayPlan.plan(current: running, requested: running), .unchanged)
    }

    func testNothingRunningIsAFullStart() {
        XCTAssertEqual(TCPRelayPlan.plan(current: nil, requested: running), .start)
    }

    /// The ephemeral-port path: relay to a provisional target so the alias
    /// exists, bind the listener to the alias, then re-point. The re-point
    /// must keep the alias the listener is bound to.
    func testRepointingOnTheSameHostKeepsTheAlias() {
        var repointed = running
        repointed.targetPort = 51234
        XCTAssertEqual(TCPRelayPlan.plan(current: running, requested: repointed), .repoint)
    }

    func testADifferentHostIsAFullStart() {
        var moved = running
        moved.host = "127.44.3.1"
        XCTAssertEqual(TCPRelayPlan.plan(current: running, requested: moved), .start)
    }

    // MARK: - Reassert after a helper restart

    /// launchd relaunches a crashed helper with `KeepAlive`, but its relays
    /// are process state and the relaunch has none. Nothing re-issued the
    /// TCP relay start — the DNS relay has had a liveness probe for this,
    /// the TCP relay had no path back at all.
    @MainActor func testAGoneRelayIsReissuedFromTheProbe() {
        let client = RecordingPrivilegeClient()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { _, _ in false }
        )
        orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay])
        XCTAssertEqual(client.commands.first?.1, ["443", "10443", "127.44.3.0"])
        XCTAssertTrue(orchestrator.eventLog.events.contains { $0.event == "tcp_relay.reasserted" })
    }

    @MainActor func testALiveRelayIsLeftAlone() {
        let client = RecordingPrivilegeClient()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { _, _ in true }
        )
        orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        XCTAssertTrue(client.commands.isEmpty)
    }

    /// The public entry consults the published bindings: nothing published
    /// means nothing to reassert, whatever the probe says.
    @MainActor func testNothingPublishedMeansNothingToReassert() {
        let client = RecordingPrivilegeClient()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { _, _ in false }
        )
        orchestrator.reassertTransparentRelay()
        XCTAssertTrue(client.commands.isEmpty)
    }

    func testTheProbeSeesAClosedPortAsNotAccepting() {
        // Port 1 on loopback: reserved, nothing listens there on a developer
        // machine, and a refused connect is the exact signal a gone relay
        // produces.
        XCTAssertFalse(TCPAcceptProbe.accepts(host: "127.0.0.1", port: 1, timeoutMilliseconds: 200))
    }
}
