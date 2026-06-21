// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

final class ConnectionPoolTests: XCTestCase {
    @MainActor func testSwitchToNextUpstreamRotatesOrder() async throws {
        let pool = makePool()
        defer { pool.closeAll() }

        let first = pool.activeUpstream()
        let second = pool.switchToNextUpstream()
        let third = pool.switchToNextUpstream()

        XCTAssertEqual(first, "proxy-a.example.test:8080")
        XCTAssertEqual(second, "proxy-b.example.test:8080")
        XCTAssertEqual(third, "proxy-c.example.test:8080")
    }

    @MainActor func testSwitchToNextUpstreamWrapsAround() async throws {
        let pool = makePool()
        defer { pool.closeAll() }

        let config = ProxyConfig.testFixture()
        let count = config.enabledUpstreams.count
        for _ in 0..<count {
            _ = pool.switchToNextUpstream()
        }
        let wrapped = pool.activeUpstream()
        XCTAssertEqual(wrapped, "proxy-a.example.test:8080", "Should wrap back to first upstream after cycling through all \(count)")
    }

    @MainActor func testActiveUpstreamReturnsNilWhenEmpty() {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        var cleared = ProxyConfig.testFixture()
        cleared.upstreams = []

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { cleared },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        XCTAssertNil(pool.activeUpstream())
        XCTAssertNil(pool.switchToNextUpstream())
    }

    @MainActor func testResetAuthenticationClearsPoolState() {
        let pool = makePool()
        defer { pool.closeAll() }
        pool.resetAuthentication()
    }

    // MARK: - Stalled connection cleanup

    @MainActor func testCloseStalledConnectionsDoesNotCrashWhenEmpty() {
        let pool = makePool()
        defer { pool.closeAll() }
        pool.closeStalledConnections(olderThan: 0)
    }

    // MARK: - Close all

    @MainActor func testCloseAllIdempotent() {
        let pool = makePool()
        pool.closeAll()
        pool.closeAll()
    }

    @MainActor func testCloseAllScopedIdempotent() {
        let pool = makePool()
        pool.closeAll(scope: .all)
        pool.closeAll(scope: .allButDedicated)
        pool.closeAll(scope: .idleOnly)
    }

    // MARK: - CloseScope filter semantics

