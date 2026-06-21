// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// End-to-end test: client → ProxiedTunnel → mock CONNECT proxy → mock target server.
/// Verifies that non-HTTP wire protocols (e.g. MongoDB) can traverse a corporate
/// proxy via HTTP CONNECT tunneling.
final class ProxiedTunnelTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        try? group.syncShutdownGracefully()
    }

    // MARK: - Full integration: MongoDB wire protocol through proxied tunnel

    @MainActor
    func testMongoDBThroughProxiedTunnel() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        // 1. Start a mock target that echoes data (simulates CosmosDB/MongoDB endpoint)
        let targetReceived = NIOLockedValueBox<ByteBuffer?>(nil)
        let targetServer = try await MockTCPEchoServer.start(group: group, onReceive: { buf in
            targetReceived.withLockedValue { $0 = buf }
        })
        let targetPort = targetServer.localAddress!.port!

        // 2. Start a mock upstream proxy that handles CONNECT
        let mockProxy = try await MockConnectProxy.start(group: group)
        let proxyPort = mockProxy.localAddress!.port!

        // 3. Set up the proxy infrastructure
        let upstream = UpstreamProxy(name: "mock", host: "127.0.0.1", port: proxyPort, priority: 0)
        var config = ProxyConfig.testFixture()
        config.upstreams = [upstream]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in NoOpAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in NoOpAuthenticator() }, logger: logger)

        // 4. Start the proxied tunnel: local port → 127.0.0.1:targetPort via CONNECT
        let tunnelDef = TunnelDefinition(
            localPort: 0,  // will pick an available port below
            remoteHost: "127.0.0.1",
            remotePort: targetPort,
            proxied: true,
            label: "MongoDB-test"
        )

        let tunnelListener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    ProxiedTunnelClientHandlerForTest(
                        remoteHost: "127.0.0.1",
                        remotePort: targetPort,
                        label: tunnelDef.effectiveLabel,
                        connectCoordinator: coordinator,
                        logger: logger
                    )
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let tunnelPort = tunnelListener.localAddress!.port!

        // 5. Connect a client and send MongoDB OP_MSG
        let clientChannel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .connect(host: "127.0.0.1", port: tunnelPort)
            .get()

        let mongoMessage = Self.buildMongoDBOpMsg(body: "{\"hello\": 1}")
        var sendBuf = clientChannel.allocator.buffer(capacity: mongoMessage.count)
        sendBuf.writeBytes(mongoMessage)
        try await clientChannel.writeAndFlush(sendBuf).get()

        // 6. Wait for data to arrive at target
        try await Task.sleep(for: .milliseconds(500))

        let received = targetReceived.withLockedValue { $0 }
        XCTAssertNotNil(received, "Target server should have received data")

        if let received {
            XCTAssertEqual(received.readableBytes, mongoMessage.count, "All bytes should arrive intact")
            let receivedBytes = received.getBytes(at: received.readerIndex, length: received.readableBytes)!
            XCTAssertEqual(receivedBytes, mongoMessage, "Wire protocol bytes should be bit-identical")

            let detected = ProtocolDetector.detect(received)
            XCTAssertEqual(detected, DetectedProtocol.mongodb, "Protocol detector should identify MongoDB from the relayed bytes")
        }

        try await clientChannel.close().get()
        try await tunnelListener.close().get()
        try await targetServer.close().get()
        try await mockProxy.close().get()
    }

    // MARK: - Verify protocol detection on tunnel data

    @MainActor
    func testProtocolDetectionOnTunnelData() async throws {
        let logger = RecordingLogSink(minLevel: .debug)

        let targetServer = try await MockTCPEchoServer.start(group: group, onReceive: { _ in })
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
            authenticatorProvider: { _ in NoOpAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in NoOpAuthenticator() }, logger: logger)

        let tunnelListener = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(
                    ProxiedTunnelClientHandlerForTest(
                        remoteHost: "127.0.0.1",
                        remotePort: targetPort,
                        label: "PG-test",
                        connectCoordinator: coordinator,
                        logger: logger
                    )
                )
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let tunnelPort = tunnelListener.localAddress!.port!

        let clientChannel = try await ClientBootstrap(group: group)
            .connectTimeout(.seconds(5))
            .connect(host: "127.0.0.1", port: tunnelPort)
            .get()

        // Send PostgreSQL SSLRequest
        var pgBytes: [UInt8] = []
        pgBytes.append(contentsOf: withUnsafeBytes(of: Int32(8).bigEndian) { Array($0) })
        pgBytes.append(contentsOf: withUnsafeBytes(of: Int32(80877103).bigEndian) { Array($0) })

        var sendBuf = clientChannel.allocator.buffer(capacity: pgBytes.count)
        sendBuf.writeBytes(pgBytes)
        try await clientChannel.writeAndFlush(sendBuf).get()

        try await Task.sleep(for: .milliseconds(500))

        // Check the log for PostgreSQL detection
        let tunnelLogs = logger.entries().filter { $0.category == .tunnel }
        let pgDetected = tunnelLogs.contains { $0.message.contains("PostgreSQL") }
        XCTAssertTrue(pgDetected, "Logger should record PostgreSQL detection on tunnel. Logs: \(tunnelLogs.map(\.message))")

        try await clientChannel.close().get()
        try await tunnelListener.close().get()
        try await targetServer.close().get()
        try await mockProxy.close().get()
    }

    // MARK: - TunnelDefinition backward compatibility

    func testTunnelDefinitionDefaultsProxiedFalse() {
        let def = TunnelDefinition(localPort: 27017, remoteHost: "cosmos.example.com", remotePort: 10255)
        XCTAssertFalse(def.proxied)
        XCTAssertEqual(def.label, "")
    }

    func testTunnelDefinitionProxiedTrue() {
        let def = TunnelDefinition(localPort: 27017, remoteHost: "cosmos.example.com", remotePort: 10255, proxied: true, label: "CosmosDB")
        XCTAssertTrue(def.proxied)
        XCTAssertEqual(def.effectiveLabel, "CosmosDB")
    }

    func testTunnelDefinitionEffectiveLabelFallback() {
        let def = TunnelDefinition(localPort: 5432, remoteHost: "pg.internal.corp", remotePort: 5432, proxied: true)
        XCTAssertEqual(def.effectiveLabel, "5432→pg.internal.corp:5432")
    }

    func testTunnelDefinitionDecodesWithoutProxiedField() throws {
        let json = """
        {"id":"00000000-0000-0000-0000-000000000001","localPort":27017,"remoteHost":"example.com","remotePort":10255,"enabled":true}
        """
        let def = try JSONDecoder().decode(TunnelDefinition.self, from: Data(json.utf8))
        XCTAssertFalse(def.proxied)
        XCTAssertEqual(def.label, "")
    }

    // MARK: - Session tracker

    func testSessionTrackerEnforcesGlobalLimit() {
        let tracker = TunnelSessionTracker(limits: .init(maxGlobal: 2, maxPerTunnel: 10))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 5432))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 27017))
        XCTAssertFalse(tracker.tryAcquire(tunnelPort: 6379), "Should reject when global limit reached")
        tracker.release(tunnelPort: 5432)
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 6379), "Should allow after release")
    }

    func testSessionTrackerEnforcesPerTunnelLimit() {
        let tracker = TunnelSessionTracker(limits: .init(maxGlobal: 100, maxPerTunnel: 2))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 5432))
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 5432))
        XCTAssertFalse(tracker.tryAcquire(tunnelPort: 5432), "Should reject when per-tunnel limit reached")
        XCTAssertTrue(tracker.tryAcquire(tunnelPort: 27017), "Different tunnel should still work")
    }

    func testSessionTrackerTotalActiveSessions() {
        let tracker = TunnelSessionTracker(limits: .init(maxGlobal: 100, maxPerTunnel: 100))
        _ = tracker.tryAcquire(tunnelPort: 5432)
        _ = tracker.tryAcquire(tunnelPort: 5432)
        _ = tracker.tryAcquire(tunnelPort: 27017)
        XCTAssertEqual(tracker.totalActiveSessions, 3)
        tracker.release(tunnelPort: 5432)
        XCTAssertEqual(tracker.totalActiveSessions, 2)
    }

    // MARK: - Config tunnel limits

    func testTunnelSessionLimitsDefaults() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.maxTunnelSessions, 128)
        XCTAssertEqual(config.maxSessionsPerTunnel, 32)
    }

    func testTunnelSessionLimitsDecodeWhenMissing() throws {
        let json = #"{}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.maxTunnelSessions, 128)
        XCTAssertEqual(config.maxSessionsPerTunnel, 32)
    }

    // MARK: - Gateway mode tunnel listen host

    func testEffectiveTunnelListenHostAlwaysLoopback() {
        var config = ProxyConfig.testFixture()
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1")
        config.gatewayMode = true
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must stay loopback even in gateway mode")
        XCTAssertEqual(config.effectiveListenHost, "0.0.0.0",
                       "Main proxy listen host should still be 0.0.0.0 in gateway mode")
        config.gatewayMode = false
        config.localHost = "0.0.0.0"
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must stay loopback even when localHost is 0.0.0.0")
        config.localHost = "10.0.0.5"
        XCTAssertEqual(config.effectiveTunnelListenHost, "127.0.0.1",
                       "Tunnel listen host must stay loopback for any custom localHost")
    }

    // MARK: - Helpers

    static func buildMongoDBOpMsg(body: String) -> [UInt8] {
        // Build a minimal MongoDB OP_MSG (opcode 2013)
        // Header: messageLength(4 LE) + requestID(4) + responseTo(4) + opCode(4 LE)
        // Body section: flagBits(4) + section kind(1) + BSON document
        let bson = Self.minimalBSON(body)
        let flagBits: [UInt8] = [0x00, 0x00, 0x00, 0x00]
        let sectionKind: [UInt8] = [0x00]  // kind 0 = body

        let headerSize = 16
        let payloadSize = flagBits.count + sectionKind.count + bson.count
        let messageLength = Int32(headerSize + payloadSize)

        var bytes: [UInt8] = []
        bytes.append(contentsOf: withUnsafeBytes(of: messageLength.littleEndian) { Array($0) })
        bytes.append(contentsOf: withUnsafeBytes(of: Int32(1).littleEndian) { Array($0) })   // requestID
        bytes.append(contentsOf: withUnsafeBytes(of: Int32(0).littleEndian) { Array($0) })   // responseTo
        bytes.append(contentsOf: withUnsafeBytes(of: Int32(2013).littleEndian) { Array($0) }) // OP_MSG
        bytes.append(contentsOf: flagBits)
        bytes.append(contentsOf: sectionKind)
        bytes.append(contentsOf: bson)
        return bytes
    }

    /// Build a minimal BSON document: { "hello": 1 } represented as BSON.
    static func minimalBSON(_ hint: String) -> [UInt8] {
        // BSON: length(4 LE) + elements + 0x00 terminator
        // Element: type(1) + cstring name + value
        // int32 type = 0x10, value = 1
        let name = Array("hello\0".utf8)
        let value = withUnsafeBytes(of: Int32(1).littleEndian) { Array($0) }
        let elements: [UInt8] = [0x10] + [UInt8](name) + value
        let docLength = Int32(4 + elements.count + 1) // 4 for length, 1 for terminator
        var doc: [UInt8] = []
        doc.append(contentsOf: withUnsafeBytes(of: docLength.littleEndian) { Array($0) })
        doc.append(contentsOf: elements)
        doc.append(0x00) // terminator
        return doc
    }
}

