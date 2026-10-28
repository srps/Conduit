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
    @MainActor func testAGoneRelayIsReissuedFromTheProbe() async {
        let client = RecordingPrivilegeClient()
        let orchestrator = relayOrchestrator(client: client, probe: { _, _ in false })
        await startDNS(orchestrator)
        await orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay])
        XCTAssertEqual(client.commands.first?.1, ["443", "10443", "127.44.3.0"])
        XCTAssertTrue(orchestrator.eventLog.events.contains { $0.event == "tcp_relay.reasserted" })
        await orchestrator.stopDNS()
    }

    @MainActor func testALiveRelayIsLeftAlone() async {
        let client = RecordingPrivilegeClient()
        let orchestrator = relayOrchestrator(client: client, probe: { _, _ in true })
        await startDNS(orchestrator)
        await orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        XCTAssertTrue(client.commands.isEmpty)
        await orchestrator.stopDNS()
    }

    /// The public entry consults the published bindings: nothing published
    /// means nothing to reassert, whatever the probe says.
    @MainActor func testNothingPublishedMeansNothingToReassert() async {
        let client = RecordingPrivilegeClient()
        let orchestrator = relayOrchestrator(client: client, probe: { _, _ in false })
        await orchestrator.reassertTransparentRelay()
        XCTAssertTrue(client.commands.isEmpty)
    }

    // MARK: - A stop during the probe (#199)

    /// The reassert probe runs off the main actor, for up to its connect
    /// timeout. A stop that lands meanwhile used to be followed by a fresh
    /// `startTCPRelay`: the relay came back after it was turned off.
    @MainActor func testAStopDuringTheProbeIsNotFollowedByAStart() async {
        let client = RecordingPrivilegeClient()
        let probe = BlockingRelayProbe()
        defer { probe.release() }
        let orchestrator = relayOrchestrator(client: client, probe: { host, port in probe.accepts(host, port) })
        await startDNS(orchestrator)
        // The first probe answers at once, so the relay comes up.
        await orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
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
    /// runs before that task starts must fence it too: the fence is taken in
    /// the tick's turn, not when the task gets to run.
    @MainActor func testAStopBeforeTheTickTaskRunsIsNotFollowedByAStart() async throws {
        let client = RecordingPrivilegeClient()
        let orchestrator = relayOrchestrator(client: client, probe: { _, _ in false })
        await startDNS(orchestrator)
        await orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        let tick = try XCTUnwrap(orchestrator.beginTransparentRelayReassert(host: "127.44.3.0", targetPort: 10443))
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
        let orchestrator = relayOrchestrator(client: client, probe: { _, _ in false })
        await startDNS(orchestrator)
        await orchestrator.reassertTransparentRelayOffMain(host: "127.44.3.0", targetPort: 10443)
        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay])
        XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "tcp_relay.reassert_superseded" })
        await orchestrator.stopDNS()
    }

    // MARK: - The reassert inside the DNS module's slot

    /// A reassert's reissue runs as an effect in the DNS module's slot. Its start, held on the platform queue, has claimed the slot
    /// when a DNS Stop is admitted, so the Stop's teardown waits for it and then stops the relay it started. Run beside the slot, the
    /// teardown would find no relay up yet, skip the stop, and leave the relay the start then raised running after DNS stopped.
    @MainActor func testADNSStopAdmittedWhileAReassertsStartIsHeldWaitsForItAndEndsTheRelayStopped() async {
        let client = RecordingPrivilegeClient()
        let hold = HeldCall()
        defer { hold.release() }
        let orchestrator = relayOrchestrator(client: client, hold: hold, probe: { _, _ in false })
        await startDNS(orchestrator)
        hold.arm(onQueueLabeled: Self.relayQueueLabel, otherQueues: .recorded) { name, _ in
            name == PrivilegedOperation.startTCPRelay.rawValue
        }
        let reassert = Task { @MainActor in
            await orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        }
        let reached = await hold.waitUntilReached(within: .seconds(10))
        XCTAssertTrue(reached, "the reassert's relay start reached the helper")
        XCTAssertTrue(hold.reachedOnArmedQueue, "it is held on the platform queue, not \(hold.reachedQueueLabel ?? "nowhere")")

        let stop = Task { @MainActor in await orchestrator.stopDNS() }
        for _ in 0..<5_000 where orchestrator.dnsLifecycle.admitsRunning {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertFalse(orchestrator.dnsLifecycle.admitsRunning, "the DNS Stop is admitted while the start is held")
        // A teardown beside the slot closes the forwarder within a few milliseconds; give it that long to show.
        for _ in 0..<500 where orchestrator.snapshot.dnsRunState == .running {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "the Stop's teardown waits for the reassert's effect")
        XCTAssertTrue(client.commands.isEmpty, "nothing reached the helper while the start is held")
        hold.release()
        await reassert.value
        await stop.value

        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay, .stopTCPRelay],
                       "the reassert's start, then the Stop's teardown stops the relay it raised")
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .stopped)
        XCTAssertEqual(orchestrator.eventLog.events.filter { $0.event == "tcp_relay.reasserted" }.count, 1)
    }

    /// One reassert at a time: a tick taken while one is in flight begins nothing, so the slot never holds more than one reassert
    /// waiting beside the lifecycle effects it orders.
    @MainActor func testATickWhileAReassertIsInFlightBeginsNothing() async throws {
        let client = RecordingPrivilegeClient()
        let probe = BlockingRelayProbe()
        defer { probe.release() }
        let orchestrator = relayOrchestrator(client: client, probe: { host, port in probe.accepts(host, port) })
        await startDNS(orchestrator)
        // The first probe answers at once, so the relay comes up.
        await orchestrator.reassertTransparentRelay(host: "127.44.3.0", targetPort: 10443)
        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay])

        let first = try XCTUnwrap(orchestrator.beginTransparentRelayReassert(host: "127.44.3.0", targetPort: 10443))
        await probe.waitUntilBlocked()
        let second = orchestrator.beginTransparentRelayReassert(host: "127.44.3.0", targetPort: 10443)
        XCTAssertNil(second, "a tick while the first reassert's probe is out begins nothing")
        probe.release()
        await first.value
        await second?.value

        XCTAssertEqual(client.commands.map(\.0), [.startTCPRelay, .startTCPRelay], "only the first tick reissued the relay")
        XCTAssertEqual(orchestrator.eventLog.events.filter { $0.event == "tcp_relay.reasserted" }.count, 2)
        // Once it ended, a tick begins again.
        let later = orchestrator.beginTransparentRelayReassert(host: "127.44.3.0", targetPort: 10443)
        XCTAssertNotNil(later)
        probe.release()
        await later?.value
        await orchestrator.stopDNS()
    }

    // MARK: - Fixture

    private static let relayQueueLabel = "io.github.srps.Conduit.relay-test.platform-work"

    /// An orchestrator whose relay commands run one at a time on a platform queue of their own, as the host composes them, each step
    /// offered to `hold` there first. Its forwarder binds an ephemeral port.
    @MainActor
    private func relayOrchestrator(
        client: RecordingPrivilegeClient,
        hold: HeldCall = HeldCall(),
        probe: @escaping @Sendable (String, Int) -> Bool
    ) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.dnsForwarderPort = 0
        let work = PlatformWork(label: Self.relayQueueLabel)
        return ProxyOrchestrator(
            config: config,
            relayCommand: { step in
                try await work.run {
                    Result {
                        hold.pass(step.operation.rawValue, step.values)
                        try client.execute(step.operation, values: step.values)
                    }
                }.get()
            },
            relayAcceptProbe: probe
        )
    }

    /// Starts the DNS module, the slot a reassert runs in, and checks it is running.
    @MainActor
    private func startDNS(_ orchestrator: ProxyOrchestrator) async {
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "the DNS module is up")
        XCTAssertTrue(orchestrator.dnsLifecycle.admitsRunning)
    }

    func testTheProbeSeesAClosedPortAsNotAccepting() {
        // Port 1 on loopback: reserved, nothing listens there on a developer
        // machine, and a refused connect is the exact signal a gone relay
        // produces.
        XCTAssertFalse(TCPAcceptProbe.accepts(host: "127.0.0.1", port: 1, timeoutMilliseconds: 200))
    }
}

/// Answers the first probe at once (not accepting), then holds every later
/// probe until released, so a test can land a stop while one is out. Once
/// released, every held probe and every later one goes on.
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
        // Passed on, so a release frees every probe held with this one, and any that comes after.
        gate.signal()
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
