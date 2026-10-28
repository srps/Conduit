// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import ProxyKernel

/// `pm-sim dns-doh-blocked`. Covers what the forwarder does when it is used as
/// a general-purpose resolver on a network that has taken both of its escape
/// routes away — the shape of a corporate split-DNS network under VPN:
///
/// | # | condition                                  | expected                     |
/// |---|--------------------------------------------|------------------------------|
/// | A | internal DNS dead, DoH answers 404         | client still gets an answer  |
/// | B | same                                       | one warning naming HTTP 404  |
/// | C | same, query arrives over TCP               | client still gets an answer  |
///
/// **A is the regression.** Every failure path in the resolution core used to
/// `return` without writing anything, so a lookup that could not be answered
/// became silence on the wire. A resolver client cannot distinguish that from a
/// dead forwarder: `dig` waits out its full timeout and then reports "no
/// servers could be reached". SERVFAIL is the honest answer, and it arrives
/// immediately.
///
/// **B is why this scenario exists at all.** The failure it simulates was found
/// in production and took an hour to diagnose, because eighteen concurrent DoH
/// attempts each failed and returned nil in silence — the only visible symptom
/// was an NXDOMAIN with no explanation. A uniform HTTP status across every
/// provider is the signature of a filtering proxy answering on their behalf,
/// and it is worth exactly one log line.
///
/// The fake provider speaks cleartext HTTP rather than TLS: what is under test
/// is how the forwarder treats a non-200 answer, and a real handshake would add
/// certificate plumbing without changing the assertion.
enum DNSResolverScenarios {

    /// TEST-NET-1. Guaranteed not to route anywhere, so the "internal"
    /// nameserver times out exactly as a tunnel-internal server does when the
    /// tunnel is down.
    private static let unreachableInternalDNS = "192.0.2.53"

    /// `pm-sim dns-ephemeral-pair-rebind`. With `port: 0` the forwarder binds
    /// UDP first and puts TCP on the number UDP got, but an ephemeral UDP port
    /// does not reserve its TCP twin. This takes the TCP port in that gap with
    /// a real listener, so the forwarder meets a real `EADDRINUSE`:
    ///
    /// | # | expected                                                        |
    /// |---|-----------------------------------------------------------------|
    /// | A | UDP and TCP end up on one port, and not the one that was taken  |
    /// | B | `dns.listener_port_retry` events, the first naming the taken port |
    /// | C | a query is answered on both transports of the new pair          |
    ///
    /// It used to keep the UDP port, warn, and serve UDP only, which a client
    /// retrying over TCP after a truncated answer reads as a dead resolver.
    @MainActor
    static func ephemeralPairRebind(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsEphemeralPairRebind"
        let start = Date()
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        var config = ProxyConfig.testFixture()
        // An intercept rule is answered by the forwarder itself, so the probe
        // needs no reachable nameserver.
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.pair.test", interceptIP: "127.44.3.1", enabled: true)]
        config.upstreams = []
        let frozen = config

        let takenPort = NIOLockedValueBox<Int?>(nil)
        let squatter = NIOLockedValueBox<Channel?>(nil)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        ScenarioCleanup.register { _ = try? await squatter.withLockedValue { $0 }?.close().get() }

        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { frozen },
            eventSink: { event in events.withLockedValue { $0.append(event) } },
            willBindTCP: { port in
                guard takenPort.withLockedValue({ $0 }) == nil else { return }
                takenPort.withLockedValue { $0 = port }
                // `SO_REUSEADDR` so a connection in `TIME_WAIT` on this port
                // does not stop the squatter where it would not stop the
                // forwarder. Once this socket listens, the option no longer
                // helps the forwarder.
                let channel = try? await ServerBootstrap(group: group)
                    .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
                    .bind(host: "127.0.0.1", port: port)
                    .get()
                squatter.withLockedValue { $0 = channel }
            }
        )
        ScenarioCleanup.register { await forwarder.stop() }
        try await forwarder.start(host: "127.0.0.1", port: 0)

        let taken = takenPort.withLockedValue { $0 } ?? 0
        let udpPort = forwarder.listeningPort ?? 0
        let tcpPort = forwarder.tcpListeningPort ?? 0
        notes.append("took tcp=\(taken) in the gap; forwarder bound udp=\(udpPort) tcp=\(tcpPort)")

