// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyKernel

/// The recovery ladder's reauthenticate step (`ConnectionPool.resetAuthentication`)
/// landing while an exchange is in flight, through the real pool and its
/// exchange handler over loopback with mock Negotiate credentials. The
/// upstream holds the first response until the reset has returned, so the
/// order is forced, not timed. When that exchange ends it must not mark the
/// connection authenticated again: the next request on the same connection
/// carries credentials, and the one after it does not, so a reset costs one
/// handshake, not one per request.
///
/// The upstream keeps only whether each request carried
/// `Proxy-Authorization`, never its value. Every wait on the fixture has a
/// fixed bound, and cleanup closes the pool, every accepted connection and
/// the listener whether the scenario passes or fails.
enum PoolConcurrencyScenarios {
    private static let name = "pool-auth-reset-during-exchange"
    /// Generous for loopback; only a broken fixture or pool reaches it.
    private static let fixtureBound = TimeAmount.seconds(5)
    /// Longer than `fixtureBound`: a hang is reported by the fixture
    /// deadline, and only the held response ends the first exchange.
    private static let responseTimeoutSeconds: TimeInterval = 30
    private static let requestCount = 3
    private static let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://origin.test/",
                                              headers: ["Host": "origin.test"])

    private struct FixtureDeadline: Error, CustomStringConvertible {
        let waitingFor: String
        var description: String { "waited longer than the fixture bound for \(waitingFor)" }
    }

    @RuntimeActor
    static func authResetDuringExchange(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let observed = NIOLockedValueBox(UpstreamObservation())
        let children = NIOLockedValueBox<[Channel]>([])
        let firstRequest = group.next().makePromise(of: Channel.self)
        // A no-op once the upstream has completed it.
        ScenarioCleanup.register { firstRequest.fail(ScenarioExecutionError(message: "scenario ended before the first request")) }
        let server = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let admitted = observed.withLockedValue { state -> Bool in
                    state.accepted += 1
                    guard state.accepted <= UpstreamObservation.connectionCapacity else {
                        state.refused += 1
                        return false
                    }
                    return true
                }
                guard admitted else {
                    return channel.eventLoop.makeFailedFuture(ScenarioExecutionError(message: "upstream connection over the fixture bound"))
                }
                children.withLockedValue { $0.append(channel) }
                return channel.pipeline.addHandler(HeldFirstResponseUpstream(observed: observed, firstRequest: firstRequest))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        ScenarioCleanup.register { await cleanupFixture(server, "upstream listener", logger: logger) }
        ScenarioCleanup.register {
            for child in children.withLockedValue({ $0 }) { await cleanupFixture(child, "upstream connection", logger: logger) }
        }
        guard let port = server.localAddress?.port else {
            throw ScenarioExecutionError(message: "upstream listener has no port")
        }

        var config = ProxyConfig()
        config.upstreams = [UpstreamProxy(name: "Held response", host: "127.0.0.1", port: port, priority: 0)]
        config.upstreamResponseTimeoutSeconds = responseTimeoutSeconds
        let frozenConfig = config
        let pool = ConnectionPool(group: group, logger: logger, configProvider: { frozenConfig },
                                  authenticatorProvider: { _ in MockAuthenticator() })
        ScenarioCleanup.register { pool.closeAll() }

        let first = pool.exchange(head: head, body: nil)
        let held = try await within(firstRequest.futureResult, "the first request to reach the upstream")
        let inFlight = pool.allConnectionSnapshot
        let resetMidExchange = inFlight.count == 1 && inFlight.allSatisfy(\.inUse)
        pool.resetAuthentication()
        try await within(held.writeAndFlush(ByteBuffer(string: HeldFirstResponseUpstream.ok)), "the held response to be written")
        let firstResponse = try await within(first, "the held exchange to end")
        let afterHeld = pool.allConnectionSnapshot
        let reauthenticationPending = afterHeld.count == 1 && afterHeld.allSatisfy { !$0.authenticated && !$0.inUse }

        let second = try await within(pool.exchange(head: head, body: nil), "the request after the reset")
        let afterSecond = pool.allConnectionSnapshot
        let reauthenticated = afterSecond.count == 1 && afterSecond.allSatisfy(\.authenticated)
        let third = try await within(pool.exchange(head: head, body: nil), "the request after the re-handshake")
        let afterThird = pool.allConnectionSnapshot

        let retired = pool.closeAll()
        for connection in afterThird {
            try await within(connection.channel.closeFuture, "the pooled connection to close")
        }
        try await closeFixture(server, "upstream listener")
        for child in children.withLockedValue({ $0 }) {
            try await closeFixture(child, "upstream connection")
        }

        let seen = observed.withLockedValue { $0 }
        let presence = seen.credentialPresence
        let ids = [inFlight, afterHeld, afterSecond, afterThird].map { $0.map(\.id) }
        let oneConnection = seen.accepted == 1 && ids.allSatisfy { $0.count == 1 && $0 == ids[0] }
        let completed = [firstResponse, second, third].filter { $0.head.status == .ok }.count
        return ScenarioResult(
            name: name, clientCount: requestCount, clientsOpened: completed, clientsWithFirstByte: completed,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("the first request on a fresh connection carried credentials", presence.first == true),
                .init("the reset ran while the first exchange held the connection", resetMidExchange),
                .init("every exchange completed with 200", completed == requestCount),
                .init("the held exchange left the connection to authenticate again", reauthenticationPending),
                .init("the request after the reset carried credentials", presence.dropFirst().first == true),
                .init("its success marked the connection authenticated", reauthenticated),
                .init("the request after that carried none: one re-handshake, not one per request",
                      presence.dropFirst(2).first == false),
                .init("every request rode the one pooled connection", oneConnection && presence.count == requestCount),
                .init("no connection or request exceeded the fixture bounds", seen.refused == 0),
                .init("teardown retired the one pooled connection", retired == 1),
            ],
            notes: [
                "requests=\(presence.count) acceptedConnections=\(seen.accepted)",
                "credentials=\(presence.map { $0 ? "present" : "absent" }.joined(separator: ","))",
                "Mock Negotiate credentials over loopback; Proxy-Authorization recorded as presence only",
            ]
        )
    }

    /// `future`, or a `FixtureDeadline` once `fixtureBound` has passed.
    private static func within<T: Sendable>(_ future: EventLoopFuture<T>, _ waitingFor: String) async throws -> T {
        let bounded = future.eventLoop.makePromise(of: T.self)
        let deadline = future.eventLoop.scheduleTask(in: fixtureBound) {
            bounded.fail(FixtureDeadline(waitingFor: waitingFor))
        }
        future.whenComplete { result in
            deadline.cancel()
            bounded.completeWith(result)
        }
        return try await bounded.futureResult.get()
    }

    private static func closeFixture(_ channel: Channel, _ what: String) async throws {
        do {
            try await within(channel.close(), "fixture \(what) to close")
        } catch ChannelError.alreadyClosed {
        }
    }

    private static func cleanupFixture(_ channel: Channel, _ what: String, logger: ConsoleLogSink) async {
        do {
            try await closeFixture(channel, what)
        } catch {
            logger.log(.warning, "fixture \(what) close: \(error)", category: .proxy)
        }
    }
}

