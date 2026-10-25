// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import CryptoKit
import Foundation

/// Checked counter steps. A counter that cannot advance returns nil, and its owner marks the structure exhausted.
/// Nothing in the service wraps, saturates into a sentinel, or traps on a counter.
enum RuntimeCounter {
    static func successor(_ value: Int) -> Int? {
        value < Int.max ? value + 1 : nil
    }

    static func advanced(_ value: Int, by count: Int) -> Int? {
        let (sum, overflow) = value.addingReportingOverflow(count)
        return overflow ? nil : sum
    }
}

/// The encoded form of a value as the wire codec writes it. It throws when the value cannot be encoded, so the caller
/// makes a typed refusal and never adds a fallback size to a total.
enum RuntimeWireSize {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try ControlRuntimeCodec.makeEncoder().encode(value)
    }

    static func bytes<Value: Encodable>(of value: Value) throws -> Int {
        try encode(value).count
    }
}

/// Every bound the runtime service enforces. Each value is explicit and checked when the limits are built. There are no
/// shipping defaults here: the fixture values in tests are not policy, and the owner passes the retained-byte ceiling
/// explicitly.
///
/// `maxRequestBytes` and `maxReplyBytes` are the server's own frame caps. A caller's limits can only narrow them: the
/// transport decodes and encodes under the minimum of the server cap and the caller's cap, so no per-call value widens the
/// service.
///
/// Every retained structure has a count bound and an encoded-byte bound. A byte bound is at least the measured worst
/// record it holds, so one record always fits. `retainedByteBudget` is the checked sum of every encoded-byte term the
/// configuration can hold at once: the alias partitions, the operation table, the outcome table, the ring, the control
/// log, the ingress, the collections, and the transport's in-flight reservations and subscriber first frames. It counts
/// encoded payload bytes only. It excludes object overhead, the caller's own request buffer and process memory. It must
/// not exceed `retainedByteCeiling`, which the owner passes explicitly, so an over-large configuration is refused at
/// construction.
struct RuntimeServiceLimits: Sendable, Equatable {
    /// The server's ingress cap for one request frame, applied before any parsing.
    let maxRequestBytes: Int
    /// The server's cap for one reply or stream frame.
    let maxReplyBytes: Int
    /// Measured worst encodings of one admission and of one request ID, and the fixed size of a command fingerprint.
    let admissionWorstBytes: Int
    let requestIDWorstBytes: Int
    let fingerprintBytes: Int
    /// One alias record, charged at its worst: an identifier, an admission and a command fingerprint.
    let aliasRecordWorstBytes: Int
    /// The measured sizes of the replacement an unencodable outcome becomes: the internal failure, as an outcome and as
    /// its control-log entry. They are measured here, so a replacement is never retained at a guessed size.
    let internalFailureOutcomeBytes: Int
    let internalFailureFinishedBytes: Int
    /// Request aliases per partition (ordinary, and one per stop module), by count and encoded bytes. Aliases are
    /// evictable and never pin an operation, and admission never waits for alias room.
    let aliasCapacityPerPartition: Int
    let aliasByteCapacityPerPartition: Int
    /// Ordinary operations admitted and not yet quiesced. A stop module has its own two slots, one active and one queued.
    let ordinaryPendingCapacity: Int
    /// The operation table's bound, derived: the ordinary capacity plus two slots per stop module.
    let operationCapacity: Int
    /// One operation record holds an identifier and small enums. A queued operation also holds its command, at most
    /// `maxRequestBytes`, until it launches.
    let operationRecordBytes: Int
    let outcomeCapacity: Int
    let outcomeByteCapacity: Int
    /// How long a retained alias or outcome lasts, measured on the injected monotonic clock.
    let retentionAge: Duration
    /// Retained records one janitor turn may remove.
    let janitorBatch: Int
    /// Transport reservations in flight per lane: ordinary commands, reads, and each module's stop.
    let ordinaryLaneCapacity: Int
    let readLaneCapacity: Int
    let stopLaneCapacityPerModule: Int
    /// Concurrently open subscriptions.
    let subscriberLimit: Int
    /// The total in-flight reservations across every lane, derived and checked.
    let laneCount: Int
    /// The event ring: retained positions, and encoded bytes across the events it holds.
    let ringCapacity: Int
    let ringByteCapacity: Int
    /// The largest encoded event any stage accepts. A larger event is recorded as an observation loss.
    let maxEventBytes: Int
    /// The leaf ingress: queued items, and encoded bytes across the queued events.
    let ingressCapacity: Int
    let ingressByteCapacity: Int
    /// The work one drain turn may do: items (a loss marker counts as one) and encoded event bytes.
    let drainItemsPerTurn: Int
    let drainBytesPerTurn: Int
    /// The control log of finished operations: retained entries and their encoded bytes.
    let controlLogCapacity: Int
    let controlLogByteCapacity: Int
    /// The events one replay frame may carry, by count and by encoded bytes. The frame limit still applies on top.
    let replayChunkItems: Int
    let replayChunkBytes: Int
    /// The rows one collection capture may hold, and their encoded bytes. Each kind keeps only its newest capture.
    let collectionRowCapacity: Int
    let collectionByteCapacity: Int
    /// Each in-flight reservation holds two request-sized values and two reply-sized values, so one reservation is bounded by
    /// `2 × maxRequestBytes + 2 × maxReplyBytes`. The request-sized values are the caller's request frame and the decoded message
    /// that the wait's round reads. Both are live across the await, because the frame is the transport's parameter for the whole
    /// exchange and the message is captured by the round. The reply-sized values are the typed refusal, which is kept until
    /// resolution, and the one answer produced at the peak. The total is `laneCount` of those. Sizes are encoded payload bytes,
    /// so the decoded message is counted at its encoded size, and this is not a claim about in-memory size.
    let laneRetainedBytes: Int
    /// Each open subscriber holds one buffered first frame, bounded by `maxReplyBytes`.
    let firstFrameRetainedBytes: Int
    /// The checked sum of every encoded-byte term above that the configuration can hold at once.
    let retainedByteBudget: Int
    /// The ceiling the owner passes. The budget must not exceed it, and the owner, not the service, chooses it.
    let retainedByteCeiling: Int

