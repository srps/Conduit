// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class VPNReconnectRoutingTests: XCTestCase {
    @RuntimeActor func testReconnectRevokesDirectRoutingBeforeAwaitingProbe() async throws {
        try await checkReconnect(hasUpstreams: true, reachable: true)
    }

    @RuntimeActor func testFailedReconnectProbeKeepsStrictUpstreamRouting() async throws {
        try await checkReconnect(hasUpstreams: true, reachable: false)
    }

    @RuntimeActor func testNoUpstreamsStillAllowsDirectRouting() async throws {
        try await checkReconnect(hasUpstreams: false, reachable: false)
    }

    /// Off the VPN client traffic routes directly, so DoH stops asking the corporate proxy. On the VPN, and off it while
    /// the disconnect re-probes the upstreams, DoH asks both.
    @RuntimeActor func testTheDoHRouteFollowsTheVPN() async throws {
        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.upstreams = [UpstreamProxy(name: "corporate", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let orchestrator = ProxyOrchestrator(config: config, pacEvaluator: StaticPAC(), connectivityProbe: { upstreams in
            let answers = reachable.withLockedValue { $0 }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: answers) })
        })
        try await orchestrator.startProxy()
        func routes() -> [String] {
            orchestrator.eventLog.events.filter { $0.event == "dns.doh_route_changed" }.compactMap(\.detail)
        }

        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertEqual(routes(), [], "on the VPN DoH keeps asking both routes")

        let forwarder = orchestrator.dnsForwarder
        let routeWhenCauseSeen = NIOLockedValueBox<(event: DoHRoute?, snapshot: DoHRoute?)>((nil, nil))
        orchestrator.eventLog.setSink { event in
            guard event.event == "direct_mode.entered" else { return }
            routeWhenCauseSeen.withLockedValue { $0.event = forwarder.doHRouteForNewLookups }
        }
        orchestrator.onSnapshotChange = { snapshot in
            guard snapshot.directModeCause == .vpnDisconnected else { return }
            routeWhenCauseSeen.withLockedValue { $0.snapshot = $0.snapshot ?? forwarder.doHRouteForNewLookups }
        }
        reachable.withLockedValue { $0 = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let cause = orchestrator.snapshot.directModeCause
        orchestrator.eventLog.setSink(nil)
        orchestrator.onSnapshotChange = nil
        await orchestrator.stopProxy()
        XCTAssertEqual(cause, .vpnDisconnected)
        let seen = routeWhenCauseSeen.withLockedValue { $0 }
        XCTAssertEqual(seen.event, .directOnly, "a lookup started on the direct-mode event takes the route of its cause")
        XCTAssertEqual(seen.snapshot, .directOnly, "a lookup started on the snapshot takes the route of its cause")
        XCTAssertEqual(routes(), [
            "route=direct_only prior=proxy_and_direct vpn=not_connected direct_mode=vpnDisconnected",
        ], "the re-probe off the VPN keeps both routes; direct routing drops the proxy")
    }

    /// A handler that reads the new direct-mode cause and starts a DoH lookup finds the route derived from that cause, even
    /// read from another thread while the transition is being published.
    @RuntimeActor func testAReaderThatSeesTheNewCauseFindsItsDoHRoute() async throws {
        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.upstreams = [UpstreamProxy(name: "corporate", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let orchestrator = ProxyOrchestrator(config: config, pacEvaluator: StaticPAC(), connectivityProbe: { upstreams in
            let answers = reachable.withLockedValue { $0 }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: answers) })
        })
        addTeardownBlock { @RuntimeActor in await orchestrator.stopProxy() }
        try await orchestrator.startProxy()
        let server = orchestrator.localProxyServer
        let forwarder = orchestrator.dnsForwarder

        for round in 0..<200 {
            reachable.withLockedValue { $0 = true }
            await orchestrator.handleVPNStateChange(.connected)
            XCTAssertNotEqual(server.directModeForNewConnections, .vpnDisconnected)
            let reader = NIOLockedValueBox<(spinning: Bool, route: DoHRoute?, done: Bool)>((false, nil, false))
            Thread.detachNewThread {
                let deadline = ContinuousClock.now + .seconds(10)
                reader.withLockedValue { $0.spinning = true }
                var spins = 0
                while server.directModeForNewConnections != .vpnDisconnected {
                    spins += 1
                    if spins % 4_096 == 0, ContinuousClock.now > deadline { break }
                }
                let route = forwarder.doHRouteForNewLookups
                reader.withLockedValue { $0 = (true, route, true) }
            }
            while !reader.withLockedValue({ $0.spinning }) { await Task.yield() }
            reachable.withLockedValue { $0 = false }
            await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
            while !reader.withLockedValue({ $0.done }) { try await Task.sleep(for: .milliseconds(1)) }
            let route = reader.withLockedValue { $0.route }
            XCTAssertEqual(route, .directOnly, "round \(round): the reader saw the new cause with an older route")
            if route != .directOnly { break }
        }
    }

    /// The orchestrator hands its route to both DoH consumers: once client traffic routes directly, a fresh lookup from
    /// either one leaves the local proxy alone.
    @RuntimeActor func testFreshLookupsFromBothDoHConsumersFollowTheRoute() async throws {
        var config = ProxyConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.localPACEnabled = false
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = []
        // Not loopback: CFNetwork would bypass the proxy for it.
        config.dohProviders = ["https://192.0.2.10/dns-query"]
        config.upstreams = [UpstreamProxy(name: "corporate", host: "127.0.0.1", port: 9, priority: 0)]
        let reachable = NIOLockedValueBox(true)
        let audit = CountingAuditSink()
        let orchestrator = ProxyOrchestrator(config: config, pacEvaluator: StaticPAC(), auditSink: audit, connectivityProbe: { upstreams in
            let answers = reachable.withLockedValue { $0 }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: answers) })
        })
        addTeardownBlock { @RuntimeActor in
            await orchestrator.stopDNS()
            await orchestrator.stopProxy()
        }
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")
        let dnsPort = try XCTUnwrap(orchestrator.dnsForwarder.listeningPort)
        let replies = NIOLockedValueBox(0)
        let client = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(CountReplies(replies: replies)) }
            .bind(host: "127.0.0.1", port: 0).get()
        closeAtTearDown(client)

        func proxyConnections(afterForwarderLookupOf name: String, txID: UInt16) async throws -> Int {
            let before = replies.withLockedValue { $0 }
            let query = DNSWireFormat.buildQuery(domain: name, txID: txID, qtype: 1)
            var buffer = client.allocator.buffer(capacity: query.count)
            buffer.writeBytes(query)
            try await client.writeAndFlush(AddressedEnvelope(
                remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: dnsPort), data: buffer
            )).get()
            let deadline = ContinuousClock.now + .seconds(20)
            while replies.withLockedValue({ $0 }) == before, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertGreaterThan(replies.withLockedValue { $0 }, before, "the forwarder answered \(name)")
            return try await settledProxyConnections()
        }
        func proxyConnectionsAfterOriginLookup(of name: String) async throws -> Int {
            do {
                _ = try await orchestrator.originResolver.resolveOrigin(
                    host: name, port: 443, on: MultiThreadedEventLoopGroup.singleton.next()
                ).get()
                XCTFail("no provider can answer \(name)")
            } catch {
                XCTAssertEqual(error as? OriginResolverError, .unresolved(host: name))
            }
            return try await settledProxyConnections()
        }
        // Every request the listener parsed is an active connection until it closes, then one audit record.
        func settledProxyConnections() async throws -> Int {
            let deadline = ContinuousClock.now + .seconds(10)
            while !orchestrator.snapshot.activeConnections.ordered.isEmpty, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            XCTAssertTrue(orchestrator.snapshot.activeConnections.ordered.isEmpty, "every proxied lookup closed")
            return audit.count
        }

        await orchestrator.handleVPNStateChange(.connected)
        let afterForwarderOnVPN = try await proxyConnections(afterForwarderLookupOf: "vpn.forwarder.example", txID: 0x0501)
        XCTAssertGreaterThan(afterForwarderOnVPN, 0, "on the VPN a forwarder lookup asks the local proxy")
        let afterOriginOnVPN = try await proxyConnectionsAfterOriginLookup(of: "vpn.origin.example")
        XCTAssertGreaterThan(afterOriginOnVPN, afterForwarderOnVPN, "on the VPN an origin lookup asks the local proxy")

        reachable.withLockedValue { $0 = false }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        let afterForwarderOffVPN = try await proxyConnections(afterForwarderLookupOf: "off.forwarder.example", txID: 0x0502)
        XCTAssertEqual(afterForwarderOffVPN, afterOriginOnVPN, "off the VPN a forwarder lookup leaves the local proxy alone")
        let afterOriginOffVPN = try await proxyConnectionsAfterOriginLookup(of: "off.origin.example")
        XCTAssertEqual(afterOriginOffVPN, afterOriginOnVPN, "off the VPN an origin lookup leaves the local proxy alone")
    }

    private final class CountingAuditSink: ConnectionAuditSink {
        private let records = NIOLockedValueBox(0)
        var count: Int { records.withLockedValue { $0 } }
        func record(_ record: ConnectionAuditRecord) { records.withLockedValue { $0 += 1 } }
    }

    private final class CountReplies: ChannelInboundHandler, Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        let replies: NIOLockedValueBox<Int>

        init(replies: NIOLockedValueBox<Int>) { self.replies = replies }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            replies.withLockedValue { $0 += 1 }
        }
    }

    @RuntimeActor
    private func checkReconnect(hasUpstreams: Bool, reachable: Bool) async throws {
        let entered = expectation(description: "reconnect probe entered")
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let release = loop.makePromise(of: Void.self)
        let mode = NIOLockedValueBox(0)
        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = true
        config.localPACPort = 0
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.proxy.strictMode = true
        config.routing.pacRoutingEnabled = true
        config.pacURL = "http://pac.fixture.test/proxy.pac"
        config.upstreams = hasUpstreams ? [UpstreamProxy(name: "isolated", host: "127.0.0.1", port: 9, priority: 0)] : []
        let orchestrator = ProxyOrchestrator(config: config, pacEvaluator: StaticPAC(), connectivityProbe: { upstreams in
            let phase = mode.withLockedValue { value in
                let phase = value
                if value == 2 { value = 3 }
                return phase
            }
            if phase == 2 {
                entered.fulfill()
                do { try await release.futureResult.get() }
                catch { XCTFail("probe gate failed: \(error)") }
            }
            return UpstreamProbeSummary(results: upstreams.map {
                ProbeResult(proxy: $0, latencyMS: 0, reachable: phase >= 2 ? reachable : phase != 1)
            })
        })
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running)
        mode.withLockedValue { $0 = 1 }
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        var invalidatedBeforePublish: Bool?
        var dnsResetBeforePublish: Bool?
        orchestrator.onSnapshotChange = { [weak orchestrator] snapshot in
            guard let orchestrator else { return }
            if hasUpstreams, snapshot.vpnState == .connected, snapshot.directModeCause == .none,
               invalidatedBeforePublish == nil {
                invalidatedBeforePublish = orchestrator.eventLog.events.last {
                    $0.event == "pac.routes_invalidated"
                }?.detail?.contains("reason=vpn_connected") == true
                dnsResetBeforePublish = orchestrator.eventLog.events.last {
                    $0.event == "dns.transports_reset"
                }?.detail?.contains("source=vpn_reconnected") == true
            }
        }
        mode.withLockedValue { $0 = 2 }
        let reconnect = Task { await orchestrator.handleVPNStateChange(.connected) }
        await fulfillment(of: [entered], timeout: 3)
        let pendingCause = orchestrator.snapshot.directModeCause
        let reconnectEvent = orchestrator.eventLog.events.last { $0.event == "vpn.reconnecting" }
        var script = ""
        if let localPAC = orchestrator.snapshot.bindings.localPACURL, let url = URL(string: localPAC) {
            do {
                let (data, _) = try await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 3))
                script = String(decoding: data, as: UTF8.self)
            } catch { XCTFail("local PAC fetch failed: \(error)") }
        } else { XCTFail("local PAC did not bind") }
        release.succeed(())
        await reconnect.value
        let finalCause = orchestrator.snapshot.directModeCause
        await orchestrator.stopDNS()
        await orchestrator.stopProxy()
        XCTAssertEqual(pendingCause, hasUpstreams ? .none : .noUpstreamsConfigured)
        XCTAssertEqual(finalCause, hasUpstreams ? (reachable ? .none : .upstreamsUnreachable) : .noUpstreamsConfigured)
        XCTAssertEqual(script.contains("function FindProxyForURL(url, host) {\n  return \"DIRECT\";\n}"), !hasUpstreams,
                       "served PAC must follow configuration regardless of pending probes")
        XCTAssertNotNil(reconnectEvent)
        if hasUpstreams {
            XCTAssertEqual(invalidatedBeforePublish, true, "old PAC routes must be invalidated before the new routing cause is visible")
            XCTAssertEqual(dnsResetBeforePublish, true, "old DNS transports must be reset before upstream routing is visible")
        }
    }

    private struct StaticPAC: PacEvaluator {
        func fetchPAC(from urlString: String) async throws -> String { "function FindProxyForURL(url, host) { return 'DIRECT'; }" }
        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating { Script() }
        func routeChain(for entries: [String]) -> PACChain { PACChain(routes: [.direct]) }
        private struct Script: PacScriptEvaluating {
            func resolveProxyChain(for url: URL) throws -> [String] { ["DIRECT"] }
        }
    }
}
