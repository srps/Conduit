// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import HelperSupport
@testable import PlatformMac
@testable import ProxyKernel

/// A loopback DNS server on UDP and, optionally, TCP on the same port that answers A queries with one address.
private final class StandInDNS: @unchecked Sendable {
    private let ip: String
    private let lock = NSLock()
    private var _silent = false
    private var _dropsRealQueries = false
    private var _dropsRealTCPQueries = false
    private var _dropsEDNSOverTCP = false
    private var _delay: TimeInterval = 0
    private var _asked: [String: Int] = [:]
    private var stopped = false
    private let udp: Int32
    private let tcp: Int32?
    let port: Int

    init(ip: String, tcp wantsTCP: Bool = false) throws {
        self.ip = ip
        for _ in 0..<50 {
            let udp = try Self.bound(port: 0, type: SOCK_DGRAM)
            let port = Self.port(of: udp)
            guard wantsTCP else {
                (self.udp, self.tcp, self.port) = (udp, nil, port)
                start()
                return
            }
            if let tcp = try? Self.bound(port: port, type: SOCK_STREAM) {
                (self.udp, self.tcp, self.port) = (udp, tcp, port)
                start()
                return
            }
            close(udp)
        }
        throw XCTSkip("no port free on both UDP and TCP")
    }

    var silent: Bool {
        get { lock.withLock { _silent } }
        set { lock.withLock { _silent = newValue } }
    }

    /// How long a query other than the forwarder's probe waits for its answer.
    /// Answers the probe name and nothing else, as a forwarder that drops every lookup.
    var dropsRealQueries: Bool {
        get { lock.withLock { _dropsRealQueries } }
        set { lock.withLock { _dropsRealQueries = newValue } }
    }

    /// Answers real queries over UDP and drops them over TCP.
    var dropsRealTCPQueries: Bool {
        get { lock.withLock { _dropsRealTCPQueries } }
        set { lock.withLock { _dropsRealTCPQueries = newValue } }
    }

    /// Over TCP, drops real queries that carry an additional record, as an EDNS OPT, and answers plain ones.
    var dropsEDNSOverTCP: Bool {
        get { lock.withLock { _dropsEDNSOverTCP } }
        set { lock.withLock { _dropsEDNSOverTCP = newValue } }
    }

    var delay: TimeInterval {
        get { lock.withLock { _delay } }
        set { lock.withLock { _delay = newValue } }
    }

    var total: Int { lock.withLock { _asked.values.reduce(0, +) } }
    func asked(_ name: String) -> Int { lock.withLock { _asked[name] ?? 0 } }

