// SPDX-License-Identifier: Apache-2.0
// Outside strict mode the HTTP listener's reachability shortcut probes a
// target directly before `handleRequest` applies the gateway blocklist. A
// blocked target must never be probed, and a probe must not connect to a
// name that resolves to a blocked address (#93).

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class GatewayReachabilityProbeTests: XCTestCase {

    func testBlockedLiteralIsNeitherProbedNorConnectedTo() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        // Answers as a resolver would for the literal, so a probe would connect.
        let resolver = ProbeResolver(.addresses([try SocketAddress(ipAddress: "127.0.0.1", port: target.port)]))
        let proxy = try await GatewayTestProxy.start(gatewayMode: true, resolver: resolver)
        defer { proxy.stop() }

        let head = try await proxy.request("http://127.0.0.1:\(target.port)/")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 403"), head)
        XCTAssertEqual(proxy.detector.probeCount, 0, "a blocked literal was probed")
        XCTAssertEqual(resolver.lookups, 0)
        XCTAssertEqual(target.accepted, 0, "the probe connected to a blocked literal")
    }

    func testBlockedMetadataHostnameIsNotProbed() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let blocked = try SocketAddress(ipAddress: "127.0.0.1", port: target.port)
        let resolver = ProbeResolver(.addresses([blocked]))
        let proxy = try await GatewayTestProxy.start(gatewayMode: true, resolver: resolver)
        defer { proxy.stop() }

        let head = try await proxy.request("http://metadata.google.internal:\(target.port)/computeMetadata/v1/")
        XCTAssertTrue(head.hasPrefix("HTTP/1.1 403"), head)
        XCTAssertEqual(proxy.detector.probeCount, 0, "a blocked metadata hostname was probed")
        XCTAssertEqual(resolver.lookups, 0, "a blocked metadata hostname was resolved")
        XCTAssertEqual(target.accepted, 0)
    }

    /// A name that passes the name check but resolves to loopback is
    /// resolved, never connected to, and cached as unreachable; the same
    /// request outside gateway mode is probed, so the counts can see one.
    func testNameResolvingToABlockedAddressIsNotConnectedTo() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: target.port)

        let gatewayResolver = ProbeResolver(.addresses([loopback]))
        let gateway = try await GatewayTestProxy.start(gatewayMode: true, resolver: gatewayResolver)
        defer { gateway.stop() }
        let gatewayHead = try await gateway.request("http://rebind.example:\(target.port)/")
        XCTAssertTrue(gatewayHead.hasPrefix("HTTP/1.1 200"), "the request goes through the upstream: \(gatewayHead)")
        let gatewayCached = try await gateway.awaitCachedReachability(host: "rebind.example", port: target.port)
        XCTAssertEqual(gatewayResolver.lookups, 1)
        XCTAssertEqual(target.accepted, 0, "the probe connected to a name resolving to a blocked address")
        XCTAssertFalse(gatewayCached, "a blocked resolved address cached as reachable")

        // Control: outside gateway mode the same request probes and connects.
        let openResolver = ProbeResolver(.addresses([loopback]))
        let open = try await GatewayTestProxy.start(gatewayMode: false, resolver: openResolver)
        defer { open.stop() }
        let openHead = try await open.request("http://rebind.example:\(target.port)/")
        XCTAssertTrue(openHead.hasPrefix("HTTP/1.1 200"), openHead)
        let openCached = try await open.awaitCachedReachability(host: "rebind.example", port: target.port)
        XCTAssertTrue(openCached, "the control probe did not reach the target through the injected resolver")
        XCTAssertEqual(open.detector.probeCount, 1)
        XCTAssertEqual(target.accepted, 1)
    }

    /// A reachability cached before gateway mode came on never counts for a
    /// host the blocklist refuses.
    func testCachedReachabilityNeverCountsForABlockedHost() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let detector = DirectConnectDetector(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink())
        let reachable = await detector.isDirectlyReachable(host: "127.0.0.1", port: target.port, gatewayMode: false)
        XCTAssertTrue(reachable)
        XCTAssertEqual(detector.cachedReachability(host: "127.0.0.1", port: target.port, gatewayMode: false), true)
        XCTAssertEqual(detector.cachedReachability(host: "127.0.0.1", port: target.port, gatewayMode: true), false)
        let again = await detector.isDirectlyReachable(host: "127.0.0.1", port: target.port, gatewayMode: true)
        XCTAssertFalse(again)
        XCTAssertEqual(detector.probeCount, 1, "a blocked host was probed")
    }
}

// MARK: - Proxy under test

/// One HTTP listener on loopback running `HTTPProxyHandler` with an explicit
/// gateway flag, so gateway mode is tested without binding 0.0.0.0. Non-strict,
/// no PAC, no No-proxy entries: every request takes the reachability shortcut.
/// The upstream answers every request with 200.
private final class GatewayTestProxy: @unchecked Sendable {
    let detector: DirectConnectDetector
    private let listener: Channel
    private let upstream: Channel
    private let pool: ConnectionPool

