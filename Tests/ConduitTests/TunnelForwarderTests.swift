// SPDX-License-Identifier: Apache-2.0
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Production-path integration tests that exercise the real TunnelForwarder.
final class TunnelForwarderTests: XCTestCase {

    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    }

    override func tearDown() {
        XCTAssertNoThrow(try group.syncShutdownGracefully(), "The event loop group should shut down cleanly")
    }

    /// Polls `condition` until it holds or `timeout` passes; the caller's
    /// assertions then report what was (or was not) observed.
    private static func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
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

        // Wait for the bytes, not the clock: a loaded CI runner can take
        // longer than any fixed sleep to connect the tunnel (#56).
        try await Self.waitUntil { targetReceived.withLockedValue { $0 } != nil }

        let received = targetReceived.withLockedValue { $0 }
        XCTAssertNotNil(received, "Target should have received data through direct tunnel; log: \(logger.entries().map { "[\($0.level)] \($0.message)" })")
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

        // Wait for the bytes, not the clock: a loaded CI runner can take
        // longer than any fixed sleep to connect the tunnel (#56).
        try await Self.waitUntil { targetReceived.withLockedValue { $0 } != nil }

        let received = targetReceived.withLockedValue { $0 }
        XCTAssertNotNil(received, "Target should have received data through proxied tunnel; log: \(logger.entries().map { "[\($0.level)] \($0.message)" })")
        if let received {
            XCTAssertEqual(received.getString(at: received.readerIndex, length: received.readableBytes), "proxy")
        }

        try await clientChannel.close().get()
        await forwarder.stop()
        try await targetServer.close().get()
        try await mockProxy.close().get()
    }

    // MARK: - A wire protocol through a proxied tunnel

    /// A MongoDB OP_MSG crosses the production proxied tunnel bit for bit, and the real handler logs the protocol it
    /// detected. The mock proxy holds its dial to the target until that log appears: the handler logs on its first client
    /// read, while CONNECT is still pending, so the log does not show that any byte reached the target. The test waits for
    /// the bytes themselves. Teardown joins the mock's dials before the group shuts down, on every path, because
    /// `forwarder.stop()` closes only the listeners and does not wait for a pending CONNECT.
    @MainActor
    func testProxiedTunnelCarriesMongoDBBytesExactlyAndLogsTheDetectedProtocol() async throws {
        let message = Self.buildMongoDBOpMsg()
        let loop = group.next()
        let detectionLogged = loop.makePromise(of: Void.self)
        let logger = TunnelLogSignal(marker: "detected MongoDB wire protocol", signal: detectionLogged)
        let received = NIOLockedValueBox<[UInt8]>([])
        let bytesArrived = loop.makePromise(of: Void.self)
        let dials = MockProxyDials(eventLoop: loop)
        var target: Channel?
        var proxy: Channel?
        var client: Channel?
        var pool: ConnectionPool?
        var forwarder: TunnelForwarder?
        var failure: Error?

        do {
            let targetServer = try await MockTCPEchoServer.start(group: group, onReceive: { buffer in
                let count = received.withLockedValue { bytes in
                    bytes += buffer.getBytes(at: buffer.readerIndex, length: buffer.readableBytes) ?? []
                    return bytes.count
                }
                if count >= message.count { bytesArrived.succeed(()) }
            })
            target = targetServer
            let mockProxy = try await MockConnectProxy.start(group: group, dials: dials)
            proxy = mockProxy

            let proxyPort = try XCTUnwrap(mockProxy.localAddress?.port)
            var config = ProxyConfig.testFixture()
            config.upstreams = [UpstreamProxy(name: "mock", host: "127.0.0.1", port: proxyPort, priority: 0)]
            let fixedConfig = config
            let tunnelPool = ConnectionPool(
                group: group, logger: logger, configProvider: { fixedConfig }, authenticatorProvider: { _ in StubAuthenticator() }
            )
            pool = tunnelPool
            let coordinator = CONNECTCoordinator(pool: tunnelPool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger)
            let tunnelForwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: tunnelPool, logger: logger)
            forwarder = tunnelForwarder
            let targetPort = try XCTUnwrap(targetServer.localAddress?.port)
            let result = await tunnelForwarder.start(
                tunnels: [TunnelDefinition(localPort: 0, remoteHost: "127.0.0.1", remotePort: targetPort, enabled: true, proxied: true, label: "mongodb-e2e")],
                listenHost: "127.0.0.1"
            )
            XCTAssertEqual(result.started, 1, "One proxied tunnel should have started")
            let tunnelPort = try XCTUnwrap(result.boundPorts.first)

            let tunnelClient = try await ClientBootstrap(group: group)
                .connectTimeout(.seconds(5))
                .connect(host: "127.0.0.1", port: tunnelPort)
                .get()
            client = tunnelClient
            var sendBuf = tunnelClient.allocator.buffer(capacity: message.count)
            sendBuf.writeBytes(message)
            try await tunnelClient.writeAndFlush(sendBuf).get()

            // The handler has read and classified the OP_MSG while the mock still holds the CONNECT's dial to the target.
            try await Self.awaitSignal(detectionLogged, "the detection log")
            try await Self.awaitSignal(dials.requested, "the mock proxy's dial request")
            XCTAssertEqual(received.withLockedValue { $0 }, [], "No byte may reach the target while its dial is held")

            dials.release()
            try await Self.awaitSignal(bytesArrived, "the OP_MSG at the target")
            let bytes = received.withLockedValue { $0 }
            XCTAssertEqual(bytes, message, "Wire protocol bytes should be bit-identical")
            var relayed = ByteBufferAllocator().buffer(capacity: bytes.count)
            relayed.writeBytes(bytes)
            XCTAssertEqual(ProtocolDetector.detect(relayed), .mongodb, "Protocol detector should identify MongoDB from the relayed bytes")
            let detections = logger.recording.entries().filter { $0.category == .tunnel && $0.message.contains("detected MongoDB wire protocol") }
            XCTAssertEqual(detections.map(\.message), ["Proxied tunnel mongodb-e2e: detected MongoDB wire protocol."])
            XCTAssertEqual(detections.map(\.level), [.info])
        } catch {
            failure = error
        }

        // Teardown on every path leaves no dial in flight when the group shuts down: the client first, then the listeners,
        // then the mock's dials (any still held end without dialing), then the servers.
        var cleanupFailures: [String] = []
        if let failed = await Self.closeFailure(client, "the client") { cleanupFailures.append(failed) }
        await forwarder?.stop()
        cleanupFailures += await dials.join()
        if let failed = await Self.closeFailure(proxy, "the mock proxy") { cleanupFailures.append(failed) }
        if let failed = await Self.closeFailure(target, "the target") { cleanupFailures.append(failed) }
        pool?.closeAll()
        // A signal never seen must still complete, so no promise outlives the test unfulfilled.
        detectionLogged.fail(TestEnded())
        bytesArrived.fail(TestEnded())
        for failed in cleanupFailures {
            XCTFail("Cleanup failed: \(failed)")
        }
        if let failure { throw failure }
    }

    /// Once joined, the mock proxy's dial record admits no dial, whether or not it was released: a CONNECT that reached the
    /// mock after teardown's join would otherwise start a dial that nothing waits for. The connect closure never touches the
    /// network; it counts its calls and fails at once.
    func testJoinedMockProxyDialsAdmitNoLaterDial() async {
        let loop = group.next()
        let connects = NIOLockedValueBox(0)
        let connect: @Sendable () -> EventLoopFuture<Channel> = {
            connects.withLockedValue { $0 += 1 }
            return loop.makeFailedFuture(UnexpectedConnect())
        }

        // Released before the join: the gate has succeeded, so only the closed record can refuse.
        let released = MockProxyDials(eventLoop: loop)
        released.release()
        let releasedFailures = await released.join()
        XCTAssertEqual(releasedFailures, [])
        let afterRelease = await Self.lateDialOutcome(released.dial(connect))
        XCTAssertNil(afterRelease, "A joined record must refuse a dial after its release")

        // Never released: the gate has failed as well.
        let held = MockProxyDials(eventLoop: loop)
        let heldFailures = await held.join()
        XCTAssertEqual(heldFailures, [])
        let whileHeld = await Self.lateDialOutcome(held.dial(connect))
        XCTAssertNil(whileHeld, "A joined record must refuse a dial that was never released")

        XCTAssertEqual(connects.withLockedValue { $0 }, 0, "No connect may start after the join")
    }

    /// The connect a test expected never to run.
    private struct UnexpectedConnect: Error {}

    /// Waits for a dial the record should have refused, and says how it ended; nil means it was refused.
    private static func lateDialOutcome(_ dial: EventLoopFuture<Channel>?) async -> String? {
        guard let dial else { return nil }
        do {
            let channel = try await dial.get()
            return "admitted and connected to \(String(describing: channel.remoteAddress))"
        } catch {
            return "admitted, then failed with \(error)"
        }
    }

    /// A promise a test still held when it ended.
    private struct TestEnded: Error {}

    /// A signal the test waited for that did not arrive.
    private struct MissingSignal: Error, CustomStringConvertible {
        let signal: String
        var description: String { "\(signal) did not arrive within five seconds" }
    }

    /// Waits for `promise`, failing it after five seconds so a missing signal fails the test instead of hanging it.
    private static func awaitSignal(_ promise: EventLoopPromise<Void>, _ signal: String) async throws {
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(MissingSignal(signal: signal))
        }
        defer { timeout.cancel() }
        try await promise.futureResult.get()
    }

    /// Closes `channel` and describes any failure. A channel its peer already closed is not a failure.
    private static func closeFailure(_ channel: Channel?, _ name: String) async -> String? {
        guard let channel else { return nil }
        do {
            try await channel.close().get()
            return nil
        } catch ChannelError.alreadyClosed {
            return nil
        } catch {
            return "closing \(name): \(error)"
        }
    }

    /// A minimal MongoDB OP_MSG (opcode 2013) whose body section holds `{ "hello": 1 }`.
    static func buildMongoDBOpMsg() -> [UInt8] {
        // Header: messageLength(4 LE) + requestID(4) + responseTo(4) + opCode(4 LE)
        // Body section: flagBits(4) + section kind(1) + BSON document
        let bson = Self.minimalBSON()
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

    /// The BSON document `{ "hello": 1 }`.
    static func minimalBSON() -> [UInt8] {
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

    // MARK: - Server-first bytes through a proxied tunnel

    /// The upstream's greeting shares a write with its `200`, and a second
    /// one follows before the client speaks. Both reach the client in order,
    /// and neither is mistaken for a malformed CONNECT response.
    @MainActor
    func testProxiedTunnelDeliversServerFirstBytes() async throws {
        let logger = RecordingLogSink(minLevel: .debug)
        let greetings: [[UInt8]] = [Array("SSH-2.0-Upstream\r\n".utf8) + [0, 0xff], Array("220 later\r\n".utf8)]
        let proxy = try await ServerBootstrap(group: group)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(GreetingConnectProxy(greetings: greetings))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "greeting", host: "127.0.0.1", port: proxy.localAddress!.port!, priority: 0)]
        let fixedConfig = config
        let events = NIOLockedValueBox<[String]>([])
        let pool = ConnectionPool(
            group: group, logger: logger, configProvider: { fixedConfig }, authenticatorProvider: { _ in StubAuthenticator() }
        )
        defer { pool.closeAll() }
        let coordinator = CONNECTCoordinator(
            pool: pool, authenticatorProvider: { _ in StubAuthenticator() }, logger: logger,
            eventSink: { event in events.withLockedValue { $0.append(event.event) } }
        )
        let forwarder = TunnelForwarder(group: group, connectCoordinator: coordinator, connectionPool: pool, logger: logger)
        let result = await forwarder.start(
            tunnels: [TunnelDefinition(localPort: 0, remoteHost: "origin.test", remotePort: 22, enabled: true, proxied: true, label: "server-first")],
            listenHost: "127.0.0.1"
        )
        let tunnelPort = try XCTUnwrap(result.boundPorts.first)

        let expected = greetings.flatMap { $0 }
        let received = group.next().makePromise(of: [UInt8].self)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(CollectBytes(count: expected.count, promise: received))
            }
            .connect(host: "127.0.0.1", port: tunnelPort)
            .get()
        let timeout = group.next().scheduleTask(in: .seconds(5)) {
            received.fail(ChannelError.connectTimeout(.seconds(5)))
        }
        let bytes = try await received.futureResult.get()
        timeout.cancel()

        XCTAssertEqual(bytes, expected)
        XCTAssertFalse(events.withLockedValue { $0 }.contains("connection.upstream_invalid_response"))
        try await client.close().get()
        await forwarder.stop()
        try await proxy.close().get()
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
        let resolverManager = TunnelResolverManager(
            privilegeClient: recording, logger: logger, resolverDirectory: unscannedTunnelResolverDirectory(),
            work: PlatformWork(label: "io.github.srps.Conduit.tests.tunnel-forwarder")
        )

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

        let appliesAfterStart = recording.commands(matching: .applyDNS).map { $0[0] }
        XCTAssertTrue(appliesAfterStart.contains("reconcile-remove.example.com"),
                      "Initial start should apply a resolver file for the proxied hostname")

        // Reconcile with no definitions: the proxied tunnel is removed.
        let result = await forwarder.reconcile(newDefinitions: [], listenHost: "127.0.0.1")

        XCTAssertEqual(result.started, 0)
        XCTAssertEqual(result.dnsOverrideStatus, .notNeeded,
                       "dnsOverrideStatus must reflect the torn-down state, not the stale default")

        let removes = recording.commands(matching: .removeDNS).map { $0[0] }
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
        let resolverManager = TunnelResolverManager(
            privilegeClient: recording, logger: logger, resolverDirectory: unscannedTunnelResolverDirectory(),
            work: PlatformWork(label: "io.github.srps.Conduit.tests.tunnel-forwarder")
        )

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

        let removedDuringReconcile = recording.commands(matching: .removeDNS).map { $0[0] }
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

