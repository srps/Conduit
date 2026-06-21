// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class UpstreamProberTests: XCTestCase {
    @MainActor func testProbeAllReturnsResultsForEachProxy() async {
        let logger = DiscardingLogSink()
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: logger, timeoutSeconds: 1)

        let proxies = [
            UpstreamProxy(name: "A", host: "127.0.0.1", port: 1, priority: 0),
            UpstreamProxy(name: "B", host: "127.0.0.1", port: 2, priority: 1)
        ]

        let results = await prober.probeAll(proxies)
        XCTAssertEqual(results.count, 2)
    }

    @MainActor func testSummarizeDoesNotMutatePriorities() async {
        let logger = DiscardingLogSink()
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: logger, timeoutSeconds: 1)

        let proxies = [
            UpstreamProxy(name: "A", host: "192.0.2.1", port: 9999, priority: 5),
            UpstreamProxy(name: "B", host: "192.0.2.2", port: 9999, priority: 10)
        ]

        _ = await prober.summarize(proxies)
        XCTAssertEqual(proxies.map(\.priority), [5, 10], "Probing must not rewrite manual priorities")
    }

    @MainActor func testProxyAuthenticateResponseCountsAsReachableProxy() async throws {
        let serverChannel = try await makeStaticResponseServer(
            "HTTP/1.1 407 Proxy Authentication Required\r\n" +
            "Proxy-Authenticate: Negotiate\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        )
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), timeoutSeconds: 1)
        let summary = await prober.summarize([
            UpstreamProxy(name: "Proxy", host: "127.0.0.1", port: port, priority: 0)
        ])

        XCTAssertTrue(summary.hasReachableUpstream)
    }

    @MainActor func testBadRequestResponseDoesNotCountAsUsableProxy() async throws {
        let serverChannel = try await makeStaticResponseServer(
            "HTTP/1.1 400 Bad Request\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        )
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), timeoutSeconds: 1)
        let summary = await prober.summarize([
            UpstreamProxy(name: "Not a proxy", host: "127.0.0.1", port: port, priority: 0)
        ])

        XCTAssertFalse(summary.hasReachableUpstream)
    }

    @MainActor func testServiceUnavailableResponseDoesNotCountAsUsableProxy() async throws {
        let serverChannel = try await makeStaticResponseServer(
            "HTTP/1.1 503 Service Unavailable\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        )
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        let prober = UpstreamProber(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), timeoutSeconds: 1)
        let summary = await prober.summarize([
            UpstreamProxy(name: "Overloaded proxy", host: "127.0.0.1", port: port, priority: 0)
        ])

        XCTAssertFalse(summary.hasReachableUpstream)
    }

    @MainActor func testSilentUpstreamIsBoundedByTimeoutSeconds() async throws {
        let serverChannel = try await makeSilentServer()
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        let timeoutSeconds: TimeInterval = 1
        let prober = UpstreamProber(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            timeoutSeconds: timeoutSeconds
        )

        let start = DispatchTime.now()
        let summary = await prober.summarize([
            UpstreamProxy(name: "Silent", host: "127.0.0.1", port: port, priority: 0)
        ])
        let elapsedSeconds = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000

        XCTAssertFalse(summary.hasReachableUpstream)
        XCTAssertLessThan(
            elapsedSeconds,
            timeoutSeconds * 2,
            "Probe should be bounded by timeoutSeconds, not connectTimeout + responseTimeout"
        )
    }

    @MainActor func testOversizedResponseDoesNotAccumulateUnbounded() async throws {
        // 256 KiB without a header terminator is well beyond `maxAccumulatedBytes`
        // and represents a clearly misbehaving upstream rather than a realistic
        // response head (legitimate CONNECT responses, including those carrying
        // multi-KB Kerberos / Negotiate challenges, stay comfortably under the cap).
        let payloadByteCount = 256 * 1024
        let serverChannel = try await makeStaticResponseServer(
            String(repeating: "A", count: payloadByteCount)
        )
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        let prober = UpstreamProber(
            group: MultiThreadedEventLoopGroup.singleton,
            logger: DiscardingLogSink(),
            timeoutSeconds: 1
        )
        let summary = await prober.summarize([
            UpstreamProxy(name: "Misbehaving", host: "127.0.0.1", port: port, priority: 0)
        ])

        XCTAssertFalse(summary.hasReachableUpstream)
    }

    @MainActor
    private func makeStaticResponseServer(_ response: String) async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(UpstreamProberStaticResponseHandler(response: response))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    @MainActor
    private func makeSilentServer() async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.eventLoop.makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }
}

private final class UpstreamProberStaticResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let response: String
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    init(response: String) {
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let request = accumulated.getString(
            at: accumulated.readerIndex,
            length: accumulated.readableBytes
        ), request.contains("\r\n\r\n") else {
            return
        }

        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        accumulated.clear()
    }
}
