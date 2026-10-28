// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import ProxyKernel

/// #148, #156: a confirmed VPN transition closes the tunnels whose path it
/// removed, at once, so clients reconnect instead of stalling into a
/// timeout; a flap keeps every stream.
///
/// The real orchestrator, listener, pool and CONNECT pipeline own the
/// sockets. Probe reachability and the machine's paths are injected: every
/// socket here is loopback, so a path is "gone" by its peer's port, standing
/// in for a VPN address that went away or a route that moved onto the
/// tunnel. `127.0.0.1` is a default no-proxy host, so a CONNECT to an
/// origin's loopback port is a DIRECT tunnel whatever the VPN state;
/// `migrate.test:443` goes via the upstream.
enum VPNTransitionMigrationScenarios {
    @RuntimeActor
    private static func until(timeout: TimeInterval, _ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(Int64(timeout * 1000))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        return condition()
    }

    /// Paths judged by peer port: a port in `gone` has lost its path (its
    /// route moved), one in `goneAddress` its local address.
    private static func paths(
        _ gone: NIOLockedValueBox<Set<Int>>, goneAddress: NIOLockedValueBox<Set<Int>> = NIOLockedValueBox([])
    ) -> ClosureSocketPaths {
        ClosureSocketPaths { query in
            let port = query.remote.port ?? -1
            if goneAddress.withLockedValue({ $0.contains(port) }) { return .stranded(SocketPathVerdict.addressGone) }
            return gone.withLockedValue { $0.contains(port) } ? .stranded("interface_changed") : .current
        }
    }

