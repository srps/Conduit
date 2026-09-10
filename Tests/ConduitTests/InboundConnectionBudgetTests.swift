// SPDX-License-Identifier: Apache-2.0
import XCTest
import NIOEmbedded
import NIOCore
@testable import ProxyKernel

final class InboundConnectionBudgetTests: XCTestCase {
    func testCombinedBudgetTracksChannelLifetimeAndLiveLimitReduction() throws {
        let budget = InboundConnectionBudget()
        let events = RuntimeEventLog(capacity: 8)
        let logger = RecordingLogSink()
        var config = GenericDefaults.shared.makeConfig()
        config.inboundConnectionMaxLimit = 2
        config.inboundConnectionWarnThreshold = 1
        let http = EmbeddedChannel()
        let socks = EmbeddedChannel()
        let rejected = EmbeddedChannel()
        XCTAssertTrue(budget.admit(http, protocolName: "http", config: config, logger: logger, eventSink: events.append))
        XCTAssertTrue(budget.admit(socks, protocolName: "socks5", config: config, logger: logger, eventSink: events.append))
        XCTAssertFalse(budget.admit(rejected, protocolName: "socks5", config: config, logger: logger, eventSink: events.append))
        XCTAssertEqual(budget.count, 2)
        // A failed/rejected pipeline has no reservation to release.
        try rejected.close().wait()
        rejected.embeddedEventLoop.run()
        XCTAssertEqual(budget.count, 2)
        config.inboundConnectionMaxLimit = 1
        try http.close().wait()
        http.embeddedEventLoop.run()
        XCTAssertEqual(budget.count, 1)
        let replacement = EmbeddedChannel()
        XCTAssertFalse(budget.admit(replacement, protocolName: "http", config: config, logger: logger, eventSink: events.append))
        try socks.close().wait()
        socks.embeddedEventLoop.run()
        XCTAssertEqual(budget.count, 0)
        XCTAssertTrue(budget.admit(replacement, protocolName: "http", config: config, logger: logger, eventSink: events.append))
        try replacement.close().wait()
        replacement.embeddedEventLoop.run()
        XCTAssertEqual(budget.count, 0)
        XCTAssertEqual(events.events.filter { $0.event == "connection.inbound_limit_rejected" }.count, 2)
    }
    func testSOCKSRequestDeadlineDoesNotResetAfterProgress() throws {
        let loop = EmbeddedEventLoop()
        let events = RuntimeEventLog(capacity: 8)
        let channel = try makeSOCKSChannel(loop: loop, events: events)
        var bytes = channel.allocator.buffer(capacity: 4)
        bytes.writeBytes([UInt8(5), 1, 0, 5])
        try channel.writeInbound(bytes)
        loop.advanceTime(by: .milliseconds(600))
        bytes.clear()
        bytes.writeBytes([UInt8(1)])
        try channel.writeInbound(bytes)
        loop.advanceTime(by: .milliseconds(399))
        XCTAssertFalse(events.events.contains { $0.event == "connection.socks5_handshake_timeout" })
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(events.events.filter { $0.event == "connection.socks5_handshake_timeout" }.count, 1)
        loop.advanceTime(by: .seconds(10))
        XCTAssertEqual(events.events.filter { $0.event == "connection.socks5_handshake_timeout" }.count, 1)
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    func testSOCKSOversizedNegotiationClosesWithoutWaitingForDeadline() throws {
        let loop = EmbeddedEventLoop()
        let events = RuntimeEventLog(capacity: 8)
        let channel = try makeSOCKSChannel(loop: loop, events: events)
        var bytes = channel.allocator.buffer(capacity: 520)
        bytes.writeRepeatingByte(0, count: 520)
        try channel.writeInbound(bytes)
        XCTAssertTrue(events.events.contains { $0.event == "connection.socks5_handshake_oversized" })
        loop.advanceTime(by: .seconds(2))
        XCTAssertFalse(events.events.contains { $0.event == "connection.socks5_handshake_timeout" })
        _ = try channel.finish(acceptAlreadyClosed: true)
    }

    func testSOCKSOversizedPipelinedPayloadPreservesGreetingReply() throws {
        // Cover coalescing, a split header, and the maximum 255-method list
        // split before its last method. None may start request routing.
        for (methodCount, prefixLength) in [(1, 0), (1, 1), (1, 2), (255, 256)] {
            let loop = EmbeddedEventLoop()
            let events = RuntimeEventLog(capacity: 8)
            let channel = try makeSOCKSChannel(loop: loop, events: events)
            var bytes = channel.allocator.buffer(capacity: 1040)
            let greeting: [UInt8] = [5, UInt8(methodCount)] + Array(repeating: 0, count: methodCount)
            if prefixLength > 0 {
                bytes.writeBytes(greeting.prefix(prefixLength))
                try channel.writeInbound(bytes)
                XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self))
                bytes.clear()
            }
            bytes.writeBytes(greeting.dropFirst(prefixLength))
            bytes.writeBytes([UInt8(5), 1, 0, 1, 127, 0, 0, 1, 0, 80])
            bytes.writeRepeatingByte(0x41, count: 1024)
            try channel.writeInbound(bytes)
            let reply = try channel.readOutbound(as: ByteBuffer.self)
            XCTAssertEqual(reply.map { Array($0.readableBytesView) }, [5, 0])
            XCTAssertNil(try channel.readOutbound(as: ByteBuffer.self), "Early payload must not receive CONNECT success")
            XCTAssertTrue(events.events.contains { $0.event == "connection.socks5_handshake_oversized" })
            loop.advanceTime(by: .seconds(2))
            XCTAssertFalse(events.events.contains { $0.event == "connection.socks5_handshake_timeout" })
            _ = try channel.finish(acceptAlreadyClosed: true)
        }
    }

    private func makeSOCKSChannel(loop: EmbeddedEventLoop, events: RuntimeEventLog) throws -> EmbeddedChannel {
        let config = GenericDefaults.shared.makeConfig()
        let logger = DiscardingLogSink()
        let pool = ConnectionPool(group: loop, logger: logger, configProvider: { config },
                                  authenticatorProvider: { _ in throw CocoaError(.featureUnsupported) })
        let coordinator = CONNECTCoordinator(pool: pool,
            authenticatorProvider: { _ in throw CocoaError(.featureUnsupported) }, logger: logger)
        return EmbeddedChannel(handler: SOCKS5Handler(
            connectCoordinator: coordinator, logger: logger, group: loop,
            directModeProvider: { (true, .noUpstreamsConfigured) }, pacRoutingEngine: nil,
            configProvider: { config }, gatewayMode: false, handshakeTimeout: .seconds(1),
            eventSink: events.append, onConnectionOpened: { _ in XCTFail("Negotiation rejection started routing") }, onConnectionClosed: { _ in },
            onConnectionActivity: { _ in }
        ), loop: loop)
    }

}
