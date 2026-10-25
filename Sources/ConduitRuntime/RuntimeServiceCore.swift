// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// The logical state of one operation. `settled` is a marker only: the outcome itself lives in the bounded outcome table
/// and the control log, so no outcome is held twice.
private enum RuntimeLogicalState: Sendable, Equatable {
    case pending
    case settled
}

/// The physical state of one operation. A queued operation has not launched: it holds its command, which the service
/// hands to the owner at launch and then releases, or which it releases when the operation is dropped. A running operation
/// holds no command, and it holds its effect until the owner reports quiescence.
private enum RuntimePhysicalState {
    case queued(ControlRuntimeCommand)
    case running
}

/// One live operation, from admission until its physical effect has quiesced.
private struct RuntimeOperationRecord {
    let partition: RuntimePartition
    var logical: RuntimeLogicalState
    var physical: RuntimePhysicalState

    var isQueued: Bool {
        if case .queued = physical { return true }
        return false
    }

    var isRunning: Bool {
        if case .running = physical { return true }
        return false
    }
}

/// A stop module's slots: at most one running effect and one queued launch. `launchQueued` dedupes the launch hop.
private struct RuntimeStopSlots {
    var active: ControlOperationID?
    var queued: ControlOperationID?
    var launchQueued = false
}

/// A settled outcome kept for lookup, aged from its settlement.
private struct RuntimeOutcomeEntry {
    let outcome: ControlOperationOutcome
    let bytes: Int
    let finishedAt: ContinuousClock.Instant
}

/// A collection's captured rows for one revision. Only the newest revision of each kind is retained.
private struct RuntimeCollectionCapture {
    let revision: ControlCollectionRevision
    let rows: ControlProjectedRows
}

/// The one parked wait a subscriber may hold. Its token names the registration exactly, so a stale cleanup cannot remove a newer one.
private struct RuntimeParkedWaiter {
    let token: RuntimeWaiterToken
    let wake: @Sendable () -> Void
}

/// The identity of one parked registration. Tokens are unique, so no counter can wrap or collide.
struct RuntimeWaiterToken: Hashable, Sendable {
    let id: UUID

    init() {
        id = UUID()
    }
}

/// The answer to a park. `subscriberGone` means the subscription left the service, which is a disconnect, and
/// `alreadyParked` means another wait holds the one slot, which is a busy wait that consumed nothing.
enum RuntimeParkResult: Sendable, Equatable {
    case parked
    case subscriberGone
    case alreadyParked
}

/// The answer to a subscription open. A refusal is a wire failure, and the stream carries it as its first frame.
enum RuntimeSubscribeResult {
    case opened(subscriber: Int, baseline: ControlRuntimeFrame)
    case refused(ControlRuntimeErrorCode)
}

extension ControlRuntimeCollections {
    /// The reference the snapshot holds for one kind.
    func reference(for kind: ControlCollectionKind) -> ControlCollectionReference {
        switch kind {
        case .activeConnections: activeConnections
        case .upstreamHealth: upstreamHealth
        case .tunnelBindings: tunnelBindings
        case .tunnelDNSHosts: tunnelDNSHosts
        }
    }
}

/// The source of one page, read in one owner turn.
enum RuntimePageSource {
    case rows(revision: ControlCollectionRevision, rows: ControlProjectedRows, offset: Int)
    case unavailable(ControlCollectionUnavailableReason)
}

