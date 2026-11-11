// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

private final class ScriptedUpstream: @unchecked Sendable {
    enum Answer { case ok, status(Int), silent }

    private let script: @Sendable (_ connection: Int, _ requestLine: String) -> Answer
    private let connections = NIOLockedValueBox(0)
    private let lines = NIOLockedValueBox<[String]>([])
    private var channel: Channel?

    init(_ script: @escaping @Sendable (_ connection: Int, _ requestLine: String) -> Answer) {
        self.script = script
    }

    var port: Int { channel?.localAddress?.port ?? 0 }
    var requestLines: [String] { lines.withLockedValue { $0 } }

    func start(group: EventLoopGroup) async throws {
        let script = self.script, connections = self.connections, lines = self.lines
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let connection = connections.withLockedValue { $0 += 1; return $0 }
                return channel.pipeline.addHandler(RequestHandler { channel, requestLine in
                    lines.withLockedValue { $0.append(requestLine) }
                    let response: String
                    switch script(connection, requestLine) {
                    case .silent: return
                    case .status(let code): response = "HTTP/1.1 \(code) Answered\r\nContent-Length: 0\r\n\r\n"
                    case .ok where requestLine.hasPrefix("CONNECT "): response = "HTTP/1.1 200 Connection established\r\n\r\n"
                    case .ok: response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                    }
                    channel.writeAndFlush(channel.allocator.buffer(string: response), promise: nil)
                })
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async throws {
        try await channel?.close().get()
    }

    private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let onRequest: (Channel, String) -> Void
        private var pending = ""

        init(onRequest: @escaping (Channel, String) -> Void) { self.onRequest = onRequest }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            pending += buffer.readString(length: buffer.readableBytes) ?? ""
            while let end = pending.range(of: "\r\n\r\n") {
                let head = String(pending[pending.startIndex..<end.lowerBound])
                pending.removeSubrange(pending.startIndex..<end.upperBound)
                onRequest(context.channel, head.components(separatedBy: "\r\n").first ?? "")
            }
        }
    }
}

