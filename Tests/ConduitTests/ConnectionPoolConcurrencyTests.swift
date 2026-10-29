// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The pool's membership and per-connection state against what runs beside
/// it: an acquisition while connections are being retired, a control-plane
/// `closeAll` as a dedicated tunnel is published, and a reauthentication
/// while an exchange is in flight.
///
/// Every interleaving is forced, not hoped for. Each test runs the
/// competing operation from a callback the pool itself makes at the point in
/// question, on the connection's own loop, so the order is the same on every
/// run. Every upstream channel is a real loopback channel on
/// `MultiThreadedEventLoopGroup.singleton`, and every one is closed before
/// the test ends; a streaming exchange's client is a testing channel.
final class ConnectionPoolConcurrencyTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton
    private let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://origin.test/",
                                       headers: ["Host": "origin.test"])

    // MARK: - Retirement is atomic with acquisition

    /// `closeAll(scope: .idleOnly)` chooses idle connections. If it chose
    /// them and only removed them after closing them, an acquisition in
    /// between could take one it had chosen, and the close would then end an
    /// exchange `.idleOnly` promises to keep. Each close here checks, at the
    /// moment it starts, that no connection being retired is still a pool
    /// member, which is what an acquisition needs to take it.
    func testCloseAllRemovesEveryConnectionItRetiresBeforeClosingAny() async throws {
        try await assertRetirementPrecedesClose(expected: 2) { pool in
            pool.closeAll(scope: .idleOnly)
        }
    }

    /// The same for the recovery ladder's stalled-connection step.
    func testCloseStalledRemovesEveryConnectionItRetiresBeforeClosingAny() async throws {
        try await assertRetirementPrecedesClose(expected: 2) { pool in
            // A negative age puts the cutoff in the future: every idle
            // connection is stalled now, without waiting for one to age.
            pool.closeStalledConnections(olderThan: -1)
        }
    }

    /// Prewarms two idle connections on one loop, puts a close probe at the
    /// tail of each pipeline, then runs `retire` on that loop. A close called
    /// on its channel's loop reaches the probe inline, so each probe runs
    /// inside `retire`, before `retire` has closed the other channel.
    private func assertRetirementPrecedesClose(
        expected: Int,
        file: StaticString = #filePath, line: UInt = #line,
        _ retire: @escaping @Sendable (ConnectionPool) -> Int
    ) async throws {
        let server = try await acceptingServer()
        let loop = group.next()
        // One loop as the pool's group, so both connections share it.
        let pool = ConnectionPool(group: loop, logger: DiscardingLogSink(), configProvider: configProvider(for: server),
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") })
        addTeardownBlock { pool.closeAll() }

        await pool.prewarmConnections(perUpstream: expected)
        let connections = pool.allConnectionSnapshot
        XCTAssertEqual(connections.count, expected, "prewarm leaves its connections idle", file: file, line: line)
        XCTAssertTrue(connections.allSatisfy { !$0.inUse }, file: file, line: line)
        let retiring = Set(connections.map(\.id))

        let membersAtClose = NIOLockedValueBox<[Set<UUID>]>([])
        for connection in connections {
            let probe = CloseProbe {
                let members = Set(pool.allConnectionSnapshot.map(\.id))
                membersAtClose.withLockedValue { $0.append(members) }
            }
            try await connection.channel.pipeline.addHandler(probe).get()
        }

        let retired = try await loop.submit { retire(pool) }.get()

        XCTAssertEqual(retired, expected, file: file, line: line)
        let seen = membersAtClose.withLockedValue { $0 }
        XCTAssertEqual(seen.count, expected, "every retired channel is closed", file: file, line: line)
        for members in seen {
            XCTAssertTrue(members.isDisjoint(with: retiring),
                          "a connection being retired was still acquirable when a close began",
                          file: file, line: line)
        }
        XCTAssertTrue(pool.allConnectionSnapshot.isEmpty, file: file, line: line)
        for connection in connections {
            connection.channel.close(mode: .all, promise: nil)
            try await connection.channel.closeFuture.get()
        }
    }

    // MARK: - A dedicated tunnel is classified before it is published

    /// A control-plane `closeAll(scope: .allButDedicated)` keeps dedicated
    /// CONNECT tunnels. A tunnel the pool published before marking it
    /// dedicated could be taken for a pooled connection and closed. The pool
    /// logs the raw connect on the dial's loop right after publishing it;
    /// the sweep runs from that log line, the first moment any other caller
    /// could see the tunnel.
    func testAControlPlaneSweepAtPublicationKeepsTheNewDedicatedTunnel() async throws {
        let server = try await acceptingServer()
        let poolBox = NIOLockedValueBox<ConnectionPool?>(nil)
        let sweeps = NIOLockedValueBox<[Int]>([])
        let logger = MessageProbeLogSink { message in
            guard message.contains("(raw)"), let pool = poolBox.withLockedValue({ $0 }) else { return }
            let closed = pool.closeAll(scope: .allButDedicated)
            sweeps.withLockedValue { $0.append(closed) }
        }
        let pool = ConnectionPool(group: group, logger: logger, configProvider: configProvider(for: server),
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") })
        poolBox.withLockedValue { $0 = pool }
        // The logger holds the pool through the box; break the cycle.
        addTeardownBlock { poolBox.withLockedValue { $0 = nil } }

        let (tunnel, _) = try await pool.makeDedicatedTunnelConnection(target: "origin.test:443").get()

        XCTAssertEqual(sweeps.withLockedValue { $0 }, [0], "the sweep at publication closes nothing")
        XCTAssertTrue(tunnel.isDedicatedTunnel)
        XCTAssertTrue(tunnel.channel.isActive, "the new tunnel survives the sweep")
        XCTAssertEqual(pool.allConnectionSnapshot.map(\.id), [tunnel.id])

        XCTAssertEqual(pool.closeAll(scope: .all), 1)
        tunnel.channel.close(mode: .all, promise: nil)
        try await tunnel.channel.closeFuture.get()
    }

    // MARK: - A reauthentication is not undone by an exchange in flight

    /// `resetAuthentication` (the recovery ladder's reauthenticate step)
    /// makes every pooled connection authenticate again. An exchange that
    /// was already in flight used to mark its connection authenticated when
    /// it ended, so that connection skipped the new handshake. The upstream
    /// holds the first response until the reset has run, and the next
    /// request on the same connection must carry credentials again.
    func testAResetDuringAnExchangeMakesTheConnectionAuthenticateAgain() async throws {
        let upstream = try await heldFirstResponseUpstream()
        defer { upstream.deadline.cancel() }

        let first = upstream.pool.exchange(head: head, body: nil)
        first.whenFailure { upstream.firstRequest.fail($0) }
        try await resetWhileTheFirstResponseIsHeld(upstream)
        let firstResponse = try await first.get()
        XCTAssertEqual(firstResponse.head.status, .ok)

        let second = try await upstream.pool.exchange(head: head, body: nil).get()
        XCTAssertEqual(second.head.status, .ok)

        try await assertBothRequestsCarriedCredentials(upstream)
    }

    /// The same through the streaming path, which forwards each response to
    /// its client as it arrives and marks the connection on its own.
    func testAResetDuringAStreamingExchangeMakesTheConnectionAuthenticateAgain() async throws {
        let upstream = try await heldFirstResponseUpstream()
        defer { upstream.deadline.cancel() }
        // The exchange writes to its client from the upstream's loop: the
        // client needs a thread-safe loop. Connecting it only marks it active.
        let client = NIOAsyncTestingChannel()
        finishAtTearDown(client)
        try await client.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1)).get()

        let first = upstream.pool.streamingExchange(head: head, body: nil, clientChannel: client)
        first.whenFailure { upstream.firstRequest.fail($0) }
        try await resetWhileTheFirstResponseIsHeld(upstream)
        let firstResult = try await first.get()
        XCTAssertTrue(firstResult.keepAlive)
        try await assertForwardedOK(to: client)

        let second = try await upstream.pool.streamingExchange(head: head, body: nil, clientChannel: client).get()
        XCTAssertTrue(second.keepAlive)
        try await assertForwardedOK(to: client)

        try await assertBothRequestsCarriedCredentials(upstream)
    }

    /// A loopback upstream that holds its first response, and a pool that
    /// dials only it.
    private struct HeldFirstResponseUpstream {
        let pool: ConnectionPool
        let accepted: NIOLockedValueBox<Int>
        let requests: NIOLockedValueBox<[Bool]>
        let firstRequest: EventLoopPromise<Channel>
        /// Fails `firstRequest` after 10 s; the test cancels it when it ends.
        let deadline: Scheduled<Void>
    }

    private func heldFirstResponseUpstream() async throws -> HeldFirstResponseUpstream {
        let accepted = NIOLockedValueBox(0)
        let requests = NIOLockedValueBox<[Bool]>([])
        let firstRequest = group.next().makePromise(of: Channel.self)
        // A no-op once the upstream has completed it; otherwise a test that
        // failed early would leak the promise.
        addTeardownBlock { firstRequest.fail(ChannelError.ioOnClosedChannel) }
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        HeldFirstResponseHandler(requests: requests, firstRequest: firstRequest)
                    )
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try await server.close().get() }
        var settings = configProvider(for: server)()
        // The test releases the response; a broken fixture still has a deadline.
        settings.upstreamResponseTimeoutSeconds = 10
        let frozen = settings
        let pool = ConnectionPool(group: group, logger: DiscardingLogSink(), configProvider: { frozen },
                                  authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") })
        addTeardownBlock { pool.closeAll() }
        // Scheduled last: nothing after it throws, so the test's cancel
        // always runs.
        let deadline = group.next().scheduleTask(in: .seconds(10)) {
            firstRequest.fail(PoolFixtureFailure.firstRequestTimedOut)
        }
        return HeldFirstResponseUpstream(pool: pool, accepted: accepted, requests: requests,
                                         firstRequest: firstRequest, deadline: deadline)
    }

    /// Waits for the first request, resets authentication while its response
    /// is held, then sends that response.
    private func resetWhileTheFirstResponseIsHeld(_ upstream: HeldFirstResponseUpstream) async throws {
        let upstreamSide = try await upstream.firstRequest.futureResult.get()
        upstream.pool.resetAuthentication()
        try await upstreamSide.writeAndFlush(ByteBuffer(string: HeldFirstResponseHandler.ok)).get()
    }

    /// Both requests went over one connection and both carried credentials.
    /// Closes that connection.
    private func assertBothRequestsCarriedCredentials(
        _ upstream: HeldFirstResponseUpstream, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let seen = upstream.requests.withLockedValue { $0 }
        XCTAssertEqual(seen.count, 2, file: file, line: line)
        XCTAssertEqual(upstream.accepted.withLockedValue { $0 }, 1, "the second request reuses the first connection",
                       file: file, line: line)
        XCTAssertTrue(seen.allSatisfy { $0 }, "both requests carry credentials", file: file, line: line)

        let connections = upstream.pool.allConnectionSnapshot
        XCTAssertEqual(upstream.pool.closeAll(), 1, file: file, line: line)
        for connection in connections {
            connection.channel.close(mode: .all, promise: nil)
            try await connection.channel.closeFuture.get()
        }
    }

    /// Drains what one streaming exchange forwarded to `client`: the
    /// upstream's `200` head and the end of its empty body, nothing else.
    /// Only statuses and sizes are compared, never header bytes.
    private func assertForwardedOK(
        to client: NIOAsyncTestingChannel, file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        var forwarded: [String] = []
        while let part = try await client.readOutbound(as: HTTPServerResponsePart.self) {
            switch part {
            case .head(let head): forwarded.append("head \(head.status.code)")
            case .body(let body): forwarded.append("body \(body.readableBytes)")
            case .end(let trailers): forwarded.append(trailers == nil ? "end" : "end with trailers")
            }
        }
        XCTAssertEqual(forwarded, ["head 200", "end"], file: file, line: line)
    }

    // MARK: - Fixtures

    /// Accepts connections and never answers.
    private func acceptingServer() async throws -> Channel {
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try await server.close().get() }
        return server
    }

    private func configProvider(for server: Channel) -> @Sendable () -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "loopback", host: "127.0.0.1", port: server.localAddress?.port ?? 0, priority: 0)]
        let frozen = config
        return { frozen }
    }
}

