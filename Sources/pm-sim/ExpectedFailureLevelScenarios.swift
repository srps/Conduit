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
/// tunnel logs at INFO and still emits `tunnel.relay_failed`. A cloud
/// metadata probe that times out is treated as absent by policy (WARNING,
/// event kept), while a timeout to another link-local peer stays an ERROR
/// path fault.
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

    @RuntimeActor
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

        // Phase 3: link-local timeouts. The orchestrator's direct dial has no
        // seam, and a real dial to 169.254.169.254 is answered on a cloud CI
        // runner, so this drives the chain the direct CONNECT path runs —
        // link-local dial policy, failure report, coalescing log — with a
        // connect that times out.
        let probe = try await timeoutLevels(group: group)
        notes.append("metadata probe levels=\(probe.metadataLevels.map(\.label)) events=\(probe.metadataEvents) "
                     + "repeat levels=\(probe.repeatLevels.map(\.label)) bridge levels=\(probe.bridgeLevels.map(\.label))")

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
                .init("a metadata probe timeout is one WARNING line", probe.metadataLevels == [.warning]),
                .init("a metadata probe timeout still emits direct.connect_failed", probe.metadataEvents == 1),
                .init("a repeat probe inside the memo logs at INFO", probe.repeatLevels == [.info]),
                .init("a link-local bridge peer timeout stays ERROR", probe.bridgeLevels == [.error]),
            ],
            notes: notes
        )
    }

    private struct TimeoutLevels {
        var metadataLevels: [LogLevel]
        var metadataEvents: Int
        var repeatLevels: [LogLevel]
        var bridgeLevels: [LogLevel]
    }

    private static func timeoutLevels(group: EventLoopGroup) async throws -> TimeoutLevels {
        let logger = RecordingLogSink(minLevel: .debug)
        let events = RuntimeEventLog(capacity: 32)
        let log = ConnectFailureLog(logger: logger, eventSink: { events.append($0) })
        let eventLoop = group.next()
        // The link-local memo is process-wide; start this phase from empty.
        LinkLocalFailureMemo.shared.reset()

        func attempt(_ host: String) async {
            let target = "\(host):80"
            do {
                _ = try await LinkLocalConnectPolicy.dial(host: host, port: 80, on: eventLoop, eventSink: { events.append($0) }) { timeout in
                    eventLoop.makeFailedFuture(ChannelError.connectTimeout(timeout))
                }.get()
            } catch {
                let report = DirectConnectFailure.report(error, host: host, default: .error)
                log.report(report.event, level: report.level, target: target, error: error,
                           message: "Direct connect to \(target) failed: \(error.displayDescription)")
            }
        }
        func levels(_ host: String, from index: Int = 0) -> [LogLevel] {
            Array(logger.entries().filter { $0.message.hasPrefix("Direct connect to \(host):80 failed") }.dropFirst(index)).map(\.level)
        }

        await attempt("169.254.169.254")
        let metadataLevels = levels("169.254.169.254")
        let metadataEvents = events.events.filter { $0.event == "direct.connect_failed" }.count
        await attempt("169.254.169.254")
        let repeatLevels = levels("169.254.169.254", from: 1)
        await attempt("169.254.10.10")
        return TimeoutLevels(metadataLevels: metadataLevels, metadataEvents: metadataEvents,
                             repeatLevels: repeatLevels, bridgeLevels: levels("169.254.10.10"))
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
    @RuntimeActor
    private static func waitUntil(_ condition: @RuntimeActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
