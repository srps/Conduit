// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// #34: a PAC answer is kept for `routeCacheTTL` and re-evaluated in the
/// background once it is older than `routeRevalidationAge`, so a request
/// never waits on re-evaluating a host it already has an answer for. Time is
/// a fake clock; the evaluator counts its calls and may be held on a gate.
final class PACRouteRevalidationTests: XCTestCase {
    private final class Clock: @unchecked Sendable {
        private let box = NIOLockedValueBox(Date(timeIntervalSinceReferenceDate: 800_000_000))
        var now: Date { box.withLockedValue { $0 } }
        func advance(_ seconds: TimeInterval) { box.withLockedValue { $0 += seconds } }
    }

    /// Script evaluator and PAC source in one. An evaluation takes its answer
    /// when it starts (`answers[script]` for the script it was compiled
    /// from, else `answer`), may be held until `release` is signalled, and
    /// moves the clock by `cost`, the way a slow script spends wall time.
    /// A compile may be held on `compileRelease` too, on the evaluator queue.
    private final class FakePAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        /// An evaluator bound to the script text it was compiled from.
        struct Compiled: PacScriptEvaluating {
            let pac: FakePAC
            let script: String
            func resolveProxyChain(for url: URL) throws -> [String] { try pac.evaluate(script: script) }
        }

        struct State {
            var evaluations = 0
            var answer = "PROXY a.example:8080"
            var holdNext = false
            /// Evaluations that have started a hold. A test polls this count.
            var heldEvaluations = 0
            var cost: TimeInterval = 0
            var failing = false
            var script = "script-1"
            var fetches = 0
            var answers: [String: String] = [:]
            var holdNextCompile = false
            /// Compiles that have started a hold. A test polls this count.
            var heldCompiles = 0
        }

        let state = NIOLockedValueBox(State())
        /// Gates on the evaluator queue. That queue runs one job at a time, so
        /// at most one call waits on each gate.
        let release = DispatchSemaphore(value: 0)
        let compileRelease = DispatchSemaphore(value: 0)
        private let clock: Clock

        init(clock: Clock) { self.clock = clock }

        var evaluations: Int { state.withLockedValue { $0.evaluations } }
        var fetches: Int { state.withLockedValue { $0.fetches } }
        var heldEvaluations: Int { state.withLockedValue { $0.heldEvaluations } }
        var heldCompiles: Int { state.withLockedValue { $0.heldCompiles } }
        func set(_ body: (inout State) -> Void) { state.withLockedValue(body) }

        /// Ends every hold: nothing new is held, and a call already blocked on
        /// a gate is let through. A surplus signal is harmless, because only a
        /// test body sets holds and the fixture is drained once that body is done.
        func releaseHolds() {
            state.withLockedValue { $0.holdNext = false; $0.holdNextCompile = false }
            release.signal()
            compileRelease.signal()
        }

