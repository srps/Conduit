// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// `pm-sim dns-doh-upstream-407` (decision 0045).
///
/// The real runtime: `ProxyOrchestrator` with its client listener, DNS
/// forwarder, the upstream route's pool and authenticator. The only upstream demands
/// authentication (`FakeUpstreamProxy`), and Conduit answers it. The DoH
/// provider is `192.0.2.10` (TEST-NET-1), which nothing answers directly, and
/// a no-proxy entry sends it DIRECT at the client listener: the network of a
/// full-tunnel VPN that drops direct traffic to a public resolver.
///
/// | # | condition                                   | expected                                              |
/// |---|---------------------------------------------|-------------------------------------------------------|
/// | A | a public name                               | answered                                              |
/// | B | the upstream                                | tunnelled the lookup after Conduit answered its 407   |
/// | C | the route                                   | reported `dns.doh_upstream_route_used` for the provider |
/// | D | every `URLSession`                          | met no proxy challenge (`auth.proxy_challenge_refused` absent) |
///
/// No leg puts a 407 in front of a `URLSession`. If the challenge guard ever
/// regressed, that would open the macOS proxy-password dialog on the machine
/// running `pm-sim all`; `ProxyChallengeRefusalTests` covers the guard behind
/// a check that sends nothing.
enum DoHProxyAuthScenarios {
    private static let providerHost = "192.0.2.10"
    private static let publicIP = "198.51.100.30"

    @RuntimeActor
    static func resolvesThroughAnAuthenticatingUpstream(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsDoHUpstream407"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton

        let origin = ScriptedDoHOrigin(group: group, ip: publicIP)
        ScenarioCleanup.register { await origin.stop() }
        try await origin.start()
        let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: origin.port, requireAuth: true)
        ScenarioCleanup.register { await upstream.stop() }
        try await upstream.start()
        notes.append("upstream 127.0.0.1:\(upstream.port) answers 407 Negotiate, then tunnels to the DoH origin 127.0.0.1:\(origin.port)")

        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = []
        config.dohProviders = ["http://\(providerHost)/dns-query"]
        config.noProxyHosts = [providerHost]
        config.upstreams = [UpstreamProxy(name: "corp", host: "127.0.0.1", port: upstream.port, priority: 0)]
        let everyUpstreamReachable: @Sendable ([UpstreamProxy]) async -> UpstreamProbeSummary = { targets in
            UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
        }
        let orchestrator = ProxyOrchestrator(
            config: config, logger: RecordingLogSink(minLevel: verbose ? .debug : .info),
            authenticatorProvider: { _ in MockAuthenticator() }, connectivityProbe: everyUpstreamReachable
        )
        ScenarioCleanup.register {
            await orchestrator.stopDNS()
            await orchestrator.stopProxy()
        }
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        let dnsPort = orchestrator.snapshot.bindings.dnsPort ?? 0
        notes.append("listener=\(orchestrator.snapshot.bindings.proxyPort ?? 0) dns=\(dnsPort) noProxy=\(providerHost)")