// MARK: - Mock TCP Echo Server

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

// MARK: - Mock CONNECT Proxy

/// Minimal HTTP proxy that handles CONNECT requests and bridges to the target.
/// Accepts any Proxy-Authorization header without validation.
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

// MARK: - No-op authenticator for tests

private final class NoOpAuthenticator: ProxyAuthenticator, @unchecked Sendable {
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

// MARK: - Test-visible version of ProxiedTunnelClientHandler
// (The production one is private inside TunnelForwarder.swift, so we replicate
// the minimal logic for test wiring. Tests also exercise the real TunnelForwarder
// via TunnelDefinition integration.)

private final class ProxiedTunnelClientHandlerForTest: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let remoteHost: String
    private let remotePort: Int
    private let label: String
    private let connectCoordinator: CONNECTCoordinator
    private let logger: any LogSink

    private var upstream: Channel?
    private var buffered: [ByteBuffer] = []
    private var tunnelReady = false
    private var protocolDetected = false

    init(
        remoteHost: String,
        remotePort: Int,
        label: String,
        connectCoordinator: CONNECTCoordinator,
        logger: any LogSink
    ) {
        self.remoteHost = remoteHost
        self.remotePort = remotePort
        self.label = label
        self.connectCoordinator = connectCoordinator
        self.logger = logger
    }

