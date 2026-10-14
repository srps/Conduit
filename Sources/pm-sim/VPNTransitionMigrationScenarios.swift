// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel

/// #148: a confirmed VPN transition retires the tunnels the new routing
/// stranded, at once, so clients reconnect instead of stalling into a
/// timeout; a flap keeps every stream.
///
/// The real orchestrator, listener, pool and CONNECT pipeline own the
/// sockets. Only probe reachability is injected. `127.0.0.1` is a default
/// no-proxy host, so a CONNECT to the origin's loopback port is a DIRECT
/// tunnel whatever the VPN state; `migrate.test:443` goes via the upstream.
enum VPNTransitionMigrationScenarios {
    @MainActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    @MainActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "migrating", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        // What the disconnect's probe saw: the address phase must precede it.
        let eventLog = NIOLockedValueBox<RuntimeEventLog?>(nil)
        let migrationsAtProbe = NIOLockedValueBox<[String]?>(nil)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let up = reachable.withLockedValue { $0 }
                if !up, let events = eventLog.withLockedValue({ $0 })?.events {
                    migrationsAtProbe.withLockedValue {
                        $0 = events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
                    }
                }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        eventLog.withLockedValue { $0 = orchestrator.eventLog }
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        await orchestrator.handleVPNStateChange(.connected)
        let port = orchestrator.snapshot.bindings.proxyPort!

        func tunnel(_ id: Int, _ target: String) async throws -> FakeClient {
            let client = FakeClient(id: id, group: group, localProxyHost: "127.0.0.1", localProxyPort: port,
                target: target, behavior: .periodicPing(requestBytes: 16, pingIntervalMs: 100, pingBytes: 16))
            ScenarioCleanup.register { await client.close() }
            try await client.run()
            guard try await until(timeout: 3, { client.metrics.bytesReceived > 0 }) else {
                throw ScenarioExecutionError(message: "tunnel \(id) to \(target) never echoed")
            }
            return client
        }
        func exchanging(_ client: FakeClient) async throws -> Bool {
            let before = client.metrics.bytesReceived
            return try await until(timeout: 2, { client.metrics.bytesReceived > before }) && client.metrics.closedAt == nil
        }
        func migrations() -> [RuntimeEvent] {
            orchestrator.eventLog.events.filter { $0.event == "vpn.tunnels_migrated" }
        }
        let directTarget = "127.0.0.1:\(origin.port)"

        // On the VPN: one tunnel via the upstream, one PAC/no-proxy DIRECT.
        let viaUpstream = try await tunnel(0, "migrate.test:443")
        let directOnVPN = try await tunnel(1, directTarget)

        // A flap keeps every stream and decides nothing.
        await orchestrator.handleVPNStateChange(.reasserting)
        try await Task.sleep(for: .milliseconds(200))
        await orchestrator.handleVPNStateChange(.connected)
        let flapKept = try await exchanging(viaUpstream)
        let flapKeptDirect = try await exchanging(directOnVPN)
        let flapMigrations = migrations().count

