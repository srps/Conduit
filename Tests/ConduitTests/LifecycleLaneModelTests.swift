// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import XCTest

/// `LifecycleLane` against an independent bounded model (#186; the model table in
/// `docs/design-runtime-host-contract.md`).
///
/// The model is a specification written here as plain values: what each command
/// admits, supersedes, joins and wakes. It does not reuse the lane's code. Each
/// history runs on a fresh production lane, one command at a time. After every
/// command the driver lets resumed joins and idle waits run, then compares the
/// lane with the model: each admission, the latest generation, idleness, the
/// number of callers still waiting, which waits have resumed, and whether every
/// token ever issued is superseded.
///
/// Bounds. Histories are explored breadth first to `maxDepth` commands, so a
/// failure is a shortest history. The exploration is bounded by depth, not run
/// to a fixed point: the test reports how many states were still new at the
/// bound, and zero means the reachable space closed before it. At most `maxHeld`
/// operations are in flight and at most `maxWaiters` idle waiters are pending.
/// Exploration fails if more than `maxStates` distinct model states appear.
///
/// Release. Every history ends in the same release, passing or diverging: the
/// driver ends whatever the lane still holds on the production lane, and awaits
/// every join and idle wait it created. A join the lane never resumes is counted
/// and reported, not awaited, so a lost wakeup fails the test in bounded time
/// instead of hanging it.
///
/// Cleanup. After a history that did not diverge, teardown ends what the history
/// left open through `endUnfaulted`, which goes to the lane directly. It is not part
/// of the explored alphabet, so a printed witness is the commands alone.
///
/// Injected faults. `LifecycleFault` perturbs one call on its way from the
/// driver into the production lane, or what the driver keeps. The lane is not
/// changed, and no flag exists in it. Each fault must be caught, at the
/// shortest explicit history the test asserts. Cleanup and release bypass the
/// faults, so they cannot create a divergence the history did not reach.
///
/// Not proved: real Task or NIO schedules. The driver runs on the main actor with
/// nothing else scheduled, so it covers the sequential command orders only.
/// Interleavings inside platform blocks belong to the AppState and daemon
/// harnesses and to pm-sim.
///
/// Limit. A real lane lost wakeup, a join or idle wait the lane never resumes, is
/// detected and counted, but this test cannot unblock it: `CheckedContinuation` has
/// no cancellation, so the parked task outlives the failed history. Bounded
/// failure therefore does not clean up every corruption, and a leaked continuation
/// is reported rather than drained.
@MainActor
final class LifecycleLaneModelTests: XCTestCase {
    private let maxDepth = 6
    private let maxHeld = 3
    private let maxWaiters = 2
    private let maxStates = 20_000

    /// The behaviours the replayed histories showed.
    private struct Coverage {
        var coalesced = false
        var forcedNewWhileRunning = false
        var supersededWhileHeld = false
        var staleTokenHeld = false
        var joinerResumed = false
        var idleWaiterResumed = false
    }

    /// One breadth-first exploration's outcome.
    private enum Exploration {
        case conforms(states: Int, histories: Int, coverage: Coverage, newAtBound: Int)
        case diverged(LifecycleDivergence)
        case leaked(Int, after: [LifecycleCommand])
        case budgetExhausted(states: Int)
    }