/// The runtime service facade. It composes three owned parts and holds the observation state directly:
///
/// - `aliasTable` (`RuntimeAliasTable`): request aliases, retention policy only.
/// - the operation table: one record per operation until its physical effect quiesces, the stop slots, and the
///   logical pending candidate of each module. Its bookkeeping is in this file, behind `submit`, `launch`, `quiesce` and
///   `dropQueuedStop`.
/// - the observation log, subscribers, parked waits and collection captures.
///
/// Every method runs in the owner's turn on the main actor, so one turn sees one consistent state. The owner keeps the
/// single authority over intent and lifecycle, and it decides every Stop, including a coalescing one. The service never
/// decides what a command does.
@MainActor
final class RuntimeServiceCore {
    private let owner: any ControlCommandOwner
    private let limits: RuntimeServiceLimits
    private let timing: RuntimeServiceTiming
    private let scheduling: any RuntimeOwnerScheduling
    private let makeOperationID: @Sendable () -> ControlOperationID
    /// The encoder for a command's fingerprint and size. It is the codec in production, and a test substitutes a refusal.
    private let encodeCommand: @Sendable (ControlRuntimeCommand) throws -> Data
    /// The measure of an outcome and its control-log entry. It is the codec in production. A test substitutes a refusal to
    /// exercise the outcome fault, which is the only way that fault can be reached, because the current codec encodes every outcome.
    private let measureOutcome: @Sendable (ControlOperationOutcome, ControlOperationID) throws -> RuntimeOutcomeSizes
    let incarnation: ControlHostIncarnation
    /// The leaf ingress. Producers on any thread reach it through `ingest`, which is nonisolated.
    nonisolated let ingress: RuntimeIngress

    private var aliasTable: RuntimeAliasTable
    private var operations: [ControlOperationID: RuntimeOperationRecord] = [:]
    private var stopSlots: [ControlModule: RuntimeStopSlots] = [:]
    /// The logically pending stop of each module. The owner decides a join or a supersession against it.
    private var candidates: [ControlModule: ControlOperationID] = [:]
    /// Ordinary operations admitted and not yet quiesced. Their capacity returns only at quiescence, not at settlement.
    private var ordinaryUnquiesced = 0
    private var outcomes: [ControlOperationID: RuntimeOutcomeEntry] = [:]
    private var outcomeOrder: [ControlOperationID] = []
    private var outcomeBytes = 0
    private var observation: RuntimeObservationLog
    private var captures: [ControlCollectionKind: RuntimeCollectionCapture] = [:]
    private var subscribers: [Int: RuntimeSubscriberCursor] = [:]
    private var waiters: [Int: RuntimeParkedWaiter] = [:]
    private var nextSubscriber = 1

    /// `positionSeed` starts the observation position counter, for tests of exhaustion.
    init(
        owner: any ControlCommandOwner,
        limits: RuntimeServiceLimits,
        timing: RuntimeServiceTiming,
        scheduling: any RuntimeOwnerScheduling,
        makeOperationID: @escaping @Sendable () -> ControlOperationID,
        encodeCommand: @escaping @Sendable (ControlRuntimeCommand) throws -> Data = { try RuntimeWireSize.encode($0) },
        measureOutcome: @escaping @Sendable (ControlOperationOutcome, ControlOperationID) throws -> RuntimeOutcomeSizes = RuntimeServiceCore.measureRetained,
        positionSeed: Int = 0
    ) {
        self.encodeCommand = encodeCommand
        self.measureOutcome = measureOutcome
        self.owner = owner
        self.limits = limits
        self.timing = timing
        self.scheduling = scheduling
        self.makeOperationID = makeOperationID
        self.incarnation = owner.incarnation
        self.ingress = RuntimeIngress(limits: limits)
        self.observation = RuntimeObservationLog(limits: limits, positionSeed: positionSeed)
        self.aliasTable = RuntimeAliasTable(limits: limits)
    }

    // MARK: - Admission

