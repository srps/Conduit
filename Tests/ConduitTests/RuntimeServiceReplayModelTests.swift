// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// What one pull delivers, in the terms the replay model and the production log are compared on.
enum ReplayDelivery: Equatable {
    case events(first: Int, count: Int)
    case operation(sequence: Int)
    case caughtUp(through: Int)
    case idle
    case resync
}

/// The reference model of replay. It is written from the design with arrays and counters, not from the production ring or control log. Each
/// position is an event or a loss marker. The ring keeps the newest `ringCapacity` positions, and the control log keeps the newest
/// `controlCapacity` outcomes. A reader is a position, an optional replay end, and the next outcome sequence. A pull delivers an event
/// batch up to the chunk limit, a gap or the outcome boundary, whichever comes first. An outcome whose boundary has passed is delivered
/// before later events. A reader that falls behind either log resyncs, and a replay that could miss an evicted outcome is refused.
struct ReplayReferenceModel {
    struct Reader: Equatable {
        var next: Int
        var through: Int?
        var control: Int
    }

    let ringCapacity: Int
    let controlCapacity: Int
    let chunk: Int
    /// Position `p` is `isGap[p - 1]`.
    private(set) var isGap: [Bool] = []
    /// Outcome sequence `s` has boundary `boundaries[s - 1]`, the position issued just before it.
    private(set) var boundaries: [Int] = []

    init(ringCapacity: Int, controlCapacity: Int, chunk: Int) {
        self.ringCapacity = ringCapacity
        self.controlCapacity = controlCapacity
        self.chunk = chunk
    }

    var highWater: Int { isGap.count }
    var firstRetained: Int { max(1, highWater - ringCapacity + 1) }
    var controlNext: Int { boundaries.count + 1 }
    var controlFloor: Int { max(1, boundaries.count - controlCapacity + 1) }
    /// The highest gap position, or zero when no loss has happened.
    var lastGap: Int { isGap.lastIndex(of: true).map { $0 + 1 } ?? 0 }

    mutating func event() {
        isGap.append(false)
    }

    mutating func loss() {
        isGap.append(true)
    }

    mutating func operation() {
        boundaries.append(highWater)
    }

    /// A live reader starts after the high-water mark, with the next outcome.
    func liveReader() -> Reader {
        Reader(next: highWater + 1, through: nil, control: controlNext)
    }

    /// A replay from the oldest retained position through the high-water mark. It is refused, and the reader is live instead, when
    /// a loss lies in the range or when an evicted outcome may have been in it. The outcomes in range start at the first one whose
    /// boundary is at or after the replay start.
    func replayReader() -> Reader {
        guard highWater >= 1 else { return liveReader() }
        let first = firstRetained
        if lastGap >= first { return liveReader() }
        if controlFloor > 1, boundaries[controlFloor - 1] >= first { return liveReader() }
        var control = controlNext
        for sequence in controlFloor...max(controlFloor, boundaries.count) where sequence <= boundaries.count {
            if boundaries[sequence - 1] >= first {
                control = sequence
                break
            }
        }
        return Reader(next: first, through: highWater, control: control)
    }

    /// One pull and the reader after it. A closed answer is nil, and the caller drops the reader.
    func pull(_ reader: Reader) -> (ReplayDelivery, Reader?) {
        if reader.control < controlFloor || reader.next < firstRetained {
            return (.resync, nil)
        }
        let limit = reader.through ?? highWater
        let hasOutcome = reader.control <= boundaries.count
        if hasOutcome, boundaries[reader.control - 1] < reader.next {
            var after = reader
            after.control += 1
            return (.operation(sequence: reader.control), after)
        }
        if reader.next <= limit {
            let ceiling = hasOutcome ? min(limit, boundaries[reader.control - 1]) : limit
            var count = 0
            var position = reader.next
            while position <= ceiling, count < chunk {
                if isGap[position - 1] { break }
                count += 1
                position += 1
            }
            guard count > 0 else { return (.resync, nil) }
            var after = reader
            after.next += count
            return (.events(first: reader.next, count: count), after)
        }
        if let through = reader.through, reader.next > through {
            var after = reader
            after.through = nil
            return (.caughtUp(through: through), after)
        }
        return (.idle, reader)
    }
}