    func testLaneConformsToTheModelWithinItsBounds() async {
        switch await explore(fault: nil) {
        case .conforms(let states, let histories, let coverage, let newAtBound):
            let closure = newAtBound == 0
                ? "the reachable space closed before the bound"
                : "\(newAtBound) states were still new at the bound"
            print("LifecycleLane model: \(states) distinct states, \(histories) histories replayed, "
                  + "depth \(maxDepth) (stated bound; \(closure)), \(maxHeld) held, \(maxWaiters) waiters, "
                  + "state budget \(maxStates)")
            XCTAssertTrue(coverage.coalesced, "a same-kind start or stop joined the one in flight")
            XCTAssertTrue(coverage.forcedNewWhileRunning, "a forced operation began while its kind was running")
            XCTAssertTrue(coverage.supersededWhileHeld, "quit superseded operations still in flight")
            XCTAssertTrue(coverage.staleTokenHeld, "a token still held by its caller was observed superseded")
            XCTAssertTrue(coverage.joinerResumed, "a joined caller resumed when the operation it joined ended")
            XCTAssertTrue(coverage.idleWaiterResumed, "an idle waiter resumed once the last operation ended")
        case .diverged(let divergence):
            XCTFail("the lane diverged from the model: \(divergence)")
        case .leaked(let count, let history):
            XCTFail("\(count) joins or idle waits never resumed after [\(Self.describe(history))]")
        case .budgetExhausted(let states):
            XCTFail("state budget exhausted at \(states) states: raise maxStates or lower maxDepth")
        }
    }

    /// Longer histories than the breadth-first depth, from fixed seeds, with the
    /// same alphabet and checks. A failure names its seed.
    func testSeededLongerHistoriesConformToTheModel() async {
        var coverage = Coverage()
        for seed in UInt64(1)...200 {
            var generator = SplitMix64(seed: seed)
            var history: [LifecycleCommand] = []
            var model = LifecycleModel()
            for _ in 0..<40 {
                let commands = enabledCommands(model)
                let command = commands[Int(generator.next() % UInt64(commands.count))]
                history.append(command)
                _ = model.apply(command)
            }
            let replay = await replayHistory(history, fault: nil, &coverage)
            if replay.unresumed > 0 {
                return XCTFail("seed \(seed): \(replay.unresumed) joins or idle waits never resumed")
            }
            if case .failure(let failure) = replay.result {
                return XCTFail("seed \(seed) diverged from the model: \(failure)")
            }
        }
    }

    /// Each injected fault, and the shortest explicit history that shows it: the
    /// printed witness is the commands alone, with cleanup not counted. A fault the
    /// model misses, or one only a longer history shows, fails here.
    func testEachInjectedAdapterFaultDivergesAtItsShortestHistory() async {
        // `dropEnd` needs a begin and the end that is lost: the lane keeps the operation
        // open once the model has gone idle. Cleanup ends operations on the real lane, so
        // one begin alone never shows it.
        let shortest: [LifecycleFault: Int] = [
            .skipSupersedeAll: 1,
            .forceNoncoalescing: 2,
            .skipJoin: 2,
            .dropEnd: 2,
        ]
        XCTAssertEqual(Set(shortest.keys), Set(LifecycleFault.allCases), "every fault has an expected shortest history")
        for fault in LifecycleFault.allCases {
            switch await explore(fault: fault) {
            case .diverged(let divergence):
                XCTAssertEqual(divergence.history.count, shortest[fault], "\(fault): \(divergence)")
            case .conforms:
                XCTFail("\(fault) was not caught within depth \(maxDepth)")
            case .leaked(let count, let history):
                XCTFail("\(fault): \(count) joins or idle waits never resumed after [\(Self.describe(history))]")
            case .budgetExhausted(let states):
                XCTFail("\(fault): state budget exhausted at \(states) states")
            }
        }
    }

    /// Cleanup alone shows no fault. A history that only begins, or waits, leaves operations
    /// open, and cleanup ends them on the real lane around every injected fault, so each one
    /// conforms with nothing left unresumed. Without the bypass, `dropEnd` would fail here at
    /// one begin.
    func testCleanupEndsWhatAHistoryLeavesOpenAroundEveryInjectedFault() async {
        var coverage = Coverage()
        let histories: [[LifecycleCommand]] = [
            [.begin(.start, coalescing: true)],
            [.begin(.stop, coalescing: true), .waitUntilIdle],
        ]
        for fault in LifecycleFault.allCases {
            for history in histories {
                let replay = await replayHistory(history, fault: fault, &coverage)
                XCTAssertEqual(replay.unresumed, 0, "\(fault) after [\(Self.describe(history))]")
                if case .failure(let divergence) = replay.result {
                    XCTFail("\(fault): cleanup diverged, not the history: \(divergence)")
                }
            }
        }
    }

