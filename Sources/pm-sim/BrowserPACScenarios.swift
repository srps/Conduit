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
        let (data, responseHead) = try await session.data(for: URLRequest(url: pacURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 3))
        guard (responseHead as? HTTPURLResponse)?.statusCode == 200 else { throw ScenarioExecutionError(message: "PAC response was not 200") }
        let retainedScript = String(decoding: data, as: UTF8.self)
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
        let afterAgain: String
        do { afterAgain = try await freshRequest() }
        catch { afterAgain = "second cached-PAC request failed: \(error.displayDescription)" }
        let assertions: [ScenarioAssertion] = [
            .init("off-VPN request reaches origin", offVPN.contains("X-Route: direct")),
            .init("retained PAC keeps browser on the local proxy", retainedScript.contains("PROXY 127.0.0.1:")),
            .init("fresh tab recovers through upstream without PAC refetch", after.contains("X-Route: upstream")),
            .init("second fresh tab also recovers", afterAgain.contains("X-Route: upstream")),
        ]
        return ScenarioResult(name: "browserRetainedPAC", clientCount: 3, clientsOpened: 3,
                              clientsWithFirstByte: [offVPN, after, afterAgain].filter { $0.contains("HTTP/1.1 200") }.count,
                              clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
                              aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0,
                              earliestClose: nil, latestClose: nil, assertions: assertions,
                              notes: ["one PAC fetch, one retained evaluator; no refetch across reconnect", after, afterAgain])
    }
}
