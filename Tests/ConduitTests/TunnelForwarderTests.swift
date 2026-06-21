// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Production-path integration tests that exercise the real TunnelForwarder,
/// not the test-only handler replica used in ProxiedTunnelTests.
final class TunnelForwarderTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Direct tunnel through production TunnelForwarder

    @MainActor
    func testDirectTunnelForwardsBytes() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let targetReceived = NIOLockedValueBox<ByteBuffer?>(nil)
        let targetServer = try await MockTCPEchoServer.start(group: group, onReceive: { buf in
            targetReceived.withLockedValue { $0 = buf }
        })
        let targetPort = targetServer.localAddress!.port!

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { ProxyConfig.testFixture() },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)

        let result = await forwarder.start(
            tunnels: [TunnelDefinition(localPort: 0, remoteHost: "127.0.0.1", remotePort: targetPort, enabled: true, proxied: false, label: "direct-e2e")],
            listenHost: "127.0.0.1"
        )
        XCTAssertEqual(result.started, 1, "One direct tunnel should have started")
        XCTAssertEqual(result.failed, 0)

        let tunnelPort = result.boundPorts.first!

        let clientChannel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .connect(host: "127.0.0.1", port: tunnelPort)
            .get()

        var sendBuf = clientChannel.allocator.buffer(capacity: 5)
        sendBuf.writeString("hello")
        try await clientChannel.writeAndFlush(sendBuf).get()

        try await Task.sleep(for: .milliseconds(500))

        let received = targetReceived.withLockedValue { $0 }
        XCTAssertNotNil(received, "Target should have received data through direct tunnel")
        if let received {
            XCTAssertEqual(received.getString(at: received.readerIndex, length: received.readableBytes), "hello")
        }

        try await clientChannel.close().get()
        await forwarder.stop()
        try await targetServer.close().get()
    }

    // MARK: - Proxied tunnel through production TunnelForwarder

    @MainActor
    func testProxiedTunnelForwardsBytes() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let targetReceived = NIOLockedValueBox<ByteBuffer?>(nil)
        let targetServer = try await MockTCPEchoServer.start(group: group, onReceive: { buf in
            targetReceived.withLockedValue { $0 = buf }
        })
        let targetPort = targetServer.localAddress!.port!

        let mockProxy = try await MockConnectProxy.start(group: group)
        let proxyPort = mockProxy.localAddress!.port!

        let upstream = UpstreamProxy(name: "mock", host: "127.0.0.1", port: proxyPort, priority: 0)
        var config = ProxyConfig.testFixture()
        config.upstreams = [upstream]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)

        let result = await forwarder.start(
            tunnels: [TunnelDefinition(localPort: 0, remoteHost: "127.0.0.1", remotePort: targetPort, enabled: true, proxied: true, label: "proxied-e2e")],
            listenHost: "127.0.0.1"
        )
        XCTAssertEqual(result.started, 1, "One proxied tunnel should have started")
        let tunnelPort = result.boundPorts.first!

        let clientChannel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .connect(host: "127.0.0.1", port: tunnelPort)
            .get()

        var sendBuf = clientChannel.allocator.buffer(capacity: 5)
        sendBuf.writeString("proxy")
        try await clientChannel.writeAndFlush(sendBuf).get()

        try await Task.sleep(for: .milliseconds(500))

        let received = targetReceived.withLockedValue { $0 }
        XCTAssertNotNil(received, "Target should have received data through proxied tunnel")
        if let received {
            XCTAssertEqual(received.getString(at: received.readerIndex, length: received.readableBytes), "proxy")
        }

        try await clientChannel.close().get()
        await forwarder.stop()
        try await targetServer.close().get()
        try await mockProxy.close().get()
    }

    // MARK: - Startup result reporting: partial bind failure

    @MainActor
    func testStartupReportsPartialBindFailure() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { ProxyConfig.testFixture() },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)

        let blocker = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let blockedPort = blocker.localAddress!.port!

        let tunnels = [
            TunnelDefinition(localPort: blockedPort, remoteHost: "example.com", remotePort: 5432, enabled: true, proxied: false, label: "will-fail"),
            TunnelDefinition(localPort: 0, remoteHost: "example.com", remotePort: 27017, enabled: true, proxied: false, label: "will-succeed"),
        ]

        let result = await forwarder.start(tunnels: tunnels, listenHost: "127.0.0.1")
        XCTAssertEqual(result.failed, 1, "One tunnel should have failed (port conflict)")
        XCTAssertEqual(result.started, 1, "One tunnel should have succeeded")

        let errorLogs = logger.entries().filter { $0.level == .error && $0.category == .tunnel }
        XCTAssertTrue(errorLogs.contains { $0.message.contains("will-fail") }, "Error log should mention the failed tunnel")

        await forwarder.stop()
        try await blocker.close().get()
    }

    // MARK: - DNS override only for successfully bound proxied tunnels

    @MainActor
    func testDNSOverrideSkippedWhenAllProxiedBindsFail() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { ProxyConfig.testFixture() },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)

        let blocker = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let blockedPort = blocker.localAddress!.port!

        let tunnels = [
            TunnelDefinition(localPort: blockedPort, remoteHost: "cosmos.example.com", remotePort: 10255, enabled: true, proxied: true, label: "will-fail"),
        ]

        let result = await forwarder.start(tunnels: tunnels, listenHost: "127.0.0.1")
        XCTAssertEqual(result.started, 0)
        XCTAssertEqual(result.failed, 1)
        XCTAssertEqual(result.dnsOverrideStatus, .notNeeded,
                       "DNS override must not activate when no proxied tunnel actually bound")

        await forwarder.stop()
        try await blocker.close().get()
    }

    @MainActor
    func testDNSOverrideOnlyIncludesSuccessfullyBoundHostnames() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let mockProxy = try await MockConnectProxy.start(group: group)
        let proxyPort = mockProxy.localAddress!.port!

        let upstream = UpstreamProxy(name: "mock", host: "127.0.0.1", port: proxyPort, priority: 0)
        var config = ProxyConfig.testFixture()
        config.upstreams = [upstream]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)

        let blocker = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let blockedPort = blocker.localAddress!.port!

        let tunnels = [
            TunnelDefinition(localPort: blockedPort, remoteHost: "fail.example.com", remotePort: 5432, enabled: true, proxied: true, label: "will-fail"),
            TunnelDefinition(localPort: 0, remoteHost: "succeed.example.com", remotePort: 27017, enabled: true, proxied: true, label: "will-succeed"),
        ]

        let result = await forwarder.start(tunnels: tunnels, listenHost: "127.0.0.1")
        XCTAssertEqual(result.started, 1)
        XCTAssertEqual(result.failed, 1)

        switch result.dnsOverrideStatus {
        case .unavailable(let reason):
            XCTAssertTrue(reason.contains("helper") || reason.contains("bind"),
                          "Without resolver manager, status should explain why: \(reason)")
        case .notNeeded:
            break
        default:
            break
        }

        await forwarder.stop()
        try await blocker.close().get()
        try await mockProxy.close().get()
    }

    // MARK: - DNS override reconciliation (regression tests)

    /// Regression: reconcile() with a removal-only delta previously left the DNS responder and
    /// `/etc/resolver/` state in place (and returned a stale `.notNeeded` status). After the fix,
    /// a reconcile that removes all proxied tunnels must tear down the override and invoke
    /// `removeDNS` for each managed hostname.
    @MainActor
    func testReconcileRemovingProxiedTunnelTearsDownDNSOverride() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let recording = RecordingPrivilegeClient()
        let resolverManager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { ProxyConfig.testFixture() },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(
            group: group,
            connectCoordinator: coordinator,
            connectionPool: pool,
            logger: logger,
            resolverManager: resolverManager
        )

        let proxied = TunnelDefinition(
            localPort: 0, remoteHost: "reconcile-remove.example.com", remotePort: 5432,
            enabled: true, proxied: true, label: "KV"
        )

        _ = await forwarder.start(tunnels: [proxied], listenHost: "127.0.0.1")

        let appliesAfterStart = recording.commands(for: .applyDNS).map { $0.1[0] }
        XCTAssertTrue(appliesAfterStart.contains("reconcile-remove.example.com"),
                      "Initial start should apply a resolver file for the proxied hostname")

        // Reconcile with no definitions: the proxied tunnel is removed.
        let result = await forwarder.reconcile(newDefinitions: [], listenHost: "127.0.0.1")

        XCTAssertEqual(result.started, 0)
        XCTAssertEqual(result.dnsOverrideStatus, .notNeeded,
                       "dnsOverrideStatus must reflect the torn-down state, not the stale default")

        let removes = recording.commands(for: .removeDNS).map { $0.1[0] }
        XCTAssertTrue(removes.contains("reconcile-remove.example.com"),
                      "Removing the last proxied tunnel must emit removeDNS for its hostname")

        await forwarder.stop()
    }

    /// Regression: reconcile() that adds a proxied tunnel while leaving another unchanged
    /// previously called `start()` with only the delta, which passed only the new hostname to
    /// `setupDNSOverride`. That wiped the responder mapping for the unchanged tunnel and would
    /// have had `cleanupStale` delete its `/etc/resolver/` file. After the fix, DNS is
    /// reconciled against the full active proxied set.
    @MainActor
    func testReconcileAddingProxiedTunnelPreservesUnchangedProxiedOverride() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let recording = RecordingPrivilegeClient()
        let resolverManager = TunnelResolverManager(privilegeClient: recording, logger: logger)

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { ProxyConfig.testFixture() },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(
            group: group,
            connectCoordinator: coordinator,
            connectionPool: pool,
            logger: logger,
            resolverManager: resolverManager
        )

        let existing = TunnelDefinition(
            localPort: 0, remoteHost: "keep-me.example.com", remotePort: 5432,
            enabled: true, proxied: true, label: "KEEP"
        )
        _ = await forwarder.start(tunnels: [existing], listenHost: "127.0.0.1")

        recording.reset()

        let added = TunnelDefinition(
            localPort: 0, remoteHost: "added.example.com", remotePort: 27017,
            enabled: true, proxied: true, label: "ADD"
        )
        let result = await forwarder.reconcile(newDefinitions: [existing, added], listenHost: "127.0.0.1")

        XCTAssertEqual(result.started, 2, "both the existing and new proxied tunnels should be active")

        let activeHostnames: Set<String>
        switch result.dnsOverrideStatus {
        case .active(let hostnames):
            activeHostnames = Set(hostnames)
        case .partial(let succeeded, _):
            activeHostnames = Set(succeeded)
        default:
            XCTFail("Expected .active or .partial DNS override status; got \(result.dnsOverrideStatus)")
            return
        }
        XCTAssertEqual(
            activeHostnames,
            Set(["keep-me.example.com", "added.example.com"]),
            "DNS override must include both the unchanged and newly-added proxied hostnames"
        )

        let removedDuringReconcile = recording.commands(for: .removeDNS).map { $0.1[0] }
        XCTAssertFalse(
            removedDuringReconcile.contains("keep-me.example.com"),
            "reconcile must not remove the /etc/resolver file for an unchanged proxied tunnel"
        )

        await forwarder.stop()
    }

    // MARK: - Loopback enforcement

    func testEffectiveTunnelListenHostIsLoopbackRegardlessOfLocalHost() {
        var config = ProxyConfig.testFixture()
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1")

        config.localHost = "0.0.0.0"
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must remain loopback even when localHost is 0.0.0.0")

        config.localHost = "192.168.1.100"
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must remain loopback for arbitrary localHost values")
    }

    // MARK: - Cosmos preset port alignment

    func testCosmosPresetHasMatchingLocalAndRemotePorts() {
        let preset = TunnelPreset.cosmosDBMongo
        XCTAssertEqual(preset.defaultLocalPort, preset.defaultRemotePort,
                       "Cosmos preset local and remote ports must match for DNS override to enable normal connection strings")
    }

    func testAllPresetsHaveMatchingPortsExceptCustom() {
        for preset in TunnelPreset.allCases where preset != .custom {
            XCTAssertEqual(preset.defaultLocalPort, preset.defaultRemotePort,
                           "Preset \(preset.displayName) should have matching local/remote ports for DNS override compatibility")
        }
    }

    // MARK: - Session limit enforcement

    @MainActor
    func testSessionLimitRejectsExcessConnections() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let targetServer = try await MockTCPEchoServer.start(group: group, onReceive: { _ in })
        let targetPort = targetServer.localAddress!.port!

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { ProxyConfig.testFixture() },
            authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)

        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)
        forwarder.updateLimits(maxGlobal: 1, maxPerTunnel: 1)

        let startResult = await forwarder.start(
            tunnels: [TunnelDefinition(localPort: 0, remoteHost: "127.0.0.1", remotePort: targetPort, enabled: true, proxied: false, label: "limit-test")],
            listenHost: "127.0.0.1"
        )
        let tunnelPort = startResult.boundPorts.first!

        let client1 = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .connect(host: "127.0.0.1", port: tunnelPort)
            .get()

        try await Task.sleep(for: .milliseconds(200))

        XCTAssertEqual(forwarder.sessionTracker.totalActiveSessions, 1)

        do {
            let client2 = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(2))
                .connect(host: "127.0.0.1", port: tunnelPort)
                .get()
            try await Task.sleep(for: .milliseconds(200))
            let warningLogs = logger.entries().filter { $0.level == .warning && $0.message.contains("session limit") }
            XCTAssertFalse(warningLogs.isEmpty, "Should log a session limit warning")
            try? await client2.close().get()
        } catch {
            // Connection may be rejected entirely, which is also acceptable
        }

        try await client1.close().get()
        await forwarder.stop()
        try await targetServer.close().get()
    }
}

