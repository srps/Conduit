// SPDX-License-Identifier: Apache-2.0
// Routing table for PAC outcomes (#50), through the real HTTP, CONNECT and
// SOCKS5 listeners.
//
// The origin and the upstream are separate servers that answer with their own
// name, so the response says which path a request took. The origin counts
// every connection it accepts: a "no usable answer" row must leave it at 0.

import Darwin
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

final class PACRoutingTableTests: XCTestCase {

    // MARK: - #50: every PAC outcome × listener × strict mode

    private struct Row {
        let name: String
        let answer: ScriptedPAC.Answer
        let nonStrict: Path
        let strict: Path
        /// `pac.no_usable_route` reason the row must report, if any.
        let reason: PACNoUsableReason?
    }

    private static let unsupportedProxy = "SOCKS 10.255.0.1:1080"

    private func rows(upstreamPort: Int) -> [Row] {
        let proxy = "PROXY 127.0.0.1:\(upstreamPort)"
        return [
            Row(name: "explicit DIRECT", answer: .entries(["DIRECT"]), nonStrict: .origin, strict: .origin, reason: nil),
            Row(name: "PROXY", answer: .entries([proxy]), nonStrict: .upstream, strict: .upstream, reason: nil),
            Row(name: "PROXY; DIRECT", answer: .entries([proxy, "DIRECT"]), nonStrict: .upstream, strict: .upstream, reason: nil),
            Row(name: "rejected then PROXY", answer: .entries([Self.unsupportedProxy, proxy]),
                nonStrict: .upstream, strict: .upstream, reason: nil),
            // A DIRECT promoted by removing a rejected proxy is a fallback.
            Row(name: "promoted DIRECT", answer: .entries([Self.unsupportedProxy, "DIRECT"]),
                nonStrict: .origin, strict: .upstream, reason: .unsupported),
            Row(name: "empty", answer: .entries([]), nonStrict: .upstream, strict: .upstream, reason: .empty),
            Row(name: "unsupported only", answer: .entries([Self.unsupportedProxy]),
                nonStrict: .upstream, strict: .upstream, reason: .unsupported),
            Row(name: "invalid only", answer: .entries(["PROXY 10.255.0.1:99999"]),
                nonStrict: .upstream, strict: .upstream, reason: .invalid),
            Row(name: "evaluation error", answer: .throwing, nonStrict: .upstream, strict: .upstream, reason: .evaluationFailed),
            Row(name: "timeout", answer: .hanging, nonStrict: .upstream, strict: .upstream, reason: .timeout),
            Row(name: "not loaded", answer: .notLoaded, nonStrict: .upstream, strict: .upstream, reason: .notLoaded),
            Row(name: "refused", answer: .refused, nonStrict: .upstream, strict: .upstream, reason: .refused),
        ]
    }

    func testEveryPACOutcomeRoutesPerTableOnEveryListener() async throws {
        let servers = try await Servers.start()
        defer { servers.stop() }
        for row in rows(upstreamPort: servers.upstream.port) {
            for strict in [false, true] {
                let expected = strict ? row.strict : row.nonStrict
                let label = "\(row.name) strict=\(strict)"
                let fixture = try await ProxyFixture.start(
                    servers: servers, strict: strict, pac: ScriptedPAC(row.answer)
                )
                // A reachable, cached origin: the shortcut would take it DIRECT
                // if it applied to a PAC answer.
                try await fixture.seedReachability(port: servers.origin.port, expected: true, origin: servers.origin)
                let acceptedBefore = servers.origin.accepted
                let probesBefore = fixture.detector.probeCount

                for listener in Listener.allCases {
                    let path = try fixture.request(listener, target: servers.origin.port)
                    XCTAssertEqual(path, expected, "\(label) \(listener)")
                }
                if expected == .upstream {
                    XCTAssertEqual(servers.origin.accepted - acceptedBefore, 0, "\(label): origin contacted directly")
                } else {
                    XCTAssertGreaterThanOrEqual(servers.origin.accepted - acceptedBefore, Listener.allCases.count, label)
                }
                XCTAssertEqual(fixture.detector.probeCount, probesBefore, "\(label): a PAC answer triggered a direct probe")
                let reasons = fixture.noUsableReasons()
                if let reason = row.reason, expected == .upstream {
                    XCTAssertTrue(reasons.contains(reason.rawValue), "\(label): \(reasons)")
                }
                if row.reason == nil {
                    XCTAssertEqual(reasons, [], "\(label)")
                }
                await fixture.stop()
            }
        }
        // Let every hung evaluation (two per listener set) finish.
        for _ in 0..<8 { ScriptedPAC.gate.signal() }
    }

