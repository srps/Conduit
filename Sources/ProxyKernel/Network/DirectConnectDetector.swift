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
    private let lock = NSLock()

    package struct CacheEntry {
        let reachable: Bool
        let checkedAt: Date
    }

    package init(
        group: EventLoopGroup,
        logger: any LogSink,
        ttlSeconds: TimeInterval = 300,
        baseTimeoutMS: Int64 = 500,
        maxCacheSize: Int = 512,
        maxConcurrentProbes: Int = 16
    ) {
        self.group = group
        self.logger = logger
        self.ttlSeconds = ttlSeconds
        self.baseTimeoutMS = baseTimeoutMS
        self.maxTimeoutMS = baseTimeoutMS * 8
        self.maxCacheSize = maxCacheSize
        self.maxConcurrentProbes = maxConcurrentProbes
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
        let timeout = lock.withLock { hostTimeouts[key] ?? baseTimeoutMS }
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