    /// One active and one queued operation per stop module.
    static let stopSlotsPerModule = 2

    init(
        maxRequestBytes: Int,
        maxReplyBytes: Int,
        aliasCapacityPerPartition: Int,
        aliasByteCapacityPerPartition: Int,
        ordinaryPendingCapacity: Int,
        outcomeCapacity: Int,
        outcomeByteCapacity: Int,
        retentionAge: Duration,
        janitorBatch: Int,
        ordinaryLaneCapacity: Int,
        readLaneCapacity: Int,
        stopLaneCapacityPerModule: Int,
        subscriberLimit: Int,
        ringCapacity: Int,
        ringByteCapacity: Int,
        maxEventBytes: Int,
        ingressCapacity: Int,
        ingressByteCapacity: Int,
        drainItemsPerTurn: Int,
        drainBytesPerTurn: Int,
        controlLogCapacity: Int,
        controlLogByteCapacity: Int,
        replayChunkItems: Int,
        replayChunkBytes: Int,
        collectionRowCapacity: Int,
        collectionByteCapacity: Int,
        retainedByteCeiling: Int
    ) throws {
        let counts = [
            aliasCapacityPerPartition, aliasByteCapacityPerPartition, ordinaryPendingCapacity,
            outcomeCapacity, outcomeByteCapacity, janitorBatch, ordinaryLaneCapacity, readLaneCapacity,
            stopLaneCapacityPerModule, subscriberLimit, ringCapacity, ringByteCapacity, maxEventBytes,
            ingressCapacity, ingressByteCapacity, drainItemsPerTurn, drainBytesPerTurn, controlLogCapacity,
            controlLogByteCapacity, replayChunkItems, replayChunkBytes, collectionRowCapacity, collectionByteCapacity,
            retainedByteCeiling,
        ]
        // A frame needs at least one payload byte and its line feed, the smallest frame that can exist.
        guard counts.allSatisfy({ $0 >= 1 }), retentionAge > .zero,
              maxRequestBytes >= 2, maxReplyBytes >= 2
        else {
            throw ControlRuntimeWireError.invalidValue
        }
        // One event must fit every byte bound that carries events, so each turn, each queue and each frame makes progress.
        guard replayChunkBytes >= maxEventBytes, ringByteCapacity >= maxEventBytes,
              drainBytesPerTurn >= maxEventBytes, ingressByteCapacity >= maxEventBytes,
              controlLogByteCapacity >= 1
        else {
            throw ControlRuntimeWireError.invalidValue
        }
        let admissionWorst = try Self.worstAdmissionBytes()
        let requestIDWorst = try Self.worstRequestIDBytes()
        let operationRecord = try Self.worstOperationIDBytes()
        let failedOutcome = ControlOperationOutcome.failed(.internalFailure)
        let failedOutcomeBytes = try RuntimeWireSize.bytes(of: failedOutcome)
        let failedFinishedBytes = try RuntimeWireSize.bytes(
            of: ControlOperationFinished(operationID: ControlOperationID(rawValue: UUID()), outcome: failedOutcome)
        )
        let fingerprint = SHA256.Digest.byteCount
        // One alias record is an identifier, an admission and a command fingerprint. A partition must hold one.
        guard let worstAlias = Self.checkedSum([requestIDWorst, admissionWorst, fingerprint]),
              aliasByteCapacityPerPartition >= worstAlias
        else {
            throw ControlRuntimeWireError.invalidValue
        }
        // A reply must carry one maximal event in one frame: its own encoded record, plus the frame's envelope and line feed.
        // The envelope is measured with the largest cursor the log can issue, so the bound is conservative.
        let eventFrameOverhead = try Self.measuredEventFrameOverhead()
        guard let oneEventFrame = Self.checkedSum([maxEventBytes, eventFrameOverhead]), maxReplyBytes >= oneEventFrame else {
            throw ControlRuntimeWireError.invalidValue
        }
        let modules = ControlModule.allCases.count
        let partitions = modules + 1
        let collectionKinds = ControlCollectionKind.allCases.count
        guard let operations = Self.checkedSum([ordinaryPendingCapacity, Self.stopSlotsPerModule * modules]),
              let aliasTotal = Self.checkedProduct(partitions, aliasByteCapacityPerPartition),
              let perOperation = Self.checkedSum([operationRecord, maxRequestBytes]),
              let operationBytes = Self.checkedProduct(operations, perOperation),
              let collectionTotal = Self.checkedProduct(collectionKinds, collectionByteCapacity),
              let stopLaneTotal = Self.checkedProduct(stopLaneCapacityPerModule, modules),
              let laneCount = Self.checkedSum([ordinaryLaneCapacity, readLaneCapacity, stopLaneTotal]),
              // Two request-sized and two reply-sized values per reservation: the request frame and the decoded message, the refusal
              // and one produced answer. See `laneRetainedBytes`.
              let perReservation = Self.checkedSum([maxRequestBytes, maxRequestBytes, maxReplyBytes, maxReplyBytes]),
              let laneBytes = Self.checkedProduct(laneCount, perReservation),
              let firstFrameBytes = Self.checkedProduct(subscriberLimit, maxReplyBytes),
              let budget = Self.checkedSum([
                  aliasTotal, operationBytes, outcomeByteCapacity, ringByteCapacity,
                  controlLogByteCapacity, ingressByteCapacity, collectionTotal, laneBytes, firstFrameBytes,
              ]),
              budget <= retainedByteCeiling
        else {
            throw ControlRuntimeWireError.invalidValue
        }
        self.maxRequestBytes = maxRequestBytes
        self.maxReplyBytes = maxReplyBytes
        self.admissionWorstBytes = admissionWorst
        self.requestIDWorstBytes = requestIDWorst
        self.fingerprintBytes = fingerprint
        self.aliasRecordWorstBytes = worstAlias
        self.internalFailureOutcomeBytes = failedOutcomeBytes
        self.internalFailureFinishedBytes = failedFinishedBytes
        self.aliasCapacityPerPartition = aliasCapacityPerPartition
        self.aliasByteCapacityPerPartition = aliasByteCapacityPerPartition
        self.ordinaryPendingCapacity = ordinaryPendingCapacity
        self.operationCapacity = operations
        self.operationRecordBytes = operationRecord
        self.outcomeCapacity = outcomeCapacity
        self.outcomeByteCapacity = outcomeByteCapacity
        self.retentionAge = retentionAge
        self.janitorBatch = janitorBatch
        self.ordinaryLaneCapacity = ordinaryLaneCapacity
        self.readLaneCapacity = readLaneCapacity
        self.stopLaneCapacityPerModule = stopLaneCapacityPerModule
        self.subscriberLimit = subscriberLimit
        self.laneCount = laneCount
        self.ringCapacity = ringCapacity
        self.ringByteCapacity = ringByteCapacity
        self.maxEventBytes = maxEventBytes
        self.ingressCapacity = ingressCapacity
        self.ingressByteCapacity = ingressByteCapacity
        self.drainItemsPerTurn = drainItemsPerTurn
        self.drainBytesPerTurn = drainBytesPerTurn
        self.controlLogCapacity = controlLogCapacity
        self.controlLogByteCapacity = controlLogByteCapacity
        self.replayChunkItems = replayChunkItems
        self.replayChunkBytes = replayChunkBytes
        self.collectionRowCapacity = collectionRowCapacity
        self.collectionByteCapacity = collectionByteCapacity
        self.laneRetainedBytes = laneBytes
        self.firstFrameRetainedBytes = firstFrameBytes
        self.retainedByteBudget = budget
        self.retainedByteCeiling = retainedByteCeiling
    }