    /// A divergence with a join still pending ends the operation the lane holds,
    /// awaits the join and reports the divergence. Without the release this
    /// test would hang on the join.
    func testADivergenceReleasesEveryTaskItOwns() async {
        var coverage = Coverage()
        let history: [LifecycleCommand] = [
            .begin(.start, coalescing: true), .begin(.start, coalescing: true), .end(index: 0),
        ]
        let replay = await replayHistory(history, fault: .dropEnd, &coverage)
        XCTAssertEqual(replay.unresumed, 0, "the release left a join or idle wait unresumed")
        guard case .failure(let divergence) = replay.result else {
            return XCTFail("the dropped end was not caught")
        }
        XCTAssertEqual(divergence.history.count, 3)
        XCTAssertTrue(divergence.problem.contains("isIdle"), divergence.problem)
    }

    // MARK: - Exploration

    private func explore(fault: LifecycleFault?) async -> Exploration {
        var coverage = Coverage()
        var visited: Set<LifecycleModel.Key> = [LifecycleModel().key]
        var frontier: [[LifecycleCommand]] = [[]]
        var replays = 0
        for _ in 0..<maxDepth {
            var next: [[LifecycleCommand]] = []
            for history in frontier {
                for command in enabledCommands(after: history) {
                    let candidate = history + [command]
                    replays += 1
                    let replay = await replayHistory(candidate, fault: fault, &coverage)
                    if replay.unresumed > 0 { return .leaked(replay.unresumed, after: candidate) }
                    switch replay.result {
                    case .failure(let divergence):
                        return .diverged(divergence)
                    case .success(let key):
                        if visited.insert(key).inserted { next.append(candidate) }
                    }
                }
            }
            if visited.count > maxStates { return .budgetExhausted(states: visited.count) }
            frontier = next
        }
        return .conforms(states: visited.count, histories: replays, coverage: coverage, newAtBound: frontier.count)
    }

    private func enabledCommands(after history: [LifecycleCommand]) -> [LifecycleCommand] {
        var model = LifecycleModel()
        for command in history { _ = model.apply(command) }
        return enabledCommands(model)
    }

    private func enabledCommands(_ model: LifecycleModel) -> [LifecycleCommand] {
        var commands: [LifecycleCommand] = []
        for kind in [LifecycleLane.Kind.start, .stop] {
            for coalescing in [true, false] where model.held.count < maxHeld || model.coalesces(kind, coalescing: coalescing) {
                commands.append(.begin(kind, coalescing: coalescing))
            }
        }
        for index in model.held.indices { commands.append(.end(index: index)) }
        commands.append(.supersedeAll)
        if model.idleWaiting < maxWaiters { commands.append(.waitUntilIdle) }
        return commands
    }

    /// What one history did: the first disagreement with the model, if any, and
    /// how many joins and idle waits the lane still owed after the release.
    private struct Replay {
        let result: Result<LifecycleModel.Key, LifecycleDivergence>
        let unresumed: Int
    }

