// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// #148: the order of a confirmed disconnect's two migration phases.
@MainActor
final class VPNTunnelMigrationTests: XCTestCase {
    private func migrations(_ events: [RuntimeEvent]) -> [String] {
        events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
    }

    /// The address phase must not wait for the connectivity probe: the probe
    /// can take its whole connect budget while stranded sockets stall.
    func testTheAddressPhaseRunsBeforeTheProbeAndTheRoutingPhaseAfterIt() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let log = NIOLockedValueBox<RuntimeEventLog?>(nil)
        let seenByProbe = NIOLockedValueBox<[String]?>(nil)
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                let up = reachable.withLockedValue { $0 }
                if !up, let events = log.withLockedValue({ $0 })?.events {
                    seenByProbe.withLockedValue { $0 = events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail) }
                }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        log.withLockedValue { $0 = orchestrator.eventLog }
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        reachable.withLockedValue { $0 = false }

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        let atProbe = try XCTUnwrap(seenByProbe.withLockedValue { $0 }, "the probe ran")
        XCTAssertEqual(atProbe.count, 1)
        XCTAssertTrue(atProbe[0].hasPrefix("transition=disconnected phase=addresses reason=user "), atProbe[0])
        let after = migrations(orchestrator.eventLog.events)
        XCTAssertEqual(after.count, 2)
        XCTAssertEqual(after.last, "transition=disconnected phase=routing reason=user routing=direct upstream_closed=0")
        await orchestrator.stopProxy()
    }

    /// On-prem: the probe finds the upstream, so the routing phase closes nothing.
    func testAReachableUpstreamKeepsItsChannelsInTheRoutingPhase() async throws {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))

        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=disconnected phase=routing reason=lost routing=upstream upstream_closed=0")
        await orchestrator.stopProxy()
    }
}
