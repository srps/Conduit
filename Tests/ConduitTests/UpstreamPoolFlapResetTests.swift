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
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    @RuntimeActor func testAReconnectAfterAnOutageClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    @RuntimeActor func testAWakeRecoveryClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleSystemWake()

        XCTAssertEqual(orchestrator.snapshot.vpnState, .connected, "the wake found the upstream and ended the flap")
        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    /// A proxy-only Stop leaves port tunnels serving, so their pool recovers with the VPN whether or not the listener runs.
    @RuntimeActor func testAFlapRecoveryWithOnlyTunnelsRunningClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startTunnelsOnly()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped, "the listener stayed stopped")
        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopTunnels()
    }

    @RuntimeActor func testAReconnectWithOnlyTunnelsRunningClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startTunnelsOnly()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped, "the listener stayed stopped")
        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopTunnels()
    }

    /// Going into a flap or an outage is not a recovery: the breakers it opened stay open.
    @RuntimeActor func testLosingTheVPNWithOnlyTunnelsRunningLeavesTheTunnelPoolsBreakersOpen() async throws {
        let orchestrator = try await startTunnelsOnly()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.open, .open])
        await orchestrator.stopTunnels()
    }

    /// A store read that fails mid-flap reports `.unknown` between the flap and its recovery. The recovery is still one.
    @RuntimeActor func testAFlapRecoveryAfterABlindReadingClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.unknown)
        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.open, .open],
                       "a blind reading is no recovery")
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    @RuntimeActor func testAReconnectAfterABlindReadingClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startOrchestrator()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        await orchestrator.handleVPNStateChange(.unknown)
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopProxy()
    }

    @RuntimeActor func testAFlapRecoveryAfterABlindReadingWithOnlyTunnelsRunningClosesTheTunnelPoolsBreakers() async throws {
        let orchestrator = try await startTunnelsOnly()
        await orchestrator.handleVPNStateChange(.connected)
        await openEveryBreaker(of: orchestrator.tunnelConnectionPool, in: orchestrator)

        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.unknown)
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.tunnelConnectionPool.upstreamStatuses().map(\.circuitState), [.closed, .closed])
        await orchestrator.stopTunnels()
    }

    // MARK: - Harness

    /// A running proxy with two enabled upstreams, each a loopback listener
    /// that answers a Negotiate 407, which the probe counts as a reachable proxy,
    /// and a CONNECT to `trip.test` with a 502.
    @RuntimeActor private func startOrchestrator() async throws -> ProxyOrchestrator {
        let orchestrator = try await makeOrchestrator()
        try await orchestrator.startProxy()
        return orchestrator
    }

    /// The same upstreams with one port tunnel serving and the client listener never started.
    @RuntimeActor private func startTunnelsOnly() async throws -> ProxyOrchestrator {
        let orchestrator = try await makeOrchestrator()
        orchestrator.config.tunnels.definitions = [
            TunnelDefinition(localPort: 0, remoteHost: "db.corp.example", remotePort: 5432, proxied: false, label: "DB")
        ]
        await orchestrator.startTunnels()
        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running, "precondition: the tunnel serves")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped, "precondition: the listener is stopped")
        return orchestrator
    }

    @RuntimeActor private func makeOrchestrator() async throws -> ProxyOrchestrator {
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
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }

    /// Each upstream refuses a CONNECT to `trip.test` with a 502, threshold times over.
    @RuntimeActor private func openEveryBreaker(of pool: ConnectionPool, in orchestrator: ProxyOrchestrator) async {
        let threshold = orchestrator.config.circuitFailureThreshold
        for proxy in orchestrator.config.enabledUpstreams {
            await pool.failTunnels(through: proxy, count: threshold, target: "trip.test:443")
        }
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open, .open], "precondition: every breaker is open")
    }
}

private final class NegotiateChallenger: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var pending = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        while let end = pending.range(of: "\r\n\r\n") {
            let requestLine = pending[pending.startIndex..<end.lowerBound].prefix { $0 != "\r" }
            pending.removeSubrange(pending.startIndex..<end.upperBound)
            let response = requestLine.hasPrefix("CONNECT trip.test:")
                ? "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n"
                : "HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n"
            context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: response)), promise: nil)
        }
    }
}