    private init(detector: DirectConnectDetector, listener: Channel, upstream: Channel, pool: ConnectionPool) {
        self.detector = detector
        self.listener = listener
        self.upstream = upstream
        self.pool = pool
    }

    static func start(gatewayMode: Bool, resolver: ProbeResolver) async throws -> GatewayTestProxy {
        let group = MultiThreadedEventLoopGroup.singleton
        let upstream = try await ServerBootstrap(group: group)
            .childChannelInitializer { $0.pipeline.addHandler(OKResponder()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()

        var config = ProxyConfig.testFixture()
        config.strictMode = false
        config.gatewayMode = gatewayMode
        config.pacRoutingEnabled = false
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.upstreams = [UpstreamProxy(
            name: "Upstream", host: "127.0.0.1", port: upstream.localAddress?.port ?? 0, priority: 0
        )]
        let fixed = config
        let logger = DiscardingLogSink()
        let detector = DirectConnectDetector(
            group: group, logger: logger, ttlSeconds: 300, baseTimeoutMS: 1_000,
            resolver: { host, port, loop in resolver.resolve(host: host, port: port, on: loop) }
        )
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { fixed },
            authenticatorProvider: { _ in GatewayProbeNoOpAuthenticator() }
        )
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in GatewayProbeNoOpAuthenticator() }, logger: logger
        )
        let listener = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                let handler = HTTPProxyHandler(
                    pool: pool,
                    connectCoordinator: coordinator,
                    logger: logger,
                    configProvider: { fixed },
                    directModeProvider: { (false, .none) },
                    directConnectDetector: detector,
                    pacRoutingEngine: nil,
                    gatewayMode: gatewayMode,
                    authSource: nil,
                    eventLoopGroup: group,
                    onConnectionOpened: { _ in },
                    onConnectionClosed: { _ in },
                    onConnectionActivity: { _ in },
                    onRequestCompleted: { _, _ in }
                )
                do {
                    try channel.pipeline.syncOperations.addHandler(
                        ByteToMessageHandler(HTTPRequestDecoder(leftOverBytesStrategy: .forwardBytes))
                    )
                    try channel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
                    try channel.pipeline.syncOperations.addHandler(handler)
                    return channel.eventLoop.makeSucceededVoidFuture()
                } catch {
                    return channel.eventLoop.makeFailedFuture(error)
                }
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        return GatewayTestProxy(detector: detector, listener: listener, upstream: upstream, pool: pool)
    }

    func stop() {
        pool.closeAll()
        listener.close(promise: nil)
        upstream.close(promise: nil)
    }

    /// Sends one absolute-form GET and returns the response head.
    func request(_ url: String) async throws -> String {
        let host = URL(string: url)?.host ?? ""
        let port = listener.localAddress?.port ?? 0
        let promise = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: String.self)
        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .channelInitializer { $0.pipeline.addHandler(HeadCollector(promise: promise)) }
            .connect(host: "127.0.0.1", port: port)
            .get()
        defer { client.close(promise: nil) }
        try await client.writeAndFlush(
            client.allocator.buffer(string: "GET \(url) HTTP/1.1\r\nHost: \(host)\r\n\r\n")
        ).get()
        return try await promise.futureResult.get()
    }

    /// The probe's cached answer once it has one. Bounded; counts, not time.
    func awaitCachedReachability(host: String, port: Int) async throws -> Bool {
        let gatewayMode = false // read the raw cache entry
        for _ in 0..<500 where detector.cachedReachability(host: host, port: port, gatewayMode: gatewayMode) == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try XCTUnwrap(
            detector.cachedReachability(host: host, port: port, gatewayMode: gatewayMode),
            "the reachability probe never finished"
        )
    }
}

/// Answers every request head with an empty 200.
private final class OKResponder: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer
    private var pending = ""

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        pending += buffer.readString(length: buffer.readableBytes) ?? ""
        while let end = pending.range(of: "\r\n\r\n") {
            pending = String(pending[end.upperBound...])
            let reply = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
            context.writeAndFlush(wrapOutboundOut(context.channel.allocator.buffer(string: reply)), promise: nil)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

/// Completes with the response head, or with whatever arrived if the
/// connection closes first.
private final class HeadCollector: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let promise: EventLoopPromise<String>
    private var received = ""
    private var done = false

    init(promise: EventLoopPromise<String>) { self.promise = promise }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        received += buffer.readString(length: buffer.readableBytes) ?? ""
        if let end = received.range(of: "\r\n\r\n") {
            complete(.success(String(received[..<end.lowerBound])))
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        complete(.success(received))
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        complete(.failure(error))
        context.close(promise: nil)
    }

    private func complete(_ result: Result<String, Error>) {
        guard !done else { return }
        done = true
        promise.completeWith(result)
    }
}

private final class GatewayProbeNoOpAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    func initialToken(for host: String) throws -> String { "Negotiate probe-token" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { true }
    func reset() {}
}
