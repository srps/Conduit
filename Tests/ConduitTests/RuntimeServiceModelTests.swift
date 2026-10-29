// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared
import ProxyKernel

/// Bounded models of the two lifetimes this slice owns. Each model drives the production types step by step, and after
/// every step it compares the observable state with a separate reference written from the rules, not from the code.
///
/// Exploration is exhaustive to a fixed depth, and it is then seeded (deterministic) for longer walks. The first
/// mismatch found by the depth-ordered search is the shortest counterexample. A search that runs out of its budget fails.
final class RuntimeServiceModelTests: XCTestCase {
    /// The longest exhaustive depth, and the explored-sequence budget. A search over the budget fails the test.
    private let exhaustiveDepth = 4
    private let sequenceBudget = 25_000

    // MARK: - Wait: gate, ticket, scheduling and the parked registration

    @RuntimeActor func testWaitLifetimeAgreesWithTheReferenceExhaustivelyToTheDepth() async throws {
        var explored = 0
        for depth in 1...exhaustiveDepth {
            for sequence in allSequences(of: WaitAction.allCases, depth: depth) {
                explored += 1
                XCTAssertLessThanOrEqual(explored, sequenceBudget, "the wait model search ran out of its budget")
                if let failure = try replayWait(sequence) {
                    return XCTFail("shortest wait counterexample \(sequence): \(failure)")
                }
            }
        }
        // Nine wait actions: 9 + 81 + 729 + 6561 sequences of depth one to four, and every one of them agreed.
        XCTAssertEqual(explored, 7_380)
    }

    @RuntimeActor func testWaitLifetimeAgreesWithTheReferenceOnSeededLongWalks() async throws {
        for seed in 1...150 {
            var generator = SplitMix64(state: UInt64(seed))
            let sequence = (0..<40).map { _ in WaitAction.allCases[Int(generator.next() % UInt64(WaitAction.allCases.count))] }
            if let failure = try replayWait(sequence) {
                return XCTFail("seed \(seed) produced a wait counterexample: \(failure)")
            }
        }
    }

    // MARK: - Work: admission, launches, supersession and quiescence

    @RuntimeActor func testWorkLifetimeAgreesWithTheReferenceExhaustivelyToTheDepth() async throws {
        var explored = 0
        for depth in 1...exhaustiveDepth {
            for sequence in allSequences(of: WorkAction.alphabet, depth: depth) {
                explored += 1
                XCTAssertLessThanOrEqual(explored, sequenceBudget, "the work model search ran out of its budget")
                if let failure = try replayWork(sequence) {
                    return XCTFail("shortest work counterexample \(sequence): \(failure)")
                }
            }
        }
        // Twelve work actions: 12 + 144 + 1728 + 20736 sequences of depth one to four, and every one of them agreed.
        XCTAssertEqual(explored, 22_620)
    }

    @RuntimeActor func testWorkLifetimeAgreesWithTheReferenceOnSeededLongWalks() async throws {
        for seed in 1...150 {
            var generator = SplitMix64(state: UInt64(seed))
            let sequence = (0..<40).map { _ in WorkAction.alphabet[Int(generator.next() % UInt64(WorkAction.alphabet.count))] }
            if let failure = try replayWork(sequence) {
                return XCTFail("seed \(seed) produced a work counterexample: \(failure)")
            }
        }
    }

    // MARK: - Sequence generation

    /// Every sequence of `depth` actions, in lexicographic order.
    @RuntimeActor private func allSequences<Action>(of alphabet: [Action], depth: Int) -> [[Action]] {
        var sequences: [[Action]] = [[]]
        for _ in 0..<depth {
            sequences = sequences.flatMap { prefix in alphabet.map { prefix + [$0] } }
        }
        return sequences
    }

    // MARK: - Replays

