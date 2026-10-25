// SPDX-License-Identifier: Apache-2.0
import Foundation
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
        collectionRowAge: Duration = .seconds(60)
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
            stopLaneCapacityPerModule: 1,
            subscriberLimit: subscribers,
            ringCapacity: 16,
            ringByteCapacity: 1 << 16,
            maxEventBytes: 4096,
            ingressCapacity: 8,
            ingressByteCapacity: 1 << 15,
            drainItemsPerTurn: 4,
            drainBytesPerTurn: 1 << 14,
            controlLogCapacity: 8,
            controlLogByteCapacity: 1 << 14,
            replayChunkItems: 4,
            replayChunkBytes: 1 << 14,
            collectionRowCapacity: 16,
            collectionByteCapacity: collectionCaptureBytes,
            collectionProofCapacityPerKind: collectionProofs,
            collectionRowRevisionsPerKind: collectionRowSets,
            collectionRetainedByteCapacity: collectionRetainedBytes,
            collectionRowRetentionAge: collectionRowAge,
            retainedByteCeiling: retainedByteCeiling
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
    @MainActor
    static func lookup(_ core: RuntimeServiceCore, _ operation: ControlOperationID) -> ControlOperationLookup {
        core.operationLookup(ControlOperationQuery(
            expectedIncarnation: incarnation(1),
            operationID: operation
        ))
    }

    /// The admission lookup of one request under the fixture incarnation.
    @MainActor
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

    var pendingCount: Int {
        lock.withLock { queue.count }
    }

    func hop(_ work: @escaping RuntimeOwnerHop) {
        lock.withLock { queue.append(work) }
    }

    /// Runs the oldest queued hop. It returns false when none is queued.
    @discardableResult
    @MainActor
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
    @MainActor
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
@MainActor
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

    func snapshot() -> ControlRuntimeSnapshot {
        snapshotValue
    }

    /// Replaces the projection for one test, to reach a mismatch or a failure the production projection cannot produce.
    var projectionOverride: ((ControlCollectionKind, ControlRowBudget) -> ControlProjection)?

    /// The production bounded projection, over a kernel snapshot that holds this fake's hostnames. The fake adds no bound of its own.
    func projectedRows(for kind: ControlCollectionKind, within budget: ControlRowBudget) -> ControlProjection {
        projectionCount += 1
        if let projectionOverride {
            return projectionOverride(kind, budget)
        }
        return RuntimeSnapshotControlProjection.projectRows(
            kind,
            from: ProxyOrchestratorSnapshot(tunnelDNSOverrideStatus: .active(hostnames: dnsHostnames)),
            within: budget
        )
    }

    func fence(
        _ command: ControlRuntimeCommand,
        operation: ControlOperationID,
        candidate: ControlOperationID?
    ) -> ControlOwnerFenceResult {
        _ = operation
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
@MainActor
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
            positionSeed: positionSeed
        )
    }

    /// A transport over this harness's service, with the same clock and hops.
    func transport() -> RuntimeInMemoryTransport {
        RuntimeInMemoryTransport(core: core, limits: limits, timing: timing.timing, scheduling: scheduling)
    }
}

/// Waits, bounded, until an observable state holds. It yields between checks and returns false after `limit` checks, so a
/// test fails on the state it expected rather than on a timing guess. It never sleeps.
@MainActor
func awaitState(limit: Int = 10_000, _ condition: () -> Bool) async -> Bool {
    for _ in 0..<limit {
        if condition() {
            return true
        }
        await Task.yield()
    }
    return condition()
}

/// Runs one call that hops to the owner. It waits, bounded, until the call has queued its work, then runs the queued hops
/// and returns the call's value.
@MainActor
func runCall<T: Sendable>(
    _ scheduling: ManualOwnerScheduling,
    _ body: @escaping @Sendable () async throws -> T
) async throws -> T {
    let call = Task { try await body() }
    _ = await awaitState { scheduling.pendingCount > 0 }
    scheduling.drainAll()
    return try await call.value
}