    /// `forceProxyHosts` still skips PAC; `noProxyHosts` still bypasses it.
    func testForceProxyAndNoProxyPrecedenceIsUnchanged() async throws {
        let servers = try await Servers.start()
        defer { servers.stop() }
        for strict in [false, true] {
            let forced = try await ProxyFixture.start(
                servers: servers, strict: strict, pac: ScriptedPAC(.entries(["DIRECT"])),
                configure: { $0.forceProxyHosts = ["127.0.0.1"] }
            )
            let before = servers.origin.accepted
            for listener in Listener.allCases {
                XCTAssertEqual(try forced.request(listener, target: servers.origin.port), .upstream, "forced \(listener)")
            }
            XCTAssertEqual(servers.origin.accepted, before)
            XCTAssertEqual(forced.pac.evaluations, 0, "a forced request evaluated PAC")
            await forced.stop()

            let bypassed = try await ProxyFixture.start(
                servers: servers, strict: strict,
                pac: ScriptedPAC(.entries(["PROXY 127.0.0.1:\(servers.upstream.port)"])),
                configure: { $0.noProxyHosts = ["127.0.0.1"] }
            )
            for listener in Listener.allCases {
                XCTAssertEqual(try bypassed.request(listener, target: servers.origin.port), .origin, "no-proxy \(listener)")
            }
            await bypassed.stop()
        }
    }
}

// MARK: - Paths and listeners

private enum Path: Equatable, CustomStringConvertible {
    case origin, upstream, badGateway
    case other(String)

    var description: String {
        switch self {
        case .origin: "origin"
        case .upstream: "upstream"
        case .badGateway: "502"
        case .other(let text): "other(\(text.prefix(80)))"
        }
    }
}

private enum Listener: CaseIterable, CustomStringConvertible {
    case http, connect, socks5
    var description: String {
        switch self {
        case .http: "HTTP"
        case .connect: "CONNECT"
        case .socks5: "SOCKS5"
        }
    }
}

// MARK: - Scripted PAC

/// A PAC whose answer is scripted; `routeChain` is the real adapter's.
private final class ScriptedPAC: PacEvaluator, PacScriptEvaluating, @unchecked Sendable {
    enum Answer {
        case entries([String])
        case throwing
        /// Blocks until `release()`; the engine times out first.
        case hanging
        /// The script never loads.
        case notLoaded
        /// The engine admits no evaluation.
        case refused
    }

    /// Holds `.hanging` evaluations; released at the end of the test.
    static let gate = DispatchSemaphore(value: 0)

    let answer: Answer
    private let count = NIOLockedValueBox(0)
    var evaluations: Int { count.withLockedValue { $0 } }

    init(_ answer: Answer) { self.answer = answer }

    func fetchPAC(from _: String) async throws -> String {
        if case .notLoaded = answer { throw PACResolverError.fetchFailed("scripted: never loads") }
        return "scripted"
    }

    func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating { self }

    func resolveProxyChain(for _: URL) throws -> [String] {
        count.withLockedValue { $0 += 1 }
        switch answer {
        case .entries(let entries): return entries
        case .throwing: throw PACResolverError.evaluationFailed("scripted error")
        case .hanging:
            Self.gate.wait()
            return ["DIRECT"]
        case .notLoaded, .refused: return ["DIRECT"]
        }
    }

    func routeChain(for entries: [String]) -> PACChain {
        CFPACEvaluator().routeChain(for: entries)
    }
}

// MARK: - Origin and upstream

/// Answers each request head with its name. As an upstream it accepts
/// CONNECT and answers the tunnelled requests the same way.
private final class TaggedServer: @unchecked Sendable {
    let tag: String
    private let acceptedBox = NIOLockedValueBox(0)
    private let requestsBox = NIOLockedValueBox(0)
    private var channel: Channel?

    var accepted: Int { acceptedBox.withLockedValue { $0 } }
    var requests: Int { requestsBox.withLockedValue { $0 } }
    var port: Int { channel?.localAddress?.port ?? 0 }

