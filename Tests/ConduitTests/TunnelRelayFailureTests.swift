// SPDX-License-Identifier: Apache-2.0
import Darwin
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

final class TunnelRelayFailureTests: XCTestCase {
    /// Reject a syscall-like write without firing an inbound error. That is
    /// the contract of a failed outbound promise, not a read-side exception.
    private final class RejectWrite: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        let closeBeforeFailing: Bool
        init(closeBeforeFailing: Bool = false) { self.closeBeforeFailing = closeBeforeFailing }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if closeBeforeFailing { context.close(promise: nil) }
            promise?.fail(IOError(errnoCode: EADDRNOTAVAIL, reason: "injected retired VPN address"))
        }
    }

    private final class HoldWrites: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        private var held: [(NIOAny, EventLoopPromise<Void>?)] = []
        private var context: ChannelHandlerContext?
        func handlerAdded(context: ChannelHandlerContext) { self.context = context }
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            precondition(held.count < 4, "bounded fixture writes")
            held.append((data, promise))
        }
        func flush(context: ChannelHandlerContext) {}
        func release() {
            let context = self.context!
            let writes = held; held.removeAll()
            for (data, promise) in writes { context.write(data, promise: promise) }
            context.flush()
        }
        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            let writes = held; held.removeAll()
            context.close(mode: mode, promise: promise)
            for (_, pending) in writes { pending?.fail(ChannelError.ioOnClosedChannel) }
        }
    }

    /// A socket channel fails writes issued after close; EmbeddedChannel
    /// accepts them, which would hide a relay aborting on an orderly close.
    private final class FailWritesAfterClose: ChannelOutboundHandler {
        typealias OutboundIn = ByteBuffer
        private var closed = false
        func write(context: ChannelHandlerContext, data: NIOAny, promise: EventLoopPromise<Void>?) {
            if closed { promise?.fail(ChannelError.ioOnClosedChannel) } else { context.write(data, promise: promise) }
        }
        func close(context: ChannelHandlerContext, mode: CloseMode, promise: EventLoopPromise<Void>?) {
            closed = true
            context.close(mode: mode, promise: promise)
        }
    }

    private func activeChannel() throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        try channel.connect(to: SocketAddress(ipAddress: "127.0.0.1", port: 1234)).wait()
        return channel
    }

    private func attach(_ client: EmbeddedChannel, _ remote: EmbeddedChannel, events: RuntimeEventLog) throws {
        let diagnostics = TunnelRelayDiagnostics(target: "stream.test:443", transport: "connect", route: "upstream",
            upstream: "proxy.test:8080", causeProvider: { .none },
            reporter: TunnelFailureReporter(logger: DiscardingLogSink(), eventSink: { events.append($0) }))
        try client.pipeline.syncOperations.addHandler(TunnelRelayHandler(peer: remote, diagnostics: diagnostics, side: .client))
        try remote.pipeline.syncOperations.addHandler(TunnelRelayHandler(peer: client, diagnostics: diagnostics, side: .remote))
    }

    func testFailedWriteClosesBothHalvesAndReportsTheDestinationSocket() throws {
        let client = try activeChannel(), remote = try activeChannel()
        let events = RuntimeEventLog(capacity: 4)
        try remote.pipeline.syncOperations.addHandler(RejectWrite())
        try attach(client, remote, events: events)
        try client.writeInbound(ByteBuffer(string: "opaque TLS bytes"))
        client.embeddedEventLoop.run(); remote.embeddedEventLoop.run()
        XCTAssertFalse(client.isActive, "the browser must learn the established tunnel is unusable")
        XCTAssertFalse(remote.isActive)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertTrue(events.events.first?.detail?.contains("side=remote") == true)
        XCTAssertTrue(events.events.first?.detail?.contains("operation=write") == true)
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }

    func testFatalReadDoesNotWaitForTheOtherSocketsBlockedWrites() throws {
        let client = try activeChannel(), remote = try activeChannel()
        let held = HoldWrites(), events = RuntimeEventLog(capacity: 4)
        try client.pipeline.syncOperations.addHandler(held)
        try attach(client, remote, events: events)
        try remote.writeInbound(ByteBuffer(string: "queued response"))
        remote.pipeline.fireErrorCaught(IOError(errnoCode: EADDRNOTAVAIL, reason: "injected VPN address loss"))
        client.embeddedEventLoop.run(); remote.embeddedEventLoop.run()
        XCTAssertFalse(client.isActive, "fatal socket failure must bypass graceful drain")
        XCTAssertFalse(remote.isActive)
        XCTAssertEqual(events.events.count, 1)
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }

    func testOrderlyEOFStillDrainsTheCompleteQueuedResponse() throws {
        let client = try activeChannel(), remote = try activeChannel()
        let held = HoldWrites(), events = RuntimeEventLog(capacity: 4)
        try client.pipeline.syncOperations.addHandler(held)
        try remote.pipeline.syncOperations.addHandler(FailWritesAfterClose())
        try attach(client, remote, events: events)
        let response = ByteBuffer(string: "complete response tail")
        try remote.writeInbound(response)
        try remote.close().wait()
        XCTAssertTrue(client.isActive, "a normal FIN must preserve pending response data")
        // The client can become writable after the remote's normal EOF. Its
        // attempt to resume remote reads must not abort the queued response.
        client.pipeline.fireChannelWritabilityChanged()
        // Nor may client bytes sent while the tail drains (an HTTP/2
        // WINDOW_UPDATE, a TLS close_notify) that fail on the closed remote.
        try client.writeInbound(ByteBuffer(string: "window update"))
        client.embeddedEventLoop.run(); remote.embeddedEventLoop.run()
        XCTAssertTrue(client.isActive)
        held.release()
        client.embeddedEventLoop.run()
        XCTAssertEqual(try client.readOutbound(as: ByteBuffer.self), response)
        XCTAssertFalse(client.isActive)
        XCTAssertTrue(events.events.isEmpty)
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }

    func testGenuineWriteFailureStillAbortsWhenDestinationHasClosed() throws {
        let client = try activeChannel(), remote = try activeChannel()
        let held = HoldWrites(), events = RuntimeEventLog(capacity: 4)
        try client.pipeline.syncOperations.addHandler(held)
        try remote.pipeline.syncOperations.addHandler(RejectWrite(closeBeforeFailing: true))
        try attach(client, remote, events: events)
        try remote.writeInbound(ByteBuffer(string: "blocked response"))
        try client.writeInbound(ByteBuffer(string: "failed client write"))
        client.embeddedEventLoop.run(); remote.embeddedEventLoop.run()
        XCTAssertFalse(client.isActive, "an actual write syscall failure must still abort the blocked pair")
        XCTAssertFalse(remote.isActive)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertTrue(events.events.first?.detail?.contains("errno=49") == true)
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }

    func testClientShutdownDoesNotWaitForBlockedUpstreamWrites() throws {
        let client = try activeChannel(), remote = try activeChannel()
        let held = HoldWrites(), events = RuntimeEventLog(capacity: 4)
        try remote.pipeline.syncOperations.addHandler(held)
        try attach(client, remote, events: events)
        try client.writeInbound(ByteBuffer(string: "queued client bytes"))
        try client.close().wait()
        client.embeddedEventLoop.run(); remote.embeddedEventLoop.run()
        XCTAssertFalse(remote.isActive, "a departed client must not strand the upstream pool slot")
        XCTAssertTrue(events.events.isEmpty, "client cancellation is not a socket failure")
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }
}
