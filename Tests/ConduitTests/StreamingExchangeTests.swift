// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class StreamingExchangeTests: XCTestCase {

    // MARK: - StreamingExchangeResult type

    func testStreamingExchangeResultStoresUpstream() {
        let proxy = UpstreamProxy(name: "Test", host: "proxy.example.com", port: 8080, priority: 0)
        let result = StreamingExchangeResult(upstream: proxy, keepAlive: true)
        XCTAssertEqual(result.upstream.host, "proxy.example.com")
        XCTAssertTrue(result.keepAlive)
    }

    func testStreamingExchangeResultKeepAliveFalse() {
        let proxy = UpstreamProxy(name: "Test", host: "proxy.example.com", port: 8080, priority: 0)
        let result = StreamingExchangeResult(upstream: proxy, keepAlive: false)
        XCTAssertFalse(result.keepAlive)
    }

    // MARK: - Pool exhaustion error

    func testPoolExhaustedError() {
        let error = ConnectionPoolError.poolExhausted
        XCTAssertEqual(error.errorDescription, "Maximum upstream connections reached.")
    }

    func testPoolExhaustedClassifier() {
        XCTAssertTrue(ConnectionPoolError.isPoolExhausted(ConnectionPoolError.poolExhausted))
        XCTAssertTrue(ConnectionPoolError.isLocalNonUpstreamFailure(ConnectionPoolError.poolExhausted))
        XCTAssertFalse(ConnectionPoolError.isPoolExhausted(ConnectionPoolError.upstreamResponseTimedOut))
    }

    func testAllConnectionPoolErrorsHaveDescriptions() {
        let errors: [ConnectionPoolError] = [
            .noUpstreamsConfigured,
            .authenticationUnavailable,
            .authenticationRejected,
            .invalidResponse,
            .poolExhausted,
            .bodyTooLargeForReplay,
            .authHandshakeLimitExceeded,
            .streamingResponseInterrupted,
            .upstreamResponseTimedOut,
            .upstreamReturnedStatus(503, target: "example.com:443")
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription, "Missing description for \(error)")
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    // MARK: - Streaming exchange requires upstreams

    @MainActor
    func testStreamingExchangeFailsWithNoUpstreams() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var config = ProxyConfig.testFixture()
        config.upstreams = []

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        let clientChannel = EmbeddedChannel()
        addTeardownBlock { try? clientChannel.close().wait() }

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        do {
            _ = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
            XCTFail("Should have thrown noUpstreamsConfigured")
        } catch {
            // Expected
        }

    }

    // MARK: - Buffered exchange still works (health check regression)

    @MainActor
    func testBufferedExchangeStillExists() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var config = ProxyConfig.testFixture()
        config.upstreams = []

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )

        let head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://example.com/")
        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("Should have thrown noUpstreamsConfigured")
        } catch {
            // Expected - the important thing is exchange() still compiles and works
        }
    }

    // MARK: - Max connections config

    func testMaxConnectionsDefaultValue() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.maxConnections, 5000)
    }

    // MARK: - DirectHTTPResponseForwarder

    func testForwarderStreamsHeadBodyEnd() throws {
        let loop = EmbeddedEventLoop()
        let clientChannel = EmbeddedChannel(loop: loop)
        try clientChannel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())

        let completed = XCTestExpectation(description: "completed")
        let forwarder = DirectHTTPResponseForwarder(
            clientChannel: clientChannel,
            onComplete: { completed.fulfill() },
            onError: { _ in XCTFail("Should not error") }
        )

        let upstreamChannel = EmbeddedChannel(handlers: [forwarder], loop: loop)

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: ["Content-Length": "5"])
        try upstreamChannel.writeInbound(HTTPClientResponsePart.head(head))

        var bodyBuf = upstreamChannel.allocator.buffer(capacity: 5)
        bodyBuf.writeString("hello")
        try upstreamChannel.writeInbound(HTTPClientResponsePart.body(bodyBuf))

        try upstreamChannel.writeInbound(HTTPClientResponsePart.end(nil))

        var totalBytes = 0
        while let out: ByteBuffer = try clientChannel.readOutbound() {
            totalBytes += out.readableBytes
        }
        XCTAssertGreaterThan(totalBytes, 0, "Client channel should have received response bytes")

        wait(for: [completed], timeout: 1.0)
        try? clientChannel.close().wait()
        try? upstreamChannel.close().wait()
    }

    func testForwarderReportsErrorOnUpstreamFailure() throws {
        let loop = EmbeddedEventLoop()
        let clientChannel = EmbeddedChannel(loop: loop)

        let errored = XCTestExpectation(description: "error reported")
        let forwarder = DirectHTTPResponseForwarder(
            clientChannel: clientChannel,
            onComplete: { XCTFail("Should not complete") },
            onError: { _ in errored.fulfill() }
        )

        let upstreamChannel = EmbeddedChannel(handlers: [forwarder], loop: loop)

        struct SimulatedError: Error {}
        upstreamChannel.pipeline.fireErrorCaught(SimulatedError())

        wait(for: [errored], timeout: 1.0)
        try? clientChannel.close().wait()
        try? upstreamChannel.close().wait()
    }

    func testForwarderResumesUpstreamWhenClientBecomesWritable() throws {
        let loop = EmbeddedEventLoop()
        let clientChannel = EmbeddedChannel(loop: loop)
        try clientChannel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())

        let forwarder = DirectHTTPResponseForwarder(
            clientChannel: clientChannel,
            onComplete: {},
            onError: { _ in XCTFail("Should not error") }
        )
        let upstreamChannel = EmbeddedChannel(handlers: [forwarder], loop: loop)

        try upstreamChannel.setOption(ChannelOptions.autoRead, value: false).wait()
        clientChannel.pipeline.fireChannelWritabilityChanged()

        let resumedAutoRead = try upstreamChannel.getOption(ChannelOptions.autoRead).wait()
        XCTAssertTrue(resumedAutoRead, "Client writability recovery should resume upstream reads")

        try? clientChannel.close().wait()
        try? upstreamChannel.close().wait()
    }
}
