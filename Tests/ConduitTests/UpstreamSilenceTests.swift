// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class UpstreamSilenceTests: XCTestCase {
    private final class Events: @unchecked Sendable {
        private let box = NIOLockedValueBox<[RuntimeEvent]>([])
        func record(_ event: RuntimeEvent) { box.withLockedValue { $0.append(event) } }
        func details(_ name: String) -> [String] { box.withLockedValue { $0.filter { $0.event == name }.compactMap(\.detail) } }
    }

    func testAHealthCheckWhoseIdleConnectionWentSilentAsksAFreshConnection() async throws {
        let upstream = try await CountingUpstream.start(answers: 1)
        let pool = makePool(upstreams: [UpstreamProxy(name: "a", host: "127.0.0.1", port: upstream.port, priority: 0)])
        let first = await pool.healthCheck(urlString: "http://check.test/")
        XCTAssertTrue(first.healthy, first.summary)

        try await upstream.stopListening()
        let second = await pool.healthCheck(urlString: "http://check.test/")

        guard case .unreachable? = second.failure else {
            return XCTFail("a refused fresh connect is a measurement, got \(String(describing: second.failure))")
        }
        pool.closeAll()
        try await upstream.close()
    }

    func testAHealthCheckSilentOnAFreshConnectionTooIsInconclusive() async throws {
        let upstream = try await CountingUpstream.start(answers: 1)
        let events = Events()
        let pool = makePool(config: NIOLockedValueBox(Self.config(upstreams: [upstream.proxy(named: "a")])), events: events)
        let first = await pool.healthCheck(urlString: "http://check.test/")
        XCTAssertTrue(first.healthy, first.summary)
        _ = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }

        let second = await pool.healthCheck(urlString: "http://check.test/")

        guard case .answerTimedOut? = second.failure else {
            return XCTFail("connected and never answered, got \(String(describing: second.failure))")
        }
        XCTAssertEqual(upstream.methods, ["HEAD", "OPTIONS", "HEAD", "OPTIONS", "HEAD"],
                       "the silent idle connection was followed by the probe, which it answered, then one fresh check")
        pool.closeAll()
        try await upstream.close()
    }

    func testAHealthCheckWithASlowCheckURLBehindAnAnsweringUpstreamIsInconclusive() async throws {
        let upstream = try await CountingUpstream.start(answers: .max) { $0.contains("check.test") }
        let pool = makePool(upstreams: [upstream.proxy(named: "a")])

        let result = await pool.healthCheck(urlString: "http://check.test/")

        guard case .answerTimedOut? = result.failure else {
            return XCTFail("the upstream answered its own request, so the origin was slow; got \(String(describing: result.failure))")
        }
        XCTAssertEqual(upstream.optionsRequests, 1, "the check asked the upstream itself once, with a request it answers without an origin")
        XCTAssertEqual(upstream.methods.filter { $0 == "HEAD" }.count, 1, "a fresh connection's silence is not retried")
        pool.closeAll()
        try await upstream.close()
    }

    func testAHealthCheckOnAnUpstreamSilentToItsOwnRequestIsDecisive() async throws {
        let upstream = try await CountingUpstream.start(answers: .max)
        let events = Events()
        let pool = makePool(config: NIOLockedValueBox(Self.config(upstreams: [upstream.proxy(named: "a")])), events: events)
        let first = await pool.healthCheck(urlString: "http://check.test/")
        XCTAssertTrue(first.healthy, first.summary)
        _ = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        upstream.stopAnsweringOnEveryConnection()

        let second = await pool.healthCheck(urlString: "http://check.test/")

        guard case .upstreamSilent? = second.failure else {
            return XCTFail("silent to a request it answers itself, got \(String(describing: second.failure))")
        }
        XCTAssertEqual(events.details("upstream.deprioritized").count, 1)
        XCTAssertTrue(events.details("upstream.deprioritized").first?.contains(" reason=silence_check_silent ") == true,
                      events.details("upstream.deprioritized").first ?? "none")
        pool.closeAll()
        try await upstream.close()
    }

    func testAnIdleConnectionThatWentSilentIsFollowedByTheProbeThenAFreshCheck() async throws {
        let upstream = try await CountingUpstream.start(answers: .max)
        let events = Events()
        let pool = makePool(config: NIOLockedValueBox(Self.config(upstreams: [upstream.proxy(named: "a")])), events: events)
        let first = await pool.healthCheck(urlString: "http://check.test/")
        XCTAssertTrue(first.healthy, first.summary)
        _ = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        upstream.silenceOpenConnections()

        let second = await pool.healthCheck(urlString: "http://check.test/")

        XCTAssertTrue(second.healthy, second.summary)
        XCTAssertEqual(events.details("health.idle_connection_silent").count, 1)
        XCTAssertEqual(upstream.methods, ["HEAD", "OPTIONS", "HEAD", "OPTIONS", "HEAD"],
                       "the idle socket's silence is followed by the probe, then one fresh check")
        pool.closeAll()
        try await upstream.close()
    }

    func testASlowCheckURLBehindAHealthyPrimaryKeepsItsTraffic() async throws {
        let primary = try await CountingUpstream.start(answers: .max) { $0.contains("check.test") }
        let secondary = try await CountingUpstream.start(answers: .max)
        let first = primary.proxy(named: "primary"), second = secondary.proxy(named: "secondary", priority: 1)
        let events = Events()
        var config = Self.config(upstreams: [first])
        config.upstreamResponseTimeoutSeconds = 0.3
        config.healthCheckURL = "http://check.test/"
        let current = NIOLockedValueBox(config)
        let pool = makePool(config: current, events: events)
        let warm = try await pool.exchange(head: Self.head(path: "/fast-warm"), body: nil).get()
        XCTAssertEqual(warm.upstream.id, first.id, "the primary answered and has a latency")
        current.withLockedValue { $0.upstreams = [first, second] }

        let slow = (0..<2).map { pool.exchange(head: Self.head(host: "check.test", path: "/\($0)"), body: nil) }
        for (index, exchange) in slow.enumerated() {
            do {
                let response = try await exchange.get()
                XCTFail("slow request \(index) was answered by \(response.upstream.name)")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut, "slow request \(index)")
            }
        }
        let checked = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }
        var servedBy: [String] = []
        for index in 0..<6 {
            servedBy.append(try await pool.exchange(head: Self.head(path: "/fast-\(index)"), body: nil).get().upstream.name)
        }

        XCTAssertTrue(checked, "the decisive silence asked the primary itself")
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains("outcome=answered") == true,
                      events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(servedBy, Array(repeating: "primary", count: 6), "a slow check URL is a slow origin, no reason to move traffic off a healthy primary")
        XCTAssertEqual(events.details("upstream.deprioritized"), [])
        XCTAssertEqual(secondary.requests, 0)
        pool.closeAll()
        try await primary.close()
        try await secondary.close()
    }

    func testAnUpstreamThatIgnoresTheProbeIsNeverRankedBehindForASilence() async throws {
        let upstream = try await CountingUpstream.start(answers: .max, probes: .ignored) { $0.contains("/slow") }
        let events = Events()
        let pool = makePool(config: NIOLockedValueBox(Self.config(upstreams: [upstream.proxy(named: "a")])), events: events)
        _ = try await pool.exchange(head: Self.head(path: "/warm"), body: nil).get()
        let discovered = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        XCTAssertTrue(discovered, "the first answer is followed by one probe that learns whether the upstream answers it")
        XCTAssertTrue(events.details("upstream.liveness_discovered").first?.contains(" answers_probes=false") == true,
                      events.details("upstream.liveness_discovered").first ?? "none")

        for index in 0..<2 {
            do {
                _ = try await pool.exchange(head: Self.head(path: "/slow-\(index)"), body: nil).get()
                XCTFail("slow request \(index) was answered")
            } catch {}
        }
        let checked = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }
        XCTAssertTrue(checked)
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains("outcome=silent verdict=kept_probe_ignored") == true,
                      events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(events.details("upstream.deprioritized"), [], "an upstream known to ignore the probe falls back to the streak rule")

        let check = await pool.healthCheck(urlString: "http://example.com/slow-check")
        guard case .answerTimedOut? = check.failure else {
            return XCTFail("a silent probe says nothing about an upstream that ignores it, and one silent origin decides nothing, got \(String(describing: check.failure))")
        }
        pool.closeAll()
        try await upstream.close()
    }

    func testAHealthCheckOnAnUpstreamWhoseRankingLapsedWithoutAnAnswerIsDecisiveWithoutAnotherProbe() async throws {
        let upstream = try await CountingUpstream.start(answers: .max)
        let events = Events()
        var config = Self.config(upstreams: [upstream.proxy(named: "a")])
        config.circuitBaseOpenIntervalSeconds = 0
        let pool = makePool(config: NIOLockedValueBox(config), events: events)
        let first = await pool.healthCheck(urlString: "http://check.test/")
        XCTAssertTrue(first.healthy, first.summary)
        _ = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        upstream.stopAnsweringOnEveryConnection()

        let second = await pool.healthCheck(urlString: "http://check.test/")
        guard case .upstreamSilent? = second.failure else {
            return XCTFail("the probe found it silent, got \(String(describing: second.failure))")
        }
        let probesSoFar = upstream.optionsRequests
        let third = await pool.healthCheck(urlString: "http://check.test/")

        guard case .upstreamSilent? = third.failure else {
            return XCTFail("its silence stands until it answers, got \(String(describing: third.failure))")
        }
        XCTAssertEqual(upstream.optionsRequests, probesSoFar, "a standing silence is not probed again")
        XCTAssertEqual(events.details("upstream.deprioritized").count, 1)
        XCTAssertTrue(events.details("upstream.reprioritized").first?.contains(" reason=interval_elapsed") == true,
                      "the ranking lapsed before the third check's HEAD timed out: \(events.details("upstream.reprioritized"))")
        pool.closeAll()
        try await upstream.close()
    }

    func testAHealthCheckWhoseProbeIsOutlivedByAnAnswerIsHeldNotDecisive() async throws {
        let upstream = try await CountingUpstream.start(answers: .max, probes: .ignored) { $0.contains("check.test") }
        let events = Events()
        var config = Self.config(upstreams: [upstream.proxy(named: "a")])
        config.upstreamResponseTimeoutSeconds = 0.5
        let pool = makePool(config: NIOLockedValueBox(config), events: events)

        async let check = pool.healthCheck(urlString: "http://check.test/")
        let probed = await Self.eventually { upstream.optionsRequests == 1 }
        XCTAssertTrue(probed, "the silent HEAD asked the probe")
        _ = try await pool.exchange(head: Self.head(path: "/fast"), body: nil).get()
        let result = await check

        guard case .answerTimedOut? = result.failure else {
            return XCTFail("an answer while the probe ran is the newer evidence, got \(String(describing: result.failure))")
        }
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains(" verdict=superseded") == true,
                      events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(events.details("upstream.deprioritized"), [])
        pool.closeAll()
        try await upstream.close()
    }

    func testAHealthCheckSilentOnAHalfOpenUpstreamThatAnswersTheProbeKeepsItHalfOpen() async throws {
        let (pool, upstream, events, openedByRefusals) = try await halfOpenPoolInFrontOf(answers: 0)

        let silent = await pool.healthCheck(urlString: "http://check.test/")

        guard case .answerTimedOut? = silent.failure else {
            return XCTFail("the upstream answered the probe, so only the origin was silent; got \(String(describing: silent.failure))")
        }
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .halfOpen, "a proxy alive to its own request neither closes nor re-opens the breaker")
        XCTAssertEqual(events.details("upstream.circuit_opened").count, openedByRefusals)
        XCTAssertEqual(events.details("upstream.silence_check_started").last?.contains(" asked_by=half_open_probe "), true)
        XCTAssertTrue(events.details("upstream.silence_check_finished").last?.contains(" outcome=answered verdict=kept ") == true,
                      events.details("upstream.silence_check_finished").last ?? "none")
        pool.closeAll()
        try await upstream.close()
    }

    func testASilentHalfOpenExchangeWhoseUpstreamAnswersTheProbeKeepsTheSlotFree() async throws {
        let (pool, upstream, events, openedByRefusals) = try await halfOpenPoolInFrontOf(answers: 0)

        do {
            _ = try await pool.exchange(head: Self.head(path: "/probe"), body: nil).get()
            XCTFail("the upstream never answers requests")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut)
        }
        let settled = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }

        XCTAssertTrue(settled, "the half-open exchange's silence asked the probe")
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains(" outcome=answered verdict=kept ") == true,
                      events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .halfOpen)
        XCTAssertEqual(events.details("upstream.circuit_opened").count, openedByRefusals, "the proxy answered for itself, so nothing re-opened")
        pool.closeAll()
        try await upstream.close()
    }

    /// A pool whose one upstream's breaker was opened by refused connects, now pointed at a `CountingUpstream`;
    /// the next selection forces it half-open.
    private func halfOpenPoolInFrontOf(answers: Int) async throws -> (ConnectionPool, CountingUpstream, Events, opened: Int) {
        let released = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let refusedPort = try XCTUnwrap(released.localAddress?.port)
        try await released.close().get()
        let upstream = try await CountingUpstream.start(answers: answers)
        let events = Events()
        var config = Self.config(upstreams: [UpstreamProxy(name: "a", host: "127.0.0.1", port: refusedPort, priority: 0)])
        config.circuitFailureThreshold = 2
        config.circuitBreakerWindowSeconds = 0
        let current = NIOLockedValueBox(config)
        let pool = makePool(config: current, events: events)
        for _ in 0..<2 {
            let refused = await pool.healthCheck(urlString: "http://check.test/")
            XCTAssertFalse(refused.healthy)
        }
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)
        current.withLockedValue { $0.upstreams[0].port = upstream.port }
        return (pool, upstream, events, events.details("upstream.circuit_opened").count)
    }

    func testTwoConcurrentSlowRequestsBehindAHealthyPrimaryLeaveItServing() async throws {
        let primary = try await CountingUpstream.start(answers: .max) { $0.contains("/slow") }
        let secondary = try await CountingUpstream.start(answers: .max)
        let first = primary.proxy(named: "primary"), second = secondary.proxy(named: "secondary", priority: 1)
        let events = Events()
        let current = NIOLockedValueBox(Self.config(upstreams: [first]))
        let pool = makePool(config: current, events: events)
        let warm = try await pool.exchange(head: Self.head(path: "/fast-warm"), body: nil).get()
        XCTAssertEqual(warm.upstream.id, first.id, "the primary answered and has a latency")
        current.withLockedValue { $0.upstreams = [first, second] }

        let slow = (0..<2).map { pool.exchange(head: Self.head(path: "/slow-\($0)"), body: nil) }
        for (index, exchange) in slow.enumerated() {
            do {
                let response = try await exchange.get()
                XCTFail("slow request \(index) was answered by \(response.upstream.name)")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut, "slow request \(index)")
            }
        }
        let checked = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }
        var servedBy: [String] = []
        for index in 0..<6 {
            servedBy.append(try await pool.exchange(head: Self.head(path: "/fast-\(index)"), body: nil).get().upstream.name)
        }

        XCTAssertEqual(servedBy, Array(repeating: "primary", count: 6), "a slow origin is no reason to move traffic off a healthy primary")
        XCTAssertEqual(events.details("upstream.deprioritized"), [])
        XCTAssertTrue(checked, "the decisive silence asked the primary itself")
        XCTAssertEqual(events.details("upstream.silence_check_started").count, 1)
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains("outcome=answered") == true,
                      events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(secondary.requests, 0)
        let status = try XCTUnwrap(pool.upstreamStatuses().first { $0.id == first.id })
        XCTAssertEqual(status.circuitState, .closed)
        XCTAssertEqual(status.consecutiveFailures, 0)
        pool.closeAll()
        try await primary.close()
        try await secondary.close()
    }

    func testASilenceCheckNeverConsultsTheAuthenticator() async throws {
        let upstream = try await CountingUpstream.start(answers: .max) { $0.contains("/slow") }
        let proxy = upstream.proxy(named: "a")
        let events = Events()
        let authenticator = CountingAuthenticator()
        let pool = ConnectionPool(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            configProvider: { Self.config(upstreams: [proxy]) }, authenticatorProvider: { _ in authenticator }, eventSink: events.record
        )
        _ = try await pool.exchange(head: Self.head(path: "/warm"), body: nil).get()
        for index in 0..<2 {
            do {
                _ = try await pool.exchange(head: Self.head(path: "/slow-\(index)"), body: nil).get()
                XCTFail("slow request \(index) was answered")
            } catch {}
        }

        let finished = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }

        XCTAssertTrue(finished)
        XCTAssertEqual(authenticator.calls, 2,
                       "one credential for the warm connection and one for the second slow request's fresh connection; the probe asks for none, so a stalled credential cannot hold it")
        let released = await Self.eventually { pool.allConnectionSnapshot.isEmpty }
        XCTAssertTrue(released, "the probe's connection is closed, or checks would pile up")
        pool.closeAll()
        try await upstream.close()
    }

    func testASecondSilenceInARowWhoseCheckIsSilentRanksTheUpstreamBehindOneThatAnswers() async throws {
        let primary = try await CountingUpstream.start(answers: .max)
        let secondary = try await CountingUpstream.start(answers: .max)
        let first = primary.proxy(named: "primary"), second = secondary.proxy(named: "secondary", priority: 1)
        let events = Events()
        let current = NIOLockedValueBox(Self.config(upstreams: [first]))
        let pool = makePool(config: current, events: events)
        let served = try await pool.exchange(head: Self.head, body: nil).get()
        XCTAssertEqual(served.upstream.id, first.id, "the primary answered and has a latency")
        _ = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        primary.stopAnsweringOnEveryConnection()
        current.withLockedValue { $0.upstreams = [first, second] }

        for attempt in 1...2 {
            do {
                let response = try await pool.exchange(head: Self.head, body: nil).get()
                XCTFail("attempt \(attempt) was answered by \(response.upstream.name)")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut, "attempt \(attempt)")
            }
        }
        XCTAssertEqual(primary.methods.filter { $0 == "GET" }.count, 3,
                       "one silence left the primary first, so the second request went to it too")
        let checked = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }

        let after = try await pool.exchange(head: Self.head, body: nil).get()

        XCTAssertTrue(checked, "the second silence in a row asked the primary itself")
        XCTAssertEqual(events.details("upstream.silence_check_finished").first?.contains("outcome=silent verdict=ranked_behind"), true,
                       events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(after.upstream.id, second.id, "a silent check ranked the primary behind the secondary")
        XCTAssertEqual(events.details("upstream.deprioritized").count, 1)
        XCTAssertTrue(events.details("upstream.deprioritized").first?.contains("upstream=primary ") == true,
                      events.details("upstream.deprioritized").first ?? "none")
        let status = try XCTUnwrap(pool.upstreamStatuses().first { $0.id == first.id })
        XCTAssertEqual(status.circuitState, .closed, "a silence is not a loss")
        XCTAssertEqual(status.consecutiveFailures, 0)
        pool.closeAll()
        try await primary.close()
        try await secondary.close()
    }

    func testASilenceOnAnOpenBreakerRanksNothing() async throws {
        let released = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let refusedPort = try XCTUnwrap(released.localAddress?.port)
        try await released.close().get()
        var config = Self.config(upstreams: [UpstreamProxy(name: "a", host: "127.0.0.1", port: refusedPort, priority: 0)])
        config.circuitFailureThreshold = 1
        config.circuitBreakerWindowSeconds = 0
        let events = Events()
        let pool = makePool(config: NIOLockedValueBox(config), events: events)
        do {
            _ = try await pool.exchange(head: Self.head, body: nil).get()
            XCTFail("a refused connect cannot succeed")
        } catch {}
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)

        for _ in 0..<2 { pool.recordExchangeFailure(ConnectionPoolError.upstreamResponseTimedOut, for: config.upstreams[0], origin: .connect("example.com:80")) }

        XCTAssertEqual(events.details("upstream.deprioritized"), [], "late silences on an open breaker must not hide its half-open probe")
        pool.closeAll()
    }

    /// The primary has a latency score from one answered exchange, so selection prefers it until it ranks behind.
    private func egressPools(
        probes: CountingUpstream.Probes = .answered, withSecondary: Bool = true, answering: @escaping @Sendable (String) -> Bool = { _ in false }
    ) async throws -> (ConnectionPool, primary: CountingUpstream, secondary: CountingUpstream?, Events, broken: NIOLockedValueBox<Bool>) {
        let broken = NIOLockedValueBox(false)
        let primary = try await CountingUpstream.start(answers: .max, probes: probes) { line in broken.withLockedValue { $0 } && !answering(line) }
        let secondary = withSecondary ? try await CountingUpstream.start(answers: .max) : nil
        let first = primary.proxy(named: "primary")
        let events = Events()
        var config = Self.config(upstreams: [first])
        config.upstreamResponseTimeoutSeconds = 0.3
        let current = NIOLockedValueBox(config)
        let pool = makePool(config: current, events: events)
        let warm = try await pool.exchange(head: Self.head(host: "warm.test", path: "/"), body: nil).get()
        XCTAssertEqual(warm.upstream.id, first.id, "the primary answered and has a latency")
        let discovered = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        XCTAssertTrue(discovered, "the first answer is followed by the discovery probe")
        if let secondary { current.withLockedValue { $0.upstreams = [first, secondary.proxy(named: "secondary", priority: 1)] } }
        broken.withLockedValue { $0 = true }
        return (pool, primary, secondary, events, broken)
    }

    private func expectSilent(_ pool: ConnectionPool, host: String, _ label: String) async {
        do {
            let response = try await pool.exchange(head: Self.head(host: host, path: "/"), body: nil).get()
            XCTFail("\(label) was answered by \(response.upstream.name)")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut, label)
        }
    }

    private func servedBy(_ pool: ConnectionPool, host: String, path: String = "/after") async -> String {
        do {
            return try await pool.exchange(head: Self.head(host: host, path: path), body: nil).get().upstream.name
        } catch {
            return "no answer: \(error)"
        }
    }

    func testASilentEgressBehindAProxyThatAnswersTheProbeRanksItBehind() async throws {
        let (pool, primary, secondary, events, _) = try await egressPools()
        await expectSilent(pool, host: "a.test", "the first request to origin a")
        await expectSilent(pool, host: "a.test", "the second request to origin a")
        let probed = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }
        XCTAssertTrue(probed, "two silences in a row asked the primary itself")

        let check = await pool.healthCheck(urlString: "http://check.test/")
        let after = await servedBy(pool, host: "a.test")

        guard case .upstreamSilent? = check.failure else {
            return XCTFail("silent to two origins with nothing answered between is a dead egress, got \(String(describing: check.failure))")
        }
        let deprioritized = events.details("upstream.deprioritized")
        XCTAssertEqual(deprioritized.count, 1, "\(deprioritized)")
        XCTAssertTrue(deprioritized.first?.contains(" reason=silent_origins ") == true, deprioritized.first ?? "none")
        XCTAssertEqual(after, "secondary", "the primary ranks behind the secondary that answers")
        pool.closeAll()
        try await primary.close()
        try await secondary?.close()
    }

    func testTwoSilentOriginsOnTheDataPathRankTheUpstreamBehindWithoutAHealthCheck() async throws {
        let (pool, primary, secondary, events, _) = try await egressPools()
        await expectSilent(pool, host: "a.test", "the request to origin a")
        await expectSilent(pool, host: "b.test", "the request to origin b")

        let after = await servedBy(pool, host: "a.test")

        XCTAssertEqual(after, "secondary", "two silent origins with no answer between rank the primary behind")
        let deprioritized = events.details("upstream.deprioritized")
        XCTAssertEqual(deprioritized.count, 1, "\(deprioritized)")
        XCTAssertTrue(deprioritized.first?.contains(" reason=silent_origins ") == true, deprioritized.first ?? "none")
        XCTAssertEqual(pool.upstreamStatuses().first { $0.name == "primary" }?.consecutiveFailures, 0, "a silence strikes nothing")
        pool.closeAll()
        try await primary.close()
        try await secondary?.close()
    }

    func testOneSilentOriginWithAnAnswerBetweenNeverRanksBehind() async throws {
        let (pool, primary, secondary, events, _) = try await egressPools { $0.contains("c.test") }
        await expectSilent(pool, host: "a.test", "the request to origin a")
        let answered = try await pool.exchange(head: Self.head(host: "c.test", path: "/"), body: nil).get()
        XCTAssertEqual(answered.upstream.name, "primary")
        await expectSilent(pool, host: "b.test", "the request to origin b")

        let after = await servedBy(pool, host: "c.test")

        XCTAssertEqual(after, "primary", "an answer between two silent origins says the egress is alive")
        XCTAssertEqual(events.details("upstream.deprioritized"), [])
        XCTAssertEqual(secondary?.requests, 0)
        pool.closeAll()
        try await primary.close()
        try await secondary?.close()
    }

    func testAProxyThatIgnoresTheProbeAndThenDiesIsRankedBehindAcrossOrigins() async throws {
        let (pool, primary, secondary, events, _) = try await egressPools(probes: .ignored)
        XCTAssertTrue(events.details("upstream.liveness_discovered").first?.contains(" answers_probes=false") == true,
                      events.details("upstream.liveness_discovered").first ?? "none")
        await expectSilent(pool, host: "a.test", "the request to origin a")

        let check = await pool.healthCheck(urlString: "http://check.test/")
        let after = await servedBy(pool, host: "a.test")

        guard case .upstreamSilent? = check.failure else {
            return XCTFail("the check URL is a second silent origin, got \(String(describing: check.failure))")
        }
        XCTAssertTrue(events.details("upstream.deprioritized").first?.contains(" reason=silent_origins ") == true,
                      events.details("upstream.deprioritized").first ?? "none")
        XCTAssertEqual(after, "secondary")
        pool.closeAll()
        try await primary.close()
        try await secondary?.close()
    }

    func testASingleUpstreamWithASilentEgressIsDecisiveAtTheFirstHealthCheck() async throws {
        let (pool, primary, _, events, _) = try await egressPools(withSecondary: false)
        await expectSilent(pool, host: "a.test", "the request to origin a")

        let check = await pool.healthCheck(urlString: "http://check.test/")

        guard case .upstreamSilent? = check.failure else {
            return XCTFail("a silent data-path origin and a silent check URL are two origins, got \(String(describing: check.failure))")
        }
        XCTAssertEqual(events.details("upstream.deprioritized").count, 1)
        pool.closeAll()
        try await primary.close()
    }

    func testAnEndpointChangeDuringAHalfOpenProbeFreesTheSlot() async throws {
        let released = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton).bind(host: "127.0.0.1", port: 0).get()
        let refusedPort = try XCTUnwrap(released.localAddress?.port)
        try await released.close().get()
        let silent = try await CountingUpstream.start(answers: 0, probes: .ignored)
        let healthy = try await CountingUpstream.start(answers: .max)
        let other = try await CountingUpstream.start(answers: .max)
        let events = Events()
        var config = Self.config(upstreams: [healthy.proxy(named: "a")])
        config.circuitFailureThreshold = 2
        config.circuitBreakerWindowSeconds = 0
        config.circuitBaseOpenIntervalSeconds = 0.3
        let current = NIOLockedValueBox(config)
        let pool = makePool(config: current, events: events)
        _ = try await pool.exchange(head: Self.head(path: "/warm"), body: nil).get()
        _ = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        current.withLockedValue { $0.upstreams[0].port = refusedPort }
        for _ in 0..<2 { _ = await pool.healthCheck(urlString: "http://check.test/") }
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)
        current.withLockedValue { $0.upstreams[0].port = silent.port }
        await expectSilent(pool, host: "example.com", "the half-open probe exchange")
        current.withLockedValue { $0.upstreams[0].port = healthy.port }
        let settled = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }
        XCTAssertTrue(settled)
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains(" verdict=superseded") == true,
                      "the probe asked the endpoint the edit replaced: \(events.details("upstream.silence_check_finished"))")
        current.withLockedValue { $0.upstreams.append(other.proxy(named: "c", priority: 1)) }
        let healthyBefore = healthy.requests

        var via: [String] = []
        for index in 0..<3 { via.append(await servedBy(pool, host: "example.com", path: "/after-\(index)")) }

        XCTAssertEqual(via.first, "a", "the slot the replaced endpoint held is free, so the next exchange is the new endpoint's probe")
        XCTAssertGreaterThan(healthy.requests, healthyBefore, "the new endpoint was asked")
        XCTAssertEqual(pool.upstreamStatuses().first { $0.name == "a" }?.circuitState, .closed, "its answer closed the breaker")
        pool.closeAll()
        try await silent.close()
        try await healthy.close()
        try await other.close()
    }

    func testAHalfOpenExchangeSilentAcrossOriginsReopensTheBreaker() async throws {
        let (pool, upstream, events, openedByRefusals) = try await halfOpenPoolInFrontOf(answers: 0)
        await expectSilent(pool, host: "a.test", "the half-open probe exchange to origin a")
        let kept = await Self.eventually { !events.details("upstream.silence_check_finished").isEmpty }
        XCTAssertTrue(kept)
        XCTAssertTrue(events.details("upstream.silence_check_finished").first?.contains(" outcome=answered verdict=kept ") == true,
                      events.details("upstream.silence_check_finished").first ?? "none")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .halfOpen)

        await expectSilent(pool, host: "b.test", "the half-open probe exchange to origin b")
        let reopened = await Self.eventually { events.details("upstream.circuit_opened").count > openedByRefusals }

        XCTAssertTrue(reopened, "two silent origins with no answer between re-open a half-open breaker")
        XCTAssertTrue(events.details("upstream.circuit_opened").last?.contains("reason=probe_failed") == true,
                      events.details("upstream.circuit_opened").last ?? "none")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .open)
        pool.closeAll()
        try await upstream.close()
    }

    /// Two pooled sockets that have each answered once and sat idle; the discovery probe ran on its own.
    private func twoIdleConnections(_ pool: ConnectionPool, to upstream: CountingUpstream, _ events: Events) async throws {
        let exchanges = [pool.exchange(head: Self.head(host: "warm.test", path: "/1"), body: nil),
                         pool.exchange(head: Self.head(host: "warm.test", path: "/2"), body: nil)]
        for exchange in exchanges { _ = try await exchange.get() }
        let discovered = await Self.eventually { !events.details("upstream.liveness_discovered").isEmpty }
        XCTAssertTrue(discovered)
        XCTAssertEqual(upstream.connections, 3, "two pooled sockets and the discovery probe's own")
    }

    func testIdleSocketsToAReplacedEndpointCarryNothingAndChargeTheNewEndpointNoSilence() async throws {
        let old = try await CountingUpstream.start(answers: .max)
        let replacement = try await CountingUpstream.start(answers: .max)
        let events = Events()
        let current = NIOLockedValueBox(Self.config(upstreams: [old.proxy(named: "a")]))
        let pool = makePool(config: current, events: events)
        try await twoIdleConnections(pool, to: old, events)
        old.silenceOpenConnections()
        current.withLockedValue { $0.upstreams[0].port = replacement.port }

        var answered: [String] = []
        for host in ["a.test", "b.test", "c.test"] { answered.append(await servedBy(pool, host: host)) }

        XCTAssertEqual(answered, ["a", "a", "a"], "the sockets to the replaced endpoint carry no request")
        XCTAssertEqual(replacement.methods.filter { $0 == "GET" }.count, 3)
        XCTAssertEqual(events.details("upstream.deprioritized"), [], "the old endpoint's silence is not the new one's")
        pool.closeAll()
        try await old.close()
        try await replacement.close()
    }

    private static let head = head(path: "/")

    private static func head(host: String = "example.com", path: String) -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://\(host)\(path)")
        head.headers.add(name: "Host", value: host)
        return head
    }

    private static func eventually(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 where !condition() {
            do { try await Task.sleep(for: .milliseconds(10)) } catch { return condition() }
        }
        return condition()
    }

    private static func config(upstreams: [UpstreamProxy]) -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.upstreamResponseTimeoutSeconds = 0.2
        config.upstreams = upstreams
        return config
    }

    private func makePool(upstreams: [UpstreamProxy]) -> ConnectionPool {
        makePool(config: NIOLockedValueBox(Self.config(upstreams: upstreams)), events: Events())
    }

    private func makePool(config: NIOLockedValueBox<ProxyConfig>, events: Events) -> ConnectionPool {
        ConnectionPool(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), configProvider: { config.withLockedValue { $0 } },
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") }, eventSink: events.record
        )
    }

    private final class CountingAuthenticator: ProxyAuthenticator, @unchecked Sendable {
        let scheme = "Basic"
        private let count = NIOLockedValueBox(0)

        var calls: Int { count.withLockedValue { $0 } }

        func initialToken(for host: String) throws -> String {
            count.withLockedValue { $0 += 1 }
            return "Basic dGVzdA=="
        }

        func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
        func canHandle(scheme: String) -> Bool { scheme.caseInsensitiveCompare("Basic") == .orderedSame }
        func reset() {}
    }

    private final class CountingUpstream: @unchecked Sendable {
        enum Probes { case answered, ignored }

        private struct Behaviour {
            var answers: Int
            var alive = true
            var silenced: Set<ObjectIdentifier> = []
        }

        private let behaviour: NIOLockedValueBox<Behaviour>
        private let counts = NIOLockedValueBox((connections: 0, requests: 0, options: 0))
        private let lines = NIOLockedValueBox<[String]>([])
        private var listener: Channel?
        private let children = NIOLockedValueBox<[Channel]>([])

        var port: Int { listener?.localAddress?.port ?? 0 }
        var connections: Int { counts.withLockedValue { $0.connections } }
        var requests: Int { counts.withLockedValue { $0.requests } }
        var optionsRequests: Int { counts.withLockedValue { $0.options } }
        var requestLines: [String] { lines.withLockedValue { $0 } }
        var methods: [String] { requestLines.map { String($0.prefix { $0 != " " }) } }

        private init(answers: Int) { self.behaviour = NIOLockedValueBox(Behaviour(answers: answers)) }

        func proxy(named name: String, priority: Int = 0) -> UpstreamProxy {
            UpstreamProxy(name: name, host: "127.0.0.1", port: port, priority: priority)
        }

        static func start(
            answers: Int, probes: Probes = .answered, neverAnswers: @escaping @Sendable (String) -> Bool = { _ in false }
        ) async throws -> CountingUpstream {
            let upstream = CountingUpstream(answers: answers)
            let behaviour = upstream.behaviour, counts = upstream.counts, lines = upstream.lines, children = upstream.children
            let reply: @Sendable (Channel, String) -> String? = { channel, line in
                counts.withLockedValue {
                    $0.requests += 1
                    if line.hasPrefix("OPTIONS ") { $0.options += 1 }
                }
                lines.withLockedValue { $0.append(line) }
                return behaviour.withLockedValue { state -> String? in
                    guard state.alive, !state.silenced.contains(ObjectIdentifier(channel)) else { return nil }
                    if line.hasPrefix("OPTIONS ") {
                        return probes == .answered ? "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n" : nil
                    }
                    guard !neverAnswers(line), state.answers > 0 else { return nil }
                    state.answers -= 1
                    return "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                }
            }
            upstream.listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    counts.withLockedValue { $0.connections += 1 }
                    children.withLockedValue { $0.append(channel) }
                    return channel.pipeline.addHandler(RequestHandler(reply: reply))
                }
                .bind(host: "127.0.0.1", port: 0).get()
            return upstream
        }

        /// New connects are refused; accepted connections stay open and silent.
        func stopListening() async throws { try await listener?.close().get() }

        func stopAnsweringOnEveryConnection() { behaviour.withLockedValue { $0.alive = false } }

        func silenceOpenConnections() {
            let open = children.withLockedValue { $0.filter(\.isActive) }.map(ObjectIdentifier.init)
            behaviour.withLockedValue { $0.silenced.formUnion(open) }
        }

        func close() async throws {
            if listener?.isActive == true { try await listener?.close().get() }
            for child in children.withLockedValue({ $0 }) where child.isActive {
                child.close(promise: nil)
            }
        }

        private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let reply: @Sendable (Channel, String) -> String?
            private var pending = ""

            init(reply: @escaping @Sendable (Channel, String) -> String?) { self.reply = reply }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                pending += buffer.readString(length: buffer.readableBytes) ?? ""
                while let end = pending.range(of: "\r\n\r\n") {
                    let line = pending[pending.startIndex..<end.lowerBound].components(separatedBy: "\r\n").first ?? ""
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    guard let response = reply(context.channel, line) else { continue }
                    context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: response)), promise: nil)
                }
            }
        }
    }
}
