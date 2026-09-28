// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import ProxyKernel

/// #100 through a running orchestrator. A burst of direct CONNECTs to a
/// host that does not resolve counts in the metrics but raises no
/// `error_rate.alarm` and no upstream re-probe, and is logged once. Then
/// the upstream dies and the same number of upstream failures does raise
/// the alarm, so the scenario fails if the alarm is merely broken.
enum DirectFailureStormScenarios {
    private static let stormHost = "storm.conduit-pm-sim.invalid"
    private static let stormSize = 300
    private static let upstreamFailures = 25

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let name = "directFailureStorm"
        let group = MultiThreadedEventLoopGroup.singleton
        let start = Date()
        var notes: [String] = []

        let origin = FakeOrigin(group: group, behavior: .echo)
        ScenarioCleanup.register { await origin.stop() }
        try await origin.start()
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        ScenarioCleanup.register { await upstream.stop() }
        try await upstream.start()

        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.proxy.maxConnections = 64
        config.proxy.inboundConnectionMaxLimit = 1024
        config.proxy.inboundConnectionWarnThreshold = 512
        config.routing.pacRoutingEnabled = false
        config.auth.mode = .systemNegotiated
        config.upstreams = [UpstreamProxy(name: "StormUpstream", host: "127.0.0.1", port: upstream.port, priority: 0)]
        // The storm host routes DIRECT, as a PAC DIRECT answer would.
        config.noProxyHosts = [stormHost]

        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        let orchestrator = ProxyOrchestrator(
            config: config,
            logger: logger,
            authenticatorProvider: { _ in MockAuthenticator() }
        )
        ScenarioCleanup.register { await orchestrator.stopProxy() }
        try await orchestrator.startProxy()
        guard let port = orchestrator.snapshot.bindings.proxyPort else {
            throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: "proxy did not bind"])
        }
        notes.append("state after start=\(orchestrator.snapshot.runtimeStatus.state) cause=\(orchestrator.snapshot.directModeCause)")

        func alarms() -> Int { orchestrator.eventLog.events.filter { $0.event == "error_rate.alarm" }.count }
        func failed() -> Int { orchestrator.snapshot.runtimeStatus.metrics.failedRequests }

        // Phase 1: the direct NXDOMAIN storm, 30 requests in flight at a time.
        var clients: [Channel] = []
        for batch in stride(from: 0, to: stormSize, by: 30) {
            for _ in batch..<min(batch + 30, stormSize) {
                clients.append(try await sendConnect("\(stormHost):443", proxyPort: port, group: group))
            }
            try await waitUntil { failed() >= min(batch + 30, stormSize) }
        }
        let stormElapsed = Date().timeIntervalSince(start)
        let stormFailed = failed()
        let stormAlarms = alarms()
        let stormLines = logger.entries().filter { $0.message.hasPrefix("Direct connect to \(stormHost):443 failed") }.count
        let reprobeLines = logger.entries().filter { $0.message.contains("triggering upstream re-probe") }.count
        notes.append("storm: failed=\(stormFailed) in \(String(format: "%.2f", stormElapsed))s alarms=\(stormAlarms) lines=\(stormLines) reprobeLines=\(reprobeLines)")
        for client in clients { client.close(promise: nil) }
        clients.removeAll()

        // Phase 2: the upstream dies; its failures still raise the alarm.
        await upstream.stop()
        for _ in 0..<upstreamFailures {
            clients.append(try await sendConnect("example.test:443", proxyPort: port, group: group))
        }
        try await waitUntil { failed() >= stormFailed + upstreamFailures }
        try await waitUntil { alarms() > stormAlarms }
        let upstreamAlarms = alarms() - stormAlarms
        notes.append("upstream: failed=\(failed() - stormFailed) alarms=\(upstreamAlarms)")
        for client in clients { client.close(promise: nil) }

        return ScenarioResult(
            name: name,
            clientCount: stormSize + upstreamFailures,
            clientsOpened: stormSize + upstreamFailures,
            clientsWithFirstByte: 0,
            clientsClosedEarly: 0,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every storm request failed and was counted", stormFailed == stormSize),
                .init("the direct storm raised no error_rate.alarm", stormAlarms == 0),
                .init("the direct storm triggered no upstream re-probe", reprobeLines == 0),
                .init("the storm was logged once, not per request", stormLines == 1),
                .init("upstream failures still raise error_rate.alarm", upstreamAlarms == 1),
            ],
            notes: notes
        )
    }

    private static func sendConnect(_ target: String, proxyPort: Int, group: EventLoopGroup) async throws -> Channel {
        let client = try await ClientBootstrap(group: group).connect(host: "127.0.0.1", port: proxyPort).get()
        let request = "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
        var buffer = client.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await client.writeAndFlush(buffer).get()
        return client
    }

    /// Polls a count; the deadline only keeps a regression from hanging pm-sim.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(20)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