    @RuntimeActor
    static func run(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        let origin = FakeOrigin(group: group, behavior: .echo)
        try await origin.start(); ScenarioCleanup.register { await origin.stop() }
        let offOrigin = FakeOrigin(group: group, behavior: .echo)
        try await offOrigin.start(); ScenarioCleanup.register { await offOrigin.stop() }
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: false)
        try await upstream.start(); ScenarioCleanup.register { await upstream.stop() }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "migrating", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let gone = NIOLockedValueBox<Set<Int>>([]), goneAddress = NIOLockedValueBox<Set<Int>>([])
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            },
            socketPaths: paths(gone, goneAddress: goneAddress), strandedResweepDelays: [.milliseconds(200)])
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
        func migrations() -> [String] {
            orchestrator.eventLog.events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
        }

        // On the VPN: one tunnel via the upstream, one PAC/no-proxy DIRECT.
        let viaUpstream = try await tunnel(0, "migrate.test:443")
        let directOnVPN = try await tunnel(1, "127.0.0.1:\(origin.port)")

        // A flap keeps every stream and sweeps nothing, even with a path
        // missing mid-flap.
        await orchestrator.handleVPNStateChange(.reasserting)
        gone.withLockedValue { _ = $0.insert(upstream.port) }
        try await Task.sleep(for: .milliseconds(300))
        gone.withLockedValue { _ = $0.remove(upstream.port) }
        await orchestrator.handleVPNStateChange(.connected)
        let flapKept = try await exchanging(viaUpstream)
        let flapKeptDirect = try await exchanging(directOnVPN)
        try await Task.sleep(for: .milliseconds(300))
        let afterFlap = migrations()
        let flapClosed = afterFlap.filter { !$0.contains("upstream_closed=0") || !$0.contains("direct_closed=0") }

        // A flap that ends with the tunnel back on another address: the
        // recovery closes the socket whose address went, after a short wait.
        let onOldAddress = try await tunnel(5, "127.0.0.1:\(offOrigin.port)")
        await orchestrator.handleVPNStateChange(.reasserting)
        goneAddress.withLockedValue { _ = $0.insert(offOrigin.port) }
        await orchestrator.handleVPNStateChange(.connected)
        let oldAddressClosed = try await until(timeout: 2, { onOldAddress.metrics.closedAt != nil })
        let flapRecoverySweep = migrations().last { $0.hasPrefix("transition=flap_recovered phase=addresses ") } ?? ""
        goneAddress.withLockedValue { $0 = [] }

        // A confirmed disconnect takes the VPN address the upstream tunnel
        // used; the DIRECT one's path survives.
        reachable.withLockedValue { $0 = false }
        gone.withLockedValue { _ = $0.insert(upstream.port) }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let upstreamClosed = try await until(timeout: 1, { viaUpstream.metrics.closedAt != nil })
        let disconnectSweep = migrations().first { $0.hasPrefix("transition=disconnected phase=paths pass=0 ") } ?? ""
        let directKeptOnDisconnect = try await exchanging(directOnVPN)

        // Off the VPN, a DIRECT tunnel; the reconnect moves its route onto
        // the tunnel, but not the one PAC/no-proxy sent DIRECT while connected.
        let directOffVPN = try await tunnel(2, "127.0.0.1:\(offOrigin.port)")
        reachable.withLockedValue { $0 = true }
        gone.withLockedValue { $0 = [offOrigin.port] }
        await orchestrator.handleVPNStateChange(.connected)
        let offVPNClosed = try await until(timeout: 1, { directOffVPN.metrics.closedAt != nil })
        let reconnectSweep = migrations().last { $0.hasPrefix("transition=connected phase=paths pass=0 ") } ?? ""
        let directKeptOnReconnect = try await exchanging(directOnVPN)

        // On-prem: the VPN goes but the upstream stays reachable over the
        // LAN, so its tunnel's path is current and it keeps exchanging; a
        // DIRECT tunnel whose route the reconnect moves is closed.
        gone.withLockedValue { $0 = [] }
        let onPremUpstream = try await tunnel(3, "migrate.test:443")
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        let onPremCause = orchestrator.snapshot.directModeCause
        let onPremKept = try await exchanging(onPremUpstream)
        let directOnPrem = try await tunnel(4, "127.0.0.1:\(offOrigin.port)")
        gone.withLockedValue { $0 = [offOrigin.port] }
        await orchestrator.handleVPNStateChange(.connected)
        let onPremClosed = try await until(timeout: 1, { directOnPrem.metrics.closedAt != nil })
        let directKeptOnPrem = try await exchanging(directOnVPN)

        let routingDetail = migrations().first { $0.contains("phase=routing reason=user") } ?? ""
        let clients = [viaUpstream, directOnVPN, onOldAddress, directOffVPN, onPremUpstream, directOnPrem]
        return ScenarioResult(name: "vpn-transition-migration", clientCount: clients.count, clientsOpened: clients.count,
            clientsWithFirstByte: clients.count, clientsClosedEarly: clients.filter { $0.metrics.closedAt != nil }.count,
            totalBytes: directOnVPN.metrics.bytesReceived, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("a flap keeps both tunnels and closes nothing, even with a path missing mid-flap",
                      flapKept && flapKeptDirect && flapClosed.isEmpty),
                .init("a flap recovery closes the tunnel whose address went, after its wait",
                      oldAddressClosed && flapRecoverySweep.contains(" direct_closed=1 ")),
                .init("a disconnect closes the upstream tunnel whose path it removed within 1 s", upstreamClosed),
                // Whichever of the path sweep and the routing phase runs
                // first closes it; the other finds it gone.
                .init("the disconnect's path sweep or routing phase reports it",
                      [disconnectSweep, routingDetail].contains {
                          $0.contains(" upstream_closed=") && !$0.contains(" upstream_closed=0 ") && !$0.hasSuffix(" upstream_closed=0")
                      }),
                .init("the routing phase still runs once the probe decides", routingDetail.contains("routing=direct")),
                .init("a DIRECT tunnel whose path survived keeps exchanging", directKeptOnDisconnect && directKeptOnReconnect),
                .init("the reconnect closes the DIRECT tunnel whose route moved within 1 s", offVPNClosed),
                .init("the reconnect's path sweep reports one DIRECT closure",
                      reconnectSweep.contains(" direct_closed=1 ")),
                .init("on-prem, the upstream tunnel on a current path survives the disconnect",
                      onPremCause == .none && onPremKept),
                .init("on-prem, the reconnect closes the DIRECT tunnel whose route moved within 1 s", onPremClosed),
                .init("the on-VPN DIRECT tunnel survives the on-prem round too", directKeptOnPrem),
            ], notes: ["flap recovery: \(flapRecoverySweep)", "disconnect: \(disconnectSweep)", "routing: \(routingDetail)", "reconnect: \(reconnectSweep)",
                       "Injected probe outcomes and paths; no real VPN, helper, settings or credentials"])
    }

    /// #156: setup that straddles a confirmed transition. A CONNECT whose
    /// upstream handshake is still unanswered when a DIRECT-routing
    /// disconnect lands fails at once with a local 502: no wait for the
    /// response timeout, no retry on another upstream, no DIRECT fallback.
    @RuntimeActor
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

        let routing = migrations(orchestrator).last { $0.contains("phase=routing") } ?? ""
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

    /// #156: a dial that connects over a path a VPN transition already
    /// removed is closed when it registers, whenever its routing was decided:
    /// the client gets a 502 at once, the upstream is not blamed, and no
    /// other upstream is tried.
    @RuntimeActor
    static func lateDial(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        // Two upstreams that count connections; the dial never gets past
        // registration, so neither needs to answer.
        let accepted = NIOLockedValueBox(0)
        var ports: [Int] = []
        for _ in 0..<2 {
            let upstream = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    accepted.withLockedValue { $0 += 1 }
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                .bind(host: "127.0.0.1", port: 0).get()
            ScenarioCleanup.register { try? await upstream.close().get() }
            ports.append(upstream.localAddress!.port!)
        }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "first", host: "127.0.0.1", port: ports[0], priority: 0),
                            UpstreamProxy(name: "second", host: "127.0.0.1", port: ports[1], priority: 1)]
        let gone = NIOLockedValueBox<Set<Int>>([])
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
            },
            socketPaths: paths(gone))
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        await orchestrator.handleVPNStateChange(.connected)
        let port = orchestrator.snapshot.bindings.proxyPort!
        try await Task.sleep(for: .milliseconds(300))
        let before = accepted.withLockedValue { $0 }

        // The route to both upstreams moved while the CONNECT was being set up.
        gone.withLockedValue { $0 = Set(ports) }
        let sentAt = ContinuousClock.now
        let answer = try await RawClient.send(group: group, port: port,
            request: "CONNECT migrate.test:443 HTTP/1.1\r\nHost: migrate.test:443\r\n\r\n").get()
        let answeredWithin = ContinuousClock.now - sentAt
        try await Task.sleep(for: .milliseconds(100))
        let retired = orchestrator.eventLog.events.filter { $0.event == LateDialRetired.event }.compactMap(\.detail)
        let failures = orchestrator.eventLog.events.filter { $0.event.hasPrefix("upstream.") && $0.event.hasSuffix("_failed") }

        return ScenarioResult(name: "vpn-transition-late-dial", clientCount: 1, clientsOpened: 1,
            clientsWithFirstByte: answer.isEmpty ? 0 : 1, clientsClosedEarly: 0,
            totalBytes: answer.utf8.count, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("the client gets a 502 within 1 s", answer.hasPrefix("HTTP/1.1 502") && answeredWithin < .seconds(1)),
                .init("the retirement is reported with its path", retired.count == 1
                      && retired[0].contains("reason=\(LateDialRetired.pathGone("interface_changed"))")),
                .init("no other upstream is tried", accepted.withLockedValue { $0 } - before == 1),
                .init("no upstream failure is reported", failures.isEmpty),
            ], notes: ["answer: \(answer.split(separator: "\r\n").first ?? "")", "retired: \(retired)",
                       "Injected probe outcomes and paths; no real VPN, helper, settings or credentials"])
    }

    @RuntimeActor
    private static func migrations(_ orchestrator: ProxyOrchestrator) -> [String] {
        orchestrator.eventLog.events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
    }

    /// #156: a plain HTTP request routed DIRECT during an outage, waiting on
    /// a silent origin, has its origin socket closed by the reconnect sweep
    /// once its route moves onto the tunnel.
    /// The client must get a 502 at once, not hang until it gives up.
    @RuntimeActor
    static func directHTTPSwept(verbose: Bool) async throws -> ScenarioResult {
        let started = Date(), group = MultiThreadedEventLoopGroup.singleton
        let logger = ConsoleLogSink(minLevel: verbose ? .debug : .warning)
        // Accepts the request and never answers, counting connections.
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
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let gone = NIOLockedValueBox<Set<Int>>([])
        let orchestrator = ProxyOrchestrator(config: config, logger: logger, authenticatorProvider: { _ in MockAuthenticator() },
            connectivityProbe: { targets in
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            },
            socketPaths: paths(gone))
        try await orchestrator.startProxy(); ScenarioCleanup.register { await orchestrator.stopProxy() }
        await orchestrator.handleVPNStateChange(.connected)
        let port = orchestrator.snapshot.bindings.proxyPort!

        // Off the VPN the upstream is gone: routing is DIRECT.
        reachable.withLockedValue { $0 = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let direct = orchestrator.snapshot.directModeCause == .vpnDisconnected
        let pending = try await RawClient.send(group: group, port: port,
            request: "GET http://127.0.0.1:\(silentPort)/held HTTP/1.1\r\nHost: 127.0.0.1:\(silentPort)\r\n\r\n")
        guard try await until(timeout: 3, { accepted.withLockedValue { $0 } > 0 }) else {
            throw ScenarioExecutionError(message: "the DIRECT request never reached the silent origin")
        }
        // The reconnect moves the origin's route onto the tunnel and closes
        // the DIRECT socket set up during the outage.
        let reconnectedAt = ContinuousClock.now
        reachable.withLockedValue { $0 = true }
        gone.withLockedValue { _ = $0.insert(silentPort) }
        await orchestrator.handleVPNStateChange(.connected)
        let answer = try await pending.get()
        let answeredWithin = ContinuousClock.now - reconnectedAt
        let sweep = orchestrator.eventLog.events.last {
            $0.event == "vpn.tunnels_migrated" && ($0.detail?.hasPrefix("transition=connected phase=paths") ?? false)
        }?.detail ?? ""

        return ScenarioResult(name: "vpn-transition-direct-http", clientCount: 1, clientsOpened: 1,
            clientsWithFirstByte: answer.isEmpty ? 0 : 1, clientsClosedEarly: 0,
            totalBytes: answer.utf8.count, durationSeconds: Date().timeIntervalSince(started), aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil, assertions: [
                .init("the request is routed DIRECT during the outage", direct),
                .init("the reconnect sweep closes its origin socket",
                      sweep.contains(" direct_closed=1 ")),
                .init("the client gets a 502 within 1 s of the reconnect, not a hang",
                      answer.hasPrefix("HTTP/1.1 502") && answeredWithin < .seconds(1)),
            ], notes: ["silent loopback origin on port \(silentPort); injected probe outcomes; sweep: \(sweep)"])
    }
}
