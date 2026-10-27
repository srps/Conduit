// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import PlatformMac
import ProxyKernel
import RuntimeEvents
import XCTest
@testable import ConduitRuntime

/// A bounded model of the configuration workflow's physical ordering (decisions 0015, 0025, 0027 and 0033). The actual
/// `RuntimeConfigurationWorkflow` and `ConfigurationStore` run over a fake `StateFileAccessing`, a real writer lease on one scratch root and
/// an injected `PlatformWork` queue. The test chooses newer intents (Start or Stop) at named boundary points, and the reference below predicts
/// the physical calls, the typed results, the stored bytes and the apply eligibility from the declared trace alone.
///
/// Boundary points, in order: `beforeOperation` (before the operation starts or its capture), `queued` (the first PlatformWork job is queued
/// behind a blocker), and for each physical file call n, `entry(n)` and `exit(n)`. A write job's claim check sits immediately before its
/// replacement's first call, so an admission there revokes the job; an admission after that call does not (decision 0015). An absent
/// sidecar's job reads its runtime source first, so an admission at that read's points still revokes it.
///
/// Explored alphabet: 4 prepare scenarios and 3 reload scenarios; 4 write faults per write job; up to 2 newer intents at one point each,
/// BFS-ordered by depth, with the full fault product only at depths 0 and 1 (depth 2 uses the fault-free case), plus a fixed-seed walk of up
/// to 4 intents. Every run ends with a second Start that resumes from the state the first run left, so unknown latches are checked as
/// holding apply. Coverage counts are asserted, so a silently shrunk exploration fails.
///
/// Scope: store I/O and returned apply eligibility, including the absent sidecar's source read. Not modeled: the real host's apply, launch
/// recovery, legacy sidecar preservation, a changed source (covered by `ConfigurationStoreSourceTests` and the store models), and the
/// preferences commit. The reference does not reuse production transition code.
@MainActor
final class ConfigurationWorkflowModelTests: XCTestCase {
    // MARK: - Trace vocabulary

    private enum Point: Hashable, Comparable {
        case beforeOperation
        case queued
        case entry(Int)
        case exit(Int)

        /// Total order used by the explorer: admissions are placed at reachable points in this order.
        private var rank: Int {
            switch self {
            case .beforeOperation: 0
            case .queued: 1
            case .entry(let n): 2 + 2 * (n - 1)
            case .exit(let n): 3 + 2 * (n - 1)
            }
        }

        static func < (lhs: Point, rhs: Point) -> Bool { lhs.rank < rhs.rank }
    }

    private struct Admission: Equatable {
        let point: Point
        let start: Bool
    }

    private enum Scenario: CaseIterable {
        /// No files on disk. Start commits both defaults before it is ready.
        case absent
        /// Both files present and canonical. Start verifies them without rewriting.
        case canonical
        /// Runtime present and canonical, platform absent. Start writes the platform only.
        case platformAbsent
        /// Runtime carries a start-blocking port. Start and reload hold before any I/O.
        case invalidRuntime
    }

    private enum Fault: CaseIterable {
        case none
        case failsBeforeLanding
        case landsThenFails
        case externalAfterWrite
    }

    /// Where a file's bytes stand, as the reference tracks them.
    private enum Stored: Equatable {
        case absent
        case canonical
        case external
    }

    /// One physical call the reference expects, in order.
    private struct Call: Equatable {
        let file: ConfigurationComponent
        let write: Bool
    }

    // MARK: - Reference

    /// The reference's own state: what each file holds, and whether a write latched it (an unknown outcome or an external change).
    private struct State {
        var stored = ConfigurationSlots(runtime: Stored.canonical, platform: Stored.canonical, preferences: Stored.canonical)
        var latched = ConfigurationSlots(runtime: false, platform: false, preferences: false)
    }

    private enum Preparation: Equatable {
        case ready, held, superseded
    }

    /// The expected result of one operation, computed from the declared trace alone.
    private struct Expected {
        var preparation = Preparation.held
        var runtime: ConfigurationWorkflowWrite?
        var platform: ConfigurationWorkflowWrite?
        var calls: [Call] = []
        var points: [Point] = []
        var applied = false
        var state = State()
    }

