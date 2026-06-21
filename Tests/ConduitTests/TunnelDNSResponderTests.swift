// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class TunnelDNSResponderTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    // MARK: - TunnelDNSResponder

    @MainActor
    func testResponderReturnsARecordForRegisteredHostname() async throws {
        let logger = DiscardingLogSink()
        let elg = group!
        let responder = TunnelDNSResponder(group: elg, logger: logger)
        try await responder.start(host: "127.0.0.1", port: 0)
        defer { Task { await responder.stop() } }

        responder.updateHostnames(["cluster0.mongodb.net": "127.0.0.1"])

        let port = try responderPort(responder)
        let query = DNSWireFormat.buildQuery(domain: "cluster0.mongodb.net", txID: 0x1234, qtype: 1)
        let response = try await UDPTestHelper.send(query: query, to: "127.0.0.1", port: port, group: elg)

        XCTAssertNotNil(response)
        XCTAssertTrue(response!.count > 12, "Response should contain header + answer")
        XCTAssertEqual(response![0], 0x12)
        XCTAssertEqual(response![1], 0x34)
        let flags = UInt16(response![2]) << 8 | UInt16(response![3])
        XCTAssertEqual(flags & 0x000F, 0, "RCODE should be NOERROR")
        let answerCount = UInt16(response![6]) << 8 | UInt16(response![7])
        XCTAssertEqual(answerCount, 1, "Should have one answer record")
    }

    @MainActor
    func testResponderReturnsNODATAForAAAA() async throws {
        let logger = DiscardingLogSink()
        let elg = group!
        let responder = TunnelDNSResponder(group: elg, logger: logger)
        try await responder.start(host: "127.0.0.1", port: 0)
        defer { Task { await responder.stop() } }

        responder.updateHostnames(["example.com": "127.0.0.1"])

        let port = try responderPort(responder)
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0xABCD, qtype: 28)
        let response = try await UDPTestHelper.send(query: query, to: "127.0.0.1", port: port, group: elg)

        XCTAssertNotNil(response)
        let answerCount = UInt16(response![6]) << 8 | UInt16(response![7])
        XCTAssertEqual(answerCount, 0, "AAAA query should return NODATA (0 answers)")
        let rcode = response![3] & 0x0F
        XCTAssertEqual(rcode, 0, "RCODE should be NOERROR for NODATA")
    }

    @MainActor
    func testResponderReturnsREFUSEDForUnknownHostname() async throws {
        let logger = DiscardingLogSink()
        let elg = group!
        let responder = TunnelDNSResponder(group: elg, logger: logger)
        try await responder.start(host: "127.0.0.1", port: 0)
        defer { Task { await responder.stop() } }

        responder.updateHostnames(["known.host": "127.0.0.1"])

        let port = try responderPort(responder)
        let query = DNSWireFormat.buildQuery(domain: "unknown.host.example.com", txID: 0x5678, qtype: 1)
        let response = try await UDPTestHelper.send(query: query, to: "127.0.0.1", port: port, group: elg)

        XCTAssertNotNil(response)
        let rcode = response![3] & 0x0F
        XCTAssertEqual(rcode, 5, "Unknown hostname should return REFUSED")
    }

    @MainActor
    func testResponderHandlesCaseInsensitiveLookup() async throws {
        let logger = DiscardingLogSink()
        let elg = group!
        let responder = TunnelDNSResponder(group: elg, logger: logger)
        try await responder.start(host: "127.0.0.1", port: 0)
        defer { Task { await responder.stop() } }

        responder.updateHostnames(["cluster0.mongodb.net": "127.0.0.1"])

        let port = try responderPort(responder)
        let query = DNSWireFormat.buildQuery(domain: "Cluster0.MongoDB.NET", txID: 0x9999, qtype: 1)
        let response = try await UDPTestHelper.send(query: query, to: "127.0.0.1", port: port, group: elg)

        XCTAssertNotNil(response)
        let answerCount = UInt16(response![6]) << 8 | UInt16(response![7])
        XCTAssertEqual(answerCount, 1, "Lookup should be case-insensitive")
    }

    @MainActor
    func testResponderUpdatesHostnamesDynamically() async throws {
        let logger = DiscardingLogSink()
        let elg = group!
        let responder = TunnelDNSResponder(group: elg, logger: logger)
        try await responder.start(host: "127.0.0.1", port: 0)
        defer { Task { await responder.stop() } }

        let port = try responderPort(responder)

        responder.updateHostnames(["first.host": "127.0.0.1"])
        let query1 = DNSWireFormat.buildQuery(domain: "first.host", txID: 0x0001, qtype: 1)
        let resp1 = try await UDPTestHelper.send(query: query1, to: "127.0.0.1", port: port, group: elg)
        XCTAssertEqual(UInt16(resp1![6]) << 8 | UInt16(resp1![7]), 1)

        responder.updateHostnames(["second.host": "127.0.0.1"])
        let query2 = DNSWireFormat.buildQuery(domain: "first.host", txID: 0x0002, qtype: 1)
        let resp2 = try await UDPTestHelper.send(query: query2, to: "127.0.0.1", port: port, group: elg)
        XCTAssertEqual(resp2![3] & 0x0F, 5, "Old hostname should now be REFUSED")

        let query3 = DNSWireFormat.buildQuery(domain: "second.host", txID: 0x0003, qtype: 1)
        let resp3 = try await UDPTestHelper.send(query: query3, to: "127.0.0.1", port: port, group: elg)
        XCTAssertEqual(UInt16(resp3![6]) << 8 | UInt16(resp3![7]), 1, "New hostname should resolve")
    }

    // MARK: - DNSWireFormat.synthesizeDirectResponse

    func testSynthesizeDirectResponseA() {
        let query = DNSWireFormat.buildQuery(domain: "test.example.com", txID: 0xBEEF, qtype: 1)
        let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "127.0.0.1")
        XCTAssertNotNil(response)
        let bytes = response!
        XCTAssertEqual(bytes[0], 0xBE)
        XCTAssertEqual(bytes[1], 0xEF)
        let answerCount = UInt16(bytes[6]) << 8 | UInt16(bytes[7])
        XCTAssertEqual(answerCount, 1)
        let lastFour = Array(bytes.suffix(4))
        XCTAssertEqual(lastFour, [127, 0, 0, 1])
    }

    func testSynthesizeDirectResponseAAAAReturnsNODATA() {
        let query = DNSWireFormat.buildQuery(domain: "test.example.com", txID: 0xCAFE, qtype: 28)
        let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "127.0.0.1")
        XCTAssertNotNil(response)
        let answerCount = UInt16(response![6]) << 8 | UInt16(response![7])
        XCTAssertEqual(answerCount, 0, "AAAA should return NODATA")
        XCTAssertEqual(response![3] & 0x0F, 0, "RCODE should be 0 (NOERROR)")
    }

    func testSynthesizeDirectResponseInvalidIPReturnsNil() {
        let query = DNSWireFormat.buildQuery(domain: "test.example.com", qtype: 1)
        XCTAssertNil(DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "not-an-ip"))
    }

    // MARK: - TunnelResolverManager with Recording

    @MainActor
    func testResolverManagerApplyCallsApplyDNSWithPort() throws {
        let recording = TestPrivilegeClient()
        let logger = DiscardingLogSink()
        let manager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        try manager.apply(hostname: "cluster0.mongodb.net", listenIP: "127.0.0.1")

        let commands = recording.executedCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].0, .applyDNS)
        XCTAssertEqual(commands[0].1[0], "cluster0.mongodb.net")
        XCTAssertEqual(commands[0].1[1], "127.0.0.1")
        XCTAssertEqual(commands[0].1[2], "15053")
    }

    @MainActor
    func testResolverManagerRemoveCallsRemoveDNS() throws {
        let recording = TestPrivilegeClient()
        let logger = DiscardingLogSink()
        let manager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        try manager.remove(hostname: "cluster0.mongodb.net")

        let commands = recording.executedCommands
        XCTAssertEqual(commands.count, 1)
        XCTAssertEqual(commands[0].0, .removeDNS)
        XCTAssertEqual(commands[0].1, ["cluster0.mongodb.net"])
    }

    @MainActor
    func testResolverManagerApplyAllTracksSuccessAndFailure() {
        let recording = TestPrivilegeClient()
        recording.failingDomains.insert("bad.host")
        let logger = DiscardingLogSink()
        let manager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        let result = manager.applyAll(hostnames: ["good.host", "bad.host", "another.host"], listenIP: "127.0.0.1")

        XCTAssertEqual(result.succeeded.sorted(), ["another.host", "good.host"])
        XCTAssertEqual(result.failed, ["bad.host"])
    }

    // MARK: - Wire format contract: A response IP bytes

    func testSynthesizeDirectResponseContainsExactIPBytes() {
        let query = DNSWireFormat.buildQuery(domain: "db.example.com", txID: 0x4444, qtype: 1)
        let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "10.20.30.40")!
        let lastFour = Array(response.suffix(4))
        XCTAssertEqual(lastFour, [10, 20, 30, 40])
    }

    func testSynthesizeDirectResponseNonANonAAAAReturnsREFUSED() {
        let query = DNSWireFormat.buildQuery(domain: "example.com", txID: 0x7777, qtype: 15)
        let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "127.0.0.1")
        XCTAssertNotNil(response)
        XCTAssertEqual(response![3] & 0x0F, 5, "MX query (qtype 15) should return REFUSED")
    }

    func testSynthesizeDirectResponsePreservesTxID() {
        for txID: UInt16 in [0x0000, 0xFFFF, 0xDEAD] {
            let query = DNSWireFormat.buildQuery(domain: "x.y", txID: txID, qtype: 1)
            let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "1.2.3.4")!
            let responseTxID = UInt16(response[0]) << 8 | UInt16(response[1])
            XCTAssertEqual(responseTxID, txID, "Transaction ID must be preserved")
        }
    }

    func testEmptyRefusedResponseHasCorrectRCODE() {
        let query = DNSWireFormat.buildQuery(domain: "refused.test", txID: 0x1111)
        let response = DNSWireFormat.emptyRefusedResponse(originalQuery: query)
        XCTAssertNotNil(response)
        XCTAssertEqual(response![3] & 0x0F, 5, "RCODE must be 5 (REFUSED)")
        let answerCount = UInt16(response![6]) << 8 | UInt16(response![7])
        XCTAssertEqual(answerCount, 0, "REFUSED response must have 0 answers")
    }

    // MARK: - TunnelDNSOverrideStatus flow

    func testDNSOverrideStatusNotNeededForDirectTunnels() {
        let result = TunnelStartResult(started: 1, failed: 0, boundPorts: [27017])
        XCTAssertEqual(result.dnsOverrideStatus, .notNeeded)
    }

    // MARK: - Resolver manager port parameter contract

    @MainActor
    func testResolverManagerPortValueIsAlways15053() throws {
        let recording = TestPrivilegeClient()
        let logger = DiscardingLogSink()
        let manager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        try manager.apply(hostname: "a.example.com", listenIP: "127.0.0.1")
        try manager.apply(hostname: "b.example.com", listenIP: "127.0.0.1")

        for cmd in recording.executedCommands {
            XCTAssertEqual(cmd.0, .applyDNS)
            XCTAssertEqual(cmd.1[2], "15053", "Port parameter must always be 15053")
        }
    }

    @MainActor
    func testResolverManagerRemoveAllCleansUpAfterApplyAll() {
        let recording = TestPrivilegeClient()
        let logger = DiscardingLogSink()
        let manager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        let hostnames = ["x.host", "y.host"]
        let result = manager.applyAll(hostnames: hostnames, listenIP: "127.0.0.1")
        XCTAssertEqual(result.succeeded.count, 2)

        manager.removeAll(hostnames: result.succeeded)

        let removes = recording.executedCommands.filter { $0.0 == .removeDNS }
        XCTAssertEqual(removes.count, 2)
        let removedDomains = Set(removes.map { $0.1[0] })
        XCTAssertEqual(removedDomains, Set(hostnames))
    }

    // MARK: - Helpers

    private nonisolated func responderPort(_ responder: TunnelDNSResponder) throws -> Int {
        let mirror = Mirror(reflecting: responder)
        guard let channel = mirror.children.first(where: { $0.label == "channel" })?.value as? Channel?,
              let port = channel?.localAddress?.port else {
            throw XCTSkip("Cannot reflect channel port")
        }
        return port
    }
}

