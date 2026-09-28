// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

package final class DirectConnectDetector: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let ttlSeconds: TimeInterval
    private let baseTimeoutMS: Int64
    private let maxTimeoutMS: Int64
    private let maxCacheSize: Int
    private let maxConcurrentProbes: Int
    /// Keyed by `cacheKey`: a result is only ever read back under the
    /// blocklist policy it was probed under (#93).
    private var cache: [String: CacheEntry] = [:]
    private var hostTimeouts: [String: Int64] = [:]
    private var pendingProbes: Set<String> = []
    /// Host → when a strict-mode hint probe last ran; see `probeForStrictModeHint`.
    private var strictHintProbedAt: [String: Date] = [:]
    private var strictHintInFlight = 0
    private var strictHintSkipped = 0
    /// The last `routing.strict_direct_reachable_suppressed` and the
    /// failures suppressed for the same reason and transition since.
    private var suppressionReport: SuppressionReport?
    /// Host → when `routing.probe_blocked` was last emitted for it.
    private var probeBlockedReportedAt: [String: Date] = [:]
    private var probesStarted = 0
    private let now: @Sendable () -> Date
    /// When routing last changed; see `probeForStrictModeHint`. Nil (tests
    /// and tools without an orchestrator) never settles anything.
    private let routingTransitions: RoutingTransitionSignal?
    private let strictHintSettleWindow: TimeInterval
    private let resolveForProbe: @Sendable (String, Int, EventLoop) -> EventLoopFuture<[SocketAddress]>
    private let lock = NSLock()

    /// Per-host cooldown between strict-mode hint probes (#87).
    package static let strictHintCooldown: TimeInterval = 600
    /// Hosts the strict-mode hint remembers at once. Past it, entries whose
    /// cooldown ran out go first, then the oldest.
    package static let strictHintCapacity = 256
    /// Strict-mode hint probes in flight at once. Past it a hint is skipped
    /// (and counted), so a burst of failing hosts cannot fan out into an
    /// unbounded number of direct connection attempts.
    package static let strictHintMaxInFlight = 4
    /// Per-host cooldown between `routing.probe_blocked` events.
    package static let probeBlockedCooldown: TimeInterval = 600
    /// Hosts the `routing.probe_blocked` rate limit remembers at once;
    /// evicted like the strict-mode hint table.
    package static let probeBlockedCapacity = 256
    /// How long after a VPN transition or direct-mode change a strict-mode
    /// failure is not probed for a hint (#97). In three days of logs every
    /// false hint came within about 5 s of a VPN connect or disconnect, and
    /// at login the upstream failures lasted about 7 s; 15 s covers that
    /// twice over. A late hint costs little: the host fails again after the
    /// window and is probed then, because suppression starts no cooldown.
    package static let strictHintSettleWindow: TimeInterval = 15
    /// While suppression goes on for one reason and one transition,
    /// `routing.strict_direct_reachable_suppressed` repeats at most this
    /// often, carrying the count since the last one.
    package static let strictHintSuppressedReportInterval: TimeInterval = 60

    /// Why `probeForStrictModeHint` did or did not start a probe.
    package enum StrictHintProbe: Equatable, Sendable {
        case started
        /// The host was probed within `strictHintCooldown`.
        case coolingDown
        /// `strictHintMaxInFlight` probes are already running.
        case busy
        /// The host is on the metadata/loopback blocklist (gateway mode).
        case blocked
        /// Routing is changing under the proxy, so the failure says nothing
        /// about the host (#97).
        case suppressed(StrictHintSuppression)
    }

    /// Why a strict-mode hint was not probed: `reason=` in
    /// `routing.strict_direct_reachable_suppressed`.
    package enum StrictHintSuppression: String, Sendable {
        /// Within `strictHintSettleWindow` of a VPN connect or disconnect or
        /// a direct-mode change, or while one is being handled.
        case vpnTransition = "vpn_transition"
        /// During a VPN flap hold (`.reasserting`).
        case flap
        /// While in direct mode.
        case directMode = "direct_mode"
    }

    private struct SuppressionReport {
        let reason: StrictHintSuppression
        /// `RoutingTransitionSignal.State.completed` when it was emitted.
        let transition: Int
        let at: Date
        /// Suppressed since `at` for this reason and transition, not yet reported.
        var pending: Int
    }

    package struct CacheEntry {
        let reachable: Bool
        let checkedAt: Date
    }

    /// Which caller a probe runs for: `kind=` in `routing.probe_blocked`.
    package enum ProbeKind: String, Sendable {
        case reachability
        case strictHint = "strict_hint"

        var label: String {
            switch self {
            case .strictHint: "Strict-mode hint probe"
            case .reachability: "Direct-connect probe"
            }
        }

        /// A skipped hint is worth noting; a skipped background reachability
        /// probe is routine.
        var blockedLogLevel: LogLevel {
            switch self {
            case .strictHint: .info
            case .reachability: .debug
            }
        }
    }

    /// Why a probe refused to connect: `reason=` in `routing.probe_blocked`.
    package enum ProbeBlockReason: Sendable, Equatable {
        /// The host name or literal itself is on the blocklist.
        case blockedName
        /// The host resolved to (or connected to) a blocked address.
        case blockedAddress(String)

        var detail: String {
            switch self {
            case .blockedName: "reason=blocked_name"
            case .blockedAddress(let ip): "reason=blocked_address address=\(ip)"
            }
        }
    }

    /// - Parameter resolver: how every probe resolves a host before it
    ///   connects, so each resolved address can be checked against the
    ///   blocklist first. Tests inject one; the default asks
    ///   `AddressFamilyAwareResolver` for A, then AAAA, records.
    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        ttlSeconds: TimeInterval = 300,
        baseTimeoutMS: Int64 = 500,
        maxCacheSize: Int = 512,
        maxConcurrentProbes: Int = 16,
        now: @escaping @Sendable () -> Date = { Date() },
        routingTransitions: RoutingTransitionSignal? = nil,
        strictHintSettleWindow: TimeInterval = DirectConnectDetector.strictHintSettleWindow,
        resolver: (@Sendable (String, Int, EventLoop) -> EventLoopFuture<[SocketAddress]>)? = nil,
        eventSink: (@Sendable (RuntimeEvent) -> Void)? = nil
    ) {
        self.group = group
        self.logger = logger
        self.eventSink = eventSink
        self.ttlSeconds = ttlSeconds
        self.baseTimeoutMS = baseTimeoutMS
        self.maxTimeoutMS = baseTimeoutMS * 8
        self.maxCacheSize = maxCacheSize
        self.maxConcurrentProbes = maxConcurrentProbes
        self.now = now
        self.routingTransitions = routingTransitions
        self.strictHintSettleWindow = strictHintSettleWindow
        self.resolveForProbe = resolver ?? { host, port, loop in
            let resolver = AddressFamilyAwareResolver(group: group)
            // A lookup that fails for one family leaves the other; if both
            // fail the host has no address to probe, which is the answer.
            let v4 = resolver.initiateAQuery(host: host, port: port).hop(to: loop)
                .flatMapError { _ in loop.makeSucceededFuture([]) }
            let v6 = resolver.initiateAAAAQuery(host: host, port: port).hop(to: loop)
                .flatMapError { _ in loop.makeSucceededFuture([]) }
            return v4.and(v6).map { $0 + $1 }
        }
    }

    /// Direct probes started so far, of every kind. Lets tests prove that a
    /// path made none (strict mode makes no proactive probes, #87).
    package var probeCount: Int {
        lock.withLock { probesStarted }
    }

    /// Background reachability probes running now (at most `maxConcurrentProbes`).
    package var pendingProbeCount: Int {
        lock.withLock { pendingProbes.count }
    }

    /// Strict-mode hint probes running now (at most `strictHintMaxInFlight`).
    package var strictHintInFlightCount: Int {
        lock.withLock { strictHintInFlight }
    }

    /// Strict-mode hints skipped because `strictHintMaxInFlight` probes were running.
    package var strictHintSkippedCount: Int {
        lock.withLock { strictHintSkipped }
    }

    /// Hosts in the `routing.probe_blocked` rate-limit table (bounded by `probeBlockedCapacity`).
    package var probeBlockedTableCount: Int {
        lock.withLock { probeBlockedReportedAt.count }
    }

    /// After a strict-mode request failed through the upstream: probe
    /// `host:port` directly once, and call `onReachable` if it answers, so
    /// the caller can suggest a No-proxy entry. The request itself is never
    /// retried directly. At most one probe per host per `strictHintCooldown`,
    /// in a table of at most `strictHintCapacity` hosts, and at most
    /// `strictHintMaxInFlight` probes at once.
    ///
    /// The probe follows the direct path's metadata/loopback policy; see
    /// `blocklistAwareProbe`.
    ///
    /// No probe runs while routing is changing under the proxy (#97): in a
    /// flap hold, in direct mode (`directModeCause`), or while a transition
    /// on `routingTransitions` is in flight or finished less than
    /// `strictHintSettleWindow` ago. A failure then says nothing about the
    /// host. The host is not put on cooldown, so its next failure after the
    /// window is probed; see `reportSuppressed` for the event.
    @discardableResult
    package func probeForStrictModeHint(
        host: String,
        port: Int,
        gatewayMode: Bool,
        directModeCause: DirectModeCause = .none,
        onReachable: @escaping @Sendable () -> Void
    ) -> StrictHintProbe {
        let current = now()
        if let reason = strictHintSuppression(directModeCause: directModeCause, at: current) {
            reportSuppressed(reason, host: host, port: port, at: current)
            return .suppressed(reason)
        }
        guard !MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) else {
            reportBlocked(host: host, port: port, kind: .strictHint, reason: .blockedName)
            return .blocked
        }
        let key = host.lowercased()
        let cooldown = Self.strictHintCooldown
        let admission = lock.withLock { () -> StrictHintProbe in
            if let last = strictHintProbedAt[key], current.timeIntervalSince(last) < cooldown {
                return .coolingDown
            }
            guard strictHintInFlight < Self.strictHintMaxInFlight else {
                strictHintSkipped += 1
                return .busy
            }
            Self.makeRoom(for: key, in: &strictHintProbedAt, now: current, cooldown: cooldown, capacity: Self.strictHintCapacity)
            strictHintProbedAt[key] = current
            strictHintInFlight += 1
            probesStarted += 1
            return .started
        }
        guard admission == .started else { return admission }
        blocklistAwareProbe(
            host: host, port: port, timeoutMS: maxTimeoutMS, gatewayMode: gatewayMode, kind: .strictHint
        ).whenComplete { result in
            self.lock.withLock { self.strictHintInFlight -= 1 }
            if case .success(true) = result { onReachable() }
        }
        return .started
    }

    private func strictHintSuppression(directModeCause: DirectModeCause, at date: Date) -> StrictHintSuppression? {
        if directModeCause == .transientNetworkChange { return .flap }
        if directModeCause.isDirect { return .directMode }
        if routingTransitions?.isSettling(at: date, window: strictHintSettleWindow) == true { return .vpnTransition }
        return nil
    }

    /// Emits `routing.strict_direct_reachable_suppressed` for the first
    /// suppressed failure of each reason and transition, then at most once
    /// per `strictHintSuppressedReportInterval` while the same suppression
    /// lasts, with `suppressed=` counting the failures since the last event.
    /// One report is kept, so this cannot grow. The log line is derived
    /// from the event.
    private func reportSuppressed(_ reason: StrictHintSuppression, host: String, port: Int, at date: Date) {
        let transition = routingTransitions?.current.completed ?? 0
        let interval = Self.strictHintSuppressedReportInterval
        let count = lock.withLock { () -> Int? in
            if var report = suppressionReport, report.reason == reason, report.transition == transition,
               date.timeIntervalSince(report.at) < interval {
                report.pending += 1
                suppressionReport = report
                return nil
            }
            let sameEpisode = suppressionReport.map { $0.reason == reason && $0.transition == transition } ?? false
            let count = (sameEpisode ? suppressionReport?.pending ?? 0 : 0) + 1
            suppressionReport = SuppressionReport(reason: reason, transition: transition, at: date, pending: 0)
            return count
        }
        guard let count else { return }
        let event = RuntimeEvent(
            kind: .routing,
            event: "routing.strict_direct_reachable_suppressed",
            detail: "reason=\(reason.rawValue) host=\(host) port=\(port) suppressed=\(count)"
        )
        eventSink?(event)
        logger.log(
            .info,
            "Strict-mode hint for \(host):\(port) not probed: routing is changing under the proxy, " +
                "so the upstream failure says nothing about the host. (\(event.event): \(event.detail ?? ""))",
            category: .network
        )
    }

    /// Before inserting `key` into a bounded cooldown table: drop entries
    /// whose cooldown ran out, then the oldest, until there is room.
    private static func makeRoom(
        for key: String,
        in table: inout [String: Date],
        now: Date,
        cooldown: TimeInterval,
        capacity: Int
    ) {
        guard table[key] == nil, table.count >= capacity else { return }
        table = table.filter { now.timeIntervalSince($0.value) < cooldown }
        if table.count >= capacity, let oldest = table.min(by: { $0.value < $1.value }) {
            table.removeValue(forKey: oldest.key)
        }
    }

    /// A probe refused to connect under the blocklist, which changes what
    /// the reachability cache (and so routing) says about the host. Emits
    /// `routing.probe_blocked` at most once per host per
    /// `probeBlockedCooldown`, and derives the log line from it.
    private func reportBlocked(host: String, port: Int, kind: ProbeKind, reason: ProbeBlockReason) {
        let key = host.lowercased()
        let current = now()
        let cooldown = Self.probeBlockedCooldown
        let admitted = lock.withLock { () -> Bool in
            if let last = probeBlockedReportedAt[key], current.timeIntervalSince(last) < cooldown { return false }
            Self.makeRoom(for: key, in: &probeBlockedReportedAt, now: current, cooldown: cooldown, capacity: Self.probeBlockedCapacity)
            probeBlockedReportedAt[key] = current
            return true
        }
        let detail = "host=\(host) port=\(port) kind=\(kind.rawValue) \(reason.detail)"
        guard admitted else {
            logger.log(.debug, "\(kind.label) of \(host):\(port) skipped (metadata/loopback protection, \(reason.detail)); event rate-limited.", category: .network)
            return
        }
        let event = RuntimeEvent(kind: .routing, event: "routing.probe_blocked", detail: detail)
        eventSink?(event)
        logger.log(kind.blockedLogLevel, "\(kind.label) skipped (metadata/loopback protection). (\(event.event): \(event.detail ?? ""))", category: .network)
    }

    /// Whether `host:port` answers a direct TCP connect under the direct
    /// path's metadata/loopback policy, shared by every probe: resolve
    /// first, connect to nothing if any resolved address is blocked, then
    /// try the resolved addresses in order (no second lookup) until one
    /// connects, checking each connected peer again. One deadline of
    /// `timeoutMS` covers the lookup and every connect attempt; past it the
    /// probe answers `false` and a late lookup or connect is dropped (a
    /// `getaddrinfo` cannot be cancelled). Never fails: an unreachable,
    /// blocked or timed-out target is `false`.
    private func blocklistAwareProbe(
        host: String,
        port: Int,
        timeoutMS: Int64,
        gatewayMode: Bool,
        kind: ProbeKind
    ) -> EventLoopFuture<Bool> {
        let run = ProbeRun(
            loop: group.next(), group: group, logger: logger,
            host: host, port: port, timeoutMS: timeoutMS, gatewayMode: gatewayMode, kind: kind,
            onBlocked: { [weak self] reason in
                self?.reportBlocked(host: host, port: port, kind: kind, reason: reason)
            }
        )
        return run.start(resolving: resolveForProbe)
    }

    /// Hosts in the strict-mode hint table (bounded by `strictHintCapacity`).
    package var strictHintTableCount: Int {
        lock.withLock { strictHintProbedAt.count }
    }

    /// Cache and pending-probe key: the policy a probe ran under is part of
    /// it, so a result from outside gateway mode (or a probe still running
    /// when gateway mode came on) is never read back under gateway mode.
    private static func cacheKey(host: String, port: Int, gatewayMode: Bool) -> String {
        "\(gatewayMode ? "gateway" : "open") \(host):\(port)"
    }

    /// Synchronous cache-only check. Returns the cached reachability result
    /// if a valid (non-expired) entry probed under the same policy exists,
    /// otherwise returns nil. When nil, call `probeInBackground` to populate
    /// the cache for next time. A host the gateway blocklist refuses is never
    /// reachable.
    package func cachedReachability(host: String, port: Int, gatewayMode: Bool) -> Bool? {
        if MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) { return false }
        let key = Self.cacheKey(host: host, port: port, gatewayMode: gatewayMode)
        return lock.withLock {
            guard let entry = cache[key],
                  Date().timeIntervalSince(entry.checkedAt) < ttlSeconds else {
                return nil
            }
            return entry.reachable
        }
    }

    /// The reachability shortcut's answer for a request: the cached result,
    /// or `false` after starting a background probe to fill the cache. A
    /// blocked host is `false` and is never probed.
    package func shortcutReachable(host: String, port: Int, gatewayMode: Bool) -> Bool {
        guard !MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) else {
            reportBlocked(host: host, port: port, kind: .reachability, reason: .blockedName)
            return false
        }
        if let cached = cachedReachability(host: host, port: port, gatewayMode: gatewayMode) {
            return cached
        }
        probeInBackground(host: host, port: port, gatewayMode: gatewayMode)
        return false
    }

    /// Fire-and-forget: kicks off a TCP probe in the background to populate
    /// the cache. Deduplicates concurrent probes for the same host:port and
    /// policy.
    ///
    /// Follows the strict-mode hint's policy (#93): a host the gateway
    /// blocklist refuses is never probed, and a host that resolves to a
    /// blocked address is not connected to and caches as unreachable.
    package func probeInBackground(host: String, port: Int, gatewayMode: Bool) {
        guard !MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) else {
            reportBlocked(host: host, port: port, kind: .reachability, reason: .blockedName)
            return
        }
        let key = Self.cacheKey(host: host, port: port, gatewayMode: gatewayMode)
        let admitted = lock.withLock { () -> Int64? in
            if pendingProbes.contains(key) { return nil }
            if pendingProbes.count >= maxConcurrentProbes { return nil }
            pendingProbes.insert(key)
            probesStarted += 1
            return hostTimeouts[key] ?? baseTimeoutMS
        }
        guard let timeout = admitted else { return }

        blocklistAwareProbe(
            host: host, port: port, timeoutMS: timeout, gatewayMode: gatewayMode, kind: .reachability
        ).whenComplete { result in
            let reachable: Bool
            if case .success(true) = result { reachable = true } else { reachable = false }
            self.lock.withLock {
                self.pendingProbes.remove(key)
                self.record(reachable: reachable, key: key)
            }
            if reachable {
                self.logger.log(.debug, "Direct-connect: \(host):\(port) reachable (timeout \(timeout)ms), will bypass on next request.", category: .network)
            }
        }
    }

    /// Async probe -- blocks until the result is known. Used by background
    /// warm-up or non-hot-path callers. Same blocklist policy as
    /// `probeInBackground`.
    package func isDirectlyReachable(host: String, port: Int, gatewayMode: Bool) async -> Bool {
        guard !MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) else {
            reportBlocked(host: host, port: port, kind: .reachability, reason: .blockedName)
            return false
        }
        if let cached = cachedReachability(host: host, port: port, gatewayMode: gatewayMode) {
            return cached
        }

        let key = Self.cacheKey(host: host, port: port, gatewayMode: gatewayMode)
        let timeout = lock.withLock { () -> Int64 in
            probesStarted += 1
            return hostTimeouts[key] ?? baseTimeoutMS
        }
        let reachable: Bool
        do {
            reachable = try await blocklistAwareProbe(
                host: host, port: port, timeoutMS: timeout, gatewayMode: gatewayMode, kind: .reachability
            ).get()
        } catch {
            // `blocklistAwareProbe` answers every failure with `false`; this
            // is reached only if that ever changes.
            logger.log(.debug, "Direct-connect probe of \(host):\(port) failed: \(error.displayDescription)", category: .network)
            reachable = false
        }

        lock.withLock { record(reachable: reachable, key: key) }

        if reachable {
            logger.log(.debug, "Direct-connect: \(host):\(port) reachable (timeout \(timeout)ms), bypassing upstream.", category: .network)
        }
        return reachable
    }

    /// Caches a probe result and adapts the host's timeout. Must be called
    /// while holding `lock`.
    private func record(reachable: Bool, key: String) {
        cache[key] = CacheEntry(reachable: reachable, checkedAt: .now)
        if reachable {
            hostTimeouts[key] = baseTimeoutMS
        } else {
            hostTimeouts[key] = min((hostTimeouts[key] ?? baseTimeoutMS) * 2, maxTimeoutMS)
        }
        evictIfNeeded()
    }

    package func clearCache() {
        lock.withLock {
            cache.removeAll()
            hostTimeouts.removeAll()
            strictHintProbedAt.removeAll()
        }
    }

    /// Must be called while holding `lock`.
    private func evictIfNeeded() {
        guard cache.count > maxCacheSize else { return }
        let now = Date()
        let expiredKeys = cache.filter { now.timeIntervalSince($0.value.checkedAt) >= ttlSeconds }.map(\.key)
        for key in expiredKeys {
            cache.removeValue(forKey: key)
            hostTimeouts.removeValue(forKey: key)
        }
        while cache.count > maxCacheSize {
            guard let oldest = cache.min(by: { $0.value.checkedAt < $1.value.checkedAt }) else { break }
            cache.removeValue(forKey: oldest.key)
            hostTimeouts.removeValue(forKey: oldest.key)
        }
    }
}

