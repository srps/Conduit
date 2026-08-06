// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

package final class LocalDNSForwarder: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let preferProxyPathForDoH: @Sendable () -> Bool
    private let onMetrics: (@Sendable (Int, Int, Int) -> Void)?
    private let tcpIdleTimeoutSeconds: Int64
    private let tcpMaximumConnections: Int
    private var channel: Channel?
    private var tcpChannel: Channel?
    private var tcpConnections: DNSTCPConnectionRegistry?
    private var core: DNSResolutionCore?

    package var listeningHost: String? {
        channel?.localAddress?.ipAddress
    }

    package var listeningPort: Int? {
        channel?.localAddress?.port
    }

    /// The TCP listener's port, or nil when only UDP is bound. Always equal to
    /// `listeningPort` when present — see `start(host:port:)`.
    package var tcpListeningPort: Int? {
        tcpChannel?.localAddress?.port
    }

    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        preferProxyPathForDoH: @escaping @Sendable () -> Bool = { false },
        onMetrics: (@Sendable (Int, Int, Int) -> Void)? = nil,
        // Exposed only so tests can drive the "client waiting on a slow lookup
        // must not be cut off" rule without a ten-second wait.
        tcpIdleTimeoutSeconds: Int64 = DNSTCPHandler.defaultIdleTimeoutSeconds,
        // Exposed only so tests can reach the cap without opening 64 sockets.
        tcpMaximumConnections: Int = DNSTCPConnectionRegistry.defaultMaximumConnections
    ) {
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.preferProxyPathForDoH = preferProxyPathForDoH
        self.onMetrics = onMetrics
        self.tcpIdleTimeoutSeconds = tcpIdleTimeoutSeconds
        self.tcpMaximumConnections = tcpMaximumConnections
    }

    /// Binds UDP and TCP on the same port.
    ///
    /// Order matters: UDP binds first and TCP follows on whatever port UDP
    /// actually got. With `port: 0` — used by `pm-proxy --dns-port 0` and by
    /// the tests — binding both to 0 would land the two listeners on different
    /// ephemeral ports, and a resolver client that retried over TCP would find
    /// nothing there.
    ///
    /// A TCP bind failure is not fatal. UDP-only is what this forwarder shipped
    /// as, and a resolver serving UDP is far more useful than one that refused
    /// to start; the failure is logged rather than thrown.
    package func start(host: String, port: Int) async throws {
        let core = DNSResolutionCore(
            group: group,
            logger: logger,
            configProvider: configProvider,
            preferProxyPathForDoH: preferProxyPathForDoH,
            onMetrics: onMetrics
        )
        self.core = core

        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(DNSUDPHandler(core: core))
            }
        channel = try await bootstrap.bind(host: host, port: port).get()
        let actualHost = channel?.localAddress?.ipAddress ?? host
        let actualPort = channel?.localAddress?.port ?? port

        let log = logger
        let idleTimeout = tcpIdleTimeoutSeconds
        let connections = DNSTCPConnectionRegistry(
            maximumConnections: tcpMaximumConnections,
            logger: logger
        )
        tcpConnections = connections
        let tcpBootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.tcpNoDelay, value: 1)
            .childChannelInitializer { channel in
                guard connections.admit(channel) else {
                    channel.close(promise: nil)
                    return channel.eventLoop.makeSucceededVoidFuture()
                }
                channel.closeFuture.whenComplete { _ in connections.release(channel) }
                return channel.pipeline.addHandler(
                    DNSTCPHandler(core: core, logger: log, idleTimeoutSeconds: idleTimeout)
                )
            }
        do {
            tcpChannel = try await tcpBootstrap.bind(host: host, port: actualPort).get()
            logger.log(.notice, "DNS forwarder listening on \(actualHost):\(actualPort) (UDP and TCP).", category: .network)
        } catch {
            logger.log(
                .warning,
                "DNS forwarder listening on \(actualHost):\(actualPort) (UDP only) — TCP bind failed: \(error.displayDescription). Clients that retry over TCP after a truncated answer will not reach it.",
                category: .network
            )
            tcpConnections = nil
        }
    }

    package func stop() async {
        if let channel {
            _ = try? await channel.close().get()
        }
        if let tcpChannel {
            _ = try? await tcpChannel.close().get()
        }
        channel = nil
        tcpChannel = nil
        // Closing a `ServerBootstrap` channel only stops accepting; the child
        // channels it already accepted survive it, and each one holds the core
        // — so a stopped forwarder would keep answering those clients from the
        // cache, from internal DNS and from intercept rules until their idle
        // window elapsed, and a restart would briefly run two resolvers with
        // separate caches and metrics.
        if let tcpConnections {
            await tcpConnections.closeAll()
        }
        tcpConnections = nil
        core?.invalidateSessions()
        core = nil
        logger.log(.notice, "DNS forwarder stopped.", category: .network)
    }

    /// Discard the current DoH `URLSession`s, build fresh ones, and flush the
    /// per-domain response cache. Called from `ProxyOrchestrator.handleSystemWake()`
    /// and the VPN-recovery branches of `handleVPNStateChange()` because
    /// `URLSession`'s connection pool and per-host TCP keep-alive state survive
    /// system sleep — and in the VPN-while-asleep case those connections become
    /// pinned to a now-defunct utun route. Without this, the next DoH lookup
    /// reuses the dead socket, hits `timeoutIntervalForRequest`, returns nil
    /// for every internet hostname, and the user sees `ERR_NAME_NOT_RESOLVED`
    /// in the browser. See `docs/design-vpn-flap-resilience.md` for the
    /// broader recovery model — these `URLSession`s are NOT covered by the
    /// "Never close active upstream channels" rule (which protects user
    /// streams in `ConnectionPool`); they carry rapid-fire DNS-lookup HTTP
    /// requests where recycling is exactly what we want.
    ///
    /// No-op when the forwarder is stopped (handler is nil). Safe to call
    /// from any actor context.
    package func resetUpstreamTransports(reason: String) {
        guard let core else {
            logger.log(.debug, "DNS forwarder transports reset skipped (forwarder not running). reason=\(reason)", category: .network)
            return
        }
        core.resetUpstreamTransports()
        logger.log(.notice, "DNS forwarder transports reset (reason=\(reason)).", category: .network)
    }

    /// Number of cached DNS response entries. Test-only accessor — production
    /// code must not depend on the absolute count (the cache is allowed to
    /// evict opportunistically). Used to verify `resetUpstreamTransports`
    /// flushes the cache.
    package var cachedResponseCount: Int {
        core?.cachedResponseCount ?? 0
    }
}