private enum UDPTestHelper {
    static func send(query: [UInt8], to host: String, port: Int, group: EventLoopGroup) async throws -> [UInt8]? {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8]?, Error>) in
            let handler = UDPTestCollector(continuation: continuation)
            DatagramBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(handler)
                }
                .bind(host: "127.0.0.1", port: 0)
                .whenComplete { result in
                    switch result {
                    case .success(let channel):
                        guard let addr = try? SocketAddress(ipAddress: host, port: port) else {
                            continuation.resume(returning: nil)
                            return
                        }
                        var buf = channel.allocator.buffer(capacity: query.count)
                        buf.writeBytes(query)
                        let envelope = AddressedEnvelope(remoteAddress: addr, data: buf)
                        channel.writeAndFlush(envelope, promise: nil)

                        channel.eventLoop.scheduleTask(in: .seconds(2)) {
                            handler.timeout()
                            channel.close(promise: nil)
                        }
                    case .failure(let error):
                        continuation.resume(throwing: error)
                    }
                }
        }
    }
}

private final class UDPTestCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    private var continuation: CheckedContinuation<[UInt8]?, Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<[UInt8]?, Error>) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buf = envelope.data
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        lock.withLock {
            continuation?.resume(returning: bytes)
            continuation = nil
        }
        context.close(promise: nil)
    }

    func timeout() {
        lock.withLock {
            continuation?.resume(returning: nil)
            continuation = nil
        }
    }
}

private final class TestPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []
    var failingDomains: Set<String> = []

    var executedCommands: [(PrivilegedOperation, [String])] {
        lock.withLock { _commands }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        lock.withLock { _commands.append((operation, values)) }
        if let domain = values.first, failingDomains.contains(domain) {
            throw PrivilegeClientError.executionFailed("Simulated failure for \(domain)")
        }
    }
}