    /// Replays one wait sequence on fresh production objects. It returns the first mismatch, or nil when every step agreed.
    @RuntimeActor private func replayWait(_ actions: [WaitAction]) throws -> String? {
        let harness = try RuntimeServiceHarness()
        let lanes = RuntimeLaneCounter(limits: harness.limits)
        guard let ticket = lanes.reserve(.read, onQuiesced: nil) else { return "the lane refused its first reservation" }
        let scheduling = harness.scheduling
        let mode = WaitModeBox()
        let tokens = WaitTokenBox()
        let transport = harness.transport()
        guard case .opened(let subscriber, _) = harness.core.openSubscription(.live) else {
            return "the subscription must open"
        }
        let gate = RuntimeWaitGate(
            ticket: ticket,
            deadline: RuntimeDeadline.after(.seconds(3600), from: harness.timing.now),
            timing: harness.timing.timing,
            scheduling: scheduling,
            attempt: { gate in
                switch mode.current {
                case .park:
                    // The production registration path: the waiter part, the registration and the park, in that order.
                    let token = RuntimeWaiterToken()
                    tokens.current = token
                    _ = transport.installRegistration(subscriber, token: token, gate: gate)
                    return nil
                case .finish:
                    return .reply(Data())
                }
            },
            abandoned: { _ in }
        )
        var model = WaitReferenceModel()

        for (step, action) in actions.enumerated() {
            var observedFinish: Bool?
            var expectedFinish: Bool?
            switch action {
            case .armPark:
                mode.current = .park
                model.arm = .park
            case .armFinish:
                mode.current = .finish
                model.arm = .finish
            case .runOldest:
                let ran = scheduling.runNext()
                if ran != model.runOldest() { return "step \(step): the hop queue disagrees about whether a hop ran" }
            case .expireCaller:
                gate.expire(.cancelled)
                model.expire()
            case .startRound:
                // `start` queues the first round after its timer task exists, but that task may already have run.
                gate.queueRound()
                model.queueRound()
            case .timerFires:
                // The timer task expires first and ends its part last, as its body does.
                gate.expire(.deadlineExpired)
                ticket.end(.timer)
                model.timerFires()
            case .timerEndsAfterCancel:
                ticket.end(.timer)
                model.timerHeld = false
            case .wake:
                // The service wakes a parked wait only after it has removed that wait's registration, as its own wake does.
                harness.core.releaseWaiter(subscriber, token: tokens.current)
                gate.wake()
                model.wake()
            case .finish:
                observedFinish = gate.finish(.reply(Data()))
                expectedFinish = model.finish()
            }
            if let expectedFinish, observedFinish != expectedFinish {
                return "step \(step) \(action): finish returned \(String(describing: observedFinish)), expected \(expectedFinish)"
            }
            if gate.currentPhase.modelPhase != model.phase {
                return "step \(step) \(action): phase is \(gate.currentPhase), expected \(model.phase)"
            }
            if ticket.isReleased != model.released {
                return "step \(step) \(action): reservation released is \(ticket.isReleased), expected \(model.released)"
            }
            if lanes.inFlight(.read) != (model.released ? 0 : 1) {
                return "step \(step) \(action): lane holds \(lanes.inFlight(.read)) slots"
            }
            if scheduling.pendingCount != model.fifo.count {
                return "step \(step) \(action): \(scheduling.pendingCount) hops queued, expected \(model.fifo.count)"
            }
        }
        return nil
    }

    /// Replays one work sequence on a fresh service with one ordinary slot, so ordinary refusal is reachable.
    @RuntimeActor private func replayWork(_ actions: [WorkAction]) throws -> String? {
        let harness = try RuntimeServiceHarness(aliases: 8, ordinaryPending: 1)
        harness.owner.answer = { _, _ in .admitted }
        var model = WorkReferenceModel(ordinaryCapacity: 1)
        var observed: [ControlOperationID] = []
        var requestID = 0

        for (step, action) in actions.enumerated() {
            switch action {
            case .submitStop(let module):
                requestID += 1
                let admission = harness.core.submit(try RuntimeServiceFixtures.request(requestID, .stop(module)))
                guard case .accepted(let operation) = admission else { return "step \(step) \(action): stop was \(admission)" }
                observed.append(operation)
                _ = model.submitStop(module)
            case .submitOrdinary:
                requestID += 1
                let admission = harness.core.submit(try RuntimeServiceFixtures.request(requestID, .restart(.proxy, ifLifecycleRevision: lifecycleRevision)))
                let expected = model.submitOrdinary()
                switch admission {
                case .accepted(let operation):
                    guard expected != nil else { return "step \(step) \(action): admitted beyond the ordinary capacity" }
                    observed.append(operation)
                case .rejected(.queueFull):
                    guard expected == nil else { return "step \(step) \(action): refused while the model had room" }
                default:
                    return "step \(step) \(action): unexpected admission \(admission)"
                }
            case .runOldest:
                let ran = harness.scheduling.runNext()
                if ran != model.runOldest() { return "step \(step) \(action): the hop queue disagrees" }
            case .settle(let index):
                if index <= observed.count {
                    harness.owner.settle(observed[index - 1], with: .failed(.effectFailed))
                    model.settle(index)
                }
            case .quiesce(let index):
                if index <= observed.count {
                    harness.owner.quiesce(observed[index - 1])
                    model.quiesce(index)
                }
            case .joinStop(let module):
                // A join needs a pending candidate: with none, the action is a no-op on both sides.
                guard let candidate = model.candidateIndex(of: module) else { break }
                harness.owner.answer = { _, _ in .joinedCandidate }
                requestID += 1
                let admission = harness.core.submit(try RuntimeServiceFixtures.request(requestID, .stop(module)))
                harness.owner.answer = { _, _ in .admitted }
                guard case .joined(let joined) = admission, joined == observed[candidate - 1] else {
                    return "step \(step) \(action): expected a join with the pending candidate, got \(admission)"
                }
            case .rejectStop(let module):
                harness.owner.answer = { _, _ in .rejected(.hostStopping) }
                requestID += 1
                let admission = harness.core.submit(try RuntimeServiceFixtures.request(requestID, .stop(module)))
                harness.owner.answer = { _, _ in .admitted }
                guard admission == .rejected(.hostStopping) else {
                    return "step \(step) \(action): expected a rejection, got \(admission)"
                }
            }
            if let mismatch = compareWork(harness, model, step: step, action: action) {
                return mismatch
            }
        }
        return nil
    }

