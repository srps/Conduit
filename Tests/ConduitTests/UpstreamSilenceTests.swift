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
        let pool = makePool(upstreams: [UpstreamProxy(name: "a", host: "127.0.0.1", port: upstream.port, priority: 0)])
        let first = await pool.healthCheck(urlString: "http://check.test/")
        XCTAssertTrue(first.healthy, first.summary)

        let second = await pool.healthCheck(urlString: "http://check.test/")

        guard case .answerTimedOut? = second.failure else {
            return XCTFail("connected and never answered, got \(String(describing: second.failure))")
        }
        XCTAssertEqual(upstream.connections, 2, "the silent idle connection was followed by one fresh connection")
        pool.closeAll()
        try await upstream.close()
    }

    func testTwoConcurrentSlowRequestsBehindAHealthyPrimaryLeaveItServing() async throws {
        let primary = try await CountingUpstream.start(answers: .max) { $0.contains("/slow") }
        let secondary = try await CountingUpstream.start(answers: .max)
        let first = UpstreamProxy(name: "primary", host: "127.0.0.1", port: primary.port, priority: 0)
        let second = UpstreamProxy(name: "secondary", host: "127.0.0.1", port: secondary.port, priority: 1)
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

    func testASecondSilenceInARowRanksTheUpstreamBehindOneThatAnswers() async throws {
        let primary = try await CountingUpstream.start(answers: 1)
        let secondary = try await CountingUpstream.start(answers: .max)
        let first = UpstreamProxy(name: "primary", host: "127.0.0.1", port: primary.port, priority: 0)
        let second = UpstreamProxy(name: "secondary", host: "127.0.0.1", port: secondary.port, priority: 1)
        let events = Events()
        let current = NIOLockedValueBox(Self.config(upstreams: [first]))
        let pool = makePool(config: current, events: events)
        let served = try await pool.exchange(head: Self.head, body: nil).get()
        XCTAssertEqual(served.upstream.id, first.id, "the primary answered and has a latency")
        current.withLockedValue { $0.upstreams = [first, second] }

        for attempt in 1...2 {
            do {
                let response = try await pool.exchange(head: Self.head, body: nil).get()
                XCTFail("attempt \(attempt) was answered by \(response.upstream.name)")
            } catch {
                XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut, "attempt \(attempt)")
            }
        }
        XCTAssertEqual(primary.requests, 3, "one silence left the primary first, so the second request went to it too")

        let after = try await pool.exchange(head: Self.head, body: nil).get()

        XCTAssertEqual(after.upstream.id, second.id, "the second silence in a row ranked the primary behind the secondary")
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

        for _ in 0..<2 { pool.recordExchangeFailure(ConnectionPoolError.upstreamResponseTimedOut, for: config.upstreams[0]) }

        XCTAssertEqual(events.details("upstream.deprioritized"), [], "late silences on an open breaker must not hide its half-open probe")
        pool.closeAll()
    }

    private static let head = head(path: "/")

    private static func head(path: String) -> HTTPRequestHead {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com\(path)")
        head.headers.add(name: "Host", value: "example.com")
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

    private final class CountingUpstream: @unchecked Sendable {
        private let answers: NIOLockedValueBox<Int>
        private let counts = NIOLockedValueBox((connections: 0, requests: 0))
        private let lines = NIOLockedValueBox<[String]>([])
        private var listener: Channel?
        private let children = NIOLockedValueBox<[Channel]>([])

        var port: Int { listener?.localAddress?.port ?? 0 }
        var connections: Int { counts.withLockedValue { $0.connections } }
        var requests: Int { counts.withLockedValue { $0.requests } }
        var requestLines: [String] { lines.withLockedValue { $0 } }

        private init(answers: Int) { self.answers = NIOLockedValueBox(answers) }

        /// `silentTo` names the request lines it never answers, as a healthy proxy whose origin for them is slow.
        static func start(answers: Int, silentTo: @escaping @Sendable (String) -> Bool = { _ in false }) async throws -> CountingUpstream {
            let upstream = CountingUpstream(answers: answers)
            let answers = upstream.answers, counts = upstream.counts, lines = upstream.lines, children = upstream.children
            upstream.listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    counts.withLockedValue { $0.connections += 1 }
                    children.withLockedValue { $0.append(channel) }
                    return channel.pipeline.addHandler(RequestHandler(answers: answers, silentTo: silentTo, counts: counts, lines: lines))
                }
                .bind(host: "127.0.0.1", port: 0).get()
            return upstream
        }

        /// New connects are refused; accepted connections stay open and silent.
        func stopListening() async throws { try await listener?.close().get() }

        func close() async throws {
            if listener?.isActive == true { try await listener?.close().get() }
            for child in children.withLockedValue({ $0 }) where child.isActive {
                child.close(promise: nil)
            }
        }

        private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let answers: NIOLockedValueBox<Int>
            private let silentTo: @Sendable (String) -> Bool
            private let counts: NIOLockedValueBox<(connections: Int, requests: Int)>
            private let lines: NIOLockedValueBox<[String]>
            private var pending = ""

            init(
                answers: NIOLockedValueBox<Int>, silentTo: @escaping @Sendable (String) -> Bool,
                counts: NIOLockedValueBox<(connections: Int, requests: Int)>, lines: NIOLockedValueBox<[String]>
            ) {
                self.answers = answers
                self.silentTo = silentTo
                self.counts = counts
                self.lines = lines
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                pending += buffer.readString(length: buffer.readableBytes) ?? ""
                while let end = pending.range(of: "\r\n\r\n") {
                    let line = pending[pending.startIndex..<end.lowerBound].components(separatedBy: "\r\n").first ?? ""
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    counts.withLockedValue { $0.requests += 1 }
                    lines.withLockedValue { $0.append(line) }
                    let answered = !silentTo(line) && answers.withLockedValue { left in
                        guard left > 0 else { return false }
                        left -= 1
                        return true
                    }
                    guard answered else { continue }
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                    context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: response)), promise: nil)
                }
            }
        }
    }
}
