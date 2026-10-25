// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// One retained position of the event ring. A gap reserves a position and carries no event, so a
/// replay that reaches it ends with a resync and never fabricates a wire event.
enum RuntimeRingEntry {
    case event(ControlRuntimeEventRecord, bytes: Int)
    case gap
}

/// A finished operation kept in the control log. Its boundary is the last event position issued before it.
struct RuntimeControlEntry {
    let finished: ControlOperationFinished
    let boundary: Int
    let bytes: Int
}

/// One subscriber's cursor. It is a fixed-size value: it holds positions and generations, not queued frames.
struct RuntimeSubscriberCursor: Sendable, Equatable {
    /// The next event position to deliver.
    var nextEvent: Int
    /// The last replay position, or nil once the subscriber is live.
    var replayThrough: Int?
    /// The next control-log sequence number to deliver.
    var nextControl: Int
    /// The private delivery generation of the snapshot this subscriber has seen. It is not the owner's revision.
    var seenSnapshotGeneration: Int
    /// Whether the last frame delivered was a snapshot. The next ordered log frame then goes first, so snapshots and log frames alternate.
    var lastWasSnapshot: Bool
}

/// The result of one pull for one subscriber.
enum RuntimePull: Equatable {
    case frame(ControlRuntimeFrame)
    /// Nothing is ready. The caller parks a wait and is woken when the owner turn publishes more.
    case idle
    case end(ControlStreamEndReason)
}

/// The bounded published observation state: the event ring with explicit gaps, and the ordered control log.
/// It is a plain value that only the service's owner turn touches, so it takes no lock.
///
/// Positions are event cursors. The first issued position is one, and zero means nothing was issued. A gap
/// consumes a position without a wire event. An operation outcome consumes no position: it sits in the control
/// log with the position it followed.
///
/// Every counter is checked. Positions and control sequences stop at `maximumPosition`, one below `Int.max`, so every
/// next-position a reader computes stays representable. A log that cannot advance is `exhausted`: every subscriber
/// resyncs, and nothing is wrapped or saturated.
struct RuntimeObservationLog {
    /// The largest position, and the largest control sequence, the log issues.
    static let maximumPosition = Int.max - 1

    let ringCapacity: Int
    let ringByteCapacity: Int
    let controlCapacity: Int
    let controlByteCapacity: Int
    let replayChunkItems: Int
    let replayChunkBytes: Int

    /// The last published position. Zero means nothing has been issued.
    private(set) var highWater = 0
    /// The oldest retained position. Positions start at one.
    private(set) var firstRetained = 1
    /// The highest gap position ever issued. A replay that starts at or below it crossed a loss.
    private(set) var lastGap = 0
    /// The boundary of the newest control outcome that was evicted or skipped, or nil when none was. Boundaries never decrease in sequence
    /// order, so this is the highest lost boundary. A replay from `first` may have lost an outcome exactly when this is at or after `first`.
    /// It is one value, so it stays fixed however many outcomes are lost.
    private(set) var lastLostBoundary: Int?
    /// Set once a checked counter cannot advance. No later event or outcome can be recorded.
    private(set) var exhausted = false
    private var ring: [RuntimeRingEntry] = []
    private var ringBytes = 0
    private var control: [RuntimeControlEntry] = []
    private var controlBytes = 0
    /// The sequence number of `control[0]`. Sequence numbers start at one.
    private(set) var controlFloor = 1

    /// `positionSeed` starts the position counter at a given point. It exists for tests of exhaustion, and it is clamped
    /// into `0...maximumPosition`.
    init(limits: RuntimeServiceLimits, positionSeed: Int = 0) {
        ringCapacity = limits.ringCapacity
        ringByteCapacity = limits.ringByteCapacity
        controlCapacity = limits.controlLogCapacity
        controlByteCapacity = limits.controlLogByteCapacity
        replayChunkItems = limits.replayChunkItems
        replayChunkBytes = limits.replayChunkBytes
        highWater = min(max(positionSeed, 0), Self.maximumPosition)
        firstRetained = highWater + 1
    }

