// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// #181: a health check still running when the health loop restarts (here,
/// for new health settings) belongs to a loop that no longer exists. Its
/// verdict is dropped as superseded; it neither applies nor starts the
/// recovery ladder under the new loop.
enum HealthRestartScenarios {
    /// An upstream that answers plain HTTP requests. The first request is
    /// held until `releaseHeld(status:)`; every later one gets 204 at once.
    private final class HeldHTTPUpstream: @unchecked Sendable {
        private let group: EventLoopGroup
        private let lock = NIOLock()
        private var requests = 0
        private var held: (any Channel)?
        private var channel: (any Channel)?

        init(group: EventLoopGroup) { self.group = group }

        var port: Int { channel?.localAddress?.port ?? 0 }
        var requestCount: Int { lock.withLock { requests } }
        var isHolding: Bool { lock.withLock { held != nil } }

        func start() async throws {
            let bootstrap = ServerBootstrap(group: group)
                .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { [weak self] channel in
                    channel.pipeline.addHandler(RequestHandler { self?.received(on: $0) })
                }
            channel = try await bootstrap.bind(host: "127.0.0.1", port: 0).get()
        }

        func stop() async {
            releaseHeld(status: "503 Service Unavailable")
            do {
                try await channel?.close().get()
            } catch ChannelError.alreadyClosed {
                // Closed already: nothing left to release.
            } catch {
                FileHandle.standardError.write(Data("health-restart-superseded: upstream listener close failed: \(error)\n".utf8))
            }
        }

        private func received(on channel: any Channel) {
            let hold = lock.withLock { () -> Bool in
                requests += 1
                guard requests == 1 else { return false }
                held = channel
                return true
            }
            if !hold { Self.respond(on: channel, status: "204 No Content") }
        }

        func releaseHeld(status: String) {
            let channel = lock.withLock { () -> (any Channel)? in defer { held = nil }; return held }
            if let channel { Self.respond(on: channel, status: status) }
        }

        private static func respond(on channel: any Channel, status: String) {
            let response = "HTTP/1.1 \(status)\r\nContent-Length: 0\r\n\r\n"
            channel.eventLoop.execute {
                var buffer = channel.allocator.buffer(capacity: response.utf8.count)
                buffer.writeString(response)
                channel.writeAndFlush(buffer, promise: nil)
            }
        }

        /// Calls `onRequest` once per request head (each blank line ends one;
        /// the health check's HEAD has no body).
        private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let onRequest: (any Channel) -> Void
            private var pending = ""

            init(onRequest: @escaping (any Channel) -> Void) { self.onRequest = onRequest }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                pending += buffer.readString(length: buffer.readableBytes) ?? ""
                while let end = pending.range(of: "\r\n\r\n") {
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    onRequest(context.channel)
                }
            }
        }
    }

    @MainActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @MainActor
    static func staleCheckAfterRestart(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let upstream = HeldHTTPUpstream(group: group)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }

        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.healthCheckURL = "http://health-restart.test/"
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            })
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }

        // The loop's first check reaches the upstream and is held there.
        guard try await until(timeout: 5, { upstream.isHolding }) else {
            throw ScenarioExecutionError(message: "the first health check never reached the upstream")
        }
        // New health settings restart the loop; its check is answered at once.
        var changed = config
        changed.healthCheckIntervalSeconds = 3599
        await orchestrator.applyConfigChange(changed)
        let restarted = !events("config.health_restart").isEmpty
        let newRunApplied = try await until(timeout: 5) {
            upstream.requestCount >= 2 && orchestrator.snapshot.runtimeStatus.lastHealthSummary.hasPrefix("Healthy via")
        }
        // The held check now fails. It belongs to the stopped loop.
        upstream.releaseHeld(status: "503 Service Unavailable")
        let dropped = try await until(timeout: 5) { !events("health.result_superseded").isEmpty }

        let superseded = events("health.result_superseded").compactMap(\.detail)
        let ladder = orchestrator.eventLog.events.filter { $0.event.hasPrefix("recovery.") }.map(\.event)
        let status = orchestrator.snapshot.runtimeStatus
        return ScenarioResult(name: "health-restart-superseded", clientCount: 0, clientsOpened: 0,
            clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("new health settings restart the loop", restarted),
                .init("the restarted loop's own check applies", newRunApplied),
                .init("the held check from the stopped loop is dropped as superseded",
                      dropped && superseded == ["reason=restarted healthy=false"]),
                .init("the stale failure neither degrades the runtime nor starts the ladder",
                      status.state == .running && status.lastHealthSummary.hasPrefix("Healthy via") && ladder.isEmpty),
            ], notes: ["Real orchestrator, pool and listener; the upstream holds the first health check's HEAD, answers later ones 204, and the held one 503"])
    }
}
