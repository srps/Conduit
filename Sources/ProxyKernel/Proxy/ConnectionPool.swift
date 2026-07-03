// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix

/// Scope of a `ConnectionPool.closeAll` operation.
///
/// Designed to support the VPN-flap-resilience design (`docs/design-vpn-flap-resilience.md`):
/// control-plane transitions (direct-mode flips, listener recycling) must NOT close active
/// upstream channels, because macOS preserves their TCP state across VPN flaps and the kernel
/// will resume delivery once the path returns. Only explicit shutdown should call `.all`.
package enum CloseScope: Sendable, Equatable {
    /// Close only idle pooled connections (those not currently in use). Preserves
    /// every connection that is mid-exchange or marked as a dedicated CONNECT tunnel.
    /// Use when recycling control-plane state without disturbing active streams.
    case idleOnly

    /// Close all pooled connections except dedicated CONNECT tunnels. Use for
    /// proxy-config restart paths where the listener identity changes but in-flight
    /// tunnels (HTTPS streams owned by the client side) should ride out the change.
    case allButDedicated

    /// Close every connection in the pool, including dedicated CONNECT tunnels.
    /// Use only for final shutdown / process termination paths.
    case all
}

package enum ConnectionPoolError: Error, LocalizedError, Equatable {
    case noUpstreamsConfigured
    case authenticationUnavailable
    case authenticationRejected
    case invalidResponse
    case poolExhausted
    case bodyTooLargeForReplay
    case authHandshakeLimitExceeded
    case streamingResponseInterrupted
    case upstreamResponseTimedOut
    case upstreamReturnedStatus(Int, target: String)

    package var errorDescription: String? {
        switch self {
        case .noUpstreamsConfigured:
            return "No upstream proxy servers are enabled."
        case .authenticationUnavailable:
            return "Proxy credentials are unavailable."
        case .authenticationRejected:
            return "The upstream proxy rejected authentication."
        case .invalidResponse:
            return "The upstream proxy returned an invalid response."
        case .poolExhausted:
            return "Maximum upstream connections reached."
        case .bodyTooLargeForReplay:
            return "Request body too large to replay for proxy authentication."
        case .authHandshakeLimitExceeded:
            return "Too many proxy authentication handshakes are already pending."
        case .streamingResponseInterrupted:
            return "The upstream response stream ended after client response forwarding began."
        case .upstreamResponseTimedOut:
            return "Timed out waiting for the upstream proxy to respond."
        case .upstreamReturnedStatus(let statusCode, let target):
            return "The upstream proxy returned HTTP \(statusCode) for \(target)."
        }
    }

    package static func isAuthHandshakeLimitExceeded(_ error: Error) -> Bool {
        if case ConnectionPoolError.authHandshakeLimitExceeded = error {
            return true
        }
        return false
    }

    package static func isPoolExhausted(_ error: Error) -> Bool {
        if case ConnectionPoolError.poolExhausted = error {
            return true
        }
        return false
    }

    package static func isLocalNonUpstreamFailure(_ error: Error) -> Bool {
        isAuthHandshakeLimitExceeded(error) || isPoolExhausted(error)
    }

    package static func isStreamingResponseInterrupted(_ error: Error) -> Bool {
        if case ConnectionPoolError.streamingResponseInterrupted = error {
            return true
        }
        return false
    }
}

package struct UpstreamExchangeResponse {
    package var head: HTTPResponseHead
    package var body: ByteBuffer
    package var upstream: UpstreamProxy
    package var authMethod: String?

    package init(
        head: HTTPResponseHead,
        body: ByteBuffer,
        upstream: UpstreamProxy,
        authMethod: String? = nil
    ) {
        self.head = head
        self.body = body
        self.upstream = upstream
        self.authMethod = authMethod
    }
}

package struct StreamingExchangeResult {
    package var upstream: UpstreamProxy
    package var keepAlive: Bool
    package var authMethod: String?

    package init(upstream: UpstreamProxy, keepAlive: Bool, authMethod: String? = nil) {
        self.upstream = upstream
        self.keepAlive = keepAlive
        self.authMethod = authMethod
    }
}

package final class PooledUpstreamConnection: @unchecked Sendable {
    package let id = UUID()
    package let proxy: UpstreamProxy
    package let channel: Channel
    package let createdAt = Date()
    package fileprivate(set) var authenticated = false
    package fileprivate(set) var authMethod: String?
    package fileprivate(set) var inUse = false
    package var lastUsedAt = Date()
    package var isDedicatedTunnel = false

    package init(proxy: UpstreamProxy, channel: Channel) {
        self.proxy = proxy
        self.channel = channel
    }

    package func markAuthenticated(authMethod: String?) {
        authenticated = true
        if let authMethod {
            self.authMethod = authMethod
        }
    }

    /// Test-only factory that constructs a connection in an arbitrary state.
    ///
    /// Production code MUST NOT use this — `inUse` and `authenticated` are
    /// `fileprivate(set)` because they're invariants of the pool's
    /// acquire/release/auth lifecycle. This factory exists so unit tests can
    /// exercise filter/policy code (e.g. `connectionIDsToClose(from:scope:)`)
    /// against synthetic states without standing up a live pool.
    package static func makeForTesting(
        proxy: UpstreamProxy,
        channel: Channel,
        inUse: Bool = false,
        isDedicatedTunnel: Bool = false,
        authenticated: Bool = false
    ) -> PooledUpstreamConnection {
        let conn = PooledUpstreamConnection(proxy: proxy, channel: channel)
        conn.inUse = inUse
        conn.isDedicatedTunnel = isDedicatedTunnel
        conn.authenticated = authenticated
        return conn
    }
}