/// Runs `onClose` when a close reaches the tail of the pipeline, then passes
/// it on.
private final class CloseProbe: ChannelOutboundHandler, Sendable {
    typealias OutboundIn = NIOAny

    private let onClose: @Sendable () -> Void

    init(onClose: @escaping @Sendable () -> Void) {
        self.onClose = onClose
    }

    func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
        onClose()
        context.close(mode: mode, promise: promise)
    }
}

/// Hands every log line to `onMessage`.
private struct MessageProbeLogSink: LogSink {
    let onMessage: @Sendable (String) -> Void

    var minLevel: LogLevel { .debug }

    func logImpl(_: LogLevel, _ message: String, category _: LogCategory) {
        onMessage(message)
    }
}

private enum PoolFixtureFailure: Error {
    case firstRequestTimedOut
}

/// Records credential presence, holds the first response, and answers the
/// second request. The test sends bodiless GETs, so a head is a request.
private final class HeldFirstResponseHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"

    private let requests: NIOLockedValueBox<[Bool]>
    private let firstRequest: EventLoopPromise<Channel>
    private var received = ""

    init(requests: NIOLockedValueBox<[Bool]>, firstRequest: EventLoopPromise<Channel>) {
        self.requests = requests
        self.firstRequest = firstRequest
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard received.utf8.count + buffer.readableBytes <= 16 * 1024 else {
            context.close(promise: nil)
            return
        }
        received += buffer.readString(length: buffer.readableBytes) ?? ""
        while let end = received.range(of: "\r\n\r\n") {
            let head = String(received[..<end.lowerBound])
            received.removeSubrange(..<end.upperBound)
            guard head.hasPrefix("GET ") else { continue }
            let count = requests.withLockedValue { requests in
                guard requests.count < 3 else { return requests.count }
                requests.append(head.lowercased().contains("\r\nproxy-authorization: basic fixture"))
                return requests.count
            }
            if count == 1 {
                firstRequest.succeed(context.channel)
            } else if count == 2 {
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: Self.ok)), promise: nil)
            } else {
                context.close(promise: nil)
            }
        }
    }
}