/// What the upstream saw, bounded: at most `connectionCapacity` accepted
/// connections and `requestCapacity` requests are served; more are refused
/// and counted.
private struct UpstreamObservation: Sendable {
    static let connectionCapacity = 2
    static let requestCapacity = 4

    var accepted = 0
    var refused = 0
    /// Whether each request carried `Proxy-Authorization`, in arrival order.
    var credentialPresence: [Bool] = []
}

/// A keep-alive upstream that answers every request `200` except the first,
/// whose channel it hands to the scenario to answer. The requests are
/// bodiless GETs, so a head is a request. Per-connection state is confined
/// to its channel's event loop.
private final class HeldFirstResponseUpstream: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    static let ok = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
    private static let headCapacity = 8_192
    private static let credentialHeader = "proxy-authorization:"

    private let observed: NIOLockedValueBox<UpstreamObservation>
    private let firstRequest: EventLoopPromise<Channel>
    private var received = ""

    init(observed: NIOLockedValueBox<UpstreamObservation>, firstRequest: EventLoopPromise<Channel>) {
        self.observed = observed
        self.firstRequest = firstRequest
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        guard buffer.readableBytes <= Self.headCapacity - received.utf8.count else {
            observed.withLockedValue { $0.refused += 1 }
            context.close(promise: nil)
            return
        }
        received += buffer.readString(length: buffer.readableBytes) ?? ""
        while let end = received.range(of: "\r\n\r\n") {
            let lines = received[..<end.lowerBound].split(separator: "\r\n")
            received.removeSubrange(..<end.upperBound)
            guard lines.first?.hasPrefix("GET ") == true else { continue }
            // Only the header name is compared; the value is never read.
            let credentials = lines.dropFirst().contains {
                $0.prefix(Self.credentialHeader.count).lowercased() == Self.credentialHeader
            }
            let index: Int? = observed.withLockedValue { state in
                guard state.credentialPresence.count < UpstreamObservation.requestCapacity else {
                    state.refused += 1
                    return nil
                }
                state.credentialPresence.append(credentials)
                return state.credentialPresence.count - 1
            }
            guard let index else {
                context.close(promise: nil)
                return
            }
            if index == 0 {
                firstRequest.succeed(context.channel)
            } else {
                context.writeAndFlush(wrapOutboundOut(ByteBuffer(string: Self.ok)), promise: nil)
            }
        }
    }
}
