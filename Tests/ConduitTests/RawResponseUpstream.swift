// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

/// An upstream proxy stand-in that answers each request head with the raw bytes its script returns, or with nothing
/// when the script returns nil. It never closes a connection itself, so a response written without its full body
/// leaves the exchange waiting for the rest.
final class RawResponseUpstream: @unchecked Sendable {
    private let script: @Sendable (_ requestLine: String) -> String?
    private let lines = NIOLockedValueBox<[String]>([])
    private var channel: Channel?

    init(_ script: @escaping @Sendable (_ requestLine: String) -> String?) {
        self.script = script
    }

    var port: Int { channel?.localAddress?.port ?? 0 }
    var requestLines: [String] { lines.withLockedValue { $0 } }

    func start(group: EventLoopGroup) async throws {
        let script = self.script, lines = self.lines
        channel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HeadReader { channel, requestLine in
                    lines.withLockedValue { $0.append(requestLine) }
                    guard let response = script(requestLine) else { return }
                    channel.writeAndFlush(channel.allocator.buffer(string: response), promise: nil)
                })
            }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    func stop() async throws {
        try await channel?.close().get()
    }

    private final class HeadReader: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        private let onRequest: (Channel, String) -> Void
        private var pending = ""

        init(onRequest: @escaping (Channel, String) -> Void) { self.onRequest = onRequest }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data)
            pending += buffer.readString(length: buffer.readableBytes) ?? ""
            while let end = pending.range(of: "\r\n\r\n") {
                let head = String(pending[pending.startIndex..<end.lowerBound])
                pending.removeSubrange(pending.startIndex..<end.upperBound)
                onRequest(context.channel, head.components(separatedBy: "\r\n").first ?? "")
            }
        }
    }
}

/// A client channel for a streaming exchange: a real socket to a sink that discards what it reads, with the response
/// encoder the pool's `HTTPServerResponsePart` writes need. Closed at teardown with the sink.
struct StreamingClientSink {
    let channel: Channel
    private let sink: Channel

    static func make(group: EventLoopGroup) async throws -> StreamingClientSink {
        let sink = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture { try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder()) }
            }
            .connect(host: "127.0.0.1", port: sink.localAddress?.port ?? 0)
            .get()
        return StreamingClientSink(channel: channel, sink: sink)
    }

    func close() async {
        for channel in [channel, sink] {
            do {
                try await channel.close().get()
            } catch ChannelError.alreadyClosed {
                // The exchange closed the client on its way out.
            } catch {
                XCTFail("closing a streaming test channel failed: \(error)")
            }
        }
    }
}