    private var lifecycleRevision: ControlLifecycleRevision {
        ControlLifecycleRevision(rawValue: 5) ?? ControlLifecycleRevision(rawValue: 0)!
    }

    /// The service's observable state, after one step, against the reference.
    @RuntimeActor private func compareWork(_ harness: RuntimeServiceHarness, _ model: WorkReferenceModel, step: Int, action: WorkAction) -> String? {
        for module in [ControlModule.dns, .proxy] {
            let observed = harness.core.stopSlotState(module)
            let expected = model.slots(of: module)
            if observed.active != expected.active || observed.queued != expected.queued {
                return "step \(step) \(action): \(module) slots are \(observed), expected \(expected)"
            }
        }
        if harness.core.ordinaryUnquiescedCount != model.unquiesced {
            return "step \(step) \(action): ordinary capacity holds \(harness.core.ordinaryUnquiescedCount), expected \(model.unquiesced)"
        }
        if harness.core.runningOperationCount != model.runningCount {
            return "step \(step) \(action): \(harness.core.runningOperationCount) running, expected \(model.runningCount)"
        }
        if harness.core.liveOperationCount != model.liveCount {
            return "step \(step) \(action): \(harness.core.liveOperationCount) live operations, expected \(model.liveCount)"
        }
        if harness.core.pendingOperationCount != model.pendingCount {
            return "step \(step) \(action): \(harness.core.pendingOperationCount) pending, expected \(model.pendingCount)"
        }
        if harness.owner.startedOperations.count != model.starts {
            return "step \(step) \(action): \(harness.owner.startedOperations.count) launches, expected \(model.starts)"
        }
        if harness.scheduling.pendingCount != model.fifo.count {
            return "step \(step) \(action): \(harness.scheduling.pendingCount) hops queued, expected \(model.fifo.count)"
        }
        return nil
    }
}

// MARK: - Actions

enum WaitAction: CaseIterable, CustomStringConvertible {
    case armPark, armFinish, startRound, runOldest, expireCaller, timerFires, timerEndsAfterCancel, wake, finish

    var description: String {
        switch self {
        case .armPark: "armPark"
        case .armFinish: "armFinish"
        case .startRound: "startRound"
        case .runOldest: "runOldest"
        case .expireCaller: "expireCaller"
        case .timerFires: "timerFires"
        case .timerEndsAfterCancel: "timerEndsAfterCancel"
        case .wake: "wake"
        case .finish: "finish"
        }
    }
}

enum WorkAction: Hashable, CustomStringConvertible {
    case submitStop(ControlModule)
    case submitOrdinary
    case runOldest
    case settle(Int)
    case quiesce(Int)
    /// A stop the owner joins to the pending candidate. It is a no-op when no candidate is pending.
    case joinStop(ControlModule)
    /// A stop the owner rejects. Nothing is queued, and nothing is recorded as an operation.
    case rejectStop(ControlModule)

