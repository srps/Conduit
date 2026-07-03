// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

package final class LocalProxyServer: @unchecked Sendable, RecoverableProxyService {
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    /// Returns `(isDirect, cause)` so request handlers can branch on the cause
    /// (log severity, telemetry) without a separate state lookup. Reads from the
    /// orchestrator's `directModeBox`. See `DirectModeCause` and Phase 2 of
    /// `docs/design-vpn-flap-resilience.md`.
    private let directModeProvider: () -> (Bool, DirectModeCause)
    private let authenticatorProvider: (String) throws -> ProxyAuthenticator
    private let directConnectDetector: DirectConnectDetector
    private let pacRoutingEngine: PACRoutingEngine?
    private let onConnectionOpened: @Sendable (ActiveConnectionInfo) -> Void
    private let onConnectionClosed: @Sendable (UUID) -> Void
    private let onConnectionActivity: @Sendable (ConnectionActivity) -> Void
    private let onRequestCompleted: @Sendable (Bool, String?) -> Void
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let authHandshakeLimiter = AuthHandshakeLimiter()
    private let group = MultiThreadedEventLoopGroup.singleton
    private let inboundConnectionCountBox = NIOLockedValueBox(0)
    private let lastWarnLoggedAt = NIOLockedValueBox<Date>(Date.distantPast)

    private var serverChannel: Channel?
    private var connectionPool: ConnectionPool?
    private var connectCoordinator: CONNECTCoordinator?
    private var socksServer: SOCKS5Server?

    package var listeningHost: String? {
        serverChannel?.localAddress?.ipAddress
    }

    package var listeningPort: Int? {
        serverChannel?.localAddress?.port
    }

    package var socksListeningHost: String? {
        socksServer?.listeningHost
    }

    package var socksListeningPort: Int? {
        socksServer?.listeningPort
    }

    package var inboundConnectionCount: Int {
        inboundConnectionCountBox.withLockedValue { $0 }
    }

    private func authHandshakeLimits() -> AuthHandshakeLimiter.Limits {
        let config = configProvider()
        return AuthHandshakeLimiter.Limits(
            total: config.pendingAuthHandshakeGlobalLimit,
            perSource: config.pendingAuthHandshakesPerSource
        )
    }

    package init(
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        directModeProvider: @escaping () -> (Bool, DirectModeCause),
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator,
        directConnectDetector: DirectConnectDetector,
        pacRoutingEngine: PACRoutingEngine?,
        onConnectionOpened: @Sendable @escaping (ActiveConnectionInfo) -> Void,
        onConnectionClosed: @Sendable @escaping (UUID) -> Void,
        onConnectionActivity: @Sendable @escaping (ConnectionActivity) -> Void = { _ in },
        onRequestCompleted: @Sendable @escaping (Bool, String?) -> Void,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.logger = logger
        self.configProvider = configProvider
        self.directModeProvider = directModeProvider
        self.authenticatorProvider = authenticatorProvider
        self.directConnectDetector = directConnectDetector
        self.pacRoutingEngine = pacRoutingEngine
        self.onConnectionOpened = onConnectionOpened
        self.onConnectionClosed = onConnectionClosed
        self.onConnectionActivity = onConnectionActivity
        self.onRequestCompleted = onRequestCompleted
        self.eventSink = eventSink
    }

    package func start() async throws {
        if serverChannel?.isActive == true {
            return
        }

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: configProvider,
            authenticatorProvider: authenticatorProvider,
            authHandshakeLimiter: authHandshakeLimiter,
            eventSink: eventSink
        )
        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: authenticatorProvider,
            logger: logger,
            authHandshakeLimiter: authHandshakeLimiter,
            authLimitProvider: authHandshakeLimits,
            eventSink: eventSink
        )

        let config = configProvider()
        let validationErrors = config.validate()
        guard validationErrors.isEmpty else {
            throw ConfigValidationError.conflict(
                description: validationErrors.compactMap(\.errorDescription).joined(separator: "; ")
            )
        }
        let listenHost = config.effectiveListenHost

        let bound = try await bindListener(
            pool: pool,
            coordinator: coordinator,
            listenHost: listenHost,
            port: config.localPort,
            gatewayMode: config.gatewayMode
        )

        serverChannel = bound
        connectionPool = pool
        connectCoordinator = coordinator
        let actualHost = bound.localAddress?.ipAddress ?? listenHost
        let actualPort = bound.localAddress?.port ?? config.localPort
        logger.log(.notice, "Local proxy listening on \(actualHost):\(actualPort).", category: .proxy)

        if config.socksEnabled {
            do {
                let socks = SOCKS5Server(
                    group: self.group,
                    connectCoordinator: coordinator,
                    logger: self.logger,
                    directModeProvider: self.directModeProvider,
                    pacRoutingEngine: self.pacRoutingEngine,
                    configProvider: self.configProvider,
                    gatewayMode: config.gatewayMode,
                    onConnectionOpened: self.onConnectionOpened,
                    onConnectionClosed: self.onConnectionClosed,
                    onConnectionActivity: self.onConnectionActivity
                )
                try await socks.start(host: listenHost, port: config.socksPort)
                self.socksServer = socks
            } catch {
                logger.log(.warning, "SOCKS5 server failed to start on port \(config.socksPort): \(error.localizedDescription). HTTP proxy is running without SOCKS5.", category: .proxy)
            }
        }

        Task { [weak self] in
            guard let self else { return }
            // Skip prewarm when upstream health is intentionally quiet (explicit
            // direct routing or transient VPN reassertion). VPN-connected
            // upstream failures still route through PAC/upstreams, so prewarm
            // remains useful there.
            let (_, cause) = self.directModeProvider()
            guard cause.runsUpstreamHealthLoop else {
                self.logger.log(.debug,
                                   "Skipping upstream prewarm: upstream health quiet (\(cause)).",
                                   category: .proxy)
                return
            }
            await pool.prewarmConnections()
            self.logger.log(.debug, "Completed upstream connection prewarm.", category: .proxy)
        }
    }

    /// Recycle the HTTP listener accept socket while preserving the connection pool,
    /// CONNECT coordinator, SOCKS5 server, and every accepted child connection.
    ///
    /// This is the recovery surface used by `AutoRecovery` step 4 — the previous
    /// implementation called `stop() + start()` which nuked the pool (including
    /// dedicated CONNECT tunnels) every time, killing in-flight HTTPS streams on
    /// every flap-induced recovery cycle. See `docs/design-vpn-flap-resilience.md`.
    ///
    /// Existing accepted child channels are independent of the parent accept socket
    /// at the BSD-socket level — closing the listener does not propagate to them.
    /// They continue to serve their owners until each side closes its end normally.
    package func recycleListener() async throws {
        guard let pool = connectionPool, let coordinator = connectCoordinator else {
            // No prior listener state — fall through to a normal start so the
            // recovery step still has end-to-end semantics in the cold-start case.
            try await start()
            return
        }

        let config = configProvider()
        let listenHost = config.effectiveListenHost

        // Bind a fresh listener BEFORE closing the old one to minimize the
        // accept-gap window. SO_REUSEADDR makes simultaneous bind to the same
        // port valid across the close.
        let newChannel = try await bindListener(
            pool: pool,
            coordinator: coordinator,
            listenHost: listenHost,
            port: config.localPort,
            gatewayMode: config.gatewayMode
        )

        let previous = serverChannel
        serverChannel = newChannel
        if let previous {
            _ = try? await previous.close().get()
        }

        let actualHost = newChannel.localAddress?.ipAddress ?? listenHost
        let actualPort = newChannel.localAddress?.port ?? config.localPort
        logger.log(.notice, "Local proxy listener recycled on \(actualHost):\(actualPort) — pool and active connections preserved.", category: .proxy)
    }

    /// Build a fresh listener channel with the canonical handler pipeline.
    /// Shared between cold start and listener-recycle paths so the pipeline
    /// shape is defined exactly once.
    private func bindListener(
        pool: ConnectionPool,
        coordinator: CONNECTCoordinator,
        listenHost: String,
        port: Int,
        gatewayMode: Bool
    ) async throws -> Channel {
        let keepalive = TCPKeepaliveConfig.default
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .childChannelOption(ChannelOptions.tcpNoDelay, value: 1)
            .childChannelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepIdle), value: CInt(keepalive.keepIdleSeconds))
            .childChannelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepInterval), value: CInt(keepalive.keepIntervalSeconds))
            .childChannelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepCount), value: CInt(keepalive.keepCountProbes))
            .childChannelInitializer { channel in
                let count = self.inboundConnectionCountBox.withLockedValue { c in c += 1; return c }
                channel.closeFuture.whenComplete { _ in
                    self.inboundConnectionCountBox.withLockedValue { c in c -= 1 }
                }

                let maxLimit = self.configProvider().inboundConnectionMaxLimit
                if count > maxLimit {
                    self.logger.log(.error, "Inbound connection limit exceeded (\(count)/\(maxLimit)), rejecting.", category: .proxy)
                    return channel.close().flatMap { channel.eventLoop.makeFailedFuture(ChannelError.ioOnClosedChannel) }
                }

                let warnThreshold = self.configProvider().inboundConnectionWarnThreshold
                if count > warnThreshold {
                    let shouldLog = self.lastWarnLoggedAt.withLockedValue { last in
                        let now = Date()
                        if now.timeIntervalSince(last) > 10 { last = now; return true }
                        return false
                    }
                    if shouldLog {
                        self.logger.log(.warning, "High inbound connection count: \(count) (warn threshold: \(warnThreshold)).", category: .proxy)
                    }
                }

                let decoder = ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                let encoder = HTTPResponseEncoder()
                let handler = HTTPProxyHandler(
                    pool: pool,
                    connectCoordinator: coordinator,
                    logger: self.logger,
                    configProvider: self.configProvider,
                    directModeProvider: self.directModeProvider,
                    directConnectDetector: self.directConnectDetector,
                    pacRoutingEngine: self.pacRoutingEngine,
                    gatewayMode: gatewayMode,
                    authSource: channel.remoteAddress?.ipAddress,
                    eventLoopGroup: self.group,
                    onConnectionOpened: self.onConnectionOpened,
                    onConnectionClosed: self.onConnectionClosed,
                    onConnectionActivity: self.onConnectionActivity,
                    onRequestCompleted: self.onRequestCompleted
                )

                do {
                    if gatewayMode {
                        nonisolated(unsafe) let configProvider = self.configProvider
                        let filter = ClientIPFilter(
                            allowedIPsProvider: { Set(configProvider().allowedClients) },
                            logger: self.logger
                        )
                        try channel.pipeline.syncOperations.addHandler(filter)
                    }
                    try channel.pipeline.syncOperations.addHandler(decoder, name: ProxyPipelineNames.serverDecoder)
                    try channel.pipeline.syncOperations.addHandler(encoder, name: ProxyPipelineNames.serverEncoder)
                    try channel.pipeline.syncOperations.addHandler(HTTPExpectContinueHandler(), name: ProxyPipelineNames.serverExpectContinue)
                    try channel.pipeline.syncOperations.addHandler(handler, name: ProxyPipelineNames.serverHandler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }

        let maxRetries = 10
        var lastError: Error?
        for attempt in 1...maxRetries {
            do {
                return try await bootstrap.bind(host: listenHost, port: port).get()
            } catch {
                lastError = error
                if attempt < maxRetries {
                    logger.log(.warning, "Port \(port) busy, retrying in 1s (attempt \(attempt)/\(maxRetries))...", category: .proxy)
                    try await Task.sleep(for: .seconds(1))
                }
            }
        }
        throw lastError ?? ConnectionPoolError.invalidResponse
    }

    /// Stop the proxy listener and tear down pooled connections according to `scope`.
    ///
    /// In every case we drop our references to the old pool/coordinator (a subsequent
    /// `start()` will allocate fresh ones). The `scope` only governs which connections
    /// in the *outgoing* pool get explicitly closed:
    ///
    /// - `.all` (default): close every pooled connection including dedicated CONNECT
    ///   tunnels. Use for process termination, user toggle-off, and other genuinely
    ///   terminal paths.
    /// - `.allButDedicated`: close pooled connections but leave dedicated CONNECT
    ///   tunnels open. Their byte-relay handlers hold direct channel references, so
    ///   they continue serving their clients independently of the pool object's
    ///   lifetime. Use for config-driven proxy restarts where in-flight HTTPS streams
    ///   established through the old listener can outlive the listener.
    /// - `.idleOnly`: close idle pooled connections only; preserve in-use and
    ///   dedicated tunnels. Reserved for niche cases — `recycleListener()` is
    ///   normally a better fit when "preserve everything active" is the intent.
    package func stop(scope: CloseScope = .all) async {
        await socksServer?.stop()
        socksServer = nil
        connectionPool?.closeAll(scope: scope)
        connectionPool = nil
        connectCoordinator = nil

        if let serverChannel {
            _ = try? await serverChannel.close().get()
        }
        serverChannel = nil
        logger.log(.notice, "Local proxy stopped (scope: \(scope)).", category: .proxy)
    }

    package func performHealthCheck() async -> HealthCheckResult {
        guard let pool = connectionPool else {
            return HealthCheckResult(healthy: false, summary: "Proxy stopped", activeUpstream: nil, responseTimeMS: 0)
        }
        return await pool.healthCheck(urlString: configProvider().healthCheckURL)
    }

    package func activeUpstream() -> String? {
        connectionPool?.activeUpstream()
    }

    package func upstreamStatuses() -> [UpstreamRuntimeStatus] {
        connectionPool?.upstreamStatuses() ?? []
    }

    /// Reset every upstream's circuit breaker to closed without touching its
    /// EWMA latency. Called by `ProxyOrchestrator` after a VPN flap recovers
    /// (`.reasserting → .connected`) or after a hard outage ends so the next
    /// request through each upstream gets an honest first attempt instead of
    /// being rejected by an open circuit that was tripped on the now-stale
    /// flap-network path. See `docs/design-vpn-flap-resilience.md` § "Pool Hardening".
    package func resetCircuitsAfterFlap() {
        connectionPool?.resetCircuitsAfterFlap()
    }

    package func closeStalledConnections() async throws -> Int {
        connectionPool?.closeStalledConnections(olderThan: configProvider().stalledConnectionTimeoutSeconds) ?? 0
    }

    package func reauthenticate() async throws {
        connectionPool?.resetAuthentication()
    }

    package func switchToNextUpstream() async throws -> String? {
        connectionPool?.switchToNextUpstream()
    }

}