    init(tag: String) { self.tag = tag }

    func start() async throws {
        let tag = self.tag
        let accepted = acceptedBox
        let requests = requestsBox
        channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                accepted.withLockedValue { $0 += 1 }
                return channel.pipeline.addHandler(TaggedHandler(tag: tag, requests: requests))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    func stop() {
        channel?.close(promise: nil)
    }
}

private final class TaggedHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let tag: String
    private let requests: NIOLockedValueBox<Int>
    private var pending = ""

    init(tag: String, requests: NIOLockedValueBox<Int>) {
        self.tag = tag
        self.requests = requests
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        while let end = pending.range(of: "\r\n\r\n") {
            let head = String(pending[..<end.lowerBound])
            pending = String(pending[end.upperBound...])
            requests.withLockedValue { $0 += 1 }
            let reply = head.hasPrefix("CONNECT ")
                ? "HTTP/1.1 200 Connection established\r\n\r\n"
                : "HTTP/1.1 200 OK\r\nContent-Length: \(tag.utf8.count + 2)\r\n\r\n<\(tag)"
                    + ">"
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: reply)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private struct Servers {
    let origin: TaggedServer
    let upstream: TaggedServer

    static func start() async throws -> Servers {
        let origin = TaggedServer(tag: "origin")
        let upstream = TaggedServer(tag: "upstream")
        try await origin.start()
        try await upstream.start()
        return Servers(origin: origin, upstream: upstream)
    }

    func stop() {
        origin.stop()
        upstream.stop()
    }

    /// A loopback port with nothing listening.
    static func closedPort() throws -> Int {
        let channel = try ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).wait()
        let port = channel.localAddress?.port ?? 0
        try channel.close().wait()
        return port
    }
}

// MARK: - Proxy under test

private final class ProxyFixture: @unchecked Sendable {
    let server: LocalProxyServer
    let detector: DirectConnectDetector
    let pac: ScriptedPAC
    private let eventsBox: NIOLockedValueBox<[RuntimeEvent]>

    private init(server: LocalProxyServer, detector: DirectConnectDetector, pac: ScriptedPAC,
                 events: NIOLockedValueBox<[RuntimeEvent]>) {
        self.server = server
        self.detector = detector
        self.pac = pac
        self.eventsBox = events
    }

