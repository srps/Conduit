// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// Every pool that dials an upstream starts a recovered VPN path with closed
/// breakers. A breaker opened on the path the VPN replaced says nothing about
/// the new one, whichever pool holds it.
final class UpstreamPoolFlapResetTests: XCTestCase {
    private var upstreams: [Channel] = []

    override func tearDown() async throws {
        for upstream in upstreams { try await upstream.close().get() }
        upstreams = []
        try await super.tearDown()
    }

    @RuntimeActor func testAFlapRecoveryClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    @RuntimeActor func testAReconnectAfterAnOutageClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    @RuntimeActor func testAWakeRecoveryClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)
        openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleSystemWake()

        XCTAssertEqual(orchestrator.snapshot.vpnState, .connected, "the wake found the upstream and ended the flap")
        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    // MARK: - Harness

    /// A running proxy with two enabled upstreams, each a loopback listener
    /// that answers a Negotiate 407, which the probe counts as a reachable proxy.
    @RuntimeActor private func startOrchestrator() async throws -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        // The tests open breakers with back-to-back failures.
        config.circuitBreakerWindowSeconds = 0
        config.upstreams = []
        for (index, name) in ["Primary", "Secondary"].enumerated() {
            let upstream = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(NegotiateChallenger())
                }
                .bind(host: "127.0.0.1", port: 0).get()
            upstreams.append(upstream)
            config.upstreams.append(
                UpstreamProxy(name: name, host: "127.0.0.1", port: try XCTUnwrap(upstream.localAddress?.port), priority: index)
            )
        }
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        return orchestrator
    }

    @RuntimeActor private func openEveryBreaker(of pool: ConnectionPool, in orchestrator: ProxyOrchestrator) {
        let threshold = orchestrator.config.circuitFailureThreshold
        for proxy in orchestrator.config.enabledUpstreams {
            for _ in 0..<threshold { pool.recordDedicatedTunnelFailure(for: proxy) }
        }
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open, .open], "precondition: every breaker is open")
    }
}

private final class NegotiateChallenger: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let response = "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}