/// One run of `DirectConnectDetector.blocklistAwareProbe`. All state is
/// touched only on `loop`, which is what makes `@unchecked Sendable` sound.
private final class ProbeRun: @unchecked Sendable {
    private let loop: EventLoop
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let host: String
    private let port: Int
    private let timeoutMS: Int64
    private let gatewayMode: Bool
    private let kind: DirectConnectDetector.ProbeKind
    private let onBlocked: @Sendable (DirectConnectDetector.ProbeBlockReason) -> Void
    private let promise: EventLoopPromise<Bool>
    private var deadline: Scheduled<Void>?
    private var finished = false

    init(
        loop: EventLoop,
        group: EventLoopGroup,
        logger: any LogSink,
        host: String,
        port: Int,
        timeoutMS: Int64,
        gatewayMode: Bool,
        kind: DirectConnectDetector.ProbeKind,
        onBlocked: @escaping @Sendable (DirectConnectDetector.ProbeBlockReason) -> Void
    ) {
        self.loop = loop
        self.group = group
        self.logger = logger
        self.host = host
        self.port = port
        self.timeoutMS = timeoutMS
        self.gatewayMode = gatewayMode
        self.kind = kind
        self.onBlocked = onBlocked
        self.promise = loop.makePromise(of: Bool.self)
    }

