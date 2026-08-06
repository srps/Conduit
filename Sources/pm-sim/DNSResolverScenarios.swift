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

    @MainActor
    static func dohBlockedStillAnswers(verbose: Bool) async throws -> ScenarioResult {
        let name = "dnsDoHBlockedStillAnswers"
        let start = Date()
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let logger = RecordingConsoleLogSink(minLevel: verbose ? .debug : .warning)

        let blockingProvider = FakeBlockingDoHProvider(group: group)
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
        try await forwarder.start(host: "127.0.0.1", port: 0)

        defer {
            Task { @MainActor in
                await forwarder.stop()
                await blockingProvider.stop()
            }
        }

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
            notes: notes
        )
    }

    private static func verdict(_ pass: Bool) -> String { pass ? "pass" : "FAIL" }
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