/// Container for the DoH-fetch `URLSession` pair. Held inside a lock so we
/// can atomically swap it on `resetUpstreamTransports()` without racing with
/// in-flight DoH requests reading the sessions in `resolveViaDoH`.
private struct DoHTransports: @unchecked Sendable {
    // NEVER call `invalidate()` while a DoH fetch may still be using these
    // sessions: `URLSession.data(for:)` on an invalidated session raises an
    // Objective-C `NSInvalidArgumentException` from CFNetwork
    // (`taskForClassInfo:`) that Swift cannot catch — the process aborts
    // (observed as the 2026-07-01 SIGABRT). All invalidation goes through
    // `DoHTransportsHandle`, which defers it until in-flight uses drain.
    let direct: URLSession
    let upstream: URLSession?
    let localProxy: URLSession?

    init(config: ProxyConfig) {
        self.direct = DoHSessionFactory.session(for: DoHSessionFactory.Route(proxy: nil))

        if let upstream = config.enabledUpstreams.first {
            self.upstream = DoHSessionFactory.session(
                for: DoHSessionFactory.Route(proxy: (upstream.host, upstream.port))
            )
        } else {
            self.upstream = nil
        }

        self.localProxy = DoHSessionFactory.session(
            for: DoHSessionFactory.Route(proxy: (config.localHost, config.localPort))
        )
    }

    func invalidate() {
        direct.invalidateAndCancel()
        upstream?.invalidateAndCancel()
        localProxy?.invalidateAndCancel()
    }

    /// On VPN, direct HTTPS to public DoH resolvers is often black-holed; try
    /// corporate upstream and the local proxy listener first.
    func sessions(preferProxyPath: Bool) -> [URLSession] {
        let proxied = [upstream, localProxy].compactMap { $0 }
        if preferProxyPath {
            return proxied + [direct]
        }
        return [direct] + proxied
    }
}

/// Reference-counted lifecycle guard around a `DoHTransports` value.
///
/// Invariant: `transports.invalidate()` runs exactly once, and only when the
/// handle is retired AND no `beginUse()`/`endUse()` window is open. This is
/// what makes `resetUpstreamTransports()` safe to call concurrently with
/// in-flight DoH queries — the old sessions stay valid until the last query
/// that snapshotted them finishes (bounded by the sessions' own 4 s request /
/// 8 s resource timeouts), then get invalidated by whichever side closes the
/// window last. Fresh queries never see a retired handle's sessions because
/// `beginUse()` refuses once retired.
private final class DoHTransportsHandle: @unchecked Sendable {
    let transports: DoHTransports
    private let lock = NSLock()
    private var activeUses = 0
    private var retired = false

    init(transports: DoHTransports) {
        self.transports = transports
    }

    /// Opens a use window. Returns false when the handle has been retired —
    /// the caller must re-read the current handle (or give up) instead of
    /// touching `transports`.
    func beginUse() -> Bool {
        lock.withLock {
            guard !retired else { return false }
            activeUses += 1
            return true
        }
    }

    /// Closes a use window. Runs the deferred invalidation if this was the
    /// last open window on a retired handle.
    func endUse() {
        let invalidateNow: Bool = lock.withLock {
            activeUses -= 1
            return retired && activeUses == 0
        }
        if invalidateNow {
            transports.invalidate()
        }
    }

    /// Marks the handle retired. Invalidates immediately when idle; otherwise
    /// the last `endUse()` performs the invalidation. Idempotent.
    func retire() {
        let invalidateNow: Bool = lock.withLock {
            guard !retired else { return false }
            retired = true
            return activeUses == 0
        }
        if invalidateNow {
            transports.invalidate()
        }
    }
}