    /// Join and reject are exercised for `.dns` only. The proxy module's stop is submitted, but it is never joined or rejected
    /// in this model. Adding `.joinStop(.proxy)` and `.rejectStop(.proxy)` would make the exhaustive depth-4 enumeration 41,370
    /// sequences (14 + 196 + 2,744 + 38,416), past the 25,000 budget. The proxy join and reject paths have no model witness.
    static let alphabet: [WorkAction] = [
        .submitStop(.dns), .submitStop(.proxy), .submitOrdinary, .runOldest,
        .settle(1), .settle(2), .settle(3), .quiesce(1), .quiesce(2), .quiesce(3),
        .joinStop(.dns), .rejectStop(.dns),
    ]

    var description: String {
        switch self {
        case .submitStop(let module): "submitStop(\(module.rawValue))"
        case .submitOrdinary: "submitOrdinary"
        case .runOldest: "runOldest"
        case .settle(let index): "settle(\(index))"
        case .quiesce(let index): "quiesce(\(index))"
        case .joinStop(let module): "joinStop(\(module.rawValue))"
        case .rejectStop(let module): "rejectStop(\(module.rawValue))"
        }
    }
}

/// The wait's owner round behaviour, set by the model's actions.
private final class WaitModeBox: @unchecked Sendable {
    enum Mode { case park, finish }
    var current = Mode.park
}

/// The registration token of the replay's latest park, so a wake can remove exactly that registration.
private final class WaitTokenBox: @unchecked Sendable {
    var current = RuntimeWaiterToken()
}

/// A deterministic generator for seeded walks.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}

extension RuntimeGatePhase {
    /// The phase in the reference's vocabulary.
    var modelPhase: WaitReferenceModel.Phase {
        switch self {
        case .open: .open
        case .claimed: .claimed
        case .parked: .parked
        case .resolved: .resolved
        }
    }
}

// MARK: - Reference models

/// The reference for one wait's phases, parts and queued hops. It is written from the rules of the design: a round claims
/// an open wait, a park holds the registration until a wake or a cleanup, and the reservation releases only when every
/// part has ended.
struct WaitReferenceModel {
    enum Phase: Equatable { case open, claimed, parked, resolved }
    enum Kind: Equatable { case round, cleanup }
    enum Mode: Equatable { case park, finish }
    enum Resolution: Equatable { case notSent, sent, reply }

    var phase = Phase.open
    var arm = Mode.park
    var timerHeld = true
    var hopHolds = 0
    var waiterHeld = false
    var wakeRequested = false
    var resolution: Resolution?
    var fifo: [Kind] = []

    var released: Bool { !timerHeld && hopHolds == 0 && !waiterHeld }

    mutating func queueRound() {
        guard !released else { return }
        hopHolds += 1
        fifo.append(.round)
    }

    /// Runs the oldest queued hop. It reports whether one was queued.
    mutating func runOldest() -> Bool {
        guard !fifo.isEmpty else { return false }
        switch fifo.removeFirst() {
        case .cleanup:
            waiterHeld = false
        case .round:
            if phase == .open {
                phase = .claimed
                switch arm {
                case .finish:
                    resolve(.reply)
                case .park:
                    if wakeRequested {
                        wakeRequested = false
                        phase = .open
                        // The next round's hop begins before the waiter part ends, as the production wake does.
                        hopHolds += 1
                        fifo.append(.round)
                        waiterHeld = false
                    } else {
                        phase = .parked
                        waiterHeld = true
                    }
                }
            }
            hopHolds -= 1
        }
        return true
    }

    /// A deadline or a cancel ends the wait: notSent before a claim, and sent after one.
    mutating func expire() {
        switch phase {
        case .resolved: return
        case .open, .parked: resolve(.notSent)
        case .claimed: resolve(.sent)
        }
    }

    /// The timer's own end, then its expiry, in the order the timer task performs them.
    mutating func timerFires() {
        timerHeld = false
        expire()
    }

    mutating func wake() {
        switch phase {
        case .parked:
            phase = .open
            // The next round's hop begins before the waiter part ends, as the production wake does.
            hopHolds += 1
            fifo.append(.round)
            waiterHeld = false
        case .claimed:
            wakeRequested = true
        case .open, .resolved:
            break
        }
    }

    /// A round's own answer. It wins only when the wait is not yet resolved.
    mutating func finish() -> Bool {
        guard phase != .resolved else { return false }
        resolve(.reply)
        return true
    }

