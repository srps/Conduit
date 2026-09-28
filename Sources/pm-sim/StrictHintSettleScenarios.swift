// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import ProxyKernel

/// #97 through a running orchestrator in strict mode. A request that fails
/// through the upstream while a VPN transition settles, or during a flap
/// hold, is not probed for a No-proxy hint, and the suppression is reported;
/// the same failure after the settle window is probed and hinted. The
/// target answers directly throughout, so each phase would hint without the
/// suppression, and the last phase fails if the hint is merely broken.
enum StrictHintSettleScenarios {
    /// Short, so the scenario can wait it out.
    private static let settleWindow: TimeInterval = 1.5

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let name = "strict-hint-vpn-settle"
        let group = MultiThreadedEventLoopGroup.singleton
        let start = Date()
        var notes: [String] = []

        // The directly reachable host. Echoes, so a request wrongly sent to
        // it directly fails at once instead of hanging.
        let target = FakeOrigin(group: group, behavior: .echo)
        ScenarioCleanup.register { await target.stop() }
        try await target.start()
        let relayed = FakeOrigin(group: group, behavior: .silent)
        ScenarioCleanup.register { await relayed.stop() }
        try await relayed.start()
        let upstream = FakeUpstreamProxy(
            group: group, originHost: "127.0.0.1", originPort: relayed.port, requireAuth: false,
            plainHTTPResponse: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
        )
        ScenarioCleanup.register { await upstream.stop() }
        try await upstream.start()
        let upstreamPort = upstream.port

        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.routing.pacRoutingEnabled = false
        config.auth.mode = .systemNegotiated
        config.strictMode = true
        // The defaults bypass loopback, where the fake target lives.
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.healthCheckURL = "http://127.0.0.1:\(relayed.port)/health"
        config.upstreams = [UpstreamProxy(name: "SettleUpstream", host: "127.0.0.1", port: upstreamPort, priority: 0)]

        let orchestrator = ProxyOrchestrator(
            config: config,
            logger: ConsoleLogSink(minLevel: verbose ? .debug : .warning),
            authenticatorProvider: { _ in MockAuthenticator() },
            strictHintSettleWindow: settleWindow
        )
        ScenarioCleanup.register { await orchestrator.stopProxy() }
        try await orchestrator.startProxy()
        guard let proxyPort = orchestrator.snapshot.bindings.proxyPort else {
            throw NSError(domain: name, code: 1, userInfo: [NSLocalizedDescriptionKey: "proxy did not bind"])
        }

        func events(_ event: String) -> [RuntimeEvent] {
            orchestrator.eventLog.events.filter { $0.event == event }
        }
        func suppressed(_ reason: String) -> Int {
            events("routing.strict_direct_reachable_suppressed").filter {
                $0.detail?.hasPrefix("reason=\(reason) ") == true
            }.count
        }
        func hints() -> Int { events("routing.strict_direct_reachable").count }
        func get() async throws -> String {
            let host = "127.0.0.1:\(target.port)"
            return try await RawHTTPAuditClient.request(
                group: group, host: "127.0.0.1", port: proxyPort,
                request: "GET http://\(host)/settle HTTP/1.1\r\nHost: \(host)\r\nConnection: close\r\n\r\n"
            )
        }
        /// The health check a resumed loop fires at once must finish while
        /// the upstream is up, or its failure would put routing into direct
        /// mode and every later phase would be suppressed for that instead.
        func waitForHealthCheck() async throws {
            try await waitUntil { orchestrator.snapshot.runtimeStatus.lastHealthSummary.hasSuffix(" ms)") }
        }

        // Phase 1: the VPN connects, then the upstream fails at once. The
        // target answers directly, but the hint is not probed.
        try await waitForHealthCheck()
        await orchestrator.handleVPNStateChange(.connected)
        await upstream.stop()
        let connectFailure = try await get()
        try await waitUntil { suppressed("vpn_transition") >= 1 }
        let afterConnect = (
            status: connectFailure.prefix(12), suppressed: suppressed("vpn_transition"),
            hints: hints(), probes: target.connectionCount
        )
        notes.append("after vpn.connected: \(afterConnect.status) suppressed=\(afterConnect.suppressed) hints=\(afterConnect.hints) targetConnections=\(afterConnect.probes)")

        // Phase 2: a flap hold. Strict mode still routes via the upstream,
        // which fails; nothing is probed.
        await orchestrator.handleVPNStateChange(.reasserting)
        let flapFailure = try await get()
        try await waitUntil { suppressed("flap") >= 1 }
        notes.append("during flap: \(flapFailure.prefix(12)) suppressed=\(suppressed("flap")) hints=\(hints()) targetConnections=\(target.connectionCount)")
        let afterFlap = (hints: hints(), probes: target.connectionCount)

        // Phase 3: the flap recovers with the upstream back, the upstream
        // fails again, and after the settle window the failure is probed
        // and hinted.
        try await upstream.start(port: upstreamPort)
        await orchestrator.handleVPNStateChange(.connected)
        let causeAfterRecovery = orchestrator.snapshot.directModeCause
        try await waitForHealthCheck()
        await upstream.stop()
        try await Task.sleep(for: .seconds(settleWindow + 0.5))
        let settledFailure = try await get()
        try await waitUntil { hints() >= 1 }
        try await waitUntil { target.connectionCount >= afterFlap.probes + 1 }
        let hint = events("routing.strict_direct_reachable").first
        notes.append("after the window: \(settledFailure.prefix(12)) cause=\(orchestrator.snapshot.directModeCause) hints=\(hints()) targetConnections=\(target.connectionCount) detail=\(hint?.detail ?? "none")")

        return ScenarioResult(
            name: name,
            clientCount: 3, clientsOpened: 3, clientsWithFirstByte: 3, clientsClosedEarly: 0,
            totalBytes: 0, durationSeconds: Date().timeIntervalSince(start), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every request failed with a 502",
                      [connectFailure, flapFailure, settledFailure].allSatisfy { $0.hasPrefix("HTTP/1.1 502") }),
                .init("vpn.connected: suppressed, reason=vpn_transition", afterConnect.suppressed == 1),
                .init("vpn.connected: no hint and no probe", afterConnect.hints == 0 && afterConnect.probes == 0),
                .init("flap hold: suppressed, reason=flap", suppressed("flap") == 1),
                .init("flap hold: no hint and no probe", afterFlap.hints == 0 && afterFlap.probes == 0),
                .init("the flap recovered into upstream routing", causeAfterRecovery == .none),
                .init("after the window: one hint for the target",
                      hints() == 1 && hint?.detail == "host=127.0.0.1 port=\(target.port) hint=add_to_no_proxy_hosts"),
                .init("after the window: one probe, no direct retry", target.connectionCount == afterFlap.probes + 1),
            ],
            notes: notes
        )
    }

    /// Polls a condition; the deadline only keeps a regression from hanging pm-sim.
    @MainActor
    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