final class ClientIPFilter: ChannelInboundHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    /// Closure rather than a captured `Set` so config-reload edits to `allowedClients`
    /// take effect for new connections without restarting the listener (mirrors the
    /// `noProxyHosts` / `forceProxyHosts` hot-reload). Read once per inbound connection
    /// at `channelActive`, not per byte, so the allocation cost is negligible.
    private let allowedIPsProvider: @Sendable () -> Set<String>
    private let logger: any LogSink

    init(allowedIPsProvider: @escaping @Sendable () -> Set<String>, logger: any LogSink) {
        self.allowedIPsProvider = allowedIPsProvider
        self.logger = logger
    }

    /// Convenience initializer that snapshots `allowedIPs` once. Production paths should
    /// use the provider-based init so reloads apply to subsequent connections; this form
    /// exists for tests that only want a static allow-list.
    convenience init(allowedIPs: [String], logger: any LogSink) {
        let snapshot = Set(allowedIPs)
        self.init(allowedIPsProvider: { snapshot }, logger: logger)
    }

    func channelActive(context: ChannelHandlerContext) {
        let allowedIPs = allowedIPsProvider()
        if let remoteAddress = context.remoteAddress,
           let ip = remoteAddress.ipAddress,
           allowedIPs.contains(ip) {
            context.fireChannelActive()
        } else {
            let ip = context.remoteAddress?.ipAddress ?? "unknown"
            logger.log(.warning, "Rejected connection from \(ip) — not in allowedClients.", category: .proxy)
            context.close(promise: nil)
        }
    }
}