    /// dup2, not close: a closed number can be reused by another test's socket while the serving threads still read it.
    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            let dead = socket(AF_INET, SOCK_STREAM, 0)
            dup2(dead, udp)
            if let tcp { dup2(dead, tcp) }
            close(dead)
        }
    }

    deinit {
        stop()
        close(udp)
        if let tcp { close(tcp) }
    }

    private func start() {
        Thread { [self] in serveUDP() }.start()
        if tcp != nil { Thread { [self] in acceptTCP() }.start() }
    }

    /// A query whose section counts do not match its bytes is dropped, as a strict server drops it.
    private func answer(_ query: [UInt8], overTCP: Bool = false) -> (reply: [UInt8], delay: TimeInterval)? {
        guard let question = DNSWireFormat.headerAndQuestion(of: query),
              (question.count < query.count) == query[6..<12].contains(where: { $0 != 0 }) else { return nil }
        let name = DNSWireFormat.extractDomainName(from: query).lowercased()
        let isProbe = name == DNSWireFormat.forwarderProbeDomain.lowercased()
        let (silent, delay) = lock.withLock { () -> (Bool, TimeInterval) in
            _asked[name, default: 0] += 1
            let edns = query[10] | query[11] != 0
            let drops = _dropsRealQueries || (overTCP && (_dropsRealTCPQueries || (_dropsEDNSOverTCP && edns)))
            return (_silent || (drops && !isProbe), isProbe ? 0 : _delay)
        }
        guard !silent else { return nil }
        // As the forwarder does: the reserved probe name is answered NXDOMAIN at once.
        if name == DNSWireFormat.forwarderProbeDomain.lowercased() {
            return DNSWireFormat.emptyDNSResponse(originalQuery: query, rcode: 3).map { ($0, 0) }
        }
        guard let reply = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: ip) else { return nil }
        return (reply, delay)
    }

    private func serveUDP() {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            var from = sockaddr_storage()
            var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
            let count = withUnsafeMutablePointer(to: &from) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(udp, &buffer, buffer.count, 0, $0, &length) }
            }
            guard count > 0 else { return }
            guard let (reply, delay) = answer(Array(buffer[0..<count])) else { continue }
            let send = { [udp] in
                var to = from
                _ = withUnsafePointer(to: &to) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(udp, reply, reply.count, 0, $0, length) }
                }
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay) { send() }
            } else {
                send()
            }
        }
    }

    private func acceptTCP() {
        guard let tcp else { return }
        while true {
            let client = accept(tcp, nil, nil)
            guard client >= 0 else { return }
            Thread { [self] in serveTCP(client) }.start()
        }
    }

    private func serveTCP(_ client: Int32) {
        defer { close(client) }
        while true {
            var header = [UInt8](repeating: 0, count: 2)
            guard Self.readFully(client, &header) else { return }
            var query = [UInt8](repeating: 0, count: Int(header[0]) << 8 | Int(header[1]))
            guard Self.readFully(client, &query), let (reply, _) = answer(query, overTCP: true) else { return }
            let framed = [UInt8(reply.count >> 8), UInt8(reply.count & 0xFF)] + reply
            guard write(client, framed, framed.count) == framed.count else { return }
        }
    }

    static func readFully(_ fd: Int32, _ buffer: inout [UInt8]) -> Bool {
        var offset = 0
        let total = buffer.count
        while offset < total {
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress! + offset, total - offset) }
            guard count > 0 else { return false }
            offset += count
        }
        return true
    }

    static func bound(port: Int, type: Int32) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0, type != SOCK_STREAM || listen(fd, 16) == 0 else {
            close(fd)
            throw POSIXError(.EADDRINUSE)
        }
        return fd
    }

    static func port(of fd: Int32) -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}

final class DNSFailoverRelayTests: XCTestCase {
    private let conduitIP = "203.0.113.7"
    private let vpnIP = "198.51.100.20"
    private let queryName = "www.example.com"
    private var relays: [DNSFailoverRelay] = []
    private var standIns: [StandInDNS] = []

    override func tearDown() {
        relays.forEach { $0.stop() }
        standIns.forEach { $0.stop() }
        super.tearDown()
    }

    private func standIn(_ ip: String, tcp: Bool = false) throws -> StandInDNS {
        let server = try StandInDNS(ip: ip, tcp: tcp)
        standIns.append(server)
        return server
    }

    /// `servers` names the VPN's servers by fake address; each maps to its stand-in's port.
    private func relay(
        conduitPort: Int, servers: [String: StandInDNS], order: [String]? = nil, timing: DNSFailoverTiming = .fast,
        dropped: (@Sendable (Int) -> Void)? = nil
    ) throws -> DNSFailoverRelay {
        let ports = servers.mapValues(\.port)
        let relay = DNSFailoverRelay(
            listenPort: 0, maximumTCPSessions: 4, timing: timing,
            serverEndpoint: { DNSFailoverEndpoint(host: "127.0.0.1", port: ports[$0] ?? 9) },
            droppedAtCapacity: dropped ?? { _ in }
        )
        relays.append(relay)
        XCTAssertEqual(relay.start(targetPort: conduitPort), [])
        relay.setFailoverServers(order ?? servers.keys.sorted())
        XCTAssertNotNil(relay.listeningPort)
        return relay
    }

    private func ask(_ relay: DNSFailoverRelay, timeout: TimeInterval = 3, edns: Bool = false) -> (ip: String?, seconds: Double) {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        return ask(relay, on: fd, timeout: timeout, edns: edns)
    }

