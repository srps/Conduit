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
    case queued(RuntimeOwnerWork)
    case running
}

/// What a queued operation hands to the owner at launch. A private editor update carries no value here: the owner holds its frozen input
/// under the operation's ID, in the composition's one admitted-input slot.
enum RuntimeOwnerWork: Sendable {
    case control(ControlRuntimeCommand)
    case privateUpdate
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

/// The answer to a snapshot read. The owner's state is captured in the read's own turn, so the answer is never older than the read.
enum RuntimeSnapshotRead {
    case snapshot(ControlRuntimeSnapshot)
    /// The owner's state could not be offered, so the read failed closed. Nothing stale is answered in its place.
    case internalFailure
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

/// The source of one page, read in one owner turn. `status` is `current`, or `staleRevision` when the rows are an older retained
/// revision, and `revision` names the revision that the rows belong to.
enum RuntimePageSource {
    case rows(revision: ControlCollectionRevision, rows: ControlProjectedRows, offset: Int, status: ControlPageStatus)
    /// A refusal with no rows. `knownTotal` is the exact total the refusal is about, or nil when no proof or snapshot states one.
    case unavailable(ControlCollectionUnavailableReason, knownTotal: ControlCount?)
    /// The request names another incarnation. Nothing was read.
    case changedIncarnation
    /// The cursor's offset is past the total its revision is known to have. It is an invalid request, decided before any capture.
    case invalidOffset
    /// The read failed internally. Nothing was stored, and the reply is a closed failure, not a refusal of the caller's request.
    case internalFailure
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
    /// The bounded proofs and retained rows of collections. Its eviction is best effort, and it reports each outcome in a page.
    private var collections: RuntimeCollectionLedger
    /// Every open subscriber, its cursors and its one parked wait. The table owns the subscriber limit.
    private var subscriptions: RuntimeSubscriptionTable
    /// The one latest safe snapshot, shared by every subscriber and read.
    private var snapshotSlot: RuntimeSnapshotSlot

