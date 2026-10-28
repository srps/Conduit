// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
import ConduitShared
@testable import ConduitRuntime
import ProxyControlBridge
@testable import PlatformMac
@testable import ProxyKernel

/// Status reads and Stop admission through the production framed client while the owner has other work standing: a held store read,
/// a held private transfer, a backlog of observer deliveries, and a whole bounded collection capture. Each case counts what answered and
/// asserts no wall-clock budget. Under `CONDUIT_RUNTIME_RESOURCE_PROBES=1` the capture case also prints its timings, observations only.
/// Every method is nonisolated and every wait bounded; nothing here blocks a thread of the concurrency pool.
final class RuntimeActorFairnessTests: XCTestCase {
    private static let reads = 8
    private var open: [InteractiveHostHarness] = []

    override func tearDown() async throws {
        for harness in open { await harness.tearDown() }
        open = []
        try await super.tearDown()
    }

    private struct Composed: Sendable {
        let harness: InteractiveHostHarness
        let host: RuntimeHost
        let control: any RuntimeClient
        let transport: RuntimeInMemoryTransport
    }

    @RuntimeActor
    private static func compose(stateFiles: (any StateFileAccessing)? = nil) async throws -> Composed {
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(manageSystemProxy: true), dnsForwarderEnabled: false)
        if let stateFiles { harness.stateFiles = stateFiles }
        let host = try await harness.makeHost()
        let composition = RuntimeControlComposition(
            host: host, limits: try RuntimeServiceFixtures.hostLimits(subscribers: 2), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let control = try makeFramedRuntimeClient(
            transport: composition.transport, limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return Composed(harness: harness, host: host, control: control, transport: composition.transport)
    }

    private func deadline() -> RuntimeDeadline { .after(.seconds(30), from: .now) }

    /// `reads` status reads and one proxy Stop, each answered within its own deadline. Returns how many reads answered and whether the
    /// Stop was admitted.
    private func controlAnswers(_ control: any RuntimeClient, _ incarnation: ControlHostIncarnation) async throws -> (reads: Int, stop: Bool) {
        var answered = 0
        for _ in 0..<Self.reads where try await control.readSnapshot(deadline: deadline()).stamp.incarnation == incarnation {
            answered += 1
        }
        let admission = try await control.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, deadline: deadline()
        )
        if case .accepted = admission { return (answered, true) }
        return (answered, false)
    }

    // MARK: - A held store read

    /// A reload whose configuration read is held on the store's own queue keeps the store's one slot taken. Every status read answers
    /// and the Stop is admitted meanwhile; the reload settles once released.
    func testStatusAndStopAnswerWhileAStoreReadIsHeld() async throws {
        let files = HeldStateFileRead()
        let composed = try await Self.compose(stateFiles: files)
        open.append(composed.harness)
        defer { files.hold.releaseAll() }
        let incarnation = try await composed.control.readSnapshot(deadline: deadline()).stamp.incarnation
        let stream = try await composed.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        guard case .baseline = try await stream.next(deadline()) else { return XCTFail("a stream opens with its baseline") }
        files.hold.arm(onQueueLabeled: ".configuration-store", otherQueues: .recorded) { name, _ in name == "read" }
        let reload = Task {
            try await composed.control.submit(.reload, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                                              deadline: .after(.seconds(30), from: .now))
        }
        let reached = await files.hold.waitUntilReached(within: .seconds(10))
        XCTAssertTrue(reached, "the reload's read arrived")
        XCTAssertTrue(files.hold.reachedOnArmedQueue, "on \(files.hold.reachedQueueLabel ?? "nothing")")

        let answers = try await controlAnswers(composed.control, incarnation)
        XCTAssertEqual(answers.reads, Self.reads, "every status read answered while the store's read was held")
        XCTAssertTrue(answers.stop, "the Stop was admitted while the store's read was held")
        XCTAssertTrue(files.hold.isHolding, "the read was still held")
        files.hold.release()
        guard case .accepted(let operation) = try await reload.value else { return XCTFail("the reload was admitted") }
        var settled = false
        for _ in 0..<128 where !settled {
            if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation { settled = true }
        }
        XCTAssertTrue(settled, "the reload settled once its read was released")
        XCTAssertFalse(files.hold.takenOnCooperativePool)
    }

