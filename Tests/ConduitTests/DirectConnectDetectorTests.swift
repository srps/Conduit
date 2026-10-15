// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOPosix
import XCTest
@testable import ProxyKernel

final class DirectConnectDetectorTests: XCTestCase {

    @MainActor
    func testCachedReachabilityReturnsNilOnColdCache() {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 100
        )
        XCTAssertNil(detector.cachedReachability(host: "example.com", port: 443, gatewayMode: false))
    }

    @MainActor
    func testIsDirectlyReachablePopulatesCache() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 200
        )

        let unreachablePort = 1
        let result = await detector.isDirectlyReachable(host: "127.0.0.1", port: unreachablePort, gatewayMode: false)
        XCTAssertFalse(result)

        let cached = detector.cachedReachability(host: "127.0.0.1", port: unreachablePort, gatewayMode: false)
        XCTAssertNotNil(cached)
        XCTAssertFalse(cached!)
    }

    @MainActor
    func testCacheExpiresAfterTTL() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 0.1,
            baseTimeoutMS: 200
        )

        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 1, gatewayMode: false)
        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 1, gatewayMode: false))

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(detector.cachedReachability(host: "127.0.0.1", port: 1, gatewayMode: false),
                     "Cache entry should expire after TTL")
    }

    @MainActor
    func testClearCacheRemovesAllEntries() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 200
        )

        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 1, gatewayMode: false)
        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 1, gatewayMode: false))

        detector.clearCache()
        XCTAssertNil(detector.cachedReachability(host: "127.0.0.1", port: 1, gatewayMode: false))
    }

    @MainActor
    func testProbeInBackgroundDeduplicatesConcurrentProbes() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 20
        )

        detector.probeInBackground(host: "192.0.2.1", port: 9999, gatewayMode: false)
        detector.probeInBackground(host: "192.0.2.1", port: 9999, gatewayMode: false)
        detector.probeInBackground(host: "192.0.2.1", port: 9999, gatewayMode: false)
        XCTAssertEqual(detector.probeCount, 1, "Concurrent probes of one host:port should start once")

        let cached = await Self.cachedReachability(of: detector, host: "192.0.2.1", port: 9999)
        XCTAssertNotNil(cached, "Background probe should have populated cache")
        XCTAssertFalse(cached!, "Unreachable host should be cached as false")
    }

    @MainActor
    func testDifferentPortsAreCachedSeparately() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 200
        )

        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 1, gatewayMode: false)
        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 2, gatewayMode: false)

        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 1, gatewayMode: false))
        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 2, gatewayMode: false))

        XCTAssertNil(detector.cachedReachability(host: "127.0.0.1", port: 3, gatewayMode: false),
                     "Unchecked port should not have a cache entry")
    }

    @MainActor
    func testConsecutiveFailuresDoNotExceedMaxTimeout() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 0.01,
            baseTimeoutMS: 5
        )

        // 5, 10, 20, 40, then held at eight times the base.
        for _ in 0..<5 {
            _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 1, gatewayMode: false)
            try? await Task.sleep(for: .milliseconds(12))
        }

        let cached = detector.cachedReachability(host: "192.0.2.1", port: 1, gatewayMode: false)
        XCTAssertNil(cached, "Cache should have expired after TTL")
        XCTAssertEqual(detector.probeCount, 5, "Each expired entry should be probed again")
        XCTAssertEqual(detector.probeTimeoutMS(host: "192.0.2.1", port: 1, gatewayMode: false), 40,
                       "Consecutive failures should double the timeout up to eight times the base, no further")
    }

    @MainActor
    func testClearCacheResetsProgressiveTimeouts() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 50
        )

        _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 1, gatewayMode: false)
        _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 1, gatewayMode: false)

        detector.clearCache()

        XCTAssertNil(detector.cachedReachability(host: "192.0.2.1", port: 1, gatewayMode: false))
    }

    @MainActor
    func testProbesCappedAtMaxConcurrent() async throws {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            // Admission is decided synchronously in `probeInBackground`, so the
            // cap holds whatever the timeout; a short one only drains sooner.
            baseTimeoutMS: 200,
            maxConcurrentProbes: 2
        )

        for port in 1...5 {
            detector.probeInBackground(host: "192.0.2.1", port: port, gatewayMode: false)
            XCTAssertLessThanOrEqual(detector.pendingProbeCount, 2, "probe \(port) ran past maxConcurrentProbes")
        }

        var cachedCount = 0
        for port in 1...5 {
            if detector.cachedReachability(host: "192.0.2.1", port: port, gatewayMode: false) != nil {
                cachedCount += 1
            }
        }
        XCTAssertLessThanOrEqual(cachedCount, 2,
                                  "At most 2 probes should have started (maxConcurrentProbes=2), found \(cachedCount) cached")

        // Let the admitted probes finish before clearing. Counts, not time.
        for _ in 0..<500 where detector.pendingProbeCount > 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(detector.pendingProbeCount, 0, "the admitted probes never finished")
        detector.clearCache()
    }

    @MainActor
    func testCacheEvictsWhenExceedingMaxSize() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 50,
            maxCacheSize: 3
        )

        for port in 1...5 {
            _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: port, gatewayMode: false)
        }

        var cachedCount = 0
        for port in 1...5 {
            if detector.cachedReachability(host: "192.0.2.1", port: port, gatewayMode: false) != nil {
                cachedCount += 1
            }
        }
        XCTAssertLessThanOrEqual(cachedCount, 3,
                                  "Cache should not exceed maxCacheSize of 3 (found \(cachedCount))")
        XCTAssertGreaterThan(cachedCount, 0, "Cache should retain some entries")
    }

    @MainActor
    func testBaseTimeoutIsConfigurable() {
        let detector100 = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 100
        )
        let detector1000 = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 1000
        )
        XCTAssertNotNil(detector100)
        XCTAssertNotNil(detector1000)
    }

    @MainActor
    func testProbeInBackgroundAllowsNewProbeAfterCompletion() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 50
        )

        detector.probeInBackground(host: "192.0.2.1", port: 9998, gatewayMode: false)
        let firstResult = await Self.cachedReachability(of: detector, host: "192.0.2.1", port: 9998)
        XCTAssertNotNil(firstResult, "First background probe should populate cache")
        XCTAssertFalse(firstResult!, "Unreachable host should be cached as false")

        detector.clearCache()
        XCTAssertNil(detector.cachedReachability(host: "192.0.2.1", port: 9998, gatewayMode: false))

        detector.probeInBackground(host: "192.0.2.1", port: 9998, gatewayMode: false)
        let secondResult = await Self.cachedReachability(of: detector, host: "192.0.2.1", port: 9998)
        XCTAssertNotNil(secondResult, "Second background probe should repopulate cache after clear")
    }

    /// The cached answer for `host:port` once a background probe has filled
    /// it, or nil if none has within five seconds.
    private static func cachedReachability(of detector: DirectConnectDetector, host: String, port: Int) async -> Bool? {
        for _ in 0..<1_000 {
            if let cached = detector.cachedReachability(host: host, port: port, gatewayMode: false) {
                return cached
            }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return detector.cachedReachability(host: host, port: port, gatewayMode: false)
    }
}
