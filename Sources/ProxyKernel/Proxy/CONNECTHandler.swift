// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

package enum ProxyPipelineNames {
    package static let serverDecoder = "serverDecoder"
    package static let serverEncoder = "serverEncoder"
    package static let serverExpectContinue = "serverExpectContinue"
    package static let serverHandler = "serverHandler"
    package static let upstreamDecoder = "upstreamDecoder"
    package static let upstreamEncoder = "upstreamEncoder"
}

package final class CONNECTCoordinator: @unchecked Sendable {
    private let pool: ConnectionPool
    private let authenticatorProvider: (String) throws -> ProxyAuthenticator
    private let logger: any LogSink
    private let authHandshakeLimiter: AuthHandshakeLimiter
    private let authLimitProvider: @Sendable () -> AuthHandshakeLimiter.Limits
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?

    package init(
        pool: ConnectionPool,
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator,
        logger: any LogSink,
        authHandshakeLimiter: AuthHandshakeLimiter = AuthHandshakeLimiter(),
        authLimitProvider: @escaping @Sendable () -> AuthHandshakeLimiter.Limits = {
            AuthHandshakeLimiter.Limits(total: 512, perSource: 128)
        },
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.pool = pool
        self.authenticatorProvider = authenticatorProvider
        self.logger = logger
        self.authHandshakeLimiter = authHandshakeLimiter
        self.authLimitProvider = authLimitProvider
        self.eventSink = eventSink
    }

    /// Establish CONNECT tunnel to upstream proxy, returning the raw tunnel channel.
    /// Uses the configured ProxyAuthenticator for 407 challenge-response.
    /// Retries with the next upstream on connection failure.
    package func connectUpstreamTunnel(
        target: String,
        authSource: String? = nil,
        proxyChain: [UpstreamProxy] = []
    ) -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> {
        if !proxyChain.isEmpty {
            return attemptTunnel(target: target, authSource: authSource, proxyChain: proxyChain, index: 0)
        }
        let maxRetries = pool.enabledUpstreamCount
        return attemptTunnel(target: target, authSource: authSource, attempt: 1, maxRetries: maxRetries)
    }

    private func attemptTunnel(
        target: String,
        authSource: String?,
        proxyChain: [UpstreamProxy],
        index: Int
    ) -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> {
        let forcedProxy = proxyChain[index]
        return attemptTunnel(
            target: target,
            authSource: authSource,
            forcedProxy: forcedProxy
        ).flatMapError { [weak self] error in
            if ConnectionPoolError.isAuthHandshakeLimitExceeded(error) {
                let el = self?.pool.eventLoop ?? MultiThreadedEventLoopGroup.singleton.next()
                return el.makeFailedFuture(error)
            }
            guard let self, index + 1 < proxyChain.count else {
                let el = self?.pool.eventLoop ?? MultiThreadedEventLoopGroup.singleton.next()
                return el.makeFailedFuture(error)
            }
            let next = proxyChain[index + 1].endpoint
            self.logger.log(.warning, "PAC upstream \(forcedProxy.endpoint) failed for \(target), trying \(next).", category: .proxy)
            return self.attemptTunnel(target: target, authSource: authSource, proxyChain: proxyChain, index: index + 1)
        }
    }

    private func attemptTunnel(
        target: String,
        authSource: String?,
        attempt: Int,
        maxRetries: Int
    ) -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> {
        return attemptTunnel(target: target, authSource: authSource, forcedProxy: nil).flatMapError { [weak self] error -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> in
            if ConnectionPoolError.isAuthHandshakeLimitExceeded(error) {
                let el = self?.pool.eventLoop ?? MultiThreadedEventLoopGroup.singleton.next()
                return el.makeFailedFuture(error)
            }
            guard let self, attempt < maxRetries else {
                let el = self?.pool.eventLoop ?? MultiThreadedEventLoopGroup.singleton.next()
                return el.makeFailedFuture(error)
            }
            let next = self.pool.switchToNextUpstream() ?? "unknown"
            self.logger.log(.warning, "Upstream failed for \(target), switching to \(next) (attempt \(attempt + 1)/\(maxRetries)).", category: .proxy)
            return self.attemptTunnel(target: target, authSource: authSource, attempt: attempt + 1, maxRetries: maxRetries)
        }
    }

    private func attemptTunnel(
        target: String,
        authSource: String?,
        forcedProxy: UpstreamProxy?
    ) -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> {
        let pool = self.pool
        let start = Date()
        return pool.makeDedicatedTunnelConnection(forcedProxy: forcedProxy).flatMap { [weak self] (connection: PooledUpstreamConnection, _: ProxyConfig) -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> in
            guard let self else {
                return connection.channel.eventLoop.makeFailedFuture(ConnectionPoolError.invalidResponse)
            }

            self.logger.log(.info, "CONNECT handshake to \(connection.proxy.endpoint) for \(target)", category: .proxy)

            let promise = connection.channel.eventLoop.makePromise(of: PooledUpstreamConnection.self)
            let handler = RawConnectHandshakeHandler(
                connection: connection,
                authenticatorProvider: self.authenticatorProvider,
                target: target,
                authSource: authSource,
                authHandshakeLimiter: self.authHandshakeLimiter,
                authLimitProvider: self.authLimitProvider,
                eventSink: self.eventSink,
                responseTimeout: pool.upstreamResponseTimeout,
                promise: promise,
                logger: self.logger
            )

            return connection.channel.pipeline.addHandler(handler, name: "rawConnectHandshake").flatMap {
                handler.start()
                return promise.futureResult
            }.flatMap { (established: PooledUpstreamConnection) -> EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)> in
                pool.recordDedicatedTunnelSuccess(
                    for: established.proxy,
                    latencyMS: Int(Date().timeIntervalSince(start) * 1_000)
                )
                return established.channel.pipeline.removeHandler(name: "rawConnectHandshake").map {
                    (channel: established.channel, endpoint: established.proxy.endpoint, authMethod: established.authMethod)
                }
            }.flatMapError { error in
                connection.channel.close(mode: .all, promise: nil)
                pool.removeDedicatedTunnel(connection)
                if !ConnectionPoolError.isAuthHandshakeLimitExceeded(error) {
                    pool.recordDedicatedTunnelFailure(for: connection.proxy)
                }
                return connection.channel.eventLoop.makeFailedFuture(error)
            }
        }
    }

    package func establishTunnel(
        requestHead: HTTPRequestHead,
        clientContext: ChannelHandlerContext,
        proxyChain: [UpstreamProxy] = [],
        onTunnelClosed: @Sendable @escaping () -> Void
    ) -> EventLoopFuture<(endpoint: String, authMethod: String?)> {
        nonisolated(unsafe) let ctx = clientContext
        let clientEL = ctx.eventLoop
        let pool = self.pool
        let authSource = clientContext.remoteAddress?.ipAddress
        return connectUpstreamTunnel(target: requestHead.uri, authSource: authSource, proxyChain: proxyChain)
            .hop(to: clientEL)
            .flatMap { [weak self] (upstreamChannel, endpoint, authMethod) in
                guard let self else {
                    return clientEL.makeFailedFuture(ConnectionPoolError.invalidResponse)
                }
                return self.attachHTTPTunnel(
                    clientContext: ctx,
                    upstreamChannel: upstreamChannel,
                    onTunnelClosed: { pool.removeDedicatedTunnelByChannel(upstreamChannel); onTunnelClosed() }
                ).map { (endpoint: endpoint, authMethod: authMethod) }
            }
    }

    private func attachHTTPTunnel(
        clientContext: ChannelHandlerContext,
        upstreamChannel: Channel,
        onTunnelClosed: @Sendable @escaping () -> Void
    ) -> EventLoopFuture<Void> {
        let clientChannel = clientContext.channel

        var responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        responseHead.headers.add(name: "Content-Length", value: "0")
        responseHead.headers.add(name: "Connection", value: "keep-alive")

        clientContext.write(NIOAny(HTTPServerResponsePart.head(responseHead)), promise: nil)
        return clientContext.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).flatMap {
            // Typed handlers must leave before the decoder so its leftover
            // raw bytes can never reach a typed unwrap.
            clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverExpectContinue)
        }.flatMap {
            clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverDecoder)
        }.flatMap {
            clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverEncoder)
        }.flatMap {
            clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverHandler)
        }.flatMap {
            let clientRelay = TunnelRelayHandler(peer: upstreamChannel, logger: self.logger, onClose: onTunnelClosed)
            let upstreamRelay = TunnelRelayHandler(peer: clientChannel, logger: self.logger)
            return clientChannel.pipeline.addHandler(clientRelay).flatMap {
                upstreamChannel.pipeline.addHandler(upstreamRelay)
            }
        }
    }

}

