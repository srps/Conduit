// SPDX-License-Identifier: Apache-2.0
// Outside strict mode the HTTP listener's reachability shortcut probes a
// target directly before `handleRequest` applies the gateway blocklist. A
// blocked target must never be probed, and a probe must not connect to a
// name that resolves to a blocked address (#93).

import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
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

    // MARK: - Results are scoped by policy (Codex review on #95)

    /// An innocuous name that resolves to loopback, found reachable outside
    /// gateway mode, is not reused once gateway mode is on: the gateway
    /// shortcut probes again under its own policy, which connects to nothing.
    func testReachabilityFoundOutsideGatewayModeIsNotReusedInGatewayMode() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: target.port)
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            resolver: ProbeResolver(.addresses([loopback])).resolve
        )
        detector.probeInBackground(host: "rebind.example", port: target.port, gatewayMode: false)
        let open = try await awaitCached(detector, host: "rebind.example", port: target.port, gatewayMode: false)
        XCTAssertTrue(open)
        XCTAssertEqual(target.accepted, 1)

        XCTAssertNil(detector.cachedReachability(host: "rebind.example", port: target.port, gatewayMode: true),
                     "a result probed outside gateway mode was read back in gateway mode")
        XCTAssertFalse(detector.shortcutReachable(host: "rebind.example", port: target.port, gatewayMode: true))
        let gateway = try await awaitCached(detector, host: "rebind.example", port: target.port, gatewayMode: true)
        XCTAssertFalse(gateway)
        XCTAssertEqual(target.accepted, 1, "gateway mode connected to a name resolving to loopback")
    }

    /// A probe still running outside gateway mode when gateway mode comes on
    /// neither absorbs the gateway request nor writes the gateway answer.
    func testProbeRunningWhenGatewayModeComesOnDoesNotAnswerForIt() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: target.port)
        let resolver = ProbeResolver(.held)
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(), resolver: resolver.resolve
        )
        detector.probeInBackground(host: "rebind.example", port: target.port, gatewayMode: false)
        XCTAssertFalse(detector.shortcutReachable(host: "rebind.example", port: target.port, gatewayMode: true))
        XCTAssertEqual(detector.probeCount, 2, "the gateway request was folded into the running open probe")
        for _ in 0..<500 where resolver.heldCount < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        resolver.release(with: [loopback])

        let open = try await awaitCached(detector, host: "rebind.example", port: target.port, gatewayMode: false)
        let gateway = try await awaitCached(detector, host: "rebind.example", port: target.port, gatewayMode: true)
        XCTAssertTrue(open)
        XCTAssertFalse(gateway, "the open probe's answer was used in gateway mode")
        XCTAssertEqual(target.accepted, 1, "only the open probe connects")
    }

    // MARK: - Every resolved address is tried (Codex review on #95)

    func testProbeTriesTheNextAddressWhenOneRefuses() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let closed = try SocketAddress(ipAddress: "127.0.0.1", port: try await Self.closedPort())
        let open = try SocketAddress(ipAddress: "127.0.0.1", port: target.port)
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            resolver: ProbeResolver(.addresses([closed, open])).resolve
        )
        let reachable = await detector.isDirectlyReachable(host: "multi.example", port: target.port, gatewayMode: false)
        XCTAssertTrue(reachable, "the probe gave up after the first address refused")
        for _ in 0..<500 where target.accepted == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(target.accepted, 1)
    }

    /// A loopback port with nothing listening.
    private static func closedPort() async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .bind(host: "127.0.0.1", port: 0).get()
        let port = channel.localAddress?.port ?? 0
        try await channel.close().get()
        return port
    }

    // MARK: - routing.probe_blocked (Codex review on #95)

    func testBlockedProbesEmitOneRateLimitedEventPerHost() async throws {
        let target = try await CountingListener.start()
        defer { target.stop() }
        let loopback = try SocketAddress(ipAddress: "127.0.0.1", port: target.port)
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let clock = NIOLockedValueBox(Date(timeIntervalSince1970: 1_000))
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            now: { clock.withLockedValue { $0 } },
            resolver: ProbeResolver(.addresses([loopback])).resolve,
            eventSink: { event in events.withLockedValue { $0.append(event) } }
        )
        func details() -> [String] {
            events.withLockedValue { $0 }.filter { $0.event == "routing.probe_blocked" }.compactMap(\.detail)
        }

        XCTAssertFalse(detector.shortcutReachable(host: "metadata.google.internal", port: 80, gatewayMode: true))
        XCTAssertFalse(detector.shortcutReachable(host: "metadata.google.internal", port: 80, gatewayMode: true))
        XCTAssertEqual(details(), ["host=metadata.google.internal port=80 kind=reachability reason=blocked_name"])

        XCTAssertEqual(detector.probeForStrictModeHint(host: "169.254.169.254", port: 80, gatewayMode: true) {}, .blocked)
        XCTAssertEqual(details().last, "host=169.254.169.254 port=80 kind=strict_hint reason=blocked_name")

        detector.probeInBackground(host: "rebind.example", port: target.port, gatewayMode: true)
        _ = try await awaitCached(detector, host: "rebind.example", port: target.port, gatewayMode: true)
        XCTAssertEqual(details().last,
                       "host=rebind.example port=\(target.port) kind=reachability reason=blocked_address address=127.0.0.1")
        XCTAssertEqual(details().count, 3)

        // Past the cooldown the host is reported again.
        clock.withLockedValue { $0 += DirectConnectDetector.probeBlockedCooldown }
        XCTAssertFalse(detector.shortcutReachable(host: "metadata.google.internal", port: 80, gatewayMode: true))
        XCTAssertEqual(details().count, 4)

        // No outside-gateway probe is ever blocked.
        XCTAssertFalse(detector.shortcutReachable(host: "metadata.google.internal", port: 80, gatewayMode: false))
        XCTAssertEqual(details().count, 4)
    }

    func testProbeBlockedRateLimitTableIsBounded() {
        let events = NIOLockedValueBox(0)
        let detector = DirectConnectDetector(
            group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink(),
            resolver: ProbeResolver(.noAddresses).resolve,
            eventSink: { _ in events.withLockedValue { $0 += 1 } }
        )
        let hosts = DirectConnectDetector.probeBlockedCapacity + 10
        for index in 0..<hosts {
            _ = detector.shortcutReachable(host: "127.0.\(index / 256).\(index % 256)", port: 80, gatewayMode: true)
        }
        XCTAssertEqual(detector.probeBlockedTableCount, DirectConnectDetector.probeBlockedCapacity)
        XCTAssertEqual(events.withLockedValue { $0 }, hosts)
        XCTAssertEqual(detector.probeCount, 0)
    }

    // MARK: - One deadline per probe (review on #95)

    /// A lookup that never answers ends the probe as unreachable at the
    /// probe's timeout and frees its slot. Driven on an embedded loop, so
    /// the deadline is counted in advanced time, not raced.
    func testProbeWithAHungLookupEndsAtItsDeadlineAndFreesItsSlot() {
        let loop = EmbeddedEventLoop()
        let resolver = ProbeResolver(.held)
        let detector = DirectConnectDetector(
            group: loop, logger: DiscardingLogSink(), baseTimeoutMS: 100, resolver: resolver.resolve
        )
        detector.probeInBackground(host: "slow.example", port: 80, gatewayMode: false)
        loop.advanceTime(by: .milliseconds(99))
        XCTAssertEqual(resolver.lookups, 1)
        XCTAssertEqual(detector.pendingProbeCount, 1)
        XCTAssertNil(detector.cachedReachability(host: "slow.example", port: 80, gatewayMode: false))

        loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(detector.pendingProbeCount, 0, "a hung lookup kept its probe slot past the deadline")
        XCTAssertEqual(detector.cachedReachability(host: "slow.example", port: 80, gatewayMode: false), false)

        // The strict-mode hint has the same deadline, at its longer timeout.
        XCTAssertEqual(detector.probeForStrictModeHint(host: "slow2.example", port: 80, gatewayMode: false) {}, .started)
        loop.advanceTime(by: .milliseconds(799))
        XCTAssertEqual(detector.strictHintInFlightCount, 1)
        loop.advanceTime(by: .milliseconds(1))
        XCTAssertEqual(detector.strictHintInFlightCount, 0, "a hung lookup kept its hint slot past the deadline")

        // A late answer is dropped.
        resolver.release()
        loop.run()
        XCTAssertEqual(detector.cachedReachability(host: "slow.example", port: 80, gatewayMode: false), false)
    }
}