/// One bounded action of the replay model. Two reader slots, as the fixture allows.
enum ReplayAction: Equatable, CustomStringConvertible {
    case event
    case loss
    case operation
    case openLive
    case openReplay
    case pull(Int)

    var description: String {
        switch self {
        case .event: "event"
        case .loss: "loss"
        case .operation: "operation"
        case .openLive: "openLive"
        case .openReplay: "openReplay"
        case .pull(let slot): "pull(\(slot))"
        }
    }
}

/// A small deterministic generator for the seeded walks. The same seed always gives the same walk.
struct ReplaySplitMix64 {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

/// The replay model against the production observation log. Every sequence runs on a fresh log with a ring of three, an outcome log of
/// two and chunks of two, so eviction, loss and mid-catch-up expiry are reached within a short sequence. Each step compares the delivery
/// of every pull, the open reader's start, and the retained window.
@MainActor
final class RuntimeServiceReplayModelTests: XCTestCase {
    private static let ringCapacity = 3
    private static let controlCapacity = 2
    private static let chunk = 2
    private static let alphabet: [ReplayAction] = [.event, .loss, .operation, .openLive, .openReplay, .pull(0), .pull(1)]

    private func limits() throws -> RuntimeServiceLimits {
        try RuntimeServiceFixtures.limits(
            ringCapacity: Self.ringCapacity,
            controlLogCapacity: Self.controlCapacity,
            replayChunkItems: Self.chunk
        )
    }

    /// The production reader for one slot, as the core's observation state holds it.
    private struct ProductionReader {
        var cursor: RuntimeSubscriberCursor
    }

    /// The production open: a live reader, or a replay from the oldest retained position that the production log refuses to a live
    /// reader when a loss or an evicted outcome is in the range. It uses only the log's own primitives.
    private func productionOpen(_ log: RuntimeObservationLog, replay: Bool) -> RuntimeSubscriberCursor {
        let live = RuntimeSubscriberCursor(
            nextEvent: log.liveStart,
            replayThrough: nil,
            nextControl: log.controlNext,
            seenSnapshotGeneration: 0,
            lastWasSnapshot: false
        )
        guard replay, log.highWater >= 1 else { return live }
        let first = log.firstRetained
        guard !log.crossesLoss(from: first), let control = log.controlStart(forEvent: first) else { return live }
        return RuntimeSubscriberCursor(
            nextEvent: first,
            replayThrough: log.highWater,
            nextControl: control,
            seenSnapshotGeneration: 0,
            lastWasSnapshot: false
        )
    }

    /// One production pull, reduced to the model's delivery vocabulary. A frame's cursor is committed only here, as the winning gate would.
    private func productionPull(
        _ log: RuntimeObservationLog,
        _ reader: inout ProductionReader?,
        sequences: [ControlOperationID: Int]
    ) throws -> ReplayDelivery? {
        guard let current = reader?.cursor else { return nil }
        let peeked = try log.peek(current, fits: { _ in true })
        switch peeked.pull {
        case .frame(.events(let batch)):
            reader?.cursor = peeked.after
            return .events(first: batch.firstCursor.rawValue, count: batch.events.count)
        case .frame(.operationFinished(let finished)):
            reader?.cursor = peeked.after
            return .operation(sequence: sequences[finished.operationID] ?? -1)
        case .frame(.replayCaughtUp(let through)):
            reader?.cursor = peeked.after
            return .caughtUp(through: through.rawValue)
        case .frame:
            return .idle
        case .idle:
            return .idle
        case .end:
            reader = nil
            return .resync
        }
    }