        // A confirmed disconnect routing DIRECT retires the upstream tunnel;
        // the DIRECT one (its loopback address is still assigned) stays.
        reachable.withLockedValue { $0 = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let upstreamClosed = try await until(timeout: 1, { viaUpstream.metrics.closedAt != nil })
        let disconnectEvents = migrations().suffix(2).compactMap(\.detail)
        let directKeptOnDisconnect = try await exchanging(directOnVPN)

        // Off the VPN, a DIRECT tunnel; the reconnect retires it, not the
        // one PAC/no-proxy sent DIRECT while connected.
        let directOffVPN = try await tunnel(2, directTarget)
        reachable.withLockedValue { $0 = true }
        await orchestrator.handleVPNStateChange(.connected)
        let offVPNClosed = try await until(timeout: 1, { directOffVPN.metrics.closedAt != nil })
        let reconnectEvent = migrations().last
        let directKeptOnReconnect = try await exchanging(directOnVPN)

        // On-prem: the upstream stays reachable, so the cause stays `.none`
        // and routing stays on the upstream, yet a no-proxy DIRECT tunnel
        // dialed during the outage still leaves on the off-VPN path. The
        // reconnect sweeps it by VPN state, not by cause.
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        let onPremCause = orchestrator.snapshot.directModeCause
        let directOnPrem = try await tunnel(3, directTarget)
        await orchestrator.handleVPNStateChange(.connected)
        let onPremClosed = try await until(timeout: 1, { directOnPrem.metrics.closedAt != nil })
        let onPremReconnect = migrations().last?.detail ?? ""
        let directKeptOnPrem = try await exchanging(directOnVPN)

        let addressesDetail = disconnectEvents.first ?? ""
        let disconnectDetail = disconnectEvents.last ?? ""
        let atProbe = migrationsAtProbe.withLockedValue { $0 } ?? []
        // The tunnel plus any pooled connection the health check left idle.
        let upstreamClosedCount = disconnectDetail.split(separator: " ")
            .first { $0.hasPrefix("upstream_closed=") }
            .flatMap { Int($0.dropFirst("upstream_closed=".count)) } ?? 0
        let reconnectDetail = reconnectEvent?.detail ?? ""
        return ScenarioResult(name: "vpn-transition-migration", clientCount: 4, clientsOpened: 4,
            clientsWithFirstByte: 4, clientsClosedEarly: [viaUpstream, directOnVPN, directOffVPN, directOnPrem].filter { $0.metrics.closedAt != nil }.count,
            totalBytes: directOnVPN.metrics.bytesReceived, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("a flap keeps both tunnels and migrates nothing", flapKept && flapKeptDirect && flapMigrations == 0),
                .init("a DIRECT-routing disconnect closes the upstream tunnel within 1 s", upstreamClosed),
                .init("the address phase ran before the probe and kept the loopback DIRECT tunnel",
                      atProbe.count == 1 && atProbe[0] == addressesDetail
                          && addressesDetail.hasPrefix("transition=disconnected phase=addresses reason=user ")
                          && addressesDetail.contains(" direct_closed=0 ")),
                .init("the routing phase reports the upstream tunnel it closed",
                      disconnectDetail.hasPrefix("transition=disconnected phase=routing reason=user routing=direct ")
                          && upstreamClosedCount >= 1),
                .init("a DIRECT tunnel whose address survived keeps exchanging", directKeptOnDisconnect && directKeptOnReconnect),
                .init("the reconnect closes the DIRECT tunnel opened off the VPN within 1 s", offVPNClosed),
                .init("the reconnect reports one DIRECT migration",
                      reconnectDetail == "transition=reconnected route=direct closed=1 untracked=0"),
                .init("an on-prem outage (cause none) still retires its DIRECT tunnel on reconnect within 1 s",
                      onPremCause == .none && onPremClosed
                          && onPremReconnect == "transition=reconnected route=direct closed=1 untracked=0"),
                .init("the on-VPN DIRECT tunnel survives the on-prem round too", directKeptOnPrem),
            ], notes: ["addresses: \(addressesDetail)", "routing: \(disconnectDetail)", "reconnect: \(reconnectDetail)", "on-prem reconnect: \(onPremReconnect)",
                       "Injected probe outcomes; no real VPN, helper, settings or credentials"])
    }

    /// #156: setup that straddles a confirmed transition. A CONNECT whose
    /// upstream handshake is still unanswered when a DIRECT-routing
    /// disconnect lands fails at once with a local 502: no wait for the
    /// response timeout, no retry on another upstream, no DIRECT fallback
    /// on the stale routing.
    @MainActor
    static func setupRace(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        // Accepts the CONNECT and never answers, counting connections.
        let accepted = NIOLockedValueBox(0)
        let silent = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                return channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0).get()
        ScenarioCleanup.register { try? await silent.close().get() }
        let silentPort = silent.localAddress!.port!
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreamResponseTimeoutSeconds = 30
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: silentPort, priority: 0),
                            UpstreamProxy(name: "second", host: "127.0.0.1", port: silentPort, priority: 1)]
        let reachable = NIOLockedValueBox(true)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            })
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        await orchestrator.handleVPNStateChange(.connected)
        let port = orchestrator.snapshot.bindings.proxyPort!

        // Startup prewarm may hold idle connections to it; count from here.
        try await Task.sleep(for: .milliseconds(300))
        let baseline = accepted.withLockedValue { $0 }
        let pending = try await RawClient.send(group: group, port: port,
            request: "CONNECT migrate.test:443 HTTP/1.1\r\nHost: migrate.test:443\r\n\r\n")
        guard try await until(timeout: 3, { accepted.withLockedValue { $0 } > baseline }) else {
            throw ScenarioExecutionError(message: "the CONNECT never reached the silent upstream")
        }
        let disconnectedAt = ContinuousClock.now
        reachable.withLockedValue { $0 = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let answer = try await pending.get()
        let answeredWithin = ContinuousClock.now - disconnectedAt
        let originBefore = origin.connectionCount
        try await Task.sleep(for: .milliseconds(200))
        let upstreamDials = accepted.withLockedValue { $0 } - baseline
        let originAfterRace = origin.connectionCount

        let routing = migrations(orchestrator).last ?? ""
        let cause = orchestrator.snapshot.directModeCause

        return ScenarioResult(name: "vpn-transition-setup-race", clientCount: 1, clientsOpened: 1,
            clientsWithFirstByte: answer.isEmpty ? 0 : 1, clientsClosedEarly: 0,
            totalBytes: answer.utf8.count, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("the in-flight CONNECT gets a 502 within 1 s of the disconnect, not after the 30 s response timeout",
                      answer.hasPrefix("HTTP/1.1 502") && answeredWithin < .seconds(1)),
                .init("the routing phase closed the handshaking upstream socket",
                      routing.hasPrefix("transition=disconnected phase=routing reason=user routing=direct ")
                          && !routing.hasSuffix("upstream_closed=0")),
                .init("the retired CONNECT is not retried on the second upstream", upstreamDials == 1),
                .init("the retired CONNECT does not fall back DIRECT on the stale routing",
                      originBefore == 0 && originAfterRace == 0),
                .init("the disconnect routes DIRECT for new requests", cause.routesClientTrafficDirectly),
            ], notes: ["answer: \(answer.split(separator: "\r\n").first ?? "")", "routing: \(routing)",
                       "answered in \(answeredWithin)", "Injected probe outcomes; no real VPN, helper, settings or credentials"])
    }

    @MainActor
    private static func migrations(_ orchestrator: ProxyOrchestrator) -> [String] {
        orchestrator.eventLog.events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
    }
}
