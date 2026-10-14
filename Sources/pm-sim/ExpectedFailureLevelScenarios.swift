// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// #149 through a running orchestrator. A direct CONNECT to a loopback port
/// nobody listens on is the destination's absence: one WARNING line, and its
/// `direct.connect_failed` event is still emitted. A client that resets its own established upstream
/// tunnel logs at INFO and still emits `tunnel.relay_failed`.
enum ExpectedFailureLevelScenarios {
    private final class Capture: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let bytes = NIOLockedValueBox<[UInt8]>([])
        var received: String { bytes.withLockedValue { String(decoding: $0, as: UTF8.self) } }
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            bytes.withLockedValue {
                guard $0.count + buffer.readableBytes <= 1024 else { return }
                $0.append(contentsOf: buffer.readableBytesView)
            }
        }
    }

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let name = "expectedFailureLevels"
        let group = MultiThreadedEventLoopGroup.singleton
        let start = Date()
        var notes: [String] = []

        let origin = FakeOrigin(group: group, behavior: .echo)
        ScenarioCleanup.register { await origin.stop() }
        try await origin.start()
        // A healthy upstream keeps the direct-mode cause at `.none`, so the
        // level under test is not already lowered by an expected cause.
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        ScenarioCleanup.register { await upstream.stop() }
        try await upstream.start()
        let closed = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let closedPort = closed.localAddress!.port!
        try await closed.close().get()

        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.routing.pacRoutingEnabled = false
        config.auth.mode = .systemNegotiated
        config.upstreams = [UpstreamProxy(name: "LevelsUpstream", host: "127.0.0.1", port: upstream.port, priority: 0)]
        config.noProxyHosts = ["127.0.0.1"]

        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() })
        ScenarioCleanup.register { await orchestrator.stopProxy() }
        try await orchestrator.startProxy()
        guard let port = orchestrator.snapshot.bindings.proxyPort else {
            throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: "proxy did not bind"])
        }
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }

        // Phase 1: nothing listens on the loopback port.
        let refusedTarget = "127.0.0.1:\(closedPort)"
        let refusedClient = try await connect(to: refusedTarget, proxyPort: port, group: group).channel
        let refusedPrefix = "Direct connect to \(refusedTarget) failed"
        try await waitUntil { logger.entries().contains { $0.message.hasPrefix(refusedPrefix) } }
        let refusedLevels = logger.entries().filter { $0.message.hasPrefix(refusedPrefix) }.map(\.level)
        notes.append("refused loopback levels=\(refusedLevels.map(\.label)) events=\(events("direct.connect_failed").count)")
        refusedClient.close(promise: nil)

        // Phase 2: an established upstream tunnel the client resets. Only
        // relayed tunnels (upstream CONNECT, transparent) carry relay
        // diagnostics; the upstream redirects any target to the echo origin.
        let tunnel = try await connect(to: "levels.example.test:443", proxyPort: port, group: group)
        try await waitUntil { tunnel.capture.received.contains("200") }
        let established = tunnel.capture.received.contains("200")
        // A zero linger turns close into a reset, as an app abandoning a socket does.
        guard let options = tunnel.channel as? SocketOptionProvider else {
            throw NSError(domain: name, code: 2, userInfo: [NSLocalizedDescriptionKey: "client socket has no options"])
        }
        try await options.setSoLinger(linger(l_onoff: 1, l_linger: 0)).get()
        try await tunnel.channel.close().get()
        try await waitUntil { !events("tunnel.relay_failed").isEmpty }
        let relayEvents = events("tunnel.relay_failed")
        let relayLines = logger.entries().filter { $0.message.hasPrefix("Tunnel relay:") }
        notes.append("relay events=\(relayEvents.count) levels=\(relayLines.map(\.level.label)) detail=\(relayEvents.first?.detail ?? "none")")

        return ScenarioResult(
            name: name,
            clientCount: 2, clientsOpened: 2, clientsWithFirstByte: established ? 1 : 0, clientsClosedEarly: 0,
            totalBytes: 0, durationSeconds: Date().timeIntervalSince(start), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a refused loopback connect is one WARNING line", refusedLevels == [.warning]),
                .init("a refused loopback connect still emits direct.connect_failed", events("direct.connect_failed").count == 1),
                .init("the upstream tunnel was established", established),
                .init("a client reset emits tunnel.relay_failed", relayEvents.count == 1
                      && relayEvents[0].detail?.contains("side=client") == true),
                .init("a client reset logs at INFO", relayLines.map(\.level) == [.info]),
            ],
            notes: notes
        )
    }

    private static func connect(
        to target: String, proxyPort: Int, group: EventLoopGroup
    ) async throws -> (channel: Channel, capture: Capture) {
        let capture = Capture()
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(capture) }
            .connect(host: "127.0.0.1", port: proxyPort).get()
        let request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
        var buffer = client.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await client.writeAndFlush(buffer).get()
        return (client, capture)
    }

    /// Polls; the deadline only keeps a regression from hanging pm-sim.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
