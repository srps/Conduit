// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class DNSForwarderNetworkResolverTests: XCTestCase {
    private static let networkServer = "192.0.2.1"
    private static let publicIP = "198.51.100.7"
    private static let networkIP = "203.0.113.40"

    private var forwarder: LocalDNSForwarder?
    private var stops: [() async -> Void] = []
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])
    private let recoveries = NIOLockedValueBox<[DNSResolutionRecovery]>([])
    private let networkServers = NIOLockedValueBox<[String]>([networkServer])

    override func tearDown() async throws {
        await forwarder?.stop()
        forwarder = nil
        for stop in stops { await stop() }
        stops = []
        try await super.tearDown()
    }

    func testDoHAnsweringMeansTheNetworkServerIsNeverAsked() async throws {
        let network = try await networkDNS(answering: true)
        let doh = try await dohProvider(silent: false)
        let port = try await start(dohPort: doh.port, networkPort: network.port)

        let answer = try await SplitDNSProbe.resolve("www.example.com", port: port)

        XCTAssertEqual(answer, Self.publicIP)
        XCTAssertEqual(network.totalQueries, 0, "DoH answered, so the network's server is not asked")
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").count, 0)
        XCTAssertEqual(forwarder?.metricCounts?.networkResolverFallbacks, 0)
        XCTAssertEqual(recoveries.withLockedValue { $0 }, [], "the path answered from its first lookup")
    }

    func testDoHSilentWithNoTableServerAsksTheNetworkServerOnce() async throws {
        let network = try await networkDNS(answering: true)
        let doh = try await dohProvider(silent: true)
        let port = try await start(dohPort: doh.port, networkPort: network.port)

        let answer = try await SplitDNSProbe.resolve("www.example.com", port: port)

        XCTAssertEqual(answer, Self.networkIP, "the network's server answers what DoH did not")
        XCTAssertEqual(network.queryCount("www.example.com"), 1, "one attempt")
        XCTAssertGreaterThan(doh.requestCount(), 0, "DoH was asked first")
        XCTAssertEqual(
            events(named: "dns.network_resolver_fallback").compactMap(\.detail),
            ["name=www.example.com servers=1 outcome=answered suppressed=0"],
            "the event names a count, never the address"
        )
        XCTAssertEqual(forwarder?.metricCounts?.networkResolverFallbacks, 1)
        XCTAssertEqual(
            recoveries.withLockedValue { $0 }, [DNSResolutionRecovery(unansweredBefore: 0, viaNetworkResolver: true)],
            "the first answer only the network server gave is a recovery"
        )

        let cached = try await SplitDNSProbe.resolve("www.example.com", port: port, txID: 0x5D01)
        XCTAssertEqual(cached, Self.networkIP)
        XCTAssertEqual(network.queryCount("www.example.com"), 1, "a public answer is cached like any other")
        XCTAssertEqual(recoveries.withLockedValue { $0 }.count, 1, "once per path")
    }

    func testAnEntryThatNamesNoServerFallsBackToTheNetworkServer() async throws {
        let network = try await networkDNS(answering: true)
        let doh = try await dohProvider(silent: true)
        let port = try await start(
            dohPort: doh.port, networkPort: network.port,
            entries: [DomainDNSEntry(domain: "corp.example", servers: [])]
        )

        let answer = try await SplitDNSProbe.resolve("pac.corp.example", port: port)
        XCTAssertEqual(answer, Self.networkIP)
        XCTAssertEqual(network.queryCount("pac.corp.example"), 1)
    }

    func testATableServerMeansTheNetworkServerIsNeverAsked() async throws {
        let network = try await networkDNS(answering: true)
        let internalServer = try await silentServer()
        let doh = try await dohProvider(silent: true)
        let port = try await start(
            dohPort: doh.port, networkPort: network.port, internalPort: internalServer.port,
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"])]
        )

        _ = try await SplitDNSProbe.resolve("www.example.com", port: port)
        _ = try await SplitDNSProbe.resolve("host.corp.example", port: port, txID: 0x5D02)

        XCTAssertGreaterThan(internalServer.received, 0, "the entry's server was asked")
        XCTAssertEqual(network.totalQueries, 0, "the table had a server, so the network's is never asked")
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").count, 0)
    }

    func testPushedServersInUseMeanTheNetworkServerIsNeverAsked() async throws {
        let network = try await networkDNS(answering: true)
        let tunnel = try await silentServer()
        let doh = try await dohProvider(silent: true)
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "intra.example", servers: [])],
            detected: [SplitDNSRule(domain: "corp.example", servers: ["10.0.0.53"], origins: [.detected(interface: "utun4")])]
        )
        let port = try await start(
            dohPort: doh.port, networkPort: network.port, internalPort: tunnel.port, table: table
        )

        let replies = [
            try await SplitDNSProbe.resolve("portal.intra.example", port: port),
            try await SplitDNSProbe.resolve("www.example.com", port: port, txID: 0x5D03),
        ]

        XCTAssertEqual(replies, [nil, nil])
        XCTAssertEqual(network.totalQueries, 0, "never while a VPN's pushed servers are in use")
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").count, 0)
    }

    func testPushedServersThatComeIntoUseWhileDoHIsHeldMeanTheNetworkServerIsNotAsked() async throws {
        let network = try await networkDNS(answering: true)
        let tunnel = try await silentServer()
        let doh = try await dohProvider(silent: true)
        let live = NIOLockedValueBox(SplitDNSTable(manual: [], detected: []))
        let port = try await start(
            dohPort: doh.port, networkPort: network.port, internalPort: tunnel.port,
            splitDNS: { live.withLockedValue { $0 } }
        )
        let pushed = SplitDNSTable(
            manual: [],
            detected: [SplitDNSRule(domain: "corp.example", servers: ["192.0.2.80"], origins: [.detected(interface: "utun4")])]
        )
        let switched = Task {
            for _ in 0..<500 where doh.requestCount() == 0 {
                try await Task.sleep(for: .milliseconds(5))
            }
            live.withLockedValue { $0 = pushed }
        }

        let reply = try await rawReply("www.example.com", port: port)
        try await switched.value

        XCTAssertGreaterThan(doh.requestCount(), 0)
        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 2, "SERVFAIL")
        XCTAssertEqual(network.totalQueries, 0, "the table in use at fallback time has pushed servers")
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").count, 0)
    }

    func testBothSilentAnswerServfailInsideTheRelayWindow() async throws {
        let network = try await silentServer()
        let doh = try await dohProvider(silent: true)
        let port = try await start(
            dohPort: doh.port, networkPort: network.port,
            dohRequestTimeout: DoHSessionFactory.requestTimeout, networkResolverTimeout: DNSForwarderTuning().networkResolverTimeout
        )

        let asked = ContinuousClock.now
        let reply = try await rawReply("www.example.com", port: port)
        let elapsed = ContinuousClock.now - asked

        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 2, "SERVFAIL")
        XCTAssertLessThan(elapsed, .seconds(UDPRelay.staleTimeoutSeconds), "inside the relay's pending window")
        XCTAssertEqual(network.received, 1)
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").compactMap(\.detail), [
            "name=www.example.com servers=1 outcome=silent suppressed=0",
        ])
    }

    func testNoAttemptIsMadeThatWouldNotFitTheRelayWindow() async throws {
        let network = try await networkDNS(answering: true)
        let doh = try await dohProvider(silent: true)
        let port = try await start(
            dohPort: doh.port, networkPort: network.port, networkResolverTimeout: .seconds(1), lookupWindow: .milliseconds(500)
        )

        let reply = try await rawReply("www.example.com", port: port)

        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 2)
        XCTAssertEqual(network.totalQueries, 0, "an attempt that cannot finish inside the window is not made")
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").compactMap(\.detail), [
            "name=www.example.com servers=1 outcome=not_asked suppressed=0",
        ])
        XCTAssertEqual(forwarder?.metricCounts?.networkResolverFallbacks, 0)
    }

    func testASilentNetworkServerOpensItsCircuitUnderItsLabel() async throws {
        let network = try await silentServer()
        let doh = try await dohProvider(silent: true)
        let port = try await start(dohPort: doh.port, networkPort: network.port)

        for index in 0..<InternalServerHealthThreshold.silences {
            _ = try await rawReply("name-\(index).example", port: port, txID: 0x5E00 + UInt16(index))
        }

        let opened = events(named: "dns.internal_server_circuit_opened").compactMap(\.detail)
        XCTAssertEqual(opened, ["server=network-resolver silences=3 suppressed=0"], "no address in the event")
        let fallbacks = events(named: "dns.network_resolver_fallback").compactMap(\.detail)
        XCTAssertEqual(fallbacks, ["name=name-0.example servers=1 outcome=silent suppressed=0"], "the rest are held back")
    }

    func testNoNetworkServerMeansSERVFAILAndTheFirstAnswerAfterReportsTheRecovery() async throws {
        let network = try await networkDNS(answering: true)
        let doh = try await dohProvider(silent: true)
        networkServers.withLockedValue { $0 = [] }
        let port = try await start(dohPort: doh.port, networkPort: network.port)

        let unanswered = try await rawReply("first.example", port: port)
        XCTAssertEqual(unanswered.map(DNSWireFormat.extractRCode), 2)
        XCTAssertEqual(events(named: "dns.network_resolver_fallback").count, 0, "nothing to ask, nothing to report")
        XCTAssertEqual(recoveries.withLockedValue { $0 }, [])

        networkServers.withLockedValue { $0 = [Self.networkServer] }
        let second = try await SplitDNSProbe.resolve("second.example", port: port, txID: 0x5D04)
        XCTAssertEqual(second, Self.networkIP)
        XCTAssertEqual(recoveries.withLockedValue { $0 }, [DNSResolutionRecovery(unansweredBefore: 1, viaNetworkResolver: true)])

        forwarder?.resetUpstreamTransports(reason: "network_change")
        let third = try await SplitDNSProbe.resolve("third.example", port: port, txID: 0x5D05)
        XCTAssertEqual(third, Self.networkIP)
        XCTAssertEqual(recoveries.withLockedValue { $0 }.count, 2, "a reset begins a new path, watched again")
    }

    private enum InternalServerHealthThreshold {
        static let silences = 3
    }

    private func start(
        dohPort: Int,
        networkPort: Int,
        internalPort: Int = 9,
        entries: [DomainDNSEntry] = [],
        table: SplitDNSTable? = nil,
        splitDNS: (@Sendable () -> SplitDNSTable)? = nil,
        dohRequestTimeout: TimeInterval = 0.3,
        networkResolverTimeout: TimeAmount = .milliseconds(300),
        lookupWindow: TimeAmount? = nil
    ) async throws -> Int {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsEntries = entries
        config.dohProviders = ["http://127.0.0.1:\(dohPort)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        let frozen = config
        var tuning = DNSForwarderTuning()
        let network = Self.networkServer
        tuning.internalServerEndpoint = { server in ("127.0.0.1", server == network ? networkPort : internalPort) }
        tuning.internalAttemptTimeout = .milliseconds(200)
        tuning.internalDomainTimeout = .milliseconds(200)
        tuning.dohRequestTimeout = dohRequestTimeout
        tuning.networkResolverTimeout = networkResolverTimeout
        if let lookupWindow { tuning.lookupWindow = lookupWindow }
        let events = events
        let recoveries = recoveries
        let servers = networkServers
        let fixedTable: (@Sendable () -> SplitDNSTable)? = splitDNS ?? table.map { fixed in { @Sendable in fixed } }
        let forwarder = LocalDNSForwarder(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: RecordingLogSink(minLevel: .debug),
            configProvider: { frozen },
            splitDNSProvider: fixedTable,
            networkResolverProvider: { servers.withLockedValue { $0 } },
            onResolutionRecovered: { recovery in recoveries.withLockedValue { $0.append(recovery) } },
            tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        self.forwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return try XCTUnwrap(forwarder.listeningPort)
    }

    private func networkDNS(answering: Bool) async throws -> FakeSplitDNSServer {
        let server = try await FakeSplitDNSServer.start(domain: "", ip: Self.networkIP, matchingEverything: true)
        stops.append { await server.stop() }
        return server
    }

    private func silentServer() async throws -> SilentUDPServer {
        let server = try await SilentUDPServer.start()
        stops.append { await server.channel.closeForTest() }
        return server
    }

    private func dohProvider(silent: Bool) async throws -> AnsweringDoHProvider {
        let provider = try await AnsweringDoHProvider.start(group: MultiThreadedEventLoopGroup.singleton, ip: Self.publicIP, silent: silent)
        stops.append { await provider.channel.closeForTest() }
        return provider
    }

    private func events(named name: String) -> [RuntimeEvent] {
        events.withLockedValue { $0 }.filter { $0.event == name }
    }

    private func rawReply(_ name: String, port: Int, txID: UInt16 = 0x5D10) async throws -> [UInt8]? {
        let collector = UDPReplyCollector()
        let client = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(collector) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { client.close(promise: nil) }
        let query = DNSWireFormat.buildQuery(domain: name, txID: txID)
        var buffer = client.allocator.buffer(capacity: query.count)
        buffer.writeBytes(query)
        try await client.writeAndFlush(AddressedEnvelope(remoteAddress: try SocketAddress(ipAddress: "127.0.0.1", port: port), data: buffer)).get()
        for _ in 0..<1200 where collector.replies().isEmpty {
            try await Task.sleep(for: .milliseconds(10))
        }
        return collector.replies().first
    }
}

final class SilentUDPServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private let count = NIOLockedValueBox(0)
    private(set) var channel: Channel!

    var port: Int { channel.localAddress?.port ?? 0 }
    var received: Int { count.withLockedValue { $0 } }

    static func start() async throws -> SilentUDPServer {
        let server = SilentUDPServer()
        server.channel = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(server) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return server
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        count.withLockedValue { $0 += 1 }
    }
}
