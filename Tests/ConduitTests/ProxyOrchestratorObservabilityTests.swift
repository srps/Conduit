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

        // Session open/close counts update via channel callbacks; poll with a
        // generous deadline instead of a fixed sleep — the fixed 250 ms
        // variant flaked under the TSan soak's ~10x scheduling slowdown.
        try await waitForSessionCount(1, orchestrator: orchestrator)

        try await client.close().get()
        try await waitForSessionCount(0, orchestrator: orchestrator)

        await orchestrator.stopTunnels()
    }

    @MainActor
    private func waitForSessionCount(
        _ expected: Int,
        orchestrator: ProxyOrchestrator,
        timeout: Duration = .seconds(10),
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if orchestrator.snapshot.tunnelSessionCount == expected {
                // Returning on first match would hide an overshoot (e.g. a
                // double-decrement driving 1 -> 0 -> -1), which the old
                // fixed-sleep assertion caught by reading the settled value.
                // Re-check after a short quiescent window.
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(
                    orchestrator.snapshot.tunnelSessionCount,
                    expected,
                    "tunnelSessionCount reached \(expected) but did not stay there",
                    file: file,
                    line: line
                )
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        let finalCount = orchestrator.snapshot.tunnelSessionCount
        XCTAssertEqual(
            finalCount,
            expected,
            "tunnelSessionCount did not reach \(expected) within \(timeout)",
            file: file,
            line: line
        )
    }
}
