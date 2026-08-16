// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The forwarder serves DNS over TCP as well as UDP.
///
/// Why TCP matters for a forwarder that only ever emits small answers: it is
/// not optional in the protocol. A resolver client is entitled to open with
/// TCP, and `getaddrinfo`/`dig` retry over TCP whenever a UDP answer comes back
/// truncated. Before this landed, `dig +tcp @127.0.0.1 -p 5053` was met with
/// `connection refused`, which reads as "the forwarder is down".
///
/// Framing is RFC 1035 §4.2.2: a 2-byte big-endian length prefix in both
/// directions.
final class DNSTCPListenerTests: XCTestCase {

    private func makeForwarder(
        logger: RecordingLogSink,
        tcpIdleTimeoutSeconds: Int64 = 2,
        tcpMaximumConnections: Int = 64,
        configure: (inout ProxyConfig) -> Void = { _ in }
    ) -> LocalDNSForwarder {
        var config = ProxyConfig.testFixture()
        configure(&config)
        let frozen = config
        return LocalDNSForwarder(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: logger,
            configProvider: { frozen },
            tcpIdleTimeoutSeconds: tcpIdleTimeoutSeconds,
            tcpMaximumConnections: tcpMaximumConnections
        )
    }

    /// Binding both listeners to port 0 independently would land them on two
    /// different ephemeral ports, so a client that retried over TCP would find
    /// nothing there. UDP binds first and TCP follows onto its port.
    @MainActor
    func testTCPAndUDPShareTheSamePortWhenBindingEphemeral() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = makeForwarder(logger: logger)

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }

        let udpPort = try XCTUnwrap(forwarder.listeningPort)
        let tcpPort = try XCTUnwrap(forwarder.tcpListeningPort, "TCP listener should be bound")
        XCTAssertNotEqual(udpPort, 0)
        XCTAssertEqual(udpPort, tcpPort)
    }

    /// An intercept rule is the one answer the forwarder synthesizes entirely
    /// on its own, so it exercises the TCP framing end to end without needing
    /// a reachable upstream nameserver.
    @MainActor
    func testInterceptedQueryRoundTripsOverTCP() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = makeForwarder(logger: logger) { config in
            config.dnsInterceptRules = [
                DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3.1", enabled: true)
            ]
        }

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        let query = DNSWireFormat.buildQuery(domain: "api.intercept.test", txID: 0x4242, qtype: 1)
        let response = try await Self.sendOverTCP(query: query, port: port)

        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: response))
        XCTAssertEqual(response[0], 0x42)
        XCTAssertEqual(response[1], 0x42)
        XCTAssertEqual(DNSWireFormat.firstIPv4Answer(in: response)?.ip, "127.44.3.1")
    }

    /// Two queries pipelined into one write must both be answered: reads are
    /// accumulated and drained message by message, not assumed to arrive one
    /// per `channelRead`.
    @MainActor
    func testTwoPipelinedQueriesAreBothAnswered() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = makeForwarder(logger: logger) { config in
            config.dnsInterceptRules = [
                DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3.1", enabled: true)
            ]
        }

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        let first = DNSWireFormat.buildQuery(domain: "a.intercept.test", txID: 0x0001, qtype: 1)
        let second = DNSWireFormat.buildQuery(domain: "b.intercept.test", txID: 0x0002, qtype: 1)

        var payload = Data()
        for query in [first, second] {
            payload.append(UInt8(query.count >> 8))
            payload.append(UInt8(query.count & 0xFF))
            payload.append(contentsOf: query)
        }

        let responses = try await Self.sendRaw(payload: payload, port: port, expectedMessages: 2)
        XCTAssertEqual(responses.count, 2)
        XCTAssertEqual(Set(responses.map { UInt16($0[0]) << 8 | UInt16($0[1]) }), [0x0001, 0x0002])
    }

    /// The 2-byte prefix permits 64 KiB. Without a cap a client could make the
    /// forwarder hold that much per connection by announcing a length it never
    /// sends, so an over-cap announcement closes the connection.
    @MainActor
    func testOversizedLengthPrefixClosesTheConnection() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = makeForwarder(logger: logger)

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        // Announce 60000 bytes and send none of them.
        let payload = Data([0xEA, 0x60])
        let closed = try await Self.expectConnectionClose(payload: payload, port: port)
        XCTAssertTrue(closed, "Connection should be closed rather than left buffering")

        let warned = logger.entries().contains {
            $0.level == .warning && $0.message.contains("exceeds the")
        }
        XCTAssertTrue(warned, "Over-cap framing should be logged, not silently dropped")
    }

    /// A client that has asked a question and is waiting is *silent*, and the
    /// idle timer cannot tell that apart from a client that has gone away. If
    /// it closes on the difference, the answer is written to a dead channel and
    /// the client gets the exact silence this forwarder exists to remove.
    ///
    /// Driven with a 1-second idle window against an unreachable internal
    /// nameserver, whose 1.5-second timeout alone outlasts it.
    @MainActor
    func testSlowLookupIsNotCutOffByTheIdleTimer() async throws {
        try XCTSkipIf(
            Self.networkAnswersForUnroutableDNS(),
            "This network transparently redirects outbound UDP/53, so the unreachable "
                + "nameserver this test depends on answers instantly and the lookup never "
                + "outlasts the idle window"
        )
        let logger = RecordingLogSink(minLevel: .debug)
        var config = ProxyConfig.testFixture()
        // TEST-NET-1: routes nowhere, so the internal attempt burns its full
        // 1.5 s before the DoH stage even begins.
        config.dnsEntries = [
            DomainDNSEntry(domain: "slow.test", servers: ["192.0.2.53"], enabled: true)
        ]
        config.dohProviders = ["https://192.0.2.1/dns-query"]
        let frozen = config

        let forwarder = LocalDNSForwarder(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: logger,
            configProvider: { frozen },
            tcpIdleTimeoutSeconds: 1
        )

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        let query = DNSWireFormat.buildQuery(domain: "host.slow.test", txID: 0x7777, qtype: 1)
        let response = try await Self.sendOverTCP(query: query, port: port)

        XCTAssertTrue(
            DNSWireFormat.responseQuestionMatches(query: query, response: response),
            "A lookup outlasting the idle window must still be answered"
        )
        XCTAssertEqual(response[3] & 0x0F, 2, "unreachable upstream should surface as SERVFAIL")
    }

    /// The connection is still bounded — an idle client with nothing pending
    /// gets closed once the window elapses.
    @MainActor
    func testIdleConnectionWithNothingPendingIsClosed() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = makeForwarder(logger: logger)

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        // Connect, send nothing at all, and wait out the window.
        let closed = try await Self.expectConnectionClose(payload: Data(), port: port)
        XCTAssertTrue(closed, "An idle connection with no outstanding query must be closed")
    }

    /// Closing the listener stops accepts but leaves the connections it already
    /// accepted alive, and each of those holds the resolution core — so a
    /// forwarder that reported itself stopped would go on answering those
    /// clients from the cache, internal DNS and intercept rules, and a restart
    /// would briefly run two resolvers side by side.
    @MainActor
    func testStopClosesConnectionsItAlreadyAccepted() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        // An idle window long enough that only `stop()` can explain the close.
        let forwarder = makeForwarder(logger: logger, tcpIdleTimeoutSeconds: 60) { config in
            config.dnsInterceptRules = [
                DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3.1", enabled: true)
            ]
        }

        try await forwarder.start(host: "127.0.0.1", port: 0)
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        let fd = try Self.openConnection(to: port)
        defer { close(fd) }
        // Answering a query proves the connection was accepted, not merely queued
        // in the listen backlog.
        let query = DNSWireFormat.buildQuery(domain: "held.intercept.test", txID: 0x1234, qtype: 1)
        _ = try Self.exchange(query: query, on: fd)

        await forwarder.stop()

        var scratch = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(
            recv(fd, &scratch, scratch.count, 0), 0,
            "stop() must close the connections the listener already accepted"
        )
    }

    /// Each accepted connection costs a buffer, a timer and a descriptor for the
    /// whole idle window even if the client never asks anything, and the
    /// in-flight resolution cap bounds lookups rather than sockets. Driven with
    /// a cap of two so the test does not open 64 sockets.
    @MainActor
    func testConnectionsBeyondTheCapAreRefused() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let forwarder = makeForwarder(logger: logger, tcpIdleTimeoutSeconds: 60, tcpMaximumConnections: 2) { config in
            config.dnsInterceptRules = [
                DNSInterceptRule(pattern: "*.intercept.test", interceptIP: "127.44.3.1", enabled: true)
            ]
        }

        try await forwarder.start(host: "127.0.0.1", port: 0)
        defer { Task { await forwarder.stop() } }
        let port = try XCTUnwrap(forwarder.tcpListeningPort)

        // Fill the cap, and make each connection answer so it is known to be
        // accepted (and therefore counted) before the next one is opened.
        var held = [Int32]()
        defer { held.forEach { close($0) } }
        for index in 0..<2 {
            let fd = try Self.openConnection(to: port)
            held.append(fd)
            let query = DNSWireFormat.buildQuery(domain: "h\(index).intercept.test", txID: 0x0100, qtype: 1)
            _ = try Self.exchange(query: query, on: fd)
        }

        let overCap = try Self.openConnection(to: port)
        defer { close(overCap) }
        var scratch = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(
            recv(overCap, &scratch, scratch.count, 0), 0,
            "A connection over the cap must be closed rather than served"
        )

        let warned = logger.entries().contains {
            $0.level == .warning && $0.message.contains("cap is already reached")
        }
        XCTAssertTrue(warned, "Refusing a connection must be reported, not silent")

        // The connections already inside the cap keep working.
        let query = DNSWireFormat.buildQuery(domain: "still.intercept.test", txID: 0x0200, qtype: 1)
        let response = try Self.exchange(query: query, on: try XCTUnwrap(held.first))
        XCTAssertTrue(DNSWireFormat.responseQuestionMatches(query: query, response: response))
    }

    // MARK: - Raw TCP helpers

    private static func sendOverTCP(query: [UInt8], port: Int) async throws -> [UInt8] {
        var payload = Data()
        payload.append(UInt8(query.count >> 8))
        payload.append(UInt8(query.count & 0xFF))
        payload.append(contentsOf: query)
        let messages = try await sendRaw(payload: payload, port: port, expectedMessages: 1)
        return try XCTUnwrap(messages.first)
    }

    /// Deliberately a plain BSD socket rather than a NIO client: this asserts
    /// the bytes on the wire, so it must not share framing code with the
    /// implementation under test.
    private static func sendRaw(payload: Data, port: Int, expectedMessages: Int) async throws -> [[UInt8]] {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
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
        XCTAssertEqual(connected, 0, "connect() failed: \(String(cString: strerror(errno)))")

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }

        var buffer = [UInt8]()
        var messages = [[UInt8]]()
        var scratch = [UInt8](repeating: 0, count: 4096)

        while messages.count < expectedMessages {
            let received = recv(fd, &scratch, scratch.count, 0)
            guard received > 0 else { break }
            buffer.append(contentsOf: scratch[0..<received])

            while buffer.count >= 2 {
                let length = Int(buffer[0]) << 8 | Int(buffer[1])
                guard buffer.count >= 2 + length else { break }
                messages.append(Array(buffer[2..<(2 + length)]))
                buffer.removeFirst(2 + length)
            }
        }

        return messages
    }

    /// A connected socket the caller keeps open, for the tests that care about
    /// connection lifetime rather than a single exchange.
    private static func openConnection(to port: Int) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(connected, 0, "connect() failed: \(String(cString: strerror(errno)))")

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return fd
    }

    /// One length-prefixed query out, one answer back, on an already-open socket.
    private static func exchange(query: [UInt8], on fd: Int32) throws -> [UInt8] {
        var payload = Data()
        payload.append(UInt8(query.count >> 8))
        payload.append(UInt8(query.count & 0xFF))
        payload.append(contentsOf: query)
        _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }

        var buffer = [UInt8]()
        var scratch = [UInt8](repeating: 0, count: 4096)
        while true {
            if buffer.count >= 2 {
                let length = Int(buffer[0]) << 8 | Int(buffer[1])
                if buffer.count >= 2 + length {
                    return Array(buffer[2..<(2 + length)])
                }
            }
            let received = recv(fd, &scratch, scratch.count, 0)
            guard received > 0 else {
                XCTFail("Connection closed or timed out before an answer arrived")
                return []
            }
            buffer.append(contentsOf: scratch[0..<received])
        }
    }

    private static func expectConnectionClose(payload: Data, port: Int) async throws -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
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
        XCTAssertEqual(connected, 0)

        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        _ = payload.withUnsafeBytes { send(fd, $0.baseAddress, payload.count, 0) }

        // A clean close surfaces as recv() returning 0 (EOF).
        var scratch = [UInt8](repeating: 0, count: 64)
        return recv(fd, &scratch, scratch.count, 0) == 0
    }

    /// Whether this network answers DNS sent to an address that routes nowhere.
    ///
    /// Home routers, hotel networks and ISPs commonly force DNS by redirecting
    /// *all* outbound UDP/53 to their own resolver regardless of destination
    /// address. On such a network, a query aimed at a documentation-range
    /// address comes back instantly — observed as an authoritative NXDOMAIN
    /// from a `192.0.2.x` "server", with the same address on port 5353 timing
    /// out normally, which is what identifies the redirect as port-based.
    ///
    /// Tests that need a genuinely unreachable nameserver have no way to get
    /// one there: the forwarder always queries port 53, so every candidate
    /// address is intercepted.
    private static func networkAnswersForUnroutableDNS() -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }

        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(53).bigEndian
        // TEST-NET-1 (RFC 5737): reserved for documentation, routed nowhere.
        addr.sin_addr.s_addr = inet_addr("192.0.2.53")

        let connected = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else { return false }

        let probe = DNSWireFormat.buildQuery(domain: "probe.invalid.test", txID: 0x5151, qtype: 1)
        _ = probe.withUnsafeBytes { send(fd, $0.baseAddress, probe.count, 0) }

        var scratch = [UInt8](repeating: 0, count: 512)
        return recv(fd, &scratch, scratch.count, 0) > 0
    }
}
