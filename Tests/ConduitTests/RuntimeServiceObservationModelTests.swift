// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
@testable import ProxyKernel

/// A bounded reference model of the live observation rules. It is written from the design with plain counters and arrays, and it
/// never calls a production helper to derive an expected value. Each sequence runs against the production core and against this model,
/// and the two must agree after every action on the pulled frame, the open result, the slot generation and the open count.
///
/// The alphabet is nine actions: the owner changes and reports it, changes silently, or reports without a change; one event is published;
/// one live subscriber opens; subscriber slot 0 or 1 pulls or is removed. Publication stops at `ObservationModel.publishCap`, so the event
/// ring never evicts within the bound, and the claims cover only that bound: two subscriber slots, four events per batch, and at most twelve
/// events. The model does not cover replay, control outcomes, gaps, wait gates, or the transport.
struct ObservationModel {
    /// The most events one live batch carries. It matches the fixture's replay chunk count.
    static let chunk = 4
    /// The most events the bounded alphabet publishes.
    static let publishCap = 12

    struct Subscriber: Equatable {
        var nextEvent: Int
        var seen: Int
        var lastWasSnapshot: Bool
    }

    /// The result of one action, in the terms the production runner reports.
    enum Step: Equatable {
        case none
        case opened(revision: Int)
        case refused
        case pulled(ObservedPull)
    }

    /// The owner's presentation revision, which the owner advances on every change.
    private(set) var ownerRevision = 9
    /// The revision the slot holds, and zero before any capture.
    private(set) var slotRevision = 0
    /// The private generation of the slot. It advances once per replacement, and never on an identical state.
    private(set) var slotGeneration = 0
    private(set) var published = 0
    /// The two subscriber slots. A slot is nil when it holds no open subscriber.
    private(set) var slots: [Subscriber?] = [nil, nil]

    /// The open subscriber count, which the production table must match.
    var openCount: Int {
        slots.reduce(0) { $0 + ($1 == nil ? 0 : 1) }
    }

    /// The slot takes the owner's state when it differs from the held one, and it advances its generation only then.
    private mutating func capture() {
        guard slotRevision != ownerRevision else { return }
        slotRevision = ownerRevision
        slotGeneration += 1
    }

    /// One action. A refused open changes nothing, not even the slot, because the subscriber limit is checked before any capture.
    mutating func apply(_ action: ObservationAction) -> Step {
        switch action {
        case .advance:
            ownerRevision += 1
            capture()
            return .none
        case .silentAdvance:
            ownerRevision += 1
            return .none
        case .repeatOwner:
            capture()
            return .none
        case .publish:
            if published < Self.publishCap {
                published += 1
            }
            return .none
        case .open:
            guard let free = slots.firstIndex(where: { $0 == nil }) else { return .refused }
            capture()
            slots[free] = Subscriber(nextEvent: published + 1, seen: slotGeneration, lastWasSnapshot: false)
            return .opened(revision: slotRevision)
        case .pull(let slot):
            guard let subscriber = slots[slot] else { return .pulled(.gone) }
            let (pulled, next) = deliver(subscriber)
            slots[slot] = next
            return .pulled(pulled)
        case .cancel(let slot):
            slots[slot] = nil
            return .none
        }
    }

    /// The frame one live pull delivers, and the subscriber after it. A snapshot waits when the subscriber has not seen the held
    /// generation. Ordered events wait when the subscriber is behind the published count. When both wait, the snapshot goes first
    /// unless the last frame was a snapshot, so the two alternate.
    private func deliver(_ subscriber: Subscriber) -> (ObservedPull, Subscriber) {
        var next = subscriber
        let snapshotWaits = subscriber.seen < slotGeneration
        let eventsWait = subscriber.nextEvent <= published
        if snapshotWaits, !eventsWait || !subscriber.lastWasSnapshot {
            next.seen = slotGeneration
            next.lastWasSnapshot = true
            return (.snapshot(revision: slotRevision), next)
        }
        if eventsWait {
            let count = min(published - subscriber.nextEvent + 1, Self.chunk)
            next.nextEvent = subscriber.nextEvent + count
            next.lastWasSnapshot = false
            return (.events(count: count, firstCursor: subscriber.nextEvent), next)
        }
        return (.idle, next)
    }
}

/// One bounded action, shared by the model and the production runner.
enum ObservationAction: Equatable, CustomStringConvertible {
    case advance
    case silentAdvance
    case repeatOwner
    case publish
    case open
    case pull(Int)
    case cancel(Int)

    var description: String {
        switch self {
        case .advance: "advance"
        case .silentAdvance: "silentAdvance"
        case .repeatOwner: "repeatOwner"
        case .publish: "publish"
        case .open: "open"
        case .pull(let slot): "pull(\(slot))"
        case .cancel(let slot): "cancel(\(slot))"
        }
    }
}