// MARK: - Test helpers

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
    /// Without `dials`, each CONNECT dials its target at once and nothing records the dial.
    static func start(group: EventLoopGroup, dials: MockProxyDials? = nil) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ConnectHandler(group: group, dials: dials))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    private final class ConnectHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let group: EventLoopGroup
        private let dials: MockProxyDials?
        private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
        private var upstream: Channel?
        private var tunnelEstablished = false

        init(group: EventLoopGroup, dials: MockProxyDials?) {
            self.group = group
            self.dials = dials
        }

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
            let group = self.group
            let connect: @Sendable () -> EventLoopFuture<Channel> = {
                ClientBootstrap(group: group)
                    .connectTimeout(.seconds(5))
                    .connect(host: host, port: port)
            }
            let dial: EventLoopFuture<Channel>
            if let dials {
                guard let recorded = dials.dial(connect) else {
                    context.close(promise: nil)
                    return
                }
                dial = recorded
            } else {
                dial = connect()
            }
            nonisolated(unsafe) let ctx = context
            let clientEL = context.eventLoop
            let clientChannel = context.channel

            dial
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

/// The mock proxy's dials to its CONNECT targets, recorded so a test can join them before its group shuts down. Each dial
/// starts only after `release()`, which lets a test hold a tunnel between the forwarder's CONNECT and the target. The record
/// has a fixed capacity and closes when joined; the mock refuses a CONNECT it does not admit.
private final class MockProxyDials: Sendable {
    static let capacity = 4

