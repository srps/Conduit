// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

/// Why the engine dropped its answers; the `reason=` of `pac.routes_invalidated`.
package enum PACRouteInvalidationReason: String, Sendable {
    /// A VPN came up: cold-start priming or a reconnect after an outage.
    case vpnConnected = "vpn_connected"
    /// A VPN went down for good (not a flap).
    case vpnDisconnected = "vpn_disconnected"
}

package final class PACRoutingEngine: @unchecked Sendable {
    /// A parsed answer, including one with no usable routes: the script's
    /// answer is deterministic for the key, so it is cached like any other.
    /// Failures (timeout, error, refusal) are not cached.
    private struct RouteCacheEntry {
        let chain: PACChain
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
    /// URL of the last fetch started. The backoff is per URL.
    private var lastAttemptedPACURL = ""
    private var jsEvaluator: (any PacScriptEvaluating)?
    private var lastRefreshAt: Date?
    /// The refresh running now, if any: one at a time, and later callers
    /// wait for it. It clears itself in the same critical section that
    /// installs its script or records its failure, so an invalidation after
    /// that point finds no refresh running and the next one fetches afresh.
    private var runningRefresh: PACRefreshOperation?
    /// Failure backoff state; see `refresh(force:honorBackoff:)`.
    private var consecutiveFailures = 0
    private var lastFailureAt: Date?
    package static let backoffBase: TimeInterval = 30
    package static let backoffCap: TimeInterval = 600

    private enum RefreshDecision {
        case run(PACRefreshOperation)
        case fresh
        case alreadyRunning(PACRefreshOperation)
        case backingOff(remaining: TimeInterval, failures: Int)
    }
    private var routeCache: [String: RouteCacheEntry] = [:]
    private var routeCacheOrder: [String] = []
    /// Bumped by `invalidateRoutes(reason:)`. An evaluation or fetch that
    /// started under an older generation computed its answer on a network
    /// that is gone: it is not cached, not handed out, and not installed.
    private var routeGeneration: UInt64 = 0
    /// Requests waiting on an evaluation already running for the same cache
    /// key. proxy.log showed six identical "PAC evaluation took 1049ms"
    /// lines with the same millisecond timestamp: a burst of connections
    /// to one host each ran the script, serially on `jsQueue`, when one
    /// result would have served all of them.
    private var pendingEvaluations: [String: [EventLoopPromise<PACDecision>]] = [:]
    /// Waiters a single evaluation may hold. Past it, a request is answered
    /// at once with no usable answer (`refused`) rather than letting one
    /// stalled script queue promises without bound.
    package static let pendingWaiterLimit = 256
    /// Evaluations that may be queued on the serial evaluator at once, across
    /// all keys. A stalled script otherwise lets a stream of unique URLs queue
    /// closures without bound — each times out for its caller but stays on
    /// the queue. Past the limit a request is answered without routes.
    private let queuedEvaluationLimit: Int
    private var queuedEvaluations = 0
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let noUsableRouteReporter: PACNoUsableRouteReporter

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
        self.noUsableRouteReporter = PACNoUsableRouteReporter(eventSink: eventSink, logger: logger)
        self.refreshInterval = refreshInterval
        self.evalTimeoutSeconds = evalTimeoutSeconds
        self.pacLoader = pacLoader ?? { url in
            try await resolver.fetchPAC(from: url)
        }
    }

    /// Fetch and compile the PAC.
    ///
    /// `force` ignores the refresh interval. `honorBackoff` yields to the
    /// failure backoff (`backoffBase` doubling to `backoffCap`): network-path
    /// updates pass it; wake, VPN connect and disconnect and user action do
    /// not. A changed URL always fetches.
    ///
    /// One refresh runs at a time. A call that finds one running waits for it
    /// and shares its outcome (#39): on return the evaluator reflects the
    /// configured URL and the last `invalidateRoutes(reason:)`, or the failure
    /// is thrown. A refresh that sees an invalidation fetches again before it
    /// finishes, so no caller returns on a fetch from before one. A cancelled
    /// caller stops waiting with `CancellationError`; the refresh itself runs
    /// on for the others.
    package func refresh(force: Bool = false, honorBackoff: Bool = false) async throws {
        guard let operation = startRefresh(force: force, honorBackoff: honorBackoff, joinRunning: true) else { return }
        guard try await operation.wait() else {
            // Event first: this caller goes on without the refresh's outcome.
            eventSink?(RuntimeEvent(kind: .routing, event: "pac.refresh_wait_refused",
                                    detail: "limit=\(PACRefreshOperation.waiterLimit)"))
            logger?.log(.warning, "PAC refresh already has \(PACRefreshOperation.waiterLimit) callers waiting; not waiting for it.", category: .pac)
            return
        }
    }

    /// Starts a refresh, or finds the running one. Returns the operation to
    /// wait for; `nil` when there is nothing to wait for, or `joinRunning`
    /// is false and one was already running.
    private func startRefresh(force: Bool, honorBackoff: Bool, joinRunning: Bool) -> PACRefreshOperation? {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty else {
            clearCachedEvaluator()
            return nil
        }

        let decision: RefreshDecision = lock.withLock {
            if let runningRefresh { return .alreadyRunning(runningRefresh) }
            let needsRefresh = force || jsEvaluator == nil || cachedPACURL != config.pacURL || refreshExpired(at: lastRefreshAt)
            guard needsRefresh else { return .fresh }
            // Per attempted URL, so a URL that never loaded still backs off.
            let urlChanged = lastAttemptedPACURL != config.pacURL
            if honorBackoff, !urlChanged, let remaining = backoffRemainingLocked(now: Date()) {
                return .backingOff(remaining: remaining, failures: consecutiveFailures)
            }
            let operation = PACRefreshOperation()
            runningRefresh = operation
            if urlChanged {
                lastAttemptedPACURL = config.pacURL
                consecutiveFailures = 0
                lastFailureAt = nil
            }
            return .run(operation)
        }

        switch decision {
        case .run(let operation):
            let url = config.pacURL
            // Not the caller's task: a cancelled caller must not abandon a
            // fetch that others wait for.
            Task { await self.perform(operation, url: url) }
            return operation
        case .alreadyRunning(let operation):
            return joinRunning ? operation : nil
        case .fresh:
            return nil
        case .backingOff(let remaining, let failures):
            let seconds = Int(remaining.rounded(.up))
            eventSink?(RuntimeEvent(kind: .routing, event: "pac.refresh_backoff",
                                    detail: "failures=\(failures) remainingSeconds=\(seconds)"))
            logger?.log(.info, "PAC refresh skipped after \(failures) failed fetch(es); next attempt in \(seconds)s.", category: .pac)
            return nil
        }
    }

    /// The body of one refresh. Ends by clearing `runningRefresh` in the same
    /// critical section that installs the script or counts the failure, then
    /// reports, then releases the callers.
    private func perform(_ operation: PACRefreshOperation, url initialURL: String) async {
        var url = initialURL
        while true {
            let generation = lock.withLock { routeGeneration }
            let fetched: Result<any PacScriptEvaluating, any Error>
            do {
                fetched = .success(try await fetchAndCompile(url: url))
            } catch {
                fetched = .failure(error)
            }

            switch fetched {
            case .success(let newEvaluator):
                // The URL may have changed while this fetch ran. An evaluator
                // for the old URL is discarded, and the new URL fetched now,
                // so no request routes by a PAC the configuration no longer names.
                let current = configProvider()
                guard current.pacRoutingEnabled, !current.pacURL.isEmpty else {
                    clearCachedEvaluator()
                    lock.withLock { runningRefresh = nil }
                    operation.finish(.success(()))
                    return
                }
                if current.pacURL != url {
                    url = current.pacURL
                    lock.withLock {
                        lastAttemptedPACURL = url
                        consecutiveFailures = 0
                        lastFailureAt = nil
                    }
                    continue
                }
                // Routes invalidated while this fetch ran: the script came
                // from the network before the transition. Fetch again.
                let installed = lock.withLock { () -> Bool in
                    guard routeGeneration == generation else { return false }
                    cachedPACURL = url
                    jsEvaluator = newEvaluator
                    lastRefreshAt = .now
                    consecutiveFailures = 0
                    lastFailureAt = nil
                    routeCache.removeAll()
                    routeCacheOrder.removeAll()
                    runningRefresh = nil
                    return true
                }
                guard installed else { continue }
                eventSink?(RuntimeEvent(kind: .routing, event: "pac.refreshed", detail: "url=\(Self.redactedURL(url))"))
                logger?.log(.info, "Refreshed PAC routing rules from \(Self.redactedURL(url)).", category: .pac)
                operation.finish(.success(()))
                return

            case .failure(let error):
                // A fetch that failed on the network before an invalidation
                // says nothing about the new one: recorded, not counted
                // towards the backoff, and retried on the new network.
                let superseded = lock.withLock { () -> Bool in
                    if routeGeneration != generation { return true }
                    consecutiveFailures += 1
                    lastFailureAt = Date()
                    runningRefresh = nil
                    return false
                }
                if superseded {
                    eventSink?(RuntimeEvent(kind: .routing, event: "pac.refresh_failed",
                                            detail: "\(error.displayDescription) superseded=refetching"))
                    logger?.log(.info, "PAC fetch from before the network change failed (\(error.displayDescription)); refetching.", category: .pac)
                    continue
                }
                // Event first, then the derived log line; callers add neither.
                eventSink?(RuntimeEvent(kind: .routing, event: "pac.refresh_failed", detail: error.displayDescription))
                logger?.log(.warning, "PAC refresh failed: \(error.displayDescription)", category: .pac)
                operation.finish(.failure(error))
                return
            }
        }
    }

    private func fetchAndCompile(url: String) async throws -> any PacScriptEvaluating {
        let pacScript = try await pacLoader(url)
        return try compile(pacScript)
    }

    /// Synchronous on purpose: the evaluator is built on `jsQueue` and waited
    /// for with a semaphore, which an async context may not do.
    private func compile(_ pacScript: String) throws -> any PacScriptEvaluating {
        let resolver = self.resolver
        let timeout = evalTimeoutSeconds
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
    }

    /// Caller holds `lock`.
    private func backoffRemainingLocked(now: Date) -> TimeInterval? {
        guard consecutiveFailures > 0, let lastFailureAt else { return nil }
        let exponent = min(consecutiveFailures - 1, 10)
        let delay = min(Self.backoffBase * pow(2, Double(exponent)), Self.backoffCap)
        let remaining = delay - now.timeIntervalSince(lastFailureAt)
        return remaining > 0 ? remaining : nil
    }

    /// Seconds until the backoff admits a fetch; `nil` when none is in force.
    package func backoffRemaining(now: Date = Date()) -> TimeInterval? {
        lock.withLock { backoffRemainingLocked(now: now) }
    }

    /// Drop every answer computed on the network that just went away: the
    /// route cache, the loaded script (a PAC server may serve a different one
    /// per network) and any evaluation or fetch still running. Until the next
    /// refresh installs a script, requests get no PAC routes and go through
    /// the configured upstreams (`pac.no_usable_route reason=not_loaded`),
    /// never an answer from before the call. Follow it with
    /// `refresh(force: true)`; a fetch already running starts over instead.
    /// Emits one `pac.routes_invalidated` when PAC routing is on.
    package func invalidateRoutes(reason: PACRouteInvalidationReason) {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty else { return }
        let (routes, hadScript, fetching) = lock.withLock { () -> (Int, Bool, Bool) in
            let dropped = (routeCache.count, jsEvaluator != nil, runningRefresh != nil)
            routeGeneration &+= 1
            jsEvaluator = nil
            routeCache.removeAll()
            routeCacheOrder.removeAll()
            return dropped
        }
        eventSink?(RuntimeEvent(
            kind: .routing,
            event: "pac.routes_invalidated",
            detail: "reason=\(reason.rawValue) routes=\(routes) script=\(hadScript ? "dropped" : "none") "
                + "fetch=\(fetching ? "restarted" : "idle")"
        ))
        logger?.log(.info, "PAC answers dropped (\(reason.rawValue)): \(routes) cached route(s)\(hadScript ? " and the loaded script" : ""); refetching.", category: .pac)
    }

    /// Synchronous decision (tests and tools; the proxy uses `decisionFuture`).
    /// Blocks the caller for up to 2 s while the script runs.
    package func decision(for url: String, host: String) -> PACDecision {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty else { return .notConsulted }
        guard let requestURL = URL(string: url) else {
            return answer(.noUsableAnswer(.evaluationFailed, rejected: []), host: host)
        }

        refreshInBackgroundIfNeeded(for: config)

        let cacheKey = Self.routeCacheKey(for: requestURL, host: host)
        if let cached = cachedChain(forKey: cacheKey) {
            return answer(PACDecision(chain: cached), host: host)
        }

        let (evaluator, evaluatedURL, generation) = lock.withLock { (jsEvaluator, cachedPACURL, routeGeneration) }
        guard let evaluator else { return answer(.noUsableAnswer(.notLoaded, rejected: []), host: host) }

        let start = CFAbsoluteTimeGetCurrent()
        nonisolated(unsafe) var result: Result<[String], any Error>?
        let evalTimeout: DispatchTime = .now() + 2.0
        let semaphore = DispatchSemaphore(value: 0)
        jsQueue.async {
            result = Result { try evaluator.resolveProxyChain(for: requestURL) }
            semaphore.signal()
        }
        if semaphore.wait(timeout: evalTimeout) == .timedOut {
            logger?.log(.warning, "PAC evaluation timed out (2s) for \(host)", category: .pac)
            return answer(.noUsableAnswer(.timeout, rejected: []), host: host)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        if elapsed > slowEvalThresholdSeconds {
            logger?.log(.warning, "PAC evaluation took \(Int(elapsed * 1000))ms for \(host)", category: .pac)
        }

        switch result {
        case .success(let rawChain):
            let chain = resolver.routeChain(for: rawChain)
            guard storeCachedChain(chain, forKey: cacheKey, evaluatedWith: evaluatedURL, generation: generation) else {
                return answer(.noUsableAnswer(.superseded, rejected: []), host: host)
            }
            if let first = chain.routes.first {
                logger?.log(.debug, "PAC route for \(host): \(first) (chain entries: \(rawChain.count))", category: .pac)
            }
            return answer(PACDecision(chain: chain), host: host)
        case .failure(let error):
            return answer(.noUsableAnswer(Self.noUsableReason(for: error), rejected: []), host: host, error: error)
        case nil:
            // The semaphore is signalled only after `result` is set.
            assertionFailure("PAC evaluation signalled without a result")
            return answer(.noUsableAnswer(.evaluationFailed, rejected: []), host: host)
        }
    }

    /// Usable routes for a request, or none (tests and tools).
    package func routeChain(for url: String, host: String) -> [PACRoute] {
        decision(for: url, host: host).routes
    }

    /// Record a request that is routed as "no usable answer" by a decision
    /// the engine itself returned as usable: a chain whose only usable
    /// entry is a promoted `DIRECT` in a mode without direct fallback.
    package func reportNoUsableRoute(_ reason: PACNoUsableReason, rejected: PACRejections, host: String) {
        noUsableRouteReporter.report(reason, rejected: rejected, host: host)
    }

    /// Report a decision with no usable answer (rate-limited) and pass it on.
    private func answer(_ decision: PACDecision, host: String, error: (any Error)? = nil) -> PACDecision {
        if case .noUsableAnswer(let reason, let rejected) = decision {
            if let error {
                logger?.log(.debug, "PAC evaluation for \(host) failed: \(error.displayDescription)", category: .pac)
            }
            noUsableRouteReporter.report(reason, rejected: rejected, host: host)
        }
        return decision
    }

    private static func noUsableReason(for error: any Error) -> PACNoUsableReason {
        if case PACResolverError.evaluationTimedOut = error { return .timeout }
        return .evaluationFailed
    }

    package func decisionFuture(for url: String, host: String, on eventLoop: EventLoop) -> EventLoopFuture<PACDecision> {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty else {
            return eventLoop.makeSucceededFuture(.notConsulted)
        }
        guard let requestURL = URL(string: url) else {
            return eventLoop.makeSucceededFuture(answer(.noUsableAnswer(.evaluationFailed, rejected: []), host: host))
        }

        refreshInBackgroundIfNeeded(for: config)

        let cacheKey = Self.routeCacheKey(for: requestURL, host: host)
        if let cached = cachedChain(forKey: cacheKey) {
            return eventLoop.makeSucceededFuture(answer(PACDecision(chain: cached), host: host))
        }

        let (evaluator, evaluatedURL, generation) = lock.withLock { (jsEvaluator, cachedPACURL, routeGeneration) }
        guard let evaluator else {
            return eventLoop.makeSucceededFuture(answer(.noUsableAnswer(.notLoaded, rejected: []), host: host))
        }
        // Waiters join an evaluation of the same generation only, so a
        // request after an invalidation never waits on a pre-transition answer.
        let pendingKey = "\(generation) \(cacheKey)"

        let promise = eventLoop.makePromise(of: PACDecision.self)
        enum Admission { case leader, waiter, refused(reason: String, limit: Int) }
        let admission = lock.withLock { () -> Admission in
            guard let waiters = pendingEvaluations[pendingKey] else {
                guard queuedEvaluations < queuedEvaluationLimit else {
                    return .refused(reason: "queue_full", limit: queuedEvaluationLimit)
                }
                queuedEvaluations += 1
                pendingEvaluations[pendingKey] = []
                return .leader
            }
            guard waiters.count < Self.pendingWaiterLimit else {
                return .refused(reason: "waiters_full", limit: Self.pendingWaiterLimit)
            }
            pendingEvaluations[pendingKey]!.append(promise)
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
            promise.succeed(answer(.noUsableAnswer(.refused, rejected: []), host: host))
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
        // behind it. Promises are fulfilled on their own loops. A decision
        // without a usable answer is reported once for the whole group.
        let finish: @Sendable (PACDecision, (any Error)?) -> Void = { decision, error in
            let decision = self.answer(decision, host: host, error: error)
            let waiters = self.lock.withLock { self.pendingEvaluations.removeValue(forKey: pendingKey) ?? [] }
            for waiter in [promise] + waiters {
                waiter.futureResult.eventLoop.execute { waiter.succeed(decision) }
            }
        }

        jsQueue.async {
            let result = Result { try evaluator.resolveProxyChain(for: requestURLForEval) }
            self.lock.withLock { self.queuedEvaluations -= 1 }
            completion.complete {
                switch result {
                case .success(let rawChain):
                    let elapsed = CFAbsoluteTimeGetCurrent() - start
                    let chain = resolver.routeChain(for: rawChain)
                    if elapsed > slowEvalThresholdSeconds {
                        logger?.log(.warning, "PAC evaluation took \(Int(elapsed * 1000))ms for \(host)", category: .pac)
                    }
                    // A result from a PAC the configuration no longer names,
                    // or from before an invalidation, is neither cached nor
                    // handed to the waiters.
                    guard self.storeCachedChain(chain, forKey: cacheKey, evaluatedWith: evaluatedURL, generation: generation) else {
                        finish(.noUsableAnswer(.superseded, rejected: []), nil)
                        return
                    }
                    if let first = chain.routes.first {
                        logger?.log(.debug, "PAC route for \(host): \(first) (chain entries: \(rawChain.count))", category: .pac)
                    }
                    finish(PACDecision(chain: chain), nil)
                case .failure(let error):
                    finish(.noUsableAnswer(Self.noUsableReason(for: error), rejected: []), error)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            completion.complete {
                logger?.log(.warning, "PAC evaluation timed out (\(Int(timeout))s) for \(host)", category: .pac)
                finish(.noUsableAnswer(.timeout, rejected: []), nil)
            }
        }

        return promise.futureResult
    }

    package func route(for url: String, host: String) -> PACRoute? {
        routeChain(for: url, host: host).first
    }

    /// Whether the script chose DIRECT for this request. A `DIRECT` promoted
    /// by removing rejected entries is a fallback, not a bypass.
    package func shouldBypass(url: String, host: String) -> Bool {
        guard case .routes(let chain) = decision(for: url, host: host) else { return false }
        return chain.routes.first == .direct && !chain.leadingDirectPromoted
    }

    private func refreshInBackgroundIfNeeded(for config: ProxyConfig) {
        // Pre-check only: `startRefresh` claims the slot. Silent, since
        // this runs on every routing decision.
        let shouldKickOff = lock.withLock {
            // A superseded PAC must not keep routing while its replacement
            // loads; routes fall back to the non-PAC behaviour until then.
            if jsEvaluator != nil, cachedPACURL != config.pacURL {
                jsEvaluator = nil
                routeCache.removeAll()
                routeCacheOrder.removeAll()
            }
            guard runningRefresh == nil else { return false }
            let needsRefresh = jsEvaluator == nil || cachedPACURL != config.pacURL || refreshExpired(at: lastRefreshAt)
            guard needsRefresh else { return false }
            return lastAttemptedPACURL != config.pacURL || backoffRemainingLocked(now: Date()) == nil
        }

        guard shouldKickOff else { return }
        // Never waits: the request that noticed goes on without PAC routes.
        _ = startRefresh(force: false, honorBackoff: true, joinRunning: false)
    }

    private func refreshExpired(at date: Date?) -> Bool {
        guard let date else { return true }
        return Date().timeIntervalSince(date) >= refreshInterval
    }

    private func clearCachedEvaluator() {
        lock.withLock {
            cachedPACURL = ""
            lastAttemptedPACURL = ""
            jsEvaluator = nil
            lastRefreshAt = nil
            // `runningRefresh` belongs to the refresh that claimed it; it
            // releases the slot itself after re-reading the configuration.
            consecutiveFailures = 0
            lastFailureAt = nil
            routeCache.removeAll()
            routeCacheOrder.removeAll()
        }
    }

    private func cachedChain(forKey key: String) -> PACChain? {
        lock.withLock {
            purgeExpiredRouteCacheEntriesLocked(now: .now)
            guard let entry = routeCache[key], entry.expiresAt > .now else {
                routeCache.removeValue(forKey: key)
                routeCacheOrder.removeAll { $0 == key }
                return nil
            }
            touchRouteCacheKeyLocked(key)
            return entry.chain
        }
    }

    /// Caches `chain` if the PAC it came from is still the loaded one and no
    /// invalidation came since. Returns whether it did; a `false` means the
    /// result is superseded and must not be used either.
    private func storeCachedChain(
        _ chain: PACChain, forKey key: String, evaluatedWith pacURL: String, generation: UInt64
    ) -> Bool {
        lock.withLock {
            guard cachedPACURL == pacURL, jsEvaluator != nil, routeGeneration == generation else { return false }
            routeCache[key] = RouteCacheEntry(
                chain: chain,
                expiresAt: Date().addingTimeInterval(Self.routeCacheTTL)
            )
            touchRouteCacheKeyLocked(key)
            evictRouteCacheIfNeededLocked(now: .now)
            return true
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

/// One PAC refresh and the callers waiting for its outcome.
private final class PACRefreshOperation: @unchecked Sendable {
    /// Callers that may wait on one refresh. Only control-plane callers wait
    /// (the per-request background refresh never does), so this is far above
    /// what a run reaches; past it a caller goes on without waiting.
    static let waiterLimit = 64

    private let lock = NSLock()
    private var outcome: Result<Void, any Error>?
    private var waiters: [UInt64: CheckedContinuation<Void, any Error>] = [:]
    private var nextWaiterID: UInt64 = 0

    /// Waits for the outcome and rethrows its failure. Returns `false`, at
    /// once, when `waiterLimit` callers are already waiting.
    func wait() async throws -> Bool {
        let id = lock.withLock { () -> UInt64 in
            nextWaiterID &+= 1
            return nextWaiterID
        }
        var admitted = true
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                let immediate = lock.withLock { () -> Result<Void, any Error>? in
                    if let outcome { return outcome }
                    // Cancelled before the handler could see this waiter.
                    if Task.isCancelled { return .failure(CancellationError()) }
                    guard waiters.count < Self.waiterLimit else {
                        admitted = false
                        return .success(())
                    }
                    waiters[id] = continuation
                    return nil
                }
                if let immediate { continuation.resume(with: immediate) }
            }
        } onCancel: {
            let waiter = lock.withLock { waiters.removeValue(forKey: id) }
            waiter?.resume(throwing: CancellationError())
        }
        return admitted
    }

    func finish(_ result: Result<Void, any Error>) {
        let waiting = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            outcome = result
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in waiting { waiter.resume(with: result) }
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
