// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore

/// Why the engine dropped its answers; the `reason=` of `pac.routes_invalidated`.
package enum PACRouteInvalidationReason: String, Sendable {
    /// A VPN came up: cold-start priming or a reconnect after an outage.
    case vpnConnected = "vpn_connected"
    /// A VPN went down for good (not a flap).
    case vpnDisconnected = "vpn_disconnected"
    /// A material network-path change (#101's fields: status, interfaces,
    /// gateways, address families, DNS) other than the first path seen.
    case networkChanged = "network_changed"

    /// Whether the loaded script goes with the answers. A VPN transition
    /// moves to a network whose PAC server may hand out another script. A
    /// path change keeps the script: the answers go, because `myIpAddress()`,
    /// `dnsResolve()` and `isInNet()` may answer differently now, but the
    /// forced refetch that follows replaces the script only if it can reach
    /// the PAC server. Dropping it would leave every request without PAC
    /// routes on an unsatisfied path or while the fetch backs off.
    var dropsScript: Bool { self != .networkChanged }
}

package final class PACRoutingEngine: @unchecked Sendable {
    /// A parsed answer, including one with no usable routes: the script's
    /// answer is deterministic for the key, so it is cached like any other.
    /// Failures (timeout, error, refusal) are not cached.
    private struct RouteCacheEntry {
        let chain: PACChain
        /// Served as is until then; after it, still served, and evaluated
        /// again in the background (#34).
        var revalidateAfter: Date
        /// Never served after it.
        let expiresAt: Date
    }

    private enum CachedRoute {
        case fresh(PACChain)
        /// Past `revalidateAfter`: serve it and evaluate it again.
        case stale(PACChain)
        case miss
    }

    /// How long an answer may be served at all (#34). Everything that changes
    /// an answer's inputs already drops the cache: a refresh that installs a
    /// different script, a VPN transition, a material path change. An answer
    /// in use is evaluated again, in the background, every
    /// `routeRevalidationAge`. The TTL is left to bound what none of those
    /// see: a host requested rarely, whose answer depends on the time
    /// (`timeRange`) or on a DNS answer that moved with no path change. Ten
    /// minutes keeps a slow host's answer across the gaps between an idle
    /// client's polls (Outlook EWS paid 0.5–1.6 s about every minute at the
    /// old 60 s), and is the same horizon as the PAC fetch backoff cap.
    package static let routeCacheTTL: TimeInterval = 600
    /// Age after which a cached answer is evaluated again in the background
    /// while it goes on being served: the old TTL, so an answer in use is as
    /// current as before and no request waits for it.
    package static let routeRevalidationAge: TimeInterval = 60
    /// `pac.evaluation_slow` and `pac.revalidation_failed` are reported at
    /// most once per host in this interval.
    package static let slowEvaluationReportInterval: TimeInterval = 600
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
    /// The text `jsEvaluator` was compiled from. A refresh that fetches the
    /// same text keeps the cached answers (marked for re-evaluation) rather
    /// than making every host pay for its first request again.
    private var loadedScript: String?
    /// Bumped when a refresh installs a different script. An evaluation by
    /// the script it replaced may still hand its answer to its waiters, as
    /// before, but does not cache it.
    private var scriptVersion: UInt64 = 0
    private var lastRefreshAt: Date?
    /// The refresh running now, if any: one at a time, and later callers
    /// wait for it. It clears itself in the same critical section that
    /// installs its script or records its failure, so an invalidation after
    /// that point finds no refresh running and the next one fetches afresh.
    private var runningRefresh: PACRefreshOperation?
    /// The reason of the last invalidation no script has been installed
    /// since; the next install is reported against it.
    private var pendingInvalidation: PACRouteInvalidationReason?
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
    /// Per-host limit for `pac.evaluation_slow` and `pac.revalidation_failed`
    /// (64 host/reason pairs).
    private let evaluationReportGate: RuntimeEventRepeatGate
    /// Drives the route cache and the evaluation timing, so tests can move
    /// time. The refresh interval and fetch backoff use the wall clock.
    private let now: @Sendable () -> Date

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
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.now = now
        self.evaluationReportGate = RuntimeEventRepeatGate(repeatInterval: Self.slowEvaluationReportInterval, now: now)
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
            let fetched: Result<(evaluator: any PacScriptEvaluating, script: String), any Error>
            do {
                fetched = .success(try await fetchAndCompile(url: url))
            } catch {
                fetched = .failure(error)
            }

            switch fetched {
            case .success(let (newEvaluator, script)):
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
                let installedAt = now()
                let installed = lock.withLock { () -> (installed: Bool, after: PACRouteInvalidationReason?, sameScript: Bool) in
                    guard routeGeneration == generation else { return (false, nil, false) }
                    let sameScript = jsEvaluator != nil && cachedPACURL == url && loadedScript == script
                    cachedPACURL = url
                    jsEvaluator = newEvaluator
                    loadedScript = script
                    lastRefreshAt = .now
                    consecutiveFailures = 0
                    lastFailureAt = nil
                    if sameScript {
                        // Same script, same network: the answers stand, and
                        // are evaluated again in the background on next use.
                        for key in Array(routeCache.keys) {
                            routeCache[key]?.revalidateAfter = installedAt
                        }
                    } else {
                        scriptVersion &+= 1
                        routeCache.removeAll()
                        routeCacheOrder.removeAll()
                    }
                    runningRefresh = nil
                    defer { pendingInvalidation = nil }
                    return (true, pendingInvalidation, sameScript)
                }
                guard installed.installed else { continue }
                let redacted = Self.redactedURL(url)
                let unchanged = installed.sameScript ? " script=unchanged" : ""
                if let reason = installed.after {
                    // A reload after a network transition is rare and the
                    // owner needs to see it in the app's notice-level log.
                    eventSink?(RuntimeEvent(kind: .routing, event: "pac.refreshed",
                                            detail: "url=\(redacted) after=\(reason.rawValue)\(unchanged)"))
                    logger?.log(.notice, "Reloaded PAC routing rules from \(redacted) after \(reason.rawValue)"
                        + "\(installed.sameScript ? " (script unchanged)" : "").", category: .pac)
                } else {
                    eventSink?(RuntimeEvent(kind: .routing, event: "pac.refreshed", detail: "url=\(redacted)\(unchanged)"))
                    logger?.log(.info, "Refreshed PAC routing rules from \(redacted)"
                        + "\(installed.sameScript ? " (script unchanged; cached answers kept)" : "").", category: .pac)
                }
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

    private func fetchAndCompile(url: String) async throws -> (evaluator: any PacScriptEvaluating, script: String) {
        let pacScript = try await pacLoader(url)
        return (try compile(pacScript), pacScript)
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
    /// route cache, any evaluation or fetch still running (a background
    /// re-evaluation included) and, when `reason.dropsScript`, the loaded
    /// script (a PAC server may serve a different one per network). Without
    /// a script, until the next refresh installs one, requests get no PAC
    /// routes and go through the configured upstreams
    /// (`pac.no_usable_route reason=not_loaded`); with it, they are evaluated
    /// afresh. Never an answer from before the call. Follow it with
    /// `refresh(force: true)`; a fetch already running starts over instead.
    /// Emits one `pac.routes_invalidated` when PAC routing is on.
    package func invalidateRoutes(reason: PACRouteInvalidationReason) {
        let config = configProvider()
        guard config.pacRoutingEnabled, !config.pacURL.isEmpty else { return }
        let (routes, hadScript, fetching) = lock.withLock { () -> (Int, Bool, Bool) in
            let dropped = (routeCache.count, jsEvaluator != nil, runningRefresh != nil)
            routeGeneration &+= 1
            pendingInvalidation = reason
            if reason.dropsScript {
                jsEvaluator = nil
                loadedScript = nil
            }
            routeCache.removeAll()
            routeCacheOrder.removeAll()
            return dropped
        }
        let script = !hadScript ? "none" : reason.dropsScript ? "dropped" : "kept"
        eventSink?(RuntimeEvent(
            kind: .routing,
            event: "pac.routes_invalidated",
            detail: "reason=\(reason.rawValue) routes=\(routes) script=\(script) "
                + "fetch=\(fetching ? "restarted" : "idle")"
        ))
        let scriptNote = script == "dropped" ? " and the loaded script" : ""
        logger?.log(.notice, "PAC answers dropped (\(reason.rawValue)): \(routes) cached route(s)\(scriptNote); refetching.", category: .pac)
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
        switch cachedRoute(forKey: cacheKey) {
        case .fresh(let cached):
            return answer(PACDecision(chain: cached), host: host)
        case .stale(let cached):
            revalidateInBackground(requestURL: requestURL, host: host, cacheKey: cacheKey)
            return answer(PACDecision(chain: cached), host: host)
        case .miss:
            break
        }

        let (evaluator, evaluatedURL, generation, version) = lock.withLock {
            (jsEvaluator, cachedPACURL, routeGeneration, scriptVersion)
        }
        guard let evaluator else { return answer(.noUsableAnswer(.notLoaded, rejected: []), host: host) }

        let now = self.now
        nonisolated(unsafe) var result: Result<[String], any Error>?
        nonisolated(unsafe) var elapsed: TimeInterval = 0
        let evalTimeout: DispatchTime = .now() + 2.0
        let semaphore = DispatchSemaphore(value: 0)
        jsQueue.async {
            let start = now()
            result = Result { try evaluator.resolveProxyChain(for: requestURL) }
            elapsed = now().timeIntervalSince(start)
            semaphore.signal()
        }
        if semaphore.wait(timeout: evalTimeout) == .timedOut {
            logger?.log(.warning, "PAC evaluation timed out (2s) for \(host)", category: .pac)
            return answer(.noUsableAnswer(.timeout, rejected: []), host: host)
        }
        reportIfSlow(elapsed, host: host)

        switch result {
        case .success(let rawChain):
            let chain = resolver.routeChain(for: rawChain)
            let stored = storeCachedChain(
                chain, forKey: cacheKey, evaluatedWith: evaluatedURL, generation: generation, scriptVersion: version
            )
            guard stored != .superseded else {
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
        switch cachedRoute(forKey: cacheKey) {
        case .fresh(let cached):
            return eventLoop.makeSucceededFuture(answer(PACDecision(chain: cached), host: host))
        case .stale(let cached):
            // Served now; the request never waits on a host it has an answer for.
            revalidateInBackground(requestURL: requestURL, host: host, cacheKey: cacheKey)
            return eventLoop.makeSucceededFuture(answer(PACDecision(chain: cached), host: host))
        case .miss:
            break
        }

        let promise = eventLoop.makePromise(of: PACDecision.self)
        enum Admission { case leader(EvaluationJob), waiter, notLoaded, refused(reason: String, limit: Int) }
        let admission = lock.withLock { () -> Admission in
            guard let evaluator = jsEvaluator else { return .notLoaded }
            // Waiters join an evaluation of the same generation and script
            // only (`EvaluationJob.pendingKey`).
            let job = EvaluationJob(
                requestURL: requestURL, host: host, cacheKey: cacheKey, generation: routeGeneration,
                evaluator: evaluator, evaluatedURL: cachedPACURL, scriptVersion: scriptVersion
            )
            guard let waiters = pendingEvaluations[job.pendingKey] else {
                guard queuedEvaluations < queuedEvaluationLimit else {
                    return .refused(reason: "queue_full", limit: queuedEvaluationLimit)
                }
                queuedEvaluations += 1
                pendingEvaluations[job.pendingKey] = []
                return .leader(job)
            }
            guard waiters.count < Self.pendingWaiterLimit else {
                return .refused(reason: "waiters_full", limit: Self.pendingWaiterLimit)
            }
            pendingEvaluations[job.pendingKey]!.append(promise)
            return .waiter
        }
        switch admission {
        case .waiter:
            return promise.futureResult
        case .notLoaded:
            promise.succeed(answer(.noUsableAnswer(.notLoaded, rejected: []), host: host))
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
        case .leader(let job):
            startEvaluation(job, leader: promise)
            return promise.futureResult
        }
    }

    /// One evaluation of one cache key, and what it was started under.
    private struct EvaluationJob: Sendable {
        let requestURL: URL
        let host: String
        let cacheKey: String
        let generation: UInt64
        let evaluator: any PacScriptEvaluating
        let evaluatedURL: String
        let scriptVersion: UInt64

        /// Requests join a running evaluation only under the same generation
        /// and script: one admitted after an invalidation or a changed
        /// script never waits on an answer from before it.
        var pendingKey: String { "\(generation) \(scriptVersion) \(cacheKey)" }
    }

    /// Starts a background evaluation of a stale answer, unless one of this
    /// key is already running (a foreground one included) or the evaluation
    /// queue is full. Either way the stale answer is what the request gets;
    /// a skipped re-evaluation is tried again on the key's next request.
    private func revalidateInBackground(requestURL: URL, host: String, cacheKey: String) {
        let job = lock.withLock { () -> EvaluationJob? in
            guard let evaluator = jsEvaluator else { return nil }
            let job = EvaluationJob(
                requestURL: requestURL, host: host, cacheKey: cacheKey, generation: routeGeneration,
                evaluator: evaluator, evaluatedURL: cachedPACURL, scriptVersion: scriptVersion
            )
            guard pendingEvaluations[job.pendingKey] == nil, queuedEvaluations < queuedEvaluationLimit else { return nil }
            queuedEvaluations += 1
            pendingEvaluations[job.pendingKey] = []
            return job
        }
        guard let job else { return }
        startEvaluation(job, leader: nil)
    }

    /// Runs `job` on the evaluator queue, bounded by `evalTimeoutSeconds`.
    /// Its result (or timeout) settles `leader` and every request that joined
    /// it; a decision without a usable answer is reported once for the whole
    /// group. A background re-evaluation has no leader: with nobody waiting,
    /// a success is only cached, and a failure keeps the stale answer.
    /// Promises are fulfilled on their own loops.
    private func startEvaluation(_ job: EvaluationJob, leader: EventLoopPromise<PACDecision>?) {
        let completion = PACRouteEvaluationCompletion()
        let timeout = evalTimeoutSeconds
        let now = self.now
        let host = job.host

        let finish: @Sendable (PACDecision, (any Error)?) -> Void = { decision, error in
            let waiters = self.lock.withLock { self.pendingEvaluations.removeValue(forKey: job.pendingKey) ?? [] }
            let promises = (leader.map { [$0] } ?? []) + waiters
            guard !promises.isEmpty else {
                self.backgroundEvaluationFinished(decision, job: job, error: error)
                return
            }
            let decision = self.answer(decision, host: host, error: error)
            for waiter in promises {
                waiter.futureResult.eventLoop.execute { waiter.succeed(decision) }
            }
        }

        jsQueue.async {
            let start = now()
            let result = Result { try job.evaluator.resolveProxyChain(for: job.requestURL) }
            let elapsed = now().timeIntervalSince(start)
            self.lock.withLock { self.queuedEvaluations -= 1 }
            completion.complete {
                switch result {
                case .success(let rawChain):
                    let chain = self.resolver.routeChain(for: rawChain)
                    self.reportIfSlow(elapsed, host: host)
                    // A result from a PAC the configuration no longer names,
                    // or from before an invalidation, is neither cached nor
                    // handed to the waiters.
                    let stored = self.storeCachedChain(
                        chain, forKey: job.cacheKey, evaluatedWith: job.evaluatedURL,
                        generation: job.generation, scriptVersion: job.scriptVersion
                    )
                    guard stored != .superseded else {
                        finish(.noUsableAnswer(.superseded, rejected: []), nil)
                        return
                    }
                    if let first = chain.routes.first {
                        self.logger?.log(.debug, "PAC route for \(host): \(first) (chain entries: \(rawChain.count))", category: .pac)
                    }
                    finish(PACDecision(chain: chain), nil)
                case .failure(let error):
                    finish(.noUsableAnswer(Self.noUsableReason(for: error), rejected: []), error)
                }
            }
        }

        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
            completion.complete {
                self.logger?.log(.warning, "PAC evaluation timed out (\(Int(timeout))s) for \(host)", category: .pac)
                finish(.noUsableAnswer(.timeout, rejected: []), nil)
            }
        }
    }

    /// A background re-evaluation that nobody waited for has finished
    /// without an answer to cache. Superseded: an invalidation or a new
    /// script dropped the stale answer too, and said so. Failed: the stale
    /// answer is kept, until it expires, and not tried again for
    /// `routeRevalidationAge`, so a failing host costs one evaluation a
    /// minute, not one per request. A failure whose answer an invalidation
    /// or a different script has dropped meanwhile has nothing left to keep
    /// serving, and is not reported: whatever now sits under the key was
    /// computed afresh and is not this job's to touch.
    private func backgroundEvaluationFinished(_ decision: PACDecision, job: EvaluationJob, error: (any Error)?) {
        guard case .noUsableAnswer(let reason, _) = decision else { return }
        let retryAt = now().addingTimeInterval(Self.routeRevalidationAge)
        let kept = reason != .superseded && lock.withLock { () -> Bool in
            guard routeGeneration == job.generation, scriptVersion == job.scriptVersion,
                  routeCache[job.cacheKey] != nil else { return false }
            routeCache[job.cacheKey]?.revalidateAfter = retryAt
            return true
        }
        guard kept else {
            logger?.log(.debug, "Background PAC re-evaluation for \(job.host) finished (\(reason.rawValue)) after its answer was dropped; discarded.", category: .pac)
            return
        }
        guard let suppressed = evaluationReportGate.admit(host: job.host.lowercased(), reason: "revalidation_failed") else { return }
        eventSink?(RuntimeEvent(
            kind: .routing,
            event: "pac.revalidation_failed",
            detail: "host=\(job.host) reason=\(reason.rawValue) suppressed=\(suppressed)"
        ))
        let cause = error.map { ": \($0.displayDescription)" } ?? ""
        logger?.log(.warning, "Background PAC re-evaluation for \(job.host) failed (\(reason.rawValue)\(cause)); "
            + "serving its previous answer until it expires.", category: .pac)
    }

    /// `pac.evaluation_slow`, at most once per host per
    /// `slowEvaluationReportInterval`, with the slow evaluations held back
    /// since the last report. The time is the script's own run, not the
    /// wait for the evaluator queue.
    private func reportIfSlow(_ elapsed: TimeInterval, host: String) {
        guard elapsed > slowEvalThresholdSeconds else { return }
        guard let suppressed = evaluationReportGate.admit(host: host.lowercased(), reason: "slow") else { return }
        let ms = Int((elapsed * 1000).rounded())
        eventSink?(RuntimeEvent(kind: .routing, event: "pac.evaluation_slow",
                                detail: "host=\(host) ms=\(ms) suppressed=\(suppressed)"))
        let held = suppressed > 0 ? " (\(suppressed) more slow evaluation(s) of it since the last report)" : ""
        logger?.log(.warning, "PAC evaluation took \(ms)ms for \(host)\(held)", category: .pac)
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
            loadedScript = nil
            lastRefreshAt = nil
            // `runningRefresh` belongs to the refresh that claimed it; it
            // releases the slot itself after re-reading the configuration.
            consecutiveFailures = 0
            lastFailureAt = nil
            routeCache.removeAll()
            routeCacheOrder.removeAll()
        }
    }

    private func cachedRoute(forKey key: String) -> CachedRoute {
        let now = self.now()
        return lock.withLock {
            purgeExpiredRouteCacheEntriesLocked(now: now)
            guard let entry = routeCache[key] else { return .miss }
            touchRouteCacheKeyLocked(key)
            return now >= entry.revalidateAfter ? .stale(entry.chain) : .fresh(entry.chain)
        }
    }

    private enum StoreOutcome {
        case stored
        /// Evaluated by a script a refresh has since replaced: still an
        /// answer for the request that waited on it, as before, but not cached.
        case scriptReplaced
        /// From a PAC the configuration no longer names, or from before an
        /// invalidation: neither cached nor used.
        case superseded
    }

    private func storeCachedChain(
        _ chain: PACChain, forKey key: String, evaluatedWith pacURL: String, generation: UInt64, scriptVersion version: UInt64
    ) -> StoreOutcome {
        let now = self.now()
        return lock.withLock {
            guard cachedPACURL == pacURL, jsEvaluator != nil, routeGeneration == generation else { return .superseded }
            guard scriptVersion == version else { return .scriptReplaced }
            routeCache[key] = RouteCacheEntry(
                chain: chain,
                revalidateAfter: now.addingTimeInterval(Self.routeRevalidationAge),
                expiresAt: now.addingTimeInterval(Self.routeCacheTTL)
            )
            touchRouteCacheKeyLocked(key)
            evictRouteCacheIfNeededLocked(now: now)
            return .stored
        }
    }

    /// Evaluations running or queued, one per cache key and generation
    /// (tests and pm-sim wait on it to reach zero).
    package func pendingEvaluationCount() -> Int {
        lock.withLock { pendingEvaluations.count }
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