        // ── Case A: the pair moved, together ──
        let passA = udpPort != 0 && udpPort == tcpPort && udpPort != taken

        // ── Case B: the retry is an event, naming the port given up ──
        // The squatter takes only the first port. Another process may hold the TCP twin of a later pick too, so a start that bound the
        // pair may have retried more than once, but never on its last attempt, which gives up instead.
        let seen = events.withLockedValue { $0 }
        notes.append("B events: \(seen.map { "\($0.event)[\($0.detail ?? "")]" })")
        let attempts = LocalDNSForwarder.ephemeralPairAttempts
        let passB = (1..<attempts).contains(seen.count)
            && seen.first?.detail == "port=\(taken) attempt=1 of=\(attempts) reason=tcp_port_in_use"
            && seen.enumerated().allSatisfy { index, event in
                event.event == "dns.listener_port_retry" && event.kind == .health
                    && event.detail?.hasSuffix(" attempt=\(index + 1) of=\(attempts) reason=tcp_port_in_use") == true
            }

        // ── Case C: both transports of the new pair answer ──
        let query = DNSWireFormat.buildQuery(domain: "host.pair.test", txID: 0x5157, qtype: 1)
        let udpAnswer = try await DNSProbe.overUDP(query: query, port: udpPort, timeout: 5)
        let tcpAnswer = tcpPort == 0 ? nil : try await DNSProbe.overTCP(query: query, port: tcpPort, timeout: 5)
        let answeredUDP = udpAnswer.map { DNSWireFormat.responseQuestionMatches(query: query, response: $0) } ?? false
        let answeredTCP = tcpAnswer.map { DNSWireFormat.responseQuestionMatches(query: query, response: $0) } ?? false
        notes.append("C answered: udp=\(answeredUDP) tcp=\(answeredTCP)")
        let passC = answeredUDP && answeredTCP

        let pass = passA && passB && passC
        notes.append("A=\(verdict(passA)) B=\(verdict(passB)) C=\(verdict(passC))")
        notes.append(pass
            ? "PASS — a taken TCP twin moves the pair to a fresh port, with retry events, and both transports answer"
            : "FAIL — see per-case lines above")

