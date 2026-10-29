// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
@testable import ConduitRuntime
import ConduitShared
@testable import ProxyKernel
import ProxyControlBridge

/// Fixture values for the runtime-service suites. Every limit is a small fixture value, not product policy.
enum RuntimeServiceFixtures {
    static func uuid(_ value: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012X", value)) ?? UUID()
    }

    static func requestID(_ value: Int) -> ControlRequestID {
        ControlRequestID(rawValue: uuid(value))
    }

    static func incarnation(_ value: Int) -> ControlHostIncarnation {
        ControlHostIncarnation(rawValue: uuid(value))
    }

    static func operation(_ value: Int) -> ControlOperationID {
        ControlOperationID(rawValue: uuid(value))
    }

    /// Fixture bounds. The ceiling is an explicit fixture value, not a product choice, and every test that varies a bound
    /// passes its own.
    static func limits(
        aliases: Int = 8,
        ordinaryPending: Int = 2,
        subscribers: Int = 2,
        requestBytes: Int = 4096,
        replyBytes: Int = 64 * 1024,
        retainedByteCeiling: Int = 1 << 24,
        collectionCaptureBytes: Int = 1 << 14,
        collectionRetainedBytes: Int = 1 << 14,
        collectionProofs: Int = 4,
        collectionRowSets: Int = 2,
        collectionRowAge: Duration = .seconds(60),
        snapshotBytes: Int = 1 << 14,
        subscriberRecordBytes: Int = 256,
        ringCapacity: Int = 16,
        ringByteCapacity: Int = 1 << 16,
        ingressCapacity: Int = 8,
        ingressByteCapacity: Int = 1 << 15,
        drainItemsPerTurn: Int = 4,
        controlLogCapacity: Int = 8,
        controlLogByteCapacity: Int = 1 << 14,
        replayChunkItems: Int = 4,
        streamLanes: Int = 2
    ) throws -> RuntimeServiceLimits {
        try RuntimeServiceLimits(
            maxRequestBytes: requestBytes,
            maxReplyBytes: replyBytes,
            aliasCapacityPerPartition: aliases,
            aliasByteCapacityPerPartition: 1 << 20,
            ordinaryPendingCapacity: ordinaryPending,
            outcomeCapacity: 8,
            outcomeByteCapacity: 1 << 20,
            retentionAge: .seconds(60),
            janitorBatch: 4,
            ordinaryLaneCapacity: 2,
            readLaneCapacity: 2,
            streamLaneCapacity: streamLanes,
            stopLaneCapacityPerModule: 1,
            subscriberLimit: subscribers,
            ringCapacity: ringCapacity,
            ringByteCapacity: ringByteCapacity,
            maxEventBytes: 4096,
            ingressCapacity: ingressCapacity,
            ingressByteCapacity: ingressByteCapacity,
            drainItemsPerTurn: drainItemsPerTurn,
            drainBytesPerTurn: 1 << 14,
            controlLogCapacity: controlLogCapacity,
            controlLogByteCapacity: controlLogByteCapacity,
            replayChunkItems: replayChunkItems,
            replayChunkBytes: 1 << 14,
            collectionRowCapacity: 16,
            collectionByteCapacity: collectionCaptureBytes,
            collectionProofCapacityPerKind: collectionProofs,
            collectionRowRevisionsPerKind: collectionRowSets,
            collectionRetainedByteCapacity: collectionRetainedBytes,
            collectionRowRetentionAge: collectionRowAge,
            latestSnapshotByteCapacity: snapshotBytes,
            subscriberRecordBytes: subscriberRecordBytes,
            retainedByteCeiling: retainedByteCeiling
        )
    }

    /// Fixture bounds for a service composed over an actual host, whose own events reach the stream: the event ring and the ingress are
    /// sized for a Start's or a quit's burst of host events, so a subscriber reading an operation's settlement is not ended by an
    /// overflow. Still fixture values, not product policy; every other bound is the small fixture one.
    static func hostLimits(ordinaryPending: Int = 2, subscribers: Int = 2) throws -> RuntimeServiceLimits {
        try limits(
            ordinaryPending: ordinaryPending, subscribers: subscribers, ringCapacity: 256, ringByteCapacity: 1 << 18, ingressCapacity: 256,
            ingressByteCapacity: 1 << 18, drainItemsPerTurn: 32, replayChunkItems: 32
        )
    }