    /// The largest encoded admission. Every admission value is measured, so the bound comes from the codec, not a guess.
    private static func worstAdmissionBytes() throws -> Int {
        let operation = ControlOperationID(rawValue: UUID())
        let admissions = [ControlAdmission.accepted(operation), .joined(operation)]
            + ControlRejectionCode.allCases.map { ControlAdmission.rejected($0) }
        var worst = 0
        for admission in admissions {
            worst = max(worst, try RuntimeWireSize.bytes(of: admission))
        }
        return worst
    }

    /// Every request ID encodes to the same length, so one measured value is the bound.
    private static func worstRequestIDBytes() throws -> Int {
        try RuntimeWireSize.bytes(of: ControlRequestID(rawValue: UUID()))
    }

    /// Every operation ID encodes to the same length, so one measured value is the bound of an operation record's identifier.
    private static func worstOperationIDBytes() throws -> Int {
        try RuntimeWireSize.bytes(of: ControlOperationID(rawValue: UUID()))
    }

    /// The bytes one event adds around its own encoded record in a frame: the envelope, the batch and the line feed. The record
    /// is counted at its own size, so this is only the wrapping, measured with the largest cursor the log can issue.
    private static func measuredEventFrameOverhead() throws -> Int {
        let sample = ControlRuntimeEventRecord.known(
            ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 0), kind: "k", event: "e")
        )
        guard let cursor = ControlEventCursor(rawValue: RuntimeObservationLog.maximumPosition) else {
            throw ControlRuntimeWireError.invalidValue
        }
        let batch = try ControlEventBatch(firstCursor: cursor, events: [sample])
        let message = ControlRuntimeMessage(correlation: ControlRequestID(rawValue: UUID()), body: .frame(.events(batch)))
        let frame = try ControlRuntimeCodec.encodeFrame(message, limits: try ControlFrameLimits(maxFrameBytes: 1 << 20))
        let record = try RuntimeWireSize.bytes(of: sample)
        guard frame.count >= record else { throw ControlRuntimeWireError.invalidValue }
        return frame.count - record
    }

    static func checkedSum(_ values: [Int]) -> Int? {
        var total = 0
        for value in values {
            guard let next = RuntimeCounter.advanced(total, by: value) else { return nil }
            total = next
        }
        return total
    }

    static func checkedProduct(_ lhs: Int, _ rhs: Int) -> Int? {
        let (product, overflow) = lhs.multipliedReportingOverflow(by: rhs)
        return overflow ? nil : product
    }
}

/// The clock and the timer the service and its transport read. Both members are injected, so tests drive time without
/// sleeping. Owner hops are a separate seam, `RuntimeOwnerScheduling`.
struct RuntimeServiceTiming: Sendable {
    /// The current monotonic instant. A deadline is compared against it at claim time as well as by the timer.
    let now: @Sendable () -> ContinuousClock.Instant
    /// Suspends until `instant`. It throws `CancellationError` when the task is cancelled.
    let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void

    static let system = RuntimeServiceTiming(
        now: { ContinuousClock.now },
        sleep: { instant in try await Task.sleep(until: instant, clock: .continuous) }
    )
}
