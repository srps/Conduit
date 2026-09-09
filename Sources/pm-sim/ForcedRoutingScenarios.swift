// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel

/// Real listener checks: the direct origin is separate from the upstream's
/// origin, so a successful handshake cannot conceal an unintended direct dial.
enum ForcedRoutingScenarios {
    private struct Failure: Error { let message: String }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(message: message) }
    }

    private final class DirectPAC: PacEvaluator, PacScriptEvaluating, Sendable {
        let evaluations = NIOLockedValueBox(0)
        func fetchPAC(from urlString: String) async throws -> String { "synthetic DIRECT" }
        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating { self }
        func resolveProxyChain(for url: URL) throws -> [String] {
            evaluations.withLockedValue { $0 += 1 }
            return ["DIRECT"]
        }
        func routeChain(for entries: [String]) -> [PACRoute] { [.direct] }
    }

    @MainActor
    private final class Fixture {
        let group = MultiThreadedEventLoopGroup.singleton
        let directOrigin: FakeOrigin
        let proxiedOrigin: FakeOrigin
        let config = NIOLockedValueBox(GenericDefaults.shared.makeConfig())
        let directMode = NIOLockedValueBox(false)
        let pac = DirectPAC()
        let events = RuntimeEventLog(capacity: 32)
        var server: LocalProxyServer?

        init() {
            directOrigin = FakeOrigin(group: group, behavior: .silent)
            proxiedOrigin = FakeOrigin(group: group, behavior: .silent)
        }

        private(set) var liveUpstream: FakeUpstreamProxy?

        func start(verbose: Bool) async throws {
            try await directOrigin.start()
            try await proxiedOrigin.start()
            let upstream = FakeUpstreamProxy(
                group: group, originHost: "127.0.0.1", originPort: proxiedOrigin.port,
                plainHTTPResponse: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            )
            liveUpstream = upstream
            try await upstream.start()
            config.withLockedValue {
                $0.localHost = "127.0.0.1"
                $0.localPort = 0
                $0.socksEnabled = true
                $0.socksPort = 0
                $0.strictMode = true
                $0.localPACEnabled = false
                $0.pacRoutingEnabled = true
                $0.pacURL = "https://pac.example.test/synthetic.pac"
                $0.noProxyHosts = ["127.0.0.1"]
                $0.forceProxyHosts = ["127.0.0.1"]
                $0.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: upstream.port, priority: 0)]
            }
            let config = self.config
            let directMode = self.directMode
            let events = self.events
            let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
            let pacEngine = PACRoutingEngine(configProvider: { config.withLockedValue { $0 } }, resolver: pac)
            try await pacEngine.refresh(force: true)
            let detector = DirectConnectDetector(group: group, logger: logger, ttlSeconds: 30, baseTimeoutMS: 100)
            let server = LocalProxyServer(
                logger: logger, configProvider: { config.withLockedValue { $0 } },
                directModeProvider: {
                    let direct = directMode.withLockedValue { $0 }
                    return (direct, direct ? .vpnDisconnected : .none)
                },
                authenticatorProvider: { _ in MockAuthenticator() }, directConnectDetector: detector,
                pacRoutingEngine: pacEngine, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
                onRequestCompleted: { _, _ in }, eventSink: { events.append($0) }
            )
            self.server = server
            try await server.start()
        }

        func stop() async {
            await server?.stop()
            await liveUpstream?.stop()
            await directOrigin.stop()
            await proxiedOrigin.stop()
        }

        func socksConnect() async throws {
            guard let port = server?.socksListeningPort else { throw Failure(message: "SOCKS listener missing") }
            let targetPort = UInt16(directOrigin.port)
            let replies = try await SOCKS5AuditClient.exchange(
                group: group, port: port,
                writes: [[5, 1, 0], [5, 1, 0, 1, 127, 0, 0, 1, UInt8(targetPort >> 8), UInt8(targetPort & 255)]],
                expectedResponses: 2
            )
            try require(replies.count == 2 && replies[0] == [5, 0] && replies[1].prefix(2) == [5, 0], "SOCKS CONNECT failed")
        }

        func waitForDirectConnections(_ count: Int) async throws {
            // The origin and SOCKS listener can run on different event loops;
            // wait for the origin's accept callback after a successful dial.
            for _ in 0..<100 where directOrigin.connectionCount < count {
                try await Task.sleep(for: .milliseconds(10))
            }
            try require(directOrigin.connectionCount == count, "Unexpected direct-origin connection count")
        }

        func httpConnect(method: String) async throws {
            guard let port = server?.listeningPort else { throw Failure(message: "HTTP listener missing") }
            let target = "127.0.0.1:\(directOrigin.port)"
            let uri = method == "CONNECT" ? target : "http://\(target)/forced"
            let response = try await RawHTTPAuditClient.request(
                group: group, host: "127.0.0.1", port: port,
                request: "\(method) \(uri) HTTP/1.1\r\nHost: \(target)\r\nConnection: close\r\n\r\n"
            )
            try require(response.hasPrefix("HTTP/1.1 200"), "\(method) request failed")
        }
    }

    @MainActor
    static func forcedProxyPrecedence(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let fixture = Fixture()
        do {
            try await fixture.start(verbose: verbose)
            try await fixture.httpConnect(method: "GET")
            try await fixture.httpConnect(method: "CONNECT")
            let upstreamBefore = fixture.liveUpstream?.connectCount ?? 0
            try await fixture.socksConnect()
            try require(fixture.directOrigin.connectionCount == 0, "Forced SOCKS5 target reached the direct origin despite PAC DIRECT")
            try require((fixture.liveUpstream?.connectCount ?? 0) > upstreamBefore, "Forced SOCKS5 request did not traverse the upstream")
            try require(fixture.pac.evaluations.withLockedValue { $0 } == 0, "A forced request evaluated PAC")

            fixture.config.withLockedValue { $0.forceProxyHosts = [] }
            try await fixture.socksConnect()
            try await fixture.waitForDirectConnections(1)
            try require(fixture.directOrigin.connectionCount == 1, "Removing a force rule did not permit direct routing")
            try require(fixture.pac.evaluations.withLockedValue { $0 } > 0, "Unforced request did not evaluate PAC")

            fixture.config.withLockedValue { $0.forceProxyHosts = ["127.0.0.1"]; $0.pacRoutingEnabled = false }
            let evaluations = fixture.pac.evaluations.withLockedValue { $0 }
            try await fixture.socksConnect()
            try require(fixture.directOrigin.connectionCount == 1, "PAC-disabled force rule was bypassed")
            try require(fixture.pac.evaluations.withLockedValue { $0 } == evaluations, "Disabled PAC still evaluated")

            fixture.config.withLockedValue { $0.pacRoutingEnabled = true; $0.forceProxyHosts = ["127.*"] }
            try await fixture.socksConnect()
            try require(fixture.directOrigin.connectionCount == 1, "Restoring a force rule reused a cached PAC DIRECT route")
            fixture.directMode.withLockedValue { $0 = true }
            try await fixture.socksConnect()
            try await fixture.waitForDirectConnections(2)
            try require(fixture.directOrigin.connectionCount == 2, "Intentional off-VPN direct behavior changed")
            let forceEvents = fixture.events.events.filter { $0.event == "routing.socks5_force_proxy" }
            try require(forceEvents.count == 3, "Forced SOCKS routes did not emit structured decisions")
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
        return ScenarioResult(
            name: "forced-proxy-precedence", clientCount: 7, clientsOpened: 7, clientsWithFirstByte: 7,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            notes: ["PASS: HTTP/CONNECT/SOCKS force precedence, live rule edits, PAC disable/cache, and intentional off-VPN direct behavior"]
        )
    }
}
