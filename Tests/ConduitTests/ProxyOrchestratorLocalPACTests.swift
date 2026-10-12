// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class ProxyOrchestratorLocalPACTests: XCTestCase {

    @MainActor
    func testLocalPACStartsWithActualBoundProxyPort() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in

            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let script = try await Self.fetch(localPACURL)

            XCTAssertTrue(script.contains("// Proxy:   127.0.0.1:\(proxyPort)"),
                          "The served PAC header must report the actual bound proxy port, not config port 0.")
        }
    }

    @MainActor
    func testRoutingReloadUpdatesServedPACScript() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.noProxyHosts = ["before.example"]

        try await withStartedOrchestrator(config) { orchestrator in

            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            var script = try await Self.fetch(localPACURL)
            XCTAssertTrue(script.contains("noProxyHosts: 1"))

            var updated = orchestrator.config
            updated.noProxyHosts = ["after.example", "another.example"]
            await orchestrator.applyConfigChange(updated)

            script = try await Self.fetch(localPACURL)
            XCTAssertTrue(script.contains("noProxyHosts: 2"))
        }
    }

    @MainActor
    func testVPNRoutingChangesKeepServedBrowserPACStable() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true

        try await withStartedOrchestrator(config) { orchestrator in
            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let retained = try await Self.fetch(localPACURL)
            XCTAssertTrue(retained.contains("return \"PROXY 127.0.0.1:\(proxyPort)\";"))
            for cause: DirectModeCause in [.vpnDisconnected, .none, .upstreamsUnreachable, .transientNetworkChange] {
                orchestrator.setDirectModeForTesting(cause)
                let current = try await Self.fetch(localPACURL)
                XCTAssertEqual(current, retained, "a browser that never refetches PAC must remain on Conduit across \(cause)")
            }
        }
    }

    @MainActor
    func testRoutingReloadDisablesLocalPACServer() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in
            XCTAssertNotNil(orchestrator.snapshot.bindings.localPACURL)

            var updated = orchestrator.config
            updated.localPACEnabled = false
            await orchestrator.applyConfigChange(updated)

            XCTAssertNil(orchestrator.snapshot.bindings.localPACHost)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACPort)
            XCTAssertNil(orchestrator.snapshot.bindings.localPACURL)
        }
    }

    @MainActor
    func testStrictModeReloadUpdatesServedPACScript() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true

        try await withStartedOrchestrator(config) { orchestrator in
            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)

            var script = try await Self.fetch(localPACURL)
            XCTAssertTrue(script.contains("return \"PROXY 127.0.0.1:\(proxyPort)\";"))
            XCTAssertFalse(script.contains("return \"PROXY 127.0.0.1:\(proxyPort); DIRECT\";"))

            var updated = orchestrator.config
            updated.strictMode = false
            await orchestrator.applyConfigChange(updated)

            script = try await Self.fetch(localPACURL)
            XCTAssertTrue(script.contains("return \"PROXY 127.0.0.1:\(proxyPort); DIRECT\";"))
            XCTAssertTrue(orchestrator.eventLog.events.contains {
                $0.kind == .config && $0.event == "config.strict_mode_pac_refresh"
            })
        }
    }

    private static func fetch(_ urlString: String) async throws -> String {
        let url = try XCTUnwrap(URL(string: urlString))
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        let http = try XCTUnwrap(response as? HTTPURLResponse)
        XCTAssertEqual(http.statusCode, 200)
        return String(decoding: data, as: UTF8.self)
    }

    @MainActor
    private func withStartedOrchestrator(
        _ config: ProxyConfig,
        body: (ProxyOrchestrator) async throws -> Void
    ) async throws {
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        try await orchestrator.startProxy()
        do {
            try await body(orchestrator)
            await orchestrator.stopProxy()
        } catch {
            await orchestrator.stopProxy()
            throw error
        }
    }
}