/// The query→response engine, independent of how the query arrived.
///
/// UDP and TCP are two framings of the same protocol, and everything that makes
/// an answer — intercept rules, the response cache, the internal-then-DoH
/// ladder, the DoH transports and their reset contract, the metrics counters —
/// must be *one* instance shared by both. Splitting that state per transport
/// would give a TCP retry a cold cache and its own `URLSession` pool, and would
/// make `resetUpstreamTransports` reset only half the forwarder.
///
/// `resolve(query:)` always answers when it possibly can: it returns SERVFAIL
/// rather than nil for lookups that failed, and returns nil only for a query so
/// malformed that no well-formed response can echo its question.
private final class DNSResolutionCore: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let preferProxyPathForDoH: @Sendable () -> Bool
    private let onMetrics: (@Sendable (Int, Int, Int) -> Void)?
    private let lock = NSLock()
    private var queryCount = 0
    private var dohCount = 0
    private var cacheHitCount = 0
    /// Caps concurrent in-flight resolutions.
    ///
    /// A plain counter behind a lock, not a `DispatchSemaphore`: acquisition is
    /// a non-blocking try (an over-limit query is answered SERVFAIL, never
    /// queued), so the semaphore bought nothing, and `DispatchSemaphore.wait`
    /// is unavailable from async contexts under Swift 6 — blocking a
    /// cooperative-pool thread is exactly what it would do.
    private static let maximumInFlightQueries = 64
    private let inFlightQueries = NIOLockedValueBox(0)
    /// A DoH outage is not per-query, but the warning that reports it is: one
    /// browser page load asks for dozens of public names, and every one of them
    /// would emit its own near-identical "all providers failed" line for a
    /// single root cause. Report at most once per this interval, carrying the
    /// count suppressed since the last report — the same shape as
    /// `DNSTCPConnectionRegistry.refusalCountToReport()`.
    private static let dohFailureReportInterval: TimeInterval = 5
    private let dohFailureLock = NSLock()
    private var dohFailuresSinceLastReport = 0
    private var lastDoHFailureReport: Date?
    private var lastDoHFailureSignature: [Int]?
    /// Swappable on `resetUpstreamTransports`. Reads via `currentHandle()`
    /// take the lock briefly, copy the reference out, release the lock —
    /// keeping the rest of the DoH path lock-free. Session invalidation is
    /// deferred through the handle's use-count (see `DoHTransportsHandle`).
    private let transportsBox: NIOLockedValueBox<DoHTransportsHandle>
    private let responseCache = DNSResponseCache()

    init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        preferProxyPathForDoH: @escaping @Sendable () -> Bool,
        onMetrics: (@Sendable (Int, Int, Int) -> Void)? = nil
    ) {
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.preferProxyPathForDoH = preferProxyPathForDoH
        self.onMetrics = onMetrics
        self.transportsBox = NIOLockedValueBox(
            DoHTransportsHandle(transports: DoHTransports(config: configProvider()))
        )
    }

    private func currentHandle() -> DoHTransportsHandle {
        transportsBox.withLockedValue { $0 }
    }

    func invalidateSessions() {
        // Retire, don't invalidate directly: a `resolveViaDoH` call that
        // snapshotted this handle may still have fetches in flight, and
        // `data(for:)` on an invalidated session aborts the process (see
        // `DoHTransports`). The handle invalidates once those drain.
        transportsBox.withLockedValue { $0 }.retire()
    }

    /// Tear down the in-flight DoH `URLSession`s, swap in fresh ones built
    /// against the latest config, and flush the response cache. The fresh
    /// sessions start with an empty TCP connection pool and an empty
    /// host-resolution cache, which is exactly what we need after a wake or
    /// VPN-route change has invalidated the old sockets. Cache flush is the
    /// belt: even though cached A records remain semantically valid across a
    /// network event, dropping them forces a fresh end-to-end probe of the
    /// DoH path on the very next query, so the user sees the recovery
    /// immediately instead of after the cached entry's TTL expires.
    func resetUpstreamTransports() {
        let fresh = DoHTransportsHandle(transports: DoHTransports(config: configProvider()))
        let old = transportsBox.withLockedValue { current -> DoHTransportsHandle in
            let captured = current
            current = fresh
            return captured
        }
        // Retire (deferred invalidate), never invalidate directly — in-flight
        // DoH fetches that snapshotted `old` finish against still-valid
        // sessions (bounded by their 4 s/8 s timeouts) and the last one out
        // invalidates. Direct invalidation here raced those fetches and
        // crashed the process with an uncatchable CFNetwork NSException.
        old.retire()
        responseCache.clear()
    }

    var cachedResponseCount: Int {
        responseCache.entryCount
    }

    /// Non-blocking admission check. **Call this on the event loop, before
    /// spawning a resolution task**, and pair every `true` with exactly one
    /// `releaseQuery()`.
    ///
    /// The gate has to sit in front of task creation, not inside `resolve`.
    /// Under a flood, checking inside means every datagram still allocates a
    /// `Task` and captures its query buffer before being turned away, so the
    /// queue of pending rejections grows without any configured bound — the
    /// cap stops bounding the work and only bounds the concurrency of work
    /// already committed to. Gating first is what the `DispatchSemaphore` this
    /// replaced did from `channelRead`.
    func admitQuery() -> Bool {
        inFlightQueries.withLockedValue { count in
            guard count < Self.maximumInFlightQueries else { return false }
            count += 1
            return true
        }
    }

    func releaseQuery() {
        inFlightQueries.withLockedValue { $0 -= 1 }
    }

    /// The answer for a query turned away by `admitQuery()`. Logs once and
    /// hands back SERVFAIL so an overloaded forwarder still answers rather
    /// than going silent — the failure mode this PR exists to remove.
    func overLimitResponse(for query: [UInt8]) -> [UInt8]? {
        let domain = DNSWireFormat.extractDomainName(from: query)
        logger.log(.warning, "DNS: query limit reached, replying SERVFAIL for \(domain).", category: .network)
        recordQuery(doh: false, cacheHit: false)
        return DNSWireFormat.emptyServerFailureResponse(originalQuery: query)
    }

    /// Total-DoH-failure count since the last report (including this one), or
    /// nil while the warning is still throttled.
    ///
    /// The observed-status set is part of the throttle key, not just the
    /// message: "nothing was reachable" and "everything answered HTTP 403" are
    /// different diagnoses, and a transition between them is exactly the moment
    /// the log has to speak. A changed signature reports immediately; an
    /// unchanged one waits out the interval.
    private func doHFailureCountToReport(signature: [Int]) -> Int? {
        dohFailureLock.withLock {
            dohFailuresSinceLastReport += 1
            let now = Date.now
            if signature == lastDoHFailureSignature,
               let lastDoHFailureReport,
               now.timeIntervalSince(lastDoHFailureReport) < Self.dohFailureReportInterval {
                return nil
            }
            lastDoHFailureReport = now
            lastDoHFailureSignature = signature
            let failures = dohFailuresSinceLastReport
            dohFailuresSinceLastReport = 0
            return failures
        }
    }

    private func recordQuery(doh: Bool, cacheHit: Bool) {
        let (q, d, c) = lock.withLock {
            queryCount += 1
            if doh { dohCount += 1 }
            if cacheHit { cacheHitCount += 1 }
            return (queryCount, dohCount, cacheHitCount)
        }
        onMetrics?(q, d, c)
    }

    /// Resolves one query. Never throws, and answers whenever a well-formed
    /// answer is possible — see the type doc for why nil is so narrow.
    ///
    /// - Precondition: the caller holds a slot from `admitQuery()` and releases
    ///   it with `releaseQuery()` once this returns.
    func resolve(query queryBytes: [UInt8]) async -> [UInt8]? {
        guard queryBytes.count >= 12 else { return nil }

        let domain = DNSWireFormat.extractDomainName(from: queryBytes)
        let config = configProvider()
        let internalServers = config.dnsEntries.filter(\.enabled).flatMap(\.servers)
        let primaryDNS = internalServers.first ?? "192.0.2.53"
        let isInternal = DNSWireFormat.isInternalDomain(domain, config: config)
        let queryType = DNSWireFormat.extractQueryType(from: queryBytes)
        let cacheKey = DNSCacheKey(domain: domain.lowercased(), queryType: queryType)

        if let interceptIP = matchingInterceptIP(for: domain, config: config) {
            recordQuery(doh: false, cacheHit: false)
            if let synth = DNSWireFormat.synthesizeDirectResponse(originalQuery: queryBytes, ip: interceptIP) {
                logger.log(.debug, "DNS intercept: \(domain) → \(interceptIP)", category: .network)
                return synth
            }
            // Synthesis rejects queries it cannot echo faithfully (multi-question
            // packets, malformed questions). Answering SERVFAIL beats the silent
            // drop this used to be: the client learns immediately instead of
            // waiting out its resolver timeout on a domain we deliberately own.
            logger.log(
                .warning,
                "DNS: could not synthesize an intercept answer for \(domain); replying SERVFAIL.",
                category: .network
            )
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        if !isInternal, let cachedResponse = responseCache.lookup(for: cacheKey, query: queryBytes) {
            recordQuery(doh: false, cacheHit: true)
            return cachedResponse
        }

        var response: [UInt8]?
        var usedDoH = false

        if isInternal {
            response = await forwardUDP(query: queryBytes, server: primaryDNS, port: 53, timeoutMS: 2000)
        } else {
            let internalResponse = await forwardUDP(
                query: queryBytes, server: primaryDNS, port: 53, timeoutMS: 1500
            )
            if DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: internalResponse) {
                logger.log(.debug, "DNS: \(domain) not resolved internally, trying DoH.", category: .network)
                let dohResponse = await resolveViaDoH(query: queryBytes, config: config)
                if let dohResponse {
                    // DoH found an answer. Prefer it: the corporate
                    // server's NXDOMAIN was just "I don't know about
                    // this name", not authoritative.
                    response = dohResponse
                    usedDoH = true
                } else {
                    // DoH failed (no providers reachable, all timed
                    // out, blocked by a filtering proxy, or the upstream
                    // proxy is down). Fall back to whatever the corporate
                    // DNS gave us — even an NXDOMAIN is a definitive
                    // answer the client can act on. Without this, the
                    // client gets no reply at all and the browser
                    // surfaces a misleading ERR_NAME_NOT_RESOLVED /
                    // DNS-timeout. The wake/VPN-recovery
                    // `resetUpstreamTransports` path exists precisely so
                    // the *next* DoH lookup succeeds; this fallback keeps
                    // the current one useful in the meantime.
                    response = internalResponse
                }
            } else {
                response = internalResponse
            }
        }

        recordQuery(doh: usedDoH, cacheHit: false)

        guard let responseBytes = response, !responseBytes.isEmpty else {
            logger.log(.warning, "DNS: failed to resolve \(domain); replying SERVFAIL.", category: .network)
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        guard DNSWireFormat.responseQuestionMatches(query: queryBytes, response: responseBytes) else {
            // Keep this visible: a response whose question does not match the
            // query is a possible spoof, not just a failure.
            logger.log(
                .warning,
                "DNS: discarded mismatched response for \(domain); replying SERVFAIL.",
                category: .network
            )
            return DNSWireFormat.emptyServerFailureResponse(originalQuery: queryBytes)
        }

        if !isInternal {
            cacheResponse(responseBytes, for: cacheKey, matching: queryBytes)
        }

        return responseBytes
    }

    private func forwardUDP(query: [UInt8], server: String, port: Int, timeoutMS: Int) async -> [UInt8]? {
        do {
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[UInt8], Error>) in
                let handler = UDPResponseCollector(continuation: continuation)
                DatagramBootstrap(group: group)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .connect(host: server, port: port)
                    .whenComplete { result in
                        switch result {
                        case .success(let channel):
                            var buf = channel.allocator.buffer(capacity: query.count)
                            buf.writeBytes(query)
                            if let addr = try? SocketAddress(ipAddress: server, port: port) {
                                let envelope = AddressedEnvelope(remoteAddress: addr, data: buf)
                                channel.writeAndFlush(envelope, promise: nil)
                            }

                            channel.eventLoop.scheduleTask(in: .milliseconds(Int64(timeoutMS))) {
                                handler.timeout()
                                channel.close(promise: nil)
                            }
                        case .failure(let error):
                            continuation.resume(throwing: error)
                        }
                    }
            }
        } catch {
            return nil
        }
    }

    private func resolveViaDoH(query: [UInt8], config: ProxyConfig) async -> [UInt8]? {
        let qtype = DNSWireFormat.extractQueryType(from: query)
        let typeName: String
        switch qtype {
        case 1: typeName = "A"
        case 28: typeName = "AAAA"
        default:
            return DNSWireFormat.emptyRefusedResponse(originalQuery: query)
        }

        // The empty-list fallback must be the shipped default, not a literal:
        // a hardcoded hostname here is unreachable on exactly the networks
        // this fallback exists for. See `DNSSection.defaultDoHProviders`.
        let providers = config.dohProviders.isEmpty
            ? DNSSection.defaultDoHProviders
            : config.dohProviders

        let domain = DNSWireFormat.extractDomainName(from: query)
        let encodedDomain = domain.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? domain

        // Every DoH attempt that reaches a server records its HTTP status here.
        // When they all fail this is the only evidence of *why* — and the
        // distinction matters enormously: an empty set means nothing was
        // reachable, while a uniform 404/403/200-not-a-DNS-answer across every
        // provider means something answered on their behalf, i.e. a filtering
        // proxy is intercepting DoH. Without this the failure is 18 silent nils
        // and an NXDOMAIN the user cannot account for.
        let observedStatuses = NIOLockedValueBox<Set<Int>>([])

        // Snapshot the current transport handle and hold a use window open for
        // the duration of this query. A concurrent `resetUpstreamTransports`/
        // `invalidateSessions` retires the handle but must not invalidate the
        // sessions while our fetches are in flight — `data(for:)` on an
        // invalidated session aborts the process (uncatchable CFNetwork
        // NSException). The use window guarantees invalidation is deferred
        // until the task group below has fully drained. If the handle was
        // retired before we could open the window, re-read once (a reset just
        // swapped in a fresh handle); if that one is retired too, the
        // forwarder is stopping — answer nil.
        var handle = currentHandle()
        if !handle.beginUse() {
            handle = currentHandle()
            guard handle.beginUse() else { return nil }
        }
        defer { handle.endUse() }
        let sessions = handle.transports.sessions(preferProxyPath: preferProxyPathForDoH())

        // `withTaskGroup` awaits all children before returning (including
        // after the early-exit `cancelAll`), so no fetch outlives the use
        // window closed by the `defer` above.
        let answer: [UInt8]? = await withTaskGroup(of: [UInt8]?.self) { group -> [UInt8]? in
            for provider in providers {
                let dohURL = "\(provider)?name=\(encodedDomain)&type=\(typeName)"
                for session in sessions {
                    group.addTask {
                        await Self.tryDoHJSONFetch(
                            dohURL: dohURL, session: session, query: query,
                            queryType: qtype, statuses: observedStatuses
                        )
                    }
                    group.addTask {
                        await Self.tryDoHWireFetch(
                            provider: provider, session: session, query: query,
                            statuses: observedStatuses
                        )
                    }
                }
            }
            for await result in group {
                if let result {
                    group.cancelAll()
                    return result
                }
            }
            return nil
        }

        if answer == nil {
            let statuses = observedStatuses.withLockedValue { $0 }.sorted()
            if let failures = doHFailureCountToReport(signature: statuses) {
                let detail = statuses.isEmpty
                    ? "no HTTP response at all — the providers were unreachable, timed out, or their hostnames did not resolve"
                    : "every attempt answered HTTP \(statuses.map(String.init).joined(separator: "/")) instead of a DNS payload, which is what a DoH-blocking proxy looks like"
                let alsoFailed = failures > 1
                    ? " (and \(failures - 1) other name(s) since the last such warning)"
                    : ""
                logger.log(
                    .warning,
                    "DNS: all \(providers.count) DoH provider(s) failed for \(domain)\(alsoFailed) — \(detail). Public names cannot be resolved until a reachable provider is configured (IP-literal endpoints avoid both failure modes).",
                    category: .network
                )
            }
        }

        return answer
    }

    private static func tryDoHJSONFetch(
        dohURL: String,
        session: URLSession,
        query: [UInt8],
        queryType: UInt16,
        statuses: NIOLockedValueBox<Set<Int>>
    ) async -> [UInt8]? {
        guard let url = URL(string: dohURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return nil
        }
        statuses.withLockedValue { _ = $0.insert(httpResponse.statusCode) }

        guard httpResponse.statusCode == 200, !data.isEmpty else {
            return nil
        }

        let json = String(decoding: data, as: UTF8.self)
        return DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: queryType)
    }

    /// RFC 8484 wire-format DoH (POST `application/dns-message`). Some VPN /
    /// proxy paths block dns-json GET but still tunnel binary DoH through the
    /// corporate HTTP proxy.
    private static func tryDoHWireFetch(
        provider: String,
        session: URLSession,
        query: [UInt8],
        statuses: NIOLockedValueBox<Set<Int>>
    ) async -> [UInt8]? {
        guard let url = URL(string: provider) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Data(query)

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse else {
            return nil
        }
        statuses.withLockedValue { _ = $0.insert(httpResponse.statusCode) }

        guard httpResponse.statusCode == 200, data.count >= 12 else {
            return nil
        }

        let bytes = [UInt8](data)
        guard DNSWireFormat.responseQuestionMatches(query: query, response: bytes) else {
            return nil
        }
        return bytes
    }

    private func matchingInterceptIP(for domain: String, config: ProxyConfig) -> String? {
        let rules = config.enabledInterceptRules
        guard !rules.isEmpty else { return nil }
        for rule in rules where rule.matches(domain) {
            return rule.interceptIP
        }
        return nil
    }

    private func cacheResponse(_ response: [UInt8], for key: DNSCacheKey, matching query: [UInt8]) {
        guard DNSWireFormat.responseQuestionMatches(query: query, response: response) else { return }

        let ttl: TimeInterval?
        if DNSWireFormat.isNXDOMAIN(response) {
            ttl = DNSResponseCache.negativeCacheTTL
        } else if let parsedTTL = DNSWireFormat.minimumTTL(in: response), parsedTTL > 0 {
            ttl = min(TimeInterval(parsedTTL), DNSResponseCache.maximumCacheTTL)
        } else {
            ttl = nil
        }

        guard let ttl else { return }
        responseCache.store(response, for: key, ttl: ttl)
    }
}

