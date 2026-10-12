// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel
import ProxyPAC

/// A browser retains the off-VPN script and never refetches it. The origin
/// is reachable off VPN, but only the corporate upstream can serve it after
/// reconnect. No browser restart, host DNS or platform writes are involved.
enum BrowserPACScenarios {
    @MainActor
    static func retainedPAC(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        func response(_ route: String) -> String {
            "HTTP/1.1 200 OK\r\nX-Route: \(route)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        }
        let origin = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: 1,
                                       requireAuth: false, plainHTTPResponse: response("direct"))
        try await origin.start()
        ScenarioCleanup.register { await origin.stop() }
        let originPort = origin.port
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: originPort,
                                         requireAuth: false, plainHTTPResponse: response("upstream"))
        try await upstream.start()
        ScenarioCleanup.register { await upstream.stop() }
        let online = NIOLockedValueBox(false)
        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.pacRoutingEnabled = false
        config.strictMode = true
        config.noProxyHosts = []
        config.upstreams = [.init(name: "Browser fixture", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, logger: logger,
                                            authenticatorProvider: { _ in MockAuthenticator() },
                                            connectivityProbe: { targets in
            UpstreamProbeSummary(results: targets.map {
                ProbeResult(proxy: $0, latencyMS: 0, reachable: online.withLockedValue { $0 })
            })
        })
        ScenarioCleanup.register { await orchestrator.stopProxy() }
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        guard let localPAC = orchestrator.snapshot.bindings.localPACURL, let pacURL = URL(string: localPAC)
        else { throw ScenarioExecutionError(message: "local PAC not ready") }
        // The raw audit client stops at the response head. Fetch the complete
        // generated body, independently of system proxies and HTTP caches.
        let sessionConfig = URLSessionConfiguration.ephemeral
        sessionConfig.connectionProxyDictionary = [:]
        let session = URLSession(configuration: sessionConfig)
        defer { session.invalidateAndCancel() }
        func fetchScript() async throws -> String {
            let (data, responseHead) = try await session.data(for: URLRequest(url: pacURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3))
            guard (responseHead as? HTTPURLResponse)?.statusCode == 200 else { throw ScenarioExecutionError(message: "PAC response was not 200") }
            return String(decoding: data, as: UTF8.self)
        }
        let retainedScript = try await fetchScript()
        let evaluator = CFPACEvaluator()
        let retained = try evaluator.makeEvaluator(pacScript: retainedScript)
        let target = URL(string: "http://127.0.0.1:\(originPort)/browser-fixture")!
        let request = "GET \(target.absoluteString) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n"
        func freshRequest() async throws -> String {
            let chain = evaluator.routeChain(for: try retained.resolveProxyChain(for: target))
            guard let route = chain.routes.first else { throw ScenarioExecutionError(message: "retained PAC has no usable answer") }
            switch route {
            case .direct:
                return try await RawHTTPAuditClient.request(group: group, host: "127.0.0.1", port: originPort, request: request)
            case .proxy(let host, let port):
                return try await RawHTTPAuditClient.request(group: group, host: host, port: port, request: request)
            default:
                throw ScenarioExecutionError(message: "unexpected browser fixture route")
            }
        }
        let offVPN = try await freshRequest()
        // The same browser script survives a network change that makes DIRECT
        // unusable. New tabs must still enter Conduit and use its live policy.
        online.withLockedValue { $0 = true }
        await orchestrator.handleVPNStateChange(.connected)
        await origin.stop()
        let after: String
        do { after = try await freshRequest() }
        catch { after = "fresh cached-PAC request failed: \(error.displayDescription)" }

        // Configuration changes are a distinct phase: the served policy must
        // reflect disabling/re-enabling the last upstream without a restart.
        let reloaded = try await reloadAvailability(orchestrator, evaluator: evaluator, target: target, fetchScript: fetchScript)
        let afterReload: String
        do { afterReload = try await freshRequest() }
        catch { afterReload = "post-reload request failed: \(error.displayDescription)" }
        let assertions: [ScenarioAssertion] = [
            .init("off-VPN request reaches origin", offVPN.contains("X-Route: direct")),
            .init("fresh tab recovers through upstream without PAC refetch", after.contains("X-Route: upstream")),
            .init("last upstream disabled: served PAC selects DIRECT", reloaded.disabled == [.direct]),
            .init("upstream re-enabled: served PAC selects local proxy", reloaded.restored == [.proxy(host: "127.0.0.1", port: reloaded.proxyPort)]),
            .init("traffic recovers after configuration reload", afterReload.contains("X-Route: upstream")),
        ]
        return ScenarioResult(name: "browserRetainedPAC", clientCount: 3, clientsOpened: 3,
                              clientsWithFirstByte: [offVPN, after, afterReload].filter { $0.contains("HTTP/1.1 200") }.count,
                              clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
                              aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
                              earliestClose: nil, latestClose: nil, assertions: assertions,
                              notes: ["one retained evaluator across VPN reconnect; served PAC then checked after explicit config reloads", after, afterReload])
    }

    @MainActor
    private static func reloadAvailability(
        _ orchestrator: ProxyOrchestrator, evaluator: any PacEvaluator,
        target: URL, fetchScript: () async throws -> String
    ) async throws -> (disabled: [PACRoute], restored: [PACRoute], proxyPort: Int) {
        let enabledConfig = orchestrator.config
        var disabledConfig = enabledConfig
        disabledConfig.upstreams[0].enabled = false
        await orchestrator.applyConfigChange(disabledConfig)
        let disabledScript = try await fetchScript()
        let disabled = evaluator.routeChain(for: try evaluator.makeEvaluator(pacScript: disabledScript).resolveProxyChain(for: target)).routes
        await orchestrator.applyConfigChange(enabledConfig)
        let restoredScript = try await fetchScript()
        let restored = evaluator.routeChain(for: try evaluator.makeEvaluator(pacScript: restoredScript).resolveProxyChain(for: target)).routes
        guard let proxyPort = orchestrator.snapshot.bindings.proxyPort else { throw ScenarioExecutionError(message: "proxy listener lost during reload") }
        return (disabled, restored, proxyPort)
    }

}