    /// Admits one command. A recorded request recovers its admission when the fingerprint matches, and conflicts when it
    /// differs. A recovered request is never fenced again. Every other request reaches the owner's synchronous fence, a
    /// stop included, and no fence is ever blocked by alias room or by ordinary capacity.
    func submit(_ request: ControlOperationRequest) -> ControlAdmission {
        guard request.expectedIncarnation == incarnation else { return .rejected(.changedIncarnation) }
        let encoded: Data
        do {
            encoded = try encodeCommand(request.command)
        } catch {
            // The failure site is reported as a closed fault, so a release build keeps where it happened. Nothing was recorded or
            // fenced, and the command body is never part of the report.
            owner.serviceFault(.submitCommandNotEncodable)
            return .rejected(.internalFailure)
        }
        guard encoded.count <= limits.maxRequestBytes else { return .rejected(.commandTooLarge) }
        let fingerprint = RuntimeAliasTable.fingerprint(of: encoded)
        if let known = aliasTable.live(request.requestID, now: timing.now()) {
            return known.fingerprint == fingerprint ? known.admission : .rejected(.requestConflict)
        }
        let partition = RuntimePartition.of(request.command)
        var stopModule: ControlModule?
        var ordinaryNext: Int?
        if case .stop(let module) = request.command {
            stopModule = module
        } else {
            // The ordinary capacity is checked before any owner turn, so a refusal changes nothing and is not recorded.
            guard ordinaryUnquiesced < limits.ordinaryPendingCapacity,
                  let next = RuntimeCounter.successor(ordinaryUnquiesced)
            else {
                return .rejected(.queueFull)
            }
            ordinaryNext = next
        }
        let operation = makeOperationID()
        let candidate = stopModule.flatMap { candidates[$0] }
        switch owner.fence(request.command, operation: operation, candidate: candidate) {
        case .rejected(let code):
            recordAlias(request, fingerprint: fingerprint, partition: partition, admission: .rejected(code))
            return .rejected(code)
        case .joinedCandidate:
            guard let candidate else {
                // The owner joins only to a candidate the service offered, so this is a fence defect.
                assertionFailure("the owner joined a stop with no candidate")
                recordAlias(request, fingerprint: fingerprint, partition: partition, admission: .rejected(.notImplemented))
                return .rejected(.notImplemented)
            }
            recordAlias(request, fingerprint: fingerprint, partition: partition, admission: .joined(candidate))
            return .joined(candidate)
        case .admitted:
            if let module = stopModule {
                if let candidate {
                    settleLogically(candidate, .superseded(by: operation))
                }
                dropQueuedStop(module)
                stopSlots[module, default: RuntimeStopSlots()].queued = operation
                candidates[module] = operation
            } else if let ordinaryNext {
                ordinaryUnquiesced = ordinaryNext
            }
            operations[operation] = RuntimeOperationRecord(
                partition: partition,
                logical: .pending,
                physical: .queued(request.command)
            )
            recordAlias(request, fingerprint: fingerprint, partition: partition, admission: .accepted(operation))
            switch partition {
            case .ordinary: scheduleOrdinaryLaunch(operation)
            case .stop(let module): scheduleStopLaunch(module)
            }
            sweepRetention()
            return .accepted(operation)
        }
    }

    /// Reads the admission recorded for one request in this incarnation. An expired alias is removed and reported as not
    /// recorded. Aliases age from admission, independently of the operation they name.
    func requestLookup(_ query: ControlRequestQuery) -> ControlRequestLookup {
        guard query.expectedIncarnation == incarnation else { return .unknown(.changedIncarnation) }
        guard let alias = aliasTable.live(query.requestID, now: timing.now()) else { return .unknown(.notRecorded) }
        return .admission(alias.admission)
    }

    /// Reads one operation's state. A pending operation is never aged, and it stays pending until its outcome is settled,
    /// even when its request alias is gone. A settled outcome past its age is removed and reported as not recorded.
    func operationLookup(_ query: ControlOperationQuery) -> ControlOperationLookup {
        guard query.expectedIncarnation == incarnation else { return .unknown(.changedIncarnation) }
        if operations[query.operationID]?.logical == .pending { return .pending }
        guard let entry = outcomes[query.operationID] else { return .unknown(.notRecorded) }
        if timing.now() - entry.finishedAt >= limits.retentionAge {
            removeOutcome(query.operationID)
            return .unknown(.notRecorded)
        }
        return .finished(entry.outcome)
    }