        return ScenarioResult(
            name: name,
            clientCount: 2,
            clientsOpened: 2,
            clientsWithFirstByte: [answeredUDP, answeredTCP].filter { $0 }.count,
            clientsClosedEarly: [answeredUDP, answeredTCP].filter { !$0 }.count,
            totalBytes: (udpAnswer?.count ?? 0) + (tcpAnswer?.count ?? 0),
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("UDP and TCP share a fresh port", passA),
                .init("one retry event names the port given up", passB),
                .init("both transports of the new pair answer", passC),
            ],
            notes: notes
        )
    }

    @MainActor
    static func dohBlockedStillAnswers(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsDoHBlockedStillAnswers"
        let start = Date()
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let blockingProvider = FakeBlockingDoHProvider(group: group)
        ScenarioCleanup.register { await blockingProvider.stop() }
        try await blockingProvider.start()
        notes.append("fake DoH provider on 127.0.0.1:\(blockingProvider.port) answering 404 to every request")

        var config = ProxyConfig.testFixture()
        config.dnsEntries = [
            DomainDNSEntry(domain: "internal.test", servers: [unreachableInternalDNS], enabled: true)
        ]
        config.dohProviders = ["http://127.0.0.1:\(blockingProvider.port)/dns-query"]
        // No upstreams and no local listener in this sim, so the proxied routes
        // fail fast and the direct route is what reaches the fake provider.
        config.upstreams = []
        let frozen = config

        let forwarder = LocalDNSForwarder(
            group: group,
            logger: logger,
            configProvider: { frozen }
        )
        ScenarioCleanup.register { await forwarder.stop() }
        try await forwarder.start(host: "127.0.0.1", port: 0)


        let udpPort = forwarder.listeningPort ?? 0
        let tcpPort = forwarder.tcpListeningPort ?? 0
        notes.append("forwarder bound udp=\(udpPort) tcp=\(tcpPort)")

        let query = DNSWireFormat.buildQuery(domain: "public.example.com", txID: 0x5150, qtype: 1)

        // ── Case A: a public name, internal DNS dead, DoH blocked ──
        let udpAnswer = try await DNSProbe.overUDP(query: query, port: udpPort, timeout: 12)
        let answeredUDP = udpAnswer.map { DNSWireFormat.responseQuestionMatches(query: query, response: $0) } ?? false
        let rcodeUDP = udpAnswer.map { Int($0[3] & 0x0F) } ?? -1
        notes.append("A udp: answered=\(answeredUDP) rcode=\(rcodeUDP) (expected an answer, not silence)")
        let passA = answeredUDP

        // ── Case B: the failure is explained exactly once, with the status ──
        let dohWarnings = logger.entries().filter {
            $0.level == .warning && $0.message.contains("DoH provider(s) failed")
        }
        let namesStatus = dohWarnings.contains { $0.message.contains("404") }
        notes.append("B log: warnings=\(dohWarnings.count) namesHTTP404=\(namesStatus)")
        if let first = dohWarnings.first {
            notes.append("B message: \(first.message)")
        }
        let passB = !dohWarnings.isEmpty && namesStatus

        // ── Case C: the same query over TCP ──
        let tcpAnswer = try await DNSProbe.overTCP(query: query, port: tcpPort, timeout: 12)
        let answeredTCP = tcpAnswer.map { DNSWireFormat.responseQuestionMatches(query: query, response: $0) } ?? false
        notes.append("C tcp: answered=\(answeredTCP)")
        let passC = answeredTCP

        let pass = passA && passB && passC
        notes.append("A=\(verdict(passA)) B=\(verdict(passB)) C=\(verdict(passC))")
        notes.append(pass
            ? "PASS — a blocked-DoH network gets an immediate answer on both transports, and one log line naming the HTTP status"
            : "FAIL — see per-case lines above")

        return ScenarioResult(
            name: name,
            clientCount: 3,
            clientsOpened: 3,
            clientsWithFirstByte: [passA, passB, passC].filter { $0 }.count,
            clientsClosedEarly: [passA, passB, passC].filter { !$0 }.count,
            totalBytes: (udpAnswer?.count ?? 0) + (tcpAnswer?.count ?? 0),
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("UDP receives a matching answer", passA),
                .init("blocked DoH diagnostic names HTTP status", passB),
                .init("TCP receives a matching answer", passC),
            ],
            notes: notes
        )
    }

    /// `pm-sim dns-upstream-spoof`. The internal DNS server's socket answers
    /// every query three times: first with a wrong transaction ID, then with
    /// QR clear, both carrying the attacker's address, then genuinely. That
    /// is what a spoofer who has the server's address and the forwarder's
    /// ephemeral port can send; only the transaction ID and QR stand between
    /// it and the client or the cache.
    ///
    /// | # | condition                                   | expected                          |
    /// |---|---------------------------------------------|-----------------------------------|
    /// | A | internal name, forgeries arrive first       | genuine answer, client's own ID   |
    /// | B | external name, forgeries arrive first       | genuine answer                    |
    /// | C | the same external name again (cache hit)    | genuine answer; cache not poisoned|
    /// | D | the forgeries are reported                  | a "possible spoof" warning        |
    /// | E | the wire ID is the forwarder's, not the client's | random per query             |
    @MainActor
    static func upstreamSpoofRejected(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsUpstreamSpoofRejected"
        let start = Date()
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let spoofer = SpoofingDNSServer(genuineIP: genuineIP, forgedIP: forgedIP)
        let server = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(spoofer) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        ScenarioCleanup.register { _ = try? await server.close().get() }
        let serverPort = server.localAddress?.port ?? 0
        notes.append("spoofing internal DNS on 127.0.0.1:\(serverPort)")

        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "internal.test", servers: ["127.0.0.1"], enabled: true)]
        // Never consulted: the internal server answers external names too, so
        // nothing falls through to DoH. Loopback port 9 keeps it off the network.
        config.dohProviders = ["http://127.0.0.1:9/dns-query"]
        config.upstreams = []
        let frozen = config
        var tuning = DNSForwarderTuning()
        tuning.internalServerPort = serverPort

        let forwarder = LocalDNSForwarder(group: group, logger: logger, configProvider: { frozen }, tuning: tuning)
        ScenarioCleanup.register { await forwarder.stop() }
        try await forwarder.start(host: "127.0.0.1", port: 0)
        let udpPort = forwarder.listeningPort ?? 0

        func answer(_ domain: String, txID: UInt16) async throws -> (ip: String?, sameID: Bool) {
            let query = DNSWireFormat.buildQuery(domain: domain, txID: txID, qtype: 1)
            guard let response = try await DNSProbe.overUDP(query: query, port: udpPort, timeout: 5),
                  DNSWireFormat.responseQuestionMatches(query: query, response: response) else {
                return (nil, false)
            }
            return (DNSWireFormat.firstIPv4Answer(in: response)?.ip, response[0] == query[0] && response[1] == query[1])
        }

        let a = try await answer("host.internal.test", txID: 0x5150)
        notes.append("A internal: ip=\(a.ip ?? "none") sameID=\(a.sameID)")
        let passA = a.ip == genuineIP && a.sameID

        let b = try await answer("public.example.com", txID: 0x6160)
        notes.append("B external: ip=\(b.ip ?? "none") sameID=\(b.sameID)")
        let passB = b.ip == genuineIP && b.sameID

        let queriesBeforeC = spoofer.queryCount
        let c = try await answer("public.example.com", txID: 0x7170)
        let servedFromCache = spoofer.queryCount == queriesBeforeC
        notes.append("C cached: ip=\(c.ip ?? "none") sameID=\(c.sameID) fromCache=\(servedFromCache)")
        let passC = c.ip == genuineIP && c.sameID && servedFromCache

        let spoofWarnings = logger.entries().filter { $0.level == .warning && $0.message.contains("possible spoof") }
        notes.append("D warnings=\(spoofWarnings.count)")
        let passD = spoofWarnings.count >= 2

        let wireIDs = spoofer.wireIDs
        notes.append("E wire IDs: \(wireIDs.map { String(format: "0x%04X", $0) })")
        let passE = wireIDs.count == 2 && !wireIDs.contains(0x5150) && !wireIDs.contains(0x6160)

        let checks = [passA, passB, passC, passD, passE]
        notes.append(checks.allSatisfy { $0 }
            ? "PASS — forged replies from the server's own address are dropped, never answered and never cached"
            : "FAIL — see per-case lines above")

        return ScenarioResult(
            name: name,
            clientCount: 3,
            clientsOpened: 3,
            clientsWithFirstByte: [a.ip, b.ip, c.ip].compactMap { $0 }.count,
            clientsClosedEarly: [a.ip, b.ip, c.ip].filter { $0 == nil }.count,
            totalBytes: 0,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: 0, maxBytes: 0, medianBytes: 0,
            earliestClose: nil, latestClose: nil,
            assertions: [
                .init("an internal name gets the genuine answer under the client's ID", passA),
                .init("an external name gets the genuine answer", passB),
                .init("the cache holds the genuine answer", passC),
                .init("discarded forgeries are reported", passD),
                .init("the forwarder sends its own random transaction ID", passE),
            ],
            notes: notes
        )
    }

    private static let genuineIP = "10.20.30.40"
    private static let forgedIP = "203.0.113.66"

    private static func verdict(_ pass: Bool) -> String { pass ? "pass" : "FAIL" }
}

