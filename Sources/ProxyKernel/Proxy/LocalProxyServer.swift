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
    /// Count of accept sockets this server has successfully bound. Lets callers
    /// (and tests) distinguish "the listener was preserved" from "the listener
    /// was re-created on the same port" — the two are indistinguishable from
    /// `listeningPort` alone, and the difference is the whole point of
    /// `recycleListener`'s healthy-case no-op.
    private let listenerGenerationBox = NIOLockedValueBox(0)
    /// How many times a retriable bind failure is re-attempted, one second
    /// apart. Injectable so tests can exercise the conflict path without
    /// paying the production handoff budget.
    private let bindRetryLimit: Int
    /// Names the process holding a contended address so an `EADDRINUSE` can
    /// say *who* rather than just *that*. Optional: hosts that link a platform
    /// layer supply one, headless/portable builds leave it nil and the error
    /// falls back to naming the address.
    private let portHolderProbe: (any ListenerPortHolderProbing)?

    /// Listener/pool references are read from arbitrary threads (orchestrator
    /// tasks, the health timer, snapshot accessors on the main thread) while
    /// start/stop/recycle write them from whatever executor thread their
    /// suspension points resume on — the scheduled TSan soak flagged exactly
    /// those pairs as data races. All access goes through this box. Never
    /// hold the lock across an `await`: copy references out, then suspend.
    /// The `(host, port)` a listener was *asked* for, kept beside the channel.
    ///
    /// Recycling needs to know "is this socket still where the config wants
    /// it", and the bound address cannot answer that. `localPort = 0` means
    /// "any port", but the channel reports the concrete one it got; a host of
    /// `localhost` is accepted by config validation, but the channel reports
    /// `127.0.0.1`. Comparing the live address against raw config values makes
    /// both configurations compare unequal forever, so the healthy-listener
    /// no-op becomes unreachable and every recovery cycle drops a working
    /// socket — with port 0, onto a different port than clients were told.
    /// Comparing request against request is exact in every case.
    struct RequestedAddress: Equatable {
        var host: String
        var port: Int
    }

    private struct RuntimeRefs {
        var serverChannel: Channel? = nil
        var serverAddress: RequestedAddress? = nil
        var connectionPool: ConnectionPool? = nil
        var connectCoordinator: CONNECTCoordinator? = nil
        var socksServer: SOCKS5Server? = nil
        /// Lifecycle stamp. Every detach (`stop()`, `start()`'s stale
        /// cleanup) bumps it; `start()`/`recycleListener()` capture it before
        /// their awaits and refuse to publish results into a lifecycle that
        /// has moved on. Without it, a start() suspended in bindListener
        /// resurrects refs a concurrent stop() already detached (listener and
        /// SOCKS server left running on a "stopped" server), and a recycle
        /// racing a stop() installs a live listener over a closed pool that
        /// start() then refuses to repair (its isActive early-return).
        var epoch = 0
    }
    private let refs = NIOLockedValueBox(RuntimeRefs())

    private var pool: ConnectionPool? {
        refs.withLockedValue { $0.connectionPool }
    }

    package var listeningHost: String? {
        refs.withLockedValue { $0.serverChannel }?.localAddress?.ipAddress
    }

    package var listeningPort: Int? {
        refs.withLockedValue { $0.serverChannel }?.localAddress?.port
    }

    /// How many accept sockets this server has bound since it was created.
    /// Unchanged across a recycle that correctly left a healthy listener alone.
    package var listenerGeneration: Int {
        listenerGenerationBox.withLockedValue { $0 }
    }

    package var socksListeningHost: String? {
        refs.withLockedValue { $0.socksServer }?.listeningHost
    }

    package var socksListeningPort: Int? {
        refs.withLockedValue { $0.socksServer }?.listeningPort
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
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil,
        bindRetryLimit: Int = 10,
        portHolderProbe: (any ListenerPortHolderProbing)? = nil
    ) {
        self.bindRetryLimit = max(1, bindRetryLimit)
        self.portHolderProbe = portHolderProbe
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
        enum StartGate {
            case alreadyRunning
            case proceed(stale: RuntimeRefs, epoch: Int)
        }
        // One atomic decision: bail if a live listener exists, otherwise
        // detach whatever is there. Check and detach must share one lock
        // acquisition — split in two, a concurrent start() could publish
        // between them and have its fresh refs detached as "stale".
        let gate = refs.withLockedValue { r -> StartGate in
            if r.serverChannel?.isActive == true { return .alreadyRunning }
            let stale = r
            r = RuntimeRefs(epoch: stale.epoch + 1)
            return .proceed(stale: stale, epoch: stale.epoch + 1)
        }
        guard case .proceed(let stale, let epoch) = gate else { return }

        // The listener can die without a stop() (socket closed externally,
        // process-level hiccup). Tear stale refs down before building
        // replacements, or the old pool's upstream connections and a
        // possibly-still-bound SOCKS listener leak beside the new ones (the
        // SOCKS one would also make the new start fail with EADDRINUSE).
        // `.allButDedicated` matches config-driven restarts: in-flight
        // CONNECT tunnels are independent of the dead listener.
        if stale.serverChannel != nil || stale.connectionPool != nil || stale.socksServer != nil {
            logger.log(.warning, "Local proxy listener was gone without a stop; cleaning up stale runtime state before restart.", category: .proxy)
            await tearDown(stale, scope: .allButDedicated)
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
        // Only the errors that describe something this listener depends on.
        // The classification lives on `ConfigValidationError.blocksProxyStart`
        // rather than as a filter written out here, so the next case added to
        // the enum has to answer the question instead of inheriting "fatal".
        // The non-blocking errors are not dropped — `AppState.saveConfig`
        // banners them and the Settings row flags the field they came from.
        let blockingErrors = config.validate().filter(\.blocksProxyStart)
        guard blockingErrors.isEmpty else {
            throw ConfigValidationError.conflict(
                description: blockingErrors.compactMap(\.errorDescription).joined(separator: "; ")
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

        let published = refs.withLockedValue { r -> Bool in
            guard r.epoch == epoch else { return false }
            r.serverChannel = bound
            r.serverAddress = RequestedAddress(host: listenHost, port: config.localPort)
            r.connectionPool = pool
            r.connectCoordinator = coordinator
            return true
        }
        guard published else {
            // A concurrent stop() (or another start()'s stale cleanup) moved
            // the lifecycle on while we were suspended in bindListener.
            // Publishing now would resurrect refs that teardown already
            // detached, so fold the fresh listener back down instead.
            pool.closeAll(scope: .all)
            _ = try? await bound.close().get()
            throw CancellationError()
        }
        let actualHost = bound.localAddress?.ipAddress ?? listenHost
        let actualPort = bound.localAddress?.port ?? config.localPort
        logger.log(.notice, "Local proxy listening on \(actualHost):\(actualPort).", category: .proxy)

        try await startSOCKSIfEnabled(config: config, coordinator: coordinator, listenHost: listenHost, epoch: epoch)
        schedulePrewarm(pool: pool)
    }

    /// Start the SOCKS5 listener when enabled, publishing it under the same
    /// epoch guard as the HTTP listener. A SOCKS bind failure is non-fatal —
    /// the HTTP proxy keeps running — but a lost epoch race means stop() tore
    /// down everything this start() published, so unwind via CancellationError.
    private func startSOCKSIfEnabled(
        config: ProxyConfig,
        coordinator: CONNECTCoordinator,
        listenHost: String,
        epoch: Int
    ) async throws {
        guard config.socksEnabled else { return }
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
            let socksPublished = refs.withLockedValue { r -> Bool in
                guard r.epoch == epoch else { return false }
                r.socksServer = socks
                return true
            }
            guard socksPublished else {
                // stop() ran during socks.start(): it already tore down
                // the HTTP listener and pool we published above, so this
                // start() has effectively been stopped — unwind the SOCKS
                // listener too rather than leaving it bound.
                await socks.stop()
                throw CancellationError()
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            logger.log(.warning, "SOCKS5 server failed to start on port \(config.socksPort): \(error.localizedDescription). HTTP proxy is running without SOCKS5.", category: .proxy)
        }
    }

    /// Prewarm the upstream connection pool off the start path, unless upstream
    /// health is intentionally quiet (explicit direct routing or transient VPN
    /// reassertion). VPN-connected upstream failures still route through
    /// PAC/upstreams, so prewarm remains useful there.
    private func schedulePrewarm(pool: ConnectionPool) {
        Task { [weak self] in
            guard let self else { return }
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
        let (existingPool, existingCoordinator, existingChannel, existingAddress, epoch) = refs.withLockedValue {
            ($0.connectionPool, $0.connectCoordinator, $0.serverChannel, $0.serverAddress, $0.epoch)
        }
        guard let pool = existingPool, let coordinator = existingCoordinator else {
            // No prior listener state — fall through to a normal start so the
            // recovery step still has end-to-end semantics in the cold-start case.
            try await start()
            return
        }

        let config = configProvider()
        let listenHost = config.effectiveListenHost

        // A listener only needs replacing when it is dead, or when it was
        // asked for an address the current config no longer wants (a host/port
        // edit, or `effectiveListenHost` flipping with gateway mode).
        let wanted = RequestedAddress(host: listenHost, port: config.localPort)
        let isHealthy = existingChannel?.isActive == true
        let isCorrectlyAddressed = existingAddress == wanted

        if isHealthy && isCorrectlyAddressed {
            // Deliberate no-op. Two independent reasons:
            //
            // 1. It cannot be done. On Darwin `SO_REUSEADDR` does not permit a
            //    second bind over a socket that is already `LISTEN`ing — the
            //    bind returns `EADDRINUSE` against our *own* accept socket.
            //    Only `SO_REUSEPORT` allows it and we will not set that (see
            //    `ListenerBindError.addressInUse`). The previous
            //    bind-new-before-close-old ordering was therefore unreachable
            //    code that always burned the full retry budget and then threw.
            //
            // 2. It should not be done. Recycling is `AutoRecovery`'s last
            //    step, reached because *health checks* are failing — which is
            //    an upstream-side condition that a fresh accept socket cannot
            //    affect. Closing a working listener to re-create an identical
            //    one only opens a window for another process to take the port.
            //    That is not hypothetical: a co-resident corporate proxy agent
            //    claimed 3128 during exactly such a gap, after which no restart
            //    could ever bind again.
            // Events are the contract with the UI, pmctl and pm-sim, and a
            // recovery step that decides to do nothing still owes them the
            // reason — otherwise the step is indistinguishable from one that
            // ran and silently failed. See AGENTS.md "Always emit a
            // RuntimeEvent first".
            eventSink?(RuntimeEvent(
                kind: .health,
                event: "proxy.listener_recycle_skipped",
                detail: "listener=\(wanted.host):\(wanted.port) healthy"
            ))
            logger.log(
                .debug,
                "Listener recycle skipped: accept socket on \(wanted.host):\(wanted.port) is healthy.",
                category: .proxy
            )
            return
        }

        // The accept socket must be released before its replacement can take
        // the address. Detach it first so a failed rebind cannot leave a closed
        // channel installed — `start()` gates on `serverChannel?.isActive`, and
        // a stale reference there turns a repairable state into a confusing one.
        let detached = refs.withLockedValue { r -> Channel? in
            guard r.epoch == epoch else { return nil }
            let old = r.serverChannel
            r.serverChannel = nil
            r.serverAddress = nil
            return old
        }
        if let detached {
            _ = try? await detached.close().get()
        }

        let newChannel: Channel
        do {
            newChannel = try await bindListener(
                pool: pool,
                coordinator: coordinator,
                listenHost: listenHost,
                port: config.localPort,
                gatewayMode: config.gatewayMode
            )
        } catch {
            // Refs already show "no listener", which is the truth. The pool and
            // its in-flight tunnels stay up: they are independent of the accept
            // socket, and dropping them would turn a listener outage into a
            // stream outage. `start()` repairs from here.
            logger.log(
                .error,
                "Local proxy listener could not be rebound: \(error.displayDescription)",
                category: .proxy
            )
            throw error
        }

        let published = refs.withLockedValue { r -> Bool in
            guard r.epoch == epoch else { return false }
            r.serverChannel = newChannel
            r.serverAddress = wanted
            return true
        }
        guard published else {
            // stop()/start() moved the lifecycle on while we were binding —
            // the pool this listener would serve is already torn down.
            // Installing it would leave a live listener over a dead pool that
            // start() then refuses to repair (isActive early-return). Close
            // the orphan instead.
            _ = try? await newChannel.close().get()
            throw CancellationError()
        }

        let actualHost = newChannel.localAddress?.ipAddress ?? listenHost
        let actualPort = newChannel.localAddress?.port ?? config.localPort
        logger.log(.notice, "Local proxy listener recycled on \(actualHost):\(actualPort) — pool and active connections preserved.", category: .proxy)
    }

    /// Closes the accept socket without touching the pool, coordinator or
    /// SOCKS listener — reproducing "the listener died without a `stop()`",
    /// the state `recycleListener` exists to repair. Test-only seam: nothing
    /// in production drops the accept socket on its own.
    package func simulateListenerLossForTesting() async {
        let detached = refs.withLockedValue { r -> Channel? in
            let old = r.serverChannel
            r.serverChannel = nil
            r.serverAddress = nil
            return old
        }
        if let detached {
            _ = try? await detached.close().get()
        }
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

        // The retry budget exists for one benign case: a handoff, where an
        // outgoing instance (an upgrade replacing a running copy) still holds
        // the port for the moment it takes to exit. Only failures a wait can
        // plausibly resolve are retried — retrying `EACCES` on a privileged
        // port ten times just stalls the start for ten seconds before
        // reporting the same thing.
        let maxRetries = bindRetryLimit
        var lastError: ListenerBindError?
        for attempt in 1...maxRetries {
            do {
                let channel = try await bootstrap.bind(host: listenHost, port: port).get()
                listenerGenerationBox.withLockedValue { $0 += 1 }
                return channel
            } catch {
                let classified = ListenerBindError.classify(
                    error,
                    listener: Self.listenerName,
                    host: listenHost,
                    port: port,
                    holderProbe: portHolderProbe
                )
                lastError = classified
                guard classified.isRetriable, attempt < maxRetries else { break }
                logger.log(
                    .warning,
                    "\(Self.listenerName) bind on \(listenHost):\(port) failed (attempt \(attempt)/\(maxRetries)), retrying in 1s: \(classified.localizedDescription)",
                    category: .proxy
                )
                try await Task.sleep(for: .seconds(1))
            }
        }
        throw lastError ?? .bindFailed(
            listener: Self.listenerName,
            host: listenHost,
            port: port,
            reason: "bind returned no channel and no error"
        )
    }

    /// Name used in bind diagnostics. Matches the label users see for this
    /// listener in the UI, so an error message and the settings field agree.
    private static let listenerName = "Local proxy"

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
        // Detach everything under the lock first, then run the async
        // teardown on the local copies — holding the lock across an await
        // is not allowed, and clearing eagerly means concurrent readers see
        // "stopped" for the whole teardown rather than half-closed refs.
        // Bumping the epoch also preempts any in-flight start()/
        // recycleListener(): their publish step notices and unwinds instead
        // of resurrecting refs into a stopped server.
        let detached = refs.withLockedValue { r -> RuntimeRefs in
            let copy = r
            r = RuntimeRefs(epoch: copy.epoch + 1)
            return copy
        }
        await tearDown(detached, scope: scope)
        logger.log(.notice, "Local proxy stopped (scope: \(scope)).", category: .proxy)
    }

    /// Order matters: SOCKS listener first (stops intake), then pooled
    /// upstream connections, then the HTTP accept socket. Shared by `stop()`
    /// and `start()`'s stale cleanup so the ordering lives in one place.
    private func tearDown(_ detached: RuntimeRefs, scope: CloseScope) async {
        await detached.socksServer?.stop()
        detached.connectionPool?.closeAll(scope: scope)

        if let serverChannel = detached.serverChannel {
            _ = try? await serverChannel.close().get()
        }
    }

    package func performHealthCheck() async -> HealthCheckResult {
        guard let pool = self.pool else {
            return HealthCheckResult(healthy: false, summary: "Proxy stopped", activeUpstream: nil, responseTimeMS: 0)
        }
        return await pool.healthCheck(urlString: configProvider().healthCheckURL)
    }

    package func activeUpstream() -> String? {
        pool?.activeUpstream()
    }

    package func upstreamStatuses() -> [UpstreamRuntimeStatus] {
        pool?.upstreamStatuses() ?? []
    }

    /// Reset every upstream's circuit breaker to closed without touching its
    /// EWMA latency. Called by `ProxyOrchestrator` after a VPN flap recovers
    /// (`.reasserting → .connected`) or after a hard outage ends so the next
    /// request through each upstream gets an honest first attempt instead of
    /// being rejected by an open circuit that was tripped on the now-stale
    /// flap-network path. See `docs/design-vpn-flap-resilience.md` § "Pool Hardening".
    package func resetCircuitsAfterFlap() {
        pool?.resetCircuitsAfterFlap()
    }

    package func closeStalledConnections() async throws -> Int {
        pool?.closeStalledConnections(olderThan: configProvider().stalledConnectionTimeoutSeconds) ?? 0
    }

    package func reauthenticate() async throws {
        pool?.resetAuthentication()
    }

    package func switchToNextUpstream() async throws -> String? {
        pool?.switchToNextUpstream()
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