    /// Runs `history` on a fresh lane and attempts release on both passing and
    /// diverging paths. Passing and injected-fault histories join their owned tasks;
    /// a corrupt production continuation is reported as unresumed rather than awaited forever.
    private func replayHistory(
        _ history: [LifecycleCommand],
        fault: LifecycleFault?,
        _ coverage: inout Coverage
    ) async -> Replay {
        var model = LifecycleModel()
        let driver = LifecycleDriver(fault: fault)
        var failure: LifecycleDivergence?
        for (step, command) in history.enumerated() {
            let idleBefore = model.idleWaiting
            let joinsBefore = model.joinersResumed
            switch command {
            case .begin(let kind, let coalescing):
                if model.coalesces(kind, coalescing: coalescing) { coverage.coalesced = true }
                if !coalescing, model.running, model.kind == kind { coverage.forcedNewWhileRunning = true }
            case .supersedeAll:
                if !model.held.isEmpty { coverage.supersededWhileHeld = true }
            case .end, .waitUntilIdle:
                break
            }
            let expected = model.apply(command)
            let observed = driver.perform(command)
            let reached = Array(history.prefix(step + 1))
            if observed != expected {
                failure = LifecycleDivergence(
                    history: reached,
                    problem: "\(command) admitted \(String(describing: observed)), the model says \(String(describing: expected))"
                )
                break
            }
            await driver.settle { compare(model, driver) == nil }
            if let problem = compare(model, driver) {
                failure = LifecycleDivergence(history: reached, problem: problem)
                break
            }
            if model.joinersResumed > joinsBefore { coverage.joinerResumed = true }
            if case .end = command, idleBefore > 0, model.idleWaiting == 0 { coverage.idleWaiterResumed = true }
            for token in driver.issued where token.isSuperseded && model.held.contains(token.generation) {
                coverage.staleTokenHeld = true
            }
        }
        let result: Result<LifecycleModel.Key, LifecycleDivergence>
        if let failure {
            result = .failure(failure)
        } else {
            // The key is the state the history reached. Teardown ends what is still
            // in flight, which would collapse every history onto one quiet state.
            let endState = model.key
            if let problem = await teardown(&model, driver) {
                result = .failure(LifecycleDivergence(history: history, problem: "teardown: \(problem)"))
            } else {
                result = .success(endState)
            }
        }
        return Replay(result: result, unresumed: await driver.release())
    }

    /// Compares every observable the model predicts. Returns the first disagreement.
    private func compare(_ model: LifecycleModel, _ driver: LifecycleDriver) -> String? {
        let lane = driver.lane
        if lane.current != model.latest {
            return "the latest generation is \(lane.current), the model says \(model.latest)"
        }
        if lane.isIdle != model.held.isEmpty {
            return "isIdle is \(lane.isIdle) with \(model.held.count) operations in flight"
        }
        if lane.idleWaiterCount != model.idleWaiting {
            return "\(lane.idleWaiterCount) idle waiters, the model says \(model.idleWaiting)"
        }
        if lane.joinerCount != model.joined.count {
            return "\(lane.joinerCount) joined callers, the model says \(model.joined.count)"
        }
        if driver.joinersResumed != model.joinersResumed {
            return "\(driver.joinersResumed) joins resumed, the model says \(model.joinersResumed)"
        }
        if driver.idleResumed != model.idleResumed {
            return "\(driver.idleResumed) idle waits resumed, the model says \(model.idleResumed)"
        }
        if driver.held.map(\.generation) != model.held {
            return "operations in flight are \(driver.held.map(\.generation)), the model says \(model.held)"
        }
        for token in driver.issued {
            let superseded = token.generation != model.latest
            if token.isSuperseded != superseded {
                return "token \(token.generation) isSuperseded is \(token.isSuperseded), the model says \(superseded)"
            }
        }
        return nil
    }

    /// Ends whatever is still in flight, then checks that every join and idle wait
    /// has resumed and the lane is quiet. Runs only on a history that did not diverge.
    /// Cleanup is not part of the explored alphabet: its ends go to the production lane
    /// directly, around the injected adapter faults, so a fault shows only where the
    /// history's own commands reach it, and the printed witness is the history alone.
    private func teardown(_ model: inout LifecycleModel, _ driver: LifecycleDriver) async -> String? {
        while !driver.held.isEmpty {
            _ = model.apply(.end(index: 0))
            driver.endUnfaulted(index: 0)
            await driver.settle { compare(model, driver) == nil }
            if let problem = compare(model, driver) { return problem }
        }
        if !model.joined.isEmpty || model.idleWaiting != 0 {
            return "the model still expects \(model.joined.count) joined callers and \(model.idleWaiting) idle waiters"
        }
        await driver.settle { compare(model, driver) == nil }
        return compare(model, driver)
    }