/// A small deterministic generator for the seeded walks. The same seed always gives the same walk.
struct ObservationSplitMix64 {
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

/// The observation model against the production core. It drives each sequence in a fresh harness and compares after every action.
final class RuntimeServiceObservationModelTests: XCTestCase {
    private static let alphabet: [ObservationAction] = [
        .advance, .silentAdvance, .repeatOwner, .publish, .open, .pull(0), .pull(1), .cancel(0), .cancel(1),
    ]

    /// Every sequence of each depth from one to four, in depth order, so the first disagreement is a shortest counterexample.
    private static func exhaustiveSequences() -> [[ObservationAction]] {
        var sequences: [[ObservationAction]] = []
        var frontier: [[ObservationAction]] = [[]]
        for _ in 1...4 {
            frontier = frontier.flatMap { prefix in alphabet.map { prefix + [$0] } }
            sequences += frontier
        }
        return sequences
    }

    /// Runs one sequence on the production core and on the model. It returns the first disagreement, named with its step, or nil.
    @RuntimeActor private func disagreement(_ sequence: [ObservationAction]) throws -> String? {
        let harness = try RuntimeServiceHarness()
        harness.owner.snapshotValue = try observationSnapshot(presentation: 9)
        var model = ObservationModel()
        // The production slot ids for each subscriber slot, so a pull and a removal address the same subscriber as the model.
        var ids: [Int?] = [nil, nil]
        var runnerPublished = 0
        for (index, action) in sequence.enumerated() {
            let expected = model.apply(action)
            let actual: ObservationModel.Step
            switch action {
            case .advance:
                harness.owner.snapshotValue = try observationSnapshot(presentation: harness.owner.snapshotValue.stamp.presentationRevision.rawValue + 1)
                harness.core.ownerDidChange()
                actual = .none
            case .silentAdvance:
                harness.owner.snapshotValue = try observationSnapshot(presentation: harness.owner.snapshotValue.stamp.presentationRevision.rawValue + 1)
                actual = .none
            case .repeatOwner:
                harness.core.ownerDidChange()
                actual = .none
            case .publish:
                if runnerPublished < ObservationModel.publishCap {
                    runnerPublished += 1
                    harness.core.ingest(ControlRuntimeEvent(timestamp: Date(timeIntervalSince1970: 1), kind: "proxy", event: "test.event"))
                    harness.scheduling.drainAll()
                }
                actual = .none
            case .open:
                guard let free = ids.firstIndex(where: { $0 == nil }) else {
                    if case .refused(let code) = harness.core.openSubscription(.live) {
                        XCTAssertEqual(code, .subscriberLimit, "step \(index)")
                    }
                    actual = .refused
                    break
                }
                switch harness.core.openSubscription(.live) {
                case .opened(let subscriber, .baseline(let baseline)):
                    ids[free] = subscriber
                    actual = .opened(revision: baseline.snapshot.stamp.presentationRevision.rawValue)
                case .opened, .refused:
                    actual = .refused
                }
            case .pull(let slot):
                if let id = ids[slot] {
                    actual = .pulled(try observePull(harness.core, id))
                } else {
                    actual = .pulled(.gone)
                }
            case .cancel(let slot):
                if let id = ids[slot] {
                    harness.core.removeSubscriber(id)
                    ids[slot] = nil
                }
                actual = .none
            }
            if actual != expected {
                return "step \(index) \(action): model \(String(describing: expected)), production \(String(describing: actual))"
            }
            if harness.core.snapshotGeneration != model.slotGeneration {
                return "step \(index) \(action): generation \(harness.core.snapshotGeneration), model \(model.slotGeneration)"
            }
            if harness.core.openSubscriberCount != model.openCount {
                return "step \(index) \(action): open count \(harness.core.openSubscriberCount), model \(model.openCount)"
            }
        }
        return nil
    }

    @RuntimeActor func testTheObservationRulesAgreeWithTheModelOnEveryBoundedSequence() async throws {
        let sequences = Self.exhaustiveSequences()
        XCTAssertEqual(sequences.count, 9 + 81 + 729 + 6561, "the exhaustive bound is every sequence of depth one to four")
        for sequence in sequences {
            if let failure = try disagreement(sequence) {
                return XCTFail("shortest counterexample \(sequence.map(\.description)): \(failure)")
            }
        }
    }

    @RuntimeActor func testTheObservationRulesAgreeWithTheModelOnSeededLongWalks() async throws {
        for seed in UInt64(1)...100 {
            var generator = ObservationSplitMix64(seed: seed)
            let walk = (0..<25).map { _ in
                Self.alphabet[Int(generator.next() % UInt64(Self.alphabet.count))]
            }
            if let failure = try disagreement(walk) {
                return XCTFail("seed \(seed) walk \(walk.map(\.description)): \(failure)")
            }
        }
    }
}
