// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyAuth

@MainActor
final class VPNReprobeRecoveryTests: XCTestCase {
    private struct ProbeState { var reachable = true; var attempts = 0 }

    private final class HealthyProxy: ChannelInboundHandler {
        typealias InboundIn = HTTPServerRequestPart
        typealias OutboundOut = HTTPServerResponsePart
        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if case .end = unwrapInboundIn(data) {
                var head = HTTPResponseHead(version: .http1_1, status: .ok)
                head.headers.add(name: "Content-Length", value: "0")
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }

    func testFailedReconnectAutomaticallyReprobesWithoutAnotherVPNReport() async throws {
        try await verifyRecovery(from: .disconnected(reason: .userInitiated))
    }

    func testFailedFlapRecoveryAutomaticallyReprobesWithoutAnotherVPNReport() async throws {
        try await verifyRecovery(from: .reasserting)
    }

    private func verifyRecovery(from outage: VPNObservedState) async throws {
        let server = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .childChannelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.configureHTTPServerPipeline()
                    try channel.pipeline.syncOperations.addHandler(HealthyProxy())
                }
            }.bind(host: "127.0.0.1", port: 0).get()
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: server.localAddress!.port!, priority: 0)]
        let state = NIOLockedValueBox(ProbeState())
        let orchestrator = ProxyOrchestrator(config: config,
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "fixture", domain: "LOCAL", workstation: "test",
                    ntHash: SecretBytes.repeating(0x22, count: 16)))
            },
            connectivityProbe: { upstreams in
                let reachable = state.withLockedValue { value in value.attempts += 1; return value.reachable }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: reachable) })
            },
            // The production cadence (15 s for this cause) is pinned in
            // VPNTransitionTableTests; here only that the retry runs matters.
            directReprobeInterval: { _ in 0.1 })
        do {
            try await orchestrator.startProxy()
            await orchestrator.handleVPNStateChange(.connected)
            state.withLockedValue { $0.reachable = false }
            await orchestrator.handleVPNStateChange(outage)
            await orchestrator.handleVPNStateChange(.connected)
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .upstreamsUnreachable)
            XCTAssertFalse(orchestrator.snapshot.directModeCause.routesClientTrafficDirectly)
            let attempts = state.withLockedValue { $0.attempts }
            let recovered = expectation(description: "production retry detected reachable upstream")
            var fulfilled = false
            orchestrator.onSnapshotChange = { snapshot in
                if snapshot.directModeCause == .none, !fulfilled { fulfilled = true; recovered.fulfill() }
            }
            state.withLockedValue { $0.reachable = true }
            await fulfillment(of: [recovered], timeout: 10)
            XCTAssertEqual(orchestrator.snapshot.vpnState, .connected)
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)
            XCTAssertGreaterThan(state.withLockedValue { $0.attempts }, attempts)
            XCTAssertTrue(orchestrator.eventLog.events.contains { $0.event == "connectivity.reprobe_started" },
                          "recovery must come from the scheduled retry, not another recovery path")
            await orchestrator.stopProxy()
            try await server.close().get()
        } catch {
            await orchestrator.stopProxy()
            do { try await server.close().get() } catch { XCTFail("fixture cleanup: \(error)") }
            throw error
        }
    }
}
