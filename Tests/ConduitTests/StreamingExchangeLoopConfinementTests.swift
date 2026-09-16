// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The pool's streaming exchange writes the upstream response to the client
/// channel and finishes when the client's `.end` write completes. That future
/// belongs to the client channel's loop; the handler's state belongs to the
/// upstream channel's loop, where NIO also calls `handlerRemoved`. The finish
/// closure hops back before touching the handler (#41, found by the TSan
/// soak). The handler asserts the loop in debug builds, so this test traps
/// if the hop goes missing.
final class StreamingExchangeLoopConfinementTests: XCTestCase {
    @MainActor
    func testAStreamedResponseFinishesOnTheUpstreamLoop() async throws {
        let upstreamGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let clientGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        addTeardownBlock {
            try await upstreamGroup.shutdownGracefully()
            try await clientGroup.shutdownGracefully()
        }

        let upstream = try await ServerBootstrap(group: upstreamGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ChunkedOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let upstreamPort = try XCTUnwrap(upstream.localAddress?.port)
        addTeardownBlock { try? await upstream.close().get() }

        // A real client channel on its own loop, carrying the response encoder
        // so the pool's `HTTPServerResponsePart` writes encode. Not the full
        // server pipeline: its state machine refuses a response that no
        // request preceded.
        let sink = try await ServerBootstrap(group: clientGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let sinkPort = try XCTUnwrap(sink.localAddress?.port)
        addTeardownBlock { try? await sink.close().get() }
        let clientChannel = try await ClientBootstrap(group: clientGroup)
            .channelInitializer { $0.pipeline.addHandler(HTTPResponseEncoder()) }
            .connect(host: "127.0.0.1", port: sinkPort)
            .get()
        addTeardownBlock { try? await clientChannel.close().get() }

        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "Mock", host: "127.0.0.1", port: upstreamPort, priority: 0)]
        let pool = ConnectionPool(
            group: upstreamGroup,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in StaticTokenAuthenticator() }
        )
        defer { pool.closeAll() }

        XCTAssertFalse(
            clientChannel.eventLoop === upstreamGroup.next(),
            "the client and upstream channels must live on different loops for this test to mean anything"
        )

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        let result = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
        XCTAssertEqual(result.upstream.port, upstreamPort)
        XCTAssertTrue(result.keepAlive)
    }
}

/// Answers any request with a chunked 200 so the exchange takes the
/// streaming path through `.head`, `.body` and `.end`.
private final class ChunkedOKHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var accumulated = ByteBufferAllocator().buffer(capacity: 1024)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let text = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              text.contains("\r\n\r\n") else {
            return
        }
        accumulated.clear()
        let response = "HTTP/1.1 200 OK\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "\r\n" +
            "5\r\nhello\r\n0\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}

private final class StaticTokenAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate dGVzdA==" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { scheme.caseInsensitiveCompare("Negotiate") == .orderedSame }
    func reset() {}
}
