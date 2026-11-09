// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// The forwarder across network changes (#292, #296, #290 part 1), driven
/// over UDP against loopback fakes: the internal servers are scripted
/// loopback sockets and the DoH provider a loopback fake, so nothing leaves
/// the machine. Every check is a count: datagrams a fake received, replies a
/// client got, slots the forwarder holds, events it emitted.
enum DNSHealthScenarios {
    /// RFC 5737 TEST-NET addresses: the configured internal servers (reached
    /// on loopback ports through the tuning seam) and the answers the fakes give.
    private static let serverA = "192.0.2.1"
    private static let serverB = "192.0.2.2"
    private static let internalIP = "192.0.2.80"
    private static let secondInternalIP = "192.0.2.81"
    private static let publicIP = "198.51.100.7"

    /// `pm-sim dns-unsatisfied-path` (#292).
    ///
    /// | # | condition                                              | expected                                                   |
    /// |---|--------------------------------------------------------|------------------------------------------------------------|
    /// | A | 40 lookups while the path is unsatisfied               | 40 SERVFAIL, the internal server saw none, no DoH request |
    /// | B | after A                                                | no slot held, one `dns.unsatisfied_path_servfail`          |
    /// | C | 8 split-DNS lookups waiting on a silent server, reset  | 8 SERVFAIL before the 20 s timeout, no slot held           |
    /// | D | the path returns, one fresh public lookup              | the DoH answer                                             |
    @RuntimeActor
    static func unsatisfiedPath(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsUnsatisfiedPath"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let silent = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [DomainDNSEntry(domain: "corp.example", servers: [serverA])],
            endpoints: [serverA: silent.port], internalDomainTimeout: .seconds(20), internalAttemptTimeout: .milliseconds(50)
        )
        let port = forwarder.listeningPort ?? 0
        func count(_ event: String) -> Int { events.withLockedValue { $0 }.filter { $0.event == event }.count }

        forwarder.updateNetworkPath(satisfied: false)
        var burst = (0..<39).map { DNSWireFormat.buildQuery(domain: "public-\($0).example", txID: 0x5A00 + UInt16($0)) }
        burst.append(DNSWireFormat.buildQuery(domain: "intranet.corp.example", txID: 0x5AFF))
        let refused = try await DNSBurstClient.ask(burst, port: port, group: group)
        let refusedRCodes = Set(refused.map(DNSWireFormat.extractRCode))
        notes.append("A replies=\(refused.count)/\(burst.count) rcodes=\(refusedRCodes.sorted()) internal=\(silent.queryCount) doh=\(provider.requests(naming: "example"))")
        let passA = refused.count == burst.count && refusedRCodes == [2] && silent.queryCount == 0 && provider.requests(naming: "example") == 0
        let inFlightAfterBurst = forwarder.inFlightQueryCount
        notes.append("B inFlight=\(inFlightAfterBurst) events=\(count("dns.unsatisfied_path_servfail"))")
        let passB = inFlightAfterBurst == 0 && count("dns.unsatisfied_path_servfail") == 1

        forwarder.updateNetworkPath(satisfied: true)
        let waiting = (0..<8).map { DNSWireFormat.buildQuery(domain: "host-\($0).corp.example", txID: 0x5B00 + UInt16($0)) }
        let client = try await DNSBurstClient.start(group: group, sending: waiting, to: port)
        try await settle { forwarder.inFlightQueryCount == waiting.count }
        let heldBeforeReset = forwarder.inFlightQueryCount
        forwarder.resetUpstreamTransports(reason: "network_change")
        try await settle { client.replies().count == waiting.count }
        try await settle { forwarder.inFlightQueryCount == 0 }
        let cancelledRCodes = Set(client.replies().map(DNSWireFormat.extractRCode))
        notes.append("C held=\(heldBeforeReset) replies=\(client.replies().count) rcodes=\(cancelledRCodes.sorted()) inFlight=\(forwarder.inFlightQueryCount) internal=\(silent.queryCount)")
        let passC = heldBeforeReset == waiting.count && client.replies().count == waiting.count && cancelledRCodes == [2]
            && forwarder.inFlightQueryCount == 0 && silent.queryCount == waiting.count