    /// Runs one sequence on the production log and on the model. It returns the first disagreement, named with its step, or nil.
    private func disagreement(_ sequence: [ReplayAction]) throws -> String? {
        let limits = try limits()
        var log = RuntimeObservationLog(limits: limits)
        var model = ReplayReferenceModel(ringCapacity: Self.ringCapacity, controlCapacity: Self.controlCapacity, chunk: Self.chunk)
        var readers: [ProductionReader?] = [nil, nil]
        var modelReaders: [ReplayReferenceModel.Reader?] = [nil, nil]
        var sequences: [ControlOperationID: Int] = [:]
        let record = ControlRuntimeEventRecord.known(
            ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event")
        )
        for (index, action) in sequence.enumerated() {
            switch action {
            case .event:
                log.apply([.event(record, bytes: 100)])
                model.event()
            case .loss:
                log.apply([.loss])
                model.loss()
            case .operation:
                let identifier = RuntimeServiceFixtures.operation(model.controlNext)
                sequences[identifier] = model.controlNext
                log.appendControl(ControlOperationFinished(operationID: identifier, outcome: .failed(.internalFailure)), bytes: 100)
                model.operation()
            case .openLive, .openReplay:
                guard let free = modelReaders.firstIndex(where: { $0 == nil }) else { break }
                let replay = action == .openReplay
                modelReaders[free] = replay ? model.replayReader() : model.liveReader()
                readers[free] = ProductionReader(cursor: productionOpen(log, replay: replay))
            case .pull(let slot):
                guard let expected = modelReaders[slot] else { break }
                let (delivery, after) = model.pull(expected)
                let actual = try productionPull(log, &readers[slot], sequences: sequences)
                if actual != delivery {
                    return "step \(index) \(action): model \(delivery), production \(String(describing: actual))"
                }
                modelReaders[slot] = after
                if after == nil {
                    readers[slot] = nil
                }
            }
            if log.highWater != model.highWater || log.firstRetained != model.firstRetained {
                return "step \(index) \(action): window model \(model.firstRetained)...\(model.highWater), production \(log.firstRetained)...\(log.highWater)"
            }
            if log.controlNext != model.controlNext || log.controlFloor != model.controlFloor {
                return "step \(index) \(action): outcomes model \(model.controlFloor)..<\(model.controlNext), production \(log.controlFloor)..<\(log.controlNext)"
            }
        }
        return nil
    }

    func testTheReplayRulesAgreeWithTheModelOnEveryBoundedSequence() throws {
        var sequences: [[ReplayAction]] = []
        var frontier: [[ReplayAction]] = [[]]
        for _ in 1...5 {
            frontier = frontier.flatMap { prefix in Self.alphabet.map { prefix + [$0] } }
            sequences += frontier
        }
        XCTAssertEqual(sequences.count, 7 + 49 + 343 + 2401 + 16807, "every sequence of depth one to five over seven actions")
        for sequence in sequences {
            if let failure = try disagreement(sequence) {
                return XCTFail("shortest counterexample \(sequence.map(\.description)): \(failure)")
            }
        }
    }

    func testTheReplayRulesAgreeWithTheModelOnSeededLongWalks() throws {
        for seed in UInt64(1)...200 {
            var generator = ReplaySplitMix64(seed: seed)
            let walk = (0..<40).map { _ in
                Self.alphabet[Int(generator.next() % UInt64(Self.alphabet.count))]
            }
            if let failure = try disagreement(walk) {
                return XCTFail("seed \(seed) walk \(walk.map(\.description)): \(failure)")
            }
        }
    }

    /// The witness for the caller's frame: an outcome that does not fit ends the reader as a resync, and the cursor does not move.
    func testAnOutcomeThatDoesNotFitEndsTheReaderWithoutConsumingIt() throws {
        var log = RuntimeObservationLog(limits: try limits())
        log.appendControl(ControlOperationFinished(operationID: RuntimeServiceFixtures.operation(1), outcome: .failed(.internalFailure)), bytes: 100)
        let start = RuntimeSubscriberCursor(nextEvent: 1, replayThrough: nil, nextControl: 1, seenSnapshotGeneration: 0, lastWasSnapshot: false)
        let refused = try log.peek(start) { frame in
            if case .operationFinished = frame { return false }
            return true
        }
        XCTAssertEqual(refused.pull, RuntimePull.end(.resyncRequired))
        XCTAssertEqual(refused.after, start, "the outcome was not consumed")
        let delivered = try log.peek(start) { _ in true }
        XCTAssertEqual(delivered.pull, RuntimePull.frame(.operationFinished(ControlOperationFinished(
            operationID: RuntimeServiceFixtures.operation(1),
            outcome: .failed(.internalFailure)
        ))))
    }
}
