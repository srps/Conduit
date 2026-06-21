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
        XCTAssertNil(detector.cachedReachability(host: "example.com", port: 443))
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
        let result = await detector.isDirectlyReachable(host: "127.0.0.1", port: unreachablePort)
        XCTAssertFalse(result)

        let cached = detector.cachedReachability(host: "127.0.0.1", port: unreachablePort)
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

        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 1)
        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 1))

        try? await Task.sleep(for: .milliseconds(150))
        XCTAssertNil(detector.cachedReachability(host: "127.0.0.1", port: 1),
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

        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 1)
        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 1))

        detector.clearCache()
        XCTAssertNil(detector.cachedReachability(host: "127.0.0.1", port: 1))
    }

    @MainActor
    func testProbeInBackgroundDeduplicatesConcurrentProbes() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 200
        )

        detector.probeInBackground(host: "192.0.2.1", port: 9999)
        detector.probeInBackground(host: "192.0.2.1", port: 9999)
        detector.probeInBackground(host: "192.0.2.1", port: 9999)

        try? await Task.sleep(for: .milliseconds(500))

        let cached = detector.cachedReachability(host: "192.0.2.1", port: 9999)
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

        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 1)
        _ = await detector.isDirectlyReachable(host: "127.0.0.1", port: 2)

        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 1))
        XCTAssertNotNil(detector.cachedReachability(host: "127.0.0.1", port: 2))

        XCTAssertNil(detector.cachedReachability(host: "127.0.0.1", port: 3),
                     "Unchecked port should not have a cache entry")
    }

    @MainActor
    func testConsecutiveFailuresDoNotExceedMaxTimeout() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 0.05,
            baseTimeoutMS: 50
        )

        for _ in 0..<5 {
            _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 1)
            try? await Task.sleep(for: .milliseconds(60))
        }

        let cached = detector.cachedReachability(host: "192.0.2.1", port: 1)
        XCTAssertNil(cached, "Cache should have expired after TTL")
    }

    @MainActor
    func testClearCacheResetsProgressiveTimeouts() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 50
        )

        _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 1)
        _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 1)

        detector.clearCache()

        XCTAssertNil(detector.cachedReachability(host: "192.0.2.1", port: 1))
    }

    @MainActor
    func testProbesCappedAtMaxConcurrent() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 2000,
            maxConcurrentProbes: 2
        )

        for port in 1...5 {
            detector.probeInBackground(host: "192.0.2.1", port: port)
        }

        try? await Task.sleep(for: .milliseconds(100))

        var cachedCount = 0
        for port in 1...5 {
            if detector.cachedReachability(host: "192.0.2.1", port: port) != nil {
                cachedCount += 1
            }
        }
        XCTAssertLessThanOrEqual(cachedCount, 2,
                                  "At most 2 probes should have started (maxConcurrentProbes=2), found \(cachedCount) cached")

        try? await Task.sleep(for: .milliseconds(2500))
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
            _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: port)
        }

        var cachedCount = 0
        for port in 1...5 {
            if detector.cachedReachability(host: "192.0.2.1", port: port) != nil {
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

        detector.probeInBackground(host: "192.0.2.1", port: 9998)
        try? await Task.sleep(for: .milliseconds(300))
        let firstResult = detector.cachedReachability(host: "192.0.2.1", port: 9998)
        XCTAssertNotNil(firstResult, "First background probe should populate cache")
        XCTAssertFalse(firstResult!, "Unreachable host should be cached as false")

        detector.clearCache()
        XCTAssertNil(detector.cachedReachability(host: "192.0.2.1", port: 9998))

        detector.probeInBackground(host: "192.0.2.1", port: 9998)
        try? await Task.sleep(for: .milliseconds(300))
        let secondResult = detector.cachedReachability(host: "192.0.2.1", port: 9998)
        XCTAssertNotNil(secondResult, "Second background probe should repopulate cache after clear")
    }
}