    /// `positionSeed` starts the observation position counter, and `snapshotGenerationSeed` starts the snapshot generation counter.
    /// Both exist for tests of exhaustion.
    init(
        owner: any ControlCommandOwner,
        limits: RuntimeServiceLimits,
        timing: RuntimeServiceTiming,
        scheduling: any RuntimeOwnerScheduling,
        makeOperationID: @escaping @Sendable () -> ControlOperationID,
        encodeCommand: @escaping @Sendable (ControlRuntimeCommand) throws -> Data = { try RuntimeWireSize.encode($0) },
        measureOutcome: @escaping @Sendable (ControlOperationOutcome, ControlOperationID) throws -> RuntimeOutcomeSizes = RuntimeServiceCore.measureRetained,
        positionSeed: Int = 0,
        snapshotGenerationSeed: Int = 0
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
        self.collections = RuntimeCollectionLedger(limits: limits)
        self.subscriptions = RuntimeSubscriptionTable(limit: limits.subscriberLimit)
        self.snapshotSlot = RuntimeSnapshotSlot(
            incarnation: owner.incarnation,
            byteCapacity: limits.latestSnapshotByteCapacity,
            generationSeed: snapshotGenerationSeed
        )
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
            switch known.origin {
            case .ordinary(let recorded):
                return recorded == fingerprint ? known.admission : .rejected(.requestConflict)
            case .privateEditor:
                return .rejected(.requestReused)
            }
        }
        let partition = RuntimePartition.of(request.command)
        var stopModule: ControlModule?
        var ordinaryNext: Int?
        if case .stop(let module) = request.command {
            stopModule = module
        } else if partition != .quit {
            // The quit's partition holds at most the one quit the host's latch admits, so it never waits on ordinary capacity.
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
        switch owner.fence(request.command, request: request.requestID, operation: operation, candidate: candidate) {
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
            // A superseded candidate's fault is held until the replacement is installed, so the owner sees the new stop.
            var supersessionFault: ControlServiceFault?
            if let module = stopModule {
                if let candidate {
                    supersessionFault = settleLogically(candidate, .superseded(by: operation))
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
                physical: .queued(.control(request.command))
            )
            recordAlias(request, fingerprint: fingerprint, partition: partition, admission: .accepted(operation))
            switch partition {
            case .ordinary, .quit: scheduleOrdinaryLaunch(operation)
            case .stop(let module): scheduleStopLaunch(module)
            }
            sweepRetention()
            deliver(supersessionFault)
            return .accepted(operation)
        }
    }

    /// Admits one private editor update (decisions 0018 and 0035). Its request ID is lookup-only: any live alias, of either origin, refuses
    /// it as reused, and its alias keeps nothing derived from the body. It takes ordinary capacity, which orders it with the other ordinary
    /// work; its frozen values are bounded by the composition's one admitted-input slot, not by this capacity. `fence` is the owner's
    /// synchronous admission for the operation, in this turn, before any I/O.
    func submitPrivate(
        requestID: ControlRequestID,
        expectedIncarnation: ControlHostIncarnation,
        fence: (ControlOperationID) -> ControlOwnerFenceResult
    ) -> ControlAdmission {
        guard expectedIncarnation == incarnation else { return .rejected(.changedIncarnation) }
        let now = timing.now()
        if aliasTable.live(requestID, now: now) != nil { return .rejected(.requestReused) }
        // Once the quit reserved its flush, an update is admitted only as that flush, in the quit's partition; otherwise it takes ordinary
        // capacity, checked before the owner turn.
        let partition: RuntimePartition = owner.reservesQuitFlush ? .quit : .ordinary
        var next: Int?
        if partition == .ordinary {
            guard ordinaryUnquiesced < limits.ordinaryPendingCapacity, let successor = RuntimeCounter.successor(ordinaryUnquiesced) else {
                return .rejected(.queueFull)
            }
            next = successor
        }
        let operation = makeOperationID()
        let admission: ControlAdmission
        switch fence(operation) {
        case .rejected(let code):
            admission = .rejected(code)
        case .joinedCandidate:
            // An update has no candidate to join, so this is a fence defect.
            assertionFailure("the owner joined a private update")
            admission = .rejected(.internalFailure)
        case .admitted:
            if let next { ordinaryUnquiesced = next }
            operations[operation] = RuntimeOperationRecord(partition: partition, logical: .pending, physical: .queued(.privateUpdate))
            admission = .accepted(operation)
            scheduleOrdinaryLaunch(operation)
        }
        aliasTable.record(requestID, origin: .privateEditor, partition: partition, admission: admission, now: now)
        sweepRetention()
        return admission
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
        guard let snapshot = owner.snapshot() else { return nil }
        return snapshot.stamp.incarnation == incarnation ? snapshot : nil
    }

    // MARK: - Observation

    /// The owner reports that its safe state changed. It runs in the owner's turn. The state is captured once and offered to the slot,
    /// and each parked wait is woken after the slot is complete, when the slot replaced its snapshot or can no longer advance.
    func ownerDidChange() {
        captureOwnerState()
    }

    /// The owner's snapshot, captured and offered in this turn. A read answers with the slot after the offer, so it is never older
    /// than the owner's state at this turn. A refused offer is an internal failure, and nothing stale is answered in its place.
    func readSnapshot() -> RuntimeSnapshotRead {
        switch captureOwnerState() {
        case .unchanged, .replaced:
            break
        case .refused:
            return .internalFailure
        }
        guard let snapshot = snapshotSlot.latest else { return .internalFailure }
        return .snapshot(snapshot)
    }

    /// Opens one subscription in one owner turn. The owner's state is captured and offered first, so the baseline, the event high-water
    /// and the registration are one consistent state. Queued ingress is not flushed to make a baseline: it publishes in later bounded turns.
    func openSubscription(_ request: ControlSubscriptionRequest) -> RuntimeSubscribeResult {
        guard subscriptions.count < limits.subscriberLimit else { return .refused(.subscriberLimit) }
        if case .refused = captureOwnerState() {
            // The owner's state could not be offered, so a baseline would name a stale snapshot. The open fails closed.
            return .refused(.internalFailure)
        }
        guard let snapshot = snapshotSlot.latest,
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
        let cursor = RuntimeSubscriberCursor(
            nextEvent: plan.nextEvent,
            replayThrough: plan.replayThrough,
            nextControl: plan.nextControl,
            seenSnapshotGeneration: snapshotSlot.generation,
            lastWasSnapshot: false
        )
        switch subscriptions.open(cursor) {
        case .opened(let subscriber):
            return .opened(subscriber: subscriber, baseline: .baseline(baseline))
        case .full:
            return .refused(.subscriberLimit)
        case .exhausted:
            return .refused(.invalidValue)
        }
    }

    /// The frame a subscriber would receive next, and the cursor after it. Nothing is committed: the caller commits
    /// with `commitCursor` only when its gate wins. `nil` means the subscription was removed.
    ///
    /// Terminal and resync answers come first. A replay delivers its ordered frames before any snapshot. In live mode, a
    /// snapshot the subscriber has not seen competes with the ordered log frame: after a snapshot the next ordered frame goes
    /// first, so neither kind starves the other, and at most one snapshot sits between two ordered frames. A snapshot that
    /// does not fit the caller's frame ends the stream with a resync, which is explicit, and nothing is skipped silently.
    func peekFrame(
        _ subscriber: Int,
        fits: (ControlRuntimeFrame) -> Bool
    ) throws -> (pull: RuntimePull, after: RuntimeSubscriberCursor)? {
        guard let start = subscriptions.cursor(subscriber) else { return nil }
        if snapshotSlot.exhausted {
            return (.end(.resyncRequired), start)
        }
        let ordered = try observation.peek(start, fits: fits)
        if case .end = ordered.pull {
            return ordered
        }
        let snapshotWaiting = start.replayThrough == nil && start.seenSnapshotGeneration < snapshotSlot.generation
        if snapshotWaiting, let snapshot = snapshotSlot.latest {
            let snapshotFirst: Bool
            switch ordered.pull {
            case .idle: snapshotFirst = true
            case .frame: snapshotFirst = !start.lastWasSnapshot
            case .end: snapshotFirst = false
            }
            if snapshotFirst {
                guard fits(.snapshot(snapshot)) else {
                    return (.end(.resyncRequired), start)
                }
                var after = start
                after.seenSnapshotGeneration = snapshotSlot.generation
                after.lastWasSnapshot = true
                return (.frame(.snapshot(snapshot)), after)
            }
        }
        var after = ordered.after
        if case .frame = ordered.pull {
            after.lastWasSnapshot = false
        }
        return (ordered.pull, after)
    }

    /// Commits a cursor that a peek produced, once its frame has been delivered.
    func commitCursor(_ subscriber: Int, _ cursor: RuntimeSubscriberCursor) {
        subscriptions.commit(subscriber, cursor)
    }

    /// Parks the one wait a subscriber may hold. It returns false when that wait is taken or the subscriber is gone, and
    /// the caller reports a busy wait that consumed nothing.
    func parkWaiter(_ subscriber: Int, token: RuntimeWaiterToken, wake: @escaping @Sendable () -> Void) -> RuntimeParkResult {
        subscriptions.park(subscriber, RuntimeParkedWaiter(token: token, wake: wake))
    }

    /// Removes a parked registration if it is still the one named by `token`. A stale token changes nothing.
    func releaseWaiter(_ subscriber: Int, token: RuntimeWaiterToken) {
        subscriptions.release(subscriber, token: token)
    }

    /// Releases a subscription's slot exactly once. The record leaves the table in this turn. A parked wait is woken after the
    /// removal, so no wake runs inside the mutation. A second removal changes nothing.
    func removeSubscriber(_ subscriber: Int) {
        if case .removed(let waiter?) = subscriptions.remove(subscriber) {
            waiter.wake()
        }
    }

    // MARK: - Pages

    /// The source of one page, read in this owner turn. The ledger decides from the bounded proofs and the owner's current revision,
    /// and it never orders revisions. A current revision without retained rows is captured on demand. Each answer is closed:
    /// - the rows of an older retained revision, as stale with the current revision named;
    /// - `expiredRevision` with the proof's exact total, when the proof shows that the rows were evicted or aged out;
    /// - `notCaptured` with no total, when no proof is held, which covers a forgotten proof and a revision never captured;
    /// - `retentionBudgetExceeded` with the snapshot's exact total, when the current revision is over budget, whole and unstored;
    /// - `changedIncarnation` or `internalFailure`, for a request this host is not answering or a failed read.
    ///
    /// The retention is best effort. No lease is promised, so a retained revision can be evicted by a later capture.
    func pageSource(_ request: ControlPageRequest) -> RuntimePageSource {
        guard request.expectedIncarnation == incarnation else { return .changedIncarnation }
        // An owner that cannot project its state has reported why itself, so the read fails closed with no fault of the service's.
        guard let snapshot = owner.snapshot() else { return .internalFailure }
        guard snapshot.stamp.incarnation == incarnation else {
            // The owner's snapshot names another incarnation than this service. The owner broke its invariant, so nothing is read.
            deliver(.snapshotIncarnationMismatch)
            return .internalFailure
        }
        let kind = request.collection
        let reference = snapshot.collections.reference(for: kind)
        let offset = request.cursor.map { Int($0.offset.rawValue) } ?? 0
        switch reference.state {
        case .unavailable(let reason):
            // No revision is readable, so an offset cannot be checked against a total it belongs to. The refusal is the answer.
            return .unavailable(reason, knownTotal: reference.totalCount)
        case .available(let current):
            // A revision names one total for its whole life. A held proof of the current revision is compared with this turn's snapshot
            // before any decision, so an aged or released proof is checked too. A different exact total is the owner's broken invariant:
            // nothing is served, replaced or recaptured. A forgotten proof has no total to compare, so it is captured again.
            if let held = collections.proof(kind, revision: current)?.total, held.rawValue != reference.totalCount.rawValue {
                deliver(.revisionTotalChanged)
                return .internalFailure
            }
            switch collections.decision(kind: kind, cursor: request.cursor?.revision, current: current, at: timing.now()) {
            case .current(let rows, let total):
                guard offset <= total.rawValue else { return .invalidOffset }
                return .rows(revision: current, rows: rows, offset: offset, status: .current)
            case .stale(let revision, let rows):
                // A stale revision keeps the total it was captured with. It is never compared with the current total.
                guard offset <= rows.rowCount else { return .invalidOffset }
                return .rows(revision: revision, rows: rows, offset: offset, status: .staleRevision(current: current))
            case .expired(let total):
                return .unavailable(.expiredRevision, knownTotal: total)
            case .notCaptured:
                return .unavailable(.notCaptured, knownTotal: nil)
            case .needsCapture:
                // The current total is known from the snapshot, so an offset past it is refused before any capture or projection.
                guard offset <= reference.totalCount.rawValue else { return .invalidOffset }
                return captureCurrent(kind, revision: current, total: reference.totalCount, offset: offset)
            }
        }
    }

    /// Captures the current revision within the row and byte bounds, in this owner turn. The snapshot's exact total is checked first, so
    /// a total past the row bound is refused before the owner projects any row. The owner's rows must then match the kind and the total
    /// of the same turn. Capacity and owner-data refusals precede mutation; an internal ledger fault has no unchanged-state guarantee.
    private func captureCurrent(
        _ kind: ControlCollectionKind,
        revision: ControlCollectionRevision,
        total: ControlCount,
        offset: Int
    ) -> RuntimePageSource {
        guard total.rawValue <= limits.collectionRowCapacity else {
            return .unavailable(.retentionBudgetExceeded, knownTotal: total)
        }
        let budget = ControlRowBudget(maxRows: limits.collectionRowCapacity, maxBytes: limits.collectionByteCapacity)
        switch owner.projectedRows(for: kind, within: budget) {
        case .rows(let rows, let encodedBytes):
            switch collections.capture(kind, revision: revision, total: total, rows: rows, encodedBytes: encodedBytes, at: timing.now()) {
            case .stored:
                return .rows(revision: revision, rows: rows, offset: offset, status: .current)
            case .overBudget:
                return .unavailable(.retentionBudgetExceeded, knownTotal: total)
            case .countOrKindMismatch:
                // The owner's rows and the snapshot's exact count disagree within one turn. That is the owner's invariant, so nothing
                // is stored or served, and the fault is reported after this turn's state is complete.
                deliver(.projectionCountMismatch)
                return .internalFailure
            case .invariantFailure:
                // The ledger's own accounting is broken. It is the service's bug, not a capacity answer, so nothing is stored or served.
                deliver(.collectionAccountingMismatch)
                return .internalFailure
            }
        case .overBudget:
            return .unavailable(.retentionBudgetExceeded, knownTotal: total)
        case .internalFailure:
            deliver(.projectionNotEncodable)
            return .internalFailure
        }
    }

    // MARK: - Introspection for tests and the scenario

    var openSubscriberCount: Int { subscriptions.count }
    var parkedWaiterCount: Int { subscriptions.parkedCount }
    /// The snapshot slot's private generation, and whether it can no longer advance.
    var snapshotGeneration: Int { snapshotSlot.generation }
    var isSnapshotSlotExhausted: Bool { snapshotSlot.exhausted }
    /// The encoded bytes of the held snapshot, measured when it was offered.
    var retainedSnapshotBytes: Int { snapshotSlot.latestBytes }
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
    /// The collection ledger's held state for one kind: its proofs, the row sets still physically held, and the retained bytes of all kinds.
    func collectionRetention(_ kind: ControlCollectionKind) -> (proofs: Int, rowSets: Int, retainedBytes: Int) {
        (collections.proofCount(kind), collections.retainedRowSetCount(kind), collections.retainedRowBytes)
    }
    /// The exact total a held proof recorded for one revision, whether or not its rows are still held. Nil when no proof is held.
    func collectionProofTotal(_ kind: ControlCollectionKind, revision: ControlCollectionRevision) -> ControlCount? {
        collections.proof(kind, revision: revision)?.total
    }

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
        // A JSON string encodes to at least its UTF-8 bytes, so the event's own text is a lower bound on its encoded size. An event whose
        // text already exceeds the event bound is a loss, and it is refused before any encoding, so its text is never encoded in full.
        let size: Int?
        if let lowerBound = Self.textLowerBound(event), lowerBound <= limits.maxEventBytes {
            size = Self.encodedSize(record)
        } else {
            size = nil
        }
        if ingress.enqueue(record, bytes: size) {
            scheduling.hop { [weak self] in
                self?.drainTurn()
            }
        }
    }