    /// Walks one prepare operation under the declared admissions. It applies the admissions at their points and evaluates each claim where
    /// the store does, so the points it returns are the ones a real run must reach.
    private func walkPrepare(
        _ scenario: Scenario,
        faults: (platform: Fault, runtime: Fault),
        from initial: State,
        admissions: [Admission]
    ) -> Expected {
        var walk = Walker(admissions: admissions)
        var expected = Expected()
        expected.state = initial
        walk.at(.beforeOperation)
        guard walk.isCurrent else {
            expected.preparation = .superseded
            expected.points = walk.points
            return expected
        }
        if scenario == .invalidRuntime {
            expected.preparation = .held
            expected.points = walk.points
            return expected
        }
        walk.at(.queued)
        // Authority is decided for both files before any I/O (a latched file has no baseline).
        let runtimeAuthorized = !initial.latched.runtime
        let platformAuthorized = !initial.latched.platform
        if !runtimeAuthorized || !platformAuthorized {
            // The store refuses an unauthorized file with its own reason. The authorized one is held behind it, with no I/O.
            expected.runtime = runtimeAuthorized ? .notAttempted(.heldBehindPlatform) : .notAttempted(.noBaseline)
            expected.platform = platformAuthorized ? .notAttempted(.heldBehindRuntime) : .notAttempted(.noBaseline)
            return finish(&expected, walk: walk)
        }
        let platformOutcome = runFile(.platform, fault: faults.platform, scenario: scenario, state: &expected.state, walk: &walk, calls: &expected.calls)
        expected.platform = platformOutcome
        if !platformOutcome.isVerified {
            expected.runtime = .notAttempted(.heldBehindPlatform)
            return finish(&expected, walk: walk)
        }
        expected.runtime = runFile(.runtime, fault: faults.runtime, scenario: scenario, state: &expected.state, walk: &walk, calls: &expected.calls)
        return finish(&expected, walk: walk)
    }

    /// One file's step. A canonical present file is verified by a read, without a claim. An absent file, or a file the scenario makes absent,
    /// is written: its claim is checked before its first call, and its read-back classifies the fault. An absent sidecar's job first reads
    /// the runtime file it takes its values from, so its claim is checked after that read. No trace edits the runtime file before the
    /// sidecar's write, so the read always matches.
    private func runFile(
        _ file: ConfigurationComponent,
        fault: Fault,
        scenario: Scenario,
        state: inout State,
        walk: inout Walker,
        calls: inout [Call]
    ) -> ConfigurationWorkflowWrite {
        let absent = state.stored[file] == .absent
        if !absent {
            walk.call(file, write: false, into: &calls)
            return .unchanged
        }
        if file != .runtime {
            walk.call(.runtime, write: false, into: &calls)
        }
        guard walk.isCurrent else { return .notAttempted(.superseded) }
        walk.call(file, write: false, into: &calls)
        walk.call(file, write: true, into: &calls)
        walk.call(file, write: false, into: &calls)
        switch fault {
        case .none:
            state.stored[file] = .canonical
            return .persisted(reportedError: false)
        case .failsBeforeLanding:
            return .notPersisted
        case .landsThenFails:
            state.stored[file] = .canonical
            return .persisted(reportedError: true)
        case .externalAfterWrite:
            state.stored[file] = .external
            state.latched[file] = true
            return .unknown(.readbackDiffers, reportedError: false)
        }
    }

    private func finish(_ expected: inout Expected, walk: Walker) -> Expected {
        expected.points = walk.points
        if expected.preparation != .superseded {
            let verified = expected.runtime?.isVerified == true && expected.platform?.isVerified == true
            expected.preparation = walk.isCurrent && verified ? .ready : (walk.isCurrent ? .held : .superseded)
        }
        expected.applied = expected.preparation == .ready
        return expected
    }

    /// The admissions applied in order, with the generation and fence they produce. A claim is current while the ticket is the latest and no
    /// Stop fence is in force. A Stop sets the fence; a Start admission leaves it, since only an authorized Start clears it (decision 0035)
    /// and these walks authorize none.
    private struct Walker {
        private let admissions: [Admission]
        private var next = 0
        private(set) var generation: Int
        private(set) var fenced = false
        private(set) var points: [Point] = []
        private var callCount = 0

        init(admissions: [Admission], generation: Int = 1) {
            self.admissions = admissions
            self.generation = generation
        }

        var isCurrent: Bool { generation == 1 && !fenced }

        /// Visits a point and applies the admissions placed there.
        mutating func at(_ point: Point) {
            points.append(point)
            while next < admissions.count, admissions[next].point == point {
                generation += 1
                if !admissions[next].start { fenced = true }
                next += 1
            }
        }

        /// One physical call: its entry and exit points, and the call itself.
        mutating func call(_ file: ConfigurationComponent, write: Bool, into calls: inout [Call]) {
            callCount += 1
            at(.entry(callCount))
            calls.append(Call(file: file, write: write))
            at(.exit(callCount))
        }
    }

    // MARK: - Driver

    /// Parks the worker at the armed points until the driver releases it. Every wait is bounded, so a failed expectation never holds the root.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed: Set<Point> = []
        private var parkedAt: Point?
        private var timedOutFlag = false
        private let reachedSignal = DispatchSemaphore(value: 0)
        private let releaseSignal = DispatchSemaphore(value: 0)