package final class ConnectionPool: @unchecked Sendable {
    /// Default circuit-breaker thresholds. Used when `HealthSection` doesn't
    /// override them. The names mirror `UpstreamCircuitBreaker` for grep-ability;
    /// the breaker itself is configuration-free and takes these as arguments.
    fileprivate static let defaultCircuitFailureThreshold = 5
    fileprivate static let defaultCircuitBaseOpenInterval: TimeInterval = 30
    fileprivate static let defaultCircuitMaxOpenInterval: TimeInterval = 300
    private static let maxConnectionAgeSeconds: TimeInterval = 300

    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let authenticatorProvider: (String) throws -> ProxyAuthenticator
    private let authHandshakeLimiter: AuthHandshakeLimiter
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let lock = NIOLock()
    private var idleConnections: [UUID: [PooledUpstreamConnection]] = [:]
    private var allConnections: [UUID: PooledUpstreamConnection] = [:]
    private var connectionIDsByChannel: [ObjectIdentifier: UUID] = [:]
    private var breakers: [UUID: UpstreamCircuitBreaker] = [:]
    /// Cached `(name, endpoint)` for each upstream we've seen, used so the
    /// transition-event emission can carry human-readable upstream identity
    /// without re-querying `configProvider().enabledUpstreams` on every fire
    /// (the config could have changed by the time we emit, and we want the
    /// event tagged with the upstream that actually transitioned).
    private var upstreamIdentities: [UUID: (name: String, endpoint: String)] = [:]
    private var pendingConnectionCount = 0
    private var preferredProxyIndex = 0
    private var selectionCounter = 0
    private var lastSelectedUpstreamID: UUID?

    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator,
        authHandshakeLimiter: AuthHandshakeLimiter = AuthHandshakeLimiter(),
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.authenticatorProvider = authenticatorProvider
        self.authHandshakeLimiter = authHandshakeLimiter
        self.eventSink = eventSink
    }

    package func exchange(head: HTTPRequestHead, body: ByteBuffer?) -> EventLoopFuture<UpstreamExchangeResponse> {
        bufferedExchange(head: head, requestBody: body.map(HTTPRequestBody.memory), forcedProxy: nil, allowRetry: true, preferFreshConnection: false, authSource: nil)
    }

    package func exchange(head: HTTPRequestHead, requestBody: HTTPRequestBody?) -> EventLoopFuture<UpstreamExchangeResponse> {
        bufferedExchange(head: head, requestBody: requestBody, forcedProxy: nil, allowRetry: true, preferFreshConnection: false, authSource: nil)
    }

    package func streamingExchange(
        head: HTTPRequestHead,
        body: ByteBuffer?,
        clientChannel: Channel,
        authSource: String? = nil,
        forcedProxy: UpstreamProxy? = nil
    ) -> EventLoopFuture<StreamingExchangeResult> {
        streamingExchange(
            head: head,
            requestBody: body.map(HTTPRequestBody.memory),
            clientChannel: clientChannel,
            authSource: authSource,
            forcedProxy: forcedProxy
        )
    }

    package func streamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        authSource: String? = nil,
        forcedProxy: UpstreamProxy? = nil
    ) -> EventLoopFuture<StreamingExchangeResult> {
        let config = configProvider()
        guard let proxy = forcedProxy ?? selectProxy(from: config) else {
            return group.next().makeFailedFuture(ConnectionPoolError.noUpstreamsConfigured)
        }

        return streamingExchange(
            head: head,
            requestBody: requestBody,
            clientChannel: clientChannel,
            authSource: authSource,
            proxy: proxy
        )
    }

    private func streamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        authSource: String?,
        proxy: UpstreamProxy
    ) -> EventLoopFuture<StreamingExchangeResult> {
        let start = Date()
        let attempt: EventLoopFuture<StreamingExchangeResult> = acquireConnection(
            for: proxy,
            preferFreshConnection: false
        ).flatMap { [weak self] connection in
            guard let self else {
                return connection.channel.eventLoop.makeFailedFuture(ConnectionPoolError.invalidResponse)
            }
            return self.performStreamingExchange(
                head: head,
                requestBody: requestBody,
                clientChannel: clientChannel,
                connection: connection,
                proxy: proxy,
                authSource: authSource
            ).flatMap { result in
                self.recordSuccess(for: result.upstream, latencyMS: Int(Date().timeIntervalSince(start) * 1_000))
                return connection.channel.eventLoop.makeSucceededFuture(result)
            }
        }
        // Mirror the buffered path: acquire-time failures (e.g. immediate
        // connect-refused on a dead upstream) are upstream health signals and
        // must feed the breaker. Local capacity signals are not upstream
        // failures and are excluded below.
        return attempt.flatMapError { [weak self] (error: Error) -> EventLoopFuture<StreamingExchangeResult> in
            guard let self else { return attempt }
            if !ConnectionPoolError.isLocalNonUpstreamFailure(error) {
                self.recordFailure(for: proxy)
            }
            return self.group.next().makeFailedFuture(error)
        }
    }

    package func makeDedicatedTunnelConnection(forcedProxy: UpstreamProxy? = nil) -> EventLoopFuture<(PooledUpstreamConnection, ProxyConfig)> {
        let config = configProvider()
        guard let proxy = forcedProxy ?? selectProxy(from: config) else {
            return group.next().makeFailedFuture(ConnectionPoolError.noUpstreamsConfigured)
        }
        return acquireDedicatedTunnelConnection(for: proxy, config: config)
    }

    private func authHandshakeLimits() -> AuthHandshakeLimiter.Limits {
        let config = configProvider()
        return AuthHandshakeLimiter.Limits(
            total: config.pendingAuthHandshakeGlobalLimit,
            perSource: config.pendingAuthHandshakesPerSource
        )
    }

    package func recordDedicatedTunnelSuccess(for proxy: UpstreamProxy, latencyMS: Int) {
        recordSuccess(for: proxy, latencyMS: latencyMS)
    }

    package func recordDedicatedTunnelFailure(for proxy: UpstreamProxy) {
        recordFailure(for: proxy)
    }

    package func removeDedicatedTunnel(_ connection: PooledUpstreamConnection) {
        lock.withLockVoid {
            removeConnectionLocked(id: connection.id)
        }
    }

    package func removeDedicatedTunnelByChannel(_ channel: Channel) {
        lock.withLockVoid {
            let channelID = ObjectIdentifier(channel)
            if let key = connectionIDsByChannel[channelID],
               allConnections[key]?.isDedicatedTunnel == true {
                removeConnectionLocked(id: key)
            }
        }
    }

    package func healthCheck(urlString: String) async -> HealthCheckResult {
        let start = Date()
        var head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: urlString)
        head.headers.add(name: "Host", value: URL(string: urlString)?.host ?? "example.com")
        do {
            let response = try await exchange(head: head, body: nil).get()
            let elapsed = Int(Date().timeIntervalSince(start) * 1_000)
            let healthy = (200..<500).contains(Int(response.head.status.code))
            return HealthCheckResult(
                healthy: healthy,
                summary: healthy ? "Healthy via \(response.upstream.endpoint)" : "HTTP \(response.head.status.code) via \(response.upstream.endpoint)",
                activeUpstream: response.upstream.endpoint,
                responseTimeMS: elapsed
            )
        } catch {
            return HealthCheckResult(
                healthy: false,
                summary: error.localizedDescription,
                activeUpstream: nil,
                responseTimeMS: Int(Date().timeIntervalSince(start) * 1_000)
            )
        }
    }

    package func upstreamStatuses() -> [UpstreamRuntimeStatus] {
        let proxies = configProvider().enabledUpstreams
        return lock.withLock {
            syncUpstreamStatesLocked(with: proxies)
            return proxies.map { proxy in
                let breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
                return UpstreamRuntimeStatus(
                    id: proxy.id,
                    name: proxy.name,
                    endpoint: proxy.endpoint,
                    circuitState: breaker.state,
                    ewmaLatencyMS: breaker.ewmaLatencyMS,
                    consecutiveFailures: breaker.consecutiveFailures,
                    openUntil: breaker.state == .open ? breaker.openUntil : nil
                )
            }
        }
    }

    package func prewarmConnections(perUpstream: Int = 1) async {
        let proxies = lock.withLock {
            let current = configProvider().enabledUpstreams
            syncUpstreamStatesLocked(with: current)
            return current
        }
        guard !proxies.isEmpty, perUpstream > 0 else { return }

        await withTaskGroup(of: Void.self) { group in
            for proxy in proxies {
                for _ in 0..<perUpstream {
                    group.addTask { [weak self] in
                        guard let self else { return }
                        do {
                            let connection = try await self.makeConnection(to: proxy).get()
                            self.release(connection, keepAlive: true)
                            self.logger.log(.debug, "Prewarmed upstream connection for \(proxy.endpoint).", category: .proxy)
                        } catch {
                            self.recordFailure(for: proxy)
                            self.logger.log(.debug, "Prewarm failed for \(proxy.endpoint): \(error.localizedDescription)", category: .proxy)
                        }
                    }
                }
            }
        }
    }

    /// Pure filter: returns the IDs of connections that should be reaped as stalled.
    /// Dedicated tunnel connections are always exempt.
    package static func stalledConnectionIDs(
        from connections: some Collection<PooledUpstreamConnection>,
        olderThan timeout: TimeInterval
    ) -> Set<UUID> {
        let cutoff = Date().addingTimeInterval(-timeout)
        return Set(connections.filter { !$0.inUse && !$0.isDedicatedTunnel && $0.lastUsedAt < cutoff }.map(\.id))
    }

    @discardableResult
    package func closeStalledConnections(olderThan timeout: TimeInterval) -> Int {
        let snapshot = lock.withLock { Array(allConnections.values) }
        let staleIDs = Self.stalledConnectionIDs(from: snapshot, olderThan: timeout)
        guard !staleIDs.isEmpty else { return 0 }

        for connection in snapshot where staleIDs.contains(connection.id) {
            connection.channel.close(mode: .all, promise: nil)
            logger.log(.warning, "Closed stalled upstream connection to \(connection.proxy.endpoint).", category: .proxy)
        }
        lock.withLockVoid {
            removeConnectionsLocked(ids: staleIDs)
        }
        return staleIDs.count
    }

    // MARK: - Pool management

    package func resetAuthentication() {
        lock.withLockVoid {
            for connection in allConnections.values {
                connection.authenticated = false
            }
        }
    }

    package func switchToNextUpstream() -> String? {
        let proxies = configProvider().enabledUpstreams
        guard !proxies.isEmpty else { return nil }
        let nextIndex = lock.withLock { () -> Int in
            syncUpstreamStatesLocked(with: proxies)
            preferredProxyIndex = (preferredProxyIndex + 1) % proxies.count
            lastSelectedUpstreamID = proxies[preferredProxyIndex].id
            return preferredProxyIndex
        }
        return proxies[nextIndex].endpoint
    }

    package func activeUpstream() -> String? {
        let proxies = configProvider().enabledUpstreams
        guard !proxies.isEmpty else { return nil }
        return lock.withLock {
            syncUpstreamStatesLocked(with: proxies)
            if let lastSelectedUpstreamID,
               let proxy = proxies.first(where: { $0.id == lastSelectedUpstreamID }) {
                return proxy.endpoint
            }
            let index = min(preferredProxyIndex, max(0, proxies.count - 1))
            return proxies[index].endpoint
        }
    }

    package var enabledUpstreamCount: Int {
        configProvider().enabledUpstreams.count
    }

    package var eventLoop: EventLoop {
        group.next()
    }

    package var upstreamResponseTimeout: TimeAmount {
        let seconds = max(configProvider().upstreamResponseTimeoutSeconds, 0.1)
        return .nanoseconds(Int64(seconds * 1_000_000_000))
    }

    package var allConnectionSnapshot: [PooledUpstreamConnection] {
        lock.withLock { Array(allConnections.values) }
    }

    /// Close pooled upstream connections according to `scope`.
    ///
    /// Default `scope: .all` preserves the historical behavior so existing call sites
    /// that genuinely want a full nuke (process shutdown, CLI cleanup) compile unchanged.
    ///
    /// New control-plane callers (listener recycle, proxy-config restart) should pass
    /// `.allButDedicated` or `.idleOnly` to avoid tearing down active client-owned tunnels.
    /// See `docs/design-vpn-flap-resilience.md` for the policy.
    package func closeAll(scope: CloseScope = .all) {
        let snapshot = lock.withLock { Array(allConnections.values) }
        let closeIDs = Self.connectionIDsToClose(from: snapshot, scope: scope)
        guard !closeIDs.isEmpty else { return }

        for connection in snapshot where closeIDs.contains(connection.id) {
            connection.channel.close(mode: .all, promise: nil)
        }

        lock.withLockVoid {
            removeConnectionsLocked(ids: closeIDs)
        }
    }

    /// Pure filter exposed for unit testing: returns the IDs of connections that
    /// should be closed for a given `scope`. Mirrors the `stalledConnectionIDs`
    /// pattern so the policy can be tested without standing up a live pool.
    package static func connectionIDsToClose(
        from connections: some Collection<PooledUpstreamConnection>,
        scope: CloseScope
    ) -> Set<UUID> {
        switch scope {
        case .all:
            return Set(connections.map(\.id))
        case .allButDedicated:
            return Set(connections.lazy.filter { !$0.isDedicatedTunnel }.map(\.id))
        case .idleOnly:
            return Set(connections.lazy.filter { !$0.inUse && !$0.isDedicatedTunnel }.map(\.id))
        }
    }

    private enum AcquireResult {
        case idle(PooledUpstreamConnection)
        case needsNew
        case exhausted
    }

    private func acquireConnection(for proxy: UpstreamProxy, preferFreshConnection: Bool) -> EventLoopFuture<PooledUpstreamConnection> {
        let config = configProvider()
        let maxConns = config.maxConnections
        let result: AcquireResult = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            pruneExpiredIdleConnectionsLocked(now: .now)
            if !preferFreshConnection {
                while let existing = idleConnections[proxy.id]?.popLast() {
                    guard allConnections[existing.id] != nil else { continue }
                    if isConnectionExpired(existing, now: .now) {
                        existing.channel.close(mode: .all, promise: nil)
                        removeConnectionLocked(id: existing.id)
                        continue
                    }
                    existing.inUse = true
                    existing.lastUsedAt = .now
                    lastSelectedUpstreamID = proxy.id
                    return .idle(existing)
                }
            }
            if allConnections.count + pendingConnectionCount >= maxConns {
                return .exhausted
            }
            pendingConnectionCount += 1
            lastSelectedUpstreamID = proxy.id
            preconditionCapacityLocked(maxConnections: maxConns)
            return .needsNew
        }

        switch result {
        case .idle(let conn):
            return conn.channel.eventLoop.makeSucceededFuture(conn)
        case .exhausted:
            return group.next().makeFailedFuture(ConnectionPoolError.poolExhausted)
        case .needsNew:
            return makeConnection(to: proxy).always { [weak self] _ in
                self?.lock.withLockVoid {
                    self?.pendingConnectionCount -= 1
                    self?.preconditionCapacityLocked(maxConnections: maxConns)
                }
            }
        }
    }

    private func acquireDedicatedTunnelConnection(
        for proxy: UpstreamProxy,
        config: ProxyConfig
    ) -> EventLoopFuture<(PooledUpstreamConnection, ProxyConfig)> {
        let maxConns = config.maxConnections
        let result: AcquireResult = lock.withLock {
            syncUpstreamStatesLocked(with: config.enabledUpstreams)
            pruneExpiredIdleConnectionsLocked(now: .now)
            guard allConnections.count + pendingConnectionCount < maxConns else {
                return .exhausted
            }
            pendingConnectionCount += 1
            lastSelectedUpstreamID = proxy.id
            preconditionCapacityLocked(maxConnections: maxConns)
            return .needsNew
        }

        switch result {
        case .idle:
            preconditionFailure("Dedicated tunnels never reuse pooled idle connections")
        case .exhausted:
            return group.next().makeFailedFuture(ConnectionPoolError.poolExhausted)
        case .needsNew:
            return makeRawConnection(to: proxy).map { conn in
                conn.isDedicatedTunnel = true
                return (conn, config)
            }.always { [weak self] _ in
                self?.lock.withLockVoid {
                    self?.pendingConnectionCount -= 1
                    self?.preconditionCapacityLocked(maxConnections: maxConns)
                }
            }
        }
    }

    private func release(_ connection: PooledUpstreamConnection, keepAlive: Bool) {
        guard keepAlive, connection.channel.isActive, !isConnectionExpired(connection, now: .now) else {
            connection.channel.close(mode: .all, promise: nil)
            lock.withLockVoid {
                connection.lastUsedAt = .now
                connection.inUse = false
                self.removeConnectionLocked(id: connection.id)
            }
            return
        }

        lock.withLockVoid {
            connection.lastUsedAt = .now
            connection.inUse = false
            self.idleConnections[connection.proxy.id, default: []].append(connection)
        }
    }

    private func makeRawConnection(to proxy: UpstreamProxy) -> EventLoopFuture<PooledUpstreamConnection> {
        return connectToUpstreamProxy(proxy)
            .map { [weak self] channel in
                let connection = PooledUpstreamConnection(proxy: proxy, channel: channel)
                self?.lock.withLockVoid {
                    connection.inUse = true
                    self?.insertConnectionLocked(connection)
                    self?.lastSelectedUpstreamID = proxy.id
                }
                self?.logger.log(.info, "Connected to upstream proxy \(proxy.endpoint) (raw).", category: .proxy)
                return connection
            }
    }

    private func makeConnection(to proxy: UpstreamProxy) -> EventLoopFuture<PooledUpstreamConnection> {
        return connectToUpstreamProxy(proxy) { channel in
            do {
                try channel.pipeline.syncOperations.addHandler(HTTPRequestEncoder(), name: ProxyPipelineNames.upstreamEncoder)
                try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)), name: ProxyPipelineNames.upstreamDecoder)
                return channel.eventLoop.makeSucceededVoidFuture()
            } catch {
                return channel.eventLoop.makeFailedFuture(error)
            }
        }
            .map { [weak self] channel in
                let connection = PooledUpstreamConnection(proxy: proxy, channel: channel)
                self?.lock.withLockVoid {
                    connection.inUse = true
                    self?.insertConnectionLocked(connection)
                    self?.lastSelectedUpstreamID = proxy.id
                }
                self?.logger.log(.info, "Connected to upstream proxy \(proxy.endpoint).", category: .proxy)
                return connection
            }
    }

    private func upstreamProxyBootstrap(
        channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil
    ) -> ClientBootstrap {
        let timeoutMS = Int64(max(configProvider().connectionCheckTimeoutMS, 500))
        let keepalive = TCPKeepaliveConfig.default
        let bootstrap = ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(timeoutMS))
            .channelOption(ChannelOptions.socketOption(.so_keepalive), value: 1)
            .channelOption(ChannelOptions.tcpNoDelay, value: 1)
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepIdle), value: CInt(keepalive.keepIdleSeconds))
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepInterval), value: CInt(keepalive.keepIntervalSeconds))
            .channelOption(ChannelOptions.tcpOption(TCPKeepaliveOption.keepCount), value: CInt(keepalive.keepCountProbes))

        if let channelInitializer {
            return bootstrap.channelInitializer(channelInitializer)
        }
        return bootstrap
    }

    private func connectToUpstreamProxy(
        _ proxy: UpstreamProxy,
        channelInitializer: (@Sendable (Channel) -> EventLoopFuture<Void>)? = nil
    ) -> EventLoopFuture<Channel> {
        let makeBootstrap: @Sendable () -> ClientBootstrap = { [weak self] in
            guard let self else {
                return ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            }
            return self.upstreamProxyBootstrap(channelInitializer: channelInitializer)
        }

        return makeBootstrap()
            .connect(host: proxy.host, port: proxy.port)
            .flatMap { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeSucceededFuture(channel)
                }
                if channel.remoteAddress == nil {
                    self.logger.log(.warning, "Half-open upstream proxy channel detected for \(proxy.endpoint) (remoteAddress nil, localAddress \(String(describing: channel.localAddress))); falling back to explicit IPv4 connect", category: .proxy)
                }
                return Self.applyHalfOpenUpstreamFallback(
                    upstreamChannel: channel,
                    proxy: proxy,
                    on: channel.eventLoop,
                    ipv4Reconnect: { address in
                        self.logger.log(.info, "Half-open upstream fallback: reconnecting to \(proxy.endpoint) via IPv4 \(address)", category: .proxy)
                        return makeBootstrap()
                            .connect(to: address)
                            .hop(to: channel.eventLoop)
                    }
                )
            }
    }

    package static func applyHalfOpenUpstreamFallback(
        upstreamChannel: Channel,
        proxy: UpstreamProxy,
        on eventLoop: EventLoop,
        ipv4Reconnect: @escaping @Sendable (SocketAddress) -> EventLoopFuture<Channel>
    ) -> EventLoopFuture<Channel> {
        HalfOpenChannelFallback.apply(
            upstreamChannel: upstreamChannel,
            host: proxy.host,
            port: proxy.port,
            on: eventLoop,
            ipv4Reconnect: ipv4Reconnect
        )
    }

    private func selectProxy(from config: ProxyConfig) -> UpstreamProxy? {
        let proxies = config.enabledUpstreams
        guard !proxies.isEmpty else { return nil }
        let result: (proxy: UpstreamProxy?, pending: [PendingTransitionEmission]) = lock.withLock {
            syncUpstreamStatesLocked(with: proxies)
            let outcome = selectableProxiesLocked(from: proxies, now: .now)
            guard !outcome.candidates.isEmpty else {
                let index = min(preferredProxyIndex, max(0, proxies.count - 1))
                return (proxies[index], outcome.pendingEmissions)
            }
            let selected = chooseProxyLocked(from: outcome.candidates)
            lastSelectedUpstreamID = selected.id
            if let selectedIndex = proxies.firstIndex(where: { $0.id == selected.id }) {
                preferredProxyIndex = selectedIndex
            }
            return (selected, outcome.pendingEmissions)
        }
        // Emit transitions OUTSIDE the lock. selectableProxiesLocked may
        // promote a breaker to half-open via tryHalfOpen / forceHalfOpen,
        // but the resulting `RuntimeEvent` + `logger.log(.notice, ...)` calls
        // must NOT re-acquire the pool lock — emitTransition's identity-
        // lookup variant takes the lock, which would deadlock under NIOLock
        // (non-recursive). Pre-lock-release emit was the source of the
        // pthread_mutex EAGAIN crash observed in `pm-sim upstream-flap`.
        for emission in result.pending {
            publishEmission(emission)
        }
        return result.proxy
    }

    private func bufferedExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        forcedProxy: UpstreamProxy?,
        allowRetry: Bool,
        preferFreshConnection: Bool,
        authSource: String?
    ) -> EventLoopFuture<UpstreamExchangeResponse> {
        let config = configProvider()
        guard let proxy = forcedProxy ?? selectProxy(from: config) else {
            return group.next().makeFailedFuture(ConnectionPoolError.noUpstreamsConfigured)
        }

        let start = Date()
        let attempt: EventLoopFuture<UpstreamExchangeResponse> = acquireConnection(
            for: proxy,
            preferFreshConnection: preferFreshConnection
        ).flatMap { [weak self] connection in
            guard let self else {
                return connection.channel.eventLoop.makeFailedFuture(ConnectionPoolError.invalidResponse)
            }
            return self.performBufferedExchange(head: head, requestBody: requestBody, connection: connection, proxy: proxy, authSource: authSource)
                .flatMap { response in
                    self.recordSuccess(for: response.upstream, latencyMS: Int(Date().timeIntervalSince(start) * 1_000))
                    return connection.channel.eventLoop.makeSucceededFuture(response)
                }
        }
        // Note: this `.flatMapError` is on the outer chain (`acquireConnection +
        // performBufferedExchange`), not just on `performBufferedExchange`'s
        // result. That's deliberate: connect-refused failures from
        // `acquireConnection` (e.g. upstream-down case in `pm-sim
        // upstream-flap`) must also feed `recordFailure` so the breaker can
        // trip. Pre-extraction the chain was nested and connect failures
        // bypassed the breaker entirely — a real-world bug, not just a
        // scenario quirk.
        return attempt.flatMapError { [weak self] (error: Error) -> EventLoopFuture<UpstreamExchangeResponse> in
            // `self?.group...makeFailedFuture(error)`
            // is unreachable here — `guard let self else` fires precisely
            // when `self` is nil, so the `??` left side always evaluates to
            // nil. The propagation that actually happens is `return attempt`
            // (which is already in a failed state because we got here via
            // `flatMapError`). Simplifying makes the intent obvious.
            guard let self else { return attempt }
            let shouldRetry = allowRetry
                && Self.isIdempotentMethod(head.method)
                && Self.isRetryableConnectionError(error)
            if shouldRetry {
                self.logger.log(.debug, "Retrying idempotent request via fresh connection after upstream reset (\(proxy.endpoint)).", category: .proxy)
                return self.bufferedExchange(
                    head: head,
                    requestBody: requestBody,
                    forcedProxy: proxy,
                    allowRetry: false,
                    preferFreshConnection: true,
                    authSource: authSource
                )
            }
            if !ConnectionPoolError.isLocalNonUpstreamFailure(error) {
                self.recordFailure(for: proxy)
            }
            return self.group.next().makeFailedFuture(error)
        }
    }

    private func performBufferedExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        connection: PooledUpstreamConnection,
        proxy: UpstreamProxy,
        authSource: String?
    ) -> EventLoopFuture<UpstreamExchangeResponse> {
        let isAuthenticated = self.lock.withLock { connection.authenticated }
        let promise = connection.channel.eventLoop.makePromise(of: UpstreamExchangeResponse.self)
        let handler = HTTPExchangeHandler(
            connection: connection,
            authenticatorProvider: self.authenticatorProvider,
            originalHead: head,
            body: requestBody,
            isAuthenticated: isAuthenticated,
            authSource: authSource,
            authHandshakeLimiter: authHandshakeLimiter,
            authLimitProvider: authHandshakeLimits,
            eventSink: eventSink,
            responseTimeout: upstreamResponseTimeout,
            responsePromise: promise
        )

        return connection.channel.pipeline.addHandler(handler).flatMap {
            handler.start()
            return promise.futureResult
        }.flatMapError { error in
            promise.fail(error)
            self.logger.log(.warning, "Exchange via \(proxy.endpoint) failed: \(error.localizedDescription)", category: .proxy)
            connection.channel.close(mode: .all, promise: nil)
            self.lock.withLockVoid {
                self.removeConnectionLocked(id: connection.id)
            }
            return connection.channel.eventLoop.makeFailedFuture(error)
        }.flatMap { response in
            self.lock.withLockVoid {
                connection.authenticated = true
                if let authMethod = response.authMethod {
                    connection.authMethod = authMethod
                }
            }
            self.release(connection, keepAlive: response.head.isKeepAlive)
            return connection.channel.eventLoop.makeSucceededFuture(response)
        }
    }

    private func performStreamingExchange(
        head: HTTPRequestHead,
        requestBody: HTTPRequestBody?,
        clientChannel: Channel,
        connection: PooledUpstreamConnection,
        proxy: UpstreamProxy,
        authSource: String?
    ) -> EventLoopFuture<StreamingExchangeResult> {
        let isAuthenticated = self.lock.withLock { connection.authenticated }
        let promise = connection.channel.eventLoop.makePromise(of: StreamingExchangeResult.self)
        let handler = HTTPExchangeHandler(
            connection: connection,
            authenticatorProvider: self.authenticatorProvider,
            originalHead: head,
            body: requestBody,
            isAuthenticated: isAuthenticated,
            authSource: authSource,
            authHandshakeLimiter: authHandshakeLimiter,
            authLimitProvider: authHandshakeLimits,
            eventSink: eventSink,
            clientChannel: clientChannel,
            responseTimeout: upstreamResponseTimeout,
            streamingPromise: promise
        )

        return connection.channel.pipeline.addHandler(handler).flatMap {
            handler.start()
            return promise.futureResult
        }.flatMapError { error in
            promise.fail(error)
            self.logger.log(.warning, "Streaming exchange via \(proxy.endpoint) failed: \(error.localizedDescription)", category: .proxy)
            connection.channel.close(mode: .all, promise: nil)
            self.lock.withLockVoid {
                self.removeConnectionLocked(id: connection.id)
            }
            return connection.channel.eventLoop.makeFailedFuture(error)
        }.flatMap { result in
            self.lock.withLockVoid {
                connection.authenticated = true
                if let authMethod = result.authMethod {
                    connection.authMethod = authMethod
                }
            }
            self.release(connection, keepAlive: result.keepAlive)
            return connection.channel.eventLoop.makeSucceededFuture(result)
        }
    }

    private func recordSuccess(for proxy: UpstreamProxy, latencyMS: Int) {
        var emittedTransition: UpstreamCircuitBreaker.Transition?
        lock.withLockVoid {
            syncUpstreamStatesLocked(with: configProvider().enabledUpstreams)
            var breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
            emittedTransition = breaker.recordSuccess(latencyMS: latencyMS)
            breakers[proxy.id] = breaker
            lastSelectedUpstreamID = proxy.id
        }
        if let emittedTransition {
            emitTransition(emittedTransition, for: proxy)
        }
    }

    private func recordFailure(for proxy: UpstreamProxy) {
        let config = configProvider()
        let proxies = config.enabledUpstreams
        let thresholds = breakerThresholds(from: config)
        var emittedTransition: UpstreamCircuitBreaker.Transition?
        lock.withLockVoid {
            syncUpstreamStatesLocked(with: proxies)
            var breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
            emittedTransition = breaker.recordFailure(
                now: Date(),
                threshold: thresholds.failureThreshold,
                windowSeconds: thresholds.windowSeconds,
                baseOpenInterval: thresholds.baseOpenInterval,
                maxOpenInterval: thresholds.maxOpenInterval
            )
            breakers[proxy.id] = breaker
        }
        if let emittedTransition {
            emitTransition(emittedTransition, for: proxy)
        }
    }

    /// Reset every upstream's circuit breaker to closed without touching its
    /// EWMA latency. Called by `ProxyOrchestrator` after a VPN flap recovers
    /// (`.reasserting → .connected`) so the next request through each upstream
    /// gets an honest first attempt instead of being rejected by an open
    /// circuit that was tripped on the now-stale flap-network path.
    ///
    /// Latency stats (EWMA) are preserved by the breaker's `reset(_:_:)`
    /// because the upstream itself didn't change, only the path through the
    /// kernel did. See `docs/design-vpn-flap-resilience.md` § "Pool Hardening".
    package func resetCircuitsAfterFlap() {
        let baseOpenInterval = breakerThresholds(from: configProvider()).baseOpenInterval
        var pending: [PendingTransitionEmission] = []
        lock.withLockVoid {
            syncUpstreamStatesLocked(with: configProvider().enabledUpstreams)
            for (id, var breaker) in breakers {
                if let transition = breaker.reset(reason: .vpnFlapRecovered, baseOpenInterval: baseOpenInterval) {
                    let identity = upstreamIdentities[id]
                    pending.append(PendingTransitionEmission(
                        transition: transition,
                        name: identity?.name ?? "unknown",
                        endpoint: identity?.endpoint ?? "unknown"
                    ))
                }
                breakers[id] = breaker
            }
        }
        for emission in pending {
            publishEmission(emission)
        }
    }

    private func syncUpstreamStatesLocked(with proxies: [UpstreamProxy]) {
        let allowedIDs = Set(proxies.map(\.id))
        breakers = breakers.filter { allowedIDs.contains($0.key) }
        upstreamIdentities = upstreamIdentities.filter { allowedIDs.contains($0.key) }
        for proxy in proxies {
            if breakers[proxy.id] == nil {
                breakers[proxy.id] = UpstreamCircuitBreaker()
            }
            // Refresh identity on every sync; the user may have renamed an
            // upstream or moved it to a new host without changing its UUID.
            upstreamIdentities[proxy.id] = (proxy.name, proxy.endpoint)
        }
    }

    /// Container the callers of `selectableProxiesLocked` use to publish
    /// breaker transitions OUTSIDE the pool lock. The fields are pre-
    /// resolved (`name` + `endpoint` already looked up while still holding
    /// the lock) so the publish path is purely a `eventSink?` + `logger.log`
    /// fan-out — no further state lookups, no further locking.
    private struct PendingTransitionEmission {
        let transition: UpstreamCircuitBreaker.Transition
        let name: String
        let endpoint: String
    }

    private struct SelectableProxiesOutcome {
        let candidates: [UpstreamProxy]
        let pendingEmissions: [PendingTransitionEmission]
    }

    private func selectableProxiesLocked(from proxies: [UpstreamProxy], now: Date) -> SelectableProxiesOutcome {
        var candidates: [UpstreamProxy] = []
        var fallback: UpstreamProxy?
        var fallbackOpenedAt = Date.distantFuture
        var pending: [PendingTransitionEmission] = []

        for proxy in proxies {
            var breaker = breakers[proxy.id] ?? UpstreamCircuitBreaker()
            switch breaker.state {
            case .closed:
                candidates.append(proxy)
            case .open:
                if let transition = breaker.tryHalfOpen(now: now) {
                    // Backoff elapsed and probe slot was free — emit and
                    // promote into candidates so the very next request
                    // becomes the probe.
                    pending.append(PendingTransitionEmission(transition: transition, name: proxy.name, endpoint: proxy.endpoint))
                    breakers[proxy.id] = breaker
                    candidates.append(proxy)
                } else {
                    let openedAt = breaker.lastOpenedAt ?? .distantFuture
                    if openedAt < fallbackOpenedAt {
                        fallback = proxy
                        fallbackOpenedAt = openedAt
                    }
                }
            case .halfOpen:
                if !breaker.halfOpenProbeInFlight {
                    // Defensive: half-open with no probe in flight is
                    // unreachable in normal operation (every entry to
                    // `.halfOpen` arms the slot via `tryHalfOpen`). Still
                    // surface the upstream to the selection round so a
                    // stuck pool can recover; the next recordSuccess /
                    // recordFailure will re-anchor the breaker.
                    candidates.append(proxy)
                }
            }
        }

        if candidates.isEmpty, let fallback {
            // Last-resort: no upstream's backoff has elapsed yet but we
            // need *something* to try. Force the longest-opened breaker
            // into half-open. This mirrors the pre-extraction behaviour
            // and keeps client requests from failing-fast when every
            // upstream is open.
            var breaker = breakers[fallback.id] ?? UpstreamCircuitBreaker()
            if let transition = breaker.forceHalfOpen() {
                pending.append(PendingTransitionEmission(transition: transition, name: fallback.name, endpoint: fallback.endpoint))
                breakers[fallback.id] = breaker
            }
            return SelectableProxiesOutcome(candidates: [fallback], pendingEmissions: pending)
        }

        return SelectableProxiesOutcome(candidates: candidates, pendingEmissions: pending)
    }

    private func chooseProxyLocked(from proxies: [UpstreamProxy]) -> UpstreamProxy {
        guard proxies.count > 1 else { return proxies[0] }

        selectionCounter += 1
        let preferredIndex = min(preferredProxyIndex, max(0, proxies.count - 1))
        let firstIndex = (preferredIndex + selectionCounter) % proxies.count
        let secondIndex = (preferredIndex + (selectionCounter * 7) + 1) % proxies.count

        let first = proxies[firstIndex]
        let second = proxies[secondIndex]
        let firstScore = breakers[first.id]?.ewmaLatencyMS ?? Double.greatestFiniteMagnitude
        let secondScore = breakers[second.id]?.ewmaLatencyMS ?? Double.greatestFiniteMagnitude
        return firstScore <= secondScore ? first : second
    }

    // MARK: - Circuit breaker helpers

    private struct BreakerThresholds {
        var failureThreshold: Int
        var windowSeconds: TimeInterval
        var baseOpenInterval: TimeInterval
        var maxOpenInterval: TimeInterval
    }

    private func breakerThresholds(from config: ProxyConfig) -> BreakerThresholds {
        // All four thresholds live on `HealthSection`. The defaults preserve
        // the legacy hardcoded values (5 / 30 s / 300 s), so existing configs
        // that don't carry the keys still behave identically.
        BreakerThresholds(
            failureThreshold: config.circuitFailureThreshold,
            windowSeconds: config.circuitBreakerWindowSeconds,
            baseOpenInterval: config.circuitBaseOpenIntervalSeconds,
            maxOpenInterval: config.circuitMaxOpenIntervalSeconds
        )
    }

    /// Fan a breaker transition out to the runtime event log + the local
    /// `logger`. Used by `recordSuccess` / `recordFailure` (which still
    /// operate on a known `UpstreamProxy` and call this directly after
    /// releasing the lock).
    private func emitTransition(
        _ transition: UpstreamCircuitBreaker.Transition,
        for proxy: UpstreamProxy
    ) {
        publishEmission(PendingTransitionEmission(
            transition: transition,
            name: proxy.name,
            endpoint: proxy.endpoint
        ))
    }

    /// Side-effect-only publish path. Pre-resolved emission (no state
    /// lookups, no locking) so it's safe to call from any context — most
    /// importantly from inside a `lock.withLock` *immediately after* the
    /// lock is released. Single funnel for both the recordSuccess /
    /// recordFailure direct-emit paths and the deferred-emit paths
    /// (`selectProxy`, `resetCircuitsAfterFlap`) that batch transitions
    /// to publish outside the pool lock.
    private func publishEmission(_ emission: PendingTransitionEmission) {
        let event: RuntimeEvent
        let logMessage: String
        let name = emission.name
        let endpoint = emission.endpoint
        switch emission.transition {
        case let .opened(reason, consecutiveFailures, openInterval):
            let reasonTag: String
            switch reason {
            case .thresholdReached: reasonTag = "threshold"
            case .probeFailed: reasonTag = "probe_failed"
            }
            event = RuntimeEvent(
                kind: .health,
                event: "upstream.circuit_opened",
                detail: "upstream=\(name) endpoint=\(endpoint) reason=\(reasonTag) failures=\(consecutiveFailures) openInterval=\(Int(openInterval))s"
            )
            logMessage = "Upstream \(name) circuit opened (\(reasonTag), \(Int(openInterval))s backoff)."
        case let .halfOpened(elapsedSeconds):
            event = RuntimeEvent(
                kind: .health,
                event: "upstream.circuit_half_opened",
                detail: "upstream=\(name) endpoint=\(endpoint) openForSeconds=\(Int(elapsedSeconds))"
            )
            logMessage = "Upstream \(name) circuit half-open (probe armed, was open \(Int(elapsedSeconds))s)."
        case let .closed(reason):
            let reasonTag: String
            switch reason {
            case .probeSuccess: reasonTag = "probe_success"
            case let .reset(resetReason):
                switch resetReason {
                case .vpnFlapRecovered: reasonTag = "reset_vpn_flap"
                case .daemonRestart: reasonTag = "reset_daemon_restart"
                case .manualOverride: reasonTag = "reset_manual"
                }
            }
            event = RuntimeEvent(
                kind: .health,
                event: "upstream.circuit_closed",
                detail: "upstream=\(name) endpoint=\(endpoint) reason=\(reasonTag)"
            )
            logMessage = "Upstream \(name) circuit closed (\(reasonTag))."
        }
        eventSink?(event)
        logger.log(.notice, logMessage, category: .network)
    }

    private func pruneExpiredIdleConnectionsLocked(now: Date) {
        let expiredIDs = allConnections.values.compactMap { connection in
            (!connection.inUse && isConnectionExpired(connection, now: now)) ? connection.id : nil
        }
        guard !expiredIDs.isEmpty else { return }
        let expiredSet = Set(expiredIDs)
        for id in expiredIDs {
            allConnections[id]?.channel.close(mode: .all, promise: nil)
        }
        removeConnectionsLocked(ids: expiredSet)
    }

    private func insertConnectionLocked(_ connection: PooledUpstreamConnection) {
        allConnections[connection.id] = connection
        connectionIDsByChannel[ObjectIdentifier(connection.channel)] = connection.id
    }

    private func removeConnectionLocked(id: UUID) {
        if let connection = allConnections.removeValue(forKey: id) {
            connectionIDsByChannel.removeValue(forKey: ObjectIdentifier(connection.channel))
        }
        idleConnections = idleConnections.mapValues { connections in
            connections.filter { $0.id != id }
        }
    }

    private func removeConnectionsLocked(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let connection = allConnections.removeValue(forKey: id) {
                connectionIDsByChannel.removeValue(forKey: ObjectIdentifier(connection.channel))
            }
        }
        idleConnections = idleConnections.mapValues { connections in
            connections.filter { !ids.contains($0.id) }
        }
    }

    private func preconditionCapacityLocked(maxConnections: Int) {
        precondition(pendingConnectionCount >= 0, "ConnectionPool pending count must never go negative")
        precondition(
            allConnections.count + pendingConnectionCount <= maxConnections,
            "ConnectionPool invariant violated: active + idle + pending must stay <= maxConnections"
        )
    }

    private func isConnectionExpired(_ connection: PooledUpstreamConnection, now: Date) -> Bool {
        now.timeIntervalSince(connection.createdAt) >= Self.maxConnectionAgeSeconds
    }

    package static func streamingResponseInterruptedDetail(uri: String, upstream: String, cause: Error) -> String {
        "uri=\(uri) upstream=\(upstream) cause=\(cause.localizedDescription)"
    }

    package static func streamingResponseInterruptedEvent(uri: String, upstream: String, cause: Error) -> RuntimeEvent {
        RuntimeEvent(
            kind: .connection,
            event: "streaming.response_interrupted",
            detail: streamingResponseInterruptedDetail(uri: uri, upstream: upstream, cause: cause)
        )
    }

    package static func upstreamResponseTimedOutEvent(uri: String, upstream: String) -> RuntimeEvent {
        RuntimeEvent(
            kind: .connection,
            event: "upstream.response_timeout",
            detail: "uri=\(uri) upstream=\(upstream)"
        )
    }

    private static func isIdempotentMethod(_ method: HTTPMethod) -> Bool {
        switch method {
        case .GET, .HEAD, .OPTIONS, .TRACE:
            return true
        default:
            return false
        }
    }

    private static func isRetryableConnectionError(_ error: Error) -> Bool {
        if let channelError = error as? ChannelError {
            switch channelError {
            case .eof, .ioOnClosedChannel, .alreadyClosed:
                return true
            default:
                break
            }
        }

        if let ioError = error as? IOError {
            switch ioError.errnoCode {
            case ECONNRESET, EPIPE, ETIMEDOUT:
                return true
            default:
                break
            }
        }

        let message = error.localizedDescription.lowercased()
        return message.contains("connection reset")
            || message.contains("broken pipe")
            || message.contains("closed")
    }
}