// MARK: - Proxy under test

/// One HTTP listener on loopback running `HTTPProxyHandler` with an explicit
/// gateway flag, so gateway mode is tested without binding 0.0.0.0. Non-strict,
/// no PAC, no No-proxy entries: every request takes the reachability shortcut.
/// The upstream answers every request with 200.
private final class GatewayTestProxy: @unchecked Sendable {
    let detector: DirectConnectDetector
    let gatewayMode: Bool
    private let listener: Channel
    private let upstream: Channel
    private let pool: ConnectionPool

    private init(
        detector: DirectConnectDetector, gatewayMode: Bool, listener: Channel, upstream: Channel, pool: ConnectionPool
    ) {
        self.detector = detector
        self.gatewayMode = gatewayMode
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
        return GatewayTestProxy(
            detector: detector, gatewayMode: gatewayMode, listener: listener, upstream: upstream, pool: pool
        )
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
        try await awaitCached(detector, host: host, port: port, gatewayMode: gatewayMode)
    }
}

/// A detector's cached answer under `gatewayMode` once it has one. Bounded;
/// counts, not time.
private func awaitCached(
    _ detector: DirectConnectDetector, host: String, port: Int, gatewayMode: Bool
) async throws -> Bool {
    for _ in 0..<500 where detector.cachedReachability(host: host, port: port, gatewayMode: gatewayMode) == nil {
        try await Task.sleep(for: .milliseconds(10))
    }
    return try XCTUnwrap(
        detector.cachedReachability(host: host, port: port, gatewayMode: gatewayMode),
        "the reachability probe never finished"
    )
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
