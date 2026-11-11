// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import ProxyKernel

enum TunnelFailoverScenarios {
    /// `pm-sim tunnel-failover-backoff` (decision 0045).
    ///
    /// A pool that does not count an answered 4xx, as the DoH upstream route's
    /// does, over two upstreams: the primary answers 403 to every CONNECT, as
    /// a proxy blocking the target by policy, and nothing listens on the
    /// secondary's port. Each tunnel fails over from the primary's 403 to the
    /// secondary, whose refused dial counts until its breaker opens. From then
    /// on a failover asks no upstream in its backoff, so the 403 stands.
    ///
    /// | # | condition                          | expected                                                      |
    /// |---|------------------------------------|---------------------------------------------------------------|
    /// | A | `threshold` tunnels                | the refused dials open the secondary's breaker                |
    /// | B | three more tunnels                 | each fails with the primary's 403                             |
    /// | C | the secondary in its backoff        | never forced half-open (`upstream.circuit_half_opened` absent) |
    /// | D | the primary                        | asked once per tunnel, and its breaker still closed           |
    @RuntimeActor
    static func aFailoverSkipsAnUpstreamInItsBackoff(verbose: Bool) async throws -> ScenarioResult {
        let name = "tunnelFailoverBackoff"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton

        let primary = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: 9, requireAuth: false)
        ScenarioCleanup.register { await primary.stop() }
        try await primary.start()
        primary.connectRefusalStatus = 403
        let unused = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let secondaryPort = unused.localAddress?.port ?? 0
        try await unused.close().get()

