// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class ProxyOrchestratorLocalPACTests: XCTestCase {

    @MainActor
    func testLocalPACStartsWithActualBoundProxyPort() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.strictMode = true
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false

        try await withStartedOrchestrator(config) { orchestrator in

            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let script = try await Self.fetch(localPACURL)

            XCTAssertEqual(try Self.routes(script, host: "public.example"), [.proxy(host: "127.0.0.1", port: proxyPort)],
                           "browsers must receive the actual bound proxy port, not configured port 0")
        }
    }

    @MainActor
    func testRoutingReloadUpdatesServedPACScript() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        config.strictMode = true
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.noProxyHosts = ["before.example"]

        try await withStartedOrchestrator(config) { orchestrator in

            let localPACURL = try XCTUnwrap(orchestrator.snapshot.bindings.localPACURL)
            let proxyPort = try XCTUnwrap(orchestrator.snapshot.bindings.proxyPort)
            let proxied: [PACRoute] = [.proxy(host: "127.0.0.1", port: proxyPort)]
            var script = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(script, host: "before.example"), [.direct])
            XCTAssertEqual(try Self.routes(script, host: "after.example"), proxied)

            var updated = orchestrator.config
            updated.noProxyHosts = ["after.example"]
            await orchestrator.applyConfigChange(updated)

            script = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(script, host: "before.example"), proxied)
            XCTAssertEqual(try Self.routes(script, host: "after.example"), [.direct])
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

    @MainActor
    func testUpstreamAvailabilityHotReloadUpdatesServedPACWithoutRestart() async throws {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true
        config.noProxyHosts = []

        try await withStartedOrchestrator(config) { orchestrator in
            let initialBindings = orchestrator.snapshot.bindings
            let localPACURL = try XCTUnwrap(initialBindings.localPACURL)
            let proxyPort = try XCTUnwrap(initialBindings.proxyPort)
            let proxyRoute: [PACRoute] = [.proxy(host: "127.0.0.1", port: proxyPort)]
            let initial = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(initial, host: "public.example"), [.direct])

            var added = orchestrator.config
            added.upstreams = [.init(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
            await orchestrator.applyConfigChange(added)
            let enabled = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(enabled, host: "public.example"), proxyRoute,
                           "adding the first enabled upstream must replace DIRECT-only PAC")

            var disabled = orchestrator.config
            disabled.upstreams[0].enabled = false
            await orchestrator.applyConfigChange(disabled)
            let noEnabled = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(noEnabled, host: "public.example"), [.direct])

            // The app mirrors editor values before applying with its prior
            // reconciled config; retain that boundary rather than diffing self.
            let prior = orchestrator.config
            var reenabled = prior
            reenabled.upstreams[0].enabled = true
            orchestrator.config = reenabled
            await orchestrator.applyConfigChange(reenabled, from: prior)
            let restored = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(restored, host: "public.example"), proxyRoute)

            var removed = orchestrator.config
            removed.upstreams = []
            await orchestrator.applyConfigChange(removed)
            let empty = try await Self.fetch(localPACURL)
            XCTAssertEqual(try Self.routes(empty, host: "public.example"), [.direct])
            XCTAssertEqual(orchestrator.snapshot.bindings.proxyPort, initialBindings.proxyPort)
            XCTAssertEqual(orchestrator.snapshot.bindings.localPACURL, localPACURL)
            XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "config.proxy_restart" })
        }
    }

    private static func routes(_ script: String, host: String) throws -> [PACRoute] {
        let evaluator = CFPACEvaluator()
        let compiled = try evaluator.makeEvaluator(pacScript: script)
        let target = try XCTUnwrap(URL(string: "https://\(host)/"))
        return evaluator.routeChain(for: try compiled.resolveProxyChain(for: target)).routes
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
        // These tests exercise served browser policy, not upstream reachability.
        // Avoid real dials to the fixture endpoints; the prober has its own tests.
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(), connectivityProbe: { targets in
            UpstreamProbeSummary(results: targets.filter(\.enabled).map {
                ProbeResult(proxy: $0, latencyMS: 0, reachable: false)
            })
        })
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
