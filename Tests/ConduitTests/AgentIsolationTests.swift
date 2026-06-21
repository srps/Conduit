// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class AgentIsolationTests: XCTestCase {
    func testRuntimeEnvironmentIsolatedDerivesExpectedPaths() {
        let stateDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-config-\(UUID().uuidString)", isDirectory: true)

        let environment = RuntimeEnvironment.isolated(stateDirectory: stateDirectory)

        XCTAssertEqual(environment.configDirectory.path, stateDirectory.path)
        XCTAssertEqual(environment.configFile.path, stateDirectory.appendingPathComponent("config.json").path)
        XCTAssertEqual(environment.savedDNSFile.path, stateDirectory.appendingPathComponent("saved-dns.json").path)
    }

    @MainActor
    func testProxyOrchestratorBindsEphemeralProxyAndDNSPorts() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.localPACEnabled = false
        config.socksEnabled = true
        config.socksPort = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0

        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        try await orchestrator.startProxy()
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running)
        XCTAssertTrue(orchestrator.snapshot.directModeCause.isDirect)
        XCTAssertNotNil(orchestrator.snapshot.bindings.proxyPort)
        XCTAssertNotEqual(orchestrator.snapshot.bindings.proxyPort, 0)
        XCTAssertNotNil(orchestrator.snapshot.bindings.socksPort)
        XCTAssertNotEqual(orchestrator.snapshot.bindings.socksPort, 0)

        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        XCTAssertNotNil(orchestrator.snapshot.bindings.dnsPort)
        XCTAssertNotEqual(orchestrator.snapshot.bindings.dnsPort, 0)

        await orchestrator.stopDNS()
        await orchestrator.stopProxy()

        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .stopped)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .stopped)
        XCTAssertNil(orchestrator.snapshot.bindings.proxyPort)
        XCTAssertNil(orchestrator.snapshot.bindings.socksPort)
        XCTAssertNil(orchestrator.snapshot.bindings.dnsPort)
    }

    func testProxyOrchestratorSnapshotCodableRoundTrips() throws {
        let snapshot = ProxyOrchestratorSnapshot(
            runtimeStatus: ProxyRuntimeStatus(
                state: .running,
                activeUpstream: "DIRECT",
                lastHealthSummary: "Healthy (12 ms)",
                metrics: ProxyMetrics(
                    requestsHandled: 12,
                    successfulRecoveries: 1,
                    failedRequests: 2,
                    openConnections: 3,
                    inboundConnections: 4,
                    uptimeStartedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    lastFailure: Date(timeIntervalSince1970: 1_700_000_100)
                )
            ),
            activeConnections: ActiveConnectionStore([
                ActiveConnectionInfo(
                    id: UUID(),
                    destination: "https://example.com",
                    upstream: "DIRECT",
                    method: "GET",
                    startedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    lastActivityAt: Date(timeIntervalSince1970: 1_700_000_010),
                    bytesSent: 128,
                    bytesReceived: 256,
                    tunnel: false
                )
            ]),
            directModeCause: .upstreamsUnreachable,
            proxyError: nil,
            dnsError: "degraded",
            dnsRunState: .warning,
            dnsQueryCount: 42,
            dnsDoHFallbackCount: 7,
            tunnelsRunState: .running,
            tunnelsError: nil,
            tunnelActiveCount: 2,
            tunnelSessionCount: 5,
            tunnelDNSOverrideStatus: .active(hostnames: ["mongo.example.com"]),
            bindings: ProxyOrchestratorBindings(
                proxyHost: "127.0.0.1",
                proxyPort: 1234,
                socksHost: "127.0.0.1",
                socksPort: 1235,
                dnsHost: "127.0.0.1",
                dnsPort: 1236,
                tunnels: [
                    TunnelBindingInfo(
                        label: "mongo",
                        localHost: "127.0.0.1",
                        localPort: 27017,
                        remoteHost: "mongo.example.com",
                        remotePort: 27017,
                        proxied: true
                    )
                ]
            )
        )

        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(ProxyOrchestratorSnapshot.self, from: data)
        XCTAssertEqual(decoded, snapshot)
    }
}