    /// The UTF-8 bytes of the event's own text. It is nil when the sum does not fit an `Int`, which the caller treats as oversize.
    nonisolated static func textLowerBound(_ event: ControlRuntimeEvent) -> Int? {
        RuntimeCounter.advanced(event.kind.utf8.count, by: event.event.utf8.count)
            .flatMap { RuntimeCounter.advanced($0, by: event.detail?.utf8.count ?? 0) }
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
        /// The first control sequence the subscriber reads. A replay reads the outcomes whose boundary is in its range.
        let nextControl: Int
        let replayThrough: Int?
    }

    /// The baseline's replay answer and the subscriber's first positions. A cursor past the live edge is refused.
    /// An exhausted log answers unavailable, since no later position can be issued. A replay whose range may include an
    /// evicted outcome is unavailable as expired history, never a silent gap.
    private func replayPlan(for request: ControlSubscriptionRequest) -> ReplayPlan? {
        let live = observation.liveStart
        let liveControl = observation.controlNext
        if observation.exhausted {
            return ReplayPlan(availability: .unavailable(.observationLoss), nextEvent: live, nextControl: liveControl, replayThrough: nil)
        }
        switch request {
        case .live:
            return ReplayPlan(availability: .live, nextEvent: live, nextControl: liveControl, replayThrough: nil)
        case .resume(let resumeIncarnation, let from):
            guard resumeIncarnation == incarnation else {
                return ReplayPlan(availability: .unavailable(.changedIncarnation), nextEvent: live, nextControl: liveControl, replayThrough: nil)
            }
            // Zero is the bootstrap sentinel: it asks for everything retained, from position one.
            let first = max(from.rawValue, 1)
            guard first <= live else { return nil }
            if first == live {
                return ReplayPlan(availability: .live, nextEvent: live, nextControl: liveControl, replayThrough: nil)
            }
            if observation.crossesLoss(from: first) {
                return ReplayPlan(availability: .unavailable(.observationLoss), nextEvent: live, nextControl: liveControl, replayThrough: nil)
            }
            if first < observation.firstRetained {
                return ReplayPlan(availability: .unavailable(.expiredHistory), nextEvent: live, nextControl: liveControl, replayThrough: nil)
            }
            guard let control = observation.controlStart(forEvent: first) else {
                return ReplayPlan(availability: .unavailable(.expiredHistory), nextEvent: live, nextControl: liveControl, replayThrough: nil)
            }
            guard let fromCursor = ControlEventCursor(rawValue: first),
                  let throughCursor = ControlEventCursor(rawValue: observation.highWater)
            else { return nil }
            return ReplayPlan(
                availability: .replay(from: fromCursor, through: throughCursor),
                nextEvent: first,
                nextControl: control,
                replayThrough: observation.highWater
            )
        }
    }