    /// The owner's safe snapshot, when it belongs to this incarnation.
    func currentSnapshot() -> ControlRuntimeSnapshot? {
        let snapshot = owner.snapshot()
        return snapshot.stamp.incarnation == incarnation ? snapshot : nil
    }

    // MARK: - Observation

    /// Opens one subscription in one owner turn. The baseline captures the published high-water and the subscriber is
    /// registered in the same turn. Queued ingress is not flushed to make a baseline: it publishes in later bounded turns.
    func openSubscription(_ request: ControlSubscriptionRequest) -> RuntimeSubscribeResult {
        guard subscribers.count < limits.subscriberLimit else { return .refused(.subscriberLimit) }
        guard let following = RuntimeCounter.successor(nextSubscriber) else { return .refused(.invalidValue) }
        guard let snapshot = currentSnapshot(),
              let plan = replayPlan(for: request),
              let highWater = ControlEventCursor(rawValue: observation.highWater)
        else {
            return .refused(.invalidValue)
        }
        let baseline: ControlBaseline
        do {
            baseline = try ControlBaseline(
                incarnation: incarnation,
                snapshot: snapshot,
                highWater: highWater,
                replay: plan.availability
            )
        } catch {
            return .refused(.invalidValue)
        }
        let subscriber = nextSubscriber
        nextSubscriber = following
        subscribers[subscriber] = RuntimeSubscriberCursor(
            nextEvent: plan.nextEvent,
            replayThrough: plan.replayThrough,
            nextControl: observation.controlNext
        )
        return .opened(subscriber: subscriber, baseline: .baseline(baseline))
    }

    /// The frame a subscriber would receive next, and the cursor after it. Nothing is committed: the caller commits
    /// with `commitCursor` only when its gate wins. `nil` means the subscription was removed.
    func peekFrame(
        _ subscriber: Int,
        fits: (ControlRuntimeFrame) -> Bool
    ) throws -> (pull: RuntimePull, after: RuntimeSubscriberCursor)? {
        guard let cursor = subscribers[subscriber] else { return nil }
        return try observation.peek(cursor, fits: fits)
    }

    /// Commits a cursor that a peek produced, once its frame has been delivered.
    func commitCursor(_ subscriber: Int, _ cursor: RuntimeSubscriberCursor) {
        if subscribers[subscriber] != nil {
            subscribers[subscriber] = cursor
        }
    }

    /// Parks the one wait a subscriber may hold. It returns false when that wait is taken or the subscriber is gone, and
    /// the caller reports a busy wait that consumed nothing.
    func parkWaiter(_ subscriber: Int, token: RuntimeWaiterToken, wake: @escaping @Sendable () -> Void) -> RuntimeParkResult {
        guard subscribers[subscriber] != nil else { return .subscriberGone }
        guard waiters[subscriber] == nil else { return .alreadyParked }
        waiters[subscriber] = RuntimeParkedWaiter(token: token, wake: wake)
        return .parked
    }

    /// Removes a parked registration if it is still the one named by `token`. A stale token changes nothing.
    func releaseWaiter(_ subscriber: Int, token: RuntimeWaiterToken) {
        guard waiters[subscriber]?.token == token else { return }
        waiters.removeValue(forKey: subscriber)
    }

    /// Releases a subscription's slot. The slot returns in this turn, and a parked wait is woken.
    func removeSubscriber(_ subscriber: Int) {
        subscribers.removeValue(forKey: subscriber)
        if let waiter = waiters.removeValue(forKey: subscriber) {
            waiter.wake()
        }
    }

    // MARK: - Pages