/// UDP framing: one datagram in, one datagram out.
private final class DNSUDPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let core: DNSResolutionCore

    init(core: DNSResolutionCore) {
        self.core = core
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let clientAddress = envelope.remoteAddress
        var queryBuffer = envelope.data
        let queryBytes = queryBuffer.readBytes(length: queryBuffer.readableBytes) ?? []
        let eventLoop = context.eventLoop
        let channel = context.channel
        let core = self.core

        // Too short to carry a DNS header, so there is nothing to answer and no
        // ID to answer it with. Reject before admission, not inside `resolve`:
        // a garbage datagram must not cost an admission slot and a task spawn,
        // or a flood of them fills all 64 slots with no-op tasks and real
        // queries start getting SERVFAIL'd. TCP needs no equivalent — its
        // length-prefix framing rejects malformed input earlier still.
        guard queryBytes.count >= 12 else { return }

        // Admission first, on the event loop: a flood must be turned away
        // before it can allocate a task each. See `admitQuery()`.
        guard core.admitQuery() else {
            if let servfail = core.overLimitResponse(for: queryBytes) {
                write(servfail, to: clientAddress, on: channel)
            }
            return
        }

        Task { @Sendable in
            let response = await core.resolve(query: queryBytes)
            core.releaseQuery()
            guard let response else { return }
            eventLoop.execute {
                Self.write(response, to: clientAddress, on: channel)
            }
        }
    }

    private func write(_ response: [UInt8], to address: SocketAddress, on channel: Channel) {
        Self.write(response, to: address, on: channel)
    }

    private static func write(_ response: [UInt8], to address: SocketAddress, on channel: Channel) {
        var buf = channel.allocator.buffer(capacity: response.count)
        buf.writeBytes(response)
        channel.writeAndFlush(AddressedEnvelope(remoteAddress: address, data: buf), promise: nil)
    }
}

