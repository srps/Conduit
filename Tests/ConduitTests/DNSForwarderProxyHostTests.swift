// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class DNSForwarderProxyHostTests: XCTestCase {
    private static let proxyHost = "proxy.example.com"
    private static let firstPushed = "10.0.0.53"
    private static let secondPushed = "10.0.0.54"
    private static let tunnelIP = "203.0.113.20"
    private static let publicIP = "198.51.100.7"

    private var forwarder: LocalDNSForwarder?
    private var stops: [() async -> Void] = []
    private let events = NIOLockedValueBox<[RuntimeEvent]>([])

    override func tearDown() async throws {
        await forwarder?.stop()
        forwarder = nil
        for stop in stops { await stop() }
        stops = []
        try await super.tearDown()
    }

    func testAProxyHostOnATunnelAsksEveryPushedServerAndNeverDoH() async throws {
        let first = try await silentServer()
        let second = try await tunnelDNS(answering: Self.proxyHost)
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: first.port, Self.secondPushed: second.port],
            table: Self.fullTunnel, hosts: ProxyHostNames(names: ["Proxy.Example.com."])
        )

        let answer = try await SplitDNSProbe.resolve(Self.proxyHost, port: port)

        XCTAssertEqual(answer, Self.tunnelIP, "the second pushed server answers what the first did not")
        XCTAssertEqual(first.received, 1)
        XCTAssertEqual(second.queryCount(Self.proxyHost), 1)
        XCTAssertEqual(doh.requestCount(), 0, "a proxy's own name never goes to DoH")
        XCTAssertEqual(
            events(named: "dns.proxy_host_via_tunnel").compactMap(\.detail),
            ["name=proxy.example.com servers=2 outcome=answered suppressed=0"],
            "a count of servers, never an address"
        )
    }

    func testALocalProxyHostOnATunnelAsksThePushedServersNotAManualEntry() async throws {
        let manual = try await silentServer()
        let tunnel = try await tunnelDNS(answering: "proxy.corp.local")
        let doh = try await dohProvider()
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"])],
            detected: Self.fullTunnel.rules
        )
        let port = try await start(
            dohPort: doh.port, endpoints: ["192.0.2.80": manual.port, Self.firstPushed: tunnel.port, Self.secondPushed: tunnel.port],
            table: table, hosts: ProxyHostNames(names: ["proxy.corp.local"])
        )

        let answer = try await SplitDNSProbe.resolve("proxy.corp.local", port: port)

        XCTAssertEqual(answer, Self.tunnelIP)
        XCTAssertEqual(manual.received, 0, "a `.local` proxy host is a proxy host first")
        XCTAssertEqual(doh.requestCount(), 0)
    }

    func testAProxyHostOnATunnelTakesNXDOMAINAsTheAnswer() async throws {
        let tunnel = try await tunnelDNS(answering: "other.example.net")
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: tunnel.port, Self.secondPushed: tunnel.port],
            table: Self.fullTunnel, hosts: ProxyHostNames(names: [Self.proxyHost])
        )

        let reply = try await rawReply(Self.proxyHost, port: port)

        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 3, "NXDOMAIN from a pushed server is the answer")
        XCTAssertEqual(tunnel.queryCount(Self.proxyHost), 1, "a reply ends the attempt")
        XCTAssertEqual(doh.requestCount(), 0)
    }

    func testAProxyHostWithAllPushedServersSilentAnswersServfailWithoutDoH() async throws {
        let silent = try await silentServer()
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: silent.port, Self.secondPushed: silent.port],
            table: Self.fullTunnel, hosts: ProxyHostNames(names: [Self.proxyHost])
        )

        let reply = try await rawReply(Self.proxyHost, port: port)

        XCTAssertEqual(reply.map(DNSWireFormat.extractRCode), 2, "SERVFAIL")
        XCTAssertEqual(silent.received, 2, "both pushed servers were asked")
        XCTAssertEqual(doh.requestCount(), 0)
        XCTAssertEqual(
            events(named: "dns.proxy_host_via_tunnel").compactMap(\.detail),
            ["name=proxy.example.com servers=2 outcome=silent suppressed=0"]
        )
    }

    func testTheSameNameOffTheTunnelTakesThePublicPath() async throws {
        let manual = try await silentServer()
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: ["192.0.2.80": manual.port],
            table: SplitDNSTable(manual: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"])], detected: []),
            hosts: ProxyHostNames(names: [Self.proxyHost])
        )

        let answer = try await SplitDNSProbe.resolve(Self.proxyHost, port: port)

        XCTAssertEqual(answer, Self.publicIP, "no pushed servers in use: one internal attempt, then DoH")
        XCTAssertEqual(manual.received, 1)
        XCTAssertGreaterThan(doh.requestCount(), 0)
        XCTAssertEqual(events(named: "dns.proxy_host_via_tunnel").count, 0)
    }

    func testANameThatIsNotAProxyHostKeepsThePublicPathOnATunnel() async throws {
        let first = try await silentServer()
        let second = try await tunnelDNS(answering: "www.example.com")
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: first.port, Self.secondPushed: second.port],
            table: Self.fullTunnel, hosts: ProxyHostNames(names: [Self.proxyHost])
        )

        let answer = try await SplitDNSProbe.resolve("www.example.com", port: port)
        let suffixed = try await SplitDNSProbe.resolve("eu.\(Self.proxyHost)", port: port, txID: 0x5D01)

        XCTAssertEqual(answer, Self.publicIP)
        XCTAssertEqual(suffixed, Self.publicIP, "exact match only: a name under a proxy host is a public name")
        XCTAssertEqual(second.totalQueries, 0, "a public name asks at most the first server")
        XCTAssertEqual(first.received, 2)
        XCTAssertEqual(events(named: "dns.proxy_host_via_tunnel").count, 0)
    }

    /// The system resolver asks for a relative upstream name with a search domain appended, and a network can set
    /// that domain to a zone it owns, which DoH would answer faithfully.
    func testASearchExpandedProxyHostOnATunnelAsksThePushedServersAndNeverDoH() async throws {
        let tunnel = try await tunnelDNS(answering: "proxy.lan.example")
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: tunnel.port, Self.secondPushed: tunnel.port],
            table: Self.fullTunnel, hosts: ProxyHostNames(names: ["proxy"])
        )

        let answer = try await SplitDNSProbe.resolve("proxy.lan.example", port: port)
        let attacker = try await rawReply("proxy.attacker.example", port: port, txID: 0x5D02)

        XCTAssertEqual(answer, Self.tunnelIP)
        XCTAssertEqual(attacker.map(DNSWireFormat.extractRCode), 3, "the pushed servers' NXDOMAIN is the answer")
        XCTAssertEqual(doh.requestCount(), 0, "an expanded proxy name never goes to DoH")
    }

    /// The PAC file decides routing and names the proxies Conduit authenticates to. Its exact host keeps the public
    /// path, so a public PAC host still loads through a tunnel whose servers know only internal names.
    func testASearchExpandedPACHostOnATunnelAsksThePushedServersAndNeverDoH() async throws {
        let tunnel = try await tunnelDNS(answering: "wpad.lan.example")
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: tunnel.port, Self.secondPushed: tunnel.port],
            table: Self.fullTunnel, configure: { $0.routing.pacURL = "http://wpad/proxy.pac" }
        )

        let attacker = try await rawReply("wpad.attacker.example", port: port, txID: 0x5D03)
        XCTAssertEqual(attacker.map(DNSWireFormat.extractRCode), 3, "the pushed servers' NXDOMAIN is the answer")
        XCTAssertEqual(doh.requestCount(), 0, "an expanded PAC host never goes to DoH")
        let expanded = try await SplitDNSProbe.resolve("wpad.lan.example", port: port, txID: 0x5D04)
        XCTAssertEqual(expanded, Self.tunnelIP)
    }

    func testAnExactPublicPACHostOnATunnelKeepsThePublicPath() async throws {
        let first = try await silentServer()
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: first.port, Self.secondPushed: first.port],
            table: Self.fullTunnel, configure: { $0.routing.pacURL = "https://pac.example.net/proxy.pac" }
        )

        let answer = try await SplitDNSProbe.resolve("pac.example.net", port: port)
        XCTAssertEqual(answer, Self.publicIP, "DoH still answers the PAC host itself")
    }

    func testAPACLearnedProxyHostIsIncluded() async throws {
        let first = try await silentServer()
        let second = try await tunnelDNS(answering: "pac-proxy.example.org")
        let doh = try await dohProvider()
        let learned = PACProxyHosts()
        learned.record(PACChain(routes: [.proxy(host: "PAC-Proxy.example.org", port: 8080), .direct]))
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "a", host: Self.proxyHost, port: 3128, priority: 0)]
        let frozen = config
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: first.port, Self.secondPushed: second.port],
            table: Self.fullTunnel,
            hostsProvider: { ProxyHostNames(config: frozen, pacHosts: learned.current) }
        )

        let answer = try await SplitDNSProbe.resolve("pac-proxy.example.org", port: port)

        XCTAssertEqual(answer, Self.tunnelIP)
        XCTAssertEqual(doh.requestCount(), 0)
    }

    func testTheEventFiresOncePerOutcomePerWindow() async throws {
        let tunnel = try await tunnelDNS(answering: Self.proxyHost)
        let doh = try await dohProvider()
        let port = try await start(
            dohPort: doh.port, endpoints: [Self.firstPushed: tunnel.port, Self.secondPushed: tunnel.port],
            table: Self.fullTunnel, hosts: ProxyHostNames(names: [Self.proxyHost])
        )

        for index in 0..<3 {
            _ = try await SplitDNSProbe.resolve(Self.proxyHost, port: port, txID: 0x5E00 + UInt16(index))
        }

        XCTAssertEqual(tunnel.queryCount(Self.proxyHost), 3, "not cached, as an internal name is not")
        XCTAssertEqual(
            events(named: "dns.proxy_host_via_tunnel").compactMap(\.detail),
            ["name=proxy.example.com servers=2 outcome=answered suppressed=0"]
        )
    }

    func testConfiguredHostsAreTheEnabledUpstreams() {
        var config = ProxyConfig.testFixture()
        config.upstreams = [
            UpstreamProxy(name: "a", host: "Proxy-A.example.com", port: 3128, priority: 0),
            UpstreamProxy(name: "b", host: "proxy-b.example.com", port: 3128, enabled: false, priority: 1),
        ]
        let hosts = ProxyHostNames(config: config, pacHosts: ["pac.example.net"])

        XCTAssertTrue(hosts.contains("proxy-a.example.com."))
        XCTAssertFalse(hosts.contains("proxy-b.example.com"), "a disabled upstream is never dialled")
        XCTAssertTrue(hosts.contains("PAC.example.net"))
        XCTAssertFalse(hosts.contains("example.com"))
    }

    func testThePACLearnedSetHoldsItsCapAndEvictsTheHostSeenLongestAgo() {
        let learned = PACProxyHosts()
        for index in 0..<PACProxyHosts.limit {
            learned.record(host: "proxy-\(index).example.com")
        }
        learned.record(host: "PROXY-0.example.com")
        learned.record(host: "proxy-new.example.com")

        let current = learned.current
        XCTAssertEqual(current.count, PACProxyHosts.limit)
        XCTAssertFalse(current.contains("proxy-1.example.com"), "the host seen longest ago is evicted")
        XCTAssertTrue(current.contains("proxy-0.example.com"), "a host seen again is kept")
        XCTAssertEqual(current.last, "proxy-new.example.com")
    }

    func testRepeatedHostsOnOtherPortsLeaveRoomForADistinctBackup() {
        let learned = PACProxyHosts()
        let repeated = (0..<PACProxyHosts.limit).map { PACRoute.proxy(host: "Primary.example.com", port: 8000 + $0) }
        learned.record(PACChain(routes: repeated + [.proxy(host: "backup.example.com", port: 8080)]))
        XCTAssertEqual(learned.current, ["backup.example.com", "primary.example.com"])
    }

    func testPACRoutesThatAreNotProxiesAreNotRecorded() {
        let learned = PACProxyHosts()
        learned.record(PACChain(routes: [.direct, .proxy(host: "proxy.example.com", port: 80)]))
        XCTAssertEqual(learned.current, ["proxy.example.com"])
    }

    func testPushedServersAreTheDetectedOnesInRuleOrderEachOnce() {
        let table = SplitDNSTable(
            manual: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"])],
            detected: [
                SplitDNSRule(domain: "corp.example", servers: ["10.0.0.53"], origins: [.detected(interface: "utun4")]),
                SplitDNSRule(
                    domain: "eu.corp.example", servers: ["10.0.0.53", "10.0.0.54"],
                    origins: [.detected(interface: "utun4"), .detected(interface: "utun4")]
                ),
            ]
        )
        XCTAssertEqual(table.pushedServers, ["10.0.0.53", "10.0.0.54"], "a manual server is not a pushed one")
        XCTAssertEqual(SplitDNSTable(manual: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"])], detected: []).pushedServers, [])
    }

    private static let fullTunnel = SplitDNSTable(
        manual: [],
        detected: [SplitDNSRule(
            domain: "de.corp.example", servers: [firstPushed, secondPushed],
            origins: [.detected(interface: "utun4"), .detected(interface: "utun4")]
        )]
    )

    private func start(
        dohPort: Int,
        endpoints: [String: Int],
        table: SplitDNSTable,
        hosts: ProxyHostNames = .empty,
        hostsProvider: (@Sendable () -> ProxyHostNames)? = nil,
        configure: (inout ProxyConfig) -> Void = { _ in }
    ) async throws -> Int {
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dohProviders = ["http://127.0.0.1:\(dohPort)/dns-query"]
        config.localHost = "127.0.0.1"
        config.localPort = 9
        configure(&config)
        let frozen = config
        var tuning = SplitDNSProbe.tuning(endpoints)
        tuning.internalAttemptTimeout = .milliseconds(200)
        tuning.internalDomainTimeout = .milliseconds(200)
        tuning.dohRequestTimeout = 0.5
        let events = events
        let forwarder = LocalDNSForwarder(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: RecordingLogSink(minLevel: .debug),
            configProvider: { frozen },
            splitDNSProvider: { table },
            proxyHostsProvider: hostsProvider ?? { hosts },
            tuning: tuning,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        self.forwarder = forwarder
        try await forwarder.start(host: "127.0.0.1", port: 0)
        return try XCTUnwrap(forwarder.listeningPort)
    }

    private func tunnelDNS(answering name: String) async throws -> FakeSplitDNSServer {
        let server = try await FakeSplitDNSServer.start(domain: name, ip: Self.tunnelIP)
        stops.append { await server.stop() }
        return server
    }

    private func silentServer() async throws -> SilentUDPServer {
        let server = try await SilentUDPServer.start()
        stops.append { await server.channel.closeForTest() }
        return server
    }

    private func dohProvider() async throws -> AnsweringDoHProvider {
        let provider = try await AnsweringDoHProvider.start(group: MultiThreadedEventLoopGroup.singleton, ip: Self.publicIP)
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