/// Raw-byte CONNECT handshake that bypasses NIO's HTTP parser entirely.
/// Writes/reads raw HTTP text on the TCP connection so the parser state corruption
/// between the 407 challenge response and the follow-up request cannot occur.
/// Uses the ProxyAuthenticator protocol for scheme-agnostic auth (NTLM, Negotiate, etc.).
private final class RawConnectHandshakeHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let connection: PooledUpstreamConnection
    private let authenticatorProvider: (String) throws -> ProxyAuthenticator
    private let target: String
    private let authSource: String?
    private let authHandshakeLimiter: AuthHandshakeLimiter
    private let authLimitProvider: @Sendable () -> AuthHandshakeLimiter.Limits
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let responseTimeout: TimeAmount
    private let promise: EventLoopPromise<PooledUpstreamConnection>
    private let logger: any LogSink

    private let maxAccumulatedBytes = 65_536
    private enum Phase { case awaitingChallenge, awaitingFinal }
    private var phase: Phase = .awaitingChallenge
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var ctx: ChannelHandlerContext?
    private var authenticator: ProxyAuthenticator?
    private var lastAuthMethod: String?
    private var authPermit: AuthHandshakePermit?
    private var responseTimeoutTask: Scheduled<Void>?
    private var completed = false

    init(
        connection: PooledUpstreamConnection,
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator,
        target: String,
        authSource: String?,
        authHandshakeLimiter: AuthHandshakeLimiter,
        authLimitProvider: @escaping @Sendable () -> AuthHandshakeLimiter.Limits,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        responseTimeout: TimeAmount,
        promise: EventLoopPromise<PooledUpstreamConnection>,
        logger: any LogSink
    ) {
        self.connection = connection
        self.authenticatorProvider = authenticatorProvider
        self.target = target
        self.authSource = authSource
        self.authHandshakeLimiter = authHandshakeLimiter
        self.authLimitProvider = authLimitProvider
        self.eventSink = eventSink
        self.responseTimeout = responseTimeout
        self.promise = promise
        self.logger = logger
    }

    func handlerAdded(context: ChannelHandlerContext) { self.ctx = context }
    func handlerRemoved(context: ChannelHandlerContext) {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        self.ctx = nil
    }

    func start() {
        guard let ctx else {
            promise.fail(ConnectionPoolError.invalidResponse)
            return
        }
        nonisolated(unsafe) let provider = self.authenticatorProvider
        let host = self.connection.proxy.host
        let eventLoop = ctx.eventLoop
        let handler = self
        nonisolated(unsafe) let capturedCtx = ctx
        guard beginAuthHandshake(host: connection.proxy.endpoint) else {
            fail(ConnectionPoolError.authHandshakeLimitExceeded, context: ctx, close: false)
            return
        }
        Task { @Sendable in
            do {
                let auth = try provider(host)
                let token = try auth.initialToken(for: host)
                eventLoop.execute {
                    handler.authenticator = auth
                    handler.logger.log(.debug, "CONNECT + \(auth.scheme) initial for \(handler.target)", category: .auth)
                    handler.recordAuthMethod(fromHeader: token)
                    handler.writeRawConnect(authHeader: token, context: capturedCtx)
                }
            } catch {
                eventLoop.execute {
                    handler.fail(error, context: capturedCtx, close: false)
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        accumulated.writeBuffer(&buf)

        if accumulated.readableBytes > maxAccumulatedBytes {
            fail(ConnectionPoolError.invalidResponse, context: context)
            return
        }

        guard let response = tryParseResponse() else { return }
        handleResponse(response, context: context)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    private func handleResponse(_ response: RawHTTPResponse, context: ChannelHandlerContext) {
        logger.log(.debug, "Upstream raw response: \(response.statusCode) for \(target)", category: .proxy)

        if response.statusCode == 200 {
            logger.log(.debug, "CONNECT tunnel established for \(target)", category: .proxy)
            succeed(connection)
            return
        }

        guard response.statusCode == 407 else {
            logger.log(.error, "Unexpected status \(response.statusCode) for \(target)", category: .proxy)
            fail(ConnectionPoolError.upstreamReturnedStatus(response.statusCode, target: target), context: context)
            return
        }
        cancelResponseTimeout()

        switch phase {
        case .awaitingChallenge:
            let authHeaders = response.headers(named: "Proxy-Authenticate")
            logger.log(.debug, "407 Proxy-Authenticate schemes: \(Self.redactedAuthChallengeSummary(authHeaders))", category: .auth)
            guard let auth = self.authenticator else {
                fail(ConnectionPoolError.authenticationRejected, context: context)
                return
            }
            let host = connection.proxy.host
            let eventLoop = context.eventLoop
            let handler = self
            nonisolated(unsafe) let ctx = context
            Task { @Sendable in
                do {
                    // nil here means the authenticator has no token to send. Since we're
                    // inside a 407 response, the proxy still demands auth — this is a rejection.
                    // (Successful mutual-auth completion arrives as 200, not 407; see RFC 4559 §4.)
                    guard let responseToken = try auth.processChallenge(headerValues: authHeaders, host: host) else {
                        eventLoop.execute {
                            handler.logger.log(.error, "No suitable challenge response for \(handler.target)", category: .auth)
                            handler.fail(ConnectionPoolError.authenticationRejected, context: ctx)
                        }
                        return
                    }
                    eventLoop.execute {
                        handler.phase = .awaitingFinal
                        handler.accumulated.clear()
                        handler.logger.log(.debug, "CONNECT + \(auth.scheme) challenge-response for \(handler.target)", category: .auth)
                        handler.recordAuthMethod(fromHeader: responseToken)
                        handler.writeRawConnect(authHeader: responseToken, context: ctx)
                    }
                } catch {
                    eventLoop.execute {
                        handler.fail(error, context: ctx)
                    }
                }
            }

        case .awaitingFinal:
            logger.log(.error, "Auth rejected after challenge-response for \(target)", category: .auth)
            fail(ConnectionPoolError.authenticationRejected, context: context)
        }
    }

    private func writeRawConnect(authHeader: String, context: ChannelHandlerContext) {
        var request = "CONNECT \(target) HTTP/1.1\r\n"
        request += "Host: \(target)\r\n"
        request += "Proxy-Authorization: \(authHeader)\r\n"
        request += "Proxy-Connection: Keep-Alive\r\n"
        request += "\r\n"

        var buf = context.channel.allocator.buffer(capacity: request.utf8.count)
        buf.writeString(request)
        nonisolated(unsafe) let ctx = context
        resetResponseTimeout(context: ctx)
        ctx.writeAndFlush(NIOAny(buf)).whenFailure { error in
            self.fail(error, context: ctx)
        }
    }

    private func resetResponseTimeout(context: ChannelHandlerContext) {
        cancelResponseTimeout()
        nonisolated(unsafe) let ctx = context
        responseTimeoutTask = ctx.eventLoop.scheduleTask(in: responseTimeout) { [weak self] in
            guard let self else { return }
            self.eventSink?(ConnectionPool.upstreamResponseTimedOutEvent(
                uri: self.target,
                upstream: self.connection.proxy.endpoint
            ))
            self.fail(ConnectionPoolError.upstreamResponseTimedOut, context: ctx)
        }
    }

    private func cancelResponseTimeout() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
    }

    private func succeed(_ connection: PooledUpstreamConnection) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        finishAuthHandshake()
        connection.markAuthenticated(authMethod: lastAuthMethod ?? connection.authMethod)
        promise.succeed(connection)
    }

    private func fail(_ error: Error, context: ChannelHandlerContext?, close: Bool = true) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        finishAuthHandshake()
        promise.fail(error)
        if close {
            context?.close(promise: nil)
        }
    }

    private func beginAuthHandshake(host: String) -> Bool {
        switch authHandshakeLimiter.acquire(source: authSource, limits: authLimitProvider()) {
        case .success(let permit):
            authPermit = permit
            return true
        case .failure(let rejection):
            emitAuthLimitEvent(rejection: rejection, host: host)
            return false
        }
    }

    private func finishAuthHandshake() {
        authPermit?.release()
        authPermit = nil
    }

    private func emitAuthLimitEvent(rejection: AuthHandshakeLimiter.Rejection, host: String) {
        let detail: String
        switch rejection {
        case .totalLimit(let total, let limit):
            detail = "host=\(host) scope=total pending=\(total) limit=\(limit)"
        case .perSourceLimit(let source, let total, let limit):
            detail = "host=\(host) scope=source source=\(source) pending=\(total) limit=\(limit)"
        }
        eventSink?(RuntimeEvent(kind: .auth, event: "auth.handshake_rejected", detail: detail))
    }

    private func recordAuthMethod(fromHeader header: String) {
        if let scheme = Self.authMethod(fromAuthorizationHeader: header) {
            lastAuthMethod = scheme
        }
    }

    private static func authMethod(fromAuthorizationHeader header: String) -> String? {
        header
            .split(whereSeparator: \.isWhitespace)
            .first
            .map(String.init)
    }

    private static func redactedAuthChallengeSummary(_ headers: [String]) -> String {
        guard !headers.isEmpty else { return "<none>" }
        return headers.map { header in
            let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
            let scheme = trimmed.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? "<unknown>"
            return "\(scheme)(\(trimmed.utf8.count) bytes)"
        }.joined(separator: ", ")
    }

    private func tryParseResponse() -> RawHTTPResponse? {
        guard let str = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes) else {
            return nil
        }

        guard let headerEnd = str.range(of: "\r\n\r\n") else { return nil }

        let headerSection = String(str[str.startIndex..<headerEnd.lowerBound])
        let lines = headerSection.split(separator: "\r\n", omittingEmptySubsequences: false)
        guard let statusLine = lines.first else { return nil }

        let statusParts = statusLine.split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, let statusCode = Int(statusParts[1]) else { return nil }

        var headers: [(String, String)] = []
        for line in lines.dropFirst() {
            if let colonIdx = line.firstIndex(of: ":") {
                let name = String(line[line.startIndex..<colonIdx]).trimmingCharacters(in: .whitespaces)
                let value = String(line[line.index(after: colonIdx)...]).trimmingCharacters(in: .whitespaces)
                headers.append((name, value))
            }
        }

        let afterHeaders = str[headerEnd.upperBound...]
        let contentLength: Int
        if headers.contains(where: {
            $0.0.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
                && $0.1.lowercased().split(separator: ",").contains {
                    String($0).trimmingCharacters(in: .whitespaces) == "chunked"
                }
        }) {
            guard let chunkedLength = Self.chunkedBodyByteCount(in: String(afterHeaders)) else {
                return nil
            }
            contentLength = chunkedLength
        } else {
            contentLength = headers.first { $0.0.lowercased() == "content-length" }
                .flatMap { Int($0.1) } ?? 0
        }

        if afterHeaders.utf8.count < contentLength {
            return nil
        }

        let totalConsumed = str.distance(from: str.startIndex, to: headerEnd.upperBound) + contentLength
        accumulated.moveReaderIndex(forwardBy: totalConsumed)

        return RawHTTPResponse(statusCode: statusCode, rawHeaders: headers)
    }

    private static func chunkedBodyByteCount(in body: String) -> Int? {
        var index = body.startIndex
        while true {
            guard let lineEnd = body[index...].range(of: "\r\n") else { return nil }
            let sizeLine = body[index..<lineEnd.lowerBound]
            let sizeText = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeText.trimmingCharacters(in: .whitespaces), radix: 16) else {
                return nil
            }
            index = lineEnd.upperBound
            guard let chunkEnd = body.index(index, offsetBy: size, limitedBy: body.endIndex) else {
                return nil
            }
            guard body[chunkEnd...].hasPrefix("\r\n") else { return nil }
            index = body.index(chunkEnd, offsetBy: 2)
            if size == 0 {
                guard let trailerEnd = body[index...].range(of: "\r\n") else { return nil }
                return body.distance(from: body.startIndex, to: trailerEnd.upperBound)
            }
        }
    }
}