    /// The source of one page, read in this owner turn. It is nil when the request names another incarnation.
    /// The newest revision of each kind is captured on first read, within the row and byte bounds. An over-budget
    /// capture is refused as unavailable, never truncated. A cursor from an older revision is expired.
    func pageSource(_ request: ControlPageRequest) -> RuntimePageSource? {
        guard request.expectedIncarnation == incarnation, let snapshot = currentSnapshot() else { return nil }
        let kind = request.collection
        switch snapshot.collections.reference(for: kind).state {

        case .unavailable(let reason):
            return .unavailable(reason)
        case .available(let current):
            if captures[kind]?.revision != current {
                let rows = owner.projectedRows(for: kind)
                guard rows.kind == kind, let bounded = boundedRows(rows) else {
                    return .unavailable(.retentionBudgetExceeded)
                }
                captures[kind] = RuntimeCollectionCapture(revision: current, rows: bounded)
            }
            if let cursor = request.cursor, cursor.revision != current {
                return .unavailable(.expiredRevision)
            }
            guard let capture = captures[kind] else { return .unavailable(.notCaptured) }
            let offset = request.cursor.map { Int($0.offset.rawValue) } ?? 0
            return .rows(revision: current, rows: capture.rows, offset: offset)
        }
    }

    /// The rows, when they fit the row count and the encoded byte bound. Every row is measured, so the bound is exact.
    private func boundedRows(_ rows: ControlProjectedRows) -> ControlProjectedRows? {
        switch rows {
        case .activeConnections(let list): boundedBytes(list) == nil ? nil : rows
        case .upstreamHealth(let list): boundedBytes(list) == nil ? nil : rows
        case .tunnelBindings(let list): boundedBytes(list) == nil ? nil : rows
        case .tunnelDNSHosts(let list): boundedBytes(list) == nil ? nil : rows
        }
    }

    private func boundedBytes<Row: Encodable>(_ list: [Row]) -> Int? {
        guard list.count <= limits.collectionRowCapacity else { return nil }
        var total = 0
        for row in list {
            guard let size = Self.encodedSize(row), size <= limits.collectionByteCapacity - total else { return nil }
            total += size
        }
        return total
    }

    // MARK: - Introspection for tests and the scenario

    var openSubscriberCount: Int { subscribers.count }
    var parkedWaiterCount: Int { waiters.count }
    /// Operations whose outcome is not yet settled.
    var pendingOperationCount: Int { operations.values.filter { $0.logical == .pending }.count }
    /// Operations whose physical effect has not yet quiesced, settled or not.
    var liveOperationCount: Int { operations.count }
    var runningOperationCount: Int { operations.values.filter(\.isRunning).count }
    var ordinaryUnquiescedCount: Int { ordinaryUnquiesced }
    var aliasCount: Int { aliasTable.count }
    /// The bytes every partition's aliases charge together.
    var aliasBytesTotal: Int { aliasTable.bytesTotal }
    var outcomeCount: Int { outcomes.count }
    var observedHighWater: Int { observation.highWater }
    var observedFirstRetained: Int { observation.firstRetained }
    var controlFloor: Int { observation.controlFloor }
    var isObservationExhausted: Bool { observation.exhausted }

    /// Whether a module's stop slots hold an active effect, and whether one is queued behind it.
    func stopSlotState(_ module: ControlModule) -> (active: Bool, queued: Bool) {
        let slots = stopSlots[module, default: RuntimeStopSlots()]
        return (slots.active != nil, slots.queued != nil)
    }

    // MARK: - Ingress

    /// Accepts one event from any thread. It is a bounded leaf enqueue, so it neither waits for the owner nor allocates
    /// per event. An event that cannot be encoded or is too large becomes a loss marker.
    nonisolated func ingest(_ event: ControlRuntimeEvent) {
        let record = ControlRuntimeEventRecord.known(event)
        if ingress.enqueue(record, bytes: Self.encodedSize(record)) {
            scheduling.hop { [weak self] in
                self?.drainTurn()
            }
        }
    }