    /// Succeeds when the mock first asks to dial.
    let requested: EventLoopPromise<Void>
    private let gate: EventLoopPromise<Void>
    /// One lock covers admission and the list, so no dial is admitted after `join()` takes its snapshot.
    private let record = NIOLockedValueBox(Record())

    private struct Record {
        var closed = false
        var dials: [EventLoopFuture<Channel>] = []
    }

    /// The gate's failure when a test ends without releasing it: the held dial never starts.
    private struct NeverReleased: Error {}

    init(eventLoop: EventLoop) {
        requested = eventLoop.makePromise()
        gate = eventLoop.makePromise()
    }

    /// Records a dial that runs `connect` once the dials are released, or returns nil when the record is full or joined.
    func dial(_ connect: @escaping @Sendable () -> EventLoopFuture<Channel>) -> EventLoopFuture<Channel>? {
        let dial: EventLoopFuture<Channel>? = record.withLockedValue { record in
            guard !record.closed, record.dials.count < Self.capacity else { return nil }
            let dial = gate.futureResult.flatMap { connect() }
            record.dials.append(dial)
            return dial
        }
        if dial != nil { requested.succeed(()) }
        return dial
    }

    func release() {
        gate.succeed(())
    }

    /// Closes the record, ends any dial still held without starting it, then waits for every recorded dial to finish. It
    /// describes each dial that failed for another reason. Once closed, the record admits no dial, released or not. A
    /// connected dial's channel belongs to the mock, which closes it with its peer.
    func join() async -> [String] {
        let dials = record.withLockedValue { record in
            record.closed = true
            return record.dials
        }
        gate.fail(NeverReleased())
        requested.fail(NeverReleased())
        var failures: [String] = []
        for dial in dials {
            do {
                _ = try await dial.get()
            } catch is NeverReleased {
                continue
            } catch {
                failures.append("a mock proxy dial failed: \(error)")
            }
        }
        return failures
    }
}

