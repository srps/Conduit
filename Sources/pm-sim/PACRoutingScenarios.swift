// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel
import ProxyPAC

/// PAC answers with nothing usable (#49, #50) and strict mode's direct
/// reachability (#87), through real listeners. The target origin is separate
/// from the origin the upstream relays to, so any direct dial shows up on its
/// connection count.
enum PACRoutingScenarios {
    private struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw Failure(description: message) }
    }

    @MainActor
    private final class Fixture {
        let group = MultiThreadedEventLoopGroup.singleton
        /// Echoes, so a request wrongly sent to it directly fails at once
        /// (the echo is not an HTTP response) instead of hanging.
        let target = FakeOrigin(group: MultiThreadedEventLoopGroup.singleton, behavior: .echo)
        let relayed = FakeOrigin(group: MultiThreadedEventLoopGroup.singleton, behavior: .silent)
        let events = RuntimeEventLog(capacity: 256)
        private(set) var upstream: FakeUpstreamProxy?
        private(set) var server: LocalProxyServer?
        private(set) var detector: DirectConnectDetector?

        func startOrigins() async throws {
            try await target.start()
            try await relayed.start()
            let upstream = FakeUpstreamProxy(
                group: group, originHost: "127.0.0.1", originPort: relayed.port,
                plainHTTPResponse: "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            )
            try await upstream.start()
            self.upstream = upstream
        }

        /// A proxy over the running origins. `pacScript` nil turns PAC off;
        /// otherwise the real CFNetwork evaluator runs it.
        func startProxy(strict: Bool, pacScript: String?, verbose: Bool) async throws {
            await server?.stop()
            var config = GenericDefaults.shared.makeConfig()
            config.localHost = "127.0.0.1"
            config.localPort = 0
            config.socksEnabled = true
            config.socksPort = 0
            config.localPACEnabled = false
            config.strictMode = strict
            config.pacRoutingEnabled = pacScript != nil
            config.pacURL = pacScript != nil ? "https://pac.example.test/scenario.pac" : ""
            config.noProxyHosts = []
            config.forceProxyHosts = []
            config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: upstream?.port ?? 0, priority: 0)]
            let fixed = config
            let events = self.events
            let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
            var engine: PACRoutingEngine?
            if let pacScript {
                let created = PACRoutingEngine(
                    configProvider: { fixed }, resolver: CFPACEvaluator(), logger: logger,
                    pacLoader: { _ in pacScript }, eventSink: { events.append($0) }
                )
                try await created.refresh(force: true)
                engine = created
            }
            let detector = DirectConnectDetector(group: group, logger: logger, ttlSeconds: 300, baseTimeoutMS: 500)
            let server = LocalProxyServer(
                logger: logger, configProvider: { fixed },
                directModeProvider: { (false, .none) },
                authenticatorProvider: { _ in MockAuthenticator() }, directConnectDetector: detector,
                pacRoutingEngine: engine, onConnectionOpened: { _ in }, onConnectionClosed: { _ in },
                onRequestCompleted: { _, _ in }, eventSink: { events.append($0) }
            )
            try await server.start()
            self.server = server
            self.detector = detector
        }

        func stop() async {
            await server?.stop()
            await upstream?.stop()
            await target.stop()
            await relayed.stop()
        }

        /// Cache the target as directly reachable, as the shortcut would, and
        /// wait for the target to count that probe. Returns the count after it.
        func seedTargetReachable() async throws -> Int {
            let before = target.connectionCount
            let reachable = await detector?.isDirectlyReachable(host: "127.0.0.1", port: target.port, gatewayMode: false) ?? false
            try require(reachable, "the target origin is not directly reachable")
            try await waitForTargetConnections(before + 1)
            return target.connectionCount
        }

        func waitForTargetConnections(_ count: Int) async throws {
            for _ in 0..<200 where target.connectionCount < count {
                try await Task.sleep(for: .milliseconds(10))
            }
            try require(target.connectionCount == count, "target connections: \(target.connectionCount), expected \(count)")
        }

        func get() async throws -> String {
            guard let port = server?.listeningPort else { throw Failure(description: "HTTP listener missing") }
            let target = "127.0.0.1:\(self.target.port)"
            return try await RawHTTPAuditClient.request(
                group: group, host: "127.0.0.1", port: port,
                request: "GET http://\(target)/scenario HTTP/1.1\r\nHost: \(target)\r\nConnection: close\r\n\r\n"
            )
        }

        func connect() async throws -> String {
            guard let port = server?.listeningPort else { throw Failure(description: "HTTP listener missing") }
            let target = "127.0.0.1:\(self.target.port)"
            return try await RawHTTPAuditClient.request(
                group: group, host: "127.0.0.1", port: port,
                request: "CONNECT \(target) HTTP/1.1\r\nHost: \(target)\r\n\r\n"
            )
        }

        func socksConnect() async throws -> [[UInt8]] {
            guard let port = server?.socksListeningPort else { throw Failure(description: "SOCKS listener missing") }
            let targetPort = UInt16(target.port)
            return try await SOCKS5AuditClient.exchange(
                group: group, port: port,
                writes: [[5, 1, 0], [5, 1, 0, 1, 127, 0, 0, 1, UInt8(targetPort >> 8), UInt8(targetPort & 255)]],
                expectedResponses: 2
            )
        }

        func events(named name: String) -> [RuntimeEvent] {
            events.events.filter { $0.event == name }
        }
    }

    /// A PAC whose every answer is unusable (CFNetwork drops `HTTPS`, `SOCKS5`
    /// and `QUIC`; the kernel rejects `SOCKS`) routes HTTP, CONNECT and SOCKS5
    /// through the configured upstream, outside strict mode and with the
    /// target cached as directly reachable, and never dials the target.
    @MainActor
    static func unsupportedOnly(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let fixture = Fixture()
        var notes: [String] = []
        do {
            try await fixture.startOrigins()
            let scripts: [(reason: String, script: String)] = [
                ("empty", #"function FindProxyForURL(url, host) { return "HTTPS p.example:8443; SOCKS5 s.example:1080; QUIC q.example:443"; }"#),
                ("unsupported", #"function FindProxyForURL(url, host) { return "SOCKS s.example:1080"; }"#),
            ]
            for (reason, script) in scripts {
                try await fixture.startProxy(strict: false, pacScript: script, verbose: verbose)
                let baseline = try await fixture.seedTargetReachable()
                let probes = fixture.detector?.probeCount ?? 0
                let connectsBefore = fixture.upstream?.connectCount ?? 0

                let get = try await fixture.get()
                let connect = try await fixture.connect()
                let socks = try await fixture.socksConnect()
                try require(fixture.target.connectionCount == baseline,
                            "\(reason): the target was dialled directly (\(fixture.target.connectionCount - baseline)x)")
                try require(get.hasPrefix("HTTP/1.1 200"), "\(reason): GET failed: \(get.prefix(60))")
                try require(connect.hasPrefix("HTTP/1.1 200"), "\(reason): CONNECT failed: \(connect.prefix(60))")
                try require(socks.count == 2 && socks[1].prefix(2) == [5, 0], "\(reason): SOCKS5 CONNECT failed")

                try require((fixture.upstream?.connectCount ?? 0) - connectsBefore == 2,
                            "\(reason): CONNECT and SOCKS5 did not both traverse the upstream")
                try require((fixture.detector?.probeCount ?? 0) == probes, "\(reason): a PAC answer triggered a direct probe")
                let reported = fixture.events(named: "pac.no_usable_route").contains {
                    $0.detail?.contains("reason=\(reason)") == true
                }
                try require(reported, "\(reason): no pac.no_usable_route event")
                notes.append("\(reason): 3/3 via upstream, 0 direct")
            }
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
        return ScenarioResult(
            name: "pac-unsupported-only", clientCount: 6, clientsOpened: 6, clientsWithFirstByte: 6,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [.init("unusable PAC answers route through the upstream, never direct", true)],
            notes: notes
        )
    }

    /// Strict mode with a directly reachable target: HTTP and CONNECT go
    /// through the upstream with no direct dial and no probe. When the
    /// upstream fails, the 502 stands, one probe runs, and one
    /// `routing.strict_direct_reachable` hint is emitted for the host.
    @MainActor
    static func strictDirectReachable(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let fixture = Fixture()
        do {
            try await fixture.startOrigins()
            try await fixture.startProxy(strict: true, pacScript: nil, verbose: verbose)
            let baseline = try await fixture.seedTargetReachable()
            let probes = fixture.detector?.probeCount ?? 0

            let get = try await fixture.get()
            let connect = try await fixture.connect()
            try require(fixture.target.connectionCount == baseline, "strict mode dialled a reachable target directly")
            try require(get.hasPrefix("HTTP/1.1 200"), "GET failed: \(get.prefix(60))")
            try require(connect.hasPrefix("HTTP/1.1 200"), "CONNECT failed: \(connect.prefix(60))")
            try require((fixture.detector?.probeCount ?? 0) == probes, "strict mode probed proactively")

            // The upstream goes away: the request fails, and only a probe
            // (one connection, no retry) reaches the target.
            await fixture.upstream?.stop()
            let failed = try await fixture.get()
            try require(failed.hasPrefix("HTTP/1.1 502"), "GET with the upstream down: \(failed.prefix(60))")
            for _ in 0..<200 where fixture.events(named: "routing.strict_direct_reachable").isEmpty {
                try await Task.sleep(for: .milliseconds(10))
            }
            let hints = fixture.events(named: "routing.strict_direct_reachable")
            try require(hints.count == 1, "expected one strict_direct_reachable hint, got \(hints.count)")
            try require(hints[0].detail == "host=127.0.0.1 port=\(fixture.target.port) hint=add_to_no_proxy_hosts",
                        "hint detail: \(hints[0].detail ?? "")")
            try await fixture.waitForTargetConnections(baseline + 1)

            let failedAgain = try await fixture.connect()
            try require(failedAgain.hasPrefix("HTTP/1.1 502"), "CONNECT with the upstream down: \(failedAgain.prefix(60))")
            try require((fixture.detector?.probeCount ?? 0) == probes + 1, "the hint probed again within its cooldown")
            try require(fixture.events(named: "routing.strict_direct_reachable").count == 1, "a second hint within the cooldown")
            try require(fixture.target.connectionCount == baseline + 1, "a failed strict request reached the target directly")
            await fixture.stop()
        } catch {
            await fixture.stop()
            throw error
        }
        return ScenarioResult(
            name: "strict-direct-reachable", clientCount: 4, clientsOpened: 4, clientsWithFirstByte: 4,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [.init("strict mode never routes a reachable target direct; one hint on upstream failure", true)],
            notes: ["PASS: 2/2 via upstream with no probe; upstream down → 502, 1 probe, 1 hint, no retry"]
        )
    }

    /// Gateway mode, outside strict mode (#93): the reachability probe never
    /// probes a blocked literal or metadata name, and never connects to a
    /// name that resolves to a blocked address; it caches that as
    /// unreachable. The same name outside gateway mode is probed and
    /// connected to, so the target's connection count would show a probe.
    /// Gateway listeners bind 0.0.0.0, so this drives the detector the HTTP
    /// listener uses rather than a gateway listener.
    @MainActor
    static func gatewayProbeBlocklist(verbose: Bool) async throws -> ScenarioResult {
        let started = Date()
        let group = MultiThreadedEventLoopGroup.singleton
        let target = FakeOrigin(group: group, behavior: .silent)
        try await target.start()
        do {
            try await checkGatewayProbeBlocklist(target: target, verbose: verbose)
        } catch {
            await target.stop()
            throw error
        }
        await target.stop()
        return ScenarioResult(
            name: "gateway-probe-blocklist", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [.init("gateway mode never probes or connects to a blocked target", true)],
            notes: ["PASS: 3 blocked targets, 0 probes; rebinding name resolved, 0 connections, cached unreachable; 4 routing.probe_blocked; control 1 connection, not reused after gateway mode comes on"]
        )
    }

    @MainActor
    private static func checkGatewayProbeBlocklist(target: FakeOrigin, verbose: Bool) async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let port = target.port
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        let lookups = NIOLockedValueBox<[String]>([])
        let events = RuntimeEventLog(capacity: 64)
        let makeDetector = {
            DirectConnectDetector(
                group: group, logger: logger, ttlSeconds: 300, baseTimeoutMS: 500,
                resolver: { host, _, loop in
                    lookups.withLockedValue { $0.append(host) }
                    return loop.makeSucceededFuture([loopback])
                },
                eventSink: { events.append($0) }
            )
        }
        func blockedReasons() -> [String] {
            events.events.filter { $0.event == "routing.probe_blocked" }.compactMap { event in
                event.detail?.split(separator: " ").first { $0.hasPrefix("reason=") }.map(String.init)
            }
        }
        func settled(_ detector: DirectConnectDetector, _ host: String, gatewayMode: Bool) async throws -> Bool {
            for _ in 0..<200 where detector.cachedReachability(host: host, port: port, gatewayMode: gatewayMode) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let cached = detector.cachedReachability(host: host, port: port, gatewayMode: gatewayMode) else {
                throw Failure(description: "the probe of \(host) never finished")
            }
            return cached
        }

        let gateway = makeDetector()
        for blocked in ["127.0.0.1", "169.254.169.254", "metadata.google.internal"] {
            gateway.probeInBackground(host: blocked, port: port, gatewayMode: true)
        }
        try require(gateway.probeCount == 0, "a blocked target was probed (\(gateway.probeCount)x)")
        try require(lookups.withLockedValue { $0 }.isEmpty, "a blocked target was resolved")

        gateway.probeInBackground(host: "rebind.example", port: port, gatewayMode: true)
        let rebound = try await settled(gateway, "rebind.example", gatewayMode: true)
        try require(!rebound, "a name resolving to loopback cached as reachable")
        try require(target.connectionCount == 0, "the probe connected to a blocked address")
        let reasons = blockedReasons()
        try require(reasons == Array(repeating: "reason=blocked_name", count: 3) + ["reason=blocked_address"],
                    "routing.probe_blocked reasons: \(reasons)")

        let open = makeDetector()
        open.probeInBackground(host: "rebind.example", port: port, gatewayMode: false)
        let control = try await settled(open, "rebind.example", gatewayMode: false)
        for _ in 0..<200 where target.connectionCount == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        try require(control && target.connectionCount == 1, "control: outside gateway mode the probe did not connect")

        // Gateway mode comes on: the answer found outside it is not reused.
        try require(!open.shortcutReachable(host: "rebind.example", port: port, gatewayMode: true),
                    "a reachability found outside gateway mode was used in gateway mode")
        let switched = try await settled(open, "rebind.example", gatewayMode: true)
        try require(!switched && target.connectionCount == 1, "after the switch the probe connected to a blocked address")
    }
}
