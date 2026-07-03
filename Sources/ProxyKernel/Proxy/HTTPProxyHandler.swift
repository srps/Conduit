// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

final class HTTPProxyHandler: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let pool: ConnectionPool
    private let connectCoordinator: CONNECTCoordinator
    private let logger: any LogSink
    /// `(isDirect, cause)` for direct/degraded routing. The cause governs log
    /// severity in failure paths: `.upstreamsUnreachable` keeps `.error`, while
    /// transient VPN flaps demote expected upstream noise to `.info`. See
    /// `docs/design-vpn-flap-resilience.md` § "Logging and Event Posture".
    private let directModeProvider: () -> (Bool, DirectModeCause)
    private let directConnectDetector: DirectConnectDetector
    private let pacRoutingEngine: PACRoutingEngine?
    private let gatewayMode: Bool
    private let authSource: String?
    private let eventLoopGroup: EventLoopGroup
    private let onConnectionOpened: @Sendable (ActiveConnectionInfo) -> Void
    private let onConnectionClosed: @Sendable (UUID) -> Void
    private let onConnectionActivity: @Sendable (ConnectionActivity) -> Void
    private let onRequestCompleted: @Sendable (Bool, String?) -> Void

    private let configProvider: () -> ProxyConfig
    private var requestHead: HTTPRequestHead?
    private var requestBody = ByteBufferAllocator().buffer(capacity: 0)
    private var requestSpool: SpooledHTTPRequestBody?
    private var requestBodyWriteFuture: EventLoopFuture<Void>?
    private var bodyTooLarge = false
    private var bodyStorageError: Error?

    init(
        pool: ConnectionPool,
        connectCoordinator: CONNECTCoordinator,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        directModeProvider: @escaping () -> (Bool, DirectModeCause),
        directConnectDetector: DirectConnectDetector,
        pacRoutingEngine: PACRoutingEngine?,
        gatewayMode: Bool,
        authSource: String?,
        eventLoopGroup: EventLoopGroup,
        onConnectionOpened: @Sendable @escaping (ActiveConnectionInfo) -> Void,
        onConnectionClosed: @Sendable @escaping (UUID) -> Void,
        onConnectionActivity: @Sendable @escaping (ConnectionActivity) -> Void,
        onRequestCompleted: @Sendable @escaping (Bool, String?) -> Void
    ) {
        self.pool = pool
        self.connectCoordinator = connectCoordinator
        self.logger = logger
        self.configProvider = configProvider
        self.directModeProvider = directModeProvider
        self.directConnectDetector = directConnectDetector
        self.pacRoutingEngine = pacRoutingEngine
        self.gatewayMode = gatewayMode
        self.authSource = authSource
        self.eventLoopGroup = eventLoopGroup
        self.onConnectionOpened = onConnectionOpened
        self.onConnectionClosed = onConnectionClosed
        self.onConnectionActivity = onConnectionActivity
        self.onRequestCompleted = onRequestCompleted
    }

    deinit {
        requestSpool?.cleanup()
    }

    func channelInactive(context: ChannelHandlerContext) {
        abandonRequestBodyStorage()
        context.fireChannelInactive()
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            requestHead = head
            resetRequestBodyState()
        case .body(var buffer):
            appendRequestBody(&buffer, context: context)
        case .end:
            guard let head = requestHead else { return }
            guard let target = HTTPRequestTarget.parse(head) else {
                writeError(status: .badRequest, message: "Invalid request target: \(head.uri)", context: context)
                requestHead = nil
                resetRequestBodyState()
                return
            }
            let targetHost = target.host
            // Read pattern lists fresh on every request so config-reload changes to
            // `noProxyHosts` / `forceProxyHosts` take effect without restarting the listener.
            // Capturing these at handler construction would freeze them for the life of the
            // channel and force every reload to either restart the proxy (visible disruption)
            // or silently lie about the active routing rules.
            let currentConfig = configProvider()
            let forceProxyPatterns = currentConfig.forceProxyHosts
            let forceProxy = NoProxyMatcher.matchesAny(host: targetHost, patterns: forceProxyPatterns)
            let (isDirectMode, directCause) = directModeProvider()
            let directModeBypass = isDirectMode && directCause.routesClientTrafficDirectly
            // Only unconditional direct states bypass PAC/upstreams. VPN-connected
            // degraded states keep PAC policy active for split-DNS safety.
            let shouldEvaluatePAC = Self.shouldEvaluatePAC(isDirectMode: directModeBypass, forceProxy: forceProxy)
            requestHead = nil
            nonisolated(unsafe) let ctx = context
            finalizeRequestBody(context: ctx).whenComplete { bodyResult in
                guard ctx.channel.isActive else { return }
                let completedBody: CompletedRequestBody
                switch bodyResult {
                case .success(let body):
                    completedBody = body
                case .failure(let error):
                    self.logger.log(.warning, "Request body storage failed for \(head.uri): \(error.localizedDescription)", category: .proxy)
                    self.onRequestCompleted(false, nil)
                    self.writeError(status: .internalServerError, message: "Request body could not be stored for replay.", context: ctx)
                        .whenComplete { _ in ctx.close(promise: nil) }
                    return
                }

                if completedBody.tooLarge {
                    self.logger.log(.warning, "Request body for \(head.uri) exceeded spool limit; rejecting.", category: .proxy)
                    self.onRequestCompleted(false, nil)
                    completedBody.body?.cleanup()
                    self.writeError(status: .payloadTooLarge, message: "Request body exceeds configured spool limit.", context: ctx)
                        .whenComplete { _ in ctx.close(promise: nil) }
                    return
                }

            if shouldEvaluatePAC,
               let engine = self.pacRoutingEngine,
               let pacURL = target.pacURL {
                // Design note: this proxy does not provide strict HTTP/1.1 pipelined
                // response ordering. That was already true once a request entered
                // async exchange/tunnel setup; async PAC only makes the routing step
                // visibly async too. Modern clients do not pipeline, and supporting it
                // correctly would require a per-client response serializer.
                engine.routeChainFuture(for: pacURL.absoluteString, host: targetHost, on: ctx.eventLoop)
                    .whenComplete { result in
                        guard ctx.channel.isActive else { return }
                        let routes = (try? result.get()) ?? []
                        let pacResult = Self.pacResult(from: routes, config: currentConfig)
                        self.routeCompletedRequest(
                            head: head,
                            body: completedBody.body,
                            target: target,
                            context: ctx,
                            currentConfig: currentConfig,
                            forceProxyPatterns: forceProxyPatterns,
                            forceProxy: forceProxy,
                            directModeBypass: directModeBypass,
                            directCause: directCause,
                            pacResult: pacResult
                        )
                    }
                return
            }
            let pacResult = PACResult(route: nil, hasDirectFallback: false)
            self.routeCompletedRequest(
                head: head,
                body: completedBody.body,
                target: target,
                context: ctx,
                currentConfig: currentConfig,
                forceProxyPatterns: forceProxyPatterns,
                forceProxy: forceProxy,
                directModeBypass: directModeBypass,
                directCause: directCause,
                pacResult: pacResult
            )
            }
        }
    }

    private func routeCompletedRequest(
        head: HTTPRequestHead,
        body: HTTPRequestBody?,
        target: HTTPRequestTarget,
        context: ChannelHandlerContext,
        currentConfig: ProxyConfig,
        forceProxyPatterns: [String],
        forceProxy: Bool,
        directModeBypass: Bool,
        directCause: DirectModeCause,
        pacResult: PACResult
    ) {
        let targetHost = target.host
        let pacBypass = pacResult.route == .direct
        let pacSaysProxy: Bool
        if case .proxy = pacResult.route { pacSaysProxy = true } else { pacSaysProxy = false }
        let bypass = directModeBypass
            || NoProxyMatcher.shouldBypass(host: targetHost, patterns: currentConfig.noProxyHosts, forceProxy: forceProxyPatterns)
            || pacBypass
            || (!forceProxy && !pacSaysProxy && cachedDirectReachable(target: target))
        let selectedUpstream = pacResult.proxyChain.first?.endpoint ?? pool.activeUpstream() ?? "pending"
        let info = ActiveConnectionInfo(
            destination: head.uri,
            upstream: bypass ? "DIRECT" : selectedUpstream,
            method: head.method.rawValue,
            tunnel: head.method == .CONNECT
        )
        onConnectionOpened(info)
        handleRequest(
            head: head,
            body: body,
            infoID: info.id,
            target: target,
            context: context,
            bypass: bypass,
            directCause: directCause,
            pacResult: pacResult
        )
    }

    private struct CompletedRequestBody {
        var body: HTTPRequestBody?
        var tooLarge: Bool
    }

    private func resetRequestBodyState() {
        requestSpool?.cleanup()
        requestSpool = nil
        requestBodyWriteFuture = nil
        requestBody.clear()
        bodyTooLarge = false
        bodyStorageError = nil
    }

    private func abandonRequestBodyStorage() {
        requestBody.clear()
        bodyTooLarge = false
        bodyStorageError = nil
        let pendingWrite = requestBodyWriteFuture
        requestBodyWriteFuture = nil

        guard let pendingWrite else {
            requestSpool?.cleanup()
            requestSpool = nil
            return
        }

        pendingWrite.whenComplete { _ in
            self.requestSpool?.cleanup()
            self.requestSpool = nil
        }
    }

    private func appendRequestBody(_ buffer: inout ByteBuffer, context: ChannelHandlerContext) {
        // Body-state fields (requestBody/requestSpool/bodyTooLarge/…) are
        // loop-confined by convention; the spool path threads them through
        // future callbacks, so verify in debug builds.
        context.eventLoop.assertInEventLoop()
        guard buffer.readableBytes > 0, !bodyTooLarge else { return }

        let readableBytes = buffer.readableBytes
        let config = configProvider()
        let currentStoredBytes = requestSpool?.readableBytes ?? requestBody.readableBytes
        guard currentStoredBytes + readableBytes <= config.maxSpooledBodyBytes else {
            bodyTooLarge = true
            return
        }

        if let spool = requestSpool {
            let chunk = buffer
            chainBodyStorage(context: context) { eventLoop in
                spool.append(chunk, eventLoop: eventLoop)
            }
            return
        }

        if requestBody.readableBytes + readableBytes <= config.maxBufferedBodyBytes {
            requestBody.writeBuffer(&buffer)
            return
        }

        var initial = requestBody
        initial.writeBuffer(&buffer)
        let initialBody = initial
        requestBody.clear()
        chainBodyStorage(context: context) { eventLoop in
            SpooledHTTPRequestBody.create(initialBody: initialBody, eventLoop: eventLoop).map { spool in
                self.requestSpool = spool
            }
        }
    }

    private func chainBodyStorage(
        context: ChannelHandlerContext,
        operation: @escaping @Sendable (EventLoop) -> EventLoopFuture<Void>
    ) {
        context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        nonisolated(unsafe) let ctx = context
        let previous = requestBodyWriteFuture ?? ctx.eventLoop.makeSucceededVoidFuture()
        let chained = previous.flatMap {
            operation(ctx.eventLoop)
        }
        requestBodyWriteFuture = chained
        chained.whenComplete { result in
            ctx.eventLoop.assertInEventLoop()
            switch result {
            case .success:
                if ctx.channel.isActive {
                    ctx.channel.setOption(ChannelOptions.autoRead, value: true).whenFailure { _ in }
                }
            case .failure(let error):
                self.bodyStorageError = error
                ctx.close(promise: nil)
            }
        }
    }

    private func finalizeRequestBody(context: ChannelHandlerContext) -> EventLoopFuture<CompletedRequestBody> {
        nonisolated(unsafe) let ctx = context
        let pending = requestBodyWriteFuture ?? ctx.eventLoop.makeSucceededVoidFuture()
        return pending.flatMap {
            ctx.eventLoop.assertInEventLoop()
            if let error = self.bodyStorageError {
                return ctx.eventLoop.makeFailedFuture(error)
            }
            if self.bodyTooLarge {
                let body = self.requestSpool.map { HTTPRequestBody.spooled($0) }
                self.requestSpool = nil
                self.requestBody.clear()
                return ctx.eventLoop.makeSucceededFuture(CompletedRequestBody(body: body, tooLarge: true))
            }
            if let spool = self.requestSpool {
                self.requestSpool = nil
                self.requestBody.clear()
                return spool.finalize(eventLoop: ctx.eventLoop).map {
                    CompletedRequestBody(body: $0, tooLarge: false)
                }
            }
            let body = self.requestBody.readableBytes > 0 ? HTTPRequestBody.memory(self.requestBody) : nil
            self.requestBody.clear()
            return ctx.eventLoop.makeSucceededFuture(CompletedRequestBody(body: body, tooLarge: false))
        }
    }

    private func cachedDirectReachable(target: HTTPRequestTarget) -> Bool {
        if let cached = directConnectDetector.cachedReachability(host: target.host, port: target.port) {
            return cached
        }
        directConnectDetector.probeInBackground(host: target.host, port: target.port)
        return false
    }

    private func directFallbackAllowedByCurrentMode() -> Bool {
        let cause = directModeProvider().1
        return Self.directFallbackAllowed(strictMode: configProvider().strictMode, cause: cause)
    }

    package static func directFallbackAllowed(strictMode: Bool, cause: DirectModeCause) -> Bool {
        cause.allowsUnconditionalDirectRouting || !strictMode
    }

    package static func shouldEvaluatePAC(isDirectMode: Bool, forceProxy: Bool) -> Bool {
        !isDirectMode && !forceProxy
    }

    package static func shouldFallbackToDirectAfterProxyExchangeFailure(hasDirectFallback: Bool, error: Error) -> Bool {
        hasDirectFallback && !ConnectionPoolError.isStreamingResponseInterrupted(error)
    }

    private struct PACResult {
        var route: PACRoute?
        var hasDirectFallback: Bool
        var proxyChain: [UpstreamProxy] = []
    }

    private static func pacResult(from chain: [PACRoute], config: ProxyConfig) -> PACResult {
        return PACResult(
            route: chain.first,
            hasDirectFallback: chain.count > 1 && chain.contains(.direct),
            proxyChain: Self.pacProxyChain(from: chain, config: config)
        )
    }

    package static func pacProxyChain(from routes: [PACRoute], config: ProxyConfig) -> [UpstreamProxy] {
        routes.enumerated().compactMap { index, route in
            guard case .proxy(let host, let port) = route else { return nil }
            if let configured = config.enabledUpstreams.first(where: {
                $0.host.caseInsensitiveCompare(host) == .orderedSame && $0.port == port
            }) {
                return configured
            }
            return UpstreamProxy(
                name: "PAC \(host):\(port)",
                host: host,
                port: port,
                priority: index
            )
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(.warning, "Client-side proxy error: \(error.localizedDescription)", category: .proxy)
        context.close(promise: nil)
    }

    private func handleRequest(
        head: HTTPRequestHead,
        body: HTTPRequestBody?,
        infoID: UUID,
        target: HTTPRequestTarget,
        context: ChannelHandlerContext,
        bypass: Bool,
        directCause: DirectModeCause = .none,
        pacResult: PACResult = PACResult(route: nil, hasDirectFallback: false)
    ) {
        if MetadataBlocklist.isBlocked(host: target.host, gatewayMode: gatewayMode) {
            logger.log(.warning, "Blocked request to \(head.uri) (metadata/loopback protection).", category: .proxy)
            onRequestCompleted(false, nil)
            writeError(status: .forbidden, message: "Request to \(head.uri) is not allowed.", context: context)
            onConnectionClosed(infoID)
            body?.cleanup()
            return
        }

        if head.method == .CONNECT {
            body?.cleanup()
            if bypass {
                handleDirectConnect(head: head, target: target, infoID: infoID, context: context)
            } else {
                let hasDirectFallback = pacResult.hasDirectFallback && directFallbackAllowedByCurrentMode()
                let upstreamFailureLevel = Self.upstreamFailureLogLevel(for: directCause)
                let onConnectionClosed = self.onConnectionClosed
                nonisolated(unsafe) let ctx = context
                connectCoordinator.establishTunnel(
                    requestHead: head,
                    clientContext: ctx,
                    proxyChain: pacResult.proxyChain,
                    onTunnelClosed: { onConnectionClosed(infoID) }
                )
                .hop(to: ctx.eventLoop)
                .whenComplete { result in
                    switch result {
                    case .success(let tunnel):
                        self.logger.log(.notice, "CONNECT tunnel via \(tunnel.endpoint).", category: .proxy)
                        if let authMethod = tunnel.authMethod {
                            self.onConnectionActivity(ConnectionActivity(connectionID: infoID, authMethod: authMethod))
                        }
                        self.onRequestCompleted(true, tunnel.endpoint)
                    case .failure(let error):
                        if hasDirectFallback {
                            self.logger.log(.warning, "CONNECT via upstream failed for \(head.uri), falling back to DIRECT (PAC chain includes DIRECT).", category: .proxy)
                            self.handleDirectConnect(head: head, target: target, infoID: infoID, context: ctx)
                        } else {
                            self.logger.log(upstreamFailureLevel, "CONNECT tunnel failed: \(error.localizedDescription)", category: .proxy)
                            self.onRequestCompleted(false, nil)
                            self.writeError(status: .badGateway, message: error.localizedDescription, context: ctx)
                            self.onConnectionClosed(infoID)
                        }
                    }
                }
            }
            return
        }

        if HTTPHopByHopHeaders.isUpgradeRequest(head) {
            // Protocol upgrades (WebSocket et al.) cannot ride the pooled
            // streaming exchange: after `101` the connection stops being
            // HTTP and can never return to the pool, and corporate upstream
            // proxies expect CONNECT for upgrades anyway (RFC 6455 §4.1 —
            // browsers do exactly that, and CONNECT already works). Relay
            // upgrades over a dedicated direct origin connection when policy
            // permits; otherwise refuse loudly instead of silently stripping
            // the `Upgrade` header and breaking the handshake.
            if !bypass && !directFallbackAllowedByCurrentMode() {
                logger.log(.warning, "Upgrade request for \(head.uri) needs a direct origin connection, but strict mode forbids direct routing; rejecting. WebSocket clients should use CONNECT through the upstream proxy.", category: .proxy)
                onRequestCompleted(false, nil)
                writeError(status: .badGateway, message: "Protocol upgrades require CONNECT through the upstream proxy in strict mode.", context: context)
                onConnectionClosed(infoID)
                body?.cleanup()
                return
            }
            if !bypass {
                logger.log(.info, "Routing Upgrade request for \(head.uri) direct (upstream proxies require CONNECT for protocol upgrades).", category: .proxy)
            }
            handleUpgradeRequest(head: head, body: body, infoID: infoID, target: target, context: context)
            return
        }

        if bypass {
            handleDirectHTTP(head: head, body: body, infoID: infoID, target: target, context: context)
            return
        }

        let hasDirectFallback = pacResult.hasDirectFallback && directFallbackAllowedByCurrentMode()
        let upstreamFailureLevel = Self.upstreamFailureLogLevel(for: directCause)
        nonisolated(unsafe) let ctx = context
        let clientEL = ctx.eventLoop
        pool.streamingExchange(
            head: head,
            requestBody: body,
            clientChannel: ctx.channel,
            authSource: authSource,
            forcedProxy: pacResult.proxyChain.first
        )
            .hop(to: clientEL)
            .whenComplete { result in
                switch result {
                case .success(let exchangeResult):
                    if let authMethod = exchangeResult.authMethod {
                        self.onConnectionActivity(ConnectionActivity(connectionID: infoID, authMethod: authMethod))
                    }
                    self.onRequestCompleted(true, exchangeResult.upstream.endpoint)
                    self.onConnectionClosed(infoID)
                    body?.cleanup()
                case .failure(let error):
                    if Self.shouldFallbackToDirectAfterProxyExchangeFailure(
                        hasDirectFallback: hasDirectFallback,
                        error: error
                    ) {
                        self.logger.log(.warning, "Proxy exchange failed for \(head.uri), falling back to DIRECT.", category: .proxy)
                        self.handleDirectHTTP(head: head, body: body, infoID: infoID, target: target, context: ctx)
                    } else {
                        self.logger.log(upstreamFailureLevel, "Proxy exchange failed: \(error.localizedDescription)", category: .proxy)
                        self.onRequestCompleted(false, nil)
                        if ctx.channel.isActive {
                            self.writeError(status: .badGateway, message: error.localizedDescription, context: ctx)
                        }
                        self.onConnectionClosed(infoID)
                        body?.cleanup()
                    }
                }
            }
    }

    private func handleDirectHTTP(
        head: HTTPRequestHead,
        body: HTTPRequestBody?,
        infoID: UUID,
        target: HTTPRequestTarget,
        context: ChannelHandlerContext
    ) {
        guard let url = target.directURL else {
            writeError(status: .badRequest, message: "Invalid direct URL for \(head.uri)", context: context)
            body?.cleanup()
            onConnectionClosed(infoID)
            return
        }

        let host = url.host ?? ""
        let port = url.port ?? 80

        logger.log(.info, "DIRECT HTTP \(head.method.rawValue) \(url.absoluteString)", category: .proxy)

        let clientChannel = context.channel
        let clientEL = context.eventLoop
        let logger = self.logger
        let onRequestCompleted = self.onRequestCompleted
        let onConnectionClosed = self.onConnectionClosed
        // Capture cause once for log-severity decisions in the failure handlers.
        // We snapshot here rather than re-querying inside the closures so the
        // log severity reflects the cause as of when the request started, not
        // a possibly-different cause millisecond-later if a flap fires mid-request.
        let directFailureLevel = Self.directFailureLogLevel(for: directModeProvider().1)

        directConnectWithFallback(
            host: host,
            port: port,
            clientEL: clientEL,
            channelInitializer: { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder())
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)))
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        )
            .whenComplete { result in
                switch result {
                case .success(let upstream):
                    let forwarder = DirectHTTPResponseForwarder(
                        clientChannel: clientChannel,
                        onComplete: {
                            onRequestCompleted(true, "DIRECT")
                            onConnectionClosed(infoID)
                            body?.cleanup()
                            upstream.close(mode: .all, promise: nil)
                        },
                        onError: { error in
                            logger.log(directFailureLevel, "Direct HTTP relay failed: \(error.localizedDescription)", category: .proxy)
                            clientEL.execute {
                                if clientChannel.isActive {
                                    var head = HTTPResponseHead(version: .http1_1, status: .badGateway)
                                    let content = "Conduit could not complete the request.\n\n\(error.localizedDescription)"
                                    var buffer = clientChannel.allocator.buffer(capacity: content.utf8.count)
                                    buffer.writeString(content)
                                    head.headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
                                    head.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                                    clientChannel.write(HTTPServerResponsePart.head(head), promise: nil)
                                    clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                                    clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                                }
                            }
                            onRequestCompleted(false, nil)
                            onConnectionClosed(infoID)
                            body?.cleanup()
                        }
                    )
                    upstream.pipeline.addHandler(forwarder).whenSuccess {
                        var reqHead = head
                        let path = url.path.isEmpty ? "/" : url.path
                        reqHead.uri = url.query.map { "\(path)?\($0)" } ?? path
                        HTTPHopByHopHeaders.sanitizeForwardedRequestHeaders(&reqHead.headers)
                        upstream.write(HTTPClientRequestPart.head(reqHead), promise: nil)
                        let bodyFuture = body?.writeClientBody(channel: upstream)
                            ?? upstream.eventLoop.makeSucceededVoidFuture()
                        bodyFuture.flatMap {
                            upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
                        }.whenFailure { error in
                            logger.log(directFailureLevel, "Direct HTTP request write failed: \(error.localizedDescription)", category: .proxy)
                            onRequestCompleted(false, nil)
                            onConnectionClosed(infoID)
                            body?.cleanup()
                            clientChannel.close(mode: .all, promise: nil)
                            upstream.close(mode: .all, promise: nil)
                        }
                    }
                case .failure(let error):
                    logger.log(directFailureLevel, "Direct connect to \(host):\(port) failed: \(error.localizedDescription)", category: .proxy)
                    onRequestCompleted(false, nil)
                    body?.cleanup()
                    clientEL.execute {
                        if clientChannel.isActive {
                            var head = HTTPResponseHead(version: .http1_1, status: .badGateway)
                            let content = "Conduit could not complete the request.\n\n\(error.localizedDescription)"
                            var buffer = clientChannel.allocator.buffer(capacity: content.utf8.count)
                            buffer.writeString(content)
                            head.headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
                            head.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
                            clientChannel.write(HTTPServerResponsePart.head(head), promise: nil)
                            clientChannel.write(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                            clientChannel.writeAndFlush(HTTPServerResponsePart.end(nil), promise: nil)
                        }
                    }
                    onConnectionClosed(infoID)
                }
            }
    }

    /// Relay an HTTP/1.1 Upgrade request (WebSocket et al.) over a dedicated
    /// direct origin connection. The upstream response decides the shape:
    /// `101 Switching Protocols` splices both pipelines into the same raw
    /// relay the direct CONNECT path uses; anything else is forwarded as a
    /// normal one-shot HTTP response and both connections close (a refused
    /// upgrade never returns to keep-alive).
    private func handleUpgradeRequest(
        head: HTTPRequestHead,
        body: HTTPRequestBody?,
        infoID: UUID,
        target: HTTPRequestTarget,
        context: ChannelHandlerContext
    ) {
        guard let url = target.directURL else {
            writeError(status: .badRequest, message: "Invalid direct URL for \(head.uri)", context: context)
            body?.cleanup()
            onConnectionClosed(infoID)
            return
        }

        let host = url.host ?? ""
        let port = url.port ?? 80

        logger.log(.info, "DIRECT upgrade \(head.method.rawValue) \(url.absoluteString) (Upgrade: \(head.headers["Upgrade"].joined(separator: ", ")))", category: .proxy)

        nonisolated(unsafe) let ctx = context
        let clientChannel = context.channel
        let clientEL = context.eventLoop
        let logger = self.logger
        let onRequestCompleted = self.onRequestCompleted
        let onConnectionClosed = self.onConnectionClosed
        let directFailureLevel = Self.directFailureLogLevel(for: directModeProvider().1)

        directConnectWithFallback(
            host: host,
            port: port,
            clientEL: clientEL,
            channelInitializer: { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        HTTPRequestEncoder(), name: UpgradePipelineNames.upstreamEncoder)
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: UpgradePipelineNames.upstreamDecoder)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
        )
            .whenComplete { result in
                switch result {
                case .success(let upstream):
                    let relay = HTTPUpgradeResponseRelay(
                        clientChannel: clientChannel,
                        targetDescription: "\(host):\(port)",
                        logger: logger,
                        failureLevel: directFailureLevel,
                        onTunnelEstablished: {
                            onRequestCompleted(true, "DIRECT")
                        },
                        onRefusedResponseComplete: {
                            onRequestCompleted(true, "DIRECT")
                            onConnectionClosed(infoID)
                            body?.cleanup()
                        },
                        onFailure: {
                            onRequestCompleted(false, nil)
                            onConnectionClosed(infoID)
                            body?.cleanup()
                        },
                        onTunnelClosed: { onConnectionClosed(infoID) }
                    )
                    upstream.pipeline.addHandler(relay).whenSuccess {
                        var reqHead = head
                        let path = url.path.isEmpty ? "/" : url.path
                        reqHead.uri = url.query.map { "\(path)?\($0)" } ?? path
                        HTTPHopByHopHeaders.sanitizeForwardedUpgradeRequestHeaders(&reqHead.headers)
                        upstream.write(HTTPClientRequestPart.head(reqHead), promise: nil)
                        let bodyFuture = body?.writeClientBody(channel: upstream)
                            ?? upstream.eventLoop.makeSucceededVoidFuture()
                        bodyFuture.flatMap {
                            upstream.writeAndFlush(HTTPClientRequestPart.end(nil))
                        }.whenFailure { error in
                            logger.log(directFailureLevel, "Upgrade request write failed: \(error.localizedDescription)", category: .proxy)
                            onRequestCompleted(false, nil)
                            onConnectionClosed(infoID)
                            body?.cleanup()
                            clientChannel.close(mode: .all, promise: nil)
                            upstream.close(mode: .all, promise: nil)
                        }
                    }
                case .failure(let error):
                    logger.log(directFailureLevel, "Direct connect for upgrade to \(host):\(port) failed: \(error.localizedDescription)", category: .proxy)
                    onRequestCompleted(false, nil)
                    body?.cleanup()
                    self.writeError(status: .badGateway, message: error.localizedDescription, context: ctx)
                    onConnectionClosed(infoID)
                }
            }
    }

    private func handleDirectConnect(head: HTTPRequestHead, target: HTTPRequestTarget, infoID: UUID, context: ChannelHandlerContext) {
        let host = target.host
        let port = target.port
        nonisolated(unsafe) let ctx = context
        let clientEL = ctx.eventLoop
        let directFailureLevel = Self.directFailureLogLevel(for: directModeProvider().1)

        logger.log(.info, "DIRECT CONNECT to \(host):\(port)", category: .proxy)

        directConnectWithFallback(host: host, port: port, clientEL: clientEL)
            .whenComplete { result in
                switch result {
                case .success(let upstreamChannel):
                    self.attachDirectTunnel(
                        clientContext: ctx,
                        upstreamChannel: upstreamChannel,
                        target: "\(host):\(port)",
                        infoID: infoID,
                        directFailureLevel: directFailureLevel
                    )
                case .failure(let error):
                    self.logger.log(directFailureLevel, "Direct connect to \(host):\(port) failed: \(error.localizedDescription)", category: .proxy)
                    self.onRequestCompleted(false, nil)
                    self.writeError(status: .badGateway, message: error.localizedDescription, context: ctx)
                    self.onConnectionClosed(infoID)
                }
            }
    }

    /// Connect to `host:port` with a half-open-channel guard and explicit-IPv4
    /// fallback.
    ///
    /// The default `ClientBootstrap.connect(host:port:)` goes through NIO's
    /// `HappyEyeballsConnector`, which in some VPN-on dual-stack environments
    /// returns a supposedly-active channel whose TCP state is actually
    /// half-open (`remoteAddress == nil`, `localAddress` is a link-local
    /// `fe80::…/…` IPv6). Writes to such a channel fail immediately with
    /// `ENOTCONN`, collapsing the tunnel before any byte reaches the wire —
    /// observed against Microsoft 365 CDN hosts on a corporate VPN where
    /// global IPv6 is unroutable but an IPv6 SYN slips into the "connecting"
    /// state long enough for happy-eyeballs to pick it over the IPv4 alternate.
    ///
    /// Strategy:
    /// 1. Try happy-eyeballs as usual.
    /// 2. If it succeeds but the resulting channel has `remoteAddress == nil`,
    ///    treat that as a failure: close the bogus channel and proceed to step 3.
    /// 3. Resolve `host` via `getaddrinfo(AF_INET)` ourselves, pick the first
    ///    A record, and connect to it explicitly via
    ///    `ClientBootstrap.connect(to:)` — which bypasses happy-eyeballs
    ///    and the AAAA branch entirely.
    /// 4. If no IPv4 address exists, propagate the fallback error.
    ///
    /// Hosts whose first happy-eyeballs pick is a reachable IPv4 (the common
    /// case, including internal hosts that only have A records) never
    /// trip this path — the flatMap observes a non-nil `remoteAddress` and
    /// hands the channel through with zero overhead.
    private func directConnectWithFallback(
        host: String,
        port: Int,
        clientEL: EventLoop,
        channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil
    ) -> EventLoopFuture<Channel> {
        let eventLoopGroup = self.eventLoopGroup
        let logger = self.logger
        let gatewayMode = self.gatewayMode

        let makeBootstrap: @Sendable () -> ClientBootstrap = {
            let bootstrap = ClientBootstrap(group: eventLoopGroup)
                .connectTimeout(.seconds(10))
                .channelOption(ChannelOptions.tcpNoDelay, value: 1)
            if let channelInitializer {
                return bootstrap.channelInitializer(channelInitializer)
            }
            return bootstrap
        }

        return makeBootstrap()
            .connect(host: host, port: port)
            .hop(to: clientEL)
            .flatMap { upstreamChannel in
                if upstreamChannel.remoteAddress == nil {
                    logger.log(.warning, "Half-open channel detected for \(host):\(port) (remoteAddress nil, localAddress \(String(describing: upstreamChannel.localAddress))); falling back to explicit IPv4 connect", category: .proxy)
                }
                return Self.applyHalfOpenFallback(
                    upstreamChannel: upstreamChannel,
                    host: host,
                    port: port,
                    on: clientEL,
                    ipv4Reconnect: { address in
                        logger.log(.info, "Half-open fallback: reconnecting to \(host):\(port) via IPv4 \(address)", category: .proxy)
                        return makeBootstrap()
                            .connect(to: address)
                            .hop(to: clientEL)
                    }
                )
            }
            .flatMapThrowing { channel in
                // DNS-rebinding guard: re-check the *resolved* peer against the
                // metadata/loopback blocklist. The pre-connect host check can't
                // see a hostname that resolves to a blocked literal. Direct path
                // only — upstream-proxy connections are operator-configured.
                if gatewayMode,
                   let ip = channel.remoteAddress?.ipAddress,
                   MetadataBlocklist.isBlockedResolvedAddress(ip, gatewayMode: gatewayMode) {
                    logger.log(.warning, "Blocked direct connection to \(host):\(port): resolved to \(ip) (metadata/loopback protection).", category: .proxy)
                    channel.close(promise: nil)
                    throw MetadataBlocklist.BlockedAddressError(host: host, resolvedIP: ip)
                }
                return channel
            }
    }

    /// Half-open-guard decision, split out from `directConnectWithFallback` so
    /// it can be unit-tested without standing up a live happy-eyeballs
    /// connector. If `upstreamChannel.remoteAddress` is non-nil, we believe
    /// the TCP state is healthy and pass the channel through unchanged. If
    /// it's nil, we close the bogus channel and hand off to the caller's
    /// `ipv4Reconnect` after resolving `host` to a first-A-record
    /// `SocketAddress`.
    ///
    /// Kept `package static` (rather than `private`) so
    /// `DirectIPv4FallbackTests` can exercise both branches with
    /// `EmbeddedChannel` (nil-remoteAddress) and a loopback
    /// `ClientBootstrap` channel (non-nil remoteAddress) without duplicating
    /// the full connect flow.
    package static func applyHalfOpenFallback(
        upstreamChannel: Channel,
        host: String,
        port: Int,
        on clientEL: EventLoop,
        ipv4Reconnect: @escaping @Sendable (SocketAddress) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        HalfOpenChannelFallback.apply(
            upstreamChannel: upstreamChannel,
            host: host,
            port: port,
            on: clientEL,
            ipv4Reconnect: ipv4Reconnect
        )
    }

    /// Resolve `host` to the first IPv4 `SocketAddress`. Uses `getaddrinfo`
    /// on a background queue — acceptable because we only enter this path in
    /// the rare half-open-fallback branch. An explicit 10-second timeout races
    /// the `getaddrinfo` call so a blocked system resolver (e.g. DNS server
    /// unreachable with no negative caching) cannot hang the client
    /// indefinitely. Returns a failed future (`DirectIPv4FallbackError`) if
    /// `getaddrinfo` errors, no A record exists, or the timeout fires first.
    ///
    /// `package static` so `DirectIPv4FallbackTests` can verify the
    /// getaddrinfo path against `localhost` (A-record always available) and
    /// against a deliberately-invalid host.
    package static func resolveIPv4(
        host: String,
        port: Int,
        on eventLoop: EventLoop
    ) -> EventLoopFuture<SocketAddress> {
        HalfOpenChannelFallback.resolveIPv4(host: host, port: port, on: eventLoop)
    }

    /// Choose log severity for direct-route failures based on the cause that put
    /// us in direct mode. Expected causes (VPN off, no upstreams configured,
    /// transient flap) demote to `.info` because direct-route failures of
    /// corp-internal hosts are the *expected* outcome in those states. Only
    /// `.upstreamsUnreachable` (and the impossible `.none` case here) keep the
    /// historical `.error` severity. See Phase 2 of the design doc.
    static func directFailureLogLevel(for cause: DirectModeCause) -> LogLevel {
        cause.isExpected ? .info : .error
    }

    static func upstreamFailureLogLevel(for cause: DirectModeCause) -> LogLevel {
        cause == .transientNetworkChange ? .info : .error
    }

    private func attachDirectTunnel(
        clientContext: ChannelHandlerContext,
        upstreamChannel: Channel,
        target: String,
        infoID: UUID,
        directFailureLevel: LogLevel
    ) {
        let clientChannel = clientContext.channel
        let logger = self.logger
        let onRequestCompleted = self.onRequestCompleted
        let onConnectionClosed = self.onConnectionClosed

        // Edge (and Chromium in general) happily reset the CONNECT while we're
        // still waiting on the upstream TCP connect — connectTimeout is 10s, and
        // a user navigating away or the kernel dropping the TCP half-open is
        // plenty to close the client socket by the time we get here. Splicing a
        // tunnel into a dead pipeline yields `ChannelPipelineError.notFound`
        // (surfaced as the opaque "ChannelPipelineError error 1" in logs) and
        // leaks the upstream channel. Short-circuit on the fast path.
        guard clientChannel.isActive else {
            logger.log(directFailureLevel, "Direct tunnel to \(target): client closed before upstream ready; discarding.", category: .proxy)
            upstreamChannel.close(mode: .all, promise: nil)
            onRequestCompleted(false, nil)
            onConnectionClosed(infoID)
            return
        }

        var responseHead = HTTPResponseHead(version: .http1_1, status: .ok)
        responseHead.headers.add(name: "Content-Length", value: "0")

        clientContext.write(wrapOutboundOut(.head(responseHead)), promise: nil)
        clientContext.writeAndFlush(wrapOutboundOut(.end(nil)))
            .flatMap {
                // Typed handlers must leave before the decoder so its
                // leftover raw bytes can never reach a typed unwrap.
                clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverExpectContinue)
            }
            .flatMap {
                clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverDecoder)
            }
            .flatMap {
                clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverEncoder)
            }
            .flatMap {
                clientChannel.pipeline.removeHandler(name: ProxyPipelineNames.serverHandler)
            }
            .flatMap { () -> EventLoopFuture<Void> in
                let clientRelay = DirectTunnelRelay(peer: upstreamChannel, onClose: { onConnectionClosed(infoID) })
                let upstreamRelay = DirectTunnelRelay(peer: clientChannel)
                return clientChannel.pipeline.addHandler(clientRelay).flatMap {
                    upstreamChannel.pipeline.addHandler(upstreamRelay)
                }
            }
            .whenComplete { result in
                switch result {
                case .success:
                    onRequestCompleted(true, "DIRECT")
                case .failure(let error):
                    // A pipeline lookup failure here means the client-side pipeline
                    // was torn down mid-setup (browser disconnected, TCP reset, or
                    // the listener recycled out from under us). That's an expected
                    // race in direct mode — log it at the cause-derived severity
                    // rather than `.error` so the UI doesn't flag a VPN-off
                    // session as broken.
                    let level: LogLevel = Self.isBenignTunnelSetupRace(error) ? directFailureLevel : .error
                    logger.log(level, "Direct tunnel to \(target) aborted during setup: \(error.localizedDescription)", category: .proxy)
                    clientChannel.close(mode: .all, promise: nil)
                    upstreamChannel.close(mode: .all, promise: nil)
                    onRequestCompleted(false, nil)
                    onConnectionClosed(infoID)
                }
            }
    }

    /// True when the tunnel-setup error looks like "client went away before we
    /// finished splicing", i.e. one of the two pipeline-lookup failures from
    /// `removeHandler(name:)` on a torn-down pipeline, or a closed-channel I/O
    /// failure on the inline write of the 200 response. The distinction matters
    /// because these races happen in normal direct-mode operation (Edge closes
    /// CONNECT tunnels aggressively) and shouldn't pollute the error stream.
    static func isBenignTunnelSetupRace(_ error: Error) -> Bool {
        if let pipelineError = error as? ChannelPipelineError {
            switch pipelineError {
            case .notFound, .alreadyRemoved: return true
            }
        }
        if let channelError = error as? ChannelError {
            switch channelError {
            case .ioOnClosedChannel, .alreadyClosed, .eof: return true
            default: return false
            }
        }
        return false
    }

    @discardableResult
    private func writeError(status: HTTPResponseStatus, message: String, context: ChannelHandlerContext) -> EventLoopFuture<Void> {
        var head = HTTPResponseHead(version: .http1_1, status: status)
        let content = "Conduit could not complete the request.\n\n\(message)"
        var buffer = context.channel.allocator.buffer(capacity: content.utf8.count)
        buffer.writeString(content)
        head.headers.add(name: "Content-Length", value: "\(buffer.readableBytes)")
        head.headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        return context.writeAndFlush(wrapOutboundOut(.end(nil)))
    }
}