// MARK: - Spoofing internal DNS server

/// Answers each query with a wrong-ID forgery, a QR-clear forgery, then the
/// genuine reply 50 ms later, all from its own socket.
private final class SpoofingDNSServer: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let genuineIP: String
    private let forgedIP: String
    private let seen = NIOLockedValueBox<[UInt16]>([])

    var queryCount: Int { seen.withLockedValue { $0.count } }
    var wireIDs: [UInt16] { seen.withLockedValue { $0 } }

    init(genuineIP: String, forgedIP: String) {
        self.genuineIP = genuineIP
        self.forgedIP = forgedIP
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buffer = envelope.data
        let query = buffer.readBytes(length: buffer.readableBytes) ?? []
        guard query.count >= 12 else { return }
        seen.withLockedValue { if $0.count < 64 { $0.append(UInt16(query[0]) << 8 | UInt16(query[1])) } }

        guard var wrongID = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: forgedIP),
              var queryShaped = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: forgedIP),
              let genuine = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: genuineIP) else { return }
        wrongID[1] ^= 0x01
        queryShaped[2] &= 0x7F

        let channel = context.channel
        let remote = envelope.remoteAddress
        @Sendable func send(_ bytes: [UInt8]) {
            var out = channel.allocator.buffer(capacity: bytes.count)
            out.writeBytes(bytes)
            channel.writeAndFlush(AddressedEnvelope(remoteAddress: remote, data: out), promise: nil)
        }
        send(wrongID)
        send(queryShaped)
        channel.eventLoop.scheduleTask(in: .milliseconds(50)) { send(genuine) }
    }
}

