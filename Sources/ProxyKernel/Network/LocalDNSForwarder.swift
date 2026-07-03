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
    private var channel: Channel?
    private var handler: DNSForwardingHandler?

    package var listeningHost: String? {
        channel?.localAddress?.ipAddress
    }

    package var listeningPort: Int? {
        channel?.localAddress?.port
    }

    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        configProvider: @escaping () -> ProxyConfig,
        preferProxyPathForDoH: @escaping @Sendable () -> Bool = { false },
        onMetrics: (@Sendable (Int, Int, Int) -> Void)? = nil
    ) {
        self.group = group
        self.logger = logger
        self.configProvider = configProvider
        self.preferProxyPathForDoH = preferProxyPathForDoH
        self.onMetrics = onMetrics
    }

    package func start(host: String, port: Int) async throws {
        let h = DNSForwardingHandler(
            group: group,
            logger: logger,
            configProvider: configProvider,
            preferProxyPathForDoH: preferProxyPathForDoH,
            onMetrics: onMetrics
        )
        self.handler = h
        let bootstrap = DatagramBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .channelInitializer { channel in
                channel.pipeline.addHandler(h)
            }
        channel = try await bootstrap.bind(host: host, port: port).get()
        let actualHost = channel?.localAddress?.ipAddress ?? host
        let actualPort = channel?.localAddress?.port ?? port
        logger.log(.notice, "DNS forwarder listening on \(actualHost):\(actualPort).", category: .network)
    }

    package func stop() async {
        if let channel {
            _ = try? await channel.close().get()
        }
        channel = nil
        handler?.invalidateSessions()
        handler = nil
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
        guard let handler else {
            logger.log(.debug, "DNS forwarder transports reset skipped (forwarder not running). reason=\(reason)", category: .network)
            return
        }
        handler.resetUpstreamTransports()
        logger.log(.notice, "DNS forwarder transports reset (reason=\(reason)).", category: .network)
    }

    /// Number of cached DNS response entries. Test-only accessor — production
    /// code must not depend on the absolute count (the cache is allowed to
    /// evict opportunistically). Used to verify `resetUpstreamTransports`
    /// flushes the cache.
    package var cachedResponseCount: Int {
        handler?.cachedResponseCount ?? 0
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
        let directConfig = URLSessionConfiguration.ephemeral
        directConfig.timeoutIntervalForRequest = 4
        directConfig.timeoutIntervalForResource = 8
        directConfig.connectionProxyDictionary = [:]
        self.direct = URLSession(configuration: directConfig)

        if let upstream = config.enabledUpstreams.first {
            let proxyConfig = URLSessionConfiguration.ephemeral
            proxyConfig.timeoutIntervalForRequest = 4
            proxyConfig.timeoutIntervalForResource = 8
            proxyConfig.connectionProxyDictionary = Self.proxyDictionary(host: upstream.host, port: upstream.port)
            self.upstream = URLSession(configuration: proxyConfig)
        } else {
            self.upstream = nil
        }

        let localConfig = URLSessionConfiguration.ephemeral
        localConfig.timeoutIntervalForRequest = 4
        localConfig.timeoutIntervalForResource = 8
        localConfig.connectionProxyDictionary = Self.proxyDictionary(host: config.localHost, port: config.localPort)
        self.localProxy = URLSession(configuration: localConfig)
    }

    private static func proxyDictionary(host: String, port: Int) -> [String: Any] {
        [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: host,
            kCFNetworkProxiesHTTPPort as String: port,
            kCFProxyTypeHTTPS as String: true,
            "HTTPSProxy" as String: host,
            "HTTPSPort" as String: port,
        ]
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

private final class DNSForwardingHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = AddressedEnvelope<ByteBuffer>
    typealias OutboundOut = AddressedEnvelope<ByteBuffer>

    private let group: EventLoopGroup
    private let logger: any LogSink
    private let configProvider: () -> ProxyConfig
    private let preferProxyPathForDoH: @Sendable () -> Bool
    private let onMetrics: (@Sendable (Int, Int, Int) -> Void)?
    private let lock = NSLock()
    private var queryCount = 0
    private var dohCount = 0
    private var cacheHitCount = 0
    private let concurrencyLimit = DispatchSemaphore(value: 64)
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

    private func recordQuery(doh: Bool, cacheHit: Bool) {
        let (q, d, c) = lock.withLock {
            queryCount += 1
            if doh { dohCount += 1 }
            if cacheHit { cacheHitCount += 1 }
            return (queryCount, dohCount, cacheHitCount)
        }
        onMetrics?(q, d, c)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let envelope = unwrapInboundIn(data)
        let clientAddress = envelope.remoteAddress
        var queryBuffer = envelope.data
        let queryBytes = queryBuffer.readBytes(length: queryBuffer.readableBytes) ?? []
        guard queryBytes.count >= 12 else { return }

        let domain = DNSWireFormat.extractDomainName(from: queryBytes)
        let config = configProvider()
        let internalServers = config.dnsEntries.filter(\.enabled).flatMap(\.servers)
        let primaryDNS = internalServers.first ?? "192.0.2.53"
        let isInternal = DNSWireFormat.isInternalDomain(domain, config: config)
        let queryType = DNSWireFormat.extractQueryType(from: queryBytes)
        let cacheKey = DNSCacheKey(domain: domain.lowercased(), queryType: queryType)
        let eventLoop = context.eventLoop
        let channel = context.channel

        if let interceptIP = matchingInterceptIP(for: domain, config: config) {
            if let synth = DNSWireFormat.synthesizeDirectResponse(originalQuery: queryBytes, ip: interceptIP) {
                recordQuery(doh: false, cacheHit: false)
                logger.log(.debug, "DNS intercept: \(domain) → \(interceptIP)", category: .network)
                eventLoop.execute {
                    var buf = channel.allocator.buffer(capacity: synth.count)
                    buf.writeBytes(synth)
                    let reply = AddressedEnvelope(remoteAddress: clientAddress, data: buf)
                    channel.writeAndFlush(reply, promise: nil)
                }
            }
            return
        }

        if !isInternal, let cachedResponse = responseCache.lookup(for: cacheKey, query: queryBytes) {
            recordQuery(doh: false, cacheHit: true)
            eventLoop.execute {
                var buf = channel.allocator.buffer(capacity: cachedResponse.count)
                buf.writeBytes(cachedResponse)
                let reply = AddressedEnvelope(remoteAddress: clientAddress, data: buf)
                channel.writeAndFlush(reply, promise: nil)
            }
            return
        }

        let forwarder = self
        guard concurrencyLimit.wait(timeout: .now()) == .success else {
            logger.log(.warning, "DNS: query limit reached, dropping query for \(domain).", category: .network)
            return
        }
        Task { @Sendable in
            defer { forwarder.concurrencyLimit.signal() }
            var response: [UInt8]?
            var usedDoH = false

            if isInternal {
                response = await forwarder.forwardUDP(query: queryBytes, server: primaryDNS, port: 53, timeoutMS: 2000)
            } else {
                let internalResponse = await forwarder.forwardUDP(
                    query: queryBytes, server: primaryDNS, port: 53, timeoutMS: 1500
                )
                if DNSWireFormat.shouldFallbackToPublicDoH(internalResponse: internalResponse) {
                    forwarder.logger.log(.debug, "DNS: \(domain) not resolved internally, trying DoH.", category: .network)
                    let dohResponse = await forwarder.resolveViaDoH(query: queryBytes, config: config)
                    if let dohResponse {
                        // DoH found an answer. Prefer it: the corporate
                        // server's NXDOMAIN was just "I don't know about
                        // this name", not authoritative.
                        response = dohResponse
                        usedDoH = true
                    } else {
                        // DoH failed (no providers reachable, all timed
                        // out, or the upstream proxy is down). Fall back
                        // to whatever the corporate DNS gave us — even an
                        // NXDOMAIN is a definitive answer the client can
                        // act on. Without this, the client gets no reply
                        // at all and the browser surfaces a misleading
                        // ERR_NAME_NOT_RESOLVED / DNS-timeout. The wake/
                        // VPN-recovery `resetUpstreamTransports` path
                        // exists precisely so the *next* DoH lookup
                        // succeeds; this fallback keeps the current one
                        // useful in the meantime.
                        response = internalResponse
                    }
                } else {
                    response = internalResponse
                }
            }

            forwarder.recordQuery(doh: usedDoH, cacheHit: false)

            guard let responseBytes = response, !responseBytes.isEmpty else {
                forwarder.logger.log(.warning, "DNS: failed to resolve \(domain).", category: .network)
                return
            }

            guard DNSWireFormat.responseQuestionMatches(query: queryBytes, response: responseBytes) else {
                forwarder.logger.log(
                    .warning,
                    "DNS: discarded mismatched response for \(domain).",
                    category: .network
                )
                return
            }

            if !isInternal {
                forwarder.cacheResponse(responseBytes, for: cacheKey, matching: queryBytes)
            }

            eventLoop.execute {
                var buf = channel.allocator.buffer(capacity: responseBytes.count)
                buf.writeBytes(responseBytes)
                let reply = AddressedEnvelope(remoteAddress: clientAddress, data: buf)
                channel.writeAndFlush(reply, promise: nil)
            }
        }
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

        let providers = config.dohProviders.isEmpty
            ? ["https://cloudflare-dns.com/dns-query"]
            : config.dohProviders

        let domain = DNSWireFormat.extractDomainName(from: query)
            .addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? DNSWireFormat.extractDomainName(from: query)

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
        return await withTaskGroup(of: [UInt8]?.self) { group in
            for provider in providers {
                let dohURL = "\(provider)?name=\(domain)&type=\(typeName)"
                for session in sessions {
                    group.addTask {
                        await Self.tryDoHJSONFetch(dohURL: dohURL, session: session, query: query, queryType: qtype)
                    }
                    group.addTask {
                        await Self.tryDoHWireFetch(provider: provider, session: session, query: query)
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
    }

    private static func tryDoHJSONFetch(dohURL: String, session: URLSession, query: [UInt8], queryType: UInt16) async -> [UInt8]? {
        guard let url = URL(string: dohURL) else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/dns-json", forHTTPHeaderField: "Accept")

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              !data.isEmpty else {
            return nil
        }

        let json = String(decoding: data, as: UTF8.self)
        return DNSWireFormat.synthesizeDNSResponse(originalQuery: query, jsonResponse: json, queryType: queryType)
    }

    /// RFC 8484 wire-format DoH (POST `application/dns-message`). Some VPN /
    /// proxy paths block dns-json GET but still tunnel binary DoH through the
    /// corporate HTTP proxy.
    private static func tryDoHWireFetch(provider: String, session: URLSession, query: [UInt8]) async -> [UInt8]? {
        guard let url = URL(string: provider) else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/dns-message", forHTTPHeaderField: "Content-Type")
        request.setValue("application/dns-message", forHTTPHeaderField: "Accept")
        request.httpBody = Data(query)

        guard let (data, response) = try? await session.data(for: request),
              let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200,
              data.count >= 12 else {
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
