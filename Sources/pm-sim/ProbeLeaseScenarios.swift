// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyKernel

/// A half-open probe that ends without a verdict hands its slot back, and a CONNECT whose dial is refused is the
/// probe's failure (#279), through the real pool, CONNECT coordinator and exchange handlers over loopback. It dials
/// only the listeners it starts and one port it closed itself.
enum ProbeLeaseScenarios {
    private static let name = "half-open-probe-lease"
    private static let authLimits = AuthHandshakeLimiter.Limits(total: 1, perSource: 1)

    private final class AnsweringUpstream: @unchecked Sendable {
        private let plainRequests = NIOLockedValueBox(0)
        private var channel: Channel?

        var port: Int { channel?.localAddress?.port ?? 0 }
        var served: Int { plainRequests.withLockedValue { $0 } }

        func start(group: EventLoopGroup) async throws {
            let plainRequests = self.plainRequests
            channel = try await ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(RequestLineHandler { channel, requestLine in
                        let response: String
                        if requestLine.hasPrefix("CONNECT ") {
                            response = "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                        } else {
                            plainRequests.withLockedValue { $0 += 1 }
                            response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                        }
                        channel.writeAndFlush(channel.allocator.buffer(string: response), promise: nil)
                    })
                }
                .bind(host: "127.0.0.1", port: 0).get()
        }

        func stop() async throws {
            try await channel?.close().get()
        }

        private final class RequestLineHandler: ChannelInboundHandler, @unchecked Sendable {
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

    private struct Fixture {
        let pool: ConnectionPool
        let coordinator: CONNECTCoordinator
        let limiter: AuthHandshakeLimiter
        let config: NIOLockedValueBox<ProxyConfig>
        let events: NIOLockedValueBox<[RuntimeEvent]>