    /// The sequence number the next operation outcome receives. Retained entries and the floor never pass `maximumPosition`.
    var controlNext: Int {
        RuntimeCounter.advanced(controlFloor, by: control.count) ?? Self.maximumPosition
    }

    /// The first position a live subscriber reads. `highWater` never exceeds `maximumPosition`, so this cannot overflow.
    var liveStart: Int {
        highWater + 1
    }

    /// Whether replay from `position` crosses a loss marker.
    func crossesLoss(from position: Int) -> Bool {
        lastGap >= position
    }

    /// The ring entry at a retained position, or nil outside the retained range.
    func entry(at position: Int) -> RuntimeRingEntry? {
        guard position >= firstRetained, position <= highWater else { return nil }
        return ring[position - firstRetained]
    }

    /// The control entry with a sequence number, or nil outside the retained range.
    func controlEntry(atSequence sequence: Int) -> RuntimeControlEntry? {
        guard sequence >= controlFloor, sequence < controlNext else { return nil }
        return control[sequence - controlFloor]
    }

    /// The first control sequence a replay that starts at event position `first` reads. It is the first retained outcome whose boundary
    /// is at or after `first`, or the next sequence when none is. An outcome before that boundary is not part of the replay. Nil means an
    /// evicted or skipped outcome may have been in the replay range: its boundary is at or after `first`. The caller then refuses the
    /// replay explicitly, because a silent gap is not allowed.
    func controlStart(forEvent first: Int) -> Int? {
        if let lost = lastLostBoundary, lost >= first {
            return nil
        }
        var sequence = controlFloor
        while sequence < controlNext {
            if let entry = controlEntry(atSequence: sequence), entry.boundary >= first {
                return sequence
            }
            sequence += 1
        }
        return controlNext
    }

    // MARK: - Publication

    /// Applies one drained batch in order. A loss marker publishes a gap; an event publishes its position.
    mutating func apply(_ batch: [RuntimeIngressItem]) {
        for item in batch {
            switch item {
            case .loss:
                appendGap()
            case .event(let record, let bytes):
                appendEvent(record, bytes: bytes)
            }
        }
    }

    private mutating func appendEvent(_ record: ControlRuntimeEventRecord, bytes: Int) {
        guard advancePosition() else { return }
        makeRingRoom(for: bytes)
        ring.append(.event(record, bytes: bytes))
        ringBytes += bytes
    }

    private mutating func appendGap() {
        guard advancePosition() else { return }
        makeRingRoom(for: 0)
        ring.append(.gap)
        lastGap = highWater
    }

    /// Issues the next position with a checked counter. It returns false, and marks the log exhausted, when the position
    /// cannot advance.
    private mutating func advancePosition() -> Bool {
        guard highWater < Self.maximumPosition, let next = RuntimeCounter.successor(highWater) else {
            exhausted = true
            return false
        }
        highWater = next
        return true
    }

    /// Evicts the oldest positions until one more entry of `bytes` fits both bounds. Eviction runs before the
    /// append, so the byte total never passes its cap, and the newest position always fits.
    private mutating func makeRingRoom(for bytes: Int) {
        while !ring.isEmpty, ring.count >= ringCapacity || ringBytes > ringByteCapacity - bytes {
            if case .event(_, let evicted) = ring.removeFirst() {
                ringBytes -= evicted
            }
            guard let next = RuntimeCounter.successor(firstRetained) else {
                exhausted = true
                return
            }
            firstRetained = next
        }
    }

    // MARK: - Control log

    /// Appends one finished operation. The log keeps the newest entries within both bounds. An entry that cannot fit its
    /// byte bound alone is never retained: every older entry is evicted and its sequence is skipped, so each subscriber
    /// behind it resyncs instead of missing it silently. Its boundary is recorded as lost, so a replay that reaches it is refused.
    mutating func appendControl(_ finished: ControlOperationFinished, bytes: Int) {
        let next = controlNext
        guard next < Self.maximumPosition else {
            exhausted = true
            return
        }
        guard bytes <= controlByteCapacity else {
            // The successor is checked before anything changes, so an exhausted count leaves the log as it was. The newest boundary is
            // the highest lost one, because every retained entry was issued at or before it.
            guard let skipped = RuntimeCounter.successor(next) else {
                exhausted = true
                return
            }
            lastLostBoundary = highWater
            control.removeAll()
            controlBytes = 0
            controlFloor = skipped
            return
        }
        while !control.isEmpty, control.count >= controlCapacity || controlBytes > controlByteCapacity - bytes {
            guard let floor = RuntimeCounter.successor(controlFloor) else {
                exhausted = true
                return
            }
            let evicted = control.removeFirst()
            controlBytes -= evicted.bytes
            controlFloor = floor
            lastLostBoundary = evicted.boundary
        }
        control.append(RuntimeControlEntry(finished: finished, boundary: highWater, bytes: bytes))
        controlBytes += bytes
    }