        func arm(_ points: Set<Point>) {
            lock.withLock { armed = points }
        }

        /// Called on the worker. It parks only at an armed point, then waits for release, with a bound.
        func park(_ point: Point) {
            let shouldPark = lock.withLock { () -> Bool in
                guard armed.contains(point) else { return false }
                armed.remove(point)
                parkedAt = point
                return true
            }
            guard shouldPark else { return }
            reachedSignal.signal()
            if releaseSignal.wait(timeout: .now() + 10) == .timedOut {
                lock.withLock { timedOutFlag = true }
            }
        }

        /// Whether a park waited out its bound instead of being released. A true value fails the trace.
        var timedOut: Bool { lock.withLock { timedOutFlag } }

        /// The point the worker parked at, after `awaitReached` returned true.
        var reached: Point? { lock.withLock { parkedAt } }

        func awaitReached() async -> Bool {
            await Self.wait(reachedSignal, seconds: 5)
        }

        func release() {
            lock.withLock { parkedAt = nil }
            releaseSignal.signal()
        }

        var isParked: Bool { lock.withLock { parkedAt != nil } }

        static func wait(_ semaphore: DispatchSemaphore, seconds: Double) async -> Bool {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().async {
                    continuation.resume(returning: semaphore.wait(timeout: .now() + seconds) == .success)
                }
            }
        }
    }

    /// Wraps the real fake and parks at the gate's armed points. The call counter gives each physical call its ordinal.
    private final class ModelFiles: StateFileAccessing, @unchecked Sendable {
        let inner: FakeStateFileAccess
        let gate: Gate
        private let lock = NSLock()
        private var calls = 0

        init(files: [String: Data], gate: Gate) {
            inner = FakeStateFileAccess(files: files)
            self.gate = gate
        }

        private func enter() -> Int {
            lock.withLock { calls += 1; return calls }
        }

        /// Starts an operation's count: its ordinals restart at one, and the fake's observations are cleared.
        func beginOperation() {
            lock.withLock { calls = 0 }
            inner.clearObservations()
        }

        func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
            let n = enter()
            gate.park(.entry(n))
            let result = inner.readConfigurationFile(file, limit: limit)
            gate.park(.exit(n))
            return result
        }

        func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
            let n = enter()
            gate.park(.entry(n))
            let result = inner.replaceConfigurationFile(file, bytes: bytes)
            gate.park(.exit(n))
            return result
        }

        func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
            inner.entryPresence(file)
        }
    }

    // MARK: - Seeds and scripts

    private static let externalBytes = Data("external edit".utf8)

    private func initialState(_ scenario: Scenario) -> State {
        var state = State()
        switch scenario {
        case .absent: state.stored = ConfigurationSlots(runtime: .absent, platform: .absent, preferences: .absent)
        case .platformAbsent: state.stored.platform = .absent
        case .canonical, .invalidRuntime: break
        }
        return state
    }

    /// The files a scenario starts with. Bytes come from the production stagers, so the model never copies a parser or a writer.
    private func seeds(_ scenario: Scenario, _ session: StateRootSession) throws -> [String: Data] {
        var files: [String: Data] = [:]
        var runtime = GenericDefaults.shared.makeConfig()
        if scenario == .invalidRuntime { runtime.proxy.port = 70_000 }
        if scenario != .absent {
            files[session.configurationFile(for: .runtime).path] = try ProxyConfigPersistence.stagedFileData(for: runtime)
        }
        if scenario == .canonical || scenario == .invalidRuntime {
            files[session.configurationFile(for: .platform).path] = try PlatformConfigPersistence.stagedData(for: PlatformIntegrationConfig())
        }
        return files
    }

    private func script(_ fault: Fault) -> FakeStateFileAccess.WriteScript {
        switch fault {
        case .none: FakeStateFileAccess.WriteScript(landing: .lands)
        case .failsBeforeLanding: FakeStateFileAccess.WriteScript(landing: .failsBeforeLanding(errno: 5))
        case .landsThenFails: FakeStateFileAccess.WriteScript(landing: .landsThenFails(errno: 5))
        case .externalAfterWrite: FakeStateFileAccess.WriteScript(landing: .lands, editAfterWrite: .replace(Self.externalBytes))
        }
    }

    /// The fault pairs a scenario explores. Only a platform write and a runtime write can fault. A scenario with one write explores the
    /// platform's faults alone.
    private func faultPairs(_ scenario: Scenario) -> [(Fault, Fault)] {
        var pairs: [(Fault, Fault)] = []
        for platform in Fault.allCases {
            switch scenario {
            case .absent:
                for runtime in Fault.allCases { pairs.append((platform, runtime)) }
            case .platformAbsent:
                pairs.append((platform, .none))
            case .canonical, .invalidRuntime:
                if platform == .none { pairs.append((.none, .none)) }
            }
        }
        return pairs
    }

    // MARK: - Reference for reload

    private struct ReloadExpected {
        var points: [Point]
        var calls: [Call]
        var stale: Bool
        var fenced: Bool
        var applied: Bool
        var preferencesAdopted: Bool
    }

    /// Reload is a read of three files. A newer intent at any point makes it stale, so it applies nothing and adopts no preferences. A Stop
    /// before the capture holds the apply without staleness, and a missing or refused input holds it too.
    private func walkReload(_ scenario: Scenario, admissions: [Admission]) -> ReloadExpected {
        var walk = Walker(admissions: admissions, generation: 0)
        walk.at(.beforeOperation)
        let captured = walk.generation
        walk.at(.queued)
        var calls: [Call] = []
        for file in [ConfigurationComponent.runtime, .platform, .preferences] {
            walk.call(file, write: false, into: &calls)
        }
        let stale = walk.generation != captured
        let runtimePresent = scenario != .absent
        let platformPresent = scenario != .absent && scenario != .platformAbsent
        let applied = !stale && !walk.fenced && runtimePresent && platformPresent && scenario != .invalidRuntime
        return ReloadExpected(
            points: walk.points,
            calls: calls,
            stale: stale,
            fenced: walk.fenced,
            applied: applied,
            preferencesAdopted: !stale
        )
    }

    // MARK: - Driver

    private struct Harness {
        let session: StateRootSession
        let gate: Gate
        let files: ModelFiles
        let queue: PlatformWork
        let store: ConfigurationStore
        let workflow: RuntimeConfigurationWorkflow
    }

    private func harness(_ root: ModelRoot, _ scenario: Scenario) throws -> Harness {
        let gate = Gate()
        let files = ModelFiles(files: try seeds(scenario, root.session), gate: gate)
        let queue = PlatformWork(label: "test.workflow-model")
        let store = ConfigurationStore(session: root.session, access: files, work: queue)
        return Harness(
            session: root.session,
            gate: gate,
            files: files,
            queue: queue,
            store: store,
            workflow: RuntimeConfigurationWorkflow(store: store, incarnation: ControlHostIncarnation(rawValue: UUID()), startupAllowsMissing: true)
        )
    }

    /// Waits, bounded, until the in-flight operation has begun on the MainActor. It yields, and never sleeps.
    private func awaitInFlight(_ workflow: RuntimeConfigurationWorkflow) async -> Bool {
        for _ in 0..<200 {
            if !workflow.isIdle { return true }
            await Task.yield()
        }
        return false
    }

    /// A newer Start admitted while its slot is busy must hold as `storeBusy` with no capture and no I/O (decision 0037). Its ticket is
    /// the admission the trace declared.
    private func busyRefusal(_ h: Harness, _ ticket: RuntimeConfigurationWorkflow.StartTicket) async -> String? {
        let before = h.files.inner.observations.count
        let outcome = await h.workflow.prepareStart(ticket)
        let held = ConfigurationWorkflowEvent.held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .storeBusy))
        guard case .held = outcome.preparation, outcome.events == [held], h.files.inner.observations.count == before else {
            return "a newer Start while the slot is busy must hold as store_busy without I/O"
        }
        counts["busy.refused", default: 0] += 1
        return nil
    }

    /// Applies the admissions at their points while `operation` runs. It returns the operation's value and the first problem found. Every
    /// path releases the gate and awaits the operation and its blocker before it returns, so no failure holds the root.
    private func gated<T: Sendable>(
        _ h: Harness,
        admissions: [Admission],
        busyChecks: Bool,
        operation: @escaping @MainActor () async -> T
    ) async -> (value: T?, problem: String?) {
        let pending = admissions.filter { $0.point != .beforeOperation }
        h.gate.arm(Set(pending.map(\.point)))
        var problem: String?
        var blocker: Task<Void, Never>?
        let gate = h.gate
        let queue = h.queue
        if pending.contains(where: { $0.point == .queued }) {
            blocker = Task { await queue.run { gate.park(.queued) } }
            let reached = await gate.awaitReached()
            if reached, gate.reached == .queued {
                counts["queued.reached", default: 0] += 1
            } else {
                problem = "the queued point was not reached"
            }
        }
        let task: Task<T, Never>? = problem == nil ? Task { await operation() } : nil
        var index = 0
        while problem == nil, index < pending.count {
            let point = pending[index].point
            var flags: [Bool] = []
            while index < pending.count, pending[index].point == point {
                flags.append(pending[index].start)
                index += 1
            }
            if point == .queued {
                guard await awaitInFlight(h.workflow) else {
                    problem = "the operation never began before the queued admission"
                    break
                }
            } else {
                guard await gate.awaitReached(), gate.reached == point else {
                    problem = "the \(point) boundary was not reached"
                    break
                }
                guard !h.workflow.isIdle else {
                    problem = "the operation was idle at \(point) while parked"
                    break
                }
            }
            for start in flags {
                if start {
                    guard case .success(let ticket) = h.workflow.admitStart() else {
                        problem = "a newer Start was not admitted"
                        break
                    }
                    if busyChecks, let text = await busyRefusal(h, ticket) {
                        problem = text
                        break
                    }
                } else {
                    h.workflow.admitStop()
                }
            }
            if problem != nil { break }
            gate.release()
        }
        if gate.isParked { gate.release() }
        let value = await task?.value
        await blocker?.value
        if gate.timedOut { problem = problem ?? "a gate waited out its bound and was released by the timeout" }
        return (value, problem)
    }

    private func component(of path: String, _ session: StateRootSession) -> ConfigurationComponent? {
        ConfigurationComponent.allCases.first { session.configurationFile(for: $0).path == path }
    }

    /// The physical calls the fake observed, mapped to the component each one named.
    private func observedCalls(_ h: Harness) -> [Call] {
        h.files.inner.observations.compactMap { (observation) -> Call? in
            switch observation {
            case .read(let path, _):
                return component(of: path, h.session).map { Call(file: $0, write: false) }
            case .write(let path, _):
                return component(of: path, h.session).map { Call(file: $0, write: true) }
            }
        }
    }

    private func storedMatches(_ file: ConfigurationComponent, _ stored: Stored, _ h: Harness) -> Bool {
        let bytes = h.files.inner.storedBytes(at: h.session.configurationFile(for: file).path)
        switch stored {
        case .absent: return bytes == nil
        case .canonical: return bytes != nil
        case .external: return bytes == Self.externalBytes
        }
    }

    private func kind(_ preparation: RuntimeConfigurationWorkflow.StartPreparation) -> Preparation {
        switch preparation {
        case .ready: .ready
        case .held: .held
        case .superseded: .superseded
        }
    }

    private func committedEvents(_ events: [ConfigurationWorkflowEvent]) -> [ConfigurationWorkflowEvent] {
        events.filter { event in
            if case .committed = event { return true }
            return false
        }
    }

    private func comparePrepare(
        _ label: String,
        _ outcome: RuntimeConfigurationWorkflow.StartOutcome,
        _ opened: RuntimeConfigurationWorkflow.Opened,
        expected: Expected,
        calls: [Call],
        _ h: Harness
    ) -> String? {
        let observed = kind(outcome.preparation)
        if observed != expected.preparation {
            return "\(label): preparation \(observed) but the reference expects \(expected.preparation)"
        }
        if case .ready(let prepared) = outcome.preparation,
           prepared.input.runtime != opened.config || prepared.input.platform != opened.platformConfig {
            return "\(label): the apply input is not the verified staged pair"
        }
        var expectedCommitted: [ConfigurationWorkflowEvent] = []
        if let runtime = expected.runtime, let platform = expected.platform {
            expectedCommitted = [
                .committed(ConfigurationWorkflowCommitted(file: .runtime, write: runtime)),
                .committed(ConfigurationWorkflowCommitted(file: .platform, write: platform)),
            ]
        }
        let committed = committedEvents(outcome.events)
        if committed != expectedCommitted {
            return "\(label): committed \(committed) but the reference expects \(expectedCommitted)"
        }
        if calls != expected.calls {
            return "\(label): physical calls \(calls) but the reference expects \(expected.calls)"
        }
        for file in [ConfigurationComponent.runtime, .platform] where !storedMatches(file, expected.state.stored[file], h) {
            return "\(label): the stored \(file) does not match the reference"
        }
        return nil
    }

    private func describe(_ trace: Trace) -> String {
        let history = trace.admissions.map { "\($0.point)\($0.start ? "+start" : "+stop")" }.joined(separator: ", ")
        let mode = trace.reload ? "reload" : "prepare"
        return "\(mode) \(trace.scenario) faults=\(trace.platformFault)/\(trace.runtimeFault) admissions=[\(history)]"
    }

    // MARK: - Runs

    private func runPrepare(_ trace: Trace, _ root: ModelRoot) async -> String? {
        let label = describe(trace)
        let h: Harness
        do {
            h = try harness(root, trace.scenario)
        } catch {
            return "\(label): the fixture could not seed: \(error)"
        }
        let expected = walkPrepare(
            trace.scenario,
            faults: (trace.platformFault, trace.runtimeFault),
            from: initialState(trace.scenario),
            admissions: trace.admissions
        )
        let opened: RuntimeConfigurationWorkflow.Opened
        do {
            opened = try await h.workflow.open()
        } catch {
            return "\(label): open refused: \(error)"
        }
        h.files.beginOperation()
        h.files.inner.scheduleWrites([script(trace.platformFault), script(trace.runtimeFault)])
        guard case .success(let ticket) = h.workflow.admitStart() else { return "\(label): the first Start was not admitted" }
        for admission in trace.admissions where admission.point == .beforeOperation {
            if admission.start {
                _ = h.workflow.admitStart()
            } else {
                h.workflow.admitStop()
            }
        }
        let workflow = h.workflow
        let first = await gated(h, admissions: trace.admissions, busyChecks: true) { await workflow.prepareStart(ticket) }
        if let problem = first.problem { return "\(label): \(problem)" }
        guard let outcome = first.value else { return "\(label): no outcome" }
        if let problem = comparePrepare("first Start", outcome, opened, expected: expected, calls: observedCalls(h), h) {
            return "\(label): \(problem)"
        }
        if h.workflow.generation != 1 + trace.admissions.count {
            return "\(label): generation \(h.workflow.generation) but the trace admitted \(trace.admissions.count) newer intents"
        }

        // The resumed Start runs from the state the first left. A latched file holds it without I/O.
        h.files.beginOperation()
        h.files.inner.scheduleWrites([])
        guard case .success(let resume) = h.workflow.admitStart() else { return "\(label): the resumed Start was not admitted" }
        let expectedResume = walkPrepare(trace.scenario, faults: (.none, .none), from: expected.state, admissions: [])
        let resumed = await workflow.prepareStart(resume)
        if let problem = comparePrepare("resumed Start", resumed, opened, expected: expectedResume, calls: observedCalls(h), h) {
            return "\(label): \(problem)"
        }
        if h.workflow.generation != 2 + trace.admissions.count {
            return "\(label): the resumed Start left generation \(h.workflow.generation)"
        }
        guard h.workflow.isIdle, !h.store.isBusy else { return "\(label): an operation is still in flight after it returned" }

        bumpPrepare(trace, expected, latched: expected.state.latched.runtime || expected.state.latched.platform)
        return nil
    }

    private func bumpPrepare(_ trace: Trace, _ expected: Expected, latched: Bool) {
        counts["prepare.\(expected.preparation)", default: 0] += 1
        counts["depth.\(trace.admissions.count)", default: 0] += 1
        if case .persisted = expected.platform, expected.runtime == .notAttempted(.superseded) {
            counts["platform.persistedRuntimeRevoked", default: 0] += 1
        }
        if case .persisted = expected.platform, trace.admissions.contains(where: { !$0.start }) {
            counts["stop.afterPersisted", default: 0] += 1
        }
        if trace.scenario == .absent, expected.preparation == .ready {
            counts["absent.defaultsCommitted", default: 0] += 1
        }
        if trace.scenario == .invalidRuntime, expected.preparation == .held {
            counts["invalidRuntime.heldNoIO", default: 0] += 1
        }
        if latched { counts["unknown.holdsNextStart", default: 0] += 1 }
    }

    private func runReload(_ trace: Trace, _ root: ModelRoot) async -> String? {
        let label = describe(trace)
        let h: Harness
        do {
            h = try harness(root, trace.scenario)
        } catch {
            return "\(label): the fixture could not seed: \(error)"
        }
        let expected = walkReload(trace.scenario, admissions: trace.admissions)
        do {
            _ = try await h.workflow.open()
        } catch {
            return "\(label): open refused: \(error)"
        }
        h.files.beginOperation()
        // Stops before the capture are applied first, so they fence the reload without making it stale.
        for admission in trace.admissions where admission.point == .beforeOperation {
            if admission.start {
                _ = h.workflow.admitStart()
            } else {
                h.workflow.admitStop()
            }
        }
        let captured = h.workflow.generation
        let workflow = h.workflow
        let reloaded = await gated(h, admissions: trace.admissions, busyChecks: false) { await workflow.reload(capturedAt: captured) }
        if let problem = reloaded.problem { return "\(label): \(problem)" }
        guard let outcome = reloaded.value else { return "\(label): no outcome" }
        if (outcome.applied != nil) != expected.applied {
            return "\(label): applied is \(outcome.applied != nil) but the reference expects \(expected.applied)"
        }
        if outcome.adopted != expected.preferencesAdopted {
            return "\(label): adopted is \(outcome.adopted) but the reference expects \(expected.preferencesAdopted)"
        }
        if !committedEvents(outcome.events).isEmpty {
            return "\(label): a reload wrote a configuration commit"
        }
        if let disagreement = Self.answerDisagrees(outcome) {
            return "\(label): \(disagreement)"
        }
        if observedCalls(h) != expected.calls {
            return "\(label): physical calls \(observedCalls(h)) but the reference expects \(expected.calls)"
        }
        if h.workflow.generation != trace.admissions.count {
            return "\(label): generation \(h.workflow.generation) but the trace admitted \(trace.admissions.count) newer intents"
        }
        guard h.workflow.isIdle, !h.store.isBusy else { return "\(label): an operation is still in flight after it returned" }
        counts["reload.applied", default: 0] += expected.applied ? 1 : 0
        counts["reload.stale", default: 0] += expected.stale ? 1 : 0
        if !expected.stale, expected.fenced { counts["reload.fencedHeld", default: 0] += 1 }
        counts["depth.\(trace.admissions.count)", default: 0] += 1
        return nil
    }

    /// The typed answer against the events of the same return: a refusal is its one refused observation, a supersession or hold is the
    /// last event, and an eligible observation holds nothing. The workflow never answers a pass it did not run.
    private static func answerDisagrees(_ outcome: RuntimeConfigurationWorkflow.ReloadOutcome) -> String? {
        let adopted = ConfigurationWorkflowEvent.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .adopted))
        switch outcome.answer {
        case .decided(.refused(let refusal)):
            let refused = ConfigurationWorkflowEvent.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(refusal)))
            return outcome.events == [refused] && !outcome.adopted ? nil : "a refused answer beside \(outcome.events)"
        case .decided(.adopted(.superseded)):
            guard case .superseded? = outcome.events.last, outcome.events.first == adopted, !outcome.adopted else {
                return "a superseded answer beside \(outcome.events)"
            }
            return nil
        case .decided(.adopted(.held(let input, let reason))):
            let held = ConfigurationWorkflowEvent.held(ConfigurationWorkflowHeld(phase: .reload, input: input, reason: reason))
            return outcome.events == [adopted, held] ? nil : "a held answer beside \(outcome.events)"
        case .decided(.adopted(.reconcileAttempted)):
            return "the workflow answered a reconcile it does not run"
        case .eligible:
            return outcome.events == [adopted] && outcome.adopted ? nil : "an eligible answer beside \(outcome.events)"
        }
    }

    private func run(_ trace: Trace, _ root: ModelRoot) async -> String? {
        trace.reload ? await runReload(trace, root) : await runPrepare(trace, root)
    }

    // MARK: - Explorer

    /// Breadth-first over the admission alphabet: each prefix is emitted, then extended at every point the reference reaches, at or after
    /// its last admission, with a Stop and a Start. Depth is bounded by `maxDepth`.
    private func enumerate(
        maxDepth: Int,
        points: ([Admission]) -> [Point],
        emit: ([Admission]) -> Void
    ) {
        var frontier: [[Admission]] = [[]]
        for depth in 0...maxDepth {
            var next: [[Admission]] = []
            for prefix in frontier {
                emit(prefix)
                guard depth < maxDepth else { continue }
                for point in points(prefix) where prefix.last.map({ point >= $0.point }) ?? true {
                    for start in [false, true] {
                        next.append(prefix + [Admission(point: point, start: start)])
                    }
                }
            }
            // A frontier past the budget is flagged and the enumeration stops there. The test fails on the flag. Nothing is dropped silently.
            guard next.count <= Self.frontierBudget else {
                frontierOverflowed = true
                return
            }
            frontier = next
        }
    }

    private func enumerateAll() -> [Trace] {
        var traces: [Trace] = []
        for scenario in Scenario.allCases {
            for (platform, runtime) in faultPairs(scenario) {
                let maxDepth = platform == .none && runtime == .none ? 2 : 1
                enumerate(maxDepth: maxDepth) { prefix in
                    walkPrepare(scenario, faults: (platform, runtime), from: initialState(scenario), admissions: prefix).points
                } emit: { prefix in
                    traces.append(Trace(scenario: scenario, platformFault: platform, runtimeFault: runtime, reload: false, admissions: prefix))
                }
            }
        }
        for scenario in [Scenario.absent, .canonical, .invalidRuntime] {
            enumerate(maxDepth: 2) { prefix in
                walkReload(scenario, admissions: prefix).points
            } emit: { prefix in
                traces.append(Trace(scenario: scenario, platformFault: .none, runtimeFault: .none, reload: true, admissions: prefix))
            }
        }
        // Shortest first, so the first counterexample is the shortest trace in the matrix.
        return traces.enumerated()
            .sorted { ($0.element.admissions.count, $0.offset) < ($1.element.admissions.count, $1.offset) }
            .map(\.element)
    }

    /// A fixed-seed walk of up to four newer intents, for depths the breadth-first matrix does not reach.
    private struct Seeded {
        var state: UInt64

        mutating func below(_ n: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(n))
        }
    }

    private func seededTrace(_ rng: inout Seeded) -> Trace {
        let drawn = Scenario.allCases[rng.below(Scenario.allCases.count)]
        let reload = rng.below(3) == 0
        let scenario = reload && drawn == .platformAbsent ? Scenario.canonical : drawn
        let pairs = faultPairs(scenario)
        let pair = pairs[rng.below(pairs.count)]
        var admissions: [Admission] = []
        for _ in 0..<4 {
            let points = reload
                ? walkReload(scenario, admissions: admissions).points
                : walkPrepare(scenario, faults: pair, from: initialState(scenario), admissions: admissions).points
            let eligible = points.filter { point in admissions.last.map { point >= $0.point } ?? true }
            if eligible.isEmpty || rng.below(4) == 0 { break }
            admissions.append(Admission(point: eligible[rng.below(eligible.count)], start: rng.below(2) == 0))
        }
        return Trace(scenario: scenario, platformFault: pair.0, runtimeFault: pair.1, reload: reload, admissions: admissions)
    }

    /// One scratch state root for the whole model. Each trace builds its own fake, store and workflow over it, so no trace creates a root.
    private final class ModelRoot {
        let directory: URL
        let session: StateRootSession

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("pm-workflow-model-\(UUID().uuidString)", isDirectory: true)
            session = try acquireScratchStateRoot(.isolated(stateDirectory: directory))
        }

        /// Closes the lease, and removes the directory only when the close was confirmed.
        func close() {
            if releaseScratchStateRoot(session) == .released, FileManager.default.fileExists(atPath: directory.path) {
                StateRootScratch.remove(directory)
            }
        }
    }

    private struct Trace {
        let scenario: Scenario
        let platformFault: Fault
        let runtimeFault: Fault
        let reload: Bool
        let admissions: [Admission]
    }

    /// Coverage that the explored matrix actually reached. Each key is a behavior the model exists to check.
    private var counts: [String: Int] = [:]

    /// The matrix is fixed, not sampled. `matrixTraces` is the breadth-first count of the declared alphabet: 4 prepare scenarios and 3 reload
    /// scenarios, the fault domains of `faultPairs`, depth at most 2 (1 for a pair with a write fault), and the points each walk reaches. Any
    /// change to those domains must change this count on purpose. `frontierBudget` bounds one frontier, and `seededWalks` is the seeded tail.
    /// It was 1,339 before an absent sidecar's job gained its runtime source read, whose two points the walks now reach.
    private static let matrixTraces = 1_459
    private static let frontierBudget = 2_000
    private static let seededWalks = 150
    private static let seed: UInt64 = 0x5EED
    /// Set when a frontier exceeded `frontierBudget`. The test fails on it, so an overflow never shrinks the matrix silently.
    private var frontierOverflowed = false

    private static let requiredCoverage = [
        "prepare.ready", "prepare.held", "prepare.superseded", "reload.applied", "reload.stale", "reload.fencedHeld",
        "platform.persistedRuntimeRevoked", "stop.afterPersisted", "unknown.holdsNextStart", "absent.defaultsCommitted",
        "busy.refused", "queued.reached", "invalidRuntime.heldNoIO", "depth.2",
    ]

    // MARK: - Tests

    /// Every explored trace matches the reference, and the matrix reaches each required behavior. The fixed-seed walk runs after it.
    func testBoundedExplorationMatchesTheReferenceModel() async throws {
        let root = try ModelRoot()
        let traces = enumerateAll()
        XCTAssertFalse(frontierOverflowed, "a breadth-first frontier exceeded \(Self.frontierBudget) prefixes, so the matrix would be truncated")
        XCTAssertEqual(traces.count, Self.matrixTraces, "the breadth-first matrix is \(Self.matrixTraces) traces; update it only with the domains")
        guard !frontierOverflowed, traces.count == Self.matrixTraces else {
            root.close()
            return
        }
        var problem: String?
        for trace in traces {
            if let text = await run(trace, root) {
                problem = text
                break
            }
        }
        if problem == nil {
            var rng = Seeded(state: Self.seed)
            for index in 0..<Self.seededWalks {
                let trace = seededTrace(&rng)
                if let text = await run(trace, root) {
                    problem = "seed \(Self.seed), walk \(index): \(text)"
                    break
                }
            }
        }
        root.close()
        if let problem { XCTFail(problem) }
        guard problem == nil else { return }
        print("ConfigurationWorkflowModel: \(traces.count) breadth-first traces (fixed), \(Self.seededWalks) seeded walks, coverage \(counts.sorted { $0.key < $1.key })")
        for key in Self.requiredCoverage {
            XCTAssertGreaterThan(counts[key] ?? 0, 0, "the matrix never reached \(key)")
        }
    }
}

private extension ConfigurationWorkflowWrite {
    /// Whether the component's current verified bytes are the candidate, by a save or by verification alone.
    var isVerified: Bool {
        switch self {
        case .persisted, .unchanged: true
        case .notPersisted, .unknown, .conflict, .notAttempted: false
        }
    }
}
