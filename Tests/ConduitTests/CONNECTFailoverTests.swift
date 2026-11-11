// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// One `connectUpstreamTunnel` call tries each enabled upstream at most once,
/// so an upstream that refuses cannot keep a working one from being asked.
final class CONNECTFailoverTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton

    /// The refusing upstream has a fast latency score and the working one
    /// none, so the latency chooser prefers the refusing one on every pick.
    /// The route's own pool does not count the 403, so no breaker moves it
    /// aside either.
    func testARefusingUpstreamWithTheBetterScoreDoesNotHideAWorkingOne() async throws {
        let refusing = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.pipeline.addHandler(ForbiddingUpstream()) }
            .bind(host: "127.0.0.1", port: 0).get()
        let working = try await AuthenticatingUpstream.start(group: group, answerIP: "198.51.100.30")
        var config = ProxyConfig.testFixture()
        config.upstreams = [
            UpstreamProxy(name: "refusing", host: "127.0.0.1", port: try XCTUnwrap(refusing.localAddress?.port), priority: 0),
            UpstreamProxy(name: "working", host: "127.0.0.1", port: working.port, priority: 1),
        ]
        let frozen = config
        let pool = ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { frozen },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() },
            answeredStatusAccounting: .serverErrorsOnly, label: "doh"
        )
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink())
        let refusingProxy = try XCTUnwrap(frozen.enabledUpstreams.first { $0.name == "refusing" })
        pool.recordDedicatedTunnelSuccess(for: refusingProxy, latencyMS: 5)

        let workingEndpoint = "127.0.0.1:\(working.port)"
        var endpoints: [String] = []
        for _ in 0..<4 {
            do {
                let tunnel = try await coordinator.connectUpstreamTunnel(target: "192.0.2.10:80").get()
                endpoints.append(tunnel.endpoint)
                tunnel.channel.close(promise: nil)
            } catch {
                endpoints.append("failed: \(error)")
            }
        }
        pool.closeAll(scope: .all)
        try await refusing.close().get()
        await working.stop()

        XCTAssertEqual(endpoints, Array(repeating: workingEndpoint, count: 4), "every call reached the working upstream")
        XCTAssertEqual(working.tunnelsOpened, 4)
    }
}

/// Answers every CONNECT with 403, as a proxy that blocks the target by policy.
private final class ForbiddingUpstream: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let head = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              head.contains("\r\n\r\n") else { return }
        accumulated.clear()
        var out = context.channel.allocator.buffer(capacity: 96)
        out.writeString("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}
