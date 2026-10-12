// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// Real TCP sockets and production CONNECT/relay handlers. Only the retired
/// VPN address's failed syscall and blocked destination writes are injected.
enum TunnelFailureScenarios {
    private final class WriteFault: ChannelOutboundHandler, @unchecked Sendable {
        typealias OutboundIn = ByteBuffer
        enum Mode { case pass, reject, hold }
        private let mode = NIOLockedValueBox(Mode.pass)
        private let count = NIOLockedValueBox(0)
        private var held: [(NIOAny, EventLoopPromise<Void>?)] = []
        var pending: Int { count.withLockedValue { $0 } }
        func set(_ value: Mode) { mode.withLockedValue { $0 = value } }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            switch mode.withLockedValue({ $0 }) {
            case .pass: context.write(data, promise: promise)
            case .reject: promise?.fail(IOError(errnoCode: EADDRNOTAVAIL, reason: "injected retired VPN address"))
            case .hold:
                precondition(held.count < 4, "bounded fault fixture")
                held.append((data, promise)); count.withLockedValue { $0 = held.count }
            }
        }
        func flush(context: ChannelHandlerContext) {
            if case .pass = mode.withLockedValue({ $0 }) { context.flush() }
        }
        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            let writes = held; held.removeAll(); count.withLockedValue { $0 = 0 }
            context.close(mode: mode, promise: promise)
            for (_, pending) in writes { pending?.fail(ChannelError.ioOnClosedChannel) }
        }
    }

    private struct Pair: Sendable {
        let local: Channel
        let remote: Channel
        let localWrites: WriteFault
        let remoteWrites: WriteFault
    }

    private final class Capture: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let bytes = NIOLockedValueBox<[UInt8]>([])
        var received: String { bytes.withLockedValue { String(decoding: $0, as: UTF8.self) } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            bytes.withLockedValue {
                precondition($0.count + buffer.readableBytes <= 256, "bounded echo fixture")
                $0.append(contentsOf: buffer.readableBytesView)
            }
        }
    }

    @MainActor
    private static func until(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        return condition()
    }

    private static func closes(_ channel: Channel) async throws -> Bool {
        let result = channel.eventLoop.makePromise(of: Bool.self)
        let settled = NIOLockedValueBox(false)
        let timeout = channel.eventLoop.scheduleTask(in: .seconds(1)) {
            if settled.withLockedValue({ old in defer { old = true }; return !old }) { result.succeed(false) }
        }
        channel.closeFuture.whenComplete { _ in
            if settled.withLockedValue({ old in defer { old = true }; return !old }) {
                timeout.cancel(); result.succeed(true)
            }
        }
        return try await result.futureResult.get()
    }

    @MainActor
    static func vpnExistingStreamFailure(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Retired address", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let cause = NIOLockedValueBox(DirectModeCause.none)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) }) })
        orchestrator.onSnapshotChange = { snapshot in cause.withLockedValue { $0 = snapshot.directModeCause } }
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        let frozenConfig = config
        let pool = ConnectionPool(group: group, logger: logger, configProvider: { frozenConfig }, authenticatorProvider: { _ in MockAuthenticator() })
        ScenarioCleanup.register { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator() }, logger: logger)
        let events = RuntimeEventLog(capacity: 16)
        let reporter = TunnelFailureReporter(logger: logger, eventSink: { events.append($0) })
        let pairs = NIOLockedValueBox<[Pair]>([])
        let listener = try await listener(group: group, coordinator: coordinator, pool: pool, pairs: pairs, cause: cause, reporter: reporter)
        ScenarioCleanup.register { do { try await listener.close().get() } catch { logger.log(.warning, "fixture listener close: \(error)", category: .proxy) } }
        return try await exercise(listener: listener, group: group, pairs: pairs, orchestrator: orchestrator,
                                  events: events, started: started)
    }

    private static func listener(group: EventLoopGroup, coordinator: CONNECTCoordinator, pool: ConnectionPool,
                                 pairs: NIOLockedValueBox<[Pair]>, cause: NIOLockedValueBox<DirectModeCause>,
                                 reporter: TunnelFailureReporter) async throws -> Channel {
        try await ServerBootstrap(group: group).childChannelInitializer { local in
            coordinator.connectUpstreamTunnel(target: "stream.test:443").hop(to: local.eventLoop).flatMap { tunnel in
                let remote = tunnel.channel, localWrites = WriteFault(), remoteWrites = WriteFault()
                let diagnostics = TunnelRelayDiagnostics(target: "stream.test:443", transport: "connect", route: "upstream",
                    upstream: tunnel.endpoint, causeProvider: { cause.withLockedValue { $0 } }, reporter: reporter)
                return local.pipeline.addHandler(localWrites).flatMap {
                    local.pipeline.addHandler(makeTunnelRelay(peer: remote, diagnostics: diagnostics, side: .client,
                        onClose: { pool.removeDedicatedTunnelByChannel(remote) }))
                }.flatMap {
                    remote.pipeline.addHandler(remoteWrites)
                }.flatMap {
                    CONNECTCoordinator.attachRelay(makeTunnelRelay(peer: local, diagnostics: diagnostics, side: .remote), toUpstreamTunnel: remote)
                }.map {
                    pairs.withLockedValue {
                        precondition($0.count < 3, "bounded established fixture tunnels")
                        $0.append(Pair(local: local, remote: remote, localWrites: localWrites, remoteWrites: remoteWrites))
                    }
                }
            }
        }.bind(host: "127.0.0.1", port: 0).get()
    }

    @MainActor
    private static func exercise(listener: Channel, group: EventLoopGroup, pairs: NIOLockedValueBox<[Pair]>,
                                 orchestrator: ProxyOrchestrator, events: RuntimeEventLog, started: Date) async throws -> ScenarioResult {
        var clients: [Channel] = [], captures: [Capture] = [] // exactly three, never network-sized
        for index in 0..<2 {
            let capture = Capture()
            let client = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(capture) }
                .connect(to: listener.localAddress!).get()
            clients.append(client); captures.append(capture)
            ScenarioCleanup.register { do { try await client.close().get() } catch ChannelError.alreadyClosed {} catch { reportCleanupFailure(error) } }
            try await client.writeAndFlush(ByteBuffer(string: "before")).get()
            guard try await until({ capture.received == "before" && pairs.withLockedValue { $0.count > index } }) else {
                throw ScenarioExecutionError(message: "initial CONNECT echo missing")
            }
        }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        await orchestrator.handleVPNStateChange(.connected)
        for client in clients { try await client.writeAndFlush(ByteBuffer(string: "after")).get() }
        let healthy = try await until { captures.allSatisfy { $0.received == "beforeafter" } }
        let old = pairs.withLockedValue { $0 }
        old[0].remoteWrites.set(.reject)
        try await clients[0].writeAndFlush(ByteBuffer(string: "failed write")).get()
        let writeClosed = try await closes(clients[0])
        old[1].localWrites.set(.hold)
        try await clients[1].writeAndFlush(ByteBuffer(string: "blocked response")).get()
        guard try await until({ old[1].localWrites.pending > 0 }) else { throw ScenarioExecutionError(message: "write gate was not reached") }
        try await old[1].remote.eventLoop.submit {
            old[1].remote.pipeline.fireErrorCaught(IOError(errnoCode: EADDRNOTAVAIL, reason: "injected VPN address loss"))
        }.get()
        let readClosed = try await closes(clients[1])
        let retryCapture = Capture()
        let retry = try await ClientBootstrap(group: group).channelInitializer { $0.pipeline.addHandler(retryCapture) }
            .connect(to: listener.localAddress!).get()
        ScenarioCleanup.register { do { try await retry.close().get() } catch ChannelError.alreadyClosed {} catch { reportCleanupFailure(error) } }
        try await retry.writeAndFlush(ByteBuffer(string: "retry")).get()
        let retryWorks = try await until { retryCapture.received == "retry" }
        let failures = events.events.filter { $0.event == "tunnel.relay_failed" }
        return ScenarioResult(name: "vpn-existing-stream-failure", clientCount: 3, clientsOpened: 3, clientsWithFirstByte: 3,
            clientsClosedEarly: 2, totalBytes: 27, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 5, maxBytes: 11, medianBytes: 11, earliestClose: nil, latestClose: nil, assertions: [
                .init("healthy established streams still echo across VPN cycle", healthy),
                .init("failed write closes the browser socket within one second", writeClosed),
                .init("fatal read bypasses blocked response drain", readClosed),
                .init("a fresh CONNECT retry exchanges data after both failures", retryWorks),
                .init("each broken tunnel emits exactly one structured failure", failures.count == 2),
            ], notes: ["Explicit socket faults; no real VPN, proxy settings, helper or credentials touched"])
    }

    private static func reportCleanupFailure(_ error: Error) { fputs("tunnel fixture cleanup failed: \(error)\n", stderr) }
}