    private func ask(
        _ relay: DNSFailoverRelay, on fd: Int32, timeout: TimeInterval = 3, edns: Bool = false
    ) -> (ip: String?, seconds: Double) {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(relay.listeningPort ?? 0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let query = query(edns: edns)
        let began = Date()
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&readiness, 1, Int32(timeout * 1_000)) == 1 else { return (nil, Date().timeIntervalSince(began)) }
        var buffer = [UInt8](repeating: 0, count: 4_096)
        let count = recv(fd, &buffer, buffer.count, 0)
        let elapsed = Date().timeIntervalSince(began)
        guard count > 0, DNSWireFormat.isResponse(Array(buffer[0..<count]), to: query) else { return (nil, elapsed) }
        return (DNSWireFormat.firstIPv4Answer(in: Array(buffer[0..<count]))?.ip, elapsed)
    }

    /// An A query for `queryName`; with `edns`, an OPT record padded by `padding` bytes.
    private func query(edns: Bool, padding: Int = 0) -> [UInt8] {
        var query = DNSWireFormat.buildQuery(domain: queryName, txID: UInt16.random(in: 1...UInt16.max))
        guard edns else { return query }
        query[11] = 1
        let option = padding > 0 ? [0x00, 0x0C, UInt8(padding >> 8), UInt8(padding & 0xFF)] + [UInt8](repeating: 0, count: padding) : []
        return query + [0x00, 0x00, 0x29, 0x10, 0x00, 0, 0, 0, 0, UInt8(option.count >> 8), UInt8(option.count & 0xFF)] + option
    }