    /// A safe scalar snapshot from the projection, stamped with an incarnation.
    static func snapshot(
        incarnation value: Int,
        collections: ControlCollectionRevisions = ControlCollectionRevisions(),
        dnsStatus: TunnelDNSOverrideStatus = .notNeeded
    ) throws -> ControlRuntimeSnapshot {
        try RuntimeSnapshotControlProjection.snapshot(
            ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: dnsStatus),
            stamp: ControlRuntimeStamp(
                incarnation: incarnation(value),
                presentationRevision: ControlPresentationRevision(rawValue: 9) ?? ControlPresentationRevision(rawValue: 0)!,
                configRevision: ControlConfigRevision(rawValue: 2) ?? ControlConfigRevision(rawValue: 0)!,
                lifecycleRevision: ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!
            ),
            profileName: "Corp",
            collectionRevisions: collections
        )
    }

    static func budget() throws -> ControlWireBudget {
        try ControlWireBudget(1_000)
    }

    /// One submit request under the fixture incarnation, unless another is named.
    static func request(
        _ id: Int,
        _ command: ControlRuntimeCommand,
        in value: ControlHostIncarnation? = nil
    ) throws -> ControlOperationRequest {
        ControlOperationRequest(
            requestID: requestID(id),
            expectedIncarnation: value ?? incarnation(1),
            command: command
        )
    }

    /// The lookup of one operation under the fixture incarnation.
    @RuntimeActor
    static func lookup(_ core: RuntimeServiceCore, _ operation: ControlOperationID) -> ControlOperationLookup {
        core.operationLookup(ControlOperationQuery(
            expectedIncarnation: incarnation(1),
            operationID: operation
        ))
    }

    /// The admission lookup of one request under the fixture incarnation.
    @RuntimeActor
    static func lookupRequest(_ core: RuntimeServiceCore, _ id: Int) throws -> ControlRequestLookup {
        core.requestLookup(ControlRequestQuery(
            expectedIncarnation: incarnation(1),
            requestID: requestID(id)
        ))
    }
}

/// A manual monotonic clock and timer set. A timer is armed when its wait starts, and it ends only when the test fires it
/// or cancels it, so no test sleeps and every expiry is an explicit step. A cancelled timer's completion can be held, as a
/// real timer task's cleanup can lag its cancel, and it is released only by the test.
final class ManualRuntimeTiming: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    private var sleepers: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var heldCancellations: [CheckedContinuation<Void, any Error>] = []
    private var holdsCancelledCompletions = false

    var timing: RuntimeServiceTiming {
        RuntimeServiceTiming(
            now: { self.now },
            sleep: { instant in try await self.sleep(until: instant) }
        )
    }

    var now: ContinuousClock.Instant {
        lock.withLock { current }
    }

    /// The timers armed and not yet fired or cancelled.
    var armedTimerCount: Int {
        lock.withLock { sleepers.count }
    }

    /// The cancelled timers whose completion is held until `releaseHeldCancellations`.
    var heldCancellationCount: Int {
        lock.withLock { heldCancellations.count }
    }

    /// From now on, a cancelled timer's completion waits for `releaseHeldCancellations`.
    func holdCancelledCompletions() {
        lock.withLock { holdsCancelledCompletions = true }
    }

    func advance(by duration: Duration) {
        lock.withLock { current = current.advanced(by: duration) }
    }

    func sleep(until _: ContinuousClock.Instant) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                // The cancellation check and the registration are one locked step, so a cancel that lands between them is
                // never missed, and the continuation is always resumed exactly once.
                let cancelled = lock.withLock { () -> Bool in
                    if Task.isCancelled { return true }
                    sleepers[id] = continuation
                    return false
                }
                if cancelled {
                    continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let parked = self.lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                self.sleepers.removeValue(forKey: id)
            }
            guard let parked else { return }
            let held = self.lock.withLock { () -> Bool in
                guard self.holdsCancelledCompletions else { return false }
                self.heldCancellations.append(parked)
                return true
            }
            if !held {
                parked.resume(throwing: CancellationError())
            }
        }
    }

    /// Fires every armed timer. Each returns normally, as if its deadline had passed.
    func fireAll() {
        let parked = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = Array(sleepers.values)
            sleepers.removeAll()
            return all
        }
        for continuation in parked {
            continuation.resume()
        }
    }

    /// Completes every held cancellation, so each cancelled timer can end.
    func releaseHeldCancellations() {
        let held = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            let all = heldCancellations
            heldCancellations.removeAll()
            return all
        }
        for continuation in held {
            continuation.resume(throwing: CancellationError())
        }
    }
}

