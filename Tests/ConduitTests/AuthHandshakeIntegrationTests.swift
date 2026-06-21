// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Integration tests verifying that the CONNECT and HTTP exchange handshakes
/// reuse a single authenticator instance across the initial token and the 407
/// challenge-response, preserving stateful GSS context for multi-leg SPNEGO.
final class AuthHandshakeIntegrationTests: XCTestCase {

    // MARK: - CONNECT handshake authenticator reuse

    @MainActor
    func testCONNECTHandshakeReusesSameAuthenticatorInstance() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let mockProxy = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Mock407ThenOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = mockProxy.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 5000
        config.upstreams = [UpstreamProxy(name: "Mock", host: "127.0.0.1", port: port, priority: 0)]

        let spy = SpyAuthenticatorProvider()

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: spy.provide
        )
        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: spy.provide,
            logger: DiscardingLogSink()
        )

        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
        } catch {
            // Tunnel may fail due to mock limitations -- the auth handshake is what we test
        }

        XCTAssertEqual(spy.providerCallCount, 1,
            "authenticatorProvider should be called once per handshake, not per auth step")
        XCTAssertEqual(spy.uniqueInstanceCount, 1,
            "Exactly one authenticator instance should be created per handshake")

        let instance = try XCTUnwrap(spy.latestInstance)
        XCTAssertEqual(instance.initialTokenCallCount, 1, "initialToken must be called on the stored instance")
        XCTAssertEqual(instance.processChallengeCallCount, 1,
            "processChallenge must be called on the SAME instance that produced the initial token")

        pool.closeAll()
        try? await mockProxy.close().get()
    }

    // MARK: - HTTP exchange authenticator reuse

    @MainActor
    func testHTTPExchangeReusesSameAuthenticatorInstance() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let mockProxy = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(MockHTTP407ThenOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = mockProxy.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 5000
        config.upstreams = [UpstreamProxy(name: "Mock", host: "127.0.0.1", port: port, priority: 0)]

        let spy = SpyAuthenticatorProvider()

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: spy.provide
        )

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        do {
            _ = try await pool.exchange(head: head, body: nil).get()
        } catch {
            // May fail at the exchange level -- we only care about authenticator reuse
        }

        XCTAssertEqual(spy.providerCallCount, 1,
            "authenticatorProvider should be called once per handshake, not per auth step")
        XCTAssertEqual(spy.uniqueInstanceCount, 1,
            "Exactly one authenticator instance should be created per handshake")

        let instance = try XCTUnwrap(spy.latestInstance)
        XCTAssertEqual(instance.initialTokenCallCount, 1, "initialToken must be called on the stored instance")
        XCTAssertEqual(instance.processChallengeCallCount, 1,
            "processChallenge must be called on the SAME instance that produced the initial token")

        pool.closeAll()
        try? await mockProxy.close().get()
    }

    // MARK: - Stateful authenticator context preservation

    @MainActor
    func testStatefulAuthenticatorReceivesBothCallsOnSameInstance() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let mockProxy = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Mock407ThenOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = mockProxy.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 5000
        config.upstreams = [UpstreamProxy(name: "Mock", host: "127.0.0.1", port: port, priority: 0)]

        let statefulAuth = StatefulMockAuthenticator()
        let coordinator = CONNECTCoordinator(
            pool: ConnectionPool(
                group: group,
                logger: DiscardingLogSink(),
                configProvider: { config },
                authenticatorProvider: { _ in statefulAuth }
            ),
            authenticatorProvider: { _ in statefulAuth },
            logger: DiscardingLogSink()
        )

        _ = try? await coordinator.connectUpstreamTunnel(target: "example.com:443").get()

        XCTAssertGreaterThanOrEqual(statefulAuth.initialTokenCallCount, 1, "initialToken must be called")
        XCTAssertGreaterThanOrEqual(statefulAuth.processChallengeCallCount, 1, "processChallenge must be called")
        XCTAssertTrue(statefulAuth.processChallengeCalledAfterInitialToken,
            "processChallenge must be called on the same instance that produced the initial token")

        try? await mockProxy.close().get()
    }

    // MARK: - Fix: Auth failure must close upstream channel (no socket leak)

    @MainActor
    func testAuthFailureClosesUpstreamChannel() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        let mockProxy = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Mock407ThenOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = mockProxy.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 5000
        config.upstreams = [UpstreamProxy(name: "Mock", host: "127.0.0.1", port: port, priority: 0)]

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw KerberosAuthError.noTicket }
        )
        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in throw KerberosAuthError.noTicket },
            logger: DiscardingLogSink()
        )

        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            XCTFail("Should have thrown")
        } catch {
            // Expected
        }

        // Give the channel close a moment to propagate
        try await Task.sleep(for: .milliseconds(100))

        let snapshot = pool.allConnectionSnapshot
        XCTAssertTrue(snapshot.isEmpty,
            "After auth failure, no connections should remain in the pool (found \(snapshot.count))")

        pool.closeAll()
        try? await mockProxy.close().get()
    }

    // MARK: - Fix 3: Slow auth must not block event loop

    @MainActor
    func testSlowAuthDoesNotBlockEventLoop() async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        let mockProxy = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(Mock407ThenOKHandler())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = mockProxy.localAddress!.port!

        var config = ProxyConfig.testFixture()
        config.connectionCheckTimeoutMS = 5000
        config.upstreams = [UpstreamProxy(name: "Mock", host: "127.0.0.1", port: port, priority: 0)]

        let slowAuth = SlowMockAuthenticator(delayMS: 200)

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in slowAuth }
        )
        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in slowAuth },
            logger: DiscardingLogSink()
        )

        let start = Date()
        let el = group.next()
        let canSchedule = el.makePromise(of: Void.self)

        el.execute { canSchedule.succeed(()) }

        _ = try? await coordinator.connectUpstreamTunnel(target: "example.com:443").get()

        let elResponded = el.makePromise(of: Void.self)
        el.execute { elResponded.succeed(()) }
        try await elResponded.futureResult.get()

        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 3.0, "Event loop should remain responsive even with slow auth (200ms delay)")

        pool.closeAll()
        try? await mockProxy.close().get()
    }

    // MARK: - setAuthenticatorProvider late-binding

    /// Regression guard. Before the
    /// `authenticatorBox` refactor, the three consumer lazy vars
    /// (`localProxyServer`, `tunnelConnectionPool`, `tunnelCoordinator`)
    /// captured `authenticatorProvider` by value on first access — meaning a
    /// `setAuthenticatorProvider(...)` call after `startProxy()` /
    /// `startTunnels()` would silently be ignored by those captured closures.
    ///
    /// This test simulates the capture by grabbing
    /// `lateBoundAuthenticatorProvider` (the same closure the lazy vars see)
    /// BEFORE the setter runs, then invokes it AFTER the setter to prove the
    /// box-dereferencing indirection makes the capture late-bound. If this
    /// test fails, the footgun has been reintroduced — either by removing the
    /// `authenticatorBox` indirection or by changing the lazy vars to capture
    /// a snapshot of the box contents instead of the closure.
    @MainActor
    func testSetAuthenticatorProviderIsLateBoundForLazyConsumers() throws {
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink()
        )

        // Capture the accessor exactly as the three lazy consumers do at
        // first-access time.
        let capturedAccessor = orchestrator.lateBoundAuthenticatorProvider

        // Invoking it now should hit the init-time default closure that
        // throws `ProxyAuthenticatorNotConfiguredError`. Proves the captor
        // is live, not stubbed.
        XCTAssertThrowsError(try capturedAccessor("127.0.0.1:1234")) { error in
            XCTAssertTrue(error is ProxyAuthenticatorNotConfiguredError,
                          "Pre-setter capture should throw default-not-configured, got: \(error)")
        }

        // Install a spy provider AFTER the accessor was captured.
        let spy = SpyAuthenticatorProvider()
        orchestrator.setAuthenticatorProvider(spy.provide)

        // Invoke the previously-captured accessor. The box-dereferencing
        // indirection must route to the spy. Without the `authenticatorBox`
        // refactor, `capturedAccessor` would still be bound to the init-time
        // default closure and this call would throw.
        _ = try capturedAccessor("127.0.0.1:1234")
        XCTAssertEqual(spy.providerCallCount, 1,
                       "Late-bound accessor must dereference authenticatorBox per call; " +
                       "a missed call here means setAuthenticatorProvider after lazy-var " +
                       "capture is a silent no-op (the pre-review footgun).")

        // Second swap: install a different provider, confirm the accessor
        // picks up the newer value too (not just the first setter call).
        let secondSpy = SpyAuthenticatorProvider()
        orchestrator.setAuthenticatorProvider(secondSpy.provide)
        _ = try capturedAccessor("example.com:8080")
        XCTAssertEqual(secondSpy.providerCallCount, 1,
                       "Subsequent setAuthenticatorProvider swaps must also be observed.")
        XCTAssertEqual(spy.providerCallCount, 1,
                       "Stale spy should not receive further calls after the second swap.")
    }

    @MainActor
    func testAuthOutcomeHandlerUpdatesHeadlessOrchestratorSnapshotAndEvents() async throws {
        let upstream = UpstreamProxy(name: "Mock", host: "proxy.example.com", port: 8080, priority: 0)
        var config = ProxyConfig.testFixture()
        config.authMode = .ntlmv2
        config.upstreams = [upstream]

        let credentialProvider = InMemoryCredentialProvider()
        try credentialProvider.setCredentials(
            ProxyCredentials(
                username: "user",
                domain: "DOMAIN",
                workstation: "WS",
                ntHash: SecretBytes.repeating(0xAA, count: 16)
            ),
            for: upstream
        )

        let logger = RecordingLogSink(minLevel: .debug)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger)
        let provider = credentialBasedAuthenticatorProvider(
            configProvider: orchestrator.configSnapshotProvider,
            credentialProvider: credentialProvider,
            outcomeHandler: { [weak orchestrator] outcome, host, reason in
                orchestrator?.reportAuthOutcome(outcome, host: host, reason: reason)
            }
        )

        _ = try provider(upstream.endpoint)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(orchestrator.snapshot.lastAuthOutcome, .ntlmDirect)
        XCTAssertNil(orchestrator.snapshot.lastAuthFallbackReason)
        XCTAssertEqual(orchestrator.eventLog.events.last?.kind, .auth)
        XCTAssertEqual(orchestrator.eventLog.events.last?.event, "auth.ntlm_configured")
        XCTAssertEqual(orchestrator.eventLog.events.last?.detail, "host=\(upstream.endpoint)")
        XCTAssertTrue(logger.containsMessage("Using NTLMv2 (configured) for \(upstream.endpoint).", at: .notice))
    }
}