    func testAQueryGoesToConduitWhileItAnswers() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        XCTAssertEqual(ask(relay).ip, conduitIP)
        XCTAssertEqual(vpn.total, 0)
        XCTAssertEqual(relay.probe().verdict, .answered)
    }

    func testARefusedConduitFailsOverAtOnce() throws {
        let conduit = try standIn(conduitIP)
        let vpn = try standIn(vpnIP)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn], timing: .standard)
        conduit.stop()
        let reply = ask(relay)
        XCTAssertEqual(reply.ip, vpnIP)
        XCTAssertLessThan(reply.seconds, 0.5, "no silence, no probe")
        XCTAssertEqual(relay.probe().verdict, .refused)
    }

    func testASilentConduitIsProbedAndTheRelaySwitches() throws {
        let conduit = try standIn(conduitIP)
        conduit.silent = true
        let vpn = try standIn(vpnIP)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let reply = ask(relay)
        XCTAssertEqual(reply.ip, vpnIP)
        XCTAssertGreaterThanOrEqual(reply.seconds, 0.3, "silence, then the probe's bound")
        XCTAssertEqual(conduit.asked(DNSWireFormat.forwarderProbeDomain.lowercased()), 1)
        XCTAssertEqual(relay.mode, .vpn)
        XCTAssertLessThan(ask(relay).seconds, 0.2, "after the switch, straight to the VPN")
    }

    func testASlowConduitThatAnswersTheProbeIsNotRaced() throws {
        let conduit = try standIn(conduitIP)
        conduit.delay = 0.6
        let vpn = try standIn(vpnIP)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        XCTAssertEqual(ask(relay).ip, conduitIP)
        XCTAssertEqual(vpn.total, 0, "the tunnel's NXDOMAIN for a public name must not win")
        XCTAssertEqual(relay.mode, .conduit)
    }

    func testTheVPNsServersAreTriedOneAtATimeAtMostThree() throws {
        let conduit = try standIn(conduitIP)
        let silent = try (0..<4).map { _ in try standIn(vpnIP) }
        silent.forEach { $0.silent = true }
        var timing = DNSFailoverTiming.fast
        timing.entryLifetime = .milliseconds(900)
        let addresses = ["192.0.2.1", "192.0.2.2", "192.0.2.3", "192.0.2.4"]
        let relay = try relay(
            conduitPort: conduit.port, servers: Dictionary(uniqueKeysWithValues: zip(addresses, silent)), order: addresses, timing: timing
        )
        relay.setMode(.vpn)
        XCTAssertNil(ask(relay, timeout: 1.2).ip)
        XCTAssertEqual(silent.map(\.total), [1, 1, 1, 0])
        XCTAssertEqual(conduit.total, 0)
    }

    /// A server whose socket cannot be made, and which then comes back.
    private final class Endpoints: @unchecked Sendable {
        private let lock = NSLock()
        private var ports: [String: Int]
        private var broken: Set<String> = []
        private var _made: [String: Int] = [:]
        private var _changes: [DNSFailoverServerSocket] = []

        init(_ ports: [String: Int]) { self.ports = ports }

        func breaks(_ server: String, _ broken: Bool) {
            lock.withLock { if broken { self.broken.insert(server) } else { self.broken.remove(server) } }
        }

        func endpoint(_ server: String) -> DNSFailoverEndpoint {
            lock.withLock {
                _made[server, default: 0] += 1
                return DNSFailoverEndpoint(host: "127.0.0.1", port: broken.contains(server) ? 0 : ports[server] ?? 9)
            }
        }

        func record(_ change: DNSFailoverServerSocket) { lock.withLock { _changes.append(change) } }
        var made: [String: Int] { lock.withLock { _made } }
        var changes: [DNSFailoverServerSocket] { lock.withLock { _changes } }
    }

    private func relay(conduitPort: Int, endpoints: Endpoints, order: [String], timing: DNSFailoverTiming) -> DNSFailoverRelay {
        let relay = DNSFailoverRelay(
            listenPort: 0, maximumTCPSessions: 4, timing: timing,
            serverEndpoint: { endpoints.endpoint($0) }, serverSocket: { endpoints.record($0) }
        )
        relays.append(relay)
        XCTAssertEqual(relay.start(targetPort: conduitPort), [])
        relay.setFailoverServers(order)
        return relay
    }

    func testAServerWithNoSocketIsSkippedAndAskedOnceItsSocketIsBack() throws {
        let conduit = try standIn(conduitIP)
        let first = try standIn(vpnIP)
        let second = try standIn("198.51.100.21")
        let endpoints = Endpoints(["192.0.2.1": first.port, "192.0.2.2": second.port])
        endpoints.breaks("192.0.2.1", true)
        var timing = DNSFailoverTiming.fast
        timing.serverSpacing = .seconds(2)
        timing.socketRetry = .milliseconds(100)
        let relay = relay(conduitPort: conduit.port, endpoints: endpoints, order: ["192.0.2.1", "192.0.2.2"], timing: timing)
        relay.setMode(.vpn)

        let skipped = ask(relay)
        XCTAssertEqual(skipped.ip, "198.51.100.21", "the first server has no socket, so the second is asked")
        XCTAssertLessThan(skipped.seconds, 1, "at once, not after the server spacing")
        XCTAssertTrue(endpoints.changes.contains {
            if case .unavailable(server: "192.0.2.1", _, retryMilliseconds: 100) = $0 { true } else { false }
        }, "\(endpoints.changes)")

        endpoints.breaks("192.0.2.1", false)
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(endpoints.changes.contains(.restored(server: "192.0.2.1")))
        XCTAssertEqual(ask(relay).ip, vpnIP, "recovered, the first server is first again")
    }

    func testASocketThatKeepsFailingBacksOffToTheLimit() throws {
        let conduit = try standIn(conduitIP)
        let endpoints = Endpoints([:])
        endpoints.breaks("192.0.2.1", true)
        var timing = DNSFailoverTiming.fast
        timing.socketRetry = .milliseconds(50)
        timing.socketRetryLimit = .milliseconds(200)
        _ = relay(conduitPort: conduit.port, endpoints: endpoints, order: ["192.0.2.1"], timing: timing)
        Thread.sleep(forTimeInterval: 2)
        let delays = endpoints.changes.compactMap { change -> Int? in
            if case .unavailable(_, _, let retry) = change { retry } else { nil }
        }
        XCTAssertEqual(Array(delays.prefix(4)), [50, 100, 200, 200])
        XCTAssertLessThan(endpoints.made["192.0.2.1"] ?? 0, 15, "bounded, not once per loop wake")
    }

    func testAPathChangeMakesEveryServerSocketAgain() throws {
        let conduit = try standIn(conduitIP)
        let vpn = try standIn(vpnIP)
        let endpoints = Endpoints(["192.0.2.1": vpn.port])
        let relay = relay(conduitPort: conduit.port, endpoints: endpoints, order: ["192.0.2.1"], timing: .fast)
        relay.setMode(.vpn)
        XCTAssertEqual(ask(relay).ip, vpnIP)
        XCTAssertEqual(endpoints.made["192.0.2.1"], 1)
        relay.renewServerSockets()
        XCTAssertEqual(ask(relay).ip, vpnIP)
        XCTAssertEqual(endpoints.made["192.0.2.1"], 2)
    }

    func testTheFirstReplyWinsAndALaterOneIsDropped() throws {
        let conduit = try standIn(conduitIP)
        let slow = try standIn("198.51.100.1")
        slow.delay = 0.3
        let quick = try standIn("198.51.100.2")
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.1": slow, "192.0.2.2": quick], order: ["192.0.2.1", "192.0.2.2"])
        relay.setMode(.vpn)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        XCTAssertEqual(ask(relay, on: fd).ip, "198.51.100.2")
        var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&readiness, 1, 600), 0, "the slow server's later reply never reaches the client")
        XCTAssertEqual(slow.total, 1)
    }

    func testLoopbackAndUnspecifiedServersAreNeverTargets() throws {
        let conduit = try standIn(conduitIP)
        let relay = try relay(conduitPort: conduit.port, servers: [:], order: ["127.0.0.1", "::1", "0.0.0.0", "::"])
        XCTAssertEqual(relay.route.servers, [])
        relay.setMode(.vpn)
        XCTAssertNil(ask(relay, timeout: 0.5).ip)
    }

    func testTheKernelKeepsOnlyUsableServersInOrderWithoutRepeats() {
        XCTAssertEqual(
            DNSFailoverServers.usable(["192.0.2.53", "127.0.0.1", "::1", "0.0.0.0", "::", "192.0.2.53", "2001:db8::53", "x", "::ffff:127.0.0.1"]),
            ["192.0.2.53", "2001:db8::53"]
        )
    }

    func testAtCapacityAQueryIsDroppedAndCounted() throws {
        let conduit = try standIn(conduitIP)
        let vpn = try standIn(vpnIP)
        vpn.silent = true
        let drops = DropCount()
        var timing = DNSFailoverTiming.fast
        timing.entryLifetime = .seconds(5)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn], timing: timing, dropped: { drops.set($0) })
        relay.setMode(.vpn)
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(relay.listeningPort ?? 0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        for batch in 0..<22 {
            for index in 0..<50 {
                let query = DNSWireFormat.buildQuery(domain: "q\(batch)-\(index).example.com", txID: UInt16(batch * 50 + index))
                _ = withUnsafePointer(to: &address) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        sendto(fd, query, query.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        let deadline = Date().addingTimeInterval(2)
        while drops.value == 0, Date() < deadline { Thread.sleep(forTimeInterval: 0.02) }
        Thread.sleep(forTimeInterval: 0.2)
        XCTAssertGreaterThan(drops.value, 0)
        XCTAssertLessThanOrEqual(vpn.total, DNSFailoverUDPRelay.maximumPendingQueries, "a dropped query adds no entry")
    }

    func testTheProbeGoesThroughBothListenersToConduitAndNeverToTheVPN() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        relay.setMode(.vpn)
        XCTAssertEqual(relay.probe(), DNSFailoverProbe(.answered), "the probe name reaches Conduit whatever the mode")
        XCTAssertEqual(conduit.asked(DNSWireFormat.forwarderProbeDomain.lowercased()), 2, "once over UDP, once over TCP")
        conduit.silent = true
        let silent = relay.probe()
        XCTAssertEqual(silent.udp, .silent)
        XCTAssertNotEqual(silent.tcp, .answered)
        XCTAssertEqual(vpn.total, 0, "the VPN's NXDOMAIN for the probe name would read as an answer")
    }

    func testATCPOnlyFailureFailsTheProbe() throws {
        let conduit = try standIn(conduitIP)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let probe = relay.probe()
        XCTAssertEqual(probe.udp, .answered)
        XCTAssertEqual(probe.tcp, .refused, "Conduit's TCP listener is gone; the relay answers the probe REFUSED")
        XCTAssertEqual(probe.verdict, .refused)
        XCTAssertEqual(vpn.total, 0)
    }

    func testExhaustedTCPAdmissionFailsTheProbe() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        var timing = DNSFailoverTiming.fast
        timing.firstQueryTimeout = .seconds(5)
        let relay = try relay(conduitPort: conduit.port, servers: [:], timing: timing)
        let held = try (0..<4).map { _ in try connectTCP(relay) }
        defer { held.forEach { close($0) } }
        Thread.sleep(forTimeInterval: 0.2)
        let probe = relay.probe()
        XCTAssertEqual(probe.udp, .answered)
        XCTAssertEqual(probe.tcp, .refused, "a session refused at the cap closes with no answer")
    }

    func testRealQueriesConduitNeverAnswersAreCountedEvenWhileTheProbeAnswers() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        conduit.dropsRealQueries = true
        let relay = try relay(conduitPort: conduit.port, servers: [:])
        XCTAssertNil(ask(relay, timeout: 0.5).ip)
        XCTAssertEqual(relay.mode, .conduit, "the in-relay probe answered, so the relay stays")
        Thread.sleep(forTimeInterval: 2.2)
        XCTAssertEqual(relay.conduitProgress(.udp), DNSFailoverProgress(answered: 0, unanswered: 1, lastUnanswered: true))
        XCTAssertEqual(relay.probe().verdict, .answered, "the probe alone cannot see it")
        conduit.dropsRealQueries = false
        XCTAssertEqual(ask(relay).ip, conduitIP)
        XCTAssertEqual(relay.conduitProgress(.udp), DNSFailoverProgress(answered: 1, unanswered: 1, lastUnanswered: false))
        XCTAssertEqual(relay.conduitProgress(.tcp), .zero)
    }

    func testATCPQueryConduitNeverAnswersIsCountedAndAskedAgain() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        conduit.dropsRealQueries = true
        let relay = try relay(conduitPort: conduit.port, servers: [:])
        XCTAssertEqual(relay.recheck(.tcp), .notRunning, "nothing left unanswered yet")
        XCTAssertNil(try askTCP(relay))
        XCTAssertEqual(relay.conduitProgress(.tcp), DNSFailoverProgress(answered: 0, unanswered: 1, lastUnanswered: true), "TCP lookups count too")
        XCTAssertEqual(relay.conduitProgress(.udp), .zero, "apart from UDP's")
        XCTAssertEqual(relay.recheck(.udp), .notRunning)
        let asked = conduit.asked(queryName)
        XCTAssertEqual(relay.recheck(.tcp), .refused, "Conduit closes the session it will not answer")
        XCTAssertEqual(conduit.asked(queryName), asked + 1, "the recheck asks Conduit the question it dropped, over TCP")
        conduit.dropsRealQueries = false
        XCTAssertEqual(relay.recheck(.tcp), .answered)
        XCTAssertEqual(try askTCP(relay), conduitIP)
        XCTAssertEqual(relay.conduitProgress(.tcp), DNSFailoverProgress(answered: 1, unanswered: 1, lastUnanswered: false))
    }

    /// The publisher over a real relay, on a clock the test moves a tick at a time.
    private final class Override: @unchecked Sendable {
        let service = "com.cisco.anyconnect"
        let store = FakeVPNDNSStore()
        var now: UInt64 = 1_000_000_000_000
        var outcomes: [VPNDNSOverrideOutcome] = []
        var publisher: VPNDNSOverridePublisher!

        init(relay: DNSFailoverRelay) {
            store.connectFullTunnel(service, servers: ["192.0.2.53"])
            publisher = VPNDNSOverridePublisher(store: store, relay: relay, now: { [unowned self] in now }) { [unowned self] in
                outcomes.append($0)
            }
            XCTAssertTrue(publisher.arm(service: service, servers: ["192.0.2.53"], owner: 1))
            XCTAssertNotNil(store.ownKey)
        }

        func tick() {
            now += UInt64(VPNDNSOverridePublisher.tickSeconds) * 1_000_000_000
            publisher.tick()
        }
    }

    /// A forwarder that answers the probe name and nothing else.
    func testAProbeOnlyForwarderLosesTheKeyByTheBoundAndNeverGetsTheLookupsBack() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let override = Override(relay: relay)
        let store = override.store

        conduit.dropsRealQueries = true
        let first = ask(relay, timeout: 3)
        XCTAssertEqual(first.ip, vpnIP, "the lookup that shows the loss is answered by the VPN, on the asker's socket")
        XCTAssertGreaterThanOrEqual(first.seconds, 1.9, "once its wait on Conduit ran out")
        override.tick()
        XCTAssertEqual(relay.mode, .vpn)
        XCTAssertEqual(ask(relay).ip, vpnIP, "the next lookup goes to the VPN's servers")
        XCTAssertNotNil(store.ownKey)
        override.tick()
        XCTAssertEqual(relay.mode, .vpn, "an answered probe does not send the lookups back to a forwarder that drops them")
        XCTAssertEqual(ask(relay).ip, vpnIP)
        XCTAssertNotNil(store.ownKey)
        override.tick()
        XCTAssertNil(store.ownKey, "withdrawn 30 s after the last confirmed answer")
        XCTAssertEqual(override.outcomes.last, .withdrawn(service: override.service, reason: .targetSilent))
        override.tick()
        XCTAssertNil(store.ownKey, "a probe answer alone does not bring it back")
        XCTAssertEqual(relay.mode, .vpn)

        conduit.dropsRealQueries = false
        override.tick()
        XCTAssertNotNil(store.ownKey, "Conduit answered the question it had dropped")
        XCTAssertEqual(relay.mode, .conduit)
        XCTAssertEqual(ask(relay).ip, conduitIP)
    }

    func testAForwarderThatDropsOnlyTCPLookupsLosesTheKeyWhileUDPAnswers() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let override = Override(relay: relay)

        conduit.dropsRealTCPQueries = true
        XCTAssertNil(try askTCP(relay))
        XCTAssertEqual(ask(relay).ip, conduitIP, "UDP is still answered")
        override.tick()
        XCTAssertEqual(relay.mode, .vpn, "a UDP answer does not end a TCP failure")
        XCTAssertEqual(try askTCP(relay), vpnIP)
        override.tick()
        XCTAssertEqual(relay.mode, .vpn, "nor does the recheck while Conduit still drops TCP")
        override.tick()
        XCTAssertNil(override.store.ownKey, "withdrawn within the bound")

        conduit.dropsRealTCPQueries = false
        override.tick()
        XCTAssertNotNil(override.store.ownKey, "the recheck over TCP is answered")
        XCTAssertEqual(relay.mode, .conduit)
        XCTAssertEqual(try askTCP(relay), conduitIP)
    }

    func testTheRecheckOfAnEDNSQuestionIsAQueryAStrictForwarderAnswers() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let override = Override(relay: relay)

        conduit.dropsRealQueries = true
        _ = ask(relay, timeout: 3, edns: true)
        conduit.dropsRealQueries = false
        override.tick()
        XCTAssertEqual(relay.mode, .conduit, "the recovered forwarder answers the replayed question")
        XCTAssertFalse(override.outcomes.contains { if case .queriesUnanswered = $0 { true } else { false } })
        XCTAssertNotNil(override.store.ownKey)
    }

    func testARecheckReplaysTheEDNSRequestConduitDroppedNotAPlainQuestion() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let override = Override(relay: relay)

        conduit.dropsEDNSOverTCP = true
        XCTAssertNil(try askTCP(relay, edns: true))
        override.tick()
        XCTAssertEqual(relay.mode, .vpn, "the replayed EDNS request is dropped too")
        XCTAssertEqual(try askTCP(relay, edns: true), vpnIP, "the client's retry reaches the VPN")
        let plain = DNSWireFormat.buildQuery(domain: queryName, txID: 1)
        XCTAssertEqual(DNSFailoverRelay.askTCP(plain, port: conduit.port, boundMilliseconds: 1_000), .answered, "Conduit answers plain TCP")
        override.tick()
        XCTAssertEqual(relay.mode, .vpn)
        override.tick()
        XCTAssertNil(override.store.ownKey, "withdrawn within the bound")
        XCTAssertEqual(override.outcomes.last, .withdrawn(service: override.service, reason: .targetSilent))

        conduit.dropsEDNSOverTCP = false
        override.tick()
        XCTAssertNotNil(override.store.ownKey, "Conduit answered the EDNS replay")
        XCTAssertEqual(relay.mode, .conduit)
        XCTAssertEqual(try askTCP(relay, edns: true), conduitIP)
    }

    func testTheLargestRequestATCPSessionCanSendIsKeptAndReplayed() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        conduit.dropsRealQueries = true
        let relay = try relay(conduitPort: conduit.port, servers: [:])
        XCTAssertNil(try askTCP(relay))
        XCTAssertNil(try askTCP(relay, edns: true, padding: 4_200))
        XCTAssertEqual(relay.conduitProgress(.tcp), DNSFailoverProgress(answered: 0, unanswered: 2, lastUnanswered: true))
        conduit.dropsRealQueries = false
        XCTAssertEqual(relay.recheck(.tcp), .answered, "a large failed request is still there to show the recovery")
    }

    func testATCPSessionTakesTheModeAtConnect() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        XCTAssertEqual(try askTCP(relay), conduitIP)
        relay.setMode(.vpn)
        XCTAssertEqual(try askTCP(relay), vpnIP)
    }

    func testATCPConnectConduitRefusesGoesToTheVPN() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        conduit.stop()
        XCTAssertEqual(try askTCP(relay), vpnIP)
    }

    func testASessionToConduitIsClosedWhenTheRelaySwitches() throws {
        let conduit = try standIn(conduitIP, tcp: true)
        let vpn = try standIn(vpnIP, tcp: true)
        let relay = try relay(conduitPort: conduit.port, servers: ["192.0.2.53": vpn])
        let fd = try connectTCP(relay)
        defer { close(fd) }
        XCTAssertEqual(try exchange(fd), conduitIP)
        relay.setMode(.vpn)
        var byte: UInt8 = 0
        var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&readiness, 1, 1_000), 1, "the session is closed, so the resolver's retry reaches the VPN")
        XCTAssertLessThanOrEqual(read(fd, &byte, 1), 0)
    }

    private func connectTCP(_ relay: DNSFailoverRelay) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(relay.listeningPort ?? 0).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let rc = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    private func exchange(_ fd: Int32, edns: Bool = false, padding: Int = 0) throws -> String? {
        let query = query(edns: edns, padding: padding)
        let framed = [UInt8(query.count >> 8), UInt8(query.count & 0xFF)] + query
        guard write(fd, framed, framed.count) == framed.count else { return nil }
        var header = [UInt8](repeating: 0, count: 2)
        guard StandInDNS.readFully(fd, &header) else { return nil }
        var reply = [UInt8](repeating: 0, count: Int(header[0]) << 8 | Int(header[1]))
        guard StandInDNS.readFully(fd, &reply) else { return nil }
        return DNSWireFormat.firstIPv4Answer(in: reply)?.ip
    }

    private func askTCP(_ relay: DNSFailoverRelay, edns: Bool = false, padding: Int = 0) throws -> String? {
        let fd = try connectTCP(relay)
        defer { close(fd) }
        return try exchange(fd, edns: edns, padding: padding)
    }
}

private final class DropCount: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = 0
    var value: Int { lock.withLock { latest } }
    func set(_ value: Int) { lock.withLock { latest = max(latest, value) } }
}

extension DNSFailoverTiming {
    /// The standard bounds scaled down, so a test waits a fifth as long.
    static var fast: DNSFailoverTiming {
        var timing = DNSFailoverTiming()
        timing.silenceBeforeProbe = .milliseconds(200)
        timing.probeBound = .milliseconds(100)
        timing.serverSpacing = .milliseconds(200)
        timing.entryLifetime = .seconds(2)
        timing.connectTimeout = .milliseconds(500)
        timing.granularity = .milliseconds(10)
        return timing
    }
}