        var config = ProxyConfig()
        config.circuitBreakerWindowSeconds = 0
        config.circuitFailureThreshold = 2
        config.circuitBaseOpenIntervalSeconds = 300
        config.circuitMaxOpenIntervalSeconds = 300
        config.upstreams = [
            UpstreamProxy(name: "primary", host: "127.0.0.1", port: primary.port, priority: 0),
            UpstreamProxy(name: "secondary", host: "127.0.0.1", port: secondaryPort, priority: 1),
        ]
        let frozen = config
        notes.append("primary 127.0.0.1:\(primary.port) answers 403; nothing listens on secondary 127.0.0.1:\(secondaryPort)")

        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event) } }
        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in MockAuthenticator() },
            eventSink: sink, answeredStatusAccounting: .serverErrorsOnly
        )
        ScenarioCleanup.register { pool.closeAll(scope: .all) }
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in MockAuthenticator() }, logger: logger, eventSink: sink
        )

        func tunnel(_ index: Int) async -> String {
            do {
                let opened = try await coordinator.connectUpstreamTunnel(target: "blocked-\(index).example:443").get()
                opened.channel.close(promise: nil)
                return "opened via \(opened.endpoint)"
            } catch {
                return error.displayDescription
            }
        }

        for index in 0..<frozen.circuitFailureThreshold { notes.append("A tunnel \(index): \(await tunnel(index))") }
        let opened = events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_opened" }.map { $0.detail ?? "" }
        let passA = opened.count == 1 && opened[0].hasPrefix("upstream=secondary ")
        notes.append("A opened=\(opened)")

        let attemptsBefore = primary.connectAttemptCount
        let phaseStart = Date()
        var outcomes: [String] = []
        for index in 0..<3 { outcomes.append(await tunnel(frozen.circuitFailureThreshold + index)) }
        let phaseSeconds = Date().timeIntervalSince(phaseStart)
        let passB = outcomes.allSatisfy { $0.contains("HTTP 403") } && phaseSeconds < 5
        notes.append("B outcomes=\(outcomes) seconds=\(String(format: "%.2f", phaseSeconds))")

        let halfOpened = events.withLockedValue { $0 }.filter { $0.event == "upstream.circuit_half_opened" }.map { $0.detail ?? "" }
        let passC = halfOpened.isEmpty
        notes.append("C halfOpened=\(halfOpened)")

        let asked = primary.connectAttemptCount - attemptsBefore
        let circuits = pool.upstreamStatuses().map { "\($0.name)=\($0.circuitState)" }
        let passD = asked == 3 && circuits == ["primary=closed", "secondary=open"]
        notes.append("D primaryAsked=\(asked) circuits=\(circuits)")

        let checks = [passA, passB, passC, passD]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — a failover leaves an upstream in its backoff alone and the 403 stands"
            : "FAIL — see per-case lines above")
        return ScenarioResult(
            name: name,
            clientCount: frozen.circuitFailureThreshold + 3,
            clientsOpened: frozen.circuitFailureThreshold + 3,
            clientsWithFirstByte: 0,
            clientsClosedEarly: 0,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("refused dials to the secondary open its breaker", passA),
                .init("with the secondary in its backoff, each tunnel fails at once with the primary's 403", passB),
                .init("no failover forced the secondary into a half-open probe", passC),
                .init("the primary is asked once per tunnel and stays closed", passD),
            ],
            notes: notes
        )
    }
    /// `pm-sim tunnel-remote-host-refused` (decision 0045).
    ///
    /// A proxied tunnel writes its remote host into a CONNECT; a direct one hands it to getaddrinfo. A proxied row whose
    /// host is a Unicode name is flagged by validation without blocking the proxy, and the tunnel start refuses that row
    /// alone.
    ///
    /// | # | condition                                   | expected                                                 |
    /// |---|---------------------------------------------|----------------------------------------------------------|
    /// | A | validate a proxied Unicode row, a direct scoped address and a direct Unicode row | one non-blocking `invalid_tunnel_remote_host`, for the proxied row |
    /// | B | start the tunnels                           | the two direct rows and a valid proxied row bind; the Unicode proxied row does not |
    /// | C | the refusal                                 | one `tunnel.start_refused` naming its port and printable host |
    @RuntimeActor
    static func aProxiedTunnelsUnwritableHostIsRefusedAlone(verbose: Bool) async throws -> ScenarioResult {
        let name = "tunnelRemoteHostRefused"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton

        var config = ProxyConfig()
        config.tunnels.definitions = [
            TunnelDefinition(localPort: 0, remoteHost: "bücher.corp.example", remotePort: 5432, proxied: true, label: "proxied-unicode"),
            TunnelDefinition(localPort: 0, remoteHost: "db.corp.example", remotePort: 5432, proxied: true, label: "proxied"),
            TunnelDefinition(localPort: 0, remoteHost: "fe80::1%en0", remotePort: 5432, label: "direct-scoped"),
            TunnelDefinition(localPort: 0, remoteHost: "bücher.corp.example", remotePort: 5432, label: "direct-unicode"),
        ]
        let problems = config.validate().map(\.check)
        let passA = problems == ["invalid_tunnel_remote_host field=tunnels.definitions[0].remoteHost"]
            && config.startBlockingProblems.isEmpty
        notes.append("A problems=\(problems) blocking=\(config.startBlockingProblems.map(\.check))")

        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event) } }
        let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
        let frozen = config
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in MockAuthenticator() }
        )
        ScenarioCleanup.register { pool.closeAll(scope: .all) }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator() }, logger: logger)
        let forwarder = TunnelForwarder(
            group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger, eventSink: sink
        )
        let result = await forwarder.start(tunnels: frozen.tunnels.definitions, listenHost: "127.0.0.1")
        await forwarder.stop()
        let bound = result.bindings.map(\.label)
        let passB = bound == ["proxied", "direct-scoped", "direct-unicode"] && result.failed == 1
        notes.append("B bound=\(bound) failed=\(result.failed)")

        let refused = events.withLockedValue { $0 }.filter { $0.event == "tunnel.start_refused" }.map { $0.detail ?? "" }
        let passC = refused == ["localPort=0 remoteHost=b__cher.corp.example reason=remote_host_not_host_text"]
        notes.append("C refused=\(refused)")

        let checks = [passA, passB, passC]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — one proxied tunnel is refused and nothing else is held back"
            : "FAIL — see per-case lines above")
        return ScenarioResult(
            name: name,
            clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("validation flags only the proxied Unicode row, and nothing blocks the proxy", passA),
                .init("every other tunnel binds, the direct scoped and Unicode rows included", passB),
                .init("the refused tunnel is reported once as tunnel.start_refused", passC),
            ],
            notes: notes
        )
    }
    /// `pm-sim tunnel-local-dial-uncharged` (decision 0045).
    ///
    /// A dial that fails on this machine says nothing about the upstream, so it must not open a breaker: during a VPN
    /// flap a routing gap would otherwise open every healthy upstream's. A connect to port 0 fails locally with
    /// `EADDRNOTAVAIL` on macOS, as NIO reports it; a port nothing listens on refuses, which is the upstream's.
    ///
    /// | # | condition                                         | expected                                      |
    /// |---|---------------------------------------------------|-----------------------------------------------|
    /// | A | `threshold + 1` tunnels and exchanges to port 0  | each fails with `EADDRNOTAVAIL`; the breaker stays closed |
    /// | B | `threshold` tunnels to a port that refuses        | the breaker opens                             |
    @RuntimeActor
    static func aLocalDialFailureOpensNoBreaker(verbose: Bool) async throws -> ScenarioResult {
        let name = "tunnelLocalDialUncharged"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let unused = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let refusingPort = unused.localAddress?.port ?? 0
        try await unused.close().get()

        func attempt(port: Int, tunnels: Int, exchanges: Int) async -> (failures: [String], circuit: String) {
            var config = ProxyConfig()
            config.circuitBreakerWindowSeconds = 0
            config.circuitFailureThreshold = 2
            config.upstreams = [UpstreamProxy(name: "upstream", host: "127.0.0.1", port: port, priority: 0)]
            let frozen = config
            let logger = RecordingLogSink(minLevel: verbose ? .debug : .info)
            let pool = ConnectionPool(
                group: group, logger: logger, configProvider: { frozen }, authenticatorProvider: { _ in MockAuthenticator() }
            )
            ScenarioCleanup.register { pool.closeAll(scope: .all) }
            let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in MockAuthenticator() }, logger: logger)
            var failures: [String] = []
            for index in 0..<tunnels {
                do {
                    let opened = try await coordinator.connectUpstreamTunnel(target: "local-\(index).example:443").get()
                    opened.channel.close(promise: nil)
                    failures.append("opened")
                } catch {
                    failures.append(error.displayDescription)
                }
            }
            var head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://local.example/")
            head.headers.add(name: "Host", value: "local.example")
            for _ in 0..<exchanges {
                do {
                    _ = try await pool.exchange(head: head, body: nil).get()
                    failures.append("answered")
                } catch {
                    failures.append(error.displayDescription)
                }
            }
            return (failures, pool.upstreamStatuses().map { "\($0.circuitState)" }.joined())
        }

        let local = await attempt(port: 0, tunnels: 3, exchanges: 3)
        let passA = local.failures.count == 6 && local.failures.allSatisfy { $0.contains("assign requested address") } && local.circuit == "closed"
        notes.append("A failures=\(Set(local.failures)) circuit=\(local.circuit)")

        let refused = await attempt(port: refusingPort, tunnels: 2, exchanges: 0)
        let passB = refused.circuit == "open"
        notes.append("B failures=\(Set(refused.failures)) circuit=\(refused.circuit)")

        let checks = [passA, passB]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — a local dial failure opens no breaker, and a refusal still does"
            : "FAIL — see per-case lines above")
        return ScenarioResult(
            name: name,
            clientCount: 8, clientsOpened: 0, clientsWithFirstByte: 0, clientsClosedEarly: 0, totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("tunnels and exchanges that fail locally with EADDRNOTAVAIL leave the breaker closed", passA),
                .init("refused dials still open the breaker", passB),
            ],
            notes: notes
        )
    }
}