    // MARK: - A held private transfer

    /// A private editor exchange held before its frame is sent keeps its custody reserved. Status reads and Stop admission go on.
    func testStatusAndStopAnswerWhileAPrivateTransferIsHeld() async throws {
        let composed = try await Self.compose()
        open.append(composed.harness)
        let held = HeldPrivateTransport(inner: composed.transport)
        defer { held.release() }
        let editor = PrivateEditorClient(transport: held)
        let incarnation = try await composed.control.readSnapshot(deadline: deadline()).stamp.incarnation
        held.arm(.beforeSend)
        let read = Task {
            let reading = RuntimeDeadline.after(.seconds(30), from: .now)
            return try await editor.read(
                requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                budget: try reading.wireBudget(at: .now, cappedAt: .seconds(30)), deadline: reading
            )
        }
        await held.waitUntilHeld()

        let answers = try await controlAnswers(composed.control, incarnation)
        XCTAssertEqual(answers.reads, Self.reads, "every status read answered while the private transfer was held")
        XCTAssertTrue(answers.stop, "the Stop was admitted while the private transfer was held")
        held.release()
        guard case .observation = try await read.value else { return XCTFail("the held read completed as an observation") }
    }

    // MARK: - An observer backlog

    private static let backlog = 2_000

    /// Queues the backlog on the host's own deliveries. Each delivery yields a few times, as an observer's handler awaits.
    @RuntimeActor
    private static func queueBacklog(on host: RuntimeHost, ran: NIOLockedValueBox<Int>) {
        for _ in 0..<backlog {
            host.deliveries.deliver {
                for _ in 0..<3 { await Task.yield() }
                ran.withLockedValue { $0 += 1 }
            }
        }
    }

    @RuntimeActor
    private static func drain(_ host: RuntimeHost) async {
        await host.deliveries.drain()
    }

    /// A backlog of observer deliveries does not starve the control path: the first status read queued behind it answers before the
    /// whole backlog has run, and the remaining reads and the Stop answer too.
    func testStatusAndStopAnswerBeforeAnObserverBacklogDrains() async throws {
        let composed = try await Self.compose()
        open.append(composed.harness)
        let incarnation = try await composed.control.readSnapshot(deadline: deadline()).stamp.incarnation
        let ran = NIOLockedValueBox(0)
        await Self.queueBacklog(on: composed.host, ran: ran)

        let first = try await composed.control.readSnapshot(deadline: deadline())
        let ranWhenFirstAnswered = ran.withLockedValue { $0 }
        XCTAssertEqual(first.stamp.incarnation, incarnation)
        XCTAssertLessThan(ranWhenFirstAnswered, Self.backlog,
                          "the first status read answered before the backlog drained (\(ranWhenFirstAnswered) of \(Self.backlog) ran)")
        let answers = try await controlAnswers(composed.control, incarnation)
        XCTAssertEqual(answers.reads, Self.reads)
        XCTAssertTrue(answers.stop)
        await Self.drain(composed.host)
        XCTAssertEqual(ran.withLockedValue { $0 }, Self.backlog)
    }

    // MARK: - A whole bounded collection capture

    /// Lock-guarded marks of one capture's projection and the requests issued during it.
    private final class CaptureMarks: @unchecked Sendable {
        private let lock = NSLock()
        private var entered: ContinuousClock.Instant?
        private var exited: ContinuousClock.Instant?
        private var waiter: CheckedContinuation<Void, Never>?

        func enter() {
            let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                entered = entered ?? .now
                defer { waiter = nil }
                return waiter
            }
            resume?.resume()
        }

        func exit() { lock.withLock { exited = exited ?? .now } }

        var times: (entered: ContinuousClock.Instant?, exited: ContinuousClock.Instant?) { lock.withLock { (entered, exited) } }