    // MARK: - Pull

    /// The frame one subscriber would receive next, and the cursor after it. Nothing is committed here: the caller commits
    /// the cursor only when its wait wins. `fits` says whether a candidate frame encodes within the frame limit, so a batch
    /// is cut by the real codec, not by a record-bytes estimate.
    ///
    /// An operation outcome is delivered once every position up to its boundary has been. An event batch never crosses a
    /// boundary, a gap or the end of a replay. A subscriber that fell behind the ring or the control log, or the exhausted
    /// log, ends with a resync, never a silent gap.
    func peek(
        _ start: RuntimeSubscriberCursor,
        fits: (ControlRuntimeFrame) -> Bool
    ) throws -> (pull: RuntimePull, after: RuntimeSubscriberCursor) {
        var cursor = start
        if exhausted || cursor.nextControl < controlFloor || cursor.nextEvent < firstRetained {
            return (.end(.resyncRequired), cursor)
        }
        let limit = cursor.replayThrough ?? highWater
        let control = controlEntry(atSequence: cursor.nextControl)
        if let control, control.boundary < cursor.nextEvent {
            // Every frame must fit the caller's frame, as an event batch does. An outcome that does not fit ends the stream as a resync,
            // and the cursor does not move, so nothing is consumed.
            let frame = ControlRuntimeFrame.operationFinished(control.finished)
            guard fits(frame), let nextControl = RuntimeCounter.successor(cursor.nextControl) else {
                return (.end(.resyncRequired), start)
            }
            cursor.nextControl = nextControl
            return (.frame(frame), cursor)
        }
        if cursor.nextEvent <= limit {
            let ceiling = min(limit, control?.boundary ?? limit)
            guard let first = ControlEventCursor(rawValue: cursor.nextEvent) else {
                throw ControlRuntimeWireError.invalidValue
            }
            var events: [ControlRuntimeEventRecord] = []
            var bytes = 0
            var position = cursor.nextEvent
            scan: while position <= ceiling, events.count < replayChunkItems {
                switch entry(at: position) {
                case .gap?, nil:
                    if events.isEmpty { return (.end(.resyncRequired), start) }
                    break scan
                case .event(let record, let size)?:
                    guard size <= replayChunkBytes - bytes else { break scan }
                    let candidate = try ControlEventBatch(firstCursor: first, events: events + [record])
                    guard fits(.events(candidate)) else {
                        if events.isEmpty { return (.end(.resyncRequired), start) }
                        break scan
                    }
                    events.append(record)
                    bytes += size
                }
                // Stop at the ceiling instead of stepping past it, so the position never overflows.
                guard position < ceiling, let next = RuntimeCounter.successor(position) else { break scan }
                position = next
            }
            let batch = try ControlEventBatch(firstCursor: first, events: events)
            guard let advanced = RuntimeCounter.advanced(cursor.nextEvent, by: events.count) else {
                return (.end(.resyncRequired), start)
            }
            cursor.nextEvent = advanced
            return (.frame(.events(batch)), cursor)
        }
        if let through = cursor.replayThrough, cursor.nextEvent > through {
            guard let caughtUp = ControlEventCursor(rawValue: through) else {
                throw ControlRuntimeWireError.invalidValue
            }
            let frame = ControlRuntimeFrame.replayCaughtUp(caughtUp)
            guard fits(frame) else { return (.end(.resyncRequired), start) }
            cursor.replayThrough = nil
            return (.frame(frame), cursor)
        }
        return (.idle, cursor)
    }
}
