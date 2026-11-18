// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// #279. Every upstream is tripped with a long open interval, so selection forces the longest-open one
/// half-open at once and no test waits on a backoff.
final class HalfOpenProbeLeaseTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var upstreams: [ScriptedUpstream] = []
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])
    private let config = NIOLockedValueBox(ProxyConfig.testFixture())
    private let limiter = AuthHandshakeLimiter()
    private static let authLimits = AuthHandshakeLimiter.Limits(total: 1, perSource: 1)

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() async throws {
        for upstream in upstreams { try await upstream.stop() }
        try await group.shutdownGracefully()
        try await super.tearDown()
    }

    // MARK: - Fixture

    private func startUpstream(_ script: @escaping @Sendable (_ connection: Int, _ requestLine: String) -> ScriptedUpstream.Answer) async throws -> ScriptedUpstream {
        let upstream = ScriptedUpstream(script)
        try await upstream.start(group: group)
        upstreams.append(upstream)
        return upstream
    }

    private func startAnsweringUpstream() async throws -> ScriptedUpstream {
        try await startUpstream { _, line in line.hasPrefix("CONNECT ") ? .status(502) : .ok }
    }

    private func refusingPort() async throws -> Int {
        let closed = try await startUpstream { _, _ in .ok }
        let port = closed.port
        try await closed.stop()
        upstreams.removeAll { $0 === closed }
        return port
    }

    private func makePool(_ named: [(name: String, port: Int)]) -> ConnectionPool {
        config.withLockedValue { config in
            config.upstreams = named.enumerated().map { UpstreamProxy(name: $1.name, host: "127.0.0.1", port: $1.port, priority: $0) }
            config.upstreamResponseTimeoutSeconds = 2
            config.circuitBreakerWindowSeconds = 0
            config.circuitFailureThreshold = 1
            config.circuitBaseOpenIntervalSeconds = 300
            config.circuitMaxOpenIntervalSeconds = 600
            config.pendingAuthHandshakeGlobalLimit = Self.authLimits.total
            config.pendingAuthHandshakesPerSource = Self.authLimits.perSource
        }
        let config = self.config, events = self.events
        return ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config.withLockedValue { $0 } },
            authenticatorProvider: { _ in Self.authenticator() },
            authHandshakeLimiter: limiter,
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            minimumConnectTimeout: 0.05
        )
    }

    /// Held for the test: a tunnel whose coordinator is gone fails without a verdict.
    private var coordinators: [ObjectIdentifier: CONNECTCoordinator] = [:]

    private func coordinator(_ pool: ConnectionPool) -> CONNECTCoordinator {
        if let existing = coordinators[ObjectIdentifier(pool)] { return existing }
        let events = self.events
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in Self.authenticator() }, logger: DiscardingLogSink(),
            authHandshakeLimiter: limiter, authLimitProvider: { Self.authLimits },
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        coordinators[ObjectIdentifier(pool)] = coordinator
        return coordinator
    }

    /// Holds the group's only event loop until the returned semaphore is signalled, so nothing the loop would run,
    /// a dial landing included, happens before the test's next steps.
    private func parkEventLoop() -> DispatchSemaphore {
        let parked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        group.next().execute {
            parked.signal()
            resume.wait()
        }
        parked.wait()
        return resume
    }

    private static func authenticator() -> ProxyAuthenticator {
        NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
    }

    private func proxy(_ name: String) -> UpstreamProxy {
        config.withLockedValue { config in config.upstreams.first { $0.name == name }! }
    }

    private func state(_ pool: ConnectionPool, _ name: String) -> UpstreamCircuitState? {
        pool.upstreamStatuses().first { $0.name == name }?.circuitState
    }

    private func holdTheOnlyHandshakePermit() -> AuthHandshakePermit {
        guard case .success(let permit) = limiter.acquire(source: nil, limits: Self.authLimits) else {
            fatalError("the limiter starts empty")
        }
        return permit
    }

    private func exchange(_ pool: ConnectionPool, _ uri: String) async -> Result<Int, Error> {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
        head.headers.add(name: "Host", value: URL(string: uri)?.host ?? uri)
        do {
            return .success(Int(try await pool.exchange(head: head, body: nil).get().head.status.code))
        } catch {
            return .failure(error)
        }
    }

    private func tunnel(_ pool: ConnectionPool, _ target: String, through chain: [UpstreamProxy] = []) async -> Error? {
        do {
            let established = try await coordinator(pool).connectUpstreamTunnel(target: target, proxyChain: chain).get()
            try await established.channel.close().get()
            return nil
        } catch {
            return error
        }
    }

    /// Opens each breaker in turn with a 502 to a forced CONNECT, so the first named is the longest open.
    private func tripInOrder(_ pool: ConnectionPool, _ names: [String], file: StaticString = #filePath, line: UInt = #line) async {
        for name in names {
            let error = await tunnel(pool, "trip.test:443", through: [proxy(name)])
            XCTAssertTrue(error.map(ConnectionPoolError.isUpstreamAnswer) ?? false, "\(String(describing: error))", file: file, line: line)
            XCTAssertEqual(state(pool, name), .open, file: file, line: line)
        }
    }

    private func released() -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == "upstream.probe_released" }.compactMap(\.detail)
    }

    private func halfOpened(_ name: String) -> Int {
        events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_half_opened" && $0.detail?.hasPrefix("upstream=\(name) ") == true }.count
    }

    private func gets(_ upstream: ScriptedUpstream) -> Int {
        upstream.requestLines.filter { $0.hasPrefix("GET ") }.count
    }

    private func assertAnswered(_ result: Result<Int, Error>, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case .success(let status) = result else { return XCTFail("expected an answer, got \(result). \(message)", file: file, line: line) }
        XCTAssertEqual(status, 200, message, file: file, line: line)
    }

    private func assertProbedAgainAndServes(
        _ pool: ConnectionPool, first: ScriptedUpstream, file: StaticString = #filePath, line: UInt = #line
    ) async {
        XCTAssertEqual(state(pool, "first"), .halfOpen, "the probe ended without a verdict", file: file, line: line)
        for index in 0..<3 {
            assertAnswered(await exchange(pool, "http://after.test/\(index)"), file: file, line: line)
        }
        XCTAssertEqual(gets(first), 3, "the upstream whose probe ended without a verdict is selectable again", file: file, line: line)
        XCTAssertEqual(state(pool, "first"), .closed, "the next probe was answered", file: file, line: line)
        XCTAssertEqual(state(pool, "second"), .open, "the other upstream was never needed", file: file, line: line)
        XCTAssertEqual(halfOpened("second"), 0, file: file, line: line)
    }

    // MARK: - A probe that ends locally

    func testABufferedProbeThatEndsInALocalFailureLeavesTheUpstreamSelectable() async throws {
        let first = try await startAnsweringUpstream(), second = try await startAnsweringUpstream()
        let pool = makePool([("first", first.port), ("second", second.port)])
        defer { pool.closeAll() }
        await tripInOrder(pool, ["first", "second"])

        let permit = holdTheOnlyHandshakePermit()
        guard case .failure(let error) = await exchange(pool, "http://probe.test/") else { return XCTFail("the handshake limit refuses the probe") }
        XCTAssertTrue(ConnectionPoolError.isAuthHandshakeLimitExceeded(error), "\(error)")
        permit.release()

        XCTAssertEqual(released(), ["upstream=first endpoint=127.0.0.1:\(first.port) origin=probe.test:80 ending=local"])
        await assertProbedAgainAndServes(pool, first: first)
    }

    func testAStreamingProbeThatEndsInALocalFailureLeavesTheUpstreamSelectable() async throws {
        let first = try await startAnsweringUpstream(), second = try await startAnsweringUpstream()
        let pool = makePool([("first", first.port), ("second", second.port)])
        defer { pool.closeAll() }
        await tripInOrder(pool, ["first", "second"])

        let permit = holdTheOnlyHandshakePermit()
        let clientChannel = NIOAsyncTestingChannel()
        finishAtTearDown(clientChannel)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://probe.test/", headers: ["Host": "probe.test"])
        do {
            _ = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
            XCTFail("the handshake limit refuses the probe")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isAuthHandshakeLimitExceeded(error), "\(error)")
        }
        permit.release()

        XCTAssertEqual(released(), ["upstream=first endpoint=127.0.0.1:\(first.port) origin=probe.test:80 ending=local"])
        await assertProbedAgainAndServes(pool, first: first)
    }

    func testACONNECTProbeThatEndsInALocalFailureLeavesTheUpstreamSelectable() async throws {
        let first = try await startAnsweringUpstream(), second = try await startAnsweringUpstream()
        let pool = makePool([("first", first.port), ("second", second.port)])
        defer { pool.closeAll() }
        await tripInOrder(pool, ["first", "second"])

        let permit = holdTheOnlyHandshakePermit()
        let error = await tunnel(pool, "probe.test:443")
        XCTAssertTrue(error.map(ConnectionPoolError.isAuthHandshakeLimitExceeded) ?? false, "\(String(describing: error))")
        permit.release()

        XCTAssertEqual(released(), ["upstream=first endpoint=127.0.0.1:\(first.port) origin=probe.test:443 ending=local"])
        await assertProbedAgainAndServes(pool, first: first)
    }

    // MARK: - A streamed probe

    func testAStreamedProbeIsAnsweredAtItsResponseHead() async throws {
        let first = try await startUpstream { _, line in
            if line.hasPrefix("CONNECT ") { return .status(502) }
            return line.contains("stream.test") ? .openStream : .ok
        }
        let second = try await startAnsweringUpstream()
        let pool = makePool([("first", first.port), ("second", second.port)])
        defer { pool.closeAll() }
        await tripInOrder(pool, ["first", "second"])

        let clientChannel = NIOAsyncTestingChannel()
        finishAtTearDown(clientChannel)
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://stream.test/events", headers: ["Host": "stream.test"])
        let stream = pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel)
        guard case .head(let forwarded) = try await clientChannel.waitForOutboundWrite(as: HTTPServerResponsePart.self) else {
            return XCTFail("the response head is forwarded first")
        }
        XCTAssertEqual(forwarded.status, .ok)

        XCTAssertEqual(state(pool, "first"), .closed, "the head answered the probe while the stream stays open")
        for index in 0..<3 {
            assertAnswered(await exchange(pool, "http://after.test/\(index)"))
        }
        XCTAssertEqual(gets(first), 4, "the streaming upstream serves the stream and the next requests")
        XCTAssertEqual(halfOpened("second"), 0, "the other upstream was never needed")
        XCTAssertEqual(released(), [])

        XCTAssertEqual(pool.closeAll(), 2, "the open stream and the idle connection")
        do {
            _ = try await stream.get()
            XCTFail("the stream was cut after its head")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isStreamingResponseInterrupted(error), "\(error)")
        }
        while try await clientChannel.readOutbound(as: HTTPServerResponsePart.self) != nil {}
        let opened = events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_opened" }.compactMap(\.detail)
            .filter { $0.hasPrefix("upstream=first ") }
        XCTAssertEqual(opened.count, 2, "the trip, then the cut stream: \(opened)")
        XCTAssertTrue(opened.last?.contains("reason=threshold") == true,
                      "a stream cut after the probe was answered fails a closed upstream, not the probe: \(opened)")
    }

    // MARK: - A failure from before a breaker reset

    private func stale() -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == "upstream.stale_failure_dropped" }.compactMap(\.detail)
    }

    func testACONNECTDialThatFailsAfterAFlapResetDoesNotReopenTheBreaker() async throws {
        let port = try await refusingPort()
        let pool = makePool([("first", port)])
        defer { pool.closeAll() }

        let parked = parkEventLoop()
        let dial = coordinator(pool).connectUpstreamTunnel(target: "before.test:443")
        pool.resetCircuitsAfterFlap()
        parked.signal()
        do {
            _ = try await dial.get()
            XCTFail("nothing listens on the port")
        } catch {
            XCTAssertFalse(ConnectionPoolError.isLocalNonUpstreamFailure(error), "\(error)")
        }
        XCTAssertEqual(state(pool, "first"), .closed, "the reset forgave the path the dial started on")
        XCTAssertEqual(stale(), ["upstream=first endpoint=127.0.0.1:\(port) origin=before.test:443 verdict=failure"])

        let after = await tunnel(pool, "after.test:443")
        XCTAssertNotNil(after)
        XCTAssertEqual(state(pool, "first"), .open, "a dial that started after the reset counts")
    }

    func testAPlainRequestWhoseDialFailsAfterAFlapResetDoesNotReopenTheBreaker() async throws {
        let port = try await refusingPort()
        let pool = makePool([("first", port)])
        defer { pool.closeAll() }

        let parked = parkEventLoop()
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://before.test/", headers: ["Host": "before.test"])
        let request = pool.exchange(head: head, body: nil)
        pool.resetCircuitsAfterFlap()
        parked.signal()
        do {
            _ = try await request.get()
            XCTFail("nothing listens on the port")
        } catch {
            XCTAssertFalse(ConnectionPoolError.isLocalNonUpstreamFailure(error), "\(error)")
        }
        XCTAssertEqual(state(pool, "first"), .closed, "the reset forgave the path the request started on")
        XCTAssertEqual(stale(), ["upstream=first endpoint=127.0.0.1:\(port) origin=before.test:80 verdict=failure"])

        guard case .failure = await exchange(pool, "http://after.test/") else { return XCTFail("nothing listens on the port") }
        XCTAssertEqual(state(pool, "first"), .open, "a request that started after the reset counts")
    }

    func testASilenceFromBeforeAFlapResetDoesNotCountTowardTheNextOne() async throws {
        let quiet = try await startUpstream { _, _ in .silent }
        let pool = makePool([("first", quiet.port)])
        defer { pool.closeAll() }
        config.withLockedValue { $0.upstreamResponseTimeoutSeconds = 0.2 }

        let parked = parkEventLoop()
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://before.test/", headers: ["Host": "before.test"])
        let request = pool.exchange(head: head, body: nil)
        pool.resetCircuitsAfterFlap()
        parked.signal()
        do {
            _ = try await request.get()
            XCTFail("the upstream never answers")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
        }
        XCTAssertEqual(stale(), ["upstream=first endpoint=127.0.0.1:\(quiet.port) origin=before.test:80 verdict=silence"])

        guard case .failure(let error) = await exchange(pool, "http://after.test/") else { return XCTFail("the upstream never answers") }
        XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
        XCTAssertEqual(state(pool, "first"), .closed, "one origin left unanswered since the reset is not upstream loss")
        XCTAssertEqual(events.withLockedValue { $0 }.filter { $0.event == "upstream.silence_counted" }.count, 0)
    }

    // MARK: - A CONNECT whose coordinator is gone

    func testATunnelWhoseCoordinatorIsReleasedBeforeItsDialLandsLeavesThePool() async throws {
        let upstream = try await startAnsweringUpstream()
        let pool = makePool([("first", upstream.port)])
        defer { pool.closeAll() }
        var owner: CONNECTCoordinator? = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in Self.authenticator() }, logger: DiscardingLogSink(),
            authHandshakeLimiter: limiter, authLimitProvider: { Self.authLimits }
        )
        weak let released = owner

        let parked = parkEventLoop()
        let tunnel = owner!.connectUpstreamTunnel(target: "gone.test:443")
        owner = nil
        XCTAssertNil(released, "nothing but the caller held the coordinator")
        parked.signal()

        do {
            _ = try await tunnel.get()
            XCTFail("no coordinator is left to run the handshake")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .tunnelCoordinatorReleased)
            XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure(error))
        }
        XCTAssertEqual(pool.allConnectionSnapshot.count, 0, "the dialed connection does not hold a pool slot")
        XCTAssertEqual(upstream.requestLines, [], "the upstream was never asked")
        XCTAssertEqual(state(pool, "first"), .closed)
        let abandoned = events.withLockedValue { $0 }.filter { $0.event == "connection.tunnel_abandoned" }.compactMap(\.detail)
        XCTAssertEqual(abandoned, ["target=gone.test:443 upstream=127.0.0.1:\(upstream.port)"])
    }

    // MARK: - A CONNECT that fails to dial

    func testARefusedCONNECTDialCountsAsABreakerFailure() async throws {
        let port = try await refusingPort()
        let pool = makePool([("first", port)])
        defer { pool.closeAll() }

        let error = await tunnel(pool, "refused.test:443", through: [proxy("first")])
        XCTAssertNotNil(error, "nothing listens on the port")
        XCTAssertFalse(error.map(ConnectionPoolError.isLocalNonUpstreamFailure) ?? true, "\(String(describing: error))")
        XCTAssertEqual(state(pool, "first"), .open, "a refused dial is the upstream's failure, as it is for a plain request")
    }

    func testACONNECTProbeWhoseDialIsRefusedReopensTheBreakerAndIsTriedAgain() async throws {
        let port = try await refusingPort()
        let second = try await startAnsweringUpstream()
        let pool = makePool([("first", port)])
        defer { pool.closeAll() }
        guard case .failure = await exchange(pool, "http://trip.test/") else { return XCTFail("nothing listens on the port") }
        XCTAssertEqual(state(pool, "first"), .open)
        config.withLockedValue { $0.upstreams.append(UpstreamProxy(name: "second", host: "127.0.0.1", port: second.port, priority: 1)) }
        await tripInOrder(pool, ["second"])

        let probeError = await tunnel(pool, "probe.test:443")
        XCTAssertNotNil(probeError, "the refused probe, then the other upstream's 502")
        XCTAssertEqual(halfOpened("first"), 1, "the CONNECT probed the longest-open upstream first")
        XCTAssertEqual(state(pool, "first"), .open, "its refused dial was the probe's failure")
        let reopened = events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_opened" }.compactMap(\.detail)
        XCTAssertTrue(reopened.contains { $0.hasPrefix("upstream=first ") && $0.contains("reason=probe_failed") }, reopened.description)

        let againError = await tunnel(pool, "again.test:443")
        XCTAssertNotNil(againError)
        XCTAssertEqual(halfOpened("first"), 2, "the upstream whose probe failed to dial is probed again")
        XCTAssertEqual(released(), [], "every probe here ended with a verdict")
    }
}