private struct RawHTTPResponse {
    let statusCode: Int
    let rawHeaders: [(String, String)]

    func headers(named name: String) -> [String] {
        rawHeaders
            .filter { $0.0.lowercased() == name.lowercased() }
            .map(\.1)
    }
}

private final class TunnelRelayHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let peer: Channel
    private let logger: any LogSink
    private let onClose: (() -> Void)?

    init(peer: Channel, logger: any LogSink, onClose: (() -> Void)? = nil) {
        self.peer = peer
        self.logger = logger
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        peer.writeAndFlush(buffer, promise: nil)
        if !peer.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        }
    }

    func channelWritabilityChanged(context: ChannelHandlerContext) {
        if context.channel.isWritable {
            peer.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
        }
        context.fireChannelWritabilityChanged()
    }

    func channelInactive(context: ChannelHandlerContext) {
        onClose?()
        // Drain peer's outbound queue before closing. `close(mode: .all)` fails all
        // buffered writes, which truncates streamed responses when the upstream FINs
        // while we still have hundreds of KB queued for the client under backpressure.
        gracefulClosePeer()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(.warning, "Tunnel relay error: \(error.localizedDescription)", category: .proxy)
        gracefulClosePeer()
        context.close(promise: nil)
    }

    private func gracefulClosePeer() {
        let peer = self.peer
        guard peer.isActive else {
            peer.close(mode: .all, promise: nil)
            return
        }
        // Write 0 bytes then flush; the future fires when all previously-queued writes
        // have been dispatched to the kernel send buffer. Then close cleanly.
        peer.writeAndFlush(NIOAny(peer.allocator.buffer(capacity: 0))).whenComplete { _ in
            peer.close(mode: .all, promise: nil)
        }
    }
}
