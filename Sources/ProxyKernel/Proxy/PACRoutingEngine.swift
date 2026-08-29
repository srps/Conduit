// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

package final class PACRoutingEngine: @unchecked Sendable {
    private struct RouteCacheEntry {
        let routes: [PACRoute]
        let expiresAt: Date
    }

    private static let routeCacheTTL: TimeInterval = 60
    private static let routeCacheLimit = 512

    private let configProvider: () -> ProxyConfig
    private let resolver: any PacEvaluator
    private let logger: (any LogSink)?
    private let refreshInterval: TimeInterval
    private let pacLoader: @Sendable (String) async throws -> String
    private let lock = NSLock()
    private let jsQueue = DispatchQueue(label: "io.github.srps.Conduit.PACEval")
    private let evalTimeoutSeconds: TimeInterval
    private let slowEvalThresholdSeconds: Double = 0.5

    private var cachedPACURL = ""
    private var jsEvaluator: (any PacScriptEvaluating)?
    private var lastRefreshAt: Date?
    private var refreshInFlight = false
    private var routeCache: [String: RouteCacheEntry] = [:]
    private var routeCacheOrder: [String] = []
    /// Requests waiting on an evaluation already running for the same cache
    /// key. proxy.log showed six identical "PAC evaluation took 1049ms"
    /// lines with the same millisecond timestamp: a burst of connections
    /// to one host each ran the script, serially on `jsQueue`, when one
    /// result would have served all of them.
    private var pendingEvaluations: [String: [EventLoopPromise<[PACRoute]>]] = [:]
    /// Waiters a single evaluation may hold. Past it, a request is answered
    /// with no routes at once — the same answer a timed-out evaluation gives —
    /// rather than letting one stalled script queue promises without bound.
    package static let pendingWaiterLimit = 256
    /// Evaluations that may be queued on the serial evaluator at once, across
    /// all keys. A stalled script otherwise lets a stream of unique URLs queue
    /// closures without bound — each times out for its caller but stays on
    /// the queue. Past the limit a request is answered without routes.
    private let queuedEvaluationLimit: Int
    private var queuedEvaluations = 0
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?

    // The pre-split concrete resolver default was
    // removed — the kernel can no longer construct the concrete resolver.
    // Callers (AppState, pm-proxy, tests) inject a `PacEvaluator`; `ProxyPAC`
    // ships the production impl (`CFPACEvaluator`).
    package init(
        configProvider: @escaping () -> ProxyConfig,
        resolver: any PacEvaluator,
        logger: (any LogSink)? = nil,
        refreshInterval: TimeInterval = 300,
        evalTimeoutSeconds: TimeInterval = 5,
        pacLoader: (@Sendable (String) async throws -> String)? = nil,
        queuedEvaluationLimit: Int = 64,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.configProvider = configProvider
        self.resolver = resolver
        self.logger = logger
        self.queuedEvaluationLimit = queuedEvaluationLimit
        self.eventSink = eventSink
        self.refreshInterval = refreshInterval
        self.evalTimeoutSeconds = evalTimeoutSeconds
        self.pacLoader = pacLoader ?? { url in
            try await resolver.fetchPAC(from: url)
        }
    }

    package func refresh(force: Bool = false) async throws {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty else {
            clearCachedEvaluator()
            return
        }

        let shouldRefresh = lock.withLock {
            force || jsEvaluator == nil || cachedPACURL != config.pacURL || refreshExpired(at: lastRefreshAt)
        }

        guard shouldRefresh else { return }

        markRefreshInFlight(true)
        defer { markRefreshInFlight(false) }

        do {
            let pacScript = try await pacLoader(config.pacURL)
            let resolver = self.resolver
            let timeout = evalTimeoutSeconds
            let newEvaluator: any PacScriptEvaluating = try {
                nonisolated(unsafe) var result: Result<any PacScriptEvaluating, Error>?
                let semaphore = DispatchSemaphore(value: 0)
                jsQueue.async {
                    result = Result { try resolver.makeEvaluator(pacScript: pacScript) }
                    semaphore.signal()
                }
                if semaphore.wait(timeout: .now() + timeout) == .timedOut {
                    throw PACResolverError.evaluationFailed("PAC script evaluation timed out after \(Int(timeout))s")
                }
                return try result!.get()
            }()
            lock.withLock {
                cachedPACURL = config.pacURL
                jsEvaluator = newEvaluator
                lastRefreshAt = .now
                routeCache.removeAll()
                routeCacheOrder.removeAll()
            }
            logger?.log(.info, "Refreshed PAC routing rules from \(Self.redactedURL(config.pacURL)).", category: .pac)
        } catch {
            logger?.log(.warning, "PAC refresh failed: \(error.displayDescription)", category: .pac)
            throw error
        }
    }

    package func routeChain(for url: String, host: String) -> [PACRoute] {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty, let requestURL = URL(string: url) else {
            return []
        }

        refreshInBackgroundIfNeeded(for: config)

        let cacheKey = Self.routeCacheKey(for: requestURL, host: host)
        if let cached = cachedRoutes(forKey: cacheKey) {
            return cached
        }

        let evaluator = lock.withLock { jsEvaluator }
        guard let evaluator else { return [] }

        let start = CFAbsoluteTimeGetCurrent()
        nonisolated(unsafe) var rawChain: [String]?
        let evalTimeout: DispatchTime = .now() + 2.0
        let semaphore = DispatchSemaphore(value: 0)
        jsQueue.async {
            rawChain = try? evaluator.resolveProxyChain(for: requestURL)
            semaphore.signal()
        }
        if semaphore.wait(timeout: evalTimeout) == .timedOut {
            logger?.log(.warning, "PAC evaluation timed out (2s) for \(host)", category: .pac)
            return []
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed > slowEvalThresholdSeconds {
            logger?.log(.warning, "PAC evaluation took \(Int(elapsed * 1000))ms for \(host)", category: .pac)
        }

        guard let rawChain else { return [] }

        let routes = resolver.routeChain(for: rawChain)
        storeCachedRoutes(routes, forKey: cacheKey)
        if let first = routes.first {
            logger?.log(.debug, "PAC route for \(host): \(first) (chain entries: \(rawChain.count))", category: .pac)
        }
        return routes
    }

    package func routeChainFuture(for url: String, host: String, on eventLoop: EventLoop) -> EventLoopFuture<[PACRoute]> {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty, let requestURL = URL(string: url) else {
            return eventLoop.makeSucceededFuture([])
        }

        refreshInBackgroundIfNeeded(for: config)

        let cacheKey = Self.routeCacheKey(for: requestURL, host: host)
        if let cached = cachedRoutes(forKey: cacheKey) {
            return eventLoop.makeSucceededFuture(cached)
        }

        let evaluator = lock.withLock { jsEvaluator }
        guard let evaluator else {
            return eventLoop.makeSucceededFuture([])
        }

        let promise = eventLoop.makePromise(of: [PACRoute].self)
        enum Admission { case leader, waiter, refused(reason: String, limit: Int) }
        let admission = lock.withLock { () -> Admission in
            guard let waiters = pendingEvaluations[cacheKey] else {
                guard queuedEvaluations < queuedEvaluationLimit else {
                    return .refused(reason: "queue_full", limit: queuedEvaluationLimit)
                }
                queuedEvaluations += 1
                pendingEvaluations[cacheKey] = []
                return .leader
            }
            guard waiters.count < Self.pendingWaiterLimit else {
                return .refused(reason: "waiters_full", limit: Self.pendingWaiterLimit)
            }
            pendingEvaluations[cacheKey]!.append(promise)
            return .waiter
        }
        switch admission {
        case .waiter:
            return promise.futureResult
        case .refused(let reason, let limit):
            // Event first: fail-closed routing under overload must be
            // distinguishable from an ordinary empty PAC answer.
            eventSink?(RuntimeEvent(
                kind: .routing,
                event: "pac.evaluation_refused",
                detail: "host=\(host) reason=\(reason) limit=\(limit)"
            ))
            logger?.log(.warning, "PAC evaluation for \(host) refused (\(reason), limit \(limit)); answering without routes.", category: .pac)
            promise.succeed([])
            return promise.futureResult
        case .leader:
            break
        }

        let completion = PACRouteEvaluationCompletion()
        let start = CFAbsoluteTimeGetCurrent()
        let timeout = evalTimeoutSeconds
        let resolver = self.resolver
        let logger = self.logger
        let slowEvalThresholdSeconds = self.slowEvalThresholdSeconds
        let requestURLForEval = requestURL

        // Leader's result (or timeout) settles every request that queued
        // behind it. Promises are fulfilled on their own loops.
        let finish: @Sendable ([PACRoute]) -> Void = { routes in
            let waiters = self.lock.withLock { self.pendingEvaluations.removeValue(forKey: cacheKey) ?? [] }
            for waiter in [promise] + waiters {
                waiter.futureResult.eventLoop.execute { waiter.succeed(routes) }
            }
        }

        jsQueue.async {
            let result = Result { try evaluator.resolveProxyChain(for: requestURLForEval) }
            self.lock.withLock { self.queuedEvaluations -= 1 }
            completion.complete {
                switch result {
                case .success(let rawChain):
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    let routes = resolver.routeChain(for: rawChain)
                    self.storeCachedRoutes(routes, forKey: cacheKey)
                    if elapsed > slowEvalThresholdSeconds {
                        logger?.log(.warning, "PAC evaluation took \(Int(elapsed * 1000))ms for \(host)", category: .pac)
                    }
                    if let first = routes.first {
                        logger?.log(.debug, "PAC route for \(host): \(first) (chain entries: \(rawChain.count))", category: .pac)
                    }
                    finish(routes)
                case .failure:
                    finish([])
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            completion.complete {
                logger?.log(.warning, "PAC evaluation timed out (\(Int(timeout))s) for \(host)", category: .pac)
                finish([])
            }
        }

        return promise.futureResult
    }

    package func route(for url: String, host: String) -> PACRoute? {
        routeChain(for: url, host: host).first
    }

    package func shouldBypass(url: String, host: String) -> Bool {
        if case .direct = route(for: url, host: host) {
            return true
        }
        return false
    }

    private func refreshInBackgroundIfNeeded(for config: ProxyConfig) {
        let shouldKickOff = lock.withLock {
            guard !refreshInFlight else { return false }
            let needsRefresh = jsEvaluator == nil || cachedPACURL != config.pacURL || refreshExpired(at: lastRefreshAt)
            if needsRefresh {
                refreshInFlight = true
            }
            return needsRefresh
        }

        guard shouldKickOff else { return }

        Task {
            try? await refresh()
        }
    }

    private func refreshExpired(at date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) >= refreshInterval
    }

    private func clearCachedEvaluator() {
        lock.withLock {
            cachedPACURL = ""
            jsEvaluator = nil
            lastRefreshAt = nil
            refreshInFlight = false
            routeCache.removeAll()
            routeCacheOrder.removeAll()
        }
    }

    private func markRefreshInFlight(_ inFlight: Bool) {
        lock.withLock {
            refreshInFlight = inFlight
        }
    }

    private func cachedRoutes(forKey key: String) -> [PACRoute]? {
        lock.withLock {
            purgeExpiredRouteCacheEntriesLocked(now: .now)
            guard let entry = routeCache[key], entry.expiresAt > .now else {
                routeCache.removeValue(forKey: key)
                routeCacheOrder.removeAll { $0 == key }
                return nil
            }
            touchRouteCacheKeyLocked(key)
            return entry.routes
        }
    }

    private func storeCachedRoutes(_ routes: [PACRoute], forKey key: String) {
        lock.withLock {
            routeCache[key] = RouteCacheEntry(
                routes: routes,
                expiresAt: Date().addingTimeInterval(Self.routeCacheTTL)
            )
            touchRouteCacheKeyLocked(key)
            evictRouteCacheIfNeededLocked(now: .now)
        }
    }

    private func touchRouteCacheKeyLocked(_ key: String) {
        routeCacheOrder.removeAll { $0 == key }
        routeCacheOrder.append(key)
    }

    private func purgeExpiredRouteCacheEntriesLocked(now: Date) {
        let expiredKeys = routeCache.compactMap { key, entry in
            entry.expiresAt <= now ? key : nil
        }
        guard !expiredKeys.isEmpty else { return }
        let expiredSet = Set(expiredKeys)
        for key in expiredKeys {
            routeCache.removeValue(forKey: key)
        }
        routeCacheOrder.removeAll { expiredSet.contains($0) }
    }

    private func evictRouteCacheIfNeededLocked(now: Date) {
        purgeExpiredRouteCacheEntriesLocked(now: now)
        while routeCache.count > Self.routeCacheLimit, let oldest = routeCacheOrder.first {
            routeCacheOrder.removeFirst()
            routeCache.removeValue(forKey: oldest)
        }
    }

    private static func routeCacheKey(for url: URL, host: String) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(host.lowercased()):\(url.port ?? defaultPort(for: url.scheme))\(url.path)?\(url.query ?? "")"
        }
        let scheme = components.scheme?.lowercased()
        components.scheme = scheme
        components.host = (components.host ?? host).lowercased()
        if components.port == nil {
            components.port = defaultPort(for: scheme)
        }
        return components.string ?? "\(host.lowercased()):\(url.port ?? defaultPort(for: url.scheme))\(url.path)?\(url.query ?? "")"
    }

    private static func defaultPort(for scheme: String?) -> Int {
        switch scheme?.lowercased() {
        case "http":
            return 80
        case "https":
            return 443
        default:
            return 0
        }
    }

    private static func redactedURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return "<invalid-url>" }
        components.user = nil
        components.password = nil
        if components.query != nil {
            components.query = "redacted"
        }
        components.fragment = nil
        return components.string ?? "<redacted-url>"
    }
}

private final class PACRouteEvaluationCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var completed = false

    func complete(_ body: () -> Void) {
        let shouldRun = lock.withLock { () -> Bool in
            guard !completed else { return false }
            completed = true
            return true
        }
        guard shouldRun else { return }
        body()
    }
}