    /// One bounded drain turn. It publishes at most the configured items and bytes, and it queues the next turn when the
    /// queue still has items.
    private func drainTurn() {
        let (batch, more) = ingress.take(
            maxItems: limits.drainItemsPerTurn,
            maxBytes: limits.drainBytesPerTurn
        )
        observation.apply(batch)
        wakeWaiters()
        if more {
            scheduling.hop { [weak self] in
                self?.drainTurn()
            }
        }
    }

    // MARK: - Internals

    private struct ReplayPlan {
        let availability: ControlReplayAvailability
        let nextEvent: Int
        let replayThrough: Int?
    }

    /// The baseline's replay answer and the subscriber's first position. A cursor past the live edge is refused.
    /// An exhausted log answers unavailable, since no later position can be issued.
    private func replayPlan(for request: ControlSubscriptionRequest) -> ReplayPlan? {
        let live = observation.liveStart
        if observation.exhausted {
            return ReplayPlan(availability: .unavailable(.observationLoss), nextEvent: live, replayThrough: nil)
        }
        switch request {
        case .live:
            return ReplayPlan(availability: .live, nextEvent: live, replayThrough: nil)
        case .resume(let resumeIncarnation, let from):
            guard resumeIncarnation == incarnation else {
                return ReplayPlan(availability: .unavailable(.changedIncarnation), nextEvent: live, replayThrough: nil)
            }
            // Zero is the bootstrap sentinel: it asks for everything retained, from position one.
            let first = max(from.rawValue, 1)
            guard first <= live else { return nil }
            if first == live {
                return ReplayPlan(availability: .live, nextEvent: live, replayThrough: nil)
            }
            if observation.crossesLoss(from: first) {
                return ReplayPlan(availability: .unavailable(.observationLoss), nextEvent: live, replayThrough: nil)
            }
            if first < observation.firstRetained {
                return ReplayPlan(availability: .unavailable(.expiredHistory), nextEvent: live, replayThrough: nil)
            }
            guard let fromCursor = ControlEventCursor(rawValue: first),
                  let throughCursor = ControlEventCursor(rawValue: observation.highWater)
            else { return nil }
            return ReplayPlan(
                availability: .replay(from: fromCursor, through: throughCursor),
                nextEvent: first,
                replayThrough: observation.highWater
            )
        }
    }

    // MARK: - Operations

    /// Settles one operation's outcome logically, and publishes it. The first settlement counts. A settlement for an
    /// operation that is not pending, which includes one after supersession or after quiescence, changes nothing.
    @discardableResult
    private func settleLogically(_ operation: ControlOperationID, _ outcome: ControlOperationOutcome) -> Bool {
        guard var record = operations[operation], record.logical == .pending else { return false }
        // The retained form is staged as pure data before any state changes. A fault it carries is delivered last.
        let staged = stageRetained(outcome: outcome, operation: operation)
        record.logical = .settled
        operations[operation] = record
        if let module = record.partition.stopModule, candidates[module] == operation {
            candidates.removeValue(forKey: module)
        }
        storeOutcome(operation, staged.outcome, bytes: staged.bytes)
        observation.appendControl(staged.finished, bytes: staged.finishedBytes)
        wakeWaiters()
        sweepRetention()
        // The owner is called only after the settlement is complete: the outcome is retained, the control entry is appended, the
        // operation is settled and the candidate is cleared. So a fault callback that reads the service sees one coherent state.
        if let fault = staged.fault {
            owner.serviceFault(fault)
        }
        return true
    }

    /// The owner reports that an operation's physical work has ended. The operation's record is then removed, and its
    /// capacity returns. A logically pending operation is closed first as an internal failure, so nothing pends after
    /// its work is gone. A duplicate, or a report for an unknown operation, changes nothing.
    private func quiesce(_ operation: ControlOperationID) {
        guard let record = operations[operation], record.isRunning else { return }
        if record.logical == .pending {
            settleLogically(operation, .failed(.internalFailure))
        }
        operations.removeValue(forKey: operation)
        switch record.partition {
        case .ordinary:
            if ordinaryUnquiesced > 0 {
                ordinaryUnquiesced -= 1
            }
        case .stop(let module):
            if stopSlots[module, default: RuntimeStopSlots()].active == operation {
                stopSlots[module, default: RuntimeStopSlots()].active = nil
                if stopSlots[module, default: RuntimeStopSlots()].queued != nil {
                    scheduleStopLaunch(module)
                }
            }
        }
        sweepRetention()
    }