    static func start(
        servers: Servers,
        strict: Bool,
        pac: ScriptedPAC?,
        upstreamPort: Int? = nil,
        configure: (inout ProxyConfig) -> Void = { _ in },
        onEvent: @escaping @Sendable (RuntimeEvent) -> Void = { _ in }
    ) async throws -> ProxyFixture {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        config.socksEnabled = true
        config.socksPort = 0
        config.localPACEnabled = false
        config.strictMode = strict
        config.pacRoutingEnabled = pac != nil
        config.pacURL = pac != nil ? "https://pac.example.test/scripted.pac" : ""
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.upstreams = [UpstreamProxy(
            name: "Upstream", host: "127.0.0.1", port: upstreamPort ?? servers.upstream.port, priority: 0
        )]
        configure(&config)
        let fixed = config

        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in
            events.withLockedValue { $0.append(event) }
            onEvent(event)
        }
        let scripted = pac ?? ScriptedPAC(.entries([]))
        var engine: PACRoutingEngine?
        if let pac {
            let refused: Bool
            if case .refused = pac.answer { refused = true } else { refused = false }
            let created = PACRoutingEngine(
                configProvider: { fixed },
                resolver: pac,
                refreshInterval: 300,
                evalTimeoutSeconds: 0.2,
                queuedEvaluationLimit: refused ? 0 : 64,
                eventSink: sink
            )
            if case .notLoaded = pac.answer {} else {
                try await created.refresh(force: true)
            }
            engine = created
        }
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), ttlSeconds: 300, baseTimeoutMS: 1_000
        )
        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { fixed },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in TableAuthenticator() },
            directConnectDetector: detector,
            pacRoutingEngine: engine,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in },
            eventSink: sink
        )
        try await server.start()
        return ProxyFixture(server: server, detector: detector, pac: scripted, events: events)
    }

    func stop() async {
        await server.stop()
    }

    func events(named name: String) -> [RuntimeEvent] {
        eventsBox.withLockedValue { $0 }.filter { $0.event == name }
    }

    func noUsableReasons() -> [String] {
        events(named: "pac.no_usable_route").compactMap { event in
            event.detail?.split(separator: " ").first { $0.hasPrefix("reason=") }.map { String($0.dropFirst(7)) }
        }
    }

    /// Cache a reachability result for `127.0.0.1:port` the way the shortcut
    /// would. For a reachable origin, wait until it has counted the probe
    /// connection, so the probe is not counted against a request.
    func seedReachability(port: Int, expected: Bool, origin: TaggedServer? = nil) async throws {
        let before = origin?.accepted ?? 0
        let reachable = await detector.isDirectlyReachable(host: "127.0.0.1", port: port)
        XCTAssertEqual(reachable, expected, "seeding 127.0.0.1:\(port)")
        guard let origin, expected else { return }
        for _ in 0..<500 where origin.accepted == before {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(origin.accepted, before + 1, "the seeding probe never reached the origin")
    }

    func request(_ listener: Listener, target: Int) throws -> Path {
        switch listener {
        case .http:
            let port = try XCTUnwrap(server.listeningPort)
            let socket = try BlockingSocket(port: port)
            try socket.send("GET http://127.0.0.1:\(target)/table HTTP/1.1\r\nHost: 127.0.0.1:\(target)\r\n\r\n")
            return Self.path(of: socket.readResponse())
        case .connect:
            let port = try XCTUnwrap(server.listeningPort)
            let socket = try BlockingSocket(port: port)
            try socket.send("CONNECT 127.0.0.1:\(target) HTTP/1.1\r\nHost: 127.0.0.1:\(target)\r\n\r\n")
            let head = socket.readUntil { $0.contains("\r\n\r\n") }
            guard head.hasPrefix("HTTP/1.1 200") else { return Self.path(of: head) }
            try socket.send("GET /table HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            return Self.path(of: socket.readResponse())
        case .socks5:
            let port = try XCTUnwrap(server.socksListeningPort)
            let socket = try BlockingSocket(port: port)
            try socket.send(bytes: [5, 1, 0])
            guard socket.readBytes(2) == [5, 0] else { return .other("SOCKS greeting refused") }
            try socket.send(bytes: [5, 1, 0, 1, 127, 0, 0, 1, UInt8(target >> 8), UInt8(target & 0xFF)])
            let reply = socket.readBytes(10)
            guard reply.count == 10, reply[1] == 0 else { return .badGateway }
            try socket.send("GET /table HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")
            return Self.path(of: socket.readResponse())
        }
    }

    private static func path(of response: String) -> Path {
        if response.contains("<origin>") { return .origin }
        if response.contains("<upstream>") { return .upstream }
        if response.hasPrefix("HTTP/1.1 502") { return .badGateway }
        return .other(response)
    }
}

private final class TableAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate table-token" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { true }
    func reset() {}
}

/// A blocking loopback client. Reads give up after 5 s, a bound that only a
/// broken build reaches; no assertion depends on it.
private final class BlockingSocket {
    private let fd: Int32

    init(port: Int) throws {
        fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    deinit { close(fd) }

    func send(_ text: String) throws {
        try send(bytes: Array(text.utf8))
    }

    func send(bytes: [UInt8]) throws {
        let written = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress, $0.count, 0) }
        guard written == bytes.count else { throw POSIXError(.EPIPE) }
    }

    private var buffered: [UInt8] = []

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 4096)
        let count = recv(fd, &chunk, chunk.count, 0)
        guard count > 0 else { return false }
        buffered += chunk.prefix(count)
        return true
    }

    func readBytes(_ count: Int) -> [UInt8] {
        while buffered.count < count, fill() {}
        let taken = Array(buffered.prefix(count))
        buffered.removeFirst(taken.count)
        return taken
    }

    func readUntil(_ done: (String) -> Bool) -> String {
        while !done(String(decoding: buffered, as: UTF8.self)), fill() {}
        let text = String(decoding: buffered, as: UTF8.self)
        buffered.removeAll()
        return text
    }

    /// One response: a tagged body, or a complete head of a non-200 status.
    func readResponse() -> String {
        readUntil { text in
            text.contains("<origin>") || text.contains("<upstream>")
                || (text.contains("\r\n\r\n") && !text.hasPrefix("HTTP/1.1 200"))
        }
    }
}
