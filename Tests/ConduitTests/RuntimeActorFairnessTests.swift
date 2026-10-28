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

    /// A status read and a Stop issued while the whole 10,000-row connection list is being projected are answered before that projection
    /// ends, because it runs off the owner, and the page is whole. This measures service admission and status answering beside the
    /// capture; physical Stop truth is the actual-host tests' witness, not this fake owner's. When the requests could not be issued inside
    /// the projection (a one-thread pool runs the issuing task only after it), the timing is reported inconclusive and not asserted.
    func testStatusAndStopIssuedDuringAFullCaptureAreAnsweredBeforeItEnds() async throws {
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
        XCTAssertLessThan(statusAt, exited, "the status read was answered while the capture was still projecting")
        XCTAssertLessThan(stopAt, exited, "the Stop was admitted while the capture was still projecting")
        if probes {
            print("RUNTIME-ACTOR-FAIRNESS capture rows=\(rows) projection=\(entered.duration(to: exited))"
                  + " statusAfterIssue=\(issued.duration(to: statusAt)) stopAfterIssue=\(issued.duration(to: stopAt))"
                  + " statusAfterProjection=\(exited.duration(to: statusAt))")
        }
    }

    // MARK: - The shared capture flight

    /// Holds every capture job where it suspends, on no thread, until released, so the flight tests run alike under a one-thread pool.
    /// It records each job's kind in start order. Released, it lets every later job through too.
    private final class HeldProjection: @unchecked Sendable {
        private let lock = NSLock()
        private var holding = true
        private var parked: [CheckedContinuation<Void, Never>] = []
        private var kinds: [ControlCollectionKind] = []

        var started: [ControlCollectionKind] { lock.withLock { kinds } }
        var heldCount: Int { lock.withLock { parked.count } }

        func enter(_ kind: ControlCollectionKind) async {
            lock.withLock { kinds.append(kind) }
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let pass = lock.withLock { () -> Bool in
                    guard holding else { return true }
                    parked.append(continuation)
                    return false
                }
                if pass { continuation.resume() }
            }
        }

        func release() {
            let waiting = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
                holding = false
                defer { parked = [] }
                return parked
            }
            for continuation in waiting { continuation.resume() }
        }

        /// Waits, bounded, until `count` jobs are held.
        func waitUntilHeld(_ count: Int = 1) async -> Bool {
            for _ in 0..<5_000 where heldCount < count {
                try? await Task.sleep(for: .milliseconds(1))
            }
            return heldCount >= count
        }
    }

    /// The production service and transport over a fake owner whose tunnel DNS hosts are `hosts` at revision 1, with the framed client
    /// over them. The owner's frozen jobs pass through `held`. The clock is the test's own, so no deadline passes unless a test moves it.
    /// The service's own hops are `coreHops` when named, so a test can see a flight's completion hop arrive and run it; the transport's
    /// rounds are always owner tasks.
    private struct FlightService: Sendable {
        let owner: FakeCommandOwner
        let core: RuntimeServiceCore
        let client: any RuntimeClient
        let timing: ManualRuntimeTiming
        let held: HeldProjection
    }

    private static let flightIncarnation = RuntimeServiceFixtures.incarnation(1)

    @RuntimeActor
    private static func flightService(
        hosts: [String] = ["a.example", "b.example"], coreHops: ManualOwnerScheduling? = nil, rowAge: Duration = .seconds(60)
    ) throws -> FlightService {
        let limits = try RuntimeServiceFixtures.limits(collectionRowAge: rowAge)
        let timing = ManualRuntimeTiming()
        let held = HeldProjection()
        let owner = FakeCommandOwner(incarnation: flightIncarnation, snapshot: try flightSnapshot(revision: 1, hosts: hosts))
        owner.dnsHostnames = hosts
        owner.projectionGate = { kind in await held.enter(kind) }
        let core = RuntimeServiceCore(
            owner: owner, limits: limits, timing: timing.timing, scheduling: coreHops ?? TaskOwnerScheduling(),
            makeOperationID: { ControlOperationID(rawValue: UUID()) }
        )
        let transport = RuntimeInMemoryTransport(core: core, limits: limits, timing: timing.timing, scheduling: TaskOwnerScheduling())
        let client = try makeFramedRuntimeClient(
            transport: transport, limits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return FlightService(owner: owner, core: core, client: client, timing: timing, held: held)
    }

    private static func flightRevision(_ value: Int) throws -> ControlCollectionRevision {
        try XCTUnwrap(ControlCollectionRevision(rawValue: value))
    }

    private static func flightSnapshot(revision: Int, hosts: [String]) throws -> ControlRuntimeSnapshot {
        try RuntimeServiceFixtures.snapshot(
            incarnation: 1,
            collections: ControlCollectionRevisions(upstreamHealth: try flightRevision(1), tunnelDNSHosts: try flightRevision(revision)),
            dnsStatus: .active(hostnames: hosts)
        )
    }

    /// Moves the owner to a new tunnel DNS revision, reported to the service in the same owner turn.
    @RuntimeActor
    private static func advance(_ service: FlightService, revision: Int, hosts: [String]) throws {
        service.owner.dnsHostnames = hosts
        service.owner.snapshotValue = try flightSnapshot(revision: revision, hosts: hosts)
        service.core.ownerDidChange()
    }

    @RuntimeActor
    private static func flightWaits(_ service: FlightService) -> Int? {
        service.core.captureFlightWaitCount
    }

    @RuntimeActor
    private static func proofs(_ service: FlightService, _ kind: ControlCollectionKind) -> Int {
        service.core.collectionRetention(kind).proofs
    }

    @RuntimeActor
    private static func faults(_ service: FlightService) -> [ControlServiceFault] {
        service.owner.faults
    }

    /// Waits, bounded, until an owner-side condition holds.
    @RuntimeActor
    private static func until(_ condition: @RuntimeActor () -> Bool) async -> Bool {
        for _ in 0..<5_000 where !condition() {
            try? await Task.sleep(for: .milliseconds(1))
        }
        return condition()
    }

    private static func flightDeadline(_ service: FlightService) -> RuntimeDeadline {
        .after(.seconds(30), from: service.timing.now)
    }

    private static func readPage(
        _ service: FlightService, _ kind: ControlCollectionKind = .tunnelDNSHosts, cursor: ControlPageCursor? = nil,
        deadline: RuntimeDeadline? = nil
    ) async throws -> ControlPageReply {
        try await service.client.readPage(
            ControlPageRequest(expectedIncarnation: flightIncarnation, collection: kind, cursor: cursor),
            deadline: deadline ?? flightDeadline(service)
        )
    }

    /// A status read and a Stop admission are answered while the capture flight's job is provably held, and the page is answered from
    /// that capture, current and whole, once it is released.
    func testStatusAndStopAnswerWhileTheCaptureFlightIsHeld() async throws {
        let service = try await Self.flightService()
        let page = Task { try await RuntimeActorFairnessTests.readPage(service) }
        let heldNow = await service.held.waitUntilHeld()
        XCTAssertTrue(heldNow, "the flight's job is held")
        let status = try await service.client.readSnapshot(deadline: Self.flightDeadline(service))
        XCTAssertEqual(status.stamp.incarnation, Self.flightIncarnation, "the status read was answered")
        let stop = try await service.client.submit(
            .stop(.proxy), requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: Self.flightIncarnation,
            deadline: Self.flightDeadline(service)
        )
        guard case .accepted = stop else { return XCTFail("the Stop was admitted: \(stop)") }
        XCTAssertEqual(service.held.heldCount, 1, "both were answered while the job was still held")
        service.held.release()
        guard case .tunnelDNSHosts(let first) = try await page.value else { return XCTFail("the page was answered with rows") }
        XCTAssertEqual(first.status, .current)
        XCTAssertEqual(first.totalCount.rawValue, 2)
        XCTAssertEqual(first.rows.count, 2, "the capture is whole")
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts])
    }

    /// Churn: the owner moves to a new revision while the flight projects the old one. The waiting first page is answered from its own
    /// flight as a stale read of that revision, exactly what an ordinary request with a cursor at it gets, and is never left to time out;
    /// the next first page starts a new flight for the current revision.
    func testAFlightWhoseRevisionMovedAnswersItsPageAsAStaleReadOfThatRevision() async throws {
        let service = try await Self.flightService(hosts: ["a.example", "b.example"])
        let page = Task { try await RuntimeActorFairnessTests.readPage(service) }
        let heldNow = await service.held.waitUntilHeld()
        XCTAssertTrue(heldNow)
        try await Self.advance(service, revision: 2, hosts: ["c.example"])
        service.held.release()
        let reply = try await page.value
        guard case .tunnelDNSHosts(let stale) = reply else { return XCTFail("the page was answered with rows: \(reply)") }
        XCTAssertEqual(stale.revision, try Self.flightRevision(1), "the rows are the revision the flight froze")
        XCTAssertEqual(stale.status, .staleRevision(current: try Self.flightRevision(2)))
        XCTAssertEqual(stale.rows.count, 2)
        let viaCursor = try await RuntimeActorFairnessTests.readPage(
            service, cursor: ControlPageCursor(revision: try Self.flightRevision(1), offset: try ControlCount(0))
        )
        XCTAssertEqual(viaCursor, reply, "the same answer as an ordinary read with a cursor at that revision")
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts], "answered from its own flight, not captured again")

        guard case .tunnelDNSHosts(let current) = try await RuntimeActorFairnessTests.readPage(service) else { return XCTFail("the next first page has rows") }
        XCTAssertEqual(current.revision, try Self.flightRevision(2))
        XCTAssertEqual(current.status, .current)
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts, .tunnelDNSHosts], "the next first page started a new flight")
    }

    /// Two first pages of one kind during one flight join it: one job runs, and both are answered with its revision.
    func testFirstPagesOfOneKindJoinTheOneFlight() async throws {
        let service = try await Self.flightService()
        let first = Task { try await RuntimeActorFairnessTests.readPage(service) }
        let second = Task { try await RuntimeActorFairnessTests.readPage(service) }
        let joined = await Self.until { Self.flightWaits(service) == 2 }
        XCTAssertTrue(joined, "both pages wait on the flight")
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts], "one job for both")
        service.held.release()
        let replies = [try await first.value, try await second.value]
        XCTAssertEqual(replies[0], replies[1])
        guard case .tunnelDNSHosts(let page) = replies[0] else { return XCTFail("rows") }
        XCTAssertEqual(page.status, .current)
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts])
    }

    /// A page of another kind waits for the flight in progress to end; its own job starts only after that, so at most one capture is
    /// outside the ledger at a time.
    func testAPageOfAnotherKindWaitsForTheFlightThenStartsItsOwn() async throws {
        let service = try await Self.flightService()
        let hosts = Task { try await RuntimeActorFairnessTests.readPage(service, .tunnelDNSHosts) }
        let heldNow = await service.held.waitUntilHeld()
        XCTAssertTrue(heldNow)
        let health = Task { try await RuntimeActorFairnessTests.readPage(service, .upstreamHealth) }
        let waiting = await Self.until { Self.flightWaits(service) == 2 }
        XCTAssertTrue(waiting, "the other kind waits on the one flight")
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts], "its own job has not started while the flight runs")
        service.held.release()
        guard case .tunnelDNSHosts(let hostsPage) = try await hosts.value else { return XCTFail("hosts rows") }
        guard case .upstreamHealth(let healthPage) = try await health.value else { return XCTFail("health rows") }
        XCTAssertEqual(hostsPage.status, .current)
        XCTAssertEqual(healthPage.status, .current)
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts, .upstreamHealth], "the other kind's flight started after the first ended")
    }

    /// A page whose deadline passes, or whose task is cancelled, while the flight is held ends alone: it is not sent, its wait leaves the
    /// flight, and the flight still commits. A later first page is served from that capture with no second job.
    func testAPageThatEndsWhileTheFlightIsHeldLeavesAloneAndTheFlightStillCommits() async throws {
        for ending in ["deadline", "cancel"] {
            let service = try await Self.flightService()
            let page = Task { try await RuntimeActorFairnessTests.readPage(service, deadline: .after(.seconds(5), from: service.timing.now)) }
            let parked = await Self.until { Self.flightWaits(service) == 1 }
            XCTAssertTrue(parked, ending)
            if ending == "deadline" {
                service.timing.advance(by: .seconds(6))
                service.timing.fireAll()
            } else {
                page.cancel()
            }
            do {
                _ = try await page.value
                XCTFail("\(ending): the page ended without an answer")
            } catch {
                let expected: [RuntimeClientError] = ending == "deadline"
                    ? [.notSent(.deadlineExpired), .wire(.deadlineExpired)] : [.notSent(.cancelled)]
                let ended = (error as? RuntimeClientError).map(expected.contains) ?? (ending == "cancel" && error is CancellationError)
                XCTAssertTrue(ended, "\(ending): \(error)")
            }
            let left = await Self.until { Self.flightWaits(service) == 0 }
            XCTAssertTrue(left, "\(ending): its wait left the flight, which still runs")
            service.held.release()
            let committed = await Self.until { Self.proofs(service, .tunnelDNSHosts) == 1 }
            XCTAssertTrue(committed, "\(ending): the flight committed with no page waiting")
            guard case .tunnelDNSHosts(let later) = try await RuntimeActorFairnessTests.readPage(service) else { return XCTFail("\(ending): rows") }
            XCTAssertEqual(later.status, .current)
            XCTAssertEqual(service.held.started, [.tunnelDNSHosts], "\(ending): served from that capture, with no second job")
        }
    }

    /// Shutdown while the flight is held: the waiting page is woken at once and refused as not captured with the exact total its
    /// reference names, before the job is released. The old job's completion hop still comes, and it commits nothing. No capture starts
    /// after shutdown.
    func testShutdownWakesTheFlightsPageAtOnceAndTheOldCompletionCommitsNothing() async throws {
        let hops = ManualOwnerScheduling()
        let service = try await Self.flightService(coreHops: hops)
        let page = Task { try await RuntimeActorFairnessTests.readPage(service) }
        let heldNow = await service.held.waitUntilHeld()
        XCTAssertTrue(heldNow)
        await Self.shutDown(service)
        let reply = try await page.value
        XCTAssertEqual(reply, .unavailable(.tunnelDNSHosts, .notCaptured, knownTotal: try ControlCount(2)))
        XCTAssertEqual(service.held.heldCount, 1, "answered while the old job was still held")

        service.held.release()
        let completed = await Self.runCompletionHop(hops)
        XCTAssertTrue(completed, "the old job's completion hop came and ran")
        let afterCompletion = await Self.proofs(service, .tunnelDNSHosts)
        XCTAssertEqual(afterCompletion, 0, "the old completion committed nothing")
        let again = try await RuntimeActorFairnessTests.readPage(service)
        XCTAssertEqual(again, .unavailable(.tunnelDNSHosts, .notCaptured, knownTotal: try ControlCount(2)))
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts], "no job starts after shutdown")
    }

    @RuntimeActor
    private static func shutDown(_ service: FlightService) {
        service.core.hostDidShutDown()
    }

    /// Waits, bounded, for a completion hop queued from off the owner, then runs every queued hop.
    @RuntimeActor
    private static func runCompletionHop(_ hops: ManualOwnerScheduling) async -> Bool {
        let queued = await until { hops.pendingCount > 0 }
        hops.drainAll()
        return queued
    }

    /// The capture's age runs from the flight's start, not from its commit: rows held past the retention age counted from the start are
    /// captured again, although the commit was more recent than that age. (The fixture age is 20 s, inside one request's 30 s budget.)
    func testACapturesAgeRunsFromTheFlightsStart() async throws {
        let service = try await Self.flightService(rowAge: .seconds(20))
        let page = Task { try await RuntimeActorFairnessTests.readPage(service) }
        let heldNow = await service.held.waitUntilHeld()
        XCTAssertTrue(heldNow)
        service.timing.advance(by: .seconds(15))
        service.held.release()
        guard case .tunnelDNSHosts(let first) = try await page.value else { return XCTFail("rows") }
        XCTAssertEqual(first.status, .current)
        service.timing.advance(by: .seconds(6))
        guard case .tunnelDNSHosts(let next) = try await RuntimeActorFairnessTests.readPage(service) else { return XCTFail("rows") }
        XCTAssertEqual(next.status, .current)
        XCTAssertEqual(service.held.started, [.tunnelDNSHosts, .tunnelDNSHosts],
                       "21 s after the start and 6 s after the commit, the 20 s rows are aged and captured again")
    }

    /// A late cleanup names its wait by token: a wait whose flight already ended is removed from no newer flight, whose own wait stays.
    @RuntimeActor
    func testALateCleanupOfAnEndedFlightsWaitLeavesTheNewFlightsWaitIntact() async throws {
        let harness = try RuntimeServiceHarness(limits: try RuntimeServiceFixtures.limits())
        try Self.publish(harness, revision: 1, hosts: ["a.example"])
        let request = ControlPageRequest(expectedIncarnation: Self.flightIncarnation, collection: .tunnelDNSHosts)
        guard case .awaitingCapture(let ended) = harness.core.pageSource(request) else { return XCTFail("the first flight started") }
        let completed = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(completed)
        harness.scheduling.drainAll()
        XCTAssertNil(harness.core.captureFlightWaitCount, "the first flight ended")
        try Self.publish(harness, revision: 2, hosts: ["b.example"])
        guard case .awaitingCapture(let current) = harness.core.pageSource(request) else { return XCTFail("a new flight started") }
        harness.core.releaseCaptureWait(ended.token)
        XCTAssertEqual(harness.core.captureFlightWaitCount, 1, "the ended flight's late cleanup left the new flight's wait")
        let next = await awaitState { harness.scheduling.pendingCount > 0 }
        XCTAssertTrue(next)
        harness.scheduling.drainAll()
        guard case .rows(let revision, _, _, .current) = harness.core.pageSource(request, resuming: current) else {
            return XCTFail("the new flight's wait was answered")
        }
        XCTAssertEqual(revision, try Self.flightRevision(2))
    }

    @RuntimeActor
    private static func publish(_ harness: RuntimeServiceHarness, revision: Int, hosts: [String]) throws {
        harness.owner.dnsHostnames = hosts
        harness.owner.snapshotValue = try flightSnapshot(revision: revision, hosts: hosts)
    }

    /// A flight that ends in a closed answer gives every page waiting on it that answer once, reports the fault once, and runs one job:
    /// nothing captures again in a loop.
    func testAFlightsClosedAnswerReachesEveryWaitingPageOnce() async throws {
        let cases: [(name: String, projection: ControlProjection, reply: Result<ControlPageReply, RuntimeClientError>,
                     faults: [ControlServiceFault])] = [
            ("over budget", .overBudget,
             .success(.unavailable(.tunnelDNSHosts, .retentionBudgetExceeded, knownTotal: try ControlCount(2))), []),
            ("internal failure", .internalFailure, .failure(.wire(.internalFailure)), [.projectionNotEncodable]),
            ("count mismatch", .rows(.tunnelDNSHosts([ControlTunnelDNSHostRow(hostname: "a.example", outcome: .active)]), encodedBytes: 1),
             .failure(.wire(.internalFailure)), [.projectionCountMismatch]),
        ]
        for testCase in cases {
            let service = try await Self.flightService()
            let held = service.held
            let projection = testCase.projection
            await Self.overrideProjection(service) { kind, _ in
                await held.enter(kind)
                return projection
            }
            let first = Task { () -> Result<ControlPageReply, RuntimeClientError> in await RuntimeActorFairnessTests.result { try await RuntimeActorFairnessTests.readPage(service) } }
            let second = Task { () -> Result<ControlPageReply, RuntimeClientError> in await RuntimeActorFairnessTests.result { try await RuntimeActorFairnessTests.readPage(service) } }
            let joined = await Self.until { Self.flightWaits(service) == 2 }
            XCTAssertTrue(joined, testCase.name)
            held.release()
            let firstResult = await first.value
            let secondResult = await second.value
            XCTAssertEqual(firstResult, testCase.reply, testCase.name)
            XCTAssertEqual(secondResult, testCase.reply, testCase.name)
            let reported = await Self.faults(service)
            XCTAssertEqual(reported, testCase.faults, "\(testCase.name): the fault is reported once")
            XCTAssertEqual(held.started, [.tunnelDNSHosts], "\(testCase.name): one job, no capture loop")
        }
    }

    @RuntimeActor
    private static func overrideProjection(
        _ service: FlightService,
        _ projection: @escaping @Sendable (ControlCollectionKind, ControlRowBudget) async -> ControlProjection
    ) {
        service.owner.projectionOverride = projection
    }

    private static func result(_ body: () async throws -> ControlPageReply) async -> Result<ControlPageReply, RuntimeClientError> {
        do {
            return .success(try await body())
        } catch let error as RuntimeClientError {
            return .failure(error)
        } catch {
            return .failure(.unexpectedReply)
        }
    }

    /// A total past the row bound is refused with that exact total before anything is frozen: the owner is never asked for a row source,
    /// and no flight starts.
    func testATotalPastTheRowBoundIsRefusedBeforeAnyFlight() async throws {
        let hosts = (1...17).map { "h\($0).example" }
        let service = try await Self.flightService(hosts: hosts)
        let reply = try await RuntimeActorFairnessTests.readPage(service)
        XCTAssertEqual(reply, .unavailable(.tunnelDNSHosts, .retentionBudgetExceeded, knownTotal: try ControlCount(17)))
        let asked = await Self.projectionCount(service)
        XCTAssertEqual(asked, 0, "no row source was frozen")
        XCTAssertEqual(service.held.started, [])
    }

    @RuntimeActor
    private static func projectionCount(_ service: FlightService) -> Int {
        service.owner.projectionCount
    }
}