final class UpstreamSilenceTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!
    private var upstreams: [ScriptedUpstream] = []
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])
    private let config = NIOLockedValueBox(ProxyConfig.testFixture())

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

    /// One upstream whose breaker trips at `threshold` counted failures, one by default, so a counted silence shows as `.open`.
    private func makePool(port: Int, threshold: Int = 1) -> ConnectionPool {
        config.withLockedValue { config in
            config.upstreams = [UpstreamProxy(name: "quiet", host: "127.0.0.1", port: port, priority: 0)]
            config.upstreamResponseTimeoutSeconds = 0.2
            config.circuitBreakerWindowSeconds = 0
            config.circuitFailureThreshold = threshold
        }
        let config = self.config, events = self.events
        return ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config.withLockedValue { $0 } },
            authenticatorProvider: { _ in Self.authenticator() },
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            minimumConnectTimeout: 0.05
        )
    }

    private static func authenticator() -> ProxyAuthenticator {
        NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
    }

    private var proxy: UpstreamProxy { config.withLockedValue { $0.upstreams[0] } }

    private func exchange(_ pool: ConnectionPool, _ uri: String, method: HTTPMethod = .GET) async -> Result<Int, Error> {
        var head = HTTPRequestHead(version: .http1_1, method: method, uri: uri)
        head.headers.add(name: "Host", value: URL(string: uri)?.host ?? uri)
        do {
            return .success(Int(try await pool.exchange(head: head, body: nil).get().head.status.code))
        } catch {
            return .failure(error)
        }
    }

    private func status(_ pool: ConnectionPool) -> UpstreamRuntimeStatus? {
        pool.upstreamStatuses().first { $0.id == proxy.id }
    }

    private func counted() -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == "upstream.silence_counted" }.compactMap(\.detail)
    }

    private func assertAnswered(_ result: Result<Int, Error>, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case .success(let status) = result else { return XCTFail("expected an answer, got \(result). \(message)", file: file, line: line) }
        XCTAssertEqual(status, 200, message, file: file, line: line)
    }

    private func assertTimedOut(_ result: Result<Int, Error>, _ message: String = "", file: StaticString = #filePath, line: UInt = #line) {
        guard case .failure(let error) = result else { return XCTFail("expected a timeout, got \(result). \(message)", file: file, line: line) }
        XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error). \(message)", file: file, line: line)
    }

    /// Two answered exchanges in flight at once leave two idle connections, so a silent exchange
    /// can close one and a health check still finds the other.
    private func warmTwoIdleConnections(_ pool: ConnectionPool, file: StaticString = #filePath, line: UInt = #line) async {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://check.test/first")
        head.headers.add(name: "Host", value: "check.test")
        let inFlight = [pool.exchange(head: head, body: nil), pool.exchange(head: head, body: nil)]
        for future in inFlight {
            do {
                let code = try await future.get().head.status.code
                XCTAssertEqual(code, 200, file: file, line: line)
            } catch {
                XCTFail("warming an idle connection failed: \(error)", file: file, line: line)
            }
        }
    }

    // MARK: - The rule

    func testASlowSingleOriginNeverTrips() async throws {
        let upstream = try await startUpstream { _, _ in .silent }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }

        for path in ["one", "two", "three"] {
            assertTimedOut(await exchange(pool, "http://slow.test/\(path)"))
        }

        XCTAssertEqual(status(pool)?.circuitState, .closed, "three silences on one origin say nothing about the upstream")
        XCTAssertEqual(status(pool)?.consecutiveFailures, 0)
        XCTAssertEqual(counted(), [])
    }

    func testSilenceAcrossTwoOriginsWithNoAnswerBetweenCounts() async throws {
        let upstream = try await startUpstream { _, _ in .silent }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }

        assertTimedOut(await exchange(pool, "http://a.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the first silent origin is pending, not counted")

        assertTimedOut(await exchange(pool, "http://B.test:80/"))
        XCTAssertEqual(status(pool)?.circuitState, .open, "silence on a second origin counts as a failure")
        XCTAssertEqual(counted(), ["upstream=quiet endpoint=127.0.0.1:\(upstream.port) origin=b.test:80 origins=a.test:80,b.test:80"])
        XCTAssertEqual(events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_opened" }.count, 1)
    }

    func testAnAnswerBetweenTwoSilentOriginsResetsThePendingSilence() async throws {
        let upstream = try await startUpstream { _, line in line.contains("/ok") ? .ok : .silent }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }

        assertTimedOut(await exchange(pool, "http://a.test/"))
        await assertAnswered(exchange(pool, "http://answers.test/ok"))
        assertTimedOut(await exchange(pool, "http://b.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the answer in between cleared a.test, so b.test is the only pending origin")
        XCTAssertEqual(counted(), [])

        assertTimedOut(await exchange(pool, "http://c.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .open, "b.test and c.test with no answer between them count")
        XCTAssertEqual(counted().count, 1)
    }

    func testAStatusTheUpstreamAnswersClearsPendingSilencesAndStillCountsAsAFailure() async throws {
        let upstream = try await startUpstream { _, line in line.hasPrefix("CONNECT ") ? .status(502) : .silent }
        let pool = makePool(port: upstream.port, threshold: 2)
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in Self.authenticator() }, logger: DiscardingLogSink())

        assertTimedOut(await exchange(pool, "http://a.test/"))
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "answers.test:443", proxyChain: [proxy]).get()
            XCTFail("the upstream answers the CONNECT with a 502")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isUpstreamAnswer(error), "\(error)")
        }
        XCTAssertEqual(status(pool)?.consecutiveFailures, 1, "the 502 is the failure it always was")

        assertTimedOut(await exchange(pool, "http://b.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the 502 was an answer, so a.test was cleared and b.test is the only pending origin")
        XCTAssertEqual(counted(), [])
        assertTimedOut(await exchange(pool, "http://c.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .open, "the counted silence is the second failure")
    }

    func testARefusedConnectStillTripsOnItsOwn() async throws {
        let closed = try await startUpstream { _, _ in .ok }
        let port = closed.port
        try await closed.stop()
        upstreams.removeAll()
        let pool = makePool(port: port)
        defer { pool.closeAll() }

        guard case .failure(let error) = await exchange(pool, "http://a.test/") else { return XCTFail("a closed port must refuse") }
        XCTAssertFalse(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
        XCTAssertEqual(status(pool)?.circuitState, .open, "a refused connect is the measurement and counts at once")
        XCTAssertEqual(counted(), [])
    }

    func testACONNECTTheUpstreamNeverAnswersIsASilence() async throws {
        let upstream = try await startUpstream { _, _ in .silent }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in Self.authenticator() }, logger: DiscardingLogSink())

        for target in ["a.test:443", "b.test:443"] {
            do {
                _ = try await coordinator.connectUpstreamTunnel(target: target, proxyChain: [proxy]).get()
                XCTFail("the upstream never answers the CONNECT")
            } catch {
                XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
            }
        }

        XCTAssertEqual(status(pool)?.circuitState, .open)
        XCTAssertEqual(counted().count, 1)
        XCTAssertEqual(counted().first?.hasSuffix("origin=b.test:443 origins=a.test:443,b.test:443"), true, counted().description)
    }

    // MARK: - The health check

    /// A pending origin seeded before each check makes a wrongly recorded idle silence count, and so visible.
    func testAHealthCheckSilentOnAnIdleSocketRetriesFreshAndCountsNothingWhenAnswered() async throws {
        // A connection that served /first answers /second with silence; a fresh one answers it.
        let warmed = NIOLockedValueBox<Set<Int>>([])
        let upstream = try await startUpstream { connection, line in
            if line.contains("/silent") { return .silent }
            if line.contains("/first") { warmed.withLockedValue { _ = $0.insert(connection) } }
            return line.contains("/second") && warmed.withLockedValue { $0.contains(connection) } ? .silent : .ok
        }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }

        await warmTwoIdleConnections(pool)
        assertTimedOut(await exchange(pool, "http://a.test/silent"), "takes one idle connection with it and leaves a.test pending")
        let result = await pool.healthCheck(urlString: "http://check.test/second")
        XCTAssertTrue(result.healthy, "the fresh retry answered: \(result)")
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the idle silence named no origin, or a.test and check.test would have counted")
        XCTAssertEqual(upstream.requestLines.filter { $0.hasPrefix("HEAD ") }.count, 2, "the idle socket's silence was retried on a fresh connection")
        XCTAssertEqual(events.withLockedValue { $0 }.filter { $0.event == "health.idle_connection_silent" }.map(\.detail),
                       ["upstream=quiet endpoint=127.0.0.1:\(upstream.port) retry=fresh_connection"])

        assertTimedOut(await exchange(pool, "http://b.test/silent"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the answer cleared everything, so b.test is the only pending one")
        assertTimedOut(await exchange(pool, "http://c.test/silent"))
        XCTAssertEqual(status(pool)?.circuitState, .open)
    }

    /// A half-open upstream's health check takes the probe slot, meets an idle socket's silence and asks a fresh
    /// connection. The slot stays claimed until that retry answers: a selection made while the retry is at the upstream
    /// gets no probe of its own.
    func testAHealthCheckKeepsItsProbeAcrossTheIdleSocketRetry() async throws {
        let warmed = NIOLockedValueBox<Set<Int>>([])
        let poolBox = NIOLockedValueBox<ConnectionPool?>(nil)
        let probeDuringRetry = NIOLockedValueBox<[Bool]>([])
        let upstream = try await startUpstream { connection, line in
            if line.hasPrefix("CONNECT ") { return .status(502) }
            if line.contains("/first") { warmed.withLockedValue { _ = $0.insert(connection) } }
            guard line.contains("/second") else { return .ok }
            if warmed.withLockedValue({ $0.contains(connection) }) { return .silent }
            let selection = poolBox.withLockedValue { $0 }?.selectTunnelUpstream(excluding: [])
            probeDuringRetry.withLockedValue { $0.append(selection?.probe != nil) }
            return .ok
        }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }
        poolBox.withLockedValue { $0 = pool }

        await warmTwoIdleConnections(pool)
        try await tripOnAnAnswerAndWaitForTheProbe(pool)
        let result = await pool.healthCheck(urlString: "http://check.test/second")

        XCTAssertTrue(result.healthy, "the fresh retry answered: \(result)")
        XCTAssertEqual(upstream.requestLines.filter { $0.hasPrefix("HEAD ") }.count, 2, "the idle socket's silence was retried")
        XCTAssertEqual(probeDuringRetry.withLockedValue { $0 }, [false], "no other selection claimed the probe while the retry ran")
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the retry's answer is the probe's verdict")
    }

    func testAHealthCheckSilentOnAFreshRetryIsOneSilenceOnTheCheckOrigin() async throws {
        let upstream = try await startUpstream { _, line in line.contains("/first") ? .ok : .silent }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }

        await warmTwoIdleConnections(pool)
        assertTimedOut(await exchange(pool, "http://a.test/"), "takes one idle connection with it and leaves a.test pending")
        XCTAssertEqual(status(pool)?.circuitState, .closed, "a.test is the one pending origin")
        let result = await pool.healthCheck(urlString: "http://check.test/second")
        guard case .unreachable? = result.failure else { return XCTFail("the fresh retry was silent too: \(result)") }

        XCTAssertEqual(status(pool)?.circuitState, .open, "the fresh retry's silence on the check origin counted with a.test")
        XCTAssertEqual(counted().count, 1, "the idle silence did not count on its own: \(counted())")
        XCTAssertEqual(counted().first?.hasSuffix("origins=a.test:80,check.test:80"), true, counted().description)
    }

    private func tripOnAnAnswerAndWaitForTheProbe(_ pool: ConnectionPool) async throws {
        config.withLockedValue { $0.circuitBaseOpenIntervalSeconds = 0.2; $0.circuitMaxOpenIntervalSeconds = 0.4 }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in Self.authenticator() }, logger: DiscardingLogSink())
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "x.test:443", proxyChain: [proxy]).get()
            XCTFail("the upstream answers the CONNECT with a 502")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isUpstreamAnswer(error), "\(error)")
        }
        XCTAssertEqual(status(pool)?.circuitState, .open, "the 502 trips with an empty ledger")
        try await Task.sleep(for: .milliseconds(300))
    }

    private func released() -> [String] {
        events.withLockedValue { $0 }.filter { $0.event == "upstream.probe_released" }.compactMap(\.detail)
    }

    func testAProbeThatMeetsOnlyASlowOriginLeavesTheUpstreamSelectable() async throws {
        let subject = try await startUpstream { _, line in line.hasPrefix("CONNECT ") ? .status(502) : (line.contains("/slow") ? .silent : .ok) }
        let other = try await startUpstream { _, _ in .ok }
        let pool = makePool(port: subject.port)
        defer { pool.closeAll() }
        await assertAnswered(exchange(pool, "http://warm.test/warm"))
        try await tripOnAnAnswerAndWaitForTheProbe(pool)

        assertTimedOut(await exchange(pool, "http://slow.test/slow"), "the half-open probe lands on a slow origin")
        XCTAssertEqual(status(pool)?.circuitState, .halfOpen, "one slow origin neither closes nor reopens the breaker")
        XCTAssertEqual(released(), ["upstream=quiet endpoint=127.0.0.1:\(subject.port) origin=slow.test:80"])
        XCTAssertEqual(counted(), [])

        config.withLockedValue { $0.upstreams.append(UpstreamProxy(name: "other", host: "127.0.0.1", port: other.port, priority: 1)) }
        for index in 0..<12 {
            _ = await exchange(pool, "http://fast.test/ok\(index)")
        }
        XCTAssertGreaterThan(subject.requestLines.filter { $0.contains("/ok") }.count, 0, "the released slot let a later request probe the upstream")
        XCTAssertEqual(status(pool)?.circuitState, .closed, "that probe was answered")
    }

    func testAProbeToAnEndpointEditedAwayStillFreesTheSlot() async throws {
        let subject = try await startUpstream { _, line in line.hasPrefix("CONNECT ") ? .status(502) : (line.contains("/slow") ? .silent : .ok) }
        let moved = try await startUpstream { _, _ in .ok }
        let other = try await startUpstream { _, _ in .ok }
        let pool = makePool(port: subject.port)
        defer { pool.closeAll() }
        await assertAnswered(exchange(pool, "http://warm.test/warm"))
        try await tripOnAnAnswerAndWaitForTheProbe(pool)

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://slow.test/slow")
        head.headers.add(name: "Host", value: "slow.test")
        let probe = pool.exchange(head: head, body: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(status(pool)?.circuitState, .halfOpen, "the probe to the old endpoint is in flight")
        config.withLockedValue { $0.upstreams[0].port = moved.port }
        do {
            _ = try await probe.get()
            XCTFail("the old endpoint never answers /slow")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
        }
        XCTAssertEqual(released().count, 1, "the probe's silence frees the slot though its endpoint is gone")
        XCTAssertEqual(counted(), [])

        config.withLockedValue { $0.upstreams.append(UpstreamProxy(name: "other", host: "127.0.0.1", port: other.port, priority: 1)) }
        for index in 0..<12 {
            _ = await exchange(pool, "http://fast.test/ok\(index)")
        }
        XCTAssertGreaterThan(moved.requestLines.filter { $0.contains("/ok") }.count, 0, "the edited upstream is probed again")
        XCTAssertEqual(status(pool)?.circuitState, .closed)
    }

    func testSilenceOnTwoOriginsDuringHalfOpenStillReopensTheBreaker() async throws {
        let subject = try await startUpstream { _, line in line.hasPrefix("CONNECT ") ? .status(502) : .silent }
        let pool = makePool(port: subject.port)
        defer { pool.closeAll() }
        try await tripOnAnAnswerAndWaitForTheProbe(pool)

        assertTimedOut(await exchange(pool, "http://a.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .halfOpen, "a.test alone is pending")
        assertTimedOut(await exchange(pool, "http://b.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .open, "silence on a second origin is the probe's failure")
        XCTAssertEqual(released().count, 1)
        XCTAssertEqual(counted().first?.hasSuffix("origins=a.test:80,b.test:80"), true, counted().description)
        XCTAssertEqual(
            events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_opened" }.last?.detail?.contains("reason=probe_failed"), true
        )
    }

    func testAnUpstreamThatLosesTheLatencyDuelIsNotLeftHoldingTheProbe() async throws {
        let subject = try await startUpstream { _, line in line.hasPrefix("CONNECT ") ? .status(502) : .ok }
        let otherFallsSilent = NIOLockedValueBox(false)
        let other = try await startUpstream { _, _ in otherFallsSilent.withLockedValue { $0 } ? .silent : .ok }
        let pool = makePool(port: other.port)
        defer { pool.closeAll() }
        await assertAnswered(exchange(pool, "http://warm.test/"), "gives the other upstream a measured latency")
        config.withLockedValue { $0.upstreams.insert(UpstreamProxy(name: "subject", host: "127.0.0.1", port: subject.port, priority: 0), at: 0) }
        try await tripOnAnAnswerAndWaitForTheProbe(pool)

        await assertAnswered(exchange(pool, "http://fast.test/first"))
        XCTAssertEqual(subject.requestLines.filter { $0.hasPrefix("GET ") }, [], "the upstream with a measured latency wins the duel")
        XCTAssertEqual(status(pool)?.circuitState, .open, "the loser took no probe slot")
        XCTAssertEqual(events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_half_opened" }.count, 0)

        otherFallsSilent.withLockedValue { $0 = true }
        assertTimedOut(await exchange(pool, "http://a.test/"))
        assertTimedOut(await exchange(pool, "http://b.test/"), "trips the other upstream")
        await assertAnswered(exchange(pool, "http://fast.test/second"), "the duel's loser carries the probe")
        XCTAssertEqual(subject.requestLines.filter { $0.hasPrefix("GET ") }.count, 1)
        XCTAssertEqual(status(pool)?.circuitState, .closed)
    }

    // MARK: - The ledger's lifetime

    func testDisablingAndReEnablingAnUpstreamDropsItsPendingSilences() async throws {
        let upstream = try await startUpstream { _, _ in .silent }
        let pool = makePool(port: upstream.port)
        defer { pool.closeAll() }

        assertTimedOut(await exchange(pool, "http://a.test/"))
        config.withLockedValue { $0.upstreams[0].enabled = false }
        XCTAssertEqual(pool.upstreamStatuses(), [])
        config.withLockedValue { $0.upstreams[0].enabled = true }

        assertTimedOut(await exchange(pool, "http://b.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "a re-enabled upstream starts with no pending silence")
        assertTimedOut(await exchange(pool, "http://c.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .open)
    }

    func testEditingAnUpstreamEndpointDropsItsPendingSilences() async throws {
        let old = try await startUpstream { _, _ in .silent }
        let new = try await startUpstream { _, _ in .silent }
        let pool = makePool(port: old.port)
        defer { pool.closeAll() }

        assertTimedOut(await exchange(pool, "http://a.test/"))
        config.withLockedValue { $0.upstreams[0].port = new.port }

        assertTimedOut(await exchange(pool, "http://b.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the move dropped a.test; b.test is the only pending origin")
        assertTimedOut(await exchange(pool, "http://c.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .open)
        XCTAssertEqual(old.requestLines.count, 1)
    }

    func testASilenceFromTheOldEndpointAfterAnEditRecordsNothing() async throws {
        let old = try await startUpstream { _, _ in .silent }
        let new = try await startUpstream { _, _ in .silent }
        let pool = makePool(port: old.port)
        defer { pool.closeAll() }

        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://a.test/")
        head.headers.add(name: "Host", value: "a.test")
        let inFlight = pool.exchange(head: head, body: nil)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(old.requestLines.count, 1, "the exchange to the old endpoint is in flight")
        config.withLockedValue { $0.upstreams[0].port = new.port }
        do {
            _ = try await inFlight.get()
            XCTFail("the old endpoint never answers")
        } catch {
            XCTAssertTrue(ConnectionPoolError.isUpstreamResponseTimedOut(error), "\(error)")
        }

        assertTimedOut(await exchange(pool, "http://b.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .closed, "the old endpoint's silence is not the new endpoint's; b.test is the only pending origin")
        assertTimedOut(await exchange(pool, "http://c.test/"))
        XCTAssertEqual(status(pool)?.circuitState, .open)
    }

    func testEditingAnUpstreamEndpointRetiresItsIdleConnections() async throws {
        let old = try await startUpstream { _, _ in .ok }
        let new = try await startUpstream { _, _ in .ok }
        let pool = makePool(port: old.port)
        defer { pool.closeAll() }

        await assertAnswered(exchange(pool, "http://warm.test/"), "leaves an idle connection to the old endpoint")
        config.withLockedValue { $0.upstreams[0].port = new.port }

        await assertAnswered(exchange(pool, "http://after.test/"))
        XCTAssertEqual(new.requestLines.map { $0.components(separatedBy: " ")[1] }, ["http://after.test/"], "the idle connection to the old host was not reused")
        XCTAssertEqual(old.requestLines.count, 1)
    }

    // MARK: - Pure values

    func testTheLedgerHoldsAtMostTheDecisiveOriginsAndAnAnswerEmptiesIt() {
        var ledger = UpstreamSilences()
        XCTAssertFalse(ledger.recordSilence(origin: .authority("a.test", defaultPort: 80)))
        XCTAssertFalse(ledger.recordSilence(origin: .authority("a.test:80", defaultPort: 443)), "the same origin again is still one origin")
        XCTAssertTrue(ledger.recordSilence(origin: .authority("b.test", defaultPort: 80)))
        XCTAssertTrue(ledger.recordSilence(origin: .authority("c.test", defaultPort: 80)))
        XCTAssertEqual(ledger.origins.count, UpstreamSilences.decisiveOrigins, "a third origin is not kept")
        ledger.recordAnswer()
        XCTAssertEqual(ledger.origins, [])
        XCTAssertFalse(ledger.recordSilence(origin: .authority("c.test", defaultPort: 80)))
    }

    func testAnOriginIsOneHostPortHoweverTheRequestSpellsIt() {
        func origin(_ method: HTTPMethod, _ uri: String, host: String? = nil) -> String {
            var head = HTTPRequestHead(version: .http1_1, method: method, uri: uri)
            if let host { head.headers.add(name: "Host", value: host) }
            return ExchangeOrigin(head).hostPort
        }
        XCTAssertEqual(origin(.GET, "http://Example.test/path"), "example.test:80")
        XCTAssertEqual(origin(.GET, "https://example.test/"), "example.test:443")
        XCTAssertEqual(origin(.GET, "http://example.test:8080/"), "example.test:8080")
        XCTAssertEqual(origin(.CONNECT, "Example.test:443"), "example.test:443")
        XCTAssertEqual(origin(.CONNECT, "example.test:0443"), "example.test:443")
        XCTAssertEqual(origin(.CONNECT, "example.test"), "example.test:443")
        XCTAssertEqual(origin(.CONNECT, "[0:0:0:0:0:0:0:1]:443"), "[::1]:443")
        XCTAssertEqual(origin(.CONNECT, "[::1]"), "[::1]:443")
        XCTAssertEqual(origin(.GET, "/relative", host: "example.test:8080"), "example.test:8080")
        XCTAssertEqual(origin(.GET, "/relative", host: "Example.test"), "example.test:80")
    }
}
