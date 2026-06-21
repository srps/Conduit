// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

final class ConnectTimeoutTests: XCTestCase {

    // MARK: - Connect timeout on unreachable upstream

    @MainActor
    func testConnectionToUnreachableHostTimesOut() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var modifiedConfig = ProxyConfig.testFixture()
        modifiedConfig.connectionCheckTimeoutMS = 200
        modifiedConfig.upstreams = [
            UpstreamProxy(name: "Unreachable", host: "192.0.2.1", port: 9999, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { modifiedConfig },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
            }
        )

        let start = Date()
        let head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://example.com/")
        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("Should have failed to connect")
        } catch {
            let elapsed = Date().timeIntervalSince(start)
            XCTAssertLessThan(elapsed, 3, "Connection should time out within 200ms + overhead, not hang")
        }

        pool.closeAll()
    }

    // MARK: - CONNECTCoordinator has connectUpstreamTunnel

    @MainActor
    func testConnectUpstreamTunnelFailsWithNoUpstreams() async {
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

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials },
            logger: logger
        )

        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }
    }

    // MARK: - Buffer overflow protection (SEC-6)

    @MainActor
    func testCONNECTHandshakeRejectsOversizedResponse() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(OversizedResponseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let port = serverChannel.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 2000
        config.upstreams = [
            UpstreamProxy(name: "Overflow", host: "127.0.0.1", port: port, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
            }
        )

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
            },
            logger: DiscardingLogSink()
        )

        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            XCTFail("Should have failed due to oversized response")
        } catch {
            // Expected -- handler rejects responses > 64KB without complete headers
        }

        pool.closeAll()
        try? await serverChannel.close().get()
    }

    @MainActor
    func testCONNECTHandshakeTimesOutWhenUpstreamAcceptsButDoesNotRespond() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BlackholeResponseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let port = serverChannel.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 2000
        config.stalledConnectionTimeoutSeconds = 60
        config.upstreamResponseTimeoutSeconds = 0.2
        config.upstreams = [
            UpstreamProxy(name: "Blackhole", host: "127.0.0.1", port: port, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in StaticAuthenticator() }
        )

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in StaticAuthenticator() },
            logger: DiscardingLogSink()
        )

        let start = Date()
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            XCTFail("CONNECT should fail when the upstream accepts TCP but never responds")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "CONNECT handshake must not hang indefinitely")
        }

        pool.closeAll()
        try? await serverChannel.close().get()
    }

    @MainActor
    func testCONNECTResponseTimeoutDoesNotFireWhileChallengeAuthIsRunning() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawChallengeThenOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let port = serverChannel.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 2000
        config.upstreamResponseTimeoutSeconds = 0.1
        config.upstreams = [
            UpstreamProxy(name: "SlowChallenge", host: "127.0.0.1", port: port, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in SlowChallengeAuthenticator(delay: 0.25) }
        )

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in SlowChallengeAuthenticator(delay: 0.25) },
            logger: DiscardingLogSink()
        )

        let tunnel = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
        XCTAssertEqual(tunnel.endpoint, "127.0.0.1:\(port)")

        tunnel.channel.close(mode: .all, promise: nil)
        pool.closeAll()
        try? await serverChannel.close().get()
    }

    @MainActor
    func testBufferedExchangeTimesOutWhenUpstreamAcceptsButDoesNotRespond() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(BlackholeResponseHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let port = serverChannel.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 2000
        config.stalledConnectionTimeoutSeconds = 60
        config.upstreamResponseTimeoutSeconds = 0.2
        config.upstreams = [
            UpstreamProxy(name: "Blackhole", host: "127.0.0.1", port: port, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in StaticAuthenticator() }
        )

        var head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://example.com/")
        head.headers.add(name: "Host", value: "example.com")

        let start = Date()
        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("Exchange should fail when the upstream accepts TCP but never responds")
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .upstreamResponseTimedOut)
            XCTAssertLessThan(Date().timeIntervalSince(start), 2, "Buffered exchange must not hang indefinitely")
        }

        pool.closeAll()
        try? await serverChannel.close().get()
    }

    @MainActor
    func testBufferedExchangeResponseTimeoutDoesNotFireWhileChallengeAuthIsRunning() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let serverChannel = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                do {
                    try channel.pipeline.syncOperations.addHandler(ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes)))
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                    try channel.pipeline.syncOperations.addHandler(HTTPChallengeThenOKHandler())
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        let port = serverChannel.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 2000
        config.upstreamResponseTimeoutSeconds = 0.1
        config.upstreams = [
            UpstreamProxy(name: "SlowChallenge", host: "127.0.0.1", port: port, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in SlowChallengeAuthenticator(delay: 0.25) }
        )

        var head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://example.com/")
        head.headers.add(name: "Host", value: "example.com")

        let response = try await pool.exchange(head: head, body: nil).get()
        XCTAssertEqual(response.head.status, .ok)

        pool.closeAll()
        try? await serverChannel.close().get()
    }

    // MARK: - Health check via pool still works

    @MainActor
    func testHealthCheckWithUnreachableUpstream() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 200
        config.upstreams = [
            UpstreamProxy(name: "Down", host: "192.0.2.1", port: 9999, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
            }
        )

        let result = await pool.healthCheck(urlString: "http://detectportal.firefox.com/success.txt")
        XCTAssertFalse(result.healthy, "Health check should report unhealthy for unreachable upstream")

        pool.closeAll()
    }
}

