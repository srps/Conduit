// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOPosix
import ProxyKernel

/// #147 through a running orchestrator. The only upstream refuses every
/// connect, so each health check fails as unreachable. The ladder must not
/// re-authenticate against an upstream that never answered, and its
/// exhaustion line must not send the user to re-enter a password.
enum RecoveryLadderScenarios {
    @MainActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @MainActor
    static func unreachableLadder(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        // A port that was just bound and released: connects to it are refused.
        let dead = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: 9, requireAuth: false)
        try await dead.start()
        let deadPort = dead.port
        await dead.stop()

        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "refusing", host: "127.0.0.1", port: deadPort, priority: 0)]
        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        // The reachability probe says yes so the health loop, not direct
        // mode, owns the outage: that is the path that starts the ladder.
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            })
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }

        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        let exhausted = try await until(timeout: 15) { !events("recovery.exhausted").isEmpty }
        let skipped = events("recovery.step_skipped")
        let exhaustedDetail = events("recovery.exhausted").first?.detail ?? ""
        let entries = logger.entries()
        let reauthRan = entries.contains { $0.message.contains("Re-authenticate") && !$0.message.hasPrefix("Recovery step skipped") }
        let errorLine = entries.last { $0.level == .error && $0.message.hasPrefix("Automatic recovery exhausted") }?.message ?? ""

        return ScenarioResult(name: "recovery-unreachable-ladder", clientCount: 0, clientsOpened: 0,
            clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("an unreachable upstream exhausts the ladder", exhausted && exhaustedDetail.hasPrefix("failure=unreachable ")),
                .init("re-authenticate is skipped with a structured reason", skipped.count == 1
                    && skipped[0].detail?.hasPrefix("step=reauthenticate reason=upstream_unreachable") == true && !reauthRan),
                .init("the exhaustion line says no upstream answered and does not blame the password",
                      errorLine.contains("no upstream proxy answered") && !errorLine.localizedCaseInsensitiveContains("password")),
                .init("the cooldown still follows exhaustion", !events("recovery.cooldown_started").isEmpty),
            ], notes: ["refusing loopback upstream on port \(deadPort); injected reachable probe; no credentials, helper or settings"])
    }
}
