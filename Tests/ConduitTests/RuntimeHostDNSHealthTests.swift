// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The host's one DNS health observation through the actual service and framed client, over a `FakeMachine` and a scratch root. The
/// harness's injected probe answers nothing, so a relay restart's own final probe finds the pipeline unresponsive. A reading is reported
/// through the host's existing internal entry, with the token its timer would have armed; a held restart parks on its final probe.
@MainActor
final class RuntimeHostDNSHealthTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private let proxyAndDNS = PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)

    private struct Composed {
        let host: RuntimeHost
        let harness: InteractiveHostHarness
        let composition: RuntimeControlComposition
        let client: any RuntimeClient
    }

    /// A running host with DNS managed, its health timer armed, and the framed client over its service.
    private func composeRunning() async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: true)
        self.harness = harness
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.hostLimits(), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport, limits: ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        try await host.startRuntime()
        XCTAssertEqual(host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertNotNil(host.dnsHealthTimer, "the timer runs beside the managed DNS")
        return Composed(host: host, harness: harness, composition: composition, client: client)
    }

    private func deadline() -> RuntimeDeadline {
        .after(.seconds(30), from: ContinuousClock.now)
    }

    /// A failure bound on real effects: polls an observed boundary, never decides by time.
    private func eventually(_ condition: @MainActor () -> Bool) async throws -> Bool {
        for _ in 0..<2_000 where !condition() {
            try await Task.sleep(for: .milliseconds(5))
        }
        return condition()
    }

    private func forwarderPort(_ host: RuntimeHost) -> Int {
        host.orchestrator.snapshot.bindings.dnsPort ?? host.config.dnsForwarderPort
    }

    /// A failed reading restarts the relay; its own final probe finds the pipeline unresponsive, so the host's snapshot carries the fixed
    /// DNS error while the kernel still reports the forwarder running. A subscriber is told without asking, and a later read after the gap
    /// reads the same. An error of the kernel's own wins. An alive reading for the same run clears it, at a newer presentation revision.
    func testAnUnresponsiveRestartDegradesTheSnapshotAndAnAliveReadingRecoversIt() async throws {
        let composed = try await composeRunning()
        let host = composed.host
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let before = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertNil(before.dnsError)

        let token = host.lanes.dns.observationToken
        host.handleDNSHealthResult(alive: false, forwarderPort: forwarderPort(host), armedBy: token)
        await host.deliveries.drain()
        XCTAssertTrue(host.dnsRelayUnresponsive)
        XCTAssertTrue(host.orchestrator.eventLog.events.contains {
            $0.event == "dns.pipeline_unresponsive" && $0.detail == "source=health_timer"
        }, "the restart's result is recorded under a host-neutral source")

        var pushed: ControlRuntimeSnapshot?
        for _ in 0..<32 where pushed == nil {
            if case .snapshot(let snapshot) = try await stream.next(deadline()), snapshot.dnsError != nil { pushed = snapshot }
        }
        XCTAssertEqual(pushed?.dnsError, RuntimeHost.dnsRelayUnresponsiveError, "the owner's change reached the subscriber")

        let degraded = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(degraded.dnsRunState, .running, "the kernel's run state stays authoritative")
        XCTAssertEqual(degraded.dnsError, RuntimeHost.dnsRelayUnresponsiveError)
        XCTAssertGreaterThan(degraded.stamp.presentationRevision, before.stamp.presentationRevision)

        host.orchestrator.mutateSnapshotForTesting { $0.dnsError = "Forwarder reported its own error" }
        let kernelError = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(kernelError.dnsError, "Forwarder reported its own error", "the kernel's own error wins")
        host.orchestrator.mutateSnapshotForTesting { $0.dnsError = nil }

        host.handleDNSHealthResult(alive: true, forwarderPort: forwarderPort(host), armedBy: token)
        XCTAssertFalse(host.dnsRelayUnresponsive)
        let recovered = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertNil(recovered.dnsError)
        XCTAssertEqual(recovered.dnsRunState, .running)
        XCTAssertGreaterThan(recovered.stamp.presentationRevision, degraded.stamp.presentationRevision)
    }

    /// Readings belong to the run whose timer armed them. A restart for run A whose final probe is held while a Stop begins reports its
    /// result, but sets no observation: the Stop superseded A. In run B, A's late failed reading restarts nothing and its late alive
    /// reading clears nothing; B's own failed reading is B's observation, and B's Stop clears it with its timer.
    func testAReadingOrRestartOfASupersededRunNeverBecomesTheNewerRunsObservation() async throws {
        let composed = try await composeRunning()
        let host = composed.host
        let harness = composed.harness
        let runA = host.lanes.dns.observationToken

        // The restart's own final probe asks port 53 on the platform queue, where it parks.
        harness.hold.arm(onQueueLabeled: ".platform-work") { name, values in name == "dns-probe" && values == ["53"] }
        host.handleDNSHealthResult(alive: false, forwarderPort: forwarderPort(host), armedBy: runA)
        await harness.hold.waitUntilReached()
        let stop = Task { await host.stopRuntime() }
        let superseded = try await eventually { runA.isSuperseded }
        XCTAssertTrue(superseded, "the Stop began while A's restart was out")
        harness.hold.release()
        await stop.value
        await host.deliveries.drain()
        XCTAssertFalse(host.dnsRelayUnresponsive, "A's late restart result is not an observation of anything running")

        try await host.startRuntime()
        let runB = host.lanes.dns.observationToken
        XCTAssertFalse(runB.isSuperseded)
        let relayStarts = harness.machine.privilege.commands(matching: .startDNSRelay).count
        host.handleDNSHealthResult(alive: false, forwarderPort: forwarderPort(host), armedBy: runA)
        await host.deliveries.drain()
        XCTAssertEqual(harness.machine.privilege.commands(matching: .startDNSRelay).count, relayStarts, "no restart for a superseded run")
        XCTAssertFalse(host.dnsRelayUnresponsive)
        let afterStaleReading = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertNil(afterStaleReading.dnsError)

        host.handleDNSHealthResult(alive: false, forwarderPort: forwarderPort(host), armedBy: runB)
        await host.deliveries.drain()
        XCTAssertTrue(host.dnsRelayUnresponsive, "B's own reading is B's observation")
        host.handleDNSHealthResult(alive: true, forwarderPort: forwarderPort(host), armedBy: runA)
        XCTAssertTrue(host.dnsRelayUnresponsive, "A's late alive reading clears nothing of B's")
        let degradedB = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(degradedB.dnsError, RuntimeHost.dnsRelayUnresponsiveError)

        await host.stopRuntime()
        XCTAssertFalse(host.dnsRelayUnresponsive, "the Stop ends the observation with its timer")
        let stopped = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertNil(stopped.dnsError)
        XCTAssertNotEqual(stopped.dnsRunState, .running)
    }
}