/// The set of accepted DNS-over-TCP connections, bounded and closable.
///
/// It exists for two reasons a `ServerBootstrap` channel alone cannot cover:
///
/// - **A cap.** Every accepted connection costs an accumulation buffer (up to
///   `DNSTCPHandler.maximumMessageBytes`), a scheduled timer and a descriptor,
///   held for the whole idle window even if the client never sends a byte. UDP
///   has no equivalent exposure because a datagram leaves no per-peer state.
///   The in-flight resolution cap bounds concurrent *lookups*, not sockets.
/// - **Shutdown reach.** Closing the listener stops accepts; it does not close
///   the children, and each child keeps the resolution core alive.
private final class DNSTCPConnectionRegistry: @unchecked Sendable {
    /// A resolver client opens a connection, asks, and goes away, so the steady
    /// state is a handful. This is generous for legitimate use and still bounds
    /// what an abusive local client can pin.
    static let defaultMaximumConnections = 64

    /// A connection flood must not become a log flood: refusals are reported at
    /// most this often, and the message carries the count since the last one.
    private static let rejectionReportInterval: TimeInterval = 5

    private let maximumConnections: Int
    private let logger: any LogSink
    private let lock = NSLock()
    private var openChannels: [ObjectIdentifier: Channel] = [:]
    private var shuttingDown = false
    private var refusedSinceLastReport = 0
    private var lastRejectionReport: Date?