    /// Drops the module's queued stop, if any. It has not launched, so no effect is ever started for it. Its command is
    /// released with its operation record, and nothing is orphaned.
    private func dropQueuedStop(_ module: ControlModule) {
        guard let queued = stopSlots[module, default: RuntimeStopSlots()].queued else { return }
        stopSlots[module, default: RuntimeStopSlots()].queued = nil
        if operations[queued]?.isQueued == true {
            operations.removeValue(forKey: queued)
        }
    }

    /// Queues one ordinary launch hop. The operation's capacity is already held, so the hop count stays within it.
    private func scheduleOrdinaryLaunch(_ operation: ControlOperationID) {
        scheduling.hop { [weak self] in
            self?.launchOrdinary(operation)
        }
    }

    private func launchOrdinary(_ operation: ControlOperationID) {
        guard operations[operation]?.isQueued == true else { return }
        launch(operation)
    }

    /// Queues one stop launch hop for a module, at most one at a time. The hop launches whichever operation is queued when
    /// it runs, so a superseded launch is never started.
    private func scheduleStopLaunch(_ module: ControlModule) {
        guard stopSlots[module, default: RuntimeStopSlots()].launchQueued == false else { return }
        stopSlots[module, default: RuntimeStopSlots()].launchQueued = true
        scheduling.hop { [weak self] in
            self?.launchStop(module)
        }
    }

    private func launchStop(_ module: ControlModule) {
        stopSlots[module, default: RuntimeStopSlots()].launchQueued = false
        let slots = stopSlots[module, default: RuntimeStopSlots()]
        guard slots.active == nil, let operation = slots.queued else { return }
        stopSlots[module, default: RuntimeStopSlots()].queued = nil
        stopSlots[module, default: RuntimeStopSlots()].active = operation
        launch(operation)
    }

    /// Hands a queued operation's command to the owner, and marks the operation running. The running state is final before
    /// the owner is called, so a report that arrives synchronously finds it. The command is released by that same step.
    private func launch(_ operation: ControlOperationID) {
        guard var record = operations[operation], case .queued(let command) = record.physical else { return }
        record.physical = .running
        operations[operation] = record
        let report = ControlEffectReport(
            settled: { [weak self] outcome in
                _ = self?.settleLogically(operation, outcome)
            },
            quiesced: { [weak self] in
                self?.quiesce(operation)
            }
        )
        owner.startEffect(command, operation: operation, report: report)
    }

    // MARK: - Aliases

    /// Records one alias. It always succeeds, because the alias table evicts within its partition and never pins an operation.
    private func recordAlias(
        _ request: ControlOperationRequest,
        fingerprint: Data,
        partition: RuntimePartition,
        admission: ControlAdmission
    ) {
        aliasTable.record(
            request.requestID,
            fingerprint: fingerprint,
            partition: partition,
            admission: admission,
            now: timing.now()
        )
    }

    // MARK: - Retention

    /// The bounded janitor. It runs the alias table's sweep and removes at most `janitorBatch` expired outcomes per turn.
    /// Both are prefixes in time order, so the sweep never scans past the first live record, and it never schedules a task.
    private func sweepRetention() {
        let now = timing.now()
        aliasTable.sweep(now: now, batch: limits.janitorBatch)
        var removed = 0
        while removed < limits.janitorBatch,
              let oldest = outcomeOrder.first,
              let entry = outcomes[oldest],
              now - entry.finishedAt >= limits.retentionAge {
            removeOutcome(oldest)
            removed += 1
        }
    }