/// Protocol-based 2-step HTTP exchange with optional response streaming.
/// Buffered mode (health checks): accumulates full response, resolves bufferedPromise.
/// Streaming mode (proxy traffic): forwards non-407 response parts directly to clientChannel.
private final class HTTPExchangeHandler: ChannelDuplexHandler, RemovableChannelHandler, @unchecked Sendable {
    typealias InboundIn = HTTPClientResponsePart
    typealias InboundOut = HTTPClientResponsePart
    typealias OutboundIn = HTTPClientRequestPart
    typealias OutboundOut = HTTPClientRequestPart

    private enum Phase {
        case awaitingChallenge
        case awaitingFinal
    }

    private let connection: PooledUpstreamConnection
    private let authenticatorProvider: (String) throws -> ProxyAuthenticator
    private let originalHead: HTTPRequestHead
    private let originalBody: HTTPRequestBody?
    private let isAuthenticated: Bool
    private let authSource: String?
    private let authHandshakeLimiter: AuthHandshakeLimiter
    private let authLimitProvider: @Sendable () -> AuthHandshakeLimiter.Limits
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let responseTimeout: TimeAmount

    private let clientChannel: Channel?
    private let bufferedPromise: EventLoopPromise<UpstreamExchangeResponse>?
    private let streamingPromise: EventLoopPromise<StreamingExchangeResult>?