private final class OversizedResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelActive(context: ChannelHandlerContext) {
        var buf = context.channel.allocator.buffer(capacity: 70_000)
        buf.writeRepeatingByte(UInt8(ascii: "X"), count: 70_000)
        context.writeAndFlush(NIOAny(buf), promise: nil)
    }
}

private final class BlackholeResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        _ = unwrapInboundIn(data)
        // Intentionally accept and ignore bytes. This simulates a VPN-blackholed
        // established upstream socket: TCP is open, but no proxy response arrives.
    }
}

private final class RawChallengeThenOKHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var requestCount = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)
        guard buffer.getString(at: buffer.readerIndex, length: buffer.readableBytes)?.contains("\r\n\r\n") == true else {
            return
        }
        requestCount += 1
        let status = requestCount == 1 ? "407 Proxy Authentication Required" : "200 OK"
        let authenticate = requestCount == 1 ? "Proxy-Authenticate: Static challenge\r\n" : ""
        var response = context.channel.allocator.buffer(capacity: 128)
        response.writeString("HTTP/1.1 \(status)\r\n\(authenticate)Content-Length: 0\r\n\r\n")
        context.writeAndFlush(NIOAny(response), promise: nil)
    }
}

private final class HTTPChallengeThenOKHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private var requestCount = 0

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        if case .head = unwrapInboundIn(data) {
            requestCount += 1
            if requestCount == 1 {
                var head = HTTPResponseHead(version: .http1_1, status: .proxyAuthenticationRequired)
                head.headers.add(name: "Proxy-Authenticate", value: "Static challenge")
                head.headers.add(name: "Content-Length", value: "0")
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            } else {
                var head = HTTPResponseHead(version: .http1_1, status: .ok)
                head.headers.add(name: "Content-Length", value: "0")
                context.write(wrapOutboundOut(.head(head)), promise: nil)
                context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
            }
        }
    }
}

private final class StaticAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    var scheme: String { "Static" }

    func initialToken(for host: String) throws -> String {
        "Static token"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        "Static token"
    }

    func canHandle(scheme: String) -> Bool {
        true
    }

    func reset() {}
}

private final class SlowChallengeAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    var scheme: String { "Static" }

    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func initialToken(for host: String) throws -> String {
        "Static initial"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        Thread.sleep(forTimeInterval: delay)
        return "Static response"
    }

    func canHandle(scheme: String) -> Bool {
        true
    }

    func reset() {}
}
