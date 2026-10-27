// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import RuntimeEvents

/// The actual `RuntimeHost` as the control service's one command owner (decisions 0014, 0031, 0035 and 0036): host, then
/// `RuntimeServiceCore`, then the in-memory transport, then the framed client, over a `FakeMachine` and a scratch root. Every bound is
/// the explicit test fixture profile, never a shipping default. Waits end on observed boundaries: a held machine call, or the
/// operation's own `operationFinished` frame within a failure deadline.
@MainActor
final class RuntimeHostControlOwnerTests: XCTestCase {
    private var harness: InteractiveHostHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private let proxyAndDNS = PlatformIntegrationConfig(manageSystemProxy: true, manageEnvironmentVariables: true, manageSystemDNS: true)

    /// The composed path over one running host.
    private struct Composed {
        let host: RuntimeHost
        let harness: InteractiveHostHarness
        let composition: RuntimeControlComposition
        let client: any RuntimeClient
    }

    private func compose(dnsForwarderEnabled: Bool = true) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: proxyAndDNS, dnsForwarderEnabled: dnsForwarderEnabled)
        self.harness = harness
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host,
            limits: try RuntimeServiceFixtures.limits(),
            timing: .system,
            scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport,
            limits: ControlFrameLimits(maxFrameBytes: 64 * 1024),
            wireBudgetCap: .seconds(30)
        )
        return Composed(host: host, harness: harness, composition: composition, client: client)
    }

    /// A failure bound only: every wait below ends on its own frame or reply long before it.
    private func deadline() -> RuntimeDeadline {
        .after(.seconds(30), from: ContinuousClock.now)
    }

    /// The stream's frames up to the named operation's settlement. Bounded: a stream that never settles it fails the test.
    private func finished(_ operation: ControlOperationID, on stream: RuntimeSubscription) async throws -> ControlOperationOutcome {
        for _ in 0..<64 {
            if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation {
                return finished.outcome
            }
        }
        XCTFail("the operation's settlement never reached the stream")
        throw RuntimeClientError.unexpectedReply
    }

    private func accepted(_ admission: ControlAdmission, file: StaticString = #filePath, line: UInt = #line) throws -> ControlOperationID {
        guard case .accepted(let operation) = admission else {
            XCTFail("expected an accepted admission, got \(admission)", file: file, line: line)
            throw RuntimeClientError.unexpectedReply
        }
        return operation
    }

    private func completed(_ outcome: ControlOperationOutcome) -> ControlRuntimeCommandKind? {
        if case .completed(let completion) = outcome, completion.result == .settled { return completion.command }
        return nil
    }

    // MARK: - One incarnation

    /// The host, its workflow's store contexts, its service and its snapshots name one incarnation, and the stamp carries the v1
    /// accepted-view counter and the whole-host lifecycle counter, read through the actual framed client.
    func testTheServiceSnapshotNamesTheHostIncarnationAndItsCounters() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        XCTAssertEqual(composed.composition.service.incarnation, composed.host.incarnation)

        let snapshot = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(snapshot.stamp.incarnation, composed.host.incarnation)
        XCTAssertEqual(snapshot.stamp.lifecycleRevision.rawValue, composed.host.workflow.generation)
        XCTAssertEqual(snapshot.stamp.configRevision.rawValue, composed.host.configGeneration)
        XCTAssertEqual(snapshot.proxyState, .running)
        XCTAssertEqual(snapshot.collections.activeConnections.state, .unavailable(.notCaptured), "no collection revision is captured yet")

        let again = try await composed.client.readSnapshot(deadline: deadline())
        XCTAssertEqual(again.stamp.presentationRevision, snapshot.stamp.presentationRevision, "an unchanged body keeps its revision")
    }

    // MARK: - Stop

    /// A Stop through the client is fenced in the service's admission turn, before its teardown's first machine call and before any store
    /// work. Held at that call, DNS is already fenced and nothing is saved; released, the teardown restores system DNS and the session
    /// Stop's disable is saved, and the operation settles as a completed Stop.
    func testAStopThroughTheClientFencesBeforeItsTeardownAndSavesItsDisableAfter() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        XCTAssertTrue(composed.harness.machine.dnsRelayRunning)
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, _ in name == PrivilegedOperation.setDNSServers.rawValue }
        let revisionBefore = composed.host.workflow.revisions.dns
        let admission = try await composed.client.submit(
            .stop(.dns), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        let operation = try accepted(admission)
        XCTAssertTrue(composed.host.workflow.dnsIntent.fenced, "the fence holds at admission")
        XCTAssertGreaterThan(composed.host.workflow.revisions.dns, revisionBefore)

        await composed.harness.hold.waitUntilReached()
        XCTAssertFalse(composed.harness.hold.reachedOnMainThread)
        XCTAssertTrue(composed.host.workflow.isIdle, "no store work runs before the teardown")
        XCTAssertEqual(composed.harness.savedDNSEnabled, true, "nothing is saved while the teardown is held")
        composed.harness.hold.release()

        let outcome = try await finished(operation, on: stream)
        XCTAssertEqual(completed(outcome), .stop)
        XCTAssertFalse(composed.harness.machine.dnsRelayRunning, "system DNS is restored")
        XCTAssertEqual(composed.harness.savedDNSEnabled, false, "the session Stop's disable is saved after the teardown")
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp, "the proxy keeps running")
        XCTAssertEqual(composed.composition.service.liveOperationCount, 0, "the operation quiesced")
    }

    /// A second Stop of the same module while the first is pending joins it: one fence, one teardown and one settlement.
    func testARepeatedStopJoinsThePendingStopWhileItsFenceStands() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())

        composed.harness.hold.arm(onQueueLabeled: ".platform-work") { name, arguments in
            name == "/usr/sbin/networksetup" && arguments.first == "-listallnetworkservices"
        }
        let first = try accepted(try await composed.client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        ))
        await composed.harness.hold.waitUntilReached()
        let revision = composed.host.workflow.revisions.proxy
        let second = try await composed.client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(second, .joined(first))
        XCTAssertEqual(composed.host.workflow.revisions.proxy, revision, "a joined Stop takes no new fence")
        composed.harness.hold.release()

        let outcome = try await finished(first, on: stream)
        XCTAssertEqual(completed(outcome), .stop)
        XCTAssertFalse(composed.host.runtimeState().proxyIsUp)
        XCTAssertEqual(composed.host.orchestrator.snapshot.dnsRunState, .running, "DNS is outside the Stop's scope")
    }

    // MARK: - Restart

    /// The ordinary menu Restart names the whole-host lifecycle counter the client read. It restarts the proxy through the host's one Start
    /// path, with no companion and no editor values, and settles as a completed Restart under its own group. The same request at the old
    /// counter is then refused whole, and nothing changes.
    func testAProxyRestartAtTheObservedRevisionRestartsAndAStaleOneIsRefusedWhole() async throws {
        let composed = try await compose()
        try await composed.host.startRuntime()
        let stream = try await composed.client.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let observed = try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision

        let operation = try accepted(try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: observed), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        ))
        let outcome = try await finished(operation, on: stream)
        XCTAssertEqual(completed(outcome), .restart)
        XCTAssertTrue(composed.host.runtimeState().proxyIsUp)
        let group = observed.rawValue + 1
        XCTAssertTrue(composed.harness.typedEvents().contains(.lifecycle(.moduleSettled(
            LifecycleModuleSettled(settlement: .explicit(.proxy, .started), group: group)
        ))), "the Restart's proxy member settles under its own group")
        XCTAssertFalse(composed.harness.typedEvents().contains { payload in
            if case .lifecycle(.moduleSettled(let settled)) = payload, settled.group == group,
               case .conditionalDNS = settled.settlement { return true }
            return false
        }, "a Restart that names no DNS revision has no companion")

        let generation = composed.host.workflow.generation
        let stale = try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: observed), requestID: ControlRequestID(rawValue: UUID()),
            expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(stale, .rejected(.staleRevision))
        XCTAssertEqual(composed.host.workflow.generation, generation, "a refused request changes no intent")
        XCTAssertTrue(composed.harness.typedEvents().contains(.configWorkflow(.held(ConfigurationWorkflowHeld(
            phase: .start, input: .unit, reason: .staleRevision
        )))))
    }

    /// Commands this owner has not adopted are refused whole at the fence, and a Restart after the process quit is refused as stopping.
    func testUnadoptedCommandsAreRefusedAndARestartAfterQuitIsRefused() async throws {
        let composed = try await compose(dnsForwarderEnabled: false)
        let revision = try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision
        for command in [ControlRuntimeCommand.restart(.dns, ifLifecycleRevision: revision), .testDNS, .refreshPreflight] {
            let admission = try await composed.client.submit(
                command, requestID: ControlRequestID(rawValue: UUID()),
                expectedIncarnation: composed.host.incarnation, deadline: deadline()
            )
            XCTAssertEqual(admission, .rejected(.notImplemented), "\(command.kind.rawValue)")
        }
        XCTAssertEqual(composed.host.workflow.generation, revision.rawValue)

        await composed.host.shutdown()
        let afterQuit = try await composed.client.submit(
            .restart(.proxy, ifLifecycleRevision: try await composed.client.readSnapshot(deadline: deadline()).stamp.lifecycleRevision),
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: composed.host.incarnation, deadline: deadline()
        )
        XCTAssertEqual(afterQuit, .rejected(.hostStopping))
    }
}