    init(maximumConnections: Int, logger: any LogSink) {
        self.maximumConnections = maximumConnections
        self.logger = logger
    }

    /// Records an accepted connection. Returns false when the cap is reached or
    /// the forwarder is shutting down — the caller must close the channel.
    func admit(_ channel: Channel) -> Bool {
        let decision: (admitted: Bool, refused: Int?, shuttingDown: Bool) = lock.withLock {
            guard !shuttingDown, openChannels.count < maximumConnections else {
                refusedSinceLastReport += 1
                return (false, refusalCountToReport(), shuttingDown)
            }
            openChannels[ObjectIdentifier(channel)] = channel
            return (true, nil, false)
        }

        if decision.admitted { return true }
        if let refused = decision.refused {
            if decision.shuttingDown {
                logger.log(
                    .debug,
                    "DNS TCP: refused \(refused) connection(s) — the forwarder is shutting down.",
                    category: .network
                )
            } else {
                logger.log(
                    .warning,
                    "DNS TCP: refused \(refused) connection(s); the \(maximumConnections)-connection cap is already reached. A client holding sockets open without querying can cause this.",
                    category: .network
                )
            }
        }
        return false
    }

    /// Refusals accumulated since the last report, or nil while still inside the
    /// reporting interval. Caller holds the lock.
    private func refusalCountToReport() -> Int? {
        let now = Date.now
        if let lastRejectionReport, now.timeIntervalSince(lastRejectionReport) < Self.rejectionReportInterval {
            return nil
        }
        lastRejectionReport = now
        let refused = refusedSinceLastReport
        refusedSinceLastReport = 0
        return refused
    }

