// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel
import ProxyPAC

/// `pm-sim vpn-pac-refresh` (#96). A PAC server that answers differently off
/// and on the VPN, the way the corporate one does: off it, every request goes
/// to a policy-detection proxy. The proxy starts off the VPN and routes one
/// request, which caches the off-VPN answer; then the VPN connects, drops,
/// and connects again. The first request after each transition must reach
/// the upstream the new network's PAC names. Each upstream stamps its
/// responses, so the response says which one served it.
enum VPNPACScenarios {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    /// Serves the script of whichever network the scenario is on; the real
    /// CFNetwork evaluator runs it.
    private final class NetworkPAC: PacEvaluator, @unchecked Sendable {
        private let onVPN = NIOLockedValueBox(false)
        private let fetches = NIOLockedValueBox(0)
        private let offScript: String
        private let onScript: String
        private let evaluator = CFPACEvaluator()

        init(offPort: Int, onPort: Int) {
            offScript = #"function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:\#(offPort)"; }"#
            onScript = #"function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:\#(onPort)"; }"#
        }

        var fetchCount: Int { fetches.withLockedValue { $0 } }
        func setOnVPN(_ value: Bool) { onVPN.withLockedValue { $0 = value } }

        func fetchPAC(from urlString: String) async throws -> String {
            fetches.withLockedValue { $0 += 1 }
            return onVPN.withLockedValue { $0 } ? onScript : offScript
        }

        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
            try evaluator.makeEvaluator(pacScript: pacScript)
        }

        func routeChain(for entries: [String]) -> PACChain {
            evaluator.routeChain(for: entries)
        }
    }

    private static func stampedResponse(_ name: String) -> String {
        "HTTP/1.1 200 OK\r\nX-Upstream: \(name)\r\nContent-Length: 0\r\nConnection: keep-alive\r\n\r\n"
    }

    /// Which upstream served a GET through the proxy: `off`, `on`, or the
    /// response's status line when neither did.
    @MainActor
    private static func servedBy(_ orchestrator: ProxyOrchestrator) async throws -> String {
        guard let port = orchestrator.snapshot.bindings.proxyPort else {
            throw Failure(description: "the proxy listener is not bound")
        }
        let response = try await RawHTTPAuditClient.request(
            group: MultiThreadedEventLoopGroup.singleton, host: "127.0.0.1", port: port,
            request: "GET http://intranet.example.test/ping HTTP/1.1\r\nHost: intranet.example.test\r\nConnection: close\r\n\r\n"
        )
        for name in ["off", "on"] where response.contains("X-Upstream: \(name)\r\n") {
            return name
        }
        return response.components(separatedBy: "\r\n").first ?? ""
    }

    @MainActor
    static func refreshOnTransition(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        var notes: [String] = []

        let offUpstream = FakeUpstreamProxy(
            group: group, originHost: "127.0.0.1", originPort: 9,
            plainHTTPResponse: stampedResponse("off")
        )
        let onUpstream = FakeUpstreamProxy(
            group: group, originHost: "127.0.0.1", originPort: 9,
            plainHTTPResponse: stampedResponse("on")
        )
        ScenarioCleanup.register { await offUpstream.stop() }
        ScenarioCleanup.register { await onUpstream.stop() }
        try await offUpstream.start()
        try await onUpstream.start()

        let pac = NetworkPAC(offPort: offUpstream.port, onPort: onUpstream.port)
        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.routing.pacRoutingEnabled = true
        config.routing.pacURL = "http://pac.example.test/proxy.pac"
        config.auth.mode = .systemNegotiated
        config.upstreams = [
            UpstreamProxy(name: "PolicyDetection", host: "127.0.0.1", port: offUpstream.port, priority: 0),
            UpstreamProxy(name: "Corporate", host: "127.0.0.1", port: onUpstream.port, priority: 1),
        ]
        let orchestrator = ProxyOrchestrator(
            config: config, logger: logger,
            authenticatorProvider: { _ in MockAuthenticator() },
            pacEvaluator: pac
        )
        ScenarioCleanup.register { await orchestrator.stopProxy() }
        try await orchestrator.startProxy()

        // Off the VPN, before the observer primes: the off-VPN answer is
        // evaluated and cached.
        let beforeConnect = try await servedBy(orchestrator)
        notes.append("before connect: \(beforeConnect)")

        let cutoff = Date()
        pac.setOnVPN(true)
        await orchestrator.handleVPNStateChange(.connected)
        let afterPriming = try await servedBy(orchestrator)
        notes.append("after priming connect: \(afterPriming)")

        pac.setOnVPN(false)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        let cause = orchestrator.snapshot.directModeCause
        let afterDisconnect = try await servedBy(orchestrator)
        notes.append("after disconnect (\(cause)): \(afterDisconnect)")

        pac.setOnVPN(true)
        await orchestrator.handleVPNStateChange(.connected)
        let afterReconnect = try await servedBy(orchestrator)
        notes.append("after reconnect: \(afterReconnect)")

        let invalidations = orchestrator.eventLog.events
            .filter { $0.event == "pac.routes_invalidated" && $0.timestamp >= cutoff }
            .compactMap(\.detail)
        let reasons = invalidations.compactMap { detail in
            detail.split(separator: " ").first { $0.hasPrefix("reason=") }.map { String($0.dropFirst("reason=".count)) }
        }
        notes.append("pac.routes_invalidated reasons=\(reasons) fetches=\(pac.fetchCount)")

        await orchestrator.stopProxy()
        await offUpstream.stop()
        await onUpstream.stop()

        return ScenarioResult(
            name: "vpn-pac-refresh", clientCount: 4, clientsOpened: 4, clientsWithFirstByte: 4,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("off the VPN, the off-VPN PAC routes", beforeConnect == "off"),
                .init("the first request after the priming connect uses the on-VPN PAC", afterPriming == "on"),
                .init("the disconnect keeps proxy routing (on-prem probe succeeds)", !cause.routesClientTrafficDirectly),
                .init("the first request after the disconnect uses the off-VPN PAC", afterDisconnect == "off"),
                .init("the first request after the reconnect uses the on-VPN PAC", afterReconnect == "on"),
                .init("each transition records one pac.routes_invalidated",
                      reasons == ["vpn_connected", "vpn_disconnected", "vpn_connected"]),
                .init("each transition fetched the PAC once", pac.fetchCount == 4),
            ],
            notes: notes
        )
    }
}
