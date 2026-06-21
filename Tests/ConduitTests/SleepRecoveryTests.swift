// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

private final class ResultCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

private final class ProbeableProxyResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let request = accumulated.getString(
            at: accumulated.readerIndex,
            length: accumulated.readableBytes
        ), request.contains("\r\n\r\n") else {
            return
        }

        let response =
            "HTTP/1.1 407 Proxy Authentication Required\r\n" +
            "Proxy-Authenticate: Negotiate\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        accumulated.clear()
    }
}

final class SleepRecoveryTests: XCTestCase {

    // MARK: - UpstreamProbeSummary

    func testSummaryReportsNoReachableWhenAllFail() {
        let results = [
            ProbeResult(proxy: .init(name: "A", host: "192.0.2.1", port: 8080, priority: 0), latencyMS: 3000, reachable: false),
            ProbeResult(proxy: .init(name: "B", host: "192.0.2.2", port: 8080, priority: 1), latencyMS: 3000, reachable: false),
        ]
        let summary = UpstreamProbeSummary(results: results)
        XCTAssertFalse(summary.hasReachableUpstream)
        XCTAssertNil(summary.bestReachableUpstream)
    }

    func testSummaryReportsReachableWhenAtLeastOneSucceeds() {
        let results = [
            ProbeResult(proxy: .init(name: "A", host: "192.0.2.1", port: 8080, priority: 0), latencyMS: 3000, reachable: false),
            ProbeResult(proxy: .init(name: "B", host: "192.0.2.2", port: 8080, priority: 1), latencyMS: 200, reachable: true),
        ]
        let summary = UpstreamProbeSummary(results: results)
        XCTAssertTrue(summary.hasReachableUpstream)
        XCTAssertEqual(summary.bestReachableUpstream?.host, "192.0.2.2")
    }

    // MARK: - DirectConnectDetector cache invalidation on wake

    @MainActor
    func testClearCacheInvalidatesStaleDirectEntries() async {
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            ttlSeconds: 60,
            baseTimeoutMS: 50
        )

        _ = await detector.isDirectlyReachable(host: "192.0.2.1", port: 443)
        XCTAssertNotNil(detector.cachedReachability(host: "192.0.2.1", port: 443),
                        "Should have a cached entry before clear")

        detector.clearCache()

        XCTAssertNil(detector.cachedReachability(host: "192.0.2.1", port: 443),
                     "clearCache (called on wake) should remove all stale entries")
    }

    // MARK: - UpstreamProber recovery simulation

    @MainActor
    func testProberDetectsRecoveryWhenUpstreamBecomesReachable() async throws {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup.singleton

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ProbeableProxyResponseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = serverChannel.localAddress!.port!

        let proxies = [
            UpstreamProxy(name: "Upstream", host: "127.0.0.1", port: port, priority: 0)
        ]

        let prober = UpstreamProber(group: group, logger: logger, timeoutSeconds: 2)
        let summary = await prober.summarize(proxies)

        try await serverChannel.close()

        XCTAssertTrue(summary.hasReachableUpstream,
                      "Prober should detect the upstream as reachable after 'recovery'")
    }

    @MainActor
    func testProberReportsUnreachableForDeadUpstreams() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup.singleton

        let proxies = [
            UpstreamProxy(name: "Dead", host: "192.0.2.1", port: 9999, priority: 0)
        ]

        let prober = UpstreamProber(group: group, logger: logger, timeoutSeconds: 1)
        let summary = await prober.summarize(proxies)

        XCTAssertFalse(summary.hasReachableUpstream,
                       "Prober should report no reachable upstream when all are dead")
    }

    // MARK: - Simulated direct→proxy recovery cycle

    @MainActor
    func testDirectModeFlagTogglesWithProbeResults() async throws {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup.singleton
        let prober = UpstreamProber(group: group, logger: logger, timeoutSeconds: 1)

        let proxies = [
            UpstreamProxy(name: "Dead", host: "192.0.2.1", port: 9999, priority: 0)
        ]

        let deadSummary = await prober.summarize(proxies)
        var directMode = !deadSummary.hasReachableUpstream
        XCTAssertTrue(directMode, "Should enter direct mode when upstreams unreachable")

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ProbeableProxyResponseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = serverChannel.localAddress!.port!

        let recoveredProxies = [
            UpstreamProxy(name: "Recovered", host: "127.0.0.1", port: port, priority: 0)
        ]

        let liveSummary = await prober.summarize(recoveredProxies)
        directMode = !liveSummary.hasReachableUpstream

        try await serverChannel.close()

        XCTAssertFalse(directMode, "Should exit direct mode when upstream becomes reachable")
        XCTAssertEqual(liveSummary.bestReachableUpstream?.host, "127.0.0.1")
    }

    // MARK: - Health checker behavior in direct mode

    func testHealthCheckerCanBeStoppedAndRestarted() async throws {
        let checker = HealthChecker()
        let counter = ResultCounter()

        checker.start(interval: 0.05) {
            HealthCheckResult(healthy: false, summary: "down", activeUpstream: nil, responseTimeMS: 0)
        } onResult: { _ in
            counter.increment()
        }

        try await Task.sleep(for: .milliseconds(200))
        checker.stop()
        XCTAssertGreaterThan(counter.value, 0, "Should have received results before stop")

        let restartCounter = ResultCounter()

        checker.start(interval: 0.05) {
            HealthCheckResult(healthy: true, summary: "up", activeUpstream: "proxy:8080", responseTimeMS: 10)
        } onResult: { _ in
            restartCounter.increment()
        }

        try await Task.sleep(for: .milliseconds(200))
        checker.stop()
        XCTAssertGreaterThan(restartCounter.value, 0,
                             "After restart (simulating exit from direct mode), health checker should deliver results")
    }

    // MARK: - NetworkMonitor fires on path changes

    func testNetworkMonitorCallsOnChange() async throws {
        let monitor = NetworkMonitor()
        let expectation = XCTestExpectation(description: "onChange called")
        monitor.onChange = { _, _ in
            expectation.fulfill()
        }
        monitor.start()

        await fulfillment(of: [expectation], timeout: 3.0)
        monitor.stop()
    }
}