    private func storeOutcome(_ operation: ControlOperationID, _ outcome: ControlOperationOutcome, bytes: Int) {
        // An outcome larger than the byte bound is not retained for lookup. Its live delivery still goes through the
        // control log, and a lookup then answers not recorded, which is honest.
        guard bytes <= limits.outcomeByteCapacity else { return }
        while !outcomeOrder.isEmpty,
              outcomeOrder.count >= limits.outcomeCapacity || outcomeBytes > limits.outcomeByteCapacity - bytes {
            removeOutcome(outcomeOrder[0])
        }
        outcomes[operation] = RuntimeOutcomeEntry(outcome: outcome, bytes: bytes, finishedAt: timing.now())
        outcomeOrder.append(operation)
        outcomeBytes += bytes
    }

    private func removeOutcome(_ operation: ControlOperationID) {
        guard let entry = outcomes.removeValue(forKey: operation) else { return }
        outcomeBytes -= entry.bytes
        if let index = outcomeOrder.firstIndex(of: operation) {
            outcomeOrder.remove(at: index)
        }
    }

    private func wakeWaiters() {
        guard !waiters.isEmpty else { return }
        let parked = waiters.values
        waiters.removeAll()
        for waiter in parked {
            waiter.wake()
        }
    }

    /// The retained form of one outcome, staged as data. It touches no state and calls no owner, so the settlement can
    /// finish its whole transaction before any fault is delivered.
    private struct StagedRetained {
        let outcome: ControlOperationOutcome
        let bytes: Int
        let finished: ControlOperationFinished
        let finishedBytes: Int
        /// The closed fault for a measure that failed. The retained form is then the measured internal failure.
        let fault: ControlServiceFault?
    }

    /// The outcome as retained, with its sizes. A measure that fails is staged as `outcomeNotEncodable`, and the measured
    /// internal failure stands in for it. Those replacement sizes were measured when the limits were built, so nothing is guessed.
    private func stageRetained(outcome: ControlOperationOutcome, operation: ControlOperationID) -> StagedRetained {
        do {
            let sizes = try measureOutcome(outcome, operation)
            return StagedRetained(
                outcome: outcome,
                bytes: sizes.outcome,
                finished: ControlOperationFinished(operationID: operation, outcome: outcome),
                finishedBytes: sizes.finished,
                fault: nil
            )
        } catch {
            // The failure is reported as its closed case. The error text is not kept, so nothing the service holds can leak.
            let failed = ControlOperationOutcome.failed(.internalFailure)
            return StagedRetained(
                outcome: failed,
                bytes: limits.internalFailureOutcomeBytes,
                finished: ControlOperationFinished(operationID: operation, outcome: failed),
                finishedBytes: limits.internalFailureFinishedBytes,
                fault: .outcomeNotEncodable
            )
        }
    }

    /// The default measure: the encoded size of the outcome, and of its control-log entry as the codec writes it.
    nonisolated static func measureRetained(
        _ outcome: ControlOperationOutcome,
        _ operation: ControlOperationID
    ) throws -> RuntimeOutcomeSizes {
        RuntimeOutcomeSizes(
            outcome: try RuntimeWireSize.bytes(of: outcome),
            finished: try RuntimeWireSize.bytes(of: ControlOperationFinished(operationID: operation, outcome: outcome))
        )
    }

    /// The encoded size of a value, which is what the byte bounds count. Nil when the value cannot be encoded. Each caller
    /// turns nil into a typed outcome: a refusal, a loss, a resync, or unavailable. It is never added to a total.
    nonisolated static func encodedSize<Value: Encodable>(_ value: Value) -> Int? {
        try? RuntimeWireSize.bytes(of: value)
    }
}

/// The encoded sizes of one retained outcome: the outcome alone, and its control-log entry.
struct RuntimeOutcomeSizes: Sendable, Equatable {
    let outcome: Int
    let finished: Int
}