        func fetchPAC(from _: String) async throws -> String {
            state.withLockedValue { state in
                state.fetches += 1
                return state.script
            }
        }

        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
            let hold = state.withLockedValue { state -> Bool in
                let hold = state.holdNextCompile
                state.holdNextCompile = false
                if hold { state.heldCompiles += 1 }
                return hold
            }
            if hold { compileRelease.wait() }
            return Compiled(pac: self, script: pacScript)
        }

        func resolveProxyChain(for _: URL) throws -> [String] {
            try evaluate(script: nil)
        }

        func evaluate(script: String?) throws -> [String] {
            let (answer, hold, cost, failing) = state.withLockedValue { state -> (String, Bool, TimeInterval, Bool) in
                state.evaluations += 1
                let hold = state.holdNext
                state.holdNext = false
                if hold { state.heldEvaluations += 1 }
                let answer = script.flatMap { state.answers[$0] } ?? state.answer
                return (answer, hold, state.cost, state.failing)
            }
            if hold { release.wait() }
            clock.advance(cost)
            if failing { throw PACResolverError.evaluationFailed("dnsResolve failed") }
            return [answer]
        }

        func routeChain(for entries: [String]) -> PACChain {
            CFPACEvaluator().routeChain(for: entries)
        }
    }

    private static let a = PACRoute.proxy(host: "a.example", port: 8080)
    private static let b = PACRoute.proxy(host: "b.example", port: 8080)

    /// The one fake and engine a test owns. `makeEngine` registers them, once
    /// per test, and `drainOwned` releases and waits for them on every path.
    private struct Owned {
        let pac: FakePAC
        let engine: PACRoutingEngine
    }
    private var owned: Owned?
    /// A refresh the test started on its own task. The body may not await it
    /// if it throws first, so the drain does.
    private var refreshTask: Task<Void, any Error>?

    override func tearDown() async throws {
        // The super call runs even when the drain throws, such as on
        // cancellation. The drain error is rethrown after it, not dropped.
        var drainError: (any Error)?
        do {
            try await drainOwned()
        } catch {
            drainError = error
        }
        try await super.tearDown()
        if let drainError { throw drainError }
    }

    /// Ends the fake's holds and waits for what the test already asked for:
    /// the refresh it started, and the evaluations the engine has queued or
    /// running. It starts no work to force quiet. `pendingEvaluationCount()`
    /// does not cover the per-evaluation 5 s timeout timer or a refresh that
    /// is still running after the body; neither is drained here.
    private func drainOwned() async throws {
        guard let fixture = owned else { return }
        owned = nil
        fixture.pac.releaseHolds()
        if let refresh = refreshTask {
            refreshTask = nil
            if case .failure(let error) = await refresh.result {
                XCTFail("the refresh failed: \(error)")
            }
        }
        try await waitForIdle(fixture.engine)
    }

    private func makeEngine(
        pac: FakePAC, clock: Clock, events: RuntimeEventLog, logger: (any LogSink)? = nil
    ) -> PACRoutingEngine {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://pac.example.com/proxy.pac"
        config.pacRoutingEnabled = true
        let fixed = config
        let engine = PACRoutingEngine(
            configProvider: { fixed },
            resolver: pac,
            logger: logger,
            refreshInterval: 3600,
            eventSink: { events.append($0) },
            now: { clock.now }
        )
        owned = Owned(pac: pac, engine: engine)
        return engine
    }

    private func request(
        _ engine: PACRoutingEngine, _ url: String = "https://outlook.example.com/EWS/Exchange.asmx",
        host: String = "outlook.example.com"
    ) async throws -> PACDecision {
        try await engine.decisionFuture(for: url, host: host, on: MultiThreadedEventLoopGroup.singleton.next()).get()
    }

    private func assertRoutes(
        _ engine: PACRoutingEngine, _ expected: [PACRoute], _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let routes = try await request(engine).routes
        XCTAssertEqual(routes, expected, message, file: file, line: line)
    }

    /// Waits, by polling a count the fake keeps, until a hold has begun. The
    /// deadline only bounds a failure: a pass returns as soon as the count is
    /// seen, and a timeout is a failed assertion.
    private func awaitHold(
        _ count: () -> Int, _ message: String, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<200 where count() == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertGreaterThan(count(), 0, message, file: file, line: line)
    }

    /// Waits, by polling a count, until no evaluation is running.
    private func waitForIdle(_ engine: PACRoutingEngine) async throws {
        for _ in 0..<500 where engine.pendingEvaluationCount() > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(engine.pendingEvaluationCount(), 0, "an evaluation never finished")
    }

    private func named(_ name: String, in events: RuntimeEventLog) -> [RuntimeEvent] {
        events.events.filter { $0.event == name }
    }

    /// Waits, by polling the log, until an event of this name is recorded. A
    /// finished background evaluation leaves the pending count before its
    /// failure is reported, so `waitForIdle` alone does not cover the report.
    private func awaitEvent(
        _ name: String, in events: RuntimeEventLog, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        for _ in 0..<200 where named(name, in: events).isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(named(name, in: events).isEmpty, "\(name) was never recorded", file: file, line: line)
    }

    func testAnAnswerYoungerThanTheRevalidationAgeIsNotEvaluatedAgain() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let engine = makeEngine(pac: pac, clock: clock, events: RuntimeEventLog(capacity: 64))
        try await engine.refresh(force: true)

        try await assertRoutes(engine, [Self.a])
        clock.advance(PACRoutingEngine.routeRevalidationAge - 1)
        for _ in 0..<5 {
            try await assertRoutes(engine, [Self.a])
        }
        try await waitForIdle(engine)
        XCTAssertEqual(pac.evaluations, 1, "no re-evaluation inside the revalidation age")
    }

    /// Nine minutes on, past the old 60 s expiry: the cached answer is served
    /// while its re-evaluation is still held, and only one runs for the burst.
    func testAStaleAnswerIsServedAtOnceAndEvaluatedAgainOnceInTheBackground() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let engine = makeEngine(pac: pac, clock: clock, events: RuntimeEventLog(capacity: 64))
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        clock.advance(9 * 60)
        pac.set { $0.answer = "PROXY b.example:8080"; $0.holdNext = true }

        for _ in 0..<5 {
            try await assertRoutes(engine, [Self.a],
                           "served from the cache while the re-evaluation is held")
        }
        try await awaitHold({ pac.heldEvaluations }, "the stale answer started a re-evaluation")
        XCTAssertEqual(pac.evaluations, 2, "one re-evaluation for five requests")

        pac.release.signal()
        try await waitForIdle(engine)
        try await assertRoutes(engine, [Self.b], "the re-evaluated answer replaced the stale one")
        XCTAssertEqual(pac.evaluations, 2, "the fresh answer is not evaluated again")
    }

    func testAnAnswerPastTheTTLIsEvaluatedBeforeItIsServed() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let engine = makeEngine(pac: pac, clock: clock, events: RuntimeEventLog(capacity: 64))
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        clock.advance(PACRoutingEngine.routeCacheTTL)
        pac.set { $0.answer = "PROXY b.example:8080" }
        try await assertRoutes(engine, [Self.b], "an expired answer is never served")
        XCTAssertEqual(pac.evaluations, 2)
    }

    /// A re-evaluation that started before an invalidation finishes after
    /// it: its answer is neither cached nor served.
    func testAnInvalidationDuringABackgroundReEvaluationDiscardsItsAnswer() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(pac: pac, clock: clock, events: events)
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        clock.advance(2 * 60)
        pac.set { $0.answer = "PROXY old-network.example:8080"; $0.holdNext = true }
        try await assertRoutes(engine, [Self.a])
        try await awaitHold({ pac.heldEvaluations }, "the re-evaluation started")

        engine.invalidateRoutes(reason: .networkChanged)
        pac.set { $0.answer = "PROXY b.example:8080" }
        pac.release.signal()
        try await waitForIdle(engine)

        try await assertRoutes(engine, [Self.b],
                       "the answer computed before the invalidation was discarded")
        XCTAssertEqual(pac.evaluations, 3)
        XCTAssertEqual(named("pac.routes_invalidated", in: events).map(\.detail),
                       ["reason=network_changed routes=1 script=kept fetch=idle"])
    }

    /// A path change drops the answers but keeps the script: requests go on
    /// being routed by the PAC while it is fetched again.
    func testANetworkChangeKeepsTheScriptAndDropsTheAnswers() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(pac: pac, clock: clock, events: events)
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        engine.invalidateRoutes(reason: .networkChanged)
        pac.set { $0.answer = "PROXY b.example:8080" }
        try await assertRoutes(engine, [Self.b], "evaluated again with the loaded script")
        XCTAssertEqual(pac.evaluations, 2)
    }

    /// A failed re-evaluation keeps the answer it was checking, reports once,
    /// and is not retried by every request.
    func testAFailedBackgroundReEvaluationKeepsTheStaleAnswer() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(pac: pac, clock: clock, events: events)
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        clock.advance(2 * 60)
        pac.set { $0.failing = true }
        try await assertRoutes(engine, [Self.a])
        try await waitForIdle(engine)
        try await awaitEvent("pac.revalidation_failed", in: events)
        XCTAssertEqual(pac.evaluations, 2)
        for _ in 0..<5 {
            try await assertRoutes(engine, [Self.a], "the stale answer outlives a failed re-evaluation")
        }
        try await waitForIdle(engine)
        XCTAssertEqual(pac.evaluations, 2, "not retried inside the revalidation age")
        XCTAssertEqual(named("pac.revalidation_failed", in: events).map(\.detail),
                       ["host=outlook.example.com reason=evaluation_failed suppressed=0"])
        XCTAssertTrue(named("pac.no_usable_route", in: events).isEmpty, "no request went without an answer")

        clock.advance(PACRoutingEngine.routeCacheTTL)
        pac.set { $0.failing = false }
        try await assertRoutes(engine, [Self.a], "evaluated afresh once expired")
        XCTAssertEqual(pac.evaluations, 3)
    }

    /// A background re-evaluation that fails after an invalidation dropped
    /// the answer it was checking has nothing to keep serving: no report.
    func testAFailedReEvaluationOfADroppedAnswerIsNotReported() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let logs = RecordingLogSink(minLevel: .warning)
        let engine = makeEngine(pac: pac, clock: clock, events: events, logger: logs)
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        clock.advance(2 * 60)
        pac.set { $0.failing = true; $0.holdNext = true }
        try await assertRoutes(engine, [Self.a])
        try await awaitHold({ pac.heldEvaluations }, "the re-evaluation started")

        engine.invalidateRoutes(reason: .networkChanged)
        pac.release.signal()
        try await waitForIdle(engine)

        XCTAssertTrue(named("pac.revalidation_failed", in: events).isEmpty,
                      "\(named("pac.revalidation_failed", in: events).map(\.detail))")
        XCTAssertFalse(logs.containsMessage("serving its previous answer"))
    }

    /// A request that arrives after a different script was installed never
    /// joins an evaluation the replaced script is still running for its key.
    func testARequestAfterAChangedScriptDoesNotJoinAnOldScriptEvaluation() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(pac: pac, clock: clock, events: events)
        pac.set { $0.answers = ["script-1": "PROXY a.example:8080", "script-2": "PROXY b.example:8080"] }
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])
        clock.advance(2 * 60)

        // The refresh's compile of script-2 holds the evaluator queue, so the
        // stale answer's re-evaluation (by script-1) queues behind it and is
        // still running when script-2 is installed.
        pac.set { $0.script = "script-2"; $0.holdNextCompile = true }
        let refresh = Task { try await engine.refresh(force: true) }
        refreshTask = refresh
        try await awaitHold({ pac.heldCompiles }, "the script-2 compile started")
        pac.set { $0.holdNext = true }
        try await assertRoutes(engine, [Self.a], "stale, served while its re-evaluation queues")
        XCTAssertEqual(engine.pendingEvaluationCount(), 1)
        pac.compileRelease.signal()
        try await refresh.value
        try await awaitHold({ pac.heldEvaluations }, "the script-1 re-evaluation is running")

        let group = MultiThreadedEventLoopGroup.singleton
        let afterInstall = engine.decisionFuture(
            for: "https://outlook.example.com/EWS/Exchange.asmx", host: "outlook.example.com", on: group.next()
        )
        pac.release.signal()
        let routes = try await afterInstall.get().routes
        XCTAssertEqual(routes, [Self.b], "answered by the script installed before the request came")
        try await waitForIdle(engine)
        try await assertRoutes(engine, [Self.b])
    }

    func testTheSlowEvaluationWarningIsAnEventOncePerHostPerTenMinutes() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let logs = RecordingLogSink(minLevel: .warning)
        let engine = makeEngine(pac: pac, clock: clock, events: events, logger: logs)
        try await engine.refresh(force: true)
        pac.set { $0.cost = 0.875 }

        for path in 0..<5 {
            _ = try await request(engine, "https://outlook.example.com/\(path)")
        }
        _ = try await request(engine, "https://other.example.com/", host: "other.example.com")
        XCTAssertEqual(named("pac.evaluation_slow", in: events).map(\.detail), [
            "host=outlook.example.com ms=875 suppressed=0",
            "host=other.example.com ms=875 suppressed=0",
        ])

        clock.advance(PACRoutingEngine.slowEvaluationReportInterval)
        _ = try await request(engine, "https://outlook.example.com/later")
        let slow = named("pac.evaluation_slow", in: events)
        XCTAssertEqual(slow.map(\.detail).last, "host=outlook.example.com ms=875 suppressed=4")
        XCTAssertEqual(slow.first?.kind, .routing)
        XCTAssertEqual(pac.evaluations, 7)

        let lines = logs.entries(at: .warning).filter { $0.message.hasPrefix("PAC evaluation took") }
        XCTAssertEqual(lines.count, 3, "one warning line per event")
    }

    /// The periodic refresh used to drop every answer, so the slow host paid
    /// again every five minutes. The same script keeps them, marked stale.
    func testARefreshWithTheSameScriptKeepsTheAnswersForBackgroundReEvaluation() async throws {
        let clock = Clock()
        let pac = FakePAC(clock: clock)
        let events = RuntimeEventLog(capacity: 64)
        let engine = makeEngine(pac: pac, clock: clock, events: events)
        try await engine.refresh(force: true)
        try await assertRoutes(engine, [Self.a])

        try await engine.refresh(force: true)
        XCTAssertEqual(named("pac.refreshed", in: events).last?.detail,
                       "url=http://pac.example.com/proxy.pac script=unchanged")
        pac.set { $0.answer = "PROXY b.example:8080"; $0.holdNext = true }
        try await assertRoutes(engine, [Self.a], "kept across the refresh, served at once")
        try await awaitHold({ pac.heldEvaluations }, "and evaluated again in the background")
        pac.release.signal()
        try await waitForIdle(engine)
        try await assertRoutes(engine, [Self.b])

        pac.set { $0.script = "script-2"; $0.answer = "PROXY a.example:8080" }
        try await engine.refresh(force: true)
        XCTAssertEqual(named("pac.refreshed", in: events).last?.detail, "url=http://pac.example.com/proxy.pac")
        try await assertRoutes(engine, [Self.a], "a changed script drops the answers")
        XCTAssertEqual(pac.evaluations, 3)
    }

}
