// SPDX-License-Identifier: Apache-2.0
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

final class TransparentRelaySetupTests: XCTestCase {
    private enum FixtureError: Error { case unexpectedDial }
    private struct UnusedResolver: OriginResolving {
        func resolveOrigin(host: String, port: Int, on eventLoop: EventLoop) -> EventLoopFuture<SocketAddress> {
            eventLoop.makeFailedFuture(FixtureError.unexpectedDial)
        }
    }
    private final class ContextCapture: ChannelInboundHandler {
        typealias InboundIn = ByteBuffer
        var context: ChannelHandlerContext!
        func handlerAdded(context: ChannelHandlerContext) { self.context = context }
    }

    func testClosedRemoteSetupReportsRemoteAndClosesClient() throws {
        try failedSetup(remoteClosed: true, expectedSide: "remote")
    }

    func testMissingClientHandlerSetupReportsClientAndClosesRemote() throws {
        try failedSetup(remoteClosed: false, expectedSide: "client")
    }

    private func failedSetup(remoteClosed: Bool, expectedSide: String) throws {
        let client = EmbeddedChannel(), remote = EmbeddedChannel()
        let address = try SocketAddress(ipAddress: "127.0.0.1", port: 1234)
        try client.connect(to: address).wait(); try remote.connect(to: address).wait()
        let logger = DiscardingLogSink(), events = RuntimeEventLog(capacity: 4)
        let pool = ConnectionPool(group: client.eventLoop, logger: logger, configProvider: { ProxyConfig() },
            authenticatorProvider: { _ in throw FixtureError.unexpectedDial })
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in throw FixtureError.unexpectedDial }, logger: logger)
        let handler = SNIInterceptHandler(connectCoordinator: coordinator, connectionPool: pool, logger: logger,
            originResolver: UnusedResolver(), directModeProvider: { .none }, strictModeProvider: { true },
            gatewayModeProvider: { false }, eventSink: nil,
            tunnelFailureReporter: TunnelFailureReporter(logger: logger, eventSink: { events.append($0) }))
        let capture = ContextCapture()
        try client.pipeline.addHandler(capture).wait()
        if remoteClosed {
            try client.pipeline.addHandler(handler).wait()
            try remote.close().wait()
        }
        let setup = handler.attachRelay(context: capture.context, upstreamChannel: remote,
            initialData: ByteBuffer(string: "ClientHello"), pooledTunnel: false, target: "stream.test:443", endpoint: nil)
        client.embeddedEventLoop.run(); remote.embeddedEventLoop.run()
        XCTAssertThrowsError(try setup.wait())
        XCTAssertFalse(client.isActive)
        XCTAssertFalse(remote.isActive)
        XCTAssertEqual(events.events.count, 1)
        XCTAssertTrue(events.events.first?.detail?.contains("side=\(expectedSide)") == true)
        XCTAssertTrue(events.events.first?.detail?.contains("operation=setup") == true)
        _ = try client.finish(acceptAlreadyClosed: true)
        _ = try remote.finish(acceptAlreadyClosed: true)
    }
}
