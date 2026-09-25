// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix

package final class DirectConnectDetector: @unchecked Sendable {
    private let group: EventLoopGroup
    private let logger: any LogSink
    private let ttlSeconds: TimeInterval
    private let baseTimeoutMS: Int64
    private let maxTimeoutMS: Int64
    private let maxCacheSize: Int
    private let maxConcurrentProbes: Int
    private var cache: [String: CacheEntry] = [:]
    private var hostTimeouts: [String: Int64] = [:]
    private var pendingProbes: Set<String> = []
    /// Host → when a strict-mode hint probe last ran; see `probeForStrictModeHint`.
    private var strictHintProbedAt: [String: Date] = [:]
    private var strictHintInFlight = 0
    private var strictHintSkipped = 0
    private var probesStarted = 0
    private let now: @Sendable () -> Date
    private let resolveForHint: @Sendable (String, Int, EventLoop) -> EventLoopFuture<[SocketAddress]>
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

    /// Why `probeForStrictModeHint` did or did not start a probe.
    package enum StrictHintProbe: Equatable, Sendable {
        case started
        /// The host was probed within `strictHintCooldown`.
        case coolingDown
        /// `strictHintMaxInFlight` probes are already running.
        case busy
        /// The host is on the metadata/loopback blocklist (gateway mode).
        case blocked
    }

    package struct CacheEntry {
        let reachable: Bool
        let checkedAt: Date
    }

    /// - Parameter hintResolver: how the strict-mode hint resolves a host
    ///   before it connects, so every resolved address can be checked against
    ///   the blocklist first. Tests inject one; the default asks
    ///   `AddressFamilyAwareResolver` for A, then AAAA, records.
    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        ttlSeconds: TimeInterval = 300,
        baseTimeoutMS: Int64 = 500,
        maxCacheSize: Int = 512,
        maxConcurrentProbes: Int = 16,
        now: @escaping @Sendable () -> Date = { Date() },
        hintResolver: (@Sendable (String, Int, EventLoop) -> EventLoopFuture<[SocketAddress]>)? = nil
    ) {
        self.group = group
        self.logger = logger
        self.ttlSeconds = ttlSeconds
        self.baseTimeoutMS = baseTimeoutMS
        self.maxTimeoutMS = baseTimeoutMS * 8
        self.maxCacheSize = maxCacheSize
        self.maxConcurrentProbes = maxConcurrentProbes
        self.now = now
        self.resolveForHint = hintResolver ?? { host, port, loop in
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

    /// Strict-mode hint probes running now (at most `strictHintMaxInFlight`).
    package var strictHintInFlightCount: Int {
        lock.withLock { strictHintInFlight }
    }

    /// Strict-mode hints skipped because `strictHintMaxInFlight` probes were running.
    package var strictHintSkippedCount: Int {
        lock.withLock { strictHintSkipped }
    }

    /// After a strict-mode request failed through the upstream: probe
    /// `host:port` directly once, and call `onReachable` if it answers, so
    /// the caller can suggest a No-proxy entry. The request itself is never
    /// retried directly. At most one probe per host per `strictHintCooldown`,
    /// in a table of at most `strictHintCapacity` hosts, and at most
    /// `strictHintMaxInFlight` probes at once.
    ///
    /// The probe follows the direct path's metadata/loopback policy: a
    /// blocked host name is never probed, and a host is resolved first and
    /// not connected to at all if any address is blocked. The connected peer
    /// is checked again, the same way the direct path checks it, before it
    /// counts as reachable.
    @discardableResult
    package func probeForStrictModeHint(
        host: String,
        port: Int,
        gatewayMode: Bool,
        onReachable: @escaping @Sendable () -> Void
    ) -> StrictHintProbe {
        guard !MetadataBlocklist.isBlocked(host: host, gatewayMode: gatewayMode) else { return .blocked }
        let key = host.lowercased()
        let current = now()
        let cooldown = Self.strictHintCooldown
        let admission = lock.withLock { () -> StrictHintProbe in
            if let last = strictHintProbedAt[key], current.timeIntervalSince(last) < cooldown {
                return .coolingDown
            }
            guard strictHintInFlight < Self.strictHintMaxInFlight else {
                strictHintSkipped += 1
                return .busy
            }
            if strictHintProbedAt[key] == nil, strictHintProbedAt.count >= Self.strictHintCapacity {
                strictHintProbedAt = strictHintProbedAt.filter { current.timeIntervalSince($0.value) < cooldown }
                if strictHintProbedAt.count >= Self.strictHintCapacity,
                   let oldest = strictHintProbedAt.min(by: { $0.value < $1.value }) {
                    strictHintProbedAt.removeValue(forKey: oldest.key)
                }
            }
            strictHintProbedAt[key] = current
            strictHintInFlight += 1
            probesStarted += 1
            return .started
        }
        guard admission == .started else { return admission }
        hintProbe(host: host, port: port, gatewayMode: gatewayMode).whenComplete { result in
            self.lock.withLock { self.strictHintInFlight -= 1 }
            if case .success(true) = result { onReachable() }
        }
        return .started
    }

    /// Whether `host:port` answers a direct TCP connect under the blocklist
    /// policy. Never fails: an unreachable or blocked target is `false`.
    private func hintProbe(host: String, port: Int, gatewayMode: Bool) -> EventLoopFuture<Bool> {
        let loop = group.next()
        let group = self.group
        let logger = self.logger
        let timeout = maxTimeoutMS
        return resolveForHint(host, port, loop).hop(to: loop).flatMap { addresses -> EventLoopFuture<Bool> in
            if let blocked = addresses.lazy.compactMap({
                MetadataBlocklist.blockedResolvedAddress($0, gatewayMode: gatewayMode)
            }).first {
                logger.log(.info, "Strict-mode hint for \(host):\(port) skipped: it resolves to \(blocked) (metadata/loopback protection).", category: .network)
                return loop.makeSucceededFuture(false)
            }
            guard let address = addresses.first else { return loop.makeSucceededFuture(false) }
            return ClientBootstrap(group: group)
                .connectTimeout(.milliseconds(timeout))
                .connect(to: address)
                .hop(to: loop)
                .flatMapThrowing { channel in
                    defer { channel.close(mode: .all, promise: nil) }
                    // The direct path's resolved-peer check.
                    if let ip = MetadataBlocklist.blockedResolvedAddress(channel.remoteAddress, gatewayMode: gatewayMode) {
                        throw MetadataBlocklist.BlockedAddressError(host: host, resolvedIP: ip)
                    }
                    return true
                }
        }
        .flatMapError { error in
            // Unreachable is the probe's answer, not a failure to report.
            logger.log(.debug, "Strict-mode hint probe of \(host):\(port): \(error.displayDescription)", category: .network)
            return loop.makeSucceededFuture(false)
        }
    }

    /// Hosts in the strict-mode hint table (bounded by `strictHintCapacity`).
    package var strictHintTableCount: Int {
        lock.withLock { strictHintProbedAt.count }
    }

    /// Synchronous cache-only check. Returns the cached reachability result
    /// if a valid (non-expired) entry exists, otherwise returns nil.
    /// When nil, call `probeInBackground` to populate the cache for next time.
    package func cachedReachability(host: String, port: Int) -> Bool? {
        let key = "\(host):\(port)"
        return lock.withLock {
            guard let entry = cache[key],
                  Date().timeIntervalSince(entry.checkedAt) < ttlSeconds else {
                return nil
            }
            return entry.reachable
        }
    }

    /// Fire-and-forget: kicks off a TCP probe in the background to populate
    /// the cache. Deduplicates concurrent probes for the same host:port.
    package func probeInBackground(host: String, port: Int) {
        let key = "\(host):\(port)"
        let shouldProbe = lock.withLock {
            if pendingProbes.contains(key) { return false }
            if pendingProbes.count >= maxConcurrentProbes { return false }
            pendingProbes.insert(key)
            probesStarted += 1
            return true
        }
        guard shouldProbe else { return }

        Task {
            let timeout = lock.withLock { hostTimeouts[key] ?? baseTimeoutMS }
            let reachable = await probe(host: host, port: port, timeoutMS: timeout)

            lock.withLock {
                cache[key] = CacheEntry(reachable: reachable, checkedAt: .now)
                pendingProbes.remove(key)
                if reachable {
                    hostTimeouts[key] = baseTimeoutMS
                } else {
                    let next = min((hostTimeouts[key] ?? baseTimeoutMS) * 2, maxTimeoutMS)
                    hostTimeouts[key] = next
                }
                evictIfNeeded()
            }

            if reachable {
                logger.log(.debug, "Direct-connect: \(key) reachable (timeout \(timeout)ms), will bypass on next request.", category: .network)
            }
        }
    }

    /// Async probe -- blocks until the result is known. Used by background
    /// warm-up or non-hot-path callers.
    package func isDirectlyReachable(host: String, port: Int) async -> Bool {
        if let cached = cachedReachability(host: host, port: port) {
            return cached
        }

        let key = "\(host):\(port)"
        let timeout = lock.withLock { () -> Int64 in
            probesStarted += 1
            return hostTimeouts[key] ?? baseTimeoutMS
        }
        let reachable = await probe(host: host, port: port, timeoutMS: timeout)

        lock.withLock {
            cache[key] = CacheEntry(reachable: reachable, checkedAt: .now)
            if reachable {
                hostTimeouts[key] = baseTimeoutMS
            } else {
                let next = min((hostTimeouts[key] ?? baseTimeoutMS) * 2, maxTimeoutMS)
                hostTimeouts[key] = next
            }
            evictIfNeeded()
        }

        if reachable {
            logger.log(.debug, "Direct-connect: \(key) reachable (timeout \(timeout)ms), bypassing upstream.", category: .network)
        }
        return reachable
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

    private func probe(host: String, port: Int, timeoutMS: Int64) async -> Bool {
        do {
            let channel = try await ClientBootstrap(group: group)
                .resolver(AddressFamilyAwareResolver(group: group))
                .connectTimeout(.milliseconds(timeoutMS))
                .connect(host: host, port: port)
                .get()
            channel.close(mode: .all, promise: nil)
            return true
        } catch {
            return false
        }
    }
}