        let fresh = try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: "fresh.example", txID: 0x5C00), port: port, timeout: 12)
        let freshIP = fresh.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        notes.append("D fresh ip=\(freshIP ?? "none")")
        let passD = freshIP == publicIP

        let checks = [passA, passB, passC, passD]
        notes.append(checks.allSatisfy { $0 } ? "PASS — no path answers at once, a reset frees the slots, the returned path answers" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: burst.count + waiting.count + 1,
            answered: refused.count + client.replies().count + (fresh == nil ? 0 : 1),
            assertions: [
                .init("a burst while the path is unsatisfied gets SERVFAIL with no internal or DoH attempt", passA),
                .init("the burst holds no slot and reports one throttled event", passB),
                .init("a transports reset cancels the lookups in flight and frees their slots", passC),
                .init("a fresh lookup right after the path returns is answered", passD),
            ]
        )
    }

    /// `pm-sim dns-no-split-entries` (#296). With the only entry disabled,
    /// a public name is answered by DoH and the internal server, which also
    /// sits on the default internal port, receives nothing.
    @RuntimeActor
    static func noSplitEntries(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsNoSplitEntries"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let silent = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: internalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [DomainDNSEntry(domain: "corp.example", servers: [serverA], enabled: false)],
            endpoints: [serverA: silent.port], internalDomainTimeout: .seconds(2), internalAttemptTimeout: .seconds(2),
            defaultInternalPort: silent.port
        )
        let port = forwarder.listeningPort ?? 0

        let queries = (0..<4).map { DNSWireFormat.buildQuery(domain: "public-\($0).example", txID: 0x5D00 + UInt16($0)) }
        let replies = try await DNSBurstClient.ask(queries, port: port, group: group)
        let ips = Set(replies.compactMap { DNSWireFormat.firstIPv4Answer(in: $0)?.ip })
        notes.append("replies=\(replies.count)/\(queries.count) ips=\(ips.sorted()) internal=\(silent.queryCount)")
        let passA = replies.count == queries.count && ips == [publicIP]
        let passB = silent.queryCount == 0
        let checks = [passA, passB]
        notes.append(checks.allSatisfy { $0 } ? "PASS — no entry, no internal attempt" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: queries.count, answered: replies.count,
            assertions: [
                .init("with no enabled split-DNS entry a public name is answered by DoH", passA),
                .init("no UDP attempt reaches any internal address", passB),
            ]
        )
    }

    /// `pm-sim dns-internal-server-circuit` (#290 part 1). The internal
    /// timeout is 300 ms, so the three lookups of E finish while the one probe
    /// they share is still out.
    ///
    /// | # | condition                                                  | expected                                                       |
    /// |---|------------------------------------------------------------|----------------------------------------------------------------|
    /// | A | 3 split-DNS lookups, server silent                         | 3 DoH answers, server saw 3, one `..._circuit_opened`          |
    /// | B | the server now answers; one lookup                         | the DoH answer (skipped), the probe closes the circuit, saw 4 |
    /// | C | one lookup                                                 | the internal answer, saw 5                                     |
    /// | D | the server is silent again; 3 lookups                      | 3 DoH answers, saw 8; the reopening event is gated (still 1)   |
    /// | E | 3 lookups while open, then a transports reset, one lookup  | saw 9 (one probe) then 10 (the lookup asks), no `_closed`      |
    /// | F | entry with two servers, first silent                       | the second server's answer, each asked once, no fallback       |
    /// | G | entries `corp.example` and `eu.corp.example`               | `host.eu.corp.example` is answered by the eu entry's server     |
    @RuntimeActor
    static func internalServerCircuit(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsInternalServerCircuit"
        let start = Date()
        var notes: [String] = []
        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let flaky = try await ScriptedInternalServer.start(group: group, silentFor: 3, answering: internalIP)
        let second = try await ScriptedInternalServer.start(group: group, silentFor: 0, answering: secondInternalIP)
        let provider = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        ScenarioCleanup.register { await provider.stop() }
        try await provider.start()
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let forwarder = try await startForwarder(
            group: group, logger: logger, provider: provider, events: events,
            entries: [
                DomainDNSEntry(domain: "corp.example", servers: [serverA]),
                DomainDNSEntry(domain: "eu.corp.example", servers: [serverB]),
                DomainDNSEntry(domain: "two.example", servers: [serverA, serverB]),
            ],
            endpoints: [serverA: flaky.port, serverB: second.port],
            internalDomainTimeout: .milliseconds(300), internalAttemptTimeout: .milliseconds(300)
        )
        let port = forwarder.listeningPort ?? 0
        func count(_ event: String) -> Int { events.withLockedValue { $0 }.filter { $0.event == event }.count }
        func lookup(_ domain: String, _ id: UInt16) async throws -> String? {
            try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: domain, txID: id), port: port, timeout: 12)
                .flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        }
        func lookups(_ prefix: String, _ base: UInt16) async throws -> [String] {
            var ips: [String] = []
            for index in 0..<3 { ips.append(try await lookup("\(prefix)-\(index).corp.example", base + UInt16(index)) ?? "none") }
            return ips
        }

        let ipsA = try await lookups("wait", 0x5E00)
        notes.append("A ips=\(ipsA) server=\(flaky.queryCount) opened=\(count("dns.internal_server_circuit_opened"))")
        let passA = ipsA.allSatisfy { $0 == publicIP } && flaky.queryCount == 3 && count("dns.internal_server_circuit_opened") == 1

        let skipped = try await lookup("probe.corp.example", 0x5E10)
        try await settle { count("dns.internal_server_circuit_closed") == 1 }
        notes.append("B ip=\(skipped ?? "none") server=\(flaky.queryCount) closed=\(count("dns.internal_server_circuit_closed"))")
        let passB = skipped == publicIP && flaky.queryCount == 4 && count("dns.internal_server_circuit_closed") == 1

        let afterProbe = try await lookup("back.corp.example", 0x5E20)
        notes.append("C ip=\(afterProbe ?? "none") server=\(flaky.queryCount)")
        let passC = afterProbe == internalIP && flaky.queryCount == 5

        flaky.silentFor(.max)
        let ipsD = try await lookups("again", 0x5E30)
        notes.append("D ips=\(ipsD) server=\(flaky.queryCount) opened=\(count("dns.internal_server_circuit_opened"))")
        // The second opening inside the minute is held back by the per-server event gate; E shows the circuit is open.
        let passD = ipsD.allSatisfy { $0 == publicIP } && flaky.queryCount == 8 && count("dns.internal_server_circuit_opened") == 1

        let ipsE = try await lookups("skip", 0x5E40)
        let sawWhileOpen = flaky.queryCount
        forwarder.resetUpstreamTransports(reason: "vpn_connected")
        let afterReset = try await lookup("reset.corp.example", 0x5E4F)
        notes.append("E ips=\(ipsE) sawWhileOpen=\(sawWhileOpen) ip=\(afterReset ?? "none") server=\(flaky.queryCount) closed=\(count("dns.internal_server_circuit_closed"))")
        let passE = ipsE.allSatisfy { $0 == publicIP } && sawWhileOpen == 9 && afterReset == publicIP && flaky.queryCount == 10
            && count("dns.internal_server_circuit_closed") == 1

        let fallbackEventsBefore = count("dns.split_dns_doh_fallback")
        let twoIP = try await lookup("mail.two.example", 0x5E50)
        notes.append("F ip=\(twoIP ?? "none") first=\(flaky.queryCount) second=\(second.queryCount) fallbacks=\(count("dns.split_dns_doh_fallback") - fallbackEventsBefore)")
        let passF = twoIP == secondInternalIP && flaky.queryCount == 11 && second.queryCount == 1
            && count("dns.split_dns_doh_fallback") == fallbackEventsBefore

        let euIP = try await lookup("host.eu.corp.example", 0x5E60)
        notes.append("G ip=\(euIP ?? "none") first=\(flaky.queryCount) second=\(second.queryCount)")
        let passG = euIP == secondInternalIP && flaky.queryCount == 11 && second.queryCount == 2

        let checks = [passA, passB, passC, passD, passE, passF, passG]
        notes.append(checks.allSatisfy { $0 } ? "PASS — the circuit opens, skips, probes closed and resets; servers in order; longest suffix wins" : "FAIL — see per-case lines above")
        return result(
            name: name, start: start, notes: notes, clients: 14, answered: 14,
            assertions: [
                .init("three silences open the server's circuit, each lookup falling back", passA),
                .init("a lookup skips the open circuit and its probe's reply closes it", passB),
                .init("the next lookup asks the server again", passC),
                .init("three silences reopen the circuit, its event held by the per-server gate", passD),
                .init("lookups while open share one probe, and a transports reset closes the circuit without one", passE),
                .init("an entry's second server answers when the first is silent", passF),
                .init("the longest-suffix entry's server answers its names", passG),
            ]
        )
    }

    // MARK: - Fixtures

    @RuntimeActor
    private static func startForwarder(
        group: EventLoopGroup,
        logger: any LogSink,
        provider: FakeAnsweringDoHProvider,
        events: NIOLockedValueBox<[RuntimeEvent]>,
        entries: [DomainDNSEntry],
        endpoints: [String: Int],
        internalDomainTimeout: TimeAmount,
        internalAttemptTimeout: TimeAmount,
        defaultInternalPort: Int = 53
    ) async throws -> LocalDNSForwarder {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = entries
        config.dohProviders = ["http://127.0.0.1:\(provider.port)/dns-query"]
        config.upstreams = []
        let frozen = config
        var tuning = DNSForwarderTuning()
        tuning.internalServerPort = defaultInternalPort
        tuning.internalServerEndpoint = { server in ("127.0.0.1", endpoints[server] ?? defaultInternalPort) }
        tuning.internalDomainTimeout = internalDomainTimeout
        tuning.internalAttemptTimeout = internalAttemptTimeout
        let forwarder = LocalDNSForwarder(
            group: group, logger: logger, configProvider: { frozen }, tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        ScenarioCleanup.register { await forwarder.stop() }
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return forwarder
    }

    /// Polls `condition` every 10 ms for up to ten seconds; the caller's
    /// counts then say whether it held.
    @RuntimeActor
    private static func settle(_ condition: @RuntimeActor () -> Bool) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func result(
        name: String, start: Date, notes: [String], clients: Int, answered: Int, assertions: [ScenarioAssertion]
    ) -> ScenarioResult {
        ScenarioResult(
            name: name,
            clientCount: clients,
            clientsOpened: clients,
            clientsWithFirstByte: answered,
            clientsClosedEarly: clients - answered,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: assertions,
            notes: notes
        )
    }
}

