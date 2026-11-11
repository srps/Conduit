// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A tunnel's upstream selection holds the half-open probe slot it claimed,
/// and the attempt settles exactly that claim: a failover asks no upstream in
/// its backoff, an attempt given up frees only its own slot, and a refused
/// dial is charged.
final class TunnelSelectionTests: XCTestCase {
    private let group = MultiThreadedEventLoopGroup.singleton
    private var servers: [Channel] = []
    private var authenticating: [AuthenticatingUpstream] = []

    override func tearDown() async throws {
        for server in servers { try await server.close().get() }
        for upstream in authenticating { await upstream.stop() }
        servers = []
        authenticating = []
        try await super.tearDown()
    }

    /// Before, a failover forced an open upstream into a half-open probe as
    /// soon as it was the only one left to try, skipping its backoff. A 403
    /// from the healthy one then dialled the one in backoff and waited out
    /// its silence; the client should get the 403 at once.
    func testAFailoverAsksNoUpstreamInItsBackoff() async throws {
        let forbidding = try await scripted { _ in .answer("HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\n\r\n") }
        let silent = try await scripted { _ in .silent }
        let setup = makeCoordinator(upstreams: [("A", forbidding.port), ("B", silent.port)])
        let (pool, coordinator) = (setup.pool, setup.coordinator)
        for _ in 0..<setup.threshold { pool.recordConnectFailure(for: setup.upstreams[1]) }
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.closed, .open], "precondition")

        let started = Date()
        do {
            _ = try await coordinator.connectUpstreamTunnel(target: "blocked.corp.example:443").get()
            XCTFail("the 403 was tunnelled")
        } catch {
            guard case .upstreamReturnedStatus(403, _)? = error as? ConnectionPoolError else {
                return XCTFail("the 403 should stand, got \(error)")
            }
        }

        XCTAssertEqual(silent.accepted, 0, "the upstream in its backoff was not dialled")
        XCTAssertLessThan(Date().timeIntervalSince(started), 2, "no upstream's silence was waited out")
        XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.closed, .open])
    }

    /// A tunnel given up after its selection claimed P's probe and before
    /// the dial gives that slot back, so the next request probes P.
    func testATunnelGivenUpBeforeItsDialFreesTheProbeItClaimed() async throws {
        let harness = try await probeHarness()
        let reads = NIOLockedValueBox(0)
        // The stop lands between the selection and the dial.
        let isWanted: @Sendable () -> Bool = { reads.withLockedValue { $0 += 1; return $0 <= 1 } }

        await assertAbandoned(harness.coordinator.connectUpstreamTunnel(target: "a.corp.example:443", isWanted: isWanted))

        try await harness.assertTheNextRequestProbesP()
    }

    /// A dial refused after its caller gave the tunnel up is not charged,
    /// and gives back the probe slot its selection claimed.
    func testADialRefusedAfterTheStopFreesTheProbeItClaimed() async throws {
        let harness = try await probeHarness()
        let reads = NIOLockedValueBox(0)
        // Wanted through the selection and the dial; given up before the refusal is seen.
        let isWanted: @Sendable () -> Bool = { reads.withLockedValue { $0 += 1; return $0 <= 2 } }

        await assertAbandoned(harness.coordinator.connectUpstreamTunnel(target: "a.corp.example:443", isWanted: isWanted))

        XCTAssertEqual(harness.pool.upstreamStatuses().first?.circuitState, .halfOpen, "the abandoned dial charged nothing")
        try await harness.assertTheNextRequestProbesP()
    }

    /// An attempt that ends with no verdict frees only a probe slot it
    /// claimed. A PAC-chain tunnel names P itself and claims nothing, so
    /// giving it up leaves the probe another tunnel holds on P in place.
    func testAnAbandonedAttemptLeavesAnotherAttemptsProbeHeld() async throws {
        // P is silent to the probe, and drops a CONNECT for the PAC chain's target.
        let p = try await scripted { head in head.contains("abandoned.corp.example") ? .hold : .silent }
        let s = try await authenticatingUpstream()
        let setup = makeCoordinator(upstreams: [("P", p.port), ("S", s.port)], openInterval: 0.05)
        let (pool, coordinator, pProxy) = (setup.pool, setup.coordinator, setup.upstreams[0])
        pool.recordDedicatedTunnelSuccess(for: pProxy, latencyMS: 1)
        for _ in 0..<setup.threshold { pool.recordConnectFailure(for: pProxy) }
        try await Task.sleep(for: .milliseconds(100))

        // The probe: P's backoff has elapsed and its score beats S's, so P is picked and its slot claimed.
        let probe = coordinator.connectUpstreamTunnel(target: "probe.corp.example:443")
        try await waitUntil { p.heads.count == 1 }
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .halfOpen, "precondition")

        let wanted = NIOLockedValueBox(true)
        let chained = coordinator.connectUpstreamTunnel(
            target: "abandoned.corp.example:443", proxyChain: [pProxy], isWanted: { wanted.withLockedValue { $0 } }
        )
        try await waitUntil { p.heads.count == 2 }
        wanted.withLockedValue { $0 = false }
        p.closeHeld()
        await assertAbandoned(chained)

        let next = try await coordinator.connectUpstreamTunnel(target: "next.corp.example:443").get()
        next.channel.close(promise: nil)
        XCTAssertEqual(next.endpoint, "127.0.0.1:\(s.port)", "P's probe is still held, so P was not asked again")
        XCTAssertEqual(p.heads.count, 2)

        // Closing P's probe fails it over to S.
        pool.closeAll(scope: .all)
        let probed = try await probe.get()
        probed.channel.close(promise: nil)
        XCTAssertEqual(probed.endpoint, "127.0.0.1:\(s.port)")
    }

    /// A stop that lands while a dial is being admitted to the pool: the
    /// dial read `isWanted` as true just before it, and the stop's `closeAll`
    /// follows. The connection is in the pool for that `closeAll` to close,
    /// so no tunnel opens for a caller that has stopped.
    func testAStopLandingAsTheDialIsAdmittedClosesIt() async throws {
        let upstream = try await authenticatingUpstream()
        let setup = makeCoordinator(upstreams: [("P", upstream.port)])
        let (pool, coordinator) = (setup.pool, setup.coordinator)
        let reads = NIOLockedValueBox(0)
        let stopped = NIOLockedValueBox(false)
        let isWanted: @Sendable () -> Bool = {
            let read = reads.withLockedValue { $0 += 1; return $0 }
            // The third read admits the connected dial.
            guard read == 3 else { return !stopped.withLockedValue { $0 } }
            stopped.withLockedValue { $0 = true }
            let closed = DispatchSemaphore(value: 0)
            DispatchQueue.global().async {
                pool.closeAll(scope: .all)
                closed.signal()
            }
            // Long enough for the stop's `closeAll` to finish, unless the admission holds the lock it needs.
            _ = closed.wait(timeout: .now() + 0.3)
            return true
        }

        await assertAbandoned(coordinator.connectUpstreamTunnel(target: "a.corp.example:443", isWanted: isWanted))

        XCTAssertEqual(upstream.tunnelsOpened, 0, "the stop closed the connection before its handshake finished")
        XCTAssertEqual(pool.allConnectionSnapshot.count, 0)
    }

    /// With one upstream half-open and its probe's CONNECT unanswered, a second request finds no upstream it may ask, and
    /// the first pick's last resort dials that upstream with no claim. Its 502 reaches the client, but the breaker takes
    /// its verdict from the probe alone: it stays half-open with the probe held, and the probe's success closes it.
    func testAFailureWithoutTheProbeLeavesAHalfOpenBreakerToItsProbe() async throws {
        let p = try await scripted { head in
            head.contains("probe.corp.example") ? .hold : .answer("HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\n\r\n")
        }
        let setup = makeCoordinator(upstreams: [("P", p.port)], openInterval: 0.05)
        let (pool, coordinator) = (setup.pool, setup.coordinator)
        for _ in 0..<setup.threshold { pool.recordConnectFailure(for: setup.upstreams[0]) }
        try await Task.sleep(for: .milliseconds(100))

        let probe = coordinator.connectUpstreamTunnel(target: "probe.corp.example:443")
        try await waitUntil { p.heads.count == 1 }
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .halfOpen, "precondition")

        do {
            let opened = try await coordinator.connectUpstreamTunnel(target: "other.corp.example:443").get()
            opened.channel.close(promise: nil)
            XCTFail("the 502 was tunnelled")
        } catch {
            guard case .upstreamReturnedStatus(502, _)? = error as? ConnectionPoolError else {
                return XCTFail("the claimless request reaches the upstream and gets its 502, got \(error)")
            }
        }
        XCTAssertEqual(p.heads.count, 2, "the request was dialled, not failed for the busy probe")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .halfOpen, "the 502 did not reopen the breaker under the probe")
        XCTAssertNil(pool.selectTunnelUpstream(excluding: [])?.probe, "the probe slot is still held")

        p.answerHeld("HTTP/1.1 200 Connection established\r\n\r\n")
        let probed = try await probe.get()
        probed.channel.close(promise: nil)
        XCTAssertEqual(probed.endpoint, "127.0.0.1:\(p.port)")
        XCTAssertEqual(pool.upstreamStatuses().first?.circuitState, .closed, "the probe's success closed it")
    }

    // MARK: - Harness

    /// P refuses every dial, has the better score, and its breaker is open
    /// with its backoff elapsed, so a selection picks P and claims its probe.
    /// S is a working upstream with its breaker closed.
    private struct ProbeHarness {
        let pool: ConnectionPool
        let coordinator: CONNECTCoordinator
        let s: AuthenticatingUpstream

        /// The next request picks P while its probe slot is free: the refused dial is charged and reopens P, and the
        /// tunnel fails over to S. With the slot still held, S would be picked and P left half-open.
        func assertTheNextRequestProbesP() async throws {
            let tunnel = try await coordinator.connectUpstreamTunnel(target: "next.corp.example:443").get()
            tunnel.channel.close(promise: nil)
            XCTAssertEqual(tunnel.endpoint, "127.0.0.1:\(s.port)")
            XCTAssertEqual(pool.upstreamStatuses().map(\.circuitState), [.open, .closed], "P was probed and its refusal reopened it")
        }
    }

    private func probeHarness() async throws -> ProbeHarness {
        let refusedPort = try await unusedPort()
        let s = try await authenticatingUpstream()
        let setup = makeCoordinator(upstreams: [("P", refusedPort), ("S", s.port)], openInterval: 0.05)
        let p = setup.upstreams[0]
        setup.pool.recordDedicatedTunnelSuccess(for: p, latencyMS: 1)
        for _ in 0..<setup.threshold { setup.pool.recordConnectFailure(for: p) }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(setup.pool.upstreamStatuses().map(\.circuitState), [.open, .closed], "precondition")
        return ProbeHarness(pool: setup.pool, coordinator: setup.coordinator, s: s)
    }

    private struct Setup {
        let pool: ConnectionPool
        let coordinator: CONNECTCoordinator
        let upstreams: [UpstreamProxy]
        let threshold: Int
    }

    private func makeCoordinator(upstreams: [(name: String, port: Int)], openInterval: TimeInterval = 300) -> Setup {
        var config = ProxyConfig.testFixture()
        config.upstreams = upstreams.enumerated().map { index, upstream in
            UpstreamProxy(name: upstream.name, host: "127.0.0.1", port: upstream.port, priority: index)
        }
        config.circuitBreakerWindowSeconds = 0
        config.circuitBaseOpenIntervalSeconds = openInterval
        config.circuitMaxOpenIntervalSeconds = openInterval
        config.upstreamResponseTimeoutSeconds = 10
        let frozen = config
        let pool = ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { frozen },
            authenticatorProvider: { _ in StubNegotiateAuthenticator() }
        )
        addTeardownBlock { pool.closeAll(scope: .all) }
        let coordinator = CONNECTCoordinator(pool: pool, authenticatorProvider: { _ in StubNegotiateAuthenticator() }, logger: DiscardingLogSink())
        return Setup(pool: pool, coordinator: coordinator, upstreams: frozen.enabledUpstreams, threshold: frozen.circuitFailureThreshold)
    }

    private func assertAbandoned(
        _ tunnel: EventLoopFuture<(channel: Channel, endpoint: String, authMethod: String?)>,
        file: StaticString = #filePath, line: UInt = #line
    ) async {
        do {
            let opened = try await tunnel.get()
            opened.channel.close(promise: nil)
            XCTFail("a tunnel opened for a caller that gave it up", file: file, line: line)
        } catch {
            XCTAssertEqual(error as? ConnectionPoolError, .tunnelAbandoned, "\(error)", file: file, line: line)
        }
    }

    private func authenticatingUpstream() async throws -> AuthenticatingUpstream {
        let upstream = try await AuthenticatingUpstream.start(group: group, answerIP: "198.51.100.30")
        authenticating.append(upstream)
        return upstream
    }

    /// A port nothing listens on, so a dial to it is refused at once.
    private func unusedPort() async throws -> Int {
        let server = try await ServerBootstrap(group: group).bind(host: "127.0.0.1", port: 0).get()
        let port = try XCTUnwrap(server.localAddress?.port)
        try await server.close().get()
        return port
    }

    private func scripted(_ action: @escaping @Sendable (String) -> ScriptedUpstream.Action) async throws -> ScriptedUpstream.Record.View {
        let record = ScriptedUpstream.Record()
        let server = try await ServerBootstrap(group: group)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                record.accept()
                return channel.pipeline.addHandler(ScriptedUpstream(record: record, action: action))
            }
            .bind(host: "127.0.0.1", port: 0).get()
        servers.append(server)
        record.port = try XCTUnwrap(server.localAddress?.port)
        return record.upstream
    }

    private func waitUntil(_ condition: @escaping @Sendable () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        for _ in 0..<300 where !condition() { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }
}