        init(upstreams: [UpstreamProxy], group: EventLoopGroup, logger: any LogSink) {
            var config = ProxyConfig()
            config.upstreams = upstreams
            config.upstreamResponseTimeoutSeconds = 2
            config.circuitBreakerWindowSeconds = 0
            config.circuitFailureThreshold = 1
            config.circuitBaseOpenIntervalSeconds = 300
            config.circuitMaxOpenIntervalSeconds = 600
            config.pendingAuthHandshakeGlobalLimit = ProbeLeaseScenarios.authLimits.total
            config.pendingAuthHandshakesPerSource = ProbeLeaseScenarios.authLimits.perSource
            let box = NIOLockedValueBox(config), events = NIOLockedValueBox<[RuntimeEvent]>([])
            let limiter = AuthHandshakeLimiter()
            let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event) } }
            pool = ConnectionPool(
                group: group, logger: logger, configProvider: { box.withLockedValue { $0 } },
                authenticatorProvider: { _ in MockAuthenticator() }, authHandshakeLimiter: limiter, eventSink: sink
            )
            coordinator = CONNECTCoordinator(
                pool: pool, authenticatorProvider: { _ in MockAuthenticator() }, logger: logger,
                authHandshakeLimiter: limiter, authLimitProvider: { ProbeLeaseScenarios.authLimits }, eventSink: sink
            )
            self.limiter = limiter
            self.config = box
            self.events = events
        }

        func upstream(_ name: String) -> UpstreamProxy? { config.withLockedValue { $0.upstreams.first { $0.name == name } } }
        func state(_ name: String) -> UpstreamCircuitState? { pool.upstreamStatuses().first { $0.name == name }?.circuitState }
        func details(_ event: String, upstream name: String) -> [String] {
            events.withLockedValue { $0 }.filter { $0.event == event }.compactMap(\.detail).filter { $0.hasPrefix("upstream=\(name) ") }
        }

        func get(_ uri: String) async -> Result<Int, Error> {
            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: uri)
            head.headers.add(name: "Host", value: URL(string: uri)?.host ?? uri)
            do {
                return .success(Int(try await pool.exchange(head: head, body: nil).get().head.status.code))
            } catch {
                return .failure(error)
            }
        }

        /// The tunnel's error, or `nil` once it is established (and closed again).
        func connect(_ target: String, through chain: [UpstreamProxy] = []) async -> Error? {
            do {
                let established = try await coordinator.connectUpstreamTunnel(target: target, proxyChain: chain).get()
                try await established.channel.close().get()
                return nil
            } catch {
                return error
            }
        }

        func tripWithCONNECT(_ name: String) async throws {
            guard let proxy = upstream(name) else { throw ScenarioExecutionError(message: "no upstream \(name)") }
            let error = await connect("trip.test:443", through: [proxy])
            guard let error, ConnectionPoolError.isUpstreamAnswer(error), state(name) == .open else {
                throw ScenarioExecutionError(message: "the 502 did not open \(name): \(String(describing: error))")
            }
        }
    }

    @RuntimeActor
    static func probeLease(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let first = AnsweringUpstream(), second = AnsweringUpstream(), standby = AnsweringUpstream()
        for upstream in [first, second, standby] {
            ScenarioCleanup.register {
                do {
                    try await upstream.stop()
                } catch {
                    logger.log(.warning, "\(name): upstream listener close: \(error)", category: .proxy)
                }
            }
            try await upstream.start(group: group)
        }
        let closed = AnsweringUpstream()
        try await closed.start(group: group)
        let refusedPort = closed.port
        try await closed.stop()

        let local = Fixture(upstreams: [
            UpstreamProxy(name: "first", host: "127.0.0.1", port: first.port, priority: 0),
            UpstreamProxy(name: "second", host: "127.0.0.1", port: second.port, priority: 1),
        ], group: group, logger: logger)
        ScenarioCleanup.register { local.pool.closeAll() }
        try await local.tripWithCONNECT("first")
        try await local.tripWithCONNECT("second")
        guard case .success(let permit) = local.limiter.acquire(source: nil, limits: authLimits) else {
            throw ScenarioExecutionError(message: "the handshake limiter did not start empty")
        }
        let refusedProbe = await local.get("http://probe.test/")
        permit.release()
        let stateAfterLocalProbe = local.state("first"), servedBeforeRelease = first.served
        var after: [Result<Int, Error>] = []
        for index in 0..<3 { after.append(await local.get("http://after.test/\(index)")) }

        let dial = Fixture(upstreams: [UpstreamProxy(name: "refusing", host: "127.0.0.1", port: refusedPort, priority: 0)], group: group, logger: logger)
        ScenarioCleanup.register { dial.pool.closeAll() }
        let firstDial = await dial.connect("dial.test:443")
        let refusedOpened = dial.state("refusing") == .open
        dial.config.withLockedValue { $0.upstreams.append(UpstreamProxy(name: "standby", host: "127.0.0.1", port: standby.port, priority: 1)) }
        try await dial.tripWithCONNECT("standby")
        let probeTunnel = await dial.connect("probe.test:443")
        let reopenedAfterProbe = dial.state("refusing") == .open
        let againTunnel = await dial.connect("again.test:443")

        let localReleased = local.details("upstream.probe_released", upstream: "first")
        let refusingOpened = dial.details("upstream.circuit_opened", upstream: "refusing")
        let refusingHalfOpened = dial.details("upstream.circuit_half_opened", upstream: "refusing")
        let localFailed: Bool
        if case .failure(let error) = refusedProbe { localFailed = ConnectionPoolError.isAuthHandshakeLimitExceeded(error) } else { localFailed = false }

        return ScenarioResult(
            name: name, clientCount: 6, clientsOpened: 6, clientsWithFirstByte: 3,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("the forced probe of the longest-open upstream failed locally, before reaching it",
                      localFailed && servedBeforeRelease == 0 && local.details("upstream.circuit_half_opened", upstream: "first").count == 1),
                .init("the local failure handed the slot back without a verdict",
                      stateAfterLocalProbe == .halfOpen && localReleased.count == 1 && localReleased[0].hasSuffix(" origin=probe.test:80 ending=local")),
                .init("the next requests probed that upstream again, and it served all of them",
                      after.allSatisfy { if case .success(200) = $0 { true } else { false } } && first.served == 3 && local.state("first") == .closed),
                .init("the other upstream stayed open and was never asked",
                      local.state("second") == .open && second.served == 0 && local.details("upstream.circuit_half_opened", upstream: "second").isEmpty),
                .init("a refused CONNECT dial opened the breaker of a closed upstream",
                      firstDial.map { !ConnectionPoolError.isLocalNonUpstreamFailure($0) } == true && refusedOpened),
                .init("a CONNECT probe whose dial was refused reopened the breaker as the probe's failure",
                      probeTunnel != nil && reopenedAfterProbe && refusingOpened.contains { $0.contains(" reason=probe_failed ") }),
                .init("the next CONNECT probed the refusing upstream again",
                      againTunnel != nil && refusingHalfOpened.count == 2),
            ],
            notes: [
                "first: \(first.served) plain requests served; second: \(second.served)",
                "released: \(localReleased)",
                "refusing opened: \(refusingOpened)",
                "refusing half-opened: \(refusingHalfOpened.count)",
            ]
        )
    }
}