    func testConnectionIDsToCloseAllReturnsEverything() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let dedicated = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        dedicated.isDedicatedTunnel = true
        let pooled = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())

        let ids = ConnectionPool.connectionIDsToClose(from: [dedicated, pooled], scope: .all)
        XCTAssertEqual(ids, Set([dedicated.id, pooled.id]),
                       ".all must select every connection regardless of dedicated/in-use state")
    }

    func testConnectionIDsToCloseAllButDedicatedPreservesTunnels() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let dedicated = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        dedicated.isDedicatedTunnel = true
        let pooled = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())

        let ids = ConnectionPool.connectionIDsToClose(from: [dedicated, pooled], scope: .allButDedicated)
        XCTAssertFalse(ids.contains(dedicated.id),
                       "Dedicated CONNECT tunnels must survive .allButDedicated for HTTPS-stream preservation")
        XCTAssertTrue(ids.contains(pooled.id),
                      "Non-dedicated pooled connections should be closed by .allButDedicated")
    }

    func testConnectionIDsToCloseIdleOnlyPreservesDedicated() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let dedicated = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())
        dedicated.isDedicatedTunnel = true
        let idle = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())

        let ids = ConnectionPool.connectionIDsToClose(from: [dedicated, idle], scope: .idleOnly)
        XCTAssertFalse(ids.contains(dedicated.id),
                       "Dedicated CONNECT tunnels must survive .idleOnly")
        XCTAssertTrue(ids.contains(idle.id),
                      "Idle non-dedicated connection should be closed by .idleOnly")
    }

    func testConnectionIDsToCloseIdleOnlyPreservesInUse() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let inUse = PooledUpstreamConnection.makeForTesting(
            proxy: proxy, channel: EmbeddedChannel(), inUse: true
        )
        let idle = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())

        let ids = ConnectionPool.connectionIDsToClose(from: [inUse, idle], scope: .idleOnly)
        XCTAssertFalse(ids.contains(inUse.id),
                       "In-use pooled connection must survive .idleOnly (mid-exchange)")
        XCTAssertTrue(ids.contains(idle.id),
                      "Idle non-dedicated connection should be closed by .idleOnly")
    }

    func testConnectionIDsToCloseIdleOnlyPreservesInUseAndDedicated() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let inUseDedicated = PooledUpstreamConnection.makeForTesting(
            proxy: proxy, channel: EmbeddedChannel(),
            inUse: true, isDedicatedTunnel: true
        )
        let inUsePooled = PooledUpstreamConnection.makeForTesting(
            proxy: proxy, channel: EmbeddedChannel(), inUse: true
        )
        let idleDedicated = PooledUpstreamConnection.makeForTesting(
            proxy: proxy, channel: EmbeddedChannel(), isDedicatedTunnel: true
        )
        let idlePooled = PooledUpstreamConnection(proxy: proxy, channel: EmbeddedChannel())

        let ids = ConnectionPool.connectionIDsToClose(
            from: [inUseDedicated, inUsePooled, idleDedicated, idlePooled],
            scope: .idleOnly
        )
        XCTAssertEqual(ids, Set([idlePooled.id]),
                       ".idleOnly must close exactly the idle-and-non-dedicated connection " +
                       "(both inUse=true and isDedicatedTunnel=true axes are preservation criteria)")
    }

    func testConnectionIDsToCloseAllButDedicatedClosesInUseNonDedicated() {
        let proxy = ProxyConfig.testFixture().enabledUpstreams[0]
        let inUsePooled = PooledUpstreamConnection.makeForTesting(
            proxy: proxy, channel: EmbeddedChannel(), inUse: true
        )
        let inUseDedicated = PooledUpstreamConnection.makeForTesting(
            proxy: proxy, channel: EmbeddedChannel(),
            inUse: true, isDedicatedTunnel: true
        )

        let ids = ConnectionPool.connectionIDsToClose(
            from: [inUsePooled, inUseDedicated],
            scope: .allButDedicated
        )
        XCTAssertTrue(ids.contains(inUsePooled.id),
                      ".allButDedicated must close in-use non-dedicated connections " +
                      "(config-driven listener restart: pool entries can't survive a new pool)")
        XCTAssertFalse(ids.contains(inUseDedicated.id),
                       ".allButDedicated must always preserve dedicated CONNECT tunnels " +
                       "regardless of inUse state — they're byte-relays independent of the pool")
    }

    func testConnectionIDsToCloseEmptyCollection() {
        for scope in [CloseScope.all, .allButDedicated, .idleOnly] {
            let ids = ConnectionPool.connectionIDsToClose(
                from: [] as [PooledUpstreamConnection],
                scope: scope
            )
            XCTAssertTrue(ids.isEmpty, "Empty collection should yield empty close set for \(scope)")
        }
    }

    // MARK: - Upstream half-open fallback

    func testApplyHalfOpenUpstreamFallback_validRemoteAddress_passesThroughWithoutFallback() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in channel.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
        addTeardownBlock { try? server.close().wait() }

        let clientChannel = try await ClientBootstrap(group: group)
            .connect(to: server.localAddress!).get()
        addTeardownBlock { try? clientChannel.close().wait() }

        let proxy = UpstreamProxy(name: "PAC de", host: "localhost", port: 8080, priority: 0)
        actor FallbackWitness { var invoked = false; func mark() { invoked = true } }
        let witness = FallbackWitness()

        let result = try await ConnectionPool.applyHalfOpenUpstreamFallback(
            upstreamChannel: clientChannel,
            proxy: proxy,
            on: clientChannel.eventLoop,
            ipv4Reconnect: { _ in
                Task { await witness.mark() }
                return clientChannel.eventLoop.makeFailedFuture(ChannelError.alreadyClosed)
            }
        ).get()

        let fallbackFired = await witness.invoked
        XCTAssertFalse(fallbackFired)
        XCTAssertTrue(result === clientChannel)
    }

    func testApplyHalfOpenUpstreamFallback_nilRemoteAddress_reconnectsToProxyIPv4() async throws {
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        let halfOpen = EmbeddedChannel(loop: EmbeddedEventLoop())
        let replacement = EmbeddedChannel(loop: EmbeddedEventLoop())
        let proxy = UpstreamProxy(name: "PAC de", host: "localhost", port: 8080, priority: 0)

        struct WitnessState {
            var invoked = false
            var address: SocketAddress?
        }
        let witness = NIOLockedValueBox(WitnessState())

        let result = try await ConnectionPool.applyHalfOpenUpstreamFallback(
            upstreamChannel: halfOpen,
            proxy: proxy,
            on: loop,
            ipv4Reconnect: { address in
                witness.withLockedValue {
                    $0.invoked = true
                    $0.address = address
                }
                return loop.makeSucceededFuture(replacement as Channel)
            }
        ).get()

        let fired = witness.withLockedValue { $0.invoked }
        let receivedAddress = witness.withLockedValue { $0.address }
        XCTAssertTrue(fired)
        XCTAssertEqual(receivedAddress?.ipAddress, "127.0.0.1")
        XCTAssertEqual(receivedAddress?.port, 8080)
        XCTAssertTrue(result === replacement)
    }

    // MARK: - streamingExchange with no upstreams

    @MainActor func testStreamingExchangeNoUpstreamsFails() async {
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

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://test.com/")
        do {
            _ = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
            XCTFail("Expected failure with no upstreams")
        } catch {
            // Expected
        }

        try? await clientChannel.close().get()
    }

    // MARK: - exchange (buffered) with no upstreams

    @MainActor func testBufferedExchangeNoUpstreamsFails() async {
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

        let head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://test.com/")
        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("Expected failure with no upstreams")
        } catch {
            // Expected
        }
    }

    // MARK: - Auth handshake local throttling

    @MainActor func testAuthHandshakeLimitDoesNotRecordBufferedUpstreamFailure() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let upstream = try await Self.startAcceptingServer(group: group)
        addTeardownBlock { try? upstream.close().wait() }

        let port = try XCTUnwrap(upstream.localAddress?.port)
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "upstream", host: "127.0.0.1", port: port, priority: 0)]
        config.pendingAuthHandshakeGlobalLimit = 1
        config.pendingAuthHandshakesPerSource = 1
        config.circuitBreakerWindowSeconds = 0

        let limiter = AuthHandshakeLimiter()
        let heldPermit = Self.tryAcquireAuthPermit(limiter, limits: AuthHandshakeLimiter.Limits(total: 1, perSource: 1))
        defer { heldPermit.release() }

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in
                XCTFail("authenticatorProvider should not be invoked when local auth limiter rejects")
                throw ConnectionPoolError.authenticationUnavailable
            },
            authHandshakeLimiter: limiter
        )
        defer { pool.closeAll() }

        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")

        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("exchange should fail with local auth throttle")
        } catch ConnectionPoolError.authHandshakeLimitExceeded {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let status = try XCTUnwrap(pool.upstreamStatuses().first)
        XCTAssertEqual(status.consecutiveFailures, 0)
        XCTAssertEqual(status.circuitState, .closed)
    }

    @MainActor func testAuthHandshakeLimitDoesNotRecordStreamingUpstreamFailure() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let upstream = try await Self.startAcceptingServer(group: group)
        addTeardownBlock { try? upstream.close().wait() }

        let port = try XCTUnwrap(upstream.localAddress?.port)
        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "upstream", host: "127.0.0.1", port: port, priority: 0)]
        config.pendingAuthHandshakeGlobalLimit = 1
        config.pendingAuthHandshakesPerSource = 1
        config.circuitBreakerWindowSeconds = 0

        let limiter = AuthHandshakeLimiter()
        let heldPermit = Self.tryAcquireAuthPermit(limiter, limits: AuthHandshakeLimiter.Limits(total: 1, perSource: 1))
        defer { heldPermit.release() }

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in
                XCTFail("authenticatorProvider should not be invoked when local auth limiter rejects")
                throw ConnectionPoolError.authenticationUnavailable
            },
            authHandshakeLimiter: limiter
        )
        defer { pool.closeAll() }

        let clientChannel = EmbeddedChannel()
        addTeardownBlock { try? clientChannel.close().wait() }
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")

        do {
            _ = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
            XCTFail("streaming exchange should fail with local auth throttle")
        } catch ConnectionPoolError.authHandshakeLimitExceeded {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let status = try XCTUnwrap(pool.upstreamStatuses().first)
        XCTAssertEqual(status.consecutiveFailures, 0)
        XCTAssertEqual(status.circuitState, .closed)
    }

    func testStreamingInterruptedDetailPreservesOriginalCause() {
        let event = ConnectionPool.streamingResponseInterruptedEvent(
            uri: "http://example.com/resource",
            upstream: "proxy.example:8080",
            cause: ChannelError.eof
        )
        let detail = try! XCTUnwrap(event.detail)

        XCTAssertEqual(event.kind, .connection)
        XCTAssertEqual(event.event, "streaming.response_interrupted")
        XCTAssertTrue(detail.contains("uri=http://example.com/resource"))
        XCTAssertTrue(detail.contains("upstream=proxy.example:8080"))
        XCTAssertTrue(detail.contains("cause="))
        XCTAssertFalse(detail.contains(ConnectionPoolError.streamingResponseInterrupted.localizedDescription))
    }

    @MainActor func testAuthHandshakeLimitDoesNotRetryConnectAcrossUpstreams() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let liveUpstream = try await Self.startAcceptingServer(group: group)
        addTeardownBlock { try? liveUpstream.close().wait() }

        let livePort = try XCTUnwrap(liveUpstream.localAddress?.port)
        var config = ProxyConfig.testFixture()
        let invalidRetryProxy = UpstreamProxy(name: "invalid-retry", host: "127.0.0.1", port: 9, priority: 0)
        let liveProxy = UpstreamProxy(name: "live", host: "127.0.0.1", port: livePort, priority: 1)
        // `chooseProxyLocked` starts with index 1 for a two-upstream pool, so
        // the live proxy is the first attempted upstream. If the local auth
        // throttle is incorrectly retried, `switchToNextUpstream()` moves to
        // the invalid port and the final error will no longer be the local
        // throttle signal.
        config.upstreams = [invalidRetryProxy, liveProxy]
        config.pendingAuthHandshakeGlobalLimit = 1
        config.pendingAuthHandshakesPerSource = 1
        config.circuitBreakerWindowSeconds = 0

        let limiter = AuthHandshakeLimiter()
        let heldPermit = Self.tryAcquireAuthPermit(limiter, limits: AuthHandshakeLimiter.Limits(total: 1, perSource: 1))
        defer { heldPermit.release() }

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in
                XCTFail("authenticatorProvider should not be invoked when local auth limiter rejects")
                throw ConnectionPoolError.authenticationUnavailable
            },
            authHandshakeLimiter: limiter
        )
        defer { pool.closeAll() }

        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in
                XCTFail("authenticatorProvider should not be invoked when local auth limiter rejects")
                throw ConnectionPoolError.authenticationUnavailable
            },
            logger: DiscardingLogSink(),
            authHandshakeLimiter: limiter,
            authLimitProvider: { AuthHandshakeLimiter.Limits(total: 1, perSource: 1) }
        )

        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "example.com:443").get()
            XCTFail("CONNECT should fail with local auth throttle")
        } catch ConnectionPoolError.authHandshakeLimitExceeded {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(pool.activeUpstream(), liveProxy.endpoint, "local throttling must not rotate to the next upstream")
        for status in pool.upstreamStatuses() {
            XCTAssertEqual(status.consecutiveFailures, 0, "local throttling must not poison \(status.endpoint)")
            XCTAssertEqual(status.circuitState, .closed)
        }
    }

    // MARK: - Pool exhaustion with pendingConnectionCount

    @MainActor func testPoolExhaustedWhenMaxConnectionsReached() async {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)

        var config = ProxyConfig.testFixture()
        config.maxConnections = 1
        config.connectionCheckTimeoutMS = 500
        config.upstreams = [
            UpstreamProxy(name: "Slow", host: "192.0.2.1", port: 9999, priority: 0)
        ]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(username: "test", domain: "TEST", workstation: "MAC", ntHash: SecretBytes.repeating(0, count: 16)))
            }
        )
        defer { pool.closeAll() }

        let head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://example.com/")

        async let first: Void = {
            _ = try? await pool.exchange(head: head, body: nil).get()
        }()

        try? await Task.sleep(for: .milliseconds(50))

        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("Second exchange should fail with poolExhausted")
        } catch let error as ConnectionPoolError {
            XCTAssertEqual(error, .poolExhausted,
                           "With maxConnections=1 and one pending connect, second request should be rejected")
        } catch {
            // Connection error is also acceptable if the first slot connected and failed
        }

        _ = await first
    }

    @MainActor func testBufferedPoolExhaustionDoesNotRecordUpstreamFailure() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        var config = ProxyConfig.testFixture()
        config.maxConnections = 0
        config.circuitFailureThreshold = 1
        config.circuitBreakerWindowSeconds = 0

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        defer { pool.closeAll() }

        let head = HTTPRequestHead(version: .http1_1, method: .HEAD, uri: "http://example.com/")
        do {
            _ = try await pool.exchange(head: head, body: nil).get()
            XCTFail("exchange should fail with poolExhausted")
        } catch ConnectionPoolError.poolExhausted {
            // Expected: local capacity, not upstream health.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let status = try XCTUnwrap(pool.upstreamStatuses().first)
        XCTAssertEqual(status.consecutiveFailures, 0, "pool exhaustion must not poison upstream failure counters")
        XCTAssertEqual(status.circuitState, .closed, "pool exhaustion must not trip the upstream breaker")
    }

    @MainActor func testStreamingPoolExhaustionDoesNotRecordUpstreamFailure() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        var config = ProxyConfig.testFixture()
        config.maxConnections = 0
        config.circuitFailureThreshold = 1
        config.circuitBreakerWindowSeconds = 0

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        defer { pool.closeAll() }

        let clientChannel = EmbeddedChannel()
        addTeardownBlock { try? clientChannel.close().wait() }
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        do {
            _ = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
            XCTFail("streaming exchange should fail with poolExhausted")
        } catch ConnectionPoolError.poolExhausted {
            // Expected: local capacity, not upstream health.
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        let status = try XCTUnwrap(pool.upstreamStatuses().first)
        XCTAssertEqual(status.consecutiveFailures, 0, "streaming pool exhaustion must not poison upstream failure counters")
        XCTAssertEqual(status.circuitState, .closed, "streaming pool exhaustion must not trip the upstream breaker")
    }

    @MainActor func testStreamingAcquireConnectionFailureRecordsUpstreamFailure() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let server = try await Self.startAcceptingServer(group: group)
        let refusedPort = try XCTUnwrap(server.localAddress?.port)
        try await server.close().get()

        var config = ProxyConfig.testFixture()
        config.upstreams = [
            UpstreamProxy(name: "refused", host: "127.0.0.1", port: refusedPort, priority: 0)
        ]
        config.circuitFailureThreshold = 1
        config.circuitBreakerWindowSeconds = 0

        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        defer { pool.closeAll() }

        let clientChannel = EmbeddedChannel()
        addTeardownBlock { try? clientChannel.close().wait() }
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "http://example.com/")
        do {
            _ = try await pool.streamingExchange(head: head, body: nil, clientChannel: clientChannel).get()
            XCTFail("streaming exchange should fail when upstream connect is refused")
        } catch ConnectionPoolError.poolExhausted {
            XCTFail("connect-refused should be reported as an upstream connection error, not local capacity")
        } catch {
            // Expected: acquireConnection failed before streaming exchange began.
        }

        let status = try XCTUnwrap(pool.upstreamStatuses().first)
        XCTAssertEqual(status.circuitState, .open, "streaming acquireConnection failure must feed the breaker")
        XCTAssertEqual(status.consecutiveFailures, 0, "trip resets the counter after opening")
    }

    @MainActor func testDedicatedTunnelRespectsMaxConnections() async throws {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup.singleton

        var config = ProxyConfig.testFixture()
        config.maxConnections = 0
        let proxy = config.enabledUpstreams[0]

        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in throw CredentialManagerError.missingCredentials }
        )
        defer { pool.closeAll() }

        do {
            _ = try await pool.makeDedicatedTunnelConnection(forcedProxy: proxy).get()
            XCTFail("Dedicated CONNECT tunnel acquisition should respect maxConnections")
        } catch ConnectionPoolError.poolExhausted {
            // Expected.
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    @MainActor func testCircuitBreakerOpensAfterThresholdAndClosesOnSuccess() {
        let logger = DiscardingLogSink()
        // Phase 5: this test exercises the threshold-trip semantic in isolation.
        // The default 10s time-window guard would prevent a synchronous burst
        // of 5 failures from tripping the breaker (intentionally — that's the
        // whole point of Phase 5). Set circuitBreakerWindowSeconds = 0 to
        // disable the guard and restore legacy burst-trip behavior; the
        // sync-burst-no-trip semantic is covered separately by
        // CircuitBreakerWindowTests.
        var config = ProxyConfig.testFixture()
        config.circuitBreakerWindowSeconds = 0
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(
                    username: config.username,
                    domain: config.domain,
                    workstation: config.workstation,
                    ntHash: SecretBytes.repeating(0x22, count: 16)
                ))
            }
        )
        defer { pool.closeAll() }

        let proxy = config.enabledUpstreams[0]
        for _ in 0..<5 {
            pool.recordDedicatedTunnelFailure(for: proxy)
        }

        let opened = pool.upstreamStatuses().first { $0.id == proxy.id }
        XCTAssertEqual(opened?.circuitState, .open)
        XCTAssertNotNil(opened?.openUntil)

        pool.recordDedicatedTunnelSuccess(for: proxy, latencyMS: 120)

        let closed = pool.upstreamStatuses().first { $0.id == proxy.id }
        XCTAssertEqual(closed?.circuitState, .closed)
        XCTAssertEqual(closed?.consecutiveFailures, 0)
        XCTAssertEqual(closed?.ewmaLatencyMS, 120)
        XCTAssertNil(closed?.openUntil)
    }

    @MainActor func testUpstreamStatusesTrackEWMA() {
        let logger = DiscardingLogSink()
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        let pool = ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(
                    username: config.username,
                    domain: config.domain,
                    workstation: config.workstation,
                    ntHash: SecretBytes.repeating(0x22, count: 16)
                ))
            }
        )
        defer { pool.closeAll() }

        let proxy = config.enabledUpstreams[0]
        pool.recordDedicatedTunnelSuccess(for: proxy, latencyMS: 100)
        pool.recordDedicatedTunnelSuccess(for: proxy, latencyMS: 200)

        let status = pool.upstreamStatuses().first { $0.id == proxy.id }
        XCTAssertEqual(status?.circuitState, .closed)
        XCTAssertNotNil(status?.ewmaLatencyMS)
        XCTAssertEqual(status?.ewmaLatencyMS ?? 0, 130, accuracy: 0.001)
    }

    // MARK: - Helper

    @MainActor
    private func makePool() -> ConnectionPool {
        let logger = DiscardingLogSink()
        let config = ProxyConfig.testFixture()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)

        return ConnectionPool(
            group: group,
            logger: logger,
            configProvider: { config },
            authenticatorProvider: { _ in
                NTLMAuthenticator(credentials: ProxyCredentials(
                    username: config.username,
                    domain: config.domain,
                    workstation: config.workstation,
                    ntHash: SecretBytes.repeating(0x22, count: 16)
                ))
            }
        )
    }

    private static func startAcceptingServer(group: EventLoopGroup) async throws -> Channel {
        try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                return channel.eventLoop.makeSucceededFuture(())
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
    }

    private static func tryAcquireAuthPermit(
        _ limiter: AuthHandshakeLimiter,
        limits: AuthHandshakeLimiter.Limits
    ) -> AuthHandshakePermit {
        switch limiter.acquire(source: nil, limits: limits) {
        case .success(let permit):
            return permit
        case .failure(let rejection):
            XCTFail("unexpected rejection: \(rejection)")
            fatalError("unreachable")
        }
    }
}