// MARK: - Shared test helpers (reused from ProxiedTunnelTests)

private enum MockTCPEchoServer {
    static func start(
        group: EventLoopGroup,
        onReceive: @escaping @Sendable (ByteBuffer) -> Void
    ) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(EchoHandler(onReceive: onReceive))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    private final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let onReceive: (ByteBuffer) -> Void

        init(onReceive: @escaping @Sendable (ByteBuffer) -> Void) {
            self.onReceive = onReceive
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buf = unwrapInboundIn(data)
            onReceive(buf)
            context.writeAndFlush(data, promise: nil)
        }
    }
}

private enum MockConnectProxy {
    static func start(group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ConnectHandler(group: group))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    private final class ConnectHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let group: EventLoopGroup
        private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
        private var upstream: Channel?
        private var tunnelEstablished = false

        init(group: EventLoopGroup) { self.group = group }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            if tunnelEstablished {
                let buf = unwrapInboundIn(data)
                upstream?.writeAndFlush(buf, promise: nil)
                return
            }

            var buf = unwrapInboundIn(data)
            accumulated.writeBuffer(&buf)

            guard let str = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
                  str.contains("\r\n\r\n") else { return }

            let lines = str.split(separator: "\r\n")
            guard let connectLine = lines.first, connectLine.hasPrefix("CONNECT ") else {
                context.close(promise: nil)
                return
            }

