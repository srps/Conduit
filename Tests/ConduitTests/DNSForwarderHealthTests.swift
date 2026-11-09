// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The forwarder across network changes (#292, #296): an unsatisfied path
/// answers at once, a transports reset cancels the lookups in flight, the
/// returned path answers, and no entry means no internal attempt. Every
/// server is a loopback fake; nothing leaves the machine.
final class DNSForwarderHealthTests: XCTestCase {
    private var ownedForwarder: LocalDNSForwarder?
    private var ownedChannels: [Channel] = []
    private var ownedProviders: [AnsweringDoHProvider] = []
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])
    private let group = MultiThreadedEventLoopGroup.singleton

    override func tearDown() async throws {
        if let forwarder = ownedForwarder {
            ownedForwarder = nil
            await forwarder.stop()
        }
        for channel in ownedChannels { _ = try? await channel.close().get() }
        ownedChannels = []
        for provider in ownedProviders { _ = try? await provider.channel.close().get() }
        ownedProviders = []
        try await super.tearDown()
    }

    // MARK: - #292: an unsatisfied path

    @MainActor
    func testUnsatisfiedPathAnswersServfailAtOnceWithoutAnAttempt() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["127.0.0.1"])],
            internalPort: internalServer.port, dohPort: doh.port, internalTimeout: .seconds(5)
        )
        ownedForwarder?.updateNetworkPath(satisfied: false)

        var queries = (0..<16).map { DNSWireFormat.buildQuery(domain: "public-\($0).example", txID: 0x7000 + UInt16($0)) }
        queries.append(DNSWireFormat.buildQuery(domain: "intranet.corp.example", txID: 0x70FF))
        let replies = try await askAll(queries, port: port)

        XCTAssertEqual(replies.count, queries.count, "every refused lookup is answered")
        XCTAssertEqual(Set(replies.map(DNSWireFormat.extractRCode)), [2], "SERVFAIL, nothing else")
        XCTAssertEqual(internalServer.queryCount, 0, "no internal attempt while the path is down")
        XCTAssertEqual(doh.requestCount(), 0, "no DoH attempt while the path is down")
        XCTAssertEqual(ownedForwarder?.inFlightQueryCount, 0, "no slot is held")
        let refused = events(named: "dns.unsatisfied_path_servfail")
        XCTAssertEqual(refused.count, 1, "the burst reports once inside the window")
        XCTAssertEqual(refused.first?.kind, .routing)
        XCTAssertEqual(refused.first?.detail?.hasSuffix(" suppressed=0"), true)
    }

    @MainActor
    func testUnsatisfiedPathStillAnswersFromInterceptAndCache() async throws {
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [], internalPort: 53, dohPort: doh.port, internalTimeout: .seconds(5),
            interceptRules: [DNSInterceptRule(pattern: "*.intercept.example", interceptIP: "127.44.3.9", enabled: true)]
        )
        let cached = DNSWireFormat.buildQuery(domain: "news.example", txID: 0x7100)
        let warm = try await ask(cached, port: port)
        XCTAssertEqual(warm.map(DNSWireFormat.extractRCode), 0, "warm the cache on a satisfied path")
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 1)
        let providerRequests = doh.requestCount()

        ownedForwarder?.updateNetworkPath(satisfied: false)

        let fromCache = try await ask(cached, port: port)
        XCTAssertEqual(fromCache.map(DNSWireFormat.extractRCode), 0, "a fresh cache entry still answers")
        XCTAssertEqual(fromCache.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        let intercepted = try await ask(DNSWireFormat.buildQuery(domain: "app.intercept.example", txID: 0x7101), port: port)
        XCTAssertEqual(intercepted.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "127.44.3.9", "an intercept rule still answers")
        XCTAssertEqual(doh.requestCount(), providerRequests, "neither asked a provider")
        XCTAssertEqual(ownedForwarder?.metricCounts?.cacheHits, 1)
    }

    @MainActor
    func testTransportsResetCancelsLookupsInFlightAndFreesTheirSlots() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["127.0.0.1"])],
            internalPort: internalServer.port, dohPort: doh.port, internalTimeout: .seconds(20)
        )
        let forwarder = try XCTUnwrap(ownedForwarder)
        let queries = (0..<8).map { DNSWireFormat.buildQuery(domain: "host-\($0).corp.example", txID: 0x7200 + UInt16($0)) }
        let collector = try await client(sending: queries, to: port)

        try await settle(until: { forwarder.inFlightQueryCount == queries.count }, "every lookup is waiting on the silent server")
        XCTAssertEqual(internalServer.queryCount, queries.count)

        forwarder.resetUpstreamTransports(reason: "network_change")

        try await settle(until: { collector.replies().count == queries.count }, "every cancelled lookup answers")
        XCTAssertEqual(Set(collector.replies().map(DNSWireFormat.extractRCode)), [2], "a cancelled lookup answers SERVFAIL")
        try await settle(until: { forwarder.inFlightQueryCount == 0 }, "every slot is released")
        XCTAssertEqual(doh.requestCount(), 0, "a cancelled lookup starts no fallback")
        XCTAssertEqual(events(named: "dns.split_dns_doh_fallback").count, 0)
    }

    @MainActor
    func testFreshLookupAfterThePathReturnsIsAnswered() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["127.0.0.1"])],
            internalPort: internalServer.port, dohPort: doh.port, internalTimeout: .milliseconds(50)
        )
        let forwarder = try XCTUnwrap(ownedForwarder)
        forwarder.updateNetworkPath(satisfied: false)
        let burst = (0..<48).map { DNSWireFormat.buildQuery(domain: "burst-\($0).example", txID: 0x7300 + UInt16($0)) }
        let refused = try await askAll(burst, port: port)
        XCTAssertEqual(refused.count, burst.count)
        XCTAssertEqual(Set(refused.map(DNSWireFormat.extractRCode)), [2])

        forwarder.updateNetworkPath(satisfied: true)
        forwarder.resetUpstreamTransports(reason: "network_change")

        let fresh = try await ask(DNSWireFormat.buildQuery(domain: "fresh.example", txID: 0x73FF), port: port)
        XCTAssertEqual(fresh.map(DNSWireFormat.extractRCode), 0, "the first lookup on the returned path is answered")
        XCTAssertEqual(fresh.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        XCTAssertEqual(forwarder.inFlightQueryCount, 0)
    }

    // MARK: - #296: no enabled entry

    @MainActor
    func testNoEnabledSplitDNSEntrySkipsTheInternalAttempt() async throws {
        let internalServer = try await ScriptedInternalServer.start(group: group, silentFor: .max, answering: "192.0.2.80")
        let doh = try await provider(ip: "198.51.100.7")
        // The disabled entry's server is on the internal port, so an attempt
        // on any address the forwarder made up would reach it too.
        let port = try await startForwarder(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["127.0.0.1"], enabled: false)],
            internalPort: internalServer.port, dohPort: doh.port, internalTimeout: .seconds(2)
        )
        let reply = try await ask(DNSWireFormat.buildQuery(domain: "public.example", txID: 0x7400), port: port)

        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 0)
        XCTAssertEqual(reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, "198.51.100.7")
        XCTAssertEqual(internalServer.queryCount, 0, "no UDP attempt to any internal address")
        XCTAssertEqual(ownedForwarder?.metricCounts?.dohFallbacks, 1)
    }

    // MARK: - Fixtures

    /// Starts the owned forwarder: `entries` as the split-DNS table, their
    /// servers asked on loopback port `internalPort`, one cleartext DoH
    /// provider on `dohPort`, and both internal timeouts set to
    /// `internalTimeout`. Returns the UDP port.
    @MainActor
    private func startForwarder(
        entries: [DomainDNSEntry],
        internalPort: Int,
        dohPort: Int,
        internalTimeout: TimeAmount,
        interceptRules: [DNSInterceptRule] = []
    ) async throws -> Int {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = entries
        config.dnsInterceptRules = interceptRules
        config.dohProviders = ["http://127.0.0.1:\(dohPort)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        let frozen = config
        var tuning = DNSForwarderTuning()
        tuning.internalServerPort = internalPort
        tuning.internalDomainTimeout = internalTimeout
        tuning.internalAttemptTimeout = internalTimeout
        let events = events
        let forwarder = LocalDNSForwarder(
            group: group,
            logger: RecordingLogSink(minLevel: .debug),
            configProvider: { frozen },
            tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        ownedForwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return try XCTUnwrap(forwarder.listeningPort)
    }

    @MainActor
    private func provider(ip: String) async throws -> AnsweringDoHProvider {
        let provider = try await AnsweringDoHProvider.start(group: group, ip: ip)
        ownedProviders.append(provider)
        return provider
    }

    @MainActor
    private func events(named name: String) -> [RuntimeEvent] {
        events.withLockedValue { $0 }.filter { $0.event == name }
    }

    /// Opens one client socket, sends every query from it and returns the
    /// collector of its replies. The channel is closed in `tearDown`.
    @MainActor
    private func client(sending queries: [[UInt8]], to port: Int) async throws -> BurstReplyCollector {
        let collector = BurstReplyCollector()
        let client = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ownedChannels.append(client)
        let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
        for query in queries {
            var buf = client.allocator.buffer(capacity: query.count)
            buf.writeBytes(query)
            try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buf)).get()
        }
        return collector
    }

    /// Sends `queries` and returns the replies once all have arrived, or
    /// those that did within ten seconds.
    @MainActor
    private func askAll(_ queries: [[UInt8]], port: Int) async throws -> [[UInt8]] {
        let collector = try await client(sending: queries, to: port)
        for _ in 0..<1000 where collector.replies().count < queries.count {
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.replies()
    }

    @MainActor
    private func ask(_ query: [UInt8], port: Int) async throws -> [UInt8]? {
        try await askAll([query], port: port).first
    }

    /// Polls `condition` every 10 ms for up to ten seconds and fails the test
    /// with `what` if it never holds.
    @MainActor
    private func settle(until condition: @MainActor @escaping () -> Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<1000 where !condition() {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), what, file: file, line: line)
    }
}