// MARK: - Spy Provider

/// Tracks authenticator creation and call patterns. After the fix, the provider
/// should be called once per handshake, and the single instance should receive
/// both `initialToken` and `processChallenge` calls.
private final class SpyAuthenticatorProvider: @unchecked Sendable {
    private let lock = NSLock()
    private var _callCount = 0
    private var _instances: [TrackingMockAuthenticator] = []

    var providerCallCount: Int {
        lock.withLock { _callCount }
    }

    var uniqueInstanceCount: Int {
        lock.withLock { Set(_instances.map { ObjectIdentifier($0) }).count }
    }

    var latestInstance: TrackingMockAuthenticator? {
        lock.withLock { _instances.last }
    }

    func provide(host: String) throws -> ProxyAuthenticator {
        lock.lock()
        _callCount += 1
        let instance = TrackingMockAuthenticator()
        _instances.append(instance)
        lock.unlock()
        return instance
    }
}

private final class TrackingMockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    private let lock = NSLock()
    private var _initialTokenCalls = 0
    private var _processChallengeCalls = 0

    var initialTokenCallCount: Int { lock.withLock { _initialTokenCalls } }
    var processChallengeCallCount: Int { lock.withLock { _processChallengeCalls } }

    func initialToken(for host: String) throws -> String {
        lock.withLock { _initialTokenCalls += 1 }
        return "Negotiate FakeInitialToken"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        lock.withLock { _processChallengeCalls += 1 }
        return "Negotiate FakeChallengeResponse"
    }

    func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
    }

    func reset() {}
}

