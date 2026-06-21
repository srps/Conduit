// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

package final class LocalPACServer: @unchecked Sendable {
    package static let pacPath = "/proxy.pac"
    package static let contentType = "application/x-ns-proxy-autoconfig; charset=utf-8"

    private let group: MultiThreadedEventLoopGroup
    private let logger: any LogSink
    private let scriptBox = NIOLockedValueBox<Data>(Data())
    private var channel: Channel?

    package init(
        group: MultiThreadedEventLoopGroup = .singleton,
        logger: any LogSink
    ) {
        self.group = group
        self.logger = logger
    }

    package var listeningHost: String? {
        channel?.localAddress?.ipAddress
    }

    package var listeningPort: Int? {
        channel?.localAddress?.port
    }

    package var isRunning: Bool {
        channel?.isActive == true
    }

    package func start(host: String = "127.0.0.1", port: Int, script: String) async throws {
        if isRunning {
            updateScript(script)
            return
        }

        updateScript(script)
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                let handler = LocalPACHTTPHandler(scriptBox: self.scriptBox)
                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let encoder = HTTPResponseEncoder()
                return channel.pipeline.addHandler(decoder).flatMap {
                    channel.pipeline.addHandler(encoder)
                }.flatMap {
                    channel.pipeline.addHandler(handler)
                }
            }

        let bound = try await bootstrap.bind(host: host, port: port).get()
        channel = bound
        let actualHost = bound.localAddress?.ipAddress ?? host
        let actualPort = bound.localAddress?.port ?? port
        logger.log(.notice, "Local PAC server listening on \(actualHost):\(actualPort).", category: .pac)
    }

    package func updateScript(_ script: String) {
        let data = Data(script.utf8)
        scriptBox.withLockedValue { $0 = data }
    }

    package func stop() async {
        let wasRunning = channel != nil
        if let channel {
            _ = try? await channel.close().get()
        }
        channel = nil
        scriptBox.withLockedValue { $0.removeAll(keepingCapacity: false) }
        if wasRunning {
            logger.log(.notice, "Local PAC server stopped.", category: .pac)
        }
    }
}

private final class LocalPACHTTPHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let scriptBox: NIOLockedValueBox<Data>

    init(scriptBox: NIOLockedValueBox<Data>) {
        self.scriptBox = scriptBox
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head):
            handleRequest(head, context: context)
        case .body:
            break
        case .end:
            break
        }
    }

    private func handleRequest(_ request: HTTPRequestHead, context: ChannelHandlerContext) {
        let path = Self.normalizedPath(from: request.uri)
        switch (request.method, path) {
        case (.GET, LocalPACServer.pacPath):
            respondPAC(context: context, includeBody: true)
        case (.HEAD, LocalPACServer.pacPath):
            respondPAC(context: context, includeBody: false)
        case (_, LocalPACServer.pacPath):
            respondText(
                context: context,
                status: .methodNotAllowed,
                body: "Method Not Allowed\n",
                extraHeaders: [("Allow", "GET, HEAD")]
            )
        default:
            respondText(context: context, status: .notFound, body: "Not Found\n")
        }
    }

    private func respondPAC(context: ChannelHandlerContext, includeBody: Bool) {
        let data = scriptBox.withLockedValue { $0 }
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: LocalPACServer.contentType)
        headers.add(name: "Content-Length", value: "\(data.count)")
        headers.add(name: "Cache-Control", value: "no-store, no-cache, must-revalidate")
        headers.add(name: "Pragma", value: "no-cache")
        headers.add(name: "Connection", value: "close")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        if includeBody {
            var buffer = context.channel.allocator.buffer(capacity: data.count)
            buffer.writeBytes(data)
            context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        }
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private func respondText(
        context: ChannelHandlerContext,
        status: HTTPResponseStatus,
        body: String,
        extraHeaders: [(String, String)] = []
    ) {
        let bodyData = Data(body.utf8)
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        headers.add(name: "Content-Length", value: "\(bodyData.count)")
        headers.add(name: "Connection", value: "close")
        for (name, value) in extraHeaders {
            headers.add(name: name, value: value)
        }

        let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        var buffer = context.channel.allocator.buffer(capacity: bodyData.count)
        buffer.writeBytes(bodyData)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            context.close(promise: nil)
        }
    }

    private static func normalizedPath(from uri: String) -> String {
        if let url = URL(string: uri), let host = url.host, !host.isEmpty {
            return url.path.isEmpty ? "/" : url.path
        }
        let pathAndQuery = uri.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false).first
        let path = pathAndQuery.map(String.init) ?? uri
        return path.isEmpty ? "/" : path
    }
}