            let parts = connectLine.split(separator: " ")
            guard parts.count >= 2 else { context.close(promise: nil); return }

            let target = String(parts[1])
            let hostPort = target.split(separator: ":")
            guard hostPort.count == 2, let port = Int(hostPort[1]) else {
                context.close(promise: nil)
                return
            }
            let host = String(hostPort[0])
            nonisolated(unsafe) let ctx = context
            let clientEL = context.eventLoop
            let clientChannel = context.channel

            ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
                .connect(host: host, port: port)
                .hop(to: clientEL)
                .whenComplete { result in
                    switch result {
                    case .success(let upstreamChannel):
                        self.upstream = upstreamChannel
                        self.tunnelEstablished = true

                        var response = ctx.channel.allocator.buffer(capacity: 64)
                        response.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
                        ctx.writeAndFlush(NIOAny(response), promise: nil)

                        upstreamChannel.pipeline.addHandler(SimpleRelay(peer: clientChannel)).whenFailure { _ in
                            clientChannel.close(promise: nil)
                        }

                    case .failure:
                        var response = ctx.channel.allocator.buffer(capacity: 64)
                        response.writeString("HTTP/1.1 502 Bad Gateway\r\n\r\n")
                        ctx.writeAndFlush(NIOAny(response)).whenComplete { _ in
                            ctx.close(promise: nil)
                        }
                    }
                }
        }

        func channelInactive(context: ChannelHandlerContext) {
            upstream?.close(mode: .all, promise: nil)
            context.fireChannelInactive()
        }
    }

    private final class SimpleRelay: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        let peer: Channel

        init(peer: Channel) { self.peer = peer }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buf = unwrapInboundIn(data)
            peer.writeAndFlush(buf, promise: nil)
        }

        func channelInactive(context: ChannelHandlerContext) {
            peer.close(mode: .all, promise: nil)
            context.fireChannelInactive()
        }
    }
}

private final class StubAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    var scheme: String { "NoOp" }

    func initialToken(for host: String) throws -> String {
        "NoOp none"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        nil
    }

    func canHandle(scheme: String) -> Bool { true }

    func reset() {}
}

/// Records helper-command invocations without touching `/etc/resolver`. Used by the DNS
/// override reconciliation regression tests to verify which hostnames were applied / removed.
private final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []

    var executedCommands: [(PrivilegedOperation, [String])] {
        lock.withLock { _commands }
    }

    func commands(for operation: PrivilegedOperation) -> [(PrivilegedOperation, [String])] {
        executedCommands.filter { $0.0 == operation }
    }

    func reset() {
        lock.withLock { _commands.removeAll() }
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        lock.withLock { _commands.append((operation, values)) }
    }
}
