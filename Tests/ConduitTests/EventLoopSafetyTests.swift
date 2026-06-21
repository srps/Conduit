// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class EventLoopSafetyTests: XCTestCase {

    // MARK: - ConnectionPool event loop properties

    @MainActor
    func testConnectionPoolExposesEventLoop() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let config = ProxyConfig.testFixture()

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        XCTAssertNotNil(pool.eventLoop)
        pool.closeAll()
    }

    @MainActor
    func testConnectionPoolEnabledUpstreamCount() {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        var config = ProxyConfig.testFixture()

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        XCTAssertEqual(pool.enabledUpstreamCount, 3)

        config.upstreams[0].enabled = false
        let pool2 = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        XCTAssertEqual(pool2.enabledUpstreamCount, 2)

        pool.closeAll()
        pool2.closeAll()
    }

    // MARK: - Hop-to-eventLoop patterns

    @MainActor
    func testFutureHopPreservesValue() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let el1 = group.next()
        let el2 = group.next()

        let promise = el1.makePromise(of: String.self)
        let hopped = promise.futureResult.hop(to: el2)

        promise.succeed("hello")

        let result = try await hopped.get()
        XCTAssertEqual(result, "hello")
    }

    @MainActor
    func testFutureHopPreservesError() async {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        let el1 = group.next()
        let el2 = group.next()

        let promise = el1.makePromise(of: String.self)
        let hopped = promise.futureResult.hop(to: el2)

        promise.fail(ConnectionPoolError.invalidResponse)

        do {
            _ = try await hopped.get()
            XCTFail("Should have thrown")
        } catch {
            XCTAssertTrue(error is ConnectionPoolError)
        }
    }

    // MARK: - DirectHTTPResponseForwarder cross-channel safety

    func testForwarderWritesToClientChannelFromUpstreamEL() throws {
        let loop = EmbeddedEventLoop()
        let clientChannel = EmbeddedChannel(loop: loop)
        try clientChannel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())

        let completed = XCTestExpectation(description: "forwarder completed")
        let forwarder = DirectHTTPResponseForwarder(
            clientChannel: clientChannel,
            onComplete: { completed.fulfill() },
            onError: { _ in XCTFail("Should not error") }
        )

        let upstreamChannel = EmbeddedChannel(handlers: [forwarder], loop: loop)

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "2"])
        try upstreamChannel.writeInbound(HTTPClientResponsePart.head(head))

        var buf = upstreamChannel.allocator.buffer(capacity: 2)
        buf.writeString("OK")
        try upstreamChannel.writeInbound(HTTPClientResponsePart.body(buf))
        try upstreamChannel.writeInbound(HTTPClientResponsePart.end(nil))

        var totalBytes = 0
        while let out: ByteBuffer = try clientChannel.readOutbound() {
            totalBytes += out.readableBytes
        }
        XCTAssertGreaterThan(totalBytes, 0)

        wait(for: [completed], timeout: 1.0)
        try? clientChannel.close().wait()
        try? upstreamChannel.close().wait()
    }

    // MARK: - ClientIPFilter with EmbeddedChannel

    @MainActor
    func testClientIPFilterDoesNotCrashWithNilRemoteAddress() throws {
        let filter = ClientIPFilter(allowedIPs: ["127.0.0.1"], logger: DiscardingLogSink())
        let channel = EmbeddedChannel(handler: filter)
        XCTAssertNotNil(channel.pipeline)
        try? channel.close().wait()
    }

    // MARK: - NoProxyMatcher thread safety (stateless)

    func testNoProxyMatcherIsConcurrentSafe() async {
        let patterns = ["localhost", "*.local", "10.*"]
        let forceProxy = ["10.0.0.1"]

        await withTaskGroup(of: Bool.self) { group in
            for i in 0..<100 {
                group.addTask {
                    let host = i % 2 == 0 ? "localhost" : "external.com"
                    return NoProxyMatcher.shouldBypass(host: host, patterns: patterns, forceProxy: forceProxy)
                }
            }
            var results: [Bool] = []
            for await result in group {
                results.append(result)
            }
            XCTAssertEqual(results.count, 100)
        }
    }
}