    func start(
        resolving resolve: @Sendable (String, Int, EventLoop) -> EventLoopFuture<[SocketAddress]>
    ) -> EventLoopFuture<Bool> {
        loop.execute {
            guard !self.finished else { return }
            self.deadline = self.loop.scheduleTask(in: .milliseconds(self.timeoutMS)) {
                guard !self.finished else { return }
                self.logger.log(.debug, "\(self.kind.label) of \(self.host):\(self.port): no answer within \(self.timeoutMS)ms.", category: .network)
                self.finish(false)
            }
        }
        resolve(host, port, loop).hop(to: loop).whenComplete { result in
            guard !self.finished else { return }
            switch result {
            case .failure(let error):
                self.logger.log(.debug, "\(self.kind.label) of \(self.host):\(self.port): \(error.displayDescription)", category: .network)
                self.finish(false)
            case .success(let addresses):
                if let blocked = addresses.lazy.compactMap({
                    MetadataBlocklist.blockedResolvedAddress($0, gatewayMode: self.gatewayMode)
                }).first {
                    self.onBlocked(.blockedAddress(blocked))
                    self.finish(false)
                    return
                }
                self.connect(addresses[...])
            }
        }
        return promise.futureResult
    }

    /// Tries `remaining` in order until one connects.
    private func connect(_ remaining: ArraySlice<SocketAddress>) {
        guard !finished else { return }
        guard let address = remaining.first else {
            finish(false)
            return
        }
        ClientBootstrap(group: group)
            .connectTimeout(.milliseconds(timeoutMS))
            .connect(to: address)
            .hop(to: loop)
            .whenComplete { result in
                switch result {
                case .success(let channel):
                    channel.close(mode: .all, promise: nil)
                    guard !self.finished else { return }
                    // The direct path's resolved-peer check.
                    if let ip = MetadataBlocklist.blockedResolvedAddress(channel.remoteAddress, gatewayMode: self.gatewayMode) {
                        self.onBlocked(.blockedAddress(ip))
                        self.finish(false)
                        return
                    }
                    self.finish(true)
                case .failure(let error):
                    // Unreachable is the probe's answer, not a failure to report.
                    self.logger.log(.debug, "\(self.kind.label) of \(self.host):\(self.port) via \(address): \(error.displayDescription)", category: .network)
                    self.connect(remaining.dropFirst())
                }
            }
    }

    private func finish(_ reachable: Bool) {
        guard !finished else { return }
        finished = true
        deadline?.cancel()
        promise.succeed(reachable)
    }
}