    private static func describe(_ history: [LifecycleCommand]) -> String {
        history.map(\.description).joined(separator: ", ")
    }
}

// MARK: - Model, commands and driver

/// One step of a history: the alphabet the exploration draws from.
private enum LifecycleCommand: Hashable, CustomStringConvertible {
    case begin(LifecycleLane.Kind, coalescing: Bool)
    /// Ends the operation at this position among those still in flight, oldest first.
    case end(index: Int)
    /// A quit: supersedes whatever is in flight without starting anything.
    case supersedeAll
    case waitUntilIdle

    var description: String {
        switch self {
        case .begin(let kind, let coalescing): "begin(\(kind.rawValue), coalescing: \(coalescing))"
        case .end(let index): "end(\(index))"
        case .supersedeAll: "supersedeAll"
        case .waitUntilIdle: "waitUntilIdle"
        }
    }
}

/// The specification. Plain values, written from the lane's contract: a begin
/// joins the operation in flight only when it asks to coalesce and the latest
/// operation is running and of its kind; otherwise it becomes the latest. An end
/// releases the latest generation's running flag only if that operation is the
/// latest one. A supersede advances the latest generation and forgets its kind.
private struct LifecycleModel {
    /// What a future command depends on. The resumption counts are cumulative
    /// and do not change what happens next, so they stay out of the key.
    struct Key: Hashable {
        var latest: Int
        var kind: LifecycleLane.Kind?
        var running: Bool
        var held: [Int]
        var joined: [Int]
        var idleWaiting: Int
    }

    enum Admission: Equatable {
        case run(generation: Int)
        case coalesced(joining: Int)
    }

    var latest = 0
    var kind: LifecycleLane.Kind?
    var running = false
    /// Generations of the operations in flight, oldest first.
    var held: [Int] = []
    /// One entry per caller waiting for that generation to end.
    var joined: [Int] = []
    var idleWaiting = 0
    var joinersResumed = 0
    var idleResumed = 0

    var key: Key {
        Key(latest: latest, kind: kind, running: running, held: held, joined: joined, idleWaiting: idleWaiting)
    }

    func coalesces(_ kind: LifecycleLane.Kind, coalescing: Bool) -> Bool {
        coalescing && self.kind == kind && running
    }

    /// Applies a command and returns what a begin must have admitted.
    mutating func apply(_ command: LifecycleCommand) -> Admission? {
        switch command {
        case .begin(let kind, let coalescing):
            if coalesces(kind, coalescing: coalescing) {
                joined.append(latest)
                return .coalesced(joining: latest)
            }
            latest += 1
            self.kind = kind
            running = true
            held.append(latest)
            return .run(generation: latest)
        case .end(let index):
            let generation = held.remove(at: index)
            if generation == latest { running = false }
            let resumed = joined.filter { $0 == generation }.count
            joined.removeAll { $0 == generation }
            joinersResumed += resumed
            if held.isEmpty {
                idleResumed += idleWaiting
                idleWaiting = 0
            }
            return nil
        case .supersedeAll:
            latest += 1
            kind = nil
            running = false
            return nil
        case .waitUntilIdle:
            if held.isEmpty {
                idleResumed += 1
            } else {
                idleWaiting += 1
            }
            return nil
        }
    }
}

private struct LifecycleDivergence: Error, CustomStringConvertible {
    let history: [LifecycleCommand]
    let problem: String

    var description: String {
        "after [\(history.map(\.description).joined(separator: ", "))]: \(problem)"
    }
}

/// An injected fault in the driver's adapter around the production lane. The lane
/// is the real type and is not changed; each fault perturbs one call or one thing
/// the driver keeps, so the model has to notice.
private enum LifecycleFault: CaseIterable, Hashable {
    /// A quit that never reaches the lane, so operations in flight stay current.
    case skipSupersedeAll
    /// Every begin is forwarded as forced, so a same-kind duplicate queues its own work.
    case forceNoncoalescing
    /// A coalesced caller is never registered with the lane, so nothing wakes it.
    case skipJoin
    /// The caller's end never reaches the lane, so the operation stays open in it.
    /// Cleanup and release bypass this, so it shows only through the history's own ends.
    case dropEnd
}