// MARK: - Slow Mock Authenticator

private final class SlowMockAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"
    private let delayMS: UInt32

    init(delayMS: UInt32) {
        self.delayMS = delayMS
    }

    func initialToken(for host: String) throws -> String {
        usleep(delayMS * 1000)
        return "Negotiate FakeSlowToken"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        usleep(delayMS * 1000)
        return "Negotiate FakeSlowResponse"
    }

    func canHandle(scheme: String) -> Bool {
        scheme.caseInsensitiveCompare("Negotiate") == .orderedSame
    }

    func reset() {}
}

// MARK: - Mock Proxy Servers

/// Simulates a proxy that replies 407 (Proxy-Authenticate: Negotiate) on the first
/// CONNECT, then 200 on the second (after receiving Proxy-Authorization with challenge-response).
private final class Mock407ThenOKHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var requestCount = 0
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        accumulated.writeBuffer(&buf)

        guard let str = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              str.contains("\r\n\r\n") else {
            return
        }

        accumulated.clear()
        requestCount += 1

        let response: String
        if requestCount == 1 {
            response = "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                "Proxy-Authenticate: Negotiate\r\n" +
                "Content-Length: 0\r\n" +
                "\r\n"
        } else {
            response = "HTTP/1.1 200 Connection Established\r\n" +
                "Content-Length: 0\r\n" +
                "\r\n"
        }

        var outBuf = context.channel.allocator.buffer(capacity: response.utf8.count)
        outBuf.writeString(response)
        context.writeAndFlush(NIOAny(outBuf), promise: nil)
    }
}

/// Simulates a proxy that replies 407 on the first HTTP request, then 200 with a body on the second.
private final class MockHTTP407ThenOKHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var requestCount = 0
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buf = unwrapInboundIn(data)
        accumulated.writeBuffer(&buf)

        guard let str = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              str.contains("\r\n\r\n") else {
            return
        }

        accumulated.clear()
        requestCount += 1

        let response: String
        if requestCount == 1 {
            response = "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                "Proxy-Authenticate: Negotiate\r\n" +
                "Content-Length: 0\r\n" +
                "Connection: Keep-Alive\r\n" +
                "\r\n"
        } else {
            let body = "OK"
            response = "HTTP/1.1 200 OK\r\n" +
                "Content-Length: \(body.count)\r\n" +
                "Connection: Keep-Alive\r\n" +
                "\r\n" + body
        }

        var outBuf = context.channel.allocator.buffer(capacity: response.utf8.count)
        outBuf.writeString(response)
        context.writeAndFlush(NIOAny(outBuf), promise: nil)
    }
}