    private mutating func resolve(_ answer: Resolution) {
        guard phase != .resolved else { return }
        // A parked registration needs a cleanup hop, and its waiter part holds until that hop runs.
        if phase == .parked {
            fifo.append(.cleanup)
        }
        phase = .resolved
        resolution = answer
    }
}

/// The reference for the service's admission, stop slots and launches. It is written from the rules: a stop's candidate
/// settles when superseded, a queued stop is dropped unstarted, one active and one queued stop per module, and ordinary
/// capacity returns only at quiescence.
struct WorkReferenceModel {
    enum Physical: Equatable { case queued, running, closed }
    enum Hop: Equatable { case stop(ControlModule), ordinary(Int) }
    struct Operation {
        let module: ControlModule?
        var pending: Bool
        var physical: Physical
    }

    let ordinaryCapacity: Int
    private(set) var ops: [Operation] = []
    private var candidate: [ControlModule: Int] = [:]
    private var queued: [ControlModule: Int] = [:]
    private var active: [ControlModule: Int] = [:]
    private var launchQueued: [ControlModule: Bool] = [:]
    private(set) var fifo: [Hop] = []
    private(set) var unquiesced = 0
    private(set) var starts = 0

    init(ordinaryCapacity: Int) {
        self.ordinaryCapacity = ordinaryCapacity
    }

    var runningCount: Int { ops.filter { $0.physical == .running }.count }
    var liveCount: Int { ops.filter { $0.physical != .closed }.count }
    var pendingCount: Int { ops.filter { $0.pending && $0.physical != .closed }.count }

    /// The operation index of a module's pending candidate, which a join returns.
    func candidateIndex(of module: ControlModule) -> Int? {
        candidate[module]
    }

    func slots(of module: ControlModule) -> (active: Bool, queued: Bool) {
        (active[module] != nil, queued[module] != nil)
    }

    /// A stop: its candidate settles as superseded, a queued one is dropped unstarted, and the new one queues for launch.
    mutating func submitStop(_ module: ControlModule) -> Int {
        ops.append(Operation(module: module, pending: true, physical: .queued))
        let index = ops.count
        if let previous = candidate[module] {
            settle(previous)
        }
        if let dropped = queued[module] {
            ops[dropped - 1].physical = .closed
            ops[dropped - 1].pending = false
            queued[module] = nil
        }
        queued[module] = index
        candidate[module] = index
        scheduleStop(module)
        return index
    }

    /// An ordinary command, when capacity allows. It is refused, and nothing is recorded, when it does not.
    mutating func submitOrdinary() -> Int? {
        guard unquiesced < ordinaryCapacity else { return nil }
        unquiesced += 1
        ops.append(Operation(module: nil, pending: true, physical: .queued))
        let index = ops.count
        fifo.append(.ordinary(index))
        return index
    }

    /// Runs the oldest hop. It reports whether one was queued.
    mutating func runOldest() -> Bool {
        guard !fifo.isEmpty else { return false }
        switch fifo.removeFirst() {
        case .ordinary(let index):
            if ops[index - 1].physical == .queued {
                launch(index)
            }
        case .stop(let module):
            launchQueued[module] = false
            if active[module] == nil, let next = queued[module] {
                queued[module] = nil
                active[module] = next
                launch(next)
            }
        }
        return true
    }

    /// A logical settlement of a launched operation. A settlement of an operation that never launched is not reachable.
    mutating func settle(_ index: Int) {
        guard ops[index - 1].physical == .running, ops[index - 1].pending else { return }
        ops[index - 1].pending = false
        if let module = ops[index - 1].module, candidate[module] == index {
            candidate[module] = nil
        }
    }

    /// The physical quiescence of a launched operation. A pending one settles first, as an internal failure.
    mutating func quiesce(_ index: Int) {
        guard ops[index - 1].physical == .running else { return }
        settle(index)
        ops[index - 1].physical = .closed
        if let module = ops[index - 1].module {
            if active[module] == index {
                active[module] = nil
                if queued[module] != nil {
                    scheduleStop(module)
                }
            }
        } else {
            unquiesced -= 1
        }
    }

    private mutating func launch(_ index: Int) {
        ops[index - 1].physical = .running
        starts += 1
    }

    private mutating func scheduleStop(_ module: ControlModule) {
        guard launchQueued[module] != true else { return }
        launchQueued[module] = true
        fifo.append(.stop(module))
    }
}