        /// Returns once the projection has begun.
        func waitForEntry() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let already = lock.withLock { () -> Bool in
                    if entered != nil { return true }
                    waiter = continuation
                    return false
                }
                if already { continuation.resume() }
            }
        }
    }

    @RuntimeActor
    private static func captureService(kernel: ProxyOrchestratorSnapshot, profile: RuntimeServiceProfile, marks: CaptureMarks) throws
        -> RuntimeInMemoryTransport {
        let incarnation = RuntimeServiceFixtures.incarnation(1)
        let owner = FakeCommandOwner(incarnation: incarnation, snapshot: try WireSnapshotFixture.snapshot(kernel, incarnation: incarnation))
        owner.projectionOverride = { kind, budget in
            guard kind == .activeConnections else { return RuntimeSnapshotControlProjection.projectRows(kind, from: kernel, within: budget) }
            marks.enter()
            defer { marks.exit() }
            return RuntimeSnapshotControlProjection.projectRows(kind, from: kernel, within: budget)
        }
        let core = RuntimeServiceCore(
            owner: owner, limits: profile.limits, timing: .system, scheduling: TaskOwnerScheduling(),
            makeOperationID: { ControlOperationID(rawValue: UUID()) }
        )
        return RuntimeInMemoryTransport(core: core, limits: profile.limits, timing: .system, scheduling: TaskOwnerScheduling())
    }

    /// A status read and a Stop issued off the owner while it projects the whole 10,000-row connection list are answered once that one
    /// turn ends, and the page is whole. This measures service admission and status queueing behind the capture; physical Stop truth
    /// is the actual-host tests' witness, not this fake owner's. When the requests could not be issued inside the projection (a
    /// one-thread pool runs the issuing task only after the owner's turn), the timing is reported inconclusive and not asserted.
    func testStatusAndStopIssuedDuringAFullCaptureAreAnsweredWhenItsTurnEnds() async throws {
        let probes = ProcessInfo.processInfo.environment["CONDUIT_RUNTIME_RESOURCE_PROBES"] == "1"
        let rows = 10_000
        let profile = try RuntimeServiceProfile.inProcessApp()
        let kernel = RuntimeServiceProfileKernels.typical(connections: rows)
        let marks = CaptureMarks()
        let transport = try await Self.captureService(kernel: kernel, profile: profile, marks: marks)
        let client = try makeFramedRuntimeClient(transport: transport, limits: profile.clientFrameLimits, wireBudgetCap: profile.wireBudgetCap)
        let incarnation = RuntimeServiceFixtures.incarnation(1)
        _ = try await client.readSnapshot(deadline: deadline())

        let page = Task {
            try await client.readPage(
                ControlPageRequest(expectedIncarnation: incarnation, collection: .activeConnections), deadline: .after(.seconds(60), from: .now)
            )
        }
        await marks.waitForEntry()
        let issued = ContinuousClock.now
        let bound = deadline()
        async let status = client.readSnapshot(deadline: bound)
        async let stop = client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, deadline: bound
        )
        let statusAnswer = try await status
        let statusAt = ContinuousClock.now
        let stopAnswer = try await stop
        let stopAt = ContinuousClock.now
        let reply = try await page.value

        XCTAssertEqual(statusAnswer.stamp.incarnation, incarnation, "the status read was answered")
        guard case .accepted = stopAnswer else { return XCTFail("the Stop was admitted: \(stopAnswer)") }
        guard case .activeConnections(let firstPage) = reply else { return XCTFail("the capture's first page was served: \(reply)") }
        XCTAssertEqual(firstPage.totalCount.rawValue, rows, "the capture is whole")

        let (entered, exited) = marks.times
        guard let entered, let exited, issued < exited else {
            print("RUNTIME-ACTOR-FAIRNESS capture inconclusive: the requests were issued after the projection ended")
            return
        }
        XCTAssertGreaterThanOrEqual(statusAt, exited, "the status read waited for the capture's one owner turn")
        if probes {
            print("RUNTIME-ACTOR-FAIRNESS capture rows=\(rows) projection=\(entered.duration(to: exited))"
                  + " statusAfterIssue=\(issued.duration(to: statusAt)) stopAfterIssue=\(issued.duration(to: stopAt))"
                  + " statusAfterProjection=\(exited.duration(to: statusAt))")
        }
    }
}