/// Answers each CONNECT head as `action` says, and records what it saw.
private final class ScriptedUpstream: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    enum Action {
        case answer(String)
        case silent
        /// Silent until the test calls `closeHeld()`.
        case hold
    }

    final class Record: @unchecked Sendable {
        private let state = NIOLockedValueBox<(accepted: Int, heads: [String], held: [Channel])>((0, [], []))
        var port = 0
        func accept() { state.withLockedValue { $0.accepted += 1 } }
        func head(_ head: String) { state.withLockedValue { $0.heads.append(head) } }
        func hold(_ channel: Channel) { state.withLockedValue { $0.held.append(channel) } }
        func closeHeld() { for channel in state.withLockedValue({ $0.held }) { channel.close(promise: nil) } }
        func answerHeld(_ response: String) {
            for channel in state.withLockedValue({ $0.held }) {
                channel.writeAndFlush(channel.allocator.buffer(string: response), promise: nil)
            }
        }
        var upstream: View { View(record: self) }

        struct View: Sendable {
            let record: Record
            var port: Int { record.port }
            var accepted: Int { record.state.withLockedValue { $0.accepted } }
            var heads: [String] { record.state.withLockedValue { $0.heads } }
            func closeHeld() { record.closeHeld() }
            func answerHeld(_ response: String) { record.answerHeld(response) }
        }
    }

    private let record: Record
    private let action: @Sendable (String) -> Action
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    init(record: Record, action: @escaping @Sendable (String) -> Action) {
        self.record = record
        self.action = action
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let text = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              let end = text.range(of: "\r\n\r\n") else { return }
        accumulated.clear()
        let head = String(text[..<end.lowerBound])
        record.head(head)
        switch action(head) {
        case .answer(let response):
            var out = context.channel.allocator.buffer(capacity: response.utf8.count)
            out.writeString(response)
            context.writeAndFlush(NIOAny(out), promise: nil)
        case .silent:
            return
        case .hold:
            record.hold(context.channel)
        }
    }
}
