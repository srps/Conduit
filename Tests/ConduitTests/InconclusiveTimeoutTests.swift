// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// #197 through a running orchestrator: one silence from an upstream that
/// connected is held, the second in a row counts. A conclusive failure
/// counts at once.
final class InconclusiveTimeoutTests: XCTestCase {
    /// Hands each probe the next scripted outcome; with the script empty it answers.
    private final class ProbeScript: @unchecked Sendable {
        private let outcomes = NIOLockedValueBox<[ProbeOutcome]>([])
        func then(_ outcome: ProbeOutcome) { outcomes.withLockedValue { $0.append(outcome) } }
        func probe(_ upstreams: [UpstreamProxy]) -> UpstreamProbeSummary {
            let outcome = outcomes.withLockedValue { $0.isEmpty ? .answered : $0.removeFirst() }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, outcome: outcome) })
        }
    }

    @RuntimeActor
    func testOneSilentHealthCheckIsHeldAndTheSecondStartsRecovery() async throws {
        let silent = try await Self.silentServer()
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.healthCheckIntervalSeconds = 1
        config.upstreamResponseTimeoutSeconds = 0.2
        let orchestrator = Self.orchestrator(config: config, probe: ProbeScript())
        try await orchestrator.startProxy()

        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        func recoveryEvents() -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event.hasPrefix("recovery.") } }

        try await Self.until { !events("health.inconclusive").isEmpty || !recoveryEvents().isEmpty }
        let first = events("health.inconclusive").first?.detail ?? ""
        XCTAssertTrue(first.hasPrefix("reason=answer_timed_out consecutive=1 decisive=false "), first)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running, "one silence changes nothing")
        XCTAssertEqual(recoveryEvents().map(\.event), [])

        try await Self.until { !recoveryEvents().isEmpty }
        XCTAssertEqual(events("health.inconclusive").dropFirst().first?.detail?.contains("consecutive=2 decisive=true"), true)
        XCTAssertEqual(recoveryEvents().first?.detail?.hasPrefix("step=reauthenticate reason=upstream_silent"), true,
                       "the decisive silence started the ladder")

        await orchestrator.stopProxy()
        try await silent.close().get()
    }

    @RuntimeActor
    func testOneSilentProbeKeepsRoutingAndTheSecondGrantsDirect() async throws {
        let silent = try await Self.silentServer()
        // The health check the disconnect restarts stays out for the whole test, so only probes write the streak.
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.upstreamResponseTimeoutSeconds = 600
        let script = ProbeScript()
        let orchestrator = Self.orchestrator(config: config, probe: script)
        try await orchestrator.startProxy()
        func inconclusive() -> [String] {
            orchestrator.eventLog.events.filter { $0.event == "connectivity.probe_inconclusive" }.compactMap(\.detail)
        }

        script.then(.silent)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none, "one silent probe keeps proxy routing")
        XCTAssertEqual(inconclusive().count, 1)
        XCTAssertTrue(inconclusive().first?.contains("consecutive=1 decisive=false") == true, inconclusive().first ?? "")

        script.then(.silent)
        var renamed = config
        renamed.upstreams[0].name = "renamed"
        await orchestrator.applyConfigChange(renamed)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected, "the second in a row counts")
        XCTAssertTrue(inconclusive().last?.contains("consecutive=2 decisive=true") == true, inconclusive().last ?? "")

        await orchestrator.stopProxy()
        try await silent.close().get()
    }

    @RuntimeActor
    func testAnUnreachableProbeGrantsDirectAtOnce() async throws {
        let silent = try await Self.silentServer()
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.upstreamResponseTimeoutSeconds = 600
        let script = ProbeScript()
        let orchestrator = Self.orchestrator(config: config, probe: script)
        try await orchestrator.startProxy()

        script.then(.unreachable)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "connectivity.probe_inconclusive" })
        await orchestrator.stopProxy()
        try await silent.close().get()
    }

    private static func silentServer() async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    private static func config(upstreamPort: Int) -> ProxyConfig {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: upstreamPort, priority: 0)]
        return config
    }

    @RuntimeActor
    private static func orchestrator(config: ProxyConfig, probe: ProbeScript) -> ProxyOrchestrator {
        ProxyOrchestrator(
            config: config, logger: DiscardingLogSink(),
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") },
            connectivityProbe: { probe.probe($0) }
        )
    }

    /// Polls a count; the deadline only guards against a hang.
    @RuntimeActor
    private static func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }
}