    private var phase: Phase
    private var responseHead: HTTPResponseHead?
    private var responseBody = ByteBufferAllocator().buffer(capacity: 0)
    private var challengeHeaders: [String] = []
    private var ctx: ChannelHandlerContext?
    private var isStreaming = false
    private var authenticator: ProxyAuthenticator?
    private var lastAuthMethod: String?
    private var authPermit: AuthHandshakePermit?
    private var backpressure: HTTPResponseBackpressureController?
    private var responseTimeoutTask: Scheduled<Void>?
    private var completed = false

    init(
        connection: PooledUpstreamConnection,
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator,
        originalHead: HTTPRequestHead,
        body: HTTPRequestBody?,
        isAuthenticated: Bool,
        authSource: String?,
        authHandshakeLimiter: AuthHandshakeLimiter,
        authLimitProvider: @escaping @Sendable () -> AuthHandshakeLimiter.Limits,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        responseTimeout: TimeAmount,
        responsePromise: EventLoopPromise<UpstreamExchangeResponse>
    ) {
        self.connection = connection
        self.authenticatorProvider = authenticatorProvider
        self.originalHead = originalHead
        self.originalBody = body
        self.isAuthenticated = isAuthenticated
        self.authSource = authSource
        self.authHandshakeLimiter = authHandshakeLimiter
        self.authLimitProvider = authLimitProvider
        self.eventSink = eventSink
        self.responseTimeout = responseTimeout
        self.clientChannel = nil
        self.bufferedPromise = responsePromise
        self.streamingPromise = nil
        self.phase = isAuthenticated ? .awaitingFinal : .awaitingChallenge
    }