enum UpgradePipelineNames {
    static let upstreamEncoder = "upgradeUpstreamEncoder"
    static let upstreamDecoder = "upgradeUpstreamDecoder"
}

/// Upstream-side handler for a relayed HTTP/1.1 Upgrade exchange.
///
/// Lives on the dedicated origin connection's pipeline behind the HTTP
/// client codec. On `101 Switching Protocols` it delivers the response head
/// to the client and performs the pipeline splice (client first, then
/// upstream — the client's HTTP encoder must be gone before raw upstream
/// bytes can be relayed at it). On any other status it forwards the refusal
/// as a one-shot HTTP response and closes both connections.
///
/// Splice ordering on the upstream side is load-bearing: this handler must
/// remove *itself* before the `ByteToMessageHandler`, because the decoder's
/// `.forwardBytes` leftovers (frames the origin sent immediately after the
/// 101) are delivered to the next inbound handler — which must be the raw
/// `DirectTunnelRelay`, not this typed handler.
final class HTTPUpgradeResponseRelay: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private enum State {
        case awaitingHead
        case splicing
        case forwardingRefusal
        case done
    }

    private let clientChannel: Channel
    private let targetDescription: String
    private let logger: any LogSink
    private let failureLevel: LogLevel
    private let onTunnelEstablished: @Sendable () -> Void
    private let onRefusedResponseComplete: @Sendable () -> Void
    private let onFailure: @Sendable () -> Void
    private let onTunnelClosed: @Sendable () -> Void
    private var state: State = .awaitingHead

    init(
        clientChannel: Channel,
        targetDescription: String,
        logger: any LogSink,
        failureLevel: LogLevel,
        onTunnelEstablished: @escaping @Sendable () -> Void,
        onRefusedResponseComplete: @escaping @Sendable () -> Void,
        onFailure: @escaping @Sendable () -> Void,
        onTunnelClosed: @escaping @Sendable () -> Void
    ) {
        self.clientChannel = clientChannel
        self.targetDescription = targetDescription
        self.logger = logger
        self.failureLevel = failureLevel
        self.onTunnelEstablished = onTunnelEstablished
        self.onRefusedResponseComplete = onRefusedResponseComplete
        self.onFailure = onFailure
        self.onTunnelClosed = onTunnelClosed
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch (state, part) {
        case (.awaitingHead, .head(let head)) where head.status == .switchingProtocols:
            splice(responseHead: head, context: context)
        case (.awaitingHead, .head(let head)):
            state = .forwardingRefusal
            var sanitized = head
            HTTPHopByHopHeaders.sanitizeForwardedResponseHeaders(&sanitized.headers)
            // A refused upgrade never returns this client connection to
            // keep-alive: the client asked to leave HTTP and we are about to
            // close, so say so explicitly.
            sanitized.headers.replaceOrAdd(name: "Connection", value: "close")
            clientChannel.write(HTTPServerResponsePart.head(sanitized), promise: nil)
        case (.forwardingRefusal, .body(let body)):
            clientChannel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
        case (.forwardingRefusal, .end(let trailers)):
            state = .done
            let upstreamChannel = context.channel
            let onRefusedResponseComplete = self.onRefusedResponseComplete
            let client = clientChannel
            clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete { _ in
                onRefusedResponseComplete()
                client.close(mode: .all, promise: nil)
                upstreamChannel.close(mode: .all, promise: nil)
            }
        case (.splicing, .end), (.splicing, .body), (.done, _):
            // The decoder may emit the 101's `.end` (and nothing else) while
            // the splice futures are still in flight; ignore it.
            break
        case (.awaitingHead, .body), (.awaitingHead, .end), (.forwardingRefusal, .head), (.splicing, .head):
            logger.log(failureLevel, "Unexpected HTTP part during upgrade relay to \(targetDescription); aborting.", category: .proxy)
            failAndClose(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        logger.log(failureLevel, "Upgrade relay to \(targetDescription) failed: \(error.localizedDescription)", category: .proxy)
        failAndClose(context: context)
    }

    func channelInactive(context: ChannelHandlerContext) {
        if state == .awaitingHead || state == .forwardingRefusal {
            logger.log(failureLevel, "Origin closed during upgrade handshake with \(targetDescription).", category: .proxy)
            failAndClose(context: context)
        }
        context.fireChannelInactive()
    }

    private func failAndClose(context: ChannelHandlerContext) {
        guard state != .done else { return }
        state = .done
        onFailure()
        context.close(promise: nil)
        let client = clientChannel
        clientChannel.eventLoop.execute {
            client.close(mode: .all, promise: nil)
        }
    }

    private func splice(responseHead: HTTPResponseHead, context: ChannelHandlerContext) {
        state = .splicing
        var sanitized = responseHead
        HTTPHopByHopHeaders.sanitizeForwardedUpgradeResponseHeaders(&sanitized.headers)

        // Ordering invariant: no raw byte may ever be written through a
        // pipeline that still has an HTTP codec installed (NIO's encoders
        // fatal-error on type mismatch — caught by the ASan soak before
        // landing). Two directions, one rule each:
        //
        //   client→upstream: the upstream HTTPRequestEncoder must be gone
        //   before the client can possibly send a frame. The client cannot
        //   send until it has SEEN the 101 — so all upstream-side surgery
        //   happens BEFORE the 101 is released to the client, with the
        //   upstream relay paused (bounded buffer) so early origin frames
        //   wait.
        //
        //   upstream→client: the client HTTPResponseEncoder must be gone
        //   before any raw origin byte is relayed at the client. The paused
        //   upstream relay holds origin frames (and the decoder's leftover
        //   bytes) until client-side surgery completes; resume flushes them.
        //
        // While either decoder remains installed, post-upgrade bytes are
        // safe: both NIO HTTP decoders enter upgrade mode after a 101/
        // upgrade request and buffer instead of parsing, delivering the
        // bytes raw on removal (`.forwardBytes`).
        let upstreamRelay = DirectTunnelRelay(peer: clientChannel, startPaused: true)

        // Defer one tick: the decoder delivers the 101's `.head` and `.end`
        // in the same read burst. The chain below removes this handler from
        // the pipeline, and if that completes inline (same-loop pipeline ops
        // do), the burst's trailing `.end` would land on the raw-typed relay
        // and fatal-error. After this tick the decoder is in upgrade mode
        // and emits nothing but leftover raw bytes on removal.
        nonisolated(unsafe) let ctx = context
        context.eventLoop.execute {
            self.runSpliceChain(
                context: ctx,
                upstreamRelay: upstreamRelay,
                sanitizedHead: sanitized
            )
        }
    }

    private func runSpliceChain(
        context: ChannelHandlerContext,
        upstreamRelay: DirectTunnelRelay,
        sanitizedHead: HTTPResponseHead
    ) {
        let sanitized = sanitizedHead
        let upstreamChannel = context.channel
        let client = clientChannel
        let onTunnelEstablished = self.onTunnelEstablished
        let onTunnelClosed = self.onTunnelClosed
        let logger = self.logger
        let failureLevel = self.failureLevel
        let targetDescription = self.targetDescription

        context.pipeline.addHandler(upstreamRelay)
            .flatMap {
                // Self before decoder: leftovers must land on the raw relay.
                upstreamChannel.pipeline.removeHandler(self)
            }
            .flatMap {
                upstreamChannel.pipeline.removeHandler(name: UpgradePipelineNames.upstreamDecoder)
            }
            .flatMap {
                upstreamChannel.pipeline.removeHandler(name: UpgradePipelineNames.upstreamEncoder)
            }
            .flatMap {
                // Upstream side is fully raw (and paused); release the 101.
                client.writeAndFlush(HTTPServerResponsePart.head(sanitized))
            }
            .hop(to: client.eventLoop)
            .flatMap {
                client.pipeline.removeHandler(name: ProxyPipelineNames.serverHandler)
            }
            .flatMap {
                client.pipeline.removeHandler(name: ProxyPipelineNames.serverEncoder)
            }
            .flatMap {
                client.pipeline.removeHandler(name: ProxyPipelineNames.serverExpectContinue)
            }
            .flatMap {
                client.pipeline.addHandler(DirectTunnelRelay(peer: upstreamChannel, onClose: onTunnelClosed))
            }
            .flatMap {
                // Decoder last: its leftover bytes (frames the client sent
                // after the 101 while surgery was in flight) land on the
                // relay just installed — every typed handler is gone by now.
                client.pipeline.removeHandler(name: ProxyPipelineNames.serverDecoder)
            }
            .hop(to: upstreamChannel.eventLoop)
            .whenComplete { result in
                // `state` and the paused relay are upstream-loop-confined.
                upstreamChannel.eventLoop.assertInEventLoop()
                switch result {
                case .success:
                    upstreamRelay.resumeForwarding()
                    self.state = .done
                    onTunnelEstablished()
                case .failure(let error):
                    self.state = .done
                    let level: LogLevel = HTTPProxyHandler.isBenignTunnelSetupRace(error) ? failureLevel : .error
                    logger.log(level, "Upgrade splice to \(targetDescription) aborted: \(error.localizedDescription)", category: .proxy)
                    self.onFailure()
                    client.close(mode: .all, promise: nil)
                    upstreamChannel.close(mode: .all, promise: nil)
                }
            }
    }
}

final class DirectHTTPResponseForwarder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart

    private let clientChannel: Channel
    private let onComplete: () -> Void
    private let onError: (Error) -> Void
    private var backpressure: HTTPResponseBackpressureController?

    init(clientChannel: Channel, onComplete: @escaping () -> Void, onError: @escaping (Error) -> Void) {
        self.clientChannel = clientChannel
        self.onComplete = onComplete
        self.onError = onError
    }

    func handlerAdded(context: ChannelHandlerContext) {
        let controller = HTTPResponseBackpressureController(
            clientChannel: clientChannel,
            upstreamChannel: context.channel
        )
        backpressure = controller
        controller.install()
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        backpressure?.complete()
        backpressure = nil
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            var sanitized = head
            HTTPHopByHopHeaders.sanitizeForwardedResponseHeaders(&sanitized.headers)
            if let backpressure {
                backpressure.write(.head(sanitized), flush: false, upstreamContext: context)
            } else {
                clientChannel.write(HTTPServerResponsePart.head(sanitized), promise: nil)
            }
        case .body(let body):
            if let backpressure {
                backpressure.write(.body(.byteBuffer(body)), flush: true, upstreamContext: context)
            } else {
                clientChannel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(body)), promise: nil)
            }
        case .end(let trailers):
            let completion: @Sendable (Result<Void, Error>) -> Void = { result in
                self.backpressure?.complete()
                if case .failure(let error) = result {
                    self.onError(error)
                    return
                }
                self.onComplete()
            }
            if let backpressure {
                backpressure.write(.end(trailers), flush: true, upstreamContext: context).whenComplete(completion)
            } else {
                clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete(completion)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        backpressure?.complete()
        context.close(promise: nil)
        onError(error)
    }

    func channelInactive(context: ChannelHandlerContext) {
        context.fireChannelInactive()
    }
}

