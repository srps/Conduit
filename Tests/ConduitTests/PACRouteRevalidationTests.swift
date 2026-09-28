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
    /// when it starts, may be held until `release` is signalled, and moves
    /// the clock by `cost`, the way a slow script spends wall time.
    private final class FakePAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
        struct State {
            var evaluations = 0
            var answer = "PROXY a.example:8080"
            var holdNext = false
            var cost: TimeInterval = 0
            var failing = false
            var script = "script-1"
            var fetches = 0
        }

        let state = NIOLockedValueBox(State())
        let held = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        private let clock: Clock

        init(clock: Clock) { self.clock = clock }

        var evaluations: Int { state.withLockedValue { $0.evaluations } }
        var fetches: Int { state.withLockedValue { $0.fetches } }
        func set(_ body: (inout State) -> Void) { state.withLockedValue(body) }

        func fetchPAC(from _: String) async throws -> String {
            state.withLockedValue { state in
                state.fetches += 1
                return state.script
            }
        }

        func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }

        func resolveProxyChain(for _: URL) throws -> [String] {
            let (answer, hold, cost, failing) = state.withLockedValue { state in
                state.evaluations += 1
                defer { state.holdNext = false }
                return (state.answer, state.holdNext, state.cost, state.failing)
            }
            if hold {
                held.signal()
                release.wait()
            }
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

    private func makeEngine(
        pac: FakePAC, clock: Clock, events: RuntimeEventLog, logger: (any LogSink)? = nil
    ) -> PACRoutingEngine {
        var config = ProxyConfig.testFixture()
        config.pacURL = "http://pac.example.com/proxy.pac"
        config.pacRoutingEnabled = true
        let fixed = config
        return PACRoutingEngine(
            configProvider: { fixed },
            resolver: pac,
            logger: logger,
            refreshInterval: 3600,
            eventSink: { events.append($0) },
            now: { clock.now }
        )
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
        var released = false
        defer { if !released { pac.release.signal() } }

        for _ in 0..<5 {
            try await assertRoutes(engine, [Self.a],
                           "served from the cache while the re-evaluation is held")
        }
        XCTAssertEqual(pac.held.wait(timeout: .now() + 2), .success, "the stale answer started a re-evaluation")
        XCTAssertEqual(pac.evaluations, 2, "one re-evaluation for five requests")

        pac.release.signal()
        released = true
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
        var released = false
        defer { if !released { pac.release.signal() } }
        try await assertRoutes(engine, [Self.a])
        XCTAssertEqual(pac.held.wait(timeout: .now() + 2), .success)

        engine.invalidateRoutes(reason: .networkChanged)
        pac.set { $0.answer = "PROXY b.example:8080" }
        pac.release.signal()
        released = true
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
        var released = false
        defer { if !released { pac.release.signal() } }
        try await assertRoutes(engine, [Self.a], "kept across the refresh, served at once")
        XCTAssertEqual(pac.held.wait(timeout: .now() + 2), .success, "and evaluated again in the background")
        pac.release.signal()
        released = true
        try await waitForIdle(engine)
        try await assertRoutes(engine, [Self.b])

        pac.set { $0.script = "script-2"; $0.answer = "PROXY a.example:8080" }
        try await engine.refresh(force: true)
        XCTAssertEqual(named("pac.refreshed", in: events).last?.detail, "url=http://pac.example.com/proxy.pac")
        try await assertRoutes(engine, [Self.a], "a changed script drops the answers")
        XCTAssertEqual(pac.evaluations, 3)
    }
}