    func release(_ channel: Channel) {
        lock.withLock { _ = openChannels.removeValue(forKey: ObjectIdentifier(channel)) }
    }

    /// Closes every accepted connection and refuses later ones. Called from
    /// `LocalDNSForwarder.stop()` after the listener is down.
    func closeAll() async {
        let open: [Channel] = lock.withLock {
            shuttingDown = true
            let values = Array(openChannels.values)
            openChannels.removeAll()
            return values
        }
        for channel in open {
            _ = try? await channel.close().get()
        }
    }
}

/// TCP framing per RFC 1035 §4.2.2: every message, in both directions, is
/// preceded by its length as a 2-byte big-endian integer. One connection may
/// carry several queries back to back, so reads are accumulated and drained
/// message by message rather than assumed to arrive one per `channelRead`.
private final class DNSTCPHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// The length prefix permits 64 KiB, but a query is one question plus a few
    /// EDNS options and never approaches that. The cap is what stops a client
    /// from making us buffer 64 KiB per connection by announcing a length it
    /// then dribbles out or never sends.
    static let maximumMessageBytes = 4096

    /// A resolver client sends its query immediately on connect. A connection
    /// still silent after this — with nothing outstanding — has gone away or is
    /// holding a socket for no reason.
    ///
    /// Enforced by our own timer rather than `IdleStateHandler` for two
    /// reasons: that type's `Sendable` conformance is unavailable, so adding it
    /// to a pipeline from a `@Sendable` initializer warns; and it measures only
    /// inbound silence, which for DNS-over-TCP is indistinguishable between "the
    /// client is gone" and "the client asked a question and is waiting". Only
    /// the handler knows which, so the handler owns the timer.
    static let defaultIdleTimeoutSeconds: Int64 = 10

    private let core: DNSResolutionCore
    private let logger: any LogSink
    private let idleTimeoutSeconds: Int64
    private var pending: ByteBuffer?

    /// Lookups spawned from this connection that have not written yet.
    /// Event-loop confined: incremented in `respond` (reached from
    /// `channelRead`) and decremented in the write hop, both on the loop.
    private var outstandingQueries = 0
    private var idleTask: Scheduled<Void>?

    init(core: DNSResolutionCore, logger: any LogSink, idleTimeoutSeconds: Int64) {
        self.core = core
        self.logger = logger
        self.idleTimeoutSeconds = idleTimeoutSeconds
    }

    func handlerAdded(context: ChannelHandlerContext) {
        armIdleTimer(on: context.eventLoop, channel: context.channel)
    }

    func handlerRemoved(context: ChannelHandlerContext) {
        idleTask?.cancel()
        idleTask = nil
    }

    /// (Re)starts the silence countdown. Rearmed on every read and every
    /// answer written, so the window measures time since the last thing that
    /// happened on this connection.
    private func armIdleTimer(on loop: EventLoop, channel: Channel) {
        idleTask?.cancel()
        idleTask = loop.scheduleTask(in: .seconds(idleTimeoutSeconds)) { [weak self] in
            guard let self else { return }
            // A client waiting on an answer is legitimately silent. A worst-case
            // resolution (1.5 s internal attempt, then a DoH race bounded by the
            // 4 s / 8 s session timeouts) runs right up against this window, so
            // closing here would discard the answer mid-flight and hand the
            // client the exact silence this forwarder exists to avoid.
            guard self.outstandingQueries == 0 else {
                self.armIdleTimer(on: loop, channel: channel)
                return
            }
            channel.close(promise: nil)
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        armIdleTimer(on: context.eventLoop, channel: context.channel)
        var incoming = unwrapInboundIn(data)
        if pending == nil {
            pending = incoming
        } else {
            pending?.writeBuffer(&incoming)
        }
        drain(context: context)
    }

    /// Peels off every complete message currently buffered. Returns as soon as
    /// the buffer holds only a partial one — the next read resumes here.
    private func drain(context: ChannelHandlerContext) {
        while var buffer = pending {
            guard let length = buffer.getInteger(at: buffer.readerIndex, as: UInt16.self) else { return }

            guard Int(length) <= Self.maximumMessageBytes else {
                logger.log(
                    .warning,
                    "DNS TCP: announced message length \(length) exceeds the \(Self.maximumMessageBytes)-byte cap; closing the connection.",
                    category: .network
                )
                pending = nil
                context.close(promise: nil)
                return
            }

            guard buffer.readableBytes >= 2 + Int(length) else { return }
            buffer.moveReaderIndex(forwardBy: 2)
            let queryBytes = buffer.readBytes(length: Int(length)) ?? []
            pending = buffer.readableBytes > 0 ? buffer : nil
            respond(to: queryBytes, context: context)
        }
    }

    private func respond(to queryBytes: [UInt8], context: ChannelHandlerContext) {
        let eventLoop = context.eventLoop
        let channel = context.channel
        let core = self.core
        let logger = self.logger

        // Admission first, on the event loop. See `DNSResolutionCore.admitQuery()`.
        guard core.admitQuery() else {
            if let servfail = core.overLimitResponse(for: queryBytes) {
                Self.write(servfail, on: channel, logger: logger)
            }
            return
        }

        outstandingQueries += 1
        Task { @Sendable in
            let response = await core.resolve(query: queryBytes)
            core.releaseQuery()
            eventLoop.execute { [weak self] in
                self?.outstandingQueries -= 1
                self?.armIdleTimer(on: eventLoop, channel: channel)
                guard let response else { return }
                Self.write(response, on: channel, logger: logger)
            }
        }
    }

    private static func write(_ response: [UInt8], on channel: Channel, logger: any LogSink) {
        guard response.count <= Int(UInt16.max) else {
            logger.log(
                .warning,
                "DNS TCP: response of \(response.count) bytes exceeds the wire framing limit; dropping it.",
                category: .network
            )
            return
        }
        var out = channel.allocator.buffer(capacity: response.count + 2)
        out.writeInteger(UInt16(response.count))
        out.writeBytes(response)
        channel.writeAndFlush(out, promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        // Never close silently: this is the only trace an operator gets when a
        // DNS-over-TCP connection fails (AGENTS.md, "never swallow an error").
        logger.log(
            .warning,
            "DNS TCP: connection error, closing: \(error.displayDescription)",
            category: .network
        )
        context.close(promise: nil)
    }
}

private struct DNSCacheKey: Hashable {
    let domain: String
    let queryType: UInt16
}

private struct DNSCacheEntry {
    let response: [UInt8]
    let expiresAt: Date
    var lastAccess: Date
}

private final class DNSResponseCache: @unchecked Sendable {
    static let maximumEntries = 2_048
    static let maximumCacheTTL: TimeInterval = 300
    static let negativeCacheTTL: TimeInterval = 30

    private let lock = NSLock()
    private var entries: [DNSCacheKey: DNSCacheEntry] = [:]

    func lookup(for key: DNSCacheKey, query: [UInt8]) -> [UInt8]? {
        lock.withLock {
            let now = Date.now
            purgeExpiredEntries(now: now)
            guard var entry = entries[key], entry.expiresAt > now else {
                entries.removeValue(forKey: key)
                return nil
            }
            entry.lastAccess = now
            entries[key] = entry
            return DNSWireFormat.responseByUpdatingTransactionID(entry.response, from: query)
        }
    }

    func store(_ response: [UInt8], for key: DNSCacheKey, ttl: TimeInterval) {
        guard ttl > 0 else { return }
        let now = Date()
        let expiresAt = now.addingTimeInterval(ttl)
        lock.withLock {
            entries[key] = DNSCacheEntry(response: response, expiresAt: expiresAt, lastAccess: now)
            evictIfNeeded(now: now)
        }
    }

    func clear() {
        lock.withLock { entries.removeAll(keepingCapacity: false) }
    }

    var entryCount: Int {
        lock.withLock { entries.count }
    }

    private func purgeExpiredEntries(now: Date) {
        entries = entries.filter { $0.value.expiresAt > now }
    }

    private func evictIfNeeded(now: Date) {
        purgeExpiredEntries(now: now)
        while entries.count > Self.maximumEntries {
            guard let oldest = entries.min(by: { $0.value.lastAccess < $1.value.lastAccess })?.key else { break }
            entries.removeValue(forKey: oldest)
        }
    }
}

private final class UDPResponseCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>

    private var continuation: CheckedContinuation<[UInt8], Error>?
    private let lock = NSLock()

    init(continuation: CheckedContinuation<[UInt8], Error>) {
        self.continuation = continuation
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        var buf = envelope.data
        let bytes = buf.readBytes(length: buf.readableBytes) ?? []
        complete(with: bytes)
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(with: error)
        context.close(promise: nil)
    }

    func timeout() {
        fail(with: DNSForwarderError.timeout)
    }

    private func complete(with bytes: [UInt8]) {
        lock.withLock {
            continuation?.resume(returning: bytes)
            continuation = nil
        }
    }

    private func fail(with error: Error) {
        lock.withLock {
            continuation?.resume(throwing: error)
            continuation = nil
        }
    }
}

private enum DNSForwarderError: Error {
    case timeout
}
