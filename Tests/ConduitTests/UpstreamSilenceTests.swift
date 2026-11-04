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

    private static let head: HTTPRequestHead = {
        var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        head.headers.add(name: "Host", value: "example.com")
        return head
    }()

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

    /// Answers `200 OK` to as many requests as it has answers and leaves the rest unanswered, counting connections and requests.
    private final class CountingUpstream: @unchecked Sendable {
        private let answers: NIOLockedValueBox<Int>
        private let counts = NIOLockedValueBox((connections: 0, requests: 0))
        private var listener: Channel?
        private let children = NIOLockedValueBox<[Channel]>([])

        var port: Int { listener?.localAddress?.port ?? 0 }
        var connections: Int { counts.withLockedValue { $0.connections } }
        var requests: Int { counts.withLockedValue { $0.requests } }

        private init(answers: Int) { self.answers = NIOLockedValueBox(answers) }

        static func start(answers: Int) async throws -> CountingUpstream {
            let upstream = CountingUpstream(answers: answers)
            let answers = upstream.answers, counts = upstream.counts, children = upstream.children
            upstream.listener = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    counts.withLockedValue { $0.connections += 1 }
                    children.withLockedValue { $0.append(channel) }
                    return channel.pipeline.addHandler(RequestHandler(answers: answers, counts: counts))
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
            private let counts: NIOLockedValueBox<(connections: Int, requests: Int)>
            private var pending = ""

            init(answers: NIOLockedValueBox<Int>, counts: NIOLockedValueBox<(connections: Int, requests: Int)>) {
                self.answers = answers
                self.counts = counts
            }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                pending += buffer.readString(length: buffer.readableBytes) ?? ""
                while let end = pending.range(of: "\r\n\r\n") {
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    counts.withLockedValue { $0.requests += 1 }
                    let answered = answers.withLockedValue { left in
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