    init(
        connection: PooledUpstreamConnection,
        authenticatorProvider: @escaping (String) throws -> ProxyAuthenticator,
        originalHead: HTTPRequestHead,
        body: HTTPRequestBody?,
        isAuthenticated: Bool,
        authSource: String?,
        authHandshakeLimiter: AuthHandshakeLimiter,
        authLimitProvider: @escaping @Sendable () -> AuthHandshakeLimiter.Limits,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        clientChannel: Channel,
        responseTimeout: TimeAmount,
        streamingPromise: EventLoopPromise<StreamingExchangeResult>
    ) {
        self.connection = connection
        self.authenticatorProvider = authenticatorProvider
        self.originalHead = originalHead
        self.originalBody = body
        self.isAuthenticated = isAuthenticated
        self.authSource = authSource
        self.authHandshakeLimiter = authHandshakeLimiter
        self.authLimitProvider = authLimitProvider
        self.eventSink = eventSink
        self.responseTimeout = responseTimeout
        self.clientChannel = clientChannel
        self.bufferedPromise = nil
        self.streamingPromise = streamingPromise
        self.phase = isAuthenticated ? .awaitingFinal : .awaitingChallenge
    }

    func handlerAdded(context: ChannelHandlerContext) {
        self.ctx = context
        if let clientChannel {
            let controller = HTTPResponseBackpressureController(
                clientChannel: clientChannel,
                upstreamChannel: context.channel
            )
            backpressure = controller
            controller.install()
        }
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        backpressure?.complete()
        backpressure = nil
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
        self.ctx = nil
    }