/// A loopback internal DNS server that counts the queries it receives, stays
/// silent for the next `silentFor` of them and answers the rest with one A
/// record for `answering`.
private final class ScriptedInternalServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let answering: String
    private let state = NIOLockedValueBox((received: 0, silentUntil: 0))
    private var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }
    var queryCount: Int { state.withLockedValue { $0.received } }

    private init(answering: String) {
        self.answering = answering
    }

    @RuntimeActor
    static func start(group: EventLoopGroup, silentFor: Int, answering: String) async throws -> ScriptedInternalServer {
        let server = ScriptedInternalServer(answering: answering)
        server.silentFor(silentFor)
        server.channel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(server) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ScenarioCleanup.register { _ = try? await server.channel?.close().get() }
        return server
    }

    /// Stays silent for the next `count` queries.
    func silentFor(_ count: Int) {
        state.withLockedValue { $0.silentUntil = count == .max ? .max : $0.received + count }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let query = buffer.readBytes(length: buffer.readableBytes) ?? []
        let answers = state.withLockedValue { state -> Bool in
            state.received += 1
            return state.received > state.silentUntil
        }
        guard answers, let reply = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: answering) else { return }
        var out = context.channel.allocator.buffer(capacity: reply.count)
        out.writeBytes(reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
    }
}

/// One client socket that sends a burst of queries and collects up to 256
/// replies, so a scenario can count them.
private final class DNSBurstClient: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let received = NIOLockedValueBox<[[UInt8]]>([])

    func replies() -> [[UInt8]] { received.withLockedValue { $0 } }

    @RuntimeActor
    static func start(group: EventLoopGroup, sending queries: [[UInt8]], to port: Int) async throws -> DNSBurstClient {
        let client = DNSBurstClient()
        let channel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(client) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ScenarioCleanup.register { _ = try? await channel.close().get() }
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        for query in queries {
            var buffer = channel.allocator.buffer(capacity: query.count)
            buffer.writeBytes(query)
            try await channel.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buffer)).get()
        }
        return client
    }

    /// Sends `queries` and returns the replies that arrived within ten seconds.
    @RuntimeActor
    static func ask(_ queries: [[UInt8]], port: Int, group: EventLoopGroup) async throws -> [[UInt8]] {
        let client = try await start(group: group, sending: queries, to: port)
        for _ in 0..<1000 where client.replies().count < queries.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return client.replies()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        received.withLockedValue { if $0.count < 256 { $0.append(bytes) } }
    }
}