private final class DirectTunnelRelay: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    let peer: Channel
    let onClose: (() -> Void)?

    /// Paused mode (upgrade splice): inbound bytes are buffered (bounded)
    /// until `resumeForwarding()` releases them, so frames the peer sends
    /// during pipeline surgery never reach a channel that still has an HTTP
    /// codec installed. All access is on this handler's channel event loop.
    private var paused: Bool
    private var pausedBuffer: [ByteBuffer] = []
    private var pausedBytes = 0
    private static let maxPausedBytes = 1 << 20

    init(peer: Channel, startPaused: Bool = false, onClose: (() -> Void)? = nil) {
        self.peer = peer
        self.paused = startPaused
        self.onClose = onClose
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if paused {
            pausedBytes += buf.readableBytes
            guard pausedBytes <= Self.maxPausedBytes else {
                // Bound everything: a peer flooding during the (millisecond)
                // splice window doesn't get unbounded memory.
                peer.close(mode: .all, promise: nil)
                context.close(promise: nil)
                return
            }
            pausedBuffer.append(buf)
            return
        }
        peer.writeAndFlush(buf, promise: nil)
        if !peer.isWritable {
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
        }
    }

    /// Must be called on this handler's channel event loop.
    func resumeForwarding() {
        guard paused else { return }
        paused = false
        let buffered = pausedBuffer
        pausedBuffer.removeAll()
        pausedBytes = 0
        for buf in buffered {
            peer.writeAndFlush(buf, promise: nil)
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
        gracefulClosePeer()
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
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
        peer.writeAndFlush(peer.allocator.buffer(capacity: 0)).whenComplete { _ in
            peer.close(mode: .all, promise: nil)
        }
    }
}