/// A finite, manual FIFO of owner hops. Nothing runs until a test runs it, so no test depends on task ordering.
/// `drainAll` stops after `limit` hops, so a self-rescheduling chain fails the test instead of spinning.
final class ManualOwnerScheduling: RuntimeOwnerScheduling, @unchecked Sendable {
    private let lock = NSLock()
    private var queue: [RuntimeOwnerHop] = []
    private var hopsQueued = 0
    /// The one driver suspended in `untilHopQueued`, if any.
    private var waitingDriver: CheckedContinuation<Void, Never>?

    var pendingCount: Int {
        lock.withLock { queue.count }
    }

    /// Every hop ever queued, including ones already run. A refusal that never hops leaves it at zero.
    var queuedHopCount: Int {
        lock.withLock { hopsQueued }
    }

    /// Whether a driver is suspended waiting for the next hop.
    var hasWaitingDriver: Bool {
        lock.withLock { waitingDriver != nil }
    }

    func hop(_ work: @escaping RuntimeOwnerHop) {
        let driver = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            hopsQueued += 1
            queue.append(work)
            defer { waitingDriver = nil }
            return waitingDriver
        }
        driver?.resume()
    }

    /// Lets a waiting driver look again without queuing a hop. The caller changes what the driver's `ended` reads first.
    func wakeDriver() {
        let driver = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { waitingDriver = nil }
            return waitingDriver
        }
        driver?.resume()
    }

    /// Suspends, on no thread, until a hop is queued or `ended` holds. Both are read in the same locked step that registers the wait,
    /// so a hop or a `wakeDriver` that lands in between is never missed. Nothing polls meanwhile, so the off-owner work that will queue
    /// the next hop has the pool. One driver waits at a time. `ended` runs under this queue's lock, so it must not read this queue.
    @RuntimeActor
    func untilHopQueued(or ended: () -> Bool) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let ready = lock.withLock { () -> Bool in
                if !queue.isEmpty || ended() { return true }
                precondition(waitingDriver == nil, "one driver waits for hops at a time")
                waitingDriver = continuation
                return false
            }
            if ready { continuation.resume() }
        }
    }

    /// Runs the oldest queued hop. It returns false when none is queued.
    @discardableResult
    @RuntimeActor
    func runNext() -> Bool {
        let next = lock.withLock { () -> RuntimeOwnerHop? in
            queue.isEmpty ? nil : queue.removeFirst()
        }
        guard let next else { return false }
        next()
        return true
    }

    /// Runs queued hops until none is left, or until `limit` have run. It returns how many ran.
    @discardableResult
    @RuntimeActor
    func drainAll(limit: Int = 10_000) -> Int {
        var ran = 0
        while ran < limit, runNext() {
            ran += 1
        }
        return ran
    }
}

/// A fake owner. It is the contract the service is proven against, not the actual host's fence. The owner keeps the
/// commands it fenced, and it resolves each launch's command from them, as the real owner will.
@RuntimeActor
final class FakeCommandOwner: ControlCommandOwner {
    let incarnation: ControlHostIncarnation
    /// The snapshot the owner reports. A test changes it, with the DNS hosts below, to move the owner to a new revision.
    var snapshotValue: ControlRuntimeSnapshot
    /// The hostnames the owner projects as tunnel DNS rows. They must match the snapshot's count in the same turn.
    var dnsHostnames: [String] = []
    /// How many captures the service asked the owner to project, so a test can see on-demand capture happen.
    private(set) var projectionCount = 0
    var answer: (ControlRuntimeCommand, ControlOperationID?) -> ControlOwnerFenceResult = { _, candidate in
        candidate == nil ? .admitted : .joinedCandidate
    }
    /// When true, an effect settles and quiesces inside its own launch.
    var completesSynchronously = false
    private(set) var fenceLog: [(command: ControlRuntimeCommand, candidate: ControlOperationID?)] = []
    private(set) var startedOperations: [ControlOperationID] = []
    /// The commands handed over at each launch, so a test can check the command that the owner was asked to run.
    private(set) var launchedCommands: [ControlRuntimeCommand] = []
    /// The closed faults the service reported, in order.
    private(set) var faults: [ControlServiceFault] = []
    /// Runs inside the fault callback, after the fault is recorded. A test reads the service here to check that the state is
    /// complete when the owner is called. It is a witness hook, not owner behaviour.
    var onFault: ((ControlServiceFault) -> Void)?