        let query = DNSWireFormat.buildQuery(domain: "first-lookup.example", txID: 0x4070, qtype: 1)
        let answer = try await DNSProbe.overUDP(query: query, port: dnsPort, timeout: 12)
        let answeredIP = answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip }
        let passA = answeredIP == publicIP
        notes.append("A answer=\(answeredIP ?? "none")")

        let passB = upstream.connectCount > 0 && origin.requests(naming: "first-lookup") > 0
        notes.append("B upstreamTunnels=\(upstream.connectCount) originRequests=\(origin.requests(naming: "first-lookup"))")

        let events = orchestrator.eventLog.events
        let used = events.filter { $0.event == "dns.doh_upstream_route_used" }.map { $0.detail ?? "" }
        let passC = used.contains { $0.hasPrefix("target=\(providerHost):80 upstream=127.0.0.1:\(upstream.port) ") }
        notes.append("C used=\(used)")

        let refusals = events.filter { $0.event == "auth.proxy_challenge_refused" }
        let passD = refusals.isEmpty
        notes.append("D refusals=\(refusals.count)")

        let checks = [passA, passB, passC, passD]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — with the rules saying DIRECT and direct a black hole, DoH resolves through the upstream Conduit authenticated to"
            : "FAIL — see per-case lines above")
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: 1,
            clientsWithFirstByte: passA ? 1 : 0,
            clientsClosedEarly: passA ? 0 : 1,
            totalBytes: answer?.count ?? 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a public name is answered though the rules say DIRECT and direct is a black hole", passA),
                .init("the upstream tunnels the lookup after Conduit answers its 407", passB),
                .init("the upstream route reports the lookup", passC),
                .init("no URLSession met a proxy challenge", passD),
            ],
            notes: notes
        )
    }

    /// `pm-sim dns-doh-upstream-refused` (decision 0045).
    ///
    /// The real runtime again, with two upstreams that answer 403 to every
    /// CONNECT: a corporate proxy that blocks DoH by policy. Direct is a black
    /// hole, so every lookup fails. What must not happen is the refusals
    /// reaching a circuit breaker: the route dials through a pool of its own,
    /// and that pool does not count an answered 4xx.
    ///
    /// | # | condition                         | expected                                                    |
    /// |---|-----------------------------------|-------------------------------------------------------------|
    /// | A | three public names                | none answered                                               |
    /// | B | each upstream                     | refused at least `circuitFailureThreshold` CONNECTs         |
    /// | C | the route                         | reported `dns.doh_upstream_route_failed` naming HTTP 403    |
    /// | D | every pool                        | opened no breaker (`upstream.circuit_opened` absent)        |
    /// | E | every `URLSession`                | met no proxy challenge                                      |
    @RuntimeActor
    static func aRefusingUpstreamOpensNoBreaker(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsDoHUpstreamRefused"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton

        var config = ProxyConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = []
        config.dohProviders = ["http://\(providerHost)/dns-query"]
        config.noProxyHosts = [providerHost]
        // A breaker opens on two back-to-back failures, so a counted refusal would show.
        config.circuitBreakerWindowSeconds = 0
        config.circuitFailureThreshold = 2
        var upstreams: [FakeUpstreamProxy] = []
        for (index, label) in ["primary", "secondary"].enumerated() {
            let upstream = FakeUpstreamProxy(group: group, originHost: "127.0.0.1", originPort: 9, requireAuth: false)
            ScenarioCleanup.register { await upstream.stop() }
            try await upstream.start()
            upstream.connectRefusalStatus = 403
            upstreams.append(upstream)
            config.upstreams.append(UpstreamProxy(name: label, host: "127.0.0.1", port: upstream.port, priority: index))
        }
        notes.append("upstreams \(upstreams.map { "127.0.0.1:\($0.port)" }) answer 403 to every CONNECT")
        let everyUpstreamReachable: @Sendable ([UpstreamProxy]) async -> UpstreamProbeSummary = { targets in
            UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: true) })
        }
        let orchestrator = ProxyOrchestrator(
            config: config, logger: RecordingLogSink(minLevel: verbose ? .debug : .info),
            authenticatorProvider: { _ in MockAuthenticator() }, connectivityProbe: everyUpstreamReachable
        )
        ScenarioCleanup.register {
            await orchestrator.stopDNS()
            await orchestrator.stopProxy()
        }
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        let dnsPort = orchestrator.snapshot.bindings.dnsPort ?? 0

        let answers = try await withThrowingTaskGroup(of: String?.self) { lookups -> [String?] in
            for index in 0..<3 {
                lookups.addTask {
                    let query = DNSWireFormat.buildQuery(domain: "refused-\(index).example", txID: UInt16(0x4030 + index), qtype: 1)
                    let answer = try await DNSProbe.overUDP(query: query, port: dnsPort, timeout: 12)
                    return answer.flatMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip }
                }
            }
            var collected: [String?] = []
            for try await answer in lookups { collected.append(answer) }
            return collected
        }
        let passA = answers.count == 3 && answers.allSatisfy { $0 == nil }
        notes.append("A answers=\(answers.map { $0 ?? "none" })")

        let attempts = upstreams.map(\.connectAttemptCount)
        let passB = attempts.allSatisfy { $0 >= config.circuitFailureThreshold }
        notes.append("B connectAttempts=\(attempts) threshold=\(config.circuitFailureThreshold)")

        let events = orchestrator.eventLog.events
        let failed = events.filter { $0.event == "dns.doh_upstream_route_failed" }.map { $0.detail ?? "" }
        let passC = failed.contains { $0.hasPrefix("target=\(providerHost):80 ") && $0.contains("HTTP 403") }
        notes.append("C failed=\(failed)")

        let opened = events.filter { $0.event == "upstream.circuit_opened" }.map { $0.detail ?? "" }
        let passD = opened.isEmpty
        notes.append("D opened=\(opened)")

        let refusals = events.filter { $0.event == "auth.proxy_challenge_refused" }
        let passE = refusals.isEmpty
        notes.append("E refusals=\(refusals.count)")

        let checks = [passA, passB, passC, passD, passE]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — upstreams that refuse DoH fail the lookups and open no circuit breaker"
            : "FAIL — see per-case lines above")
        return ScenarioResult(
            name: name,
            clientCount: 3,
            clientsOpened: 3,
            clientsWithFirstByte: 0,
            clientsClosedEarly: 0,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("no lookup is answered while every upstream refuses the provider", passA),
                .init("each upstream refused enough CONNECTs to open a breaker that counted them", passB),
                .init("the upstream route reports the refusal", passC),
                .init("no circuit breaker opened in any pool", passD),
                .init("no URLSession met a proxy challenge", passE),
            ],
            notes: notes
        )
    }
}

/// A plain-HTTP DoH provider: answers the first request on each connection
/// with one A record as `dns-json`, and keeps the request heads (at most 256).
final class ScriptedDoHOrigin: @unchecked Sendable {
    private let group: EventLoopGroup
    private let ip: String
    private let headsBox = NIOLockedValueBox<[String]>([])
    private var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }
    func requests(naming label: String) -> Int { headsBox.withLockedValue { $0 }.filter { $0.contains(label) }.count }

    init(group: EventLoopGroup, ip: String) {
        self.group = group
        self.ip = ip
    }

    func start() async throws {
        let headsBox = headsBox
        let ip = ip
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ScriptedDoHOriginHandler(ip: ip, heads: headsBox))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async {
        do {
            try await channel?.close().get()
        } catch ChannelError.alreadyClosed {
        } catch {
            FileHandle.standardError.write(Data("ScriptedDoHOrigin close failed: \(error)\n".utf8))
        }
        channel = nil
    }
}

private final class ScriptedDoHOriginHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let ip: String
    private let heads: NIOLockedValueBox<[String]>
    private var responded = false

    init(ip: String, heads: NIOLockedValueBox<[String]>) {
        self.ip = ip
        self.heads = heads
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        responded = true
        var request = unwrapInboundIn(data)
        let head = String(decoding: request.readBytes(length: request.readableBytes) ?? [], as: UTF8.self)
        heads.withLockedValue { if $0.count < 256 { $0.append(head) } }
        let body = #"{"Status":0,"Answer":[{"type":1,"TTL":60,"data":"\#(ip)"}]}"#
        let response = "HTTP/1.1 200 OK\r\nContent-Type: application/dns-json\r\n" +
            "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        let channel = context.channel
        var buffer = channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}
