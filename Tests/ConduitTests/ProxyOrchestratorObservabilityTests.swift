// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class ProxyOrchestratorObservabilityTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
        group = nil
        super.tearDown()
    }

    @MainActor
    func testTunnelSessionCountTracksLiveSessions() async throws {
        let targetServer = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { targetServer.close(promise: nil) }

        let portReservation = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let tunnelPort = portReservation.localAddress!.port!
        try await portReservation.close().get()

        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.tunnelDefinitions = [
            TunnelDefinition(
                localPort: tunnelPort,
                remoteHost: "127.0.0.1",
                remotePort: targetServer.localAddress!.port!,
                enabled: true,
                proxied: false,
                label: "direct-test"
            )
        ]

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        await orchestrator.startTunnels()

        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .running)
        XCTAssertEqual(orchestrator.snapshot.tunnelSessionCount, 0)
        guard let boundPort = orchestrator.snapshot.bindings.tunnels.first?.localPort else {
            XCTFail("Expected bound tunnel port")
            return
        }

        let client = try await ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: boundPort)
            .get()

        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(orchestrator.snapshot.tunnelSessionCount, 1)

        try await client.close().get()
        try await Task.sleep(for: .milliseconds(250))
        XCTAssertEqual(orchestrator.snapshot.tunnelSessionCount, 0)

        await orchestrator.stopTunnels()
    }
}