    func serviceFault(_ fault: ControlServiceFault) {
        faults.append(fault)
        onFault?(fault)
    }
    /// Every report the owner was given, kept so a test can deliver a late report after quiescence.
    private var reports: [ControlOperationID: ControlEffectReport] = [:]
    private var quiesced: Set<ControlOperationID> = []

    init(incarnation: ControlHostIncarnation, snapshot: ControlRuntimeSnapshot) {
        self.incarnation = incarnation
        self.snapshotValue = snapshot
    }

    func snapshot() -> ControlRuntimeSnapshot? {
        snapshotValue
    }

    /// Replaces the projection for one test, to reach a mismatch or a failure the production projection cannot produce, or to hold the
    /// capture flight's job where it suspends. It runs off the owner, as the job does.
    var projectionOverride: (@Sendable (ControlCollectionKind, ControlRowBudget) async -> ControlProjection)?
    /// Awaited off the owner by the default job before it projects its frozen value, so a test can hold the capture flight where it
    /// suspends, on no thread.
    var projectionGate: (@Sendable (ControlCollectionKind) async -> Void)?

    /// The production bounded projection, over a kernel snapshot that holds this fake's hostnames, frozen in the asking turn as the host
    /// freezes its own. The fake adds no bound of its own.
    func rowSource(for kind: ControlCollectionKind) -> RuntimeRowSource {
        projectionCount += 1
        if let projectionOverride {
            return { budget in await projectionOverride(kind, budget) }
        }
        let frozen = ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .active(hostnames: dnsHostnames))
        let gate = projectionGate
        return { budget in
            await gate?(kind)
            return RuntimeSnapshotControlProjection.projectRows(kind, from: frozen, within: budget)
        }
    }

    func fence(
        _ command: ControlRuntimeCommand,
        request: ControlRequestID,
        operation: ControlOperationID,
        candidate: ControlOperationID?
    ) -> ControlOwnerFenceResult {
        _ = (request, operation)
        fenceLog.append((command, candidate))
        return answer(command, candidate)
    }

    func startEffect(_ command: ControlRuntimeCommand, operation: ControlOperationID, report: ControlEffectReport) {
        startedOperations.append(operation)
        launchedCommands.append(command)
        reports[operation] = report
        if completesSynchronously {
            report.settled(.failed(.effectFailed))
            report.quiesced()
        }
    }

    /// The fake admits no private update, so the service never launches one on it.
    func startPrivateEffect(operation: ControlOperationID, report: ControlEffectReport) {
        startedOperations.append(operation)
        reports[operation] = report
    }

    /// Reports a logical settlement, the way the real owner does when its work decides an outcome.
    func settle(_ operation: ControlOperationID, with outcome: ControlOperationOutcome) {
        reports[operation]?.settled(outcome)
    }

    /// Reports that an operation's physical work has ended. The owner reports it once, and a repeat is a second report.
    func quiesce(_ operation: ControlOperationID) {
        quiesced.insert(operation)
        reports[operation]?.quiesced()
    }

    /// Launched effects whose quiescence the owner has not reported.
    var liveEffectCount: Int {
        startedOperations.filter { !quiesced.contains($0) }.count
    }
}

/// The production service, with its fake owner and the manual clock and hops, built once for a test.
@RuntimeActor
struct RuntimeServiceHarness {
    let limits: RuntimeServiceLimits
    let owner: FakeCommandOwner
    let core: RuntimeServiceCore
    let timing: ManualRuntimeTiming
    let scheduling: ManualOwnerScheduling

