// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import ConduitShared
@testable import PlatformMac

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

    // MARK: - A stop during the probe (#199)

    /// The reassert probe runs off the main actor, for up to its connect
    /// timeout. A stop that lands meanwhile used to be followed by a fresh
    /// `startTCPRelay`: the relay came back after it was turned off.
    @MainActor func testAStopDuringTheProbeIsNotFollowedByAStart() async {
        let client = RecordingPrivilegeClient()
        let probe = BlockingRelayProbe()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { host, port in probe.accepts(host, port) }
        )
        // The first probe answers at once, so the relay comes up.
        orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay])

        let pending = Task { @MainActor in
            await orchestrator.reassertTransparentRelayOffMain(host: "127.44.3.0", targetPort: 10443)
        }
        await probe.waitUntilBlocked()
        await orchestrator.stopDNS()
        probe.release()
        await pending.value

        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay, .stopTCPRelay])
        let superseded = orchestrator.eventLog.events.filter { $0.event == "tcp_relay.reassert_superseded" }
        XCTAssertEqual(superseded.map(\.detail), ["host=127.44.3.0 target=10443 relay_active=false"])
        XCTAssertEqual(orchestrator.eventLog.events.filter { $0.event == "tcp_relay.reasserted" }.count, 1)
    }

    /// The tick reads the bindings and hands the probe to a task. A stop that
    /// runs before that task starts must fence it too: the generation is
    /// taken in the tick's turn, not when the task gets to run.
    @MainActor func testAStopBeforeTheTickTaskRunsIsNotFollowedByAStart() async {
        let client = RecordingPrivilegeClient()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { _, _ in false }
        )
        orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        let tick = orchestrator.beginTransparentRelayReassert(host: "127.44.3.0", targetPort: 10443)
        await orchestrator.stopDNS()
        await tick.value

        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay, .stopTCPRelay])
        XCTAssertEqual(
            orchestrator.eventLog.events.filter { $0.event == "tcp_relay.reassert_superseded" }.count, 1
        )
    }

    /// The fence drops only a stale verdict: with nothing in between, the
    /// off-main probe still restarts a gone relay.
    @MainActor func testTheOffMainProbeStillReissuesAGoneRelay() async {
        let client = RecordingPrivilegeClient()
        let orchestrator = ProxyOrchestrator(
            config: GenericDefaults.shared.makeConfig(),
            privilegeClient: client,
            relayAcceptProbe: { _, _ in false }
        )
        await orchestrator.reassertTransparentRelayOffMain(host: "127.44.3.0", targetPort: 10443)
        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay])
        XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "tcp_relay.reassert_superseded" })
    }

    func testTheProbeSeesAClosedPortAsNotAccepting() {
        // Port 1 on loopback: reserved, nothing listens there on a developer
        // machine, and a refused connect is the exact signal a gone relay
        // produces.
        XCTAssertFalse(TCPAcceptProbe.accepts(host: "127.0.0.1", port: 1, timeoutMilliseconds: 200))
    }
}

/// Answers the first probe at once (not accepting), then holds every later
/// probe until released, so a test can land a stop while one is out.
private final class BlockingRelayProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private let blocked = DispatchSemaphore(value: 0)
    private let gate = DispatchSemaphore(value: 0)

    func accepts(_ host: String, _ port: Int) -> Bool {
        let call = lock.withLock { () -> Int in
            calls += 1
            return calls
        }
        guard call > 1 else { return false }
        blocked.signal()
        gate.wait()
        return false
    }

    /// Waits off the main actor, which the stop needs.
    func waitUntilBlocked() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global().async {
                self.blocked.wait()
                continuation.resume()
            }
        }
    }

    func release() {
        gate.signal()
    }
}