    func start() {
        guard let ctx else {
            failPromises(ConnectionPoolError.invalidResponse)
            return
        }
        if isAuthenticated {
            sendRequest(authHeader: nil, context: ctx)
        } else {
            guard beginAuthHandshake(host: connection.proxy.endpoint) else {
                failPromises(ConnectionPoolError.authHandshakeLimitExceeded)
                return
            }
            nonisolated(unsafe) let provider = self.authenticatorProvider
            let host = self.connection.proxy.host
            let eventLoop = ctx.eventLoop
            let handler = self
            nonisolated(unsafe) let capturedCtx = ctx
            Task { @Sendable in
                do {
                    let auth = try provider(host)
                    let token = try auth.initialToken(for: host)
                    eventLoop.execute {
                        handler.authenticator = auth
                        handler.recordAuthMethod(fromHeader: token)
                        handler.sendRequest(authHeader: token, context: capturedCtx)
                    }
                } catch {
                    eventLoop.execute { handler.failPromises(error) }
                }
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let part = unwrapInboundIn(data)
        switch part {
        case .head(let head):
            responseHead = head
            if head.status == .proxyAuthenticationRequired {
                cancelResponseTimeout()
                challengeHeaders = head.headers["Proxy-Authenticate"]
            } else {
                finishAuthHandshake()
                cancelResponseTimeout()
            }
            if head.status != .proxyAuthenticationRequired, let clientChannel {
                isStreaming = true
                cancelResponseTimeout()
                var clientHead = head
                HTTPHopByHopHeaders.sanitizeForwardedResponseHeaders(&clientHead.headers)
                if let backpressure {
                    backpressure.write(.head(clientHead), flush: false, upstreamContext: context)
                } else {
                    clientChannel.write(HTTPServerResponsePart.head(clientHead), promise: nil)
                }
            }
        case .body(var buffer):
            if isStreaming, let clientChannel {
                if let backpressure {
                    backpressure.write(.body(.byteBuffer(buffer)), flush: true, upstreamContext: context)
                } else {
                    clientChannel.writeAndFlush(HTTPServerResponsePart.body(.byteBuffer(buffer)), promise: nil)
                }
            } else {
                responseBody.writeBuffer(&buffer)
            }
        case .end(let trailers):
            if isStreaming, let clientChannel {
                nonisolated(unsafe) let ctx = context
                let finish: @Sendable (Result<Void, Error>) -> Void = { result in
                    self.backpressure?.complete()
                    ctx.pipeline.removeHandler(self, promise: nil)
                    switch result {
                    case .success:
                        self.succeedStreaming(StreamingExchangeResult(
                            upstream: self.connection.proxy,
                            keepAlive: self.responseHead?.isKeepAlive ?? false,
                            authMethod: self.resolvedAuthMethod()
                        ))
                    case .failure(let error):
                        self.failPromises(error)
                    }
                }
                // Trailers ride `.end` — dropping them here silently breaks
                // chunked responses that carry them (gRPC-Web status, digest
                // trailers). The direct path already forwards them.
                if let backpressure {
                    backpressure.write(.end(trailers), flush: true, upstreamContext: context).whenComplete(finish)
                } else {
                    clientChannel.writeAndFlush(HTTPServerResponsePart.end(trailers)).whenComplete(finish)
                }
            } else {
                handleEnd(context: context)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if isStreaming {
            backpressure?.complete()
            eventSink?(ConnectionPool.streamingResponseInterruptedEvent(
                uri: originalHead.uri,
                upstream: connection.proxy.endpoint,
                cause: error
            ))
            clientChannel?.close(mode: .all, promise: nil)
            failPromises(ConnectionPoolError.streamingResponseInterrupted)
        } else {
            failPromises(error)
        }
        context.close(promise: nil)
    }

    private func failPromises(_ error: Error) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        backpressure?.complete()
        finishAuthHandshake()
        bufferedPromise?.fail(error)
        streamingPromise?.fail(error)
    }

    private func succeedBuffered(_ response: UpstreamExchangeResponse) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        finishAuthHandshake()
        bufferedPromise?.succeed(response)
    }

    private func succeedStreaming(_ result: StreamingExchangeResult) {
        guard !completed else { return }
        completed = true
        cancelResponseTimeout()
        finishAuthHandshake()
        streamingPromise?.succeed(result)
    }

    private func handleEnd(context: ChannelHandlerContext) {
        guard let head = responseHead else {
            failPromises(ConnectionPoolError.invalidResponse)
            return
        }

        if head.status != .proxyAuthenticationRequired {
            context.pipeline.removeHandler(self, promise: nil)
            succeedBuffered(
                UpstreamExchangeResponse(
                    head: head,
                    body: responseBody,
                    upstream: connection.proxy,
                    authMethod: resolvedAuthMethod()
                )
            )
            return
        }

        switch phase {
        case .awaitingChallenge:
            guard let auth = self.authenticator else {
                failPromises(ConnectionPoolError.authenticationRejected)
                context.close(promise: nil)
                return
            }
            let headers = challengeHeaders
            let host = connection.proxy.host
            let eventLoop = context.eventLoop
            let handler = self
            nonisolated(unsafe) let ctx = context
            Task { @Sendable in
                do {
                    // nil here means the authenticator has no token to send. Since we're
                    // inside a 407 response, the proxy still demands auth — this is a rejection.
                    // (Successful mutual-auth completion arrives as 200, not 407; see RFC 4559 §4.)
                    guard let response = try auth.processChallenge(headerValues: headers, host: host) else {
                        eventLoop.execute {
                            handler.failPromises(ConnectionPoolError.authenticationRejected)
                            ctx.close(promise: nil)
                        }
                        return
                    }
                    eventLoop.execute {
                        handler.phase = .awaitingFinal
                        handler.responseHead = nil
                        handler.responseBody.clear()
                        handler.challengeHeaders = []
                        handler.recordAuthMethod(fromHeader: response)
                        handler.sendRequest(authHeader: response, context: ctx)
                    }
                } catch {
                    eventLoop.execute {
                        handler.failPromises(error)
                        ctx.close(promise: nil)
                    }
                }
            }

        case .awaitingFinal:
            failPromises(ConnectionPoolError.authenticationRejected)
            context.close(promise: nil)
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

    private func sendRequest(authHeader: String?, context: ChannelHandlerContext) {
        guard var head = upstreamHead(for: originalHead) else {
            failPromises(ConnectionPoolError.invalidResponse)
            context.close(promise: nil)
            return
        }
        if let authHeader {
            recordAuthMethod(fromHeader: authHeader)
            head.headers.replaceOrAdd(name: "Proxy-Authorization", value: authHeader)
        }

        context.write(wrapOutboundOut(.head(head)), promise: nil)
        nonisolated(unsafe) let ctx = context
        let endRequest: @Sendable () -> Void = {
            self.resetResponseTimeout(context: ctx)
            ctx.writeAndFlush(self.wrapOutboundOut(.end(nil))).whenFailure { error in
                self.failPromises(error)
                ctx.close(promise: nil)
            }
        }
        guard let body = originalBody else {
            endRequest()
            return
        }
        body.writeClientBody(context: ctx).whenComplete { result in
            switch result {
            case .success:
                endRequest()
            case .failure(let error):
                self.failPromises(error)
                ctx.close(promise: nil)
            }
        }
    }

    private func resolvedAuthMethod() -> String? {
        lastAuthMethod ?? connection.authMethod
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

    private func resetResponseTimeout(context: ChannelHandlerContext) {
        cancelResponseTimeout()
        nonisolated(unsafe) let ctx = context
        responseTimeoutTask = ctx.eventLoop.scheduleTask(in: responseTimeout) { [weak self] in
            guard let self else { return }
            self.eventSink?(ConnectionPool.upstreamResponseTimedOutEvent(
                uri: self.originalHead.uri,
                upstream: self.connection.proxy.endpoint
            ))
            self.failPromises(ConnectionPoolError.upstreamResponseTimedOut)
            ctx.close(promise: nil)
        }
    }

    private func cancelResponseTimeout() {
        responseTimeoutTask?.cancel()
        responseTimeoutTask = nil
    }

    private func upstreamHead(for head: HTTPRequestHead) -> HTTPRequestHead? {
        var updated = head
        guard HTTPRequestTarget.isSafeHTTPRequestTarget(updated.uri) else { return nil }

        if !updated.uri.contains("://"), let host = updated.headers.first(name: "Host") {
            guard HTTPRequestTarget.isSafeHTTPHostHeader(host) else { return nil }
            updated.uri = "http://\(host)\(updated.uri)"
        }
        HTTPHopByHopHeaders.sanitizeForwardedRequestHeaders(&updated.headers)
        return updated
    }
}