    init(
        aliases: Int = 8,
        ordinaryPending: Int = 2,
        subscribers: Int = 2,
        positionSeed: Int = 0,
        limits: RuntimeServiceLimits? = nil,
        snapshotGenerationSeed: Int = 0,
        encodeCommand: @escaping @Sendable (ControlRuntimeCommand) throws -> Data = { try RuntimeWireSize.encode($0) },
        measureOutcome: @escaping @Sendable (ControlOperationOutcome, ControlOperationID) throws -> RuntimeOutcomeSizes = RuntimeServiceCore.measureRetained
    ) throws {
        let resolved = try limits ?? RuntimeServiceFixtures.limits(
            aliases: aliases,
            ordinaryPending: ordinaryPending,
            subscribers: subscribers
        )
        self.limits = resolved
        owner = FakeCommandOwner(
            incarnation: RuntimeServiceFixtures.incarnation(1),
            snapshot: try RuntimeServiceFixtures.snapshot(incarnation: 1)
        )
        timing = ManualRuntimeTiming()
        scheduling = ManualOwnerScheduling()
        core = RuntimeServiceCore(
            owner: owner,
            limits: resolved,
            timing: timing.timing,
            scheduling: scheduling,
            makeOperationID: { ControlOperationID(rawValue: UUID()) },
            encodeCommand: encodeCommand,
            measureOutcome: measureOutcome,
            positionSeed: positionSeed,
            snapshotGenerationSeed: snapshotGenerationSeed
        )
    }

    /// A transport over this harness's service, with the same clock and hops.
    func transport() -> RuntimeInMemoryTransport {
        RuntimeInMemoryTransport(core: core, limits: limits, timing: timing.timing, scheduling: scheduling)
    }

    /// One page through the service alone, as its read-lane round reads it: a page waiting on the capture flight runs the flight's commit
    /// hop, which the job queues from off the owner, then reads again resuming its wait. Bounded: a page still waiting is returned as is.
    func page(_ request: ControlPageRequest) async -> RuntimePageSource {
        var source = core.pageSource(request)
        for _ in 0..<4 {
            guard case .awaitingCapture(let wait) = source else { break }
            _ = await awaitState { scheduling.pendingCount > 0 }
            scheduling.drainAll()
            source = core.pageSource(request, resuming: wait)
        }
        return source
    }
}

/// Waits, bounded, until an observable state holds. It yields between checks and returns false after `limit` checks, so a
/// test fails on the state it expected rather than on a timing guess. It never sleeps.
@RuntimeActor
func awaitState(limit: Int = 10_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<limit {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

/// A driven call still pending after its driver ran `hops` hops: a self-rescheduling chain fails the test instead of spinning.
struct ManualDriveExhausted: Error {
    let hops: Int
}

/// Starts one call on its own task. Its end is recorded, then a driver waiting in `untilHopQueued` is woken, so a call that ends
/// without queuing another hop is seen at once.
@RuntimeActor
private func startDrivenCall<T: Sendable>(
    _ scheduling: ManualOwnerScheduling,
    _ body: @escaping @Sendable () async throws -> T
) -> (call: Task<T, any Error>, ended: NIOLockedValueBox<Bool>) {
    let ended = NIOLockedValueBox(false)
    let call = Task { () async throws -> T in
        defer {
            ended.withLockedValue { $0 = true }
            scheduling.wakeDriver()
        }
        return try await body()
    }
    return (call, ended)
}

/// Runs one call that hops to the owner. It waits, on no thread, until the call has queued its work or ended, then runs the queued hops
/// and returns the call's value. It assumes an empty queue at the start and drains once: every hop the call needs is queued before it.
@RuntimeActor
func runCall<T: Sendable>(
    _ scheduling: ManualOwnerScheduling,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let (call, ended) = startDrivenCall(scheduling, body)
    await scheduling.untilHopQueued { ended.withLockedValue { $0 } }
    scheduling.drainAll()
    return try await call.value
}

/// `runCall` for a page that may wait on the capture flight: it keeps running the hops the call queues, the flight's commit hop from off the
/// owner and the woken round included, until the call has ended. Between hops it waits on no thread, so a hop that comes late is still run,
/// and the call's value is awaited only once the call has ended. Bounded by hops: a call still pending after `limit` of them is cancelled
/// and fails as `ManualDriveExhausted`. A cancelled driver cancels its call, which ends without a hop.
@RuntimeActor
func runDrainingCall<T: Sendable>(
    _ scheduling: ManualOwnerScheduling,
    limit: Int = 10_000,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let (call, ended) = startDrivenCall(scheduling, body)
    try await withTaskCancellationHandler {
        var ran = 0
        while true {
            await scheduling.untilHopQueued { ended.withLockedValue { $0 } }
            if ended.withLockedValue({ $0 }) { return }
            guard ran < limit else {
                call.cancel()
                throw ManualDriveExhausted(hops: ran)
            }
            ran += scheduling.drainAll(limit: limit - ran)
        }
    } onCancel: {
        call.cancel()
    }
    return try await call.value
}