    func channelActive(context: ChannelHandlerContext) {
        let clientChannel = context.channel
        let target = remoteHost.contains(":") ? "[\(remoteHost)]:\(remotePort)" : "\(remoteHost):\(remotePort)"
        logger.log(.info, "Proxied tunnel \(label): establishing CONNECT to \(target).", category: .tunnel)

        connectCoordinator.connectUpstreamTunnel(target: target)
            .hop(to: context.eventLoop)
            .whenComplete { [self] result in
                switch result {
                case .success(let (upstreamChannel, _, _)):
                    self.upstream = upstreamChannel
                    self.tunnelReady = true
                    let relay = ProxiedRelay(peer: clientChannel)
                    upstreamChannel.pipeline.addHandler(relay).whenComplete { _ in
                        for buf in self.buffered {
                            upstreamChannel.write(buf, promise: nil)
                        }
                        if !self.buffered.isEmpty { upstreamChannel.flush() }
                        self.buffered.removeAll()
                    }
                case .failure(let error):
                    self.logger.log(.error, "Proxied tunnel \(self.label): \(error.localizedDescription)", category: .tunnel)
                    clientChannel.close(promise: nil)
                }
            }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buf = unwrapInboundIn(data)
        if !protocolDetected {
            protocolDetected = true
            let detected = ProtocolDetector.detect(buf)
            if detected != .unknown {
                logger.log(.info, "Proxied tunnel \(label): detected \(detected.displayName) wire protocol.", category: .tunnel)
            }
        }
        if tunnelReady, let upstream {
            upstream.writeAndFlush(buf, promise: nil)
        } else {
            buffered.append(buf)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        upstream?.close(mode: .all, promise: nil)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        upstream?.close(mode: .all, promise: nil)
        context.close(promise: nil)
    }
}

private final class ProxiedRelay: ChannelInboundHandler, @unchecked Sendable {
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
