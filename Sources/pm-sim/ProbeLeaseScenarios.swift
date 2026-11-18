// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyKernel

/// A half-open probe that ends without a verdict hands its slot back, a CONNECT whose dial is refused is the
/// probe's failure, a streamed probe is answered at its response head, and a failure from before a flap reset is
/// not counted (#279), through the real pool, CONNECT coordinator and exchange handlers over loopback. It dials
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
                        } else if requestLine.contains("stream.test") {
                            plainRequests.withLockedValue { $0 += 1 }
                            response = "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nfirst\r\n"
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

    /// The client side of a streamed exchange: a loopback connection whose far end reports when the response
    /// head the pool forwarded has arrived.
    private struct StreamClient {
        let channel: Channel
        let headArrived: EventLoopFuture<Void>

        @RuntimeActor static func open(group: EventLoopGroup) async throws -> StreamClient {
            let arrived = group.next().makePromise(of: Void.self)
            let reader = try await ServerBootstrap(group: group)
                .childChannelInitializer { $0.pipeline.addHandler(HeadWatcher(arrived)) }
                .bind(host: "127.0.0.1", port: 0).get()
            ScenarioCleanup.register { reader.close(promise: nil) }
            guard let port = reader.localAddress?.port else {
                arrived.fail(ScenarioExecutionError(message: "the stream reader has no port"))
                throw ScenarioExecutionError(message: "the stream reader has no port")
            }
            let channel = try await ClientBootstrap(group: group)
                .channelInitializer { $0.pipeline.addHandler(HTTPResponseEncoder()) }
                .connect(host: "127.0.0.1", port: port).get()
            ScenarioCleanup.register { channel.close(promise: nil) }
            return StreamClient(channel: channel, headArrived: arrived.futureResult)
        }

        private final class HeadWatcher: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let arrived: EventLoopPromise<Void>
            private var received = ""

            init(_ arrived: EventLoopPromise<Void>) { self.arrived = arrived }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                received += buffer.readString(length: buffer.readableBytes) ?? ""
                if received.contains("\r\n\r\n") { arrived.succeed() }
            }

            func channelInactive(context: ChannelHandlerContext) {
                arrived.fail(ScenarioExecutionError(message: "the stream closed before its head arrived"))
                context.fireChannelInactive()
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
            await outcome(of: coordinator.connectUpstreamTunnel(target: target, proxyChain: chain))
        }

        func outcome(of tunnel: EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)>) async -> Error? {
            do {
                try await tunnel.get().channel.close().get()
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

        let streamer = AnsweringUpstream(), spare = AnsweringUpstream()
        for upstream in [streamer, spare] {
            ScenarioCleanup.register {
                do {
                    try await upstream.stop()
                } catch {
                    logger.log(.warning, "\(name): upstream listener close: \(error)", category: .proxy)
                }
            }
            try await upstream.start(group: group)
        }
        let streaming = Fixture(upstreams: [
            UpstreamProxy(name: "streamer", host: "127.0.0.1", port: streamer.port, priority: 0),
            UpstreamProxy(name: "spare", host: "127.0.0.1", port: spare.port, priority: 1),
        ], group: group, logger: logger)
        ScenarioCleanup.register { streaming.pool.closeAll() }
        try await streaming.tripWithCONNECT("streamer")
        try await streaming.tripWithCONNECT("spare")
        let client = try await StreamClient.open(group: group)
        let streamHead = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://stream.test/events", headers: ["Host": "stream.test"])
        let stream = streaming.pool.streamingExchange(head: streamHead, body: nil, clientChannel: client.channel)
        try await client.headArrived.get()
        let streamerAtHead = streaming.state("streamer")
        var whileStreaming: [Result<Int, Error>] = []
        for index in 0..<3 { whileStreaming.append(await streaming.get("http://during.test/\(index)")) }
        let servedWhileStreaming = streamer.served
        streaming.pool.closeAll()
        let streamCut: Error?
        do {
            _ = try await stream.get()
            streamCut = nil
        } catch {
            streamCut = error
        }
        let streamerOpened = streaming.details("upstream.circuit_opened", upstream: "streamer")

        let parkable = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        ScenarioCleanup.register {
            do {
                try await parkable.shutdownGracefully()
            } catch {
                logger.log(.warning, "\(name): event loop group shutdown: \(error)", category: .proxy)
            }
        }
        let flap = Fixture(upstreams: [UpstreamProxy(name: "refusing", host: "127.0.0.1", port: refusedPort, priority: 0)], group: parkable, logger: logger)
        ScenarioCleanup.register { flap.pool.closeAll() }
        let resume = park(parkable)
        let staleDial = flap.coordinator.connectUpstreamTunnel(target: "before-flap.test:443")
        flap.pool.resetCircuitsAfterFlap()
        resume.signal()
        let staleError = await flap.outcome(of: staleDial)
        let stateAfterStale = flap.state("refusing")
        let staleDropped = flap.details("upstream.stale_failure_dropped", upstream: "refusing")
        let freshError = await flap.connect("after-flap.test:443")

        let localReleased = local.details("upstream.probe_released", upstream: "first")
        let refusingOpened = dial.details("upstream.circuit_opened", upstream: "refusing")
        let refusingHalfOpened = dial.details("upstream.circuit_half_opened", upstream: "refusing")
        let localFailed: Bool
        if case .failure(let error) = refusedProbe { localFailed = ConnectionPoolError.isAuthHandshakeLimitExceeded(error) } else { localFailed = false }

        return ScenarioResult(
            name: name, clientCount: 12, clientsOpened: 12, clientsWithFirstByte: 7,
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
                .init("a streamed probe's response head closed the breaker while the stream stayed open",
                      streamerAtHead == .closed && streaming.details("upstream.circuit_half_opened", upstream: "streamer").count == 1),
                .init("the streaming upstream served the next requests, and the other upstream was never asked",
                      whileStreaming.allSatisfy { if case .success(200) = $0 { true } else { false } } && servedWhileStreaming == 4
                          && spare.served == 0 && streaming.details("upstream.circuit_half_opened", upstream: "spare").isEmpty),
                .init("a stream cut after its head failed a closed upstream, not the probe",
                      streamCut.map(ConnectionPoolError.isStreamingResponseInterrupted) == true && streamerOpened.count == 2
                          && streamerOpened.last?.contains(" reason=threshold ") == true),
                .init("a CONNECT dial that started before a flap reset and failed after it did not reopen the breaker",
                      staleError.map { !ConnectionPoolError.isLocalNonUpstreamFailure($0) } == true && stateAfterStale == .closed
                          && staleDropped.count == 1 && staleDropped[0].hasSuffix(" origin=before-flap.test:443 verdict=failure")),
                .init("a CONNECT dial that started after the reset counted",
                      freshError != nil && flap.state("refusing") == .open),
            ],
            notes: [
                "first: \(first.served) plain requests served; second: \(second.served)",
                "released: \(localReleased)",
                "refusing opened: \(refusingOpened)",
                "refusing half-opened: \(refusingHalfOpened.count)",
                "streamer: \(streamer.served) plain requests served; spare: \(spare.served); opened: \(streamerOpened)",
                "stale failures dropped: \(staleDropped)",
            ]
        )
    }

    /// Holds `group`'s only event loop until the returned semaphore is signalled, so a dial started meanwhile
    /// lands only after the scenario's next steps.
    private static func park(_ group: MultiThreadedEventLoopGroup) -> DispatchSemaphore {
        let parked = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        group.next().execute {
            parked.signal()
            resume.wait()
        }
        parked.wait()
        return resume
    }
}