/// Runs commands on one production lane. Joins and idle waits run as tasks on the
/// main actor; `settle` lets them run, and `release` ends what is open and awaits
/// what it owns.
@MainActor
private final class LifecycleDriver {
    let lane = LifecycleLane(name: "model")
    private let fault: LifecycleFault?
    /// Every token issued, for the stale-or-current check.
    private(set) var issued: [LifecycleLane.Token] = []
    /// Operations the caller still holds, oldest first, parallel to the model's `held`.
    private(set) var held: [LifecycleLane.Token] = []
    /// Operations the lane admitted and the driver has not ended. A dropped end
    /// leaves its token here, so the release can still end it.
    private var open: [LifecycleLane.Token] = []
    private(set) var joinersResumed = 0
    private(set) var idleResumed = 0
    private var joinsMade = 0
    private var idleWaitsMade = 0
    private var tasks: [Task<Void, Never>] = []

    init(fault: LifecycleFault?) {
        self.fault = fault
    }

    /// Joins and idle waits the lane owes that have not resumed.
    var unresumed: Int {
        (joinsMade - joinersResumed) + (idleWaitsMade - idleResumed)
    }

    /// Performs a command on the lane and returns what a begin admitted.
    func perform(_ command: LifecycleCommand) -> LifecycleModel.Admission? {
        switch command {
        case .begin(let kind, let coalescing):
            switch lane.begin(kind, coalescing: fault == .forceNoncoalescing ? false : coalescing) {
            case .run(let token):
                issued.append(token)
                held.append(token)
                open.append(token)
                return .run(generation: token.generation)
            case .coalesced(let generation):
                if fault != .skipJoin {
                    joinsMade += 1
                    tasks.append(Task {
                        await self.lane.join(generation)
                        self.joinersResumed += 1
                    })
                }
                return .coalesced(joining: generation)
            }
        case .end(let index):
            let token = held.remove(at: index)
            guard fault != .dropEnd else { return nil }
            lane.end(token)
            open.removeAll { $0.generation == token.generation }
            return nil
        case .supersedeAll:
            guard fault != .skipSupersedeAll else { return nil }
            lane.supersedeAll()
            return nil
        case .waitUntilIdle:
            idleWaitsMade += 1
            tasks.append(Task {
                await self.lane.waitUntilIdle()
                self.idleResumed += 1
            })
            return nil
        }
    }

    /// Ends the operation at `index` on the production lane, bypassing any injected
    /// adapter fault. Only cleanup calls it: an explored `end` goes through `perform`.
    func endUnfaulted(index: Int) {
        let token = held.remove(at: index)
        lane.end(token)
        open.removeAll { $0.generation == token.generation }
    }

    /// Lets the joins and idle waits run until `ready` holds. Bounded by a count of
    /// yields: a lane that never gets there is reported by `compare`, not waited on.
    func settle(until ready: () -> Bool) async {
        var rounds = 0
        while !ready(), rounds < 1_000 {
            rounds += 1
            await Task.yield()
        }
    }

    /// Ends every operation the lane still has open, whatever the caller did, so each
    /// join and idle wait the lane owes resumes. Then lets them run, and awaits them
    /// only once they have all resumed. Returns how many have not: those are left
    /// unawaited, because they are parked on a continuation nothing will resume.
    func release() async -> Int {
        for token in open { lane.end(token) }
        open.removeAll()
        held.removeAll()
        await settle { unresumed == 0 }
        guard unresumed == 0 else { return unresumed }
        for task in tasks { await task.value }
        return 0
    }
}

/// A small deterministic generator, so a seed names a history.
private struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