/// A loopback internal DNS server that counts the queries it receives, stays
/// silent for the first `silentFor` of them and answers the rest with one A
/// record for `answering`.
private final class ScriptedInternalServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let silentFor: Int
    private let answering: String
    private let received = NIOLockedValueBox(0)
    private(set) var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }
    var queryCount: Int { received.withLockedValue { $0 } }

    private init(silentFor: Int, answering: String) {
        self.silentFor = silentFor
        self.answering = answering
    }

    static func start(group: EventLoopGroup, silentFor: Int, answering: String) async throws -> ScriptedInternalServer {
        let server = ScriptedInternalServer(silentFor: silentFor, answering: answering)
        server.channel = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(server) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let query = buffer.readBytes(length: buffer.readableBytes) ?? []
        let index = received.withLockedValue { count -> Int in
            count += 1
            return count
        }
        guard index > silentFor, let reply = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: answering) else { return }
        var out = context.channel.allocator.buffer(capacity: reply.count)
        out.writeBytes(reply)
        context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
    }
}

/// Captures the datagrams a test client receives, up to 256: enough for a
/// burst over the forwarder's 64 in-flight slots, bounded like the forwarder.
private final class BurstReplyCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let lock = NSLock()
    private var received: [[UInt8]] = []

    func replies() -> [[UInt8]] {
        lock.withLock { received }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data).data
        let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
        lock.withLock { if received.count < 256 { received.append(bytes) } }
    }
}
