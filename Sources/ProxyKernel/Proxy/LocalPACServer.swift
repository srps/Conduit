// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

package final class LocalPACServer: @unchecked Sendable {
    package static let pacPath = "/proxy.pac"
    package static let contentType = "application/x-ns-proxy-autoconfig; charset=utf-8"

    private struct Runtime {
        var channel: Channel?
        /// Each start takes the next epoch and each stop supersedes it, so a bind that finishes after either one owns nothing.
        var epoch = 0
    }

    /// What `admit` decided: a listener is already up and took the script, or this start owns the epoch it took.
    private enum Attempt {
        case running
        case bind(epoch: Int)
    }

    private let group: MultiThreadedEventLoopGroup
    private let logger: any LogSink
    /// Written only under `runtime`'s lock, so a script always belongs to the start or stop that holds the lock.
    private let scriptBox = NIOLockedValueBox<Data>(Data())
    private let runtime = NIOLockedValueBox(Runtime())

    package init(
        group: MultiThreadedEventLoopGroup = .singleton,
        logger: any LogSink
    ) {
        self.group = group
        self.logger = logger
    }

    package var listeningHost: String? {
        runtime.withLockedValue { $0.channel?.localAddress?.ipAddress }
    }

    package var listeningPort: Int? {
        runtime.withLockedValue { $0.channel?.localAddress?.port }
    }

    package var isRunning: Bool {
        runtime.withLockedValue { $0.channel?.isActive == true }
    }

    /// A bind that completes after a stop, or after a newer start, closes its own candidate and throws `CancellationError`. It never
    /// publishes over the owner that superseded it.
    package func start(host: String = "127.0.0.1", port: Int, script: String) async throws {
        guard case .bind(let epoch) = admit(script: script) else { return }
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // On the child's loop: add synchronously rather than chain
                // non-Sendable handlers through futures.
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandlers([
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)),
                        HTTPResponseEncoder(),
                        LocalPACHTTPHandler(scriptBox: self.scriptBox),
                    ])
                }
            }

        let bound = try await bootstrap.bind(host: host, port: port).get()
        let published = runtime.withLockedValue { r -> Bool in
            guard r.epoch == epoch else { return false }
            r.channel = bound
            return true
        }
        guard published else {
            do {
                try await bound.close().get()
            } catch {
                logger.log(.warning, "Local PAC server could not close a superseded listener: \(error.localizedDescription)", category: .pac)
            }
            throw CancellationError()
        }
        let actualHost = bound.localAddress?.ipAddress ?? host
        let actualPort = bound.localAddress?.port ?? port
        logger.log(.notice, "Local PAC server listening on \(actualHost):\(actualPort).", category: .pac)
    }

    package func updateScript(_ script: String) {
        let data = Data(script.utf8)
        runtime.withLockedValue { _ in scriptBox.withLockedValue { $0 = data } }
    }

    /// The running check, the epoch advance and the script write share one lock acquisition. Split apart, a stop could detach between
    /// them and this start's epoch would then publish over a listener that stop had already superseded.
    private func admit(script: String) -> Attempt {
        let data = Data(script.utf8)
        return runtime.withLockedValue { r -> Attempt in
            scriptBox.withLockedValue { $0 = data }
            if r.channel?.isActive == true { return .running }
            r.epoch += 1
            return .bind(epoch: r.epoch)
        }
    }

    /// Supersedes any start still binding, and detaches the published channel, in the same lock acquisition as the script clear. A newer
    /// start's channel and script are therefore never cleared by this stop, and the close suspends only after the detach.
    package func stop() async {
        let detached = runtime.withLockedValue { r -> Channel? in
            r.epoch += 1
            scriptBox.withLockedValue { $0.removeAll(keepingCapacity: false) }
            defer { r.channel = nil }
            return r.channel
        }
        guard let detached else { return }
        do {
            try await detached.close().get()
        } catch {
            logger.log(.warning, "Local PAC server could not close its listener: \(error.localizedDescription)", category: .pac)
        }
        logger.log(.notice, "Local PAC server stopped.", category: .pac)
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
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
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
        let boundContext = NIOLoopBound(context, eventLoop: context.eventLoop)
        context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
            boundContext.value.close(promise: nil)
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
