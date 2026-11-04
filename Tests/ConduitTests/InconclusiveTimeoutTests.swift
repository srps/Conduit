// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

final class InconclusiveTimeoutTests: XCTestCase {
    private final class ProbeScript: @unchecked Sendable {
        private let outcomes = NIOLockedValueBox<[ProbeOutcome]>([])
        func then(_ outcome: ProbeOutcome) { outcomes.withLockedValue { $0.append(outcome) } }
        func probe(_ upstreams: [UpstreamProxy]) -> UpstreamProbeSummary {
            let outcome = outcomes.withLockedValue { $0.isEmpty ? .answered : $0.removeFirst() }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, outcome: outcome) })
        }
    }

    @RuntimeActor
    func testOneSilentHealthCheckIsHeldAndTheSecondStartsRecovery() async throws {
        let silent = try await Self.silentServer()
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.healthCheckIntervalSeconds = 1
        config.upstreamResponseTimeoutSeconds = 0.2
        let orchestrator = Self.orchestrator(config: config, probe: ProbeScript())
        try await orchestrator.startProxy()

        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }
        func recoveryEvents() -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event.hasPrefix("recovery.") } }

        try await Self.until { !events("health.inconclusive").isEmpty || !recoveryEvents().isEmpty }
        let first = events("health.inconclusive").first?.detail ?? ""
        XCTAssertTrue(first.hasPrefix("reason=answer_timed_out consecutive=1 decisive=false "), first)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.state, .running, "one silence changes nothing")
        XCTAssertEqual(recoveryEvents().map(\.event), [])

        try await Self.until { !recoveryEvents().isEmpty }
        XCTAssertEqual(events("health.inconclusive").dropFirst().first?.detail?.contains("consecutive=2 decisive=true"), true)
        XCTAssertEqual(recoveryEvents().first?.detail?.hasPrefix("step=reauthenticate reason=upstream_silent"), true,
                       "the decisive silence started the ladder")

        await orchestrator.stopProxy()
        try await silent.close().get()
    }

    @RuntimeActor
    func testOneSilentProbeKeepsRoutingAndTheSecondGrantsDirect() async throws {
        let silent = try await Self.silentServer()
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.upstreamResponseTimeoutSeconds = Self.healthCheckOutlivesTheTest
        let script = ProbeScript()
        let orchestrator = Self.orchestrator(config: config, probe: script)
        try await orchestrator.startProxy()
        func inconclusive() -> [String] {
            orchestrator.eventLog.events.filter { $0.event == "connectivity.probe_inconclusive" }.compactMap(\.detail)
        }

        script.then(.silent)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none, "one silent probe keeps proxy routing")
        XCTAssertEqual(inconclusive().count, 1)
        XCTAssertTrue(inconclusive().first?.contains("consecutive=1 decisive=false") == true, inconclusive().first ?? "")

        script.then(.silent)
        var renamed = config
        renamed.upstreams[0].name = "renamed"
        await orchestrator.applyConfigChange(renamed)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected, "the second in a row counts")
        XCTAssertTrue(inconclusive().last?.contains("consecutive=2 decisive=true") == true, inconclusive().last ?? "")

        await orchestrator.stopProxy()
        try await silent.close().get()
    }

    @RuntimeActor
    func testAnUnreachableProbeGrantsDirectAtOnce() async throws {
        let silent = try await Self.silentServer()
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.upstreamResponseTimeoutSeconds = Self.healthCheckOutlivesTheTest
        let script = ProbeScript()
        let orchestrator = Self.orchestrator(config: config, probe: script)
        try await orchestrator.startProxy()

        script.then(.unreachable)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "connectivity.probe_inconclusive" })
        await orchestrator.stopProxy()
        try await silent.close().get()
    }

    @RuntimeActor
    func testALadderThatRecoversClearsTheStandingFailure() async throws {
        let upstream = try await AnsweringUpstream.start()
        var config = Self.config(upstreamPort: upstream.port)
        config.healthCheckIntervalSeconds = 4
        config.upstreamResponseTimeoutSeconds = 0.2
        let orchestrator = Self.orchestrator(config: config, probe: ProbeScript())
        try await orchestrator.startProxy()
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }

        try await Self.until { orchestrator.snapshot.runtimeStatus.state == .recovering }
        // The pool's silence check sends a HEAD of its own and can take an answer meant for the ladder, so answer one at a time.
        try await Self.until {
            if upstream.answersLeft == 0 { upstream.answer(1) }
            return orchestrator.eventLog.events.contains { $0.typed == .proxyRecovery(.recovered) }
        }
        upstream.answer(0)
        let heldBeforeRecovery = events("health.inconclusive").count

        try await Self.until { events("health.inconclusive").count > heldBeforeRecovery }
        let next = events("health.inconclusive")[heldBeforeRecovery].detail ?? ""
        XCTAssertTrue(next.hasPrefix("reason=answer_timed_out consecutive=1 decisive=false "), next)

        await orchestrator.stopProxy()
        try await upstream.close()
    }

    @RuntimeActor
    func testAHeldProbeAfterTheLadderLeavesTheRuntimeToTheHealthLoop() async throws {
        let upstream = try await AnsweringUpstream.start()
        var config = Self.config(upstreamPort: upstream.port)
        config.healthCheckIntervalSeconds = 4
        config.upstreamResponseTimeoutSeconds = 0.2
        let hold = ProbeHold()
        let log = NIOLockedValueBox<RuntimeEventLog?>(nil)
        let orchestrator = ProxyOrchestrator(
            config: config, logger: DiscardingLogSink(),
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") },
            connectivityProbe: { upstreams in
                let exhausted = log.withLockedValue { $0 }?.events.contains { $0.event == "recovery.exhausted" } ?? false
                let outcome: ProbeOutcome = exhausted ? .silent : .answered
                if exhausted { await hold.wait() }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, outcome: outcome) })
            }
        )
        log.withLockedValue { $0 = orchestrator.eventLog }
        try await orchestrator.startProxy()
        func events(_ name: String) -> [RuntimeEvent] { orchestrator.eventLog.events.filter { $0.event == name } }

        try await Self.until { hold.isHolding }
        upstream.answer(.max)
        try await Self.until { orchestrator.snapshot.runtimeStatus.state == .running }
        hold.release()
        try await Self.until { !events("connectivity.probe_inconclusive").isEmpty }

        XCTAssertTrue(events("connectivity.probe_inconclusive").first?.detail?.contains("consecutive=1 decisive=false") == true)
        XCTAssertFalse(orchestrator.eventLog.events.contains {
            if case .proxyRecovery(.failed)? = $0.typed { true } else { false }
        })
        XCTAssertNotEqual(orchestrator.snapshot.runtimeStatus.state, .failed)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)

        await orchestrator.stopProxy()
        try await upstream.close()
    }

    @RuntimeActor
    func testNewUpstreamEndpointsStartTheirOwnStreak() async throws {
        let silent = try await Self.silentServer()
        let other = try await Self.silentServer()
        var config = Self.config(upstreamPort: try XCTUnwrap(silent.localAddress?.port))
        config.upstreamResponseTimeoutSeconds = Self.healthCheckOutlivesTheTest
        let script = ProbeScript()
        let orchestrator = Self.orchestrator(config: config, probe: script)
        try await orchestrator.startProxy()
        func inconclusive() -> [String] {
            orchestrator.eventLog.events.filter { $0.event == "connectivity.probe_inconclusive" }.compactMap(\.detail)
        }

        script.then(.silent)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertTrue(inconclusive().first?.contains("consecutive=1 decisive=false") == true, inconclusive().first ?? "")

        script.then(.silent)
        var moved = config
        moved.upstreams[0].port = try XCTUnwrap(other.localAddress?.port)
        await orchestrator.applyConfigChange(moved)
        XCTAssertEqual(inconclusive().count, 2)
        XCTAssertTrue(inconclusive().last?.contains("consecutive=1 decisive=false") == true, inconclusive().last ?? "")
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none, "the new endpoint's first silence keeps proxy routing")

        await orchestrator.stopProxy()
        try await silent.close().get()
        try await other.close().get()
    }

    /// Answers `200 OK` to as many requests as it has answers left and leaves the rest unanswered.
    private final class AnsweringUpstream: @unchecked Sendable {
        private let answers = NIOLockedValueBox(0)
        private var channel: Channel?

        var port: Int { channel?.localAddress?.port ?? 0 }
        var answersLeft: Int { answers.withLockedValue { $0 } }
        func answer(_ count: Int) { answers.withLockedValue { $0 = count } }

        static func start() async throws -> AnsweringUpstream {
            let upstream = AnsweringUpstream()
            let answers = upstream.answers
            upstream.channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
                .childChannelInitializer { $0.pipeline.addHandler(RequestHandler(answers: answers)) }
                .bind(host: "127.0.0.1", port: 0).get()
            return upstream
        }

        func close() async throws { try await channel?.close().get() }

        private final class RequestHandler: ChannelInboundHandler, @unchecked Sendable {
            typealias InboundIn = ByteBuffer
            private let answers: NIOLockedValueBox<Int>
            private var pending = ""

            init(answers: NIOLockedValueBox<Int>) { self.answers = answers }

            func channelRead(context: ChannelHandlerContext, data: NIOAny) {
                var buffer = unwrapInboundIn(data)
                pending += buffer.readString(length: buffer.readableBytes) ?? ""
                while let end = pending.range(of: "\r\n\r\n") {
                    pending.removeSubrange(pending.startIndex..<end.upperBound)
                    let answered = answers.withLockedValue { left in
                        guard left > 0 else { return false }
                        left -= 1
                        return true
                    }
                    guard answered else { continue }
                    let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                    context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: response)), promise: nil)
                }
            }
        }
    }

    private final class ProbeHold: @unchecked Sendable {
        private let lock = NSLock()
        private var waiter: CheckedContinuation<Void, Never>?
        private var released = false

        var isHolding: Bool { lock.withLock { waiter != nil } }

        func wait() async {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let resumeNow = lock.withLock { () -> Bool in
                    guard !released else { return true }
                    waiter = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        }

        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                released = true
                defer { waiter = nil }
                return waiter
            }
            continuation?.resume()
        }
    }

    /// With the check this long, only probes write the streak.
    private static let healthCheckOutlivesTheTest: TimeInterval = 600

    private static func silentServer() async throws -> Channel {
        try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { $0.eventLoop.makeSucceededVoidFuture() }
            .bind(host: "127.0.0.1", port: 0).get()
    }

    private static func config(upstreamPort: Int) -> ProxyConfig {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "silent", host: "127.0.0.1", port: upstreamPort, priority: 0)]
        return config
    }

    @RuntimeActor
    private static func orchestrator(config: ProxyConfig, probe: ProbeScript) -> ProxyOrchestrator {
        ProxyOrchestrator(
            config: config, logger: DiscardingLogSink(),
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "dGVzdA==") },
            connectivityProbe: { probe.probe($0) }
        )
    }

    @RuntimeActor
    private static func until(_ condition: () -> Bool, file: StaticString = #filePath, line: UInt = #line) async throws {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertTrue(condition(), "condition never held", file: file, line: line)
    }
}