    // MARK: - Operations

    /// Settles one operation's outcome logically, and publishes it. The first settlement counts. A settlement for an
    /// operation that is not pending, which includes one after supersession or after quiescence, changes nothing.
    ///
    /// It returns the fault staged for this settlement, if any, and does not deliver it. The caller delivers it with
    /// `deliver` only after its own transaction is complete: a supersession after the replacement is installed, and a
    /// quiescence after the capacity is returned. Otherwise the owner would read a state that is still being changed.
    @discardableResult
    private func settleLogically(_ operation: ControlOperationID, _ outcome: ControlOperationOutcome) -> ControlServiceFault? {
        guard var record = operations[operation], record.logical == .pending else { return nil }
        // The retained form is staged as pure data before any state changes. A fault it carries is returned, not called.
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
        return staged.fault
    }

    /// Delivers a staged fault to the owner. A caller invokes it last, after every state change of its transaction.
    private func deliver(_ fault: ControlServiceFault?) {
        if let fault {
            owner.serviceFault(fault)
        }
    }

    /// The owner reports that an operation's physical work has ended. The operation's record is then removed, and its
    /// capacity returns. A logically pending operation is closed first as an internal failure, so nothing pends after
    /// its work is gone. A duplicate, or a report for an unknown operation, changes nothing.
    private func quiesce(_ operation: ControlOperationID) {
        guard let record = operations[operation], record.isRunning else { return }
        var closingFault: ControlServiceFault?
        if record.logical == .pending {
            closingFault = settleLogically(operation, .failed(.internalFailure))
        }
        operations.removeValue(forKey: operation)
        var accountingFault: ControlServiceFault?
        switch record.partition {
        case .ordinary:
            if ordinaryUnquiesced > 0 {
                ordinaryUnquiesced -= 1
            } else {
                // Admission raises the count and only quiescence lowers it, so zero here is the service's own bug. Nothing goes below zero.
                assertionFailure("an ordinary quiescence found no unquiesced operation")
                accountingFault = .quiescenceAccountingMismatch
            }
        case .stop(let module):
            if stopSlots[module, default: RuntimeStopSlots()].active == operation {
                stopSlots[module, default: RuntimeStopSlots()].active = nil
                if stopSlots[module, default: RuntimeStopSlots()].queued != nil {
                    scheduleStopLaunch(module)
                }
            }
        case .quit:
            // The quit and its reserved flushes took no ordinary capacity, so none returns.
            break
        }
        sweepRetention()
        // The capacity is returned above, so the owner sees the operation closed and its slot free. Both faults wait for the whole transaction.
        deliver(closingFault)
        deliver(accountingFault)
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
        // Strong: an admitted operation owns its launch. A caller that drops its client after the admission must not leave the owner's
        // admitted work, and its pending count, stranded; the capacity bounds these hops.
        scheduling.hop { [self] in
            launchOrdinary(operation)
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
        // Strong, as an ordinary launch: a fenced Stop launches even when its caller has gone. At most one hop per module.
        scheduling.hop { [self] in
            launchStop(module)
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
        guard var record = operations[operation], case .queued(let work) = record.physical else { return }
        record.physical = .running
        operations[operation] = record
        let report = ControlEffectReport(
            settled: { [weak self] outcome in
                self?.deliver(self?.settleLogically(operation, outcome))
            },
            quiesced: { [weak self] in
                self?.quiesce(operation)
            }
        )
        switch work {
        case .control(let command): owner.startEffect(command, operation: operation, report: report)
        case .privateUpdate: owner.startPrivateEffect(operation: operation, report: report)
        }
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
            origin: .ordinary(fingerprint: fingerprint),
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
        collections.sweep(now: now, batch: limits.janitorBatch)
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
        // The waits are taken out of the table first, so each wake runs after the table is complete.
        for waiter in subscriptions.takeParkedWaiters() {
            waiter.wake()
        }
    }

    /// Captures the owner's snapshot once and offers it to the slot. A replacement, or an exhausted slot, wakes every parked wait,
    /// because each subscriber must now deliver or end. A refusal names the owner's broken invariant, and it is delivered as a closed
    /// fault only after the slot is complete. Nothing in the slot changes on a refusal.
    @discardableResult
    private func captureOwnerState() -> RuntimeSnapshotOffer {
        guard let snapshot = owner.snapshot() else {
            // The owner reported why it could not project, so nothing is offered, no fault is delivered back to it, and the slot keeps
            // its last value for the subscribers that already hold it. A read or an open answers this capture as an internal failure.
            return .refused(.notEncodable)
        }
        let offer = snapshotSlot.offer(snapshot, encodedBytes: Self.encodedSize(snapshot))
        switch offer {
        case .unchanged:
            break
        case .replaced:
            wakeWaiters()
        case .refused(let refusal):
            if refusal == .exhausted {
                wakeWaiters()
            } else {
                deliver(Self.fault(for: refusal))
            }
        }
        return offer
    }

    /// The closed fault a refused offer reports. The exhausted case is an ordinary terminal and reports no fault.
    private static func fault(for refusal: RuntimeSnapshotRefusal) -> ControlServiceFault? {
        switch refusal {
        case .incarnation: .snapshotIncarnationMismatch
        case .notEncodable: .snapshotNotEncodable
        case .overBound: .snapshotOverBound
        case .conflict: .snapshotRevisionConflict
        case .regressed: .snapshotRevisionRegressed
        case .exhausted: nil
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