/// Records every entry, and succeeds `signal` on the first tunnel entry that contains `marker`, so a test can wait for a
/// log line without polling.
private final class TunnelLogSignal: LogSink {
    let recording = RecordingLogSink(minLevel: .debug)
    private let marker: String
    private let signal: EventLoopPromise<Void>

    init(marker: String, signal: EventLoopPromise<Void>) {
        self.marker = marker
        self.signal = signal
    }

    var minLevel: LogLevel { recording.minLevel }

    func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        recording.logImpl(level, message, category: category)
        if category == .tunnel, message.contains(marker) { signal.succeed(()) }
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

/// Answers any CONNECT with a `200` and the first greeting in one write, then
/// the remaining greetings; it never needs the client to speak.
private final class GreetingConnectProxy: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let greetings: [[UInt8]]
    private var request: [UInt8] = []
    private var answered = false

    init(greetings: [[UInt8]]) { self.greetings = greetings }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        request += buffer.readBytes(length: buffer.readableBytes) ?? []
        guard !answered, String(decoding: request, as: UTF8.self).contains("\r\n\r\n") else { return }
        answered = true
        var out = context.channel.allocator.buffer(capacity: 256)
        out.writeString("HTTP/1.1 200 Connection Established\r\n\r\n")
        out.writeBytes(greetings[0])
        context.writeAndFlush(NIOAny(out), promise: nil)
        for later in greetings.dropFirst() {
            var next = context.channel.allocator.buffer(capacity: later.count)
            next.writeBytes(later)
            context.writeAndFlush(NIOAny(next), promise: nil)
        }
    }
}

private final class CollectBytes: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    private let count: Int
    private let promise: EventLoopPromise<[UInt8]>
    private var bytes: [UInt8] = []

    init(count: Int, promise: EventLoopPromise<[UInt8]>) {
        self.count = count
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        bytes += buffer.readBytes(length: buffer.readableBytes) ?? []
        if bytes.count >= count { promise.succeed(bytes) }
    }

    func channelInactive(context: ChannelHandlerContext) {
        promise.fail(ChannelError.eof)
    }
}