// MARK: - Fake provider

/// Answers every HTTP request with a 404 and a block-page body — what a
/// filtering corporate proxy substitutes for a DoH endpoint it has
/// categorized.
private final class FakeBlockingDoHProvider: @unchecked Sendable {
    private let group: EventLoopGroup
    private var channel: Channel?

    var port: Int { channel?.localAddress?.port ?? 0 }

    init(group: EventLoopGroup) {
        self.group = group
    }

    func start() async throws {
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BlockPageHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() async {
        _ = try? await channel?.close().get()
        channel = nil
    }
}

private final class BlockPageHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var responded = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !responded else { return }
        responded = true

        let body = "<HTML><HEAD><TITLE>Web Site does not exist</TITLE></HEAD><BODY></BODY></HTML>"
        let response = """
            HTTP/1.1 404 Not Found\r
            Content-Type: text/html; charset=utf-8\r
            Content-Length: \(body.utf8.count)\r
            Connection: close\r
            \r
            \(body)
            """

        let channel = context.channel
        var buffer = channel.allocator.buffer(capacity: response.utf8.count)
        buffer.writeString(response)
        // Capture the channel, not the context: `ChannelHandlerContext` is not
        // Sendable and must not cross into the completion closure.
        context.writeAndFlush(wrapOutboundOut(buffer)).whenComplete { _ in
            channel.close(promise: nil)
        }
    }
}

// MARK: - Log sink that both prints and records

/// `ConsoleLogSink` for the operator running the sim, plus retention so the
/// scenario can assert on what was logged. The log line *is* the behaviour
/// under test in case B, so it has to be inspectable.
private final class RecordingConsoleLogSink: LogSink, @unchecked Sendable {
    struct Entry {
        let level: LogLevel
        let message: String
    }

    private let console: ConsoleLogSink
    private let stored = NIOLockedValueBox<[Entry]>([])

    /// Always retain from `.debug` up regardless of what the console prints,
    /// so `--verbose` does not change what the scenario can assert on.
    let minLevel: LogLevel = .debug

    init(minLevel: LogLevel) {
        self.console = ConsoleLogSink(minLevel: minLevel)
    }

    /// Retention is synchronous, so only the console can have lines pending.
    func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome { await console.drain(until: deadline) }

    func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        stored.withLockedValue { $0.append(Entry(level: level, message: message)) }
        guard level >= console.minLevel else { return }
        console.logImpl(level, message, category: category)
    }

    func entries() -> [Entry] {
        stored.withLockedValue { $0 }
    }
}

// MARK: - Raw DNS probes

/// Plain BSD sockets on purpose: these assert bytes on the wire, so they must
/// not share framing code with the implementation under test.
private enum DNSProbe {

    static func overUDP(query: [UInt8], port: Int, timeout: Int) async throws -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        let sent = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                query.withUnsafeBytes {
                    sendto(fd, $0.baseAddress, query.count, 0, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        guard sent > 0 else { return nil }

        var scratch = [UInt8](repeating: 0, count: 4096)
        let received = recv(fd, &scratch, scratch.count, 0)
        guard received > 0 else { return nil }
        return Array(scratch[0..<received])
    }

    static func overTCP(query: [UInt8], port: Int, timeout: Int) async throws -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return nil }

        var tv = timeval(tv_sec: timeout, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var framed = [UInt8]([UInt8(query.count >> 8), UInt8(query.count & 0xFF)])
        framed.append(contentsOf: query)
        _ = framed.withUnsafeBytes { send(fd, $0.baseAddress, framed.count, 0) }

        var buffer = [UInt8]()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while buffer.count < 2 || buffer.count < 2 + (Int(buffer[0]) << 8 | Int(buffer[1])) {
            let received = recv(fd, &scratch, scratch.count, 0)
            guard received > 0 else { return nil }
            buffer.append(contentsOf: scratch[0..<received])
        }
        let length = Int(buffer[0]) << 8 | Int(buffer[1])
        return Array(buffer[2..<(2 + length)])
    }
}
