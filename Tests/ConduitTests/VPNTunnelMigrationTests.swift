// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

/// #148, #156: a confirmed transition closes the sockets whose path it
/// removed, at once and again as routes settle; a flap holds the sweeps.
@MainActor
final class VPNTunnelMigrationTests: XCTestCase {
    private func migrations(_ events: [RuntimeEvent]) -> [String] {
        events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
    }

    /// Local addresses that are gone, and those whose peer the kernel now
    /// reaches through another interface; every other socket is current.
    private let gone = NIOLockedValueBox<Set<String>>([])
    private let moved = NIOLockedValueBox<Set<String>>([])

    private var paths: ClosureSocketPaths {
        let gone = self.gone, moved = self.moved
        return ClosureSocketPaths { query in
            let local = query.local.ipAddress ?? ""
            if gone.withLockedValue({ $0.contains(local) }) { return .stranded(SocketPathVerdict.addressGone) }
            if moved.withLockedValue({ $0.contains(local) }) { return .stranded("interface_changed") }
            return .current
        }
    }

    private func config() -> ProxyConfig {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        return config
    }

    private func orchestrator(
        reachable: NIOLockedValueBox<Bool> = NIOLockedValueBox(true), logger: any LogSink = DiscardingLogSink(),
        resweeps: [Duration] = [.milliseconds(50)],
        probe: (@Sendable () async -> Void)? = nil
    ) -> ProxyOrchestrator {
        ProxyOrchestrator(config: config(), logger: logger,
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                await probe?()
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            },
            socketPaths: paths, strandedResweepDelays: resweeps)
    }

    /// A connected socket from `local`, tracked by `orchestrator`.
    private func tracked(
        _ orchestrator: ProxyOrchestrator, local: String, route: OutboundSocketRegistry.Route = .direct
    ) async throws -> EmbeddedChannel {
        let channel = EmbeddedChannel()
        channel.localAddress = try SocketAddress(ipAddress: local, port: 50_000)
        try await channel.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: route == .upstream ? 3128 : 443)).get()
        try orchestrator.sockets.register(channel, route: route, target: "origin.test:443")
        return channel
    }

    private func until(_ condition: () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(3)
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        return condition()
    }

    /// The sweep does not wait for the connectivity probe: the probe can
    /// take its whole connect budget while stranded sockets stall.
    func testADisconnectClosesStrandedSocketsWhileItsProbeRuns() async throws {
        let reachable = NIOLockedValueBox(true)
        let holdProbe = NIOLockedValueBox(false)
        let gate = Gate()
        let orchestrator = orchestrator(reachable: reachable, probe: {
            if holdProbe.withLockedValue({ let hold = $0; $0 = false; return hold }) { await gate.wait() }
        })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        let overVPN = try await tracked(orchestrator, local: "10.20.30.40", route: .upstream)
        let overWiFi = try await tracked(orchestrator, local: "192.168.2.20")
        reachable.withLockedValue { $0 = false }
        holdProbe.withLockedValue { $0 = true }
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }

        let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        while !(await gate.holding) { try await Task.sleep(for: .milliseconds(5)) }
        let closedDuringProbe = try await until { !overVPN.isActive }
        await gate.open()
        await disconnect.value

        XCTAssertTrue(closedDuringProbe)
        XCTAssertTrue(overWiFi.isActive)
        let events = migrations(orchestrator.eventLog.events)
        XCTAssertTrue(events.contains("transition=disconnected phase=paths pass=0 upstream_closed=1 direct_closed=0 unchecked=0"), "\(events)")
        XCTAssertEqual(events.last { $0.contains("phase=routing") }, "transition=disconnected phase=routing reason=user routing=direct upstream_closed=0")
        await orchestrator.stopProxy()
    }

    /// Routes settle after the VPN report: a DIRECT socket whose route moves
    /// onto the tunnel only after the first pass is closed by a re-sweep.
    func testAReSweepClosesASocketWhosePathMovedAfterTheFirstPass() async throws {
        let orchestrator = orchestrator(resweeps: [.milliseconds(100)])
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let offVPN = try await tracked(orchestrator, local: "192.168.2.20")

        await orchestrator.handleVPNStateChange(.connected)
        let settled1 = try await until {
            migrations(orchestrator.eventLog.events).last?.hasPrefix("transition=connected phase=paths pass=0 ") ?? false
        }
        XCTAssertTrue(settled1)
        XCTAssertTrue(offVPN.isActive, "its route had not moved yet")
        gone.withLockedValue { _ = $0.insert("192.168.2.20") }

        let settled2 = try await until { !offVPN.isActive }

        XCTAssertTrue(settled2)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=connected phase=paths pass=1 upstream_closed=0 direct_closed=1 unchecked=0")
        await orchestrator.stopProxy()
    }

    /// A route missing mid-flap is not a gone path: the pending re-sweeps of
    /// the transition before the flap wait it out, and run once it recovers.
    func testAFlapHoldsThePendingReSweepsUntilItRecovers() async throws {
        let orchestrator = orchestrator(resweeps: [.milliseconds(100)])
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        await orchestrator.handleVPNStateChange(.connected)
        let onVPN = try await tracked(orchestrator, local: "10.20.30.40")
        await orchestrator.handleVPNStateChange(.reasserting)
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }

        try await Task.sleep(for: .milliseconds(300))
        XCTAssertTrue(onVPN.isActive, "the flap held the re-sweep")

        await orchestrator.handleVPNStateChange(.connected)
        let settled3 = try await until { !onVPN.isActive }
        XCTAssertTrue(settled3, "the recovery ran the owed re-sweep")
        await orchestrator.stopProxy()
    }

    /// A flap with no owed sweeps closes nothing while it lasts. Its recovery
    /// closes, after the first re-sweep delay, only sockets whose address is
    /// gone (the tunnel came back on another address): a route that moved is
    /// not judged after a flap.
    func testAFlapRecoveryClosesOnlySocketsWhoseAddressIsGone() async throws {
        let orchestrator = orchestrator(resweeps: [.milliseconds(100)])
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        try await Task.sleep(for: .milliseconds(200))
        let oldAddress = try await tracked(orchestrator, local: "10.20.30.40")
        let routeMoved = try await tracked(orchestrator, local: "10.20.30.41")
        await orchestrator.handleVPNStateChange(.reasserting)
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }
        moved.withLockedValue { _ = $0.insert("10.20.30.41") }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertTrue(oldAddress.isActive, "nothing is swept during the flap")

        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertTrue(oldAddress.isActive, "the recovery waits before judging addresses")
        let closed = try await until { !oldAddress.isActive }
        XCTAssertTrue(closed)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(routeMoved.isActive)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=flap_recovered phase=addresses pass=1 upstream_closed=0 direct_closed=1 unchecked=0")
        await orchestrator.stopProxy()
    }

    /// The first report after startup is a real transition: `unknown →
    /// connected` sweeps like any other (#160).
    func testTheFirstConnectedReportSweeps() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        let beforeVPN = try await tracked(orchestrator, local: "192.168.2.20")
        gone.withLockedValue { _ = $0.insert("192.168.2.20") }
        await orchestrator.handleVPNStateChange(.connected)
        let settled4 = try await until { !beforeVPN.isActive }
        XCTAssertTrue(settled4)
        await orchestrator.stopProxy()
    }

    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        func wait() async { await withCheckedContinuation { waiter = $0 } }
        var holding: Bool { waiter != nil }
        func open() { waiter?.resume(); waiter = nil }
    }

    /// A reconnect that runs while the disconnect handler waits on its probe
    /// owns routing; the stale handler must not sweep on its old verdict.
    func testADisconnectSupersededDuringItsProbeSkipsTheRoutingSweep() async throws {
        let reachable = NIOLockedValueBox(true)
        let holdNextProbe = NIOLockedValueBox(false)
        let gate = Gate()
        let orchestrator = orchestrator(reachable: reachable, probe: {
            if holdNextProbe.withLockedValue({ let hold = $0; $0 = false; return hold }) { await gate.wait() }
        })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        reachable.withLockedValue { $0 = false }
        holdNextProbe.withLockedValue { $0 = true }

        let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        while !(await gate.holding) { try await Task.sleep(for: .milliseconds(5)) }
        reachable.withLockedValue { $0 = true }
        await orchestrator.handleVPNStateChange(.connected)
        await gate.open()
        await disconnect.value

        let routing = migrations(orchestrator.eventLog.events).filter { $0.contains("phase=routing") }
        XCTAssertEqual(routing, ["transition=disconnected phase=routing reason=user skipped=superseded"])
        await orchestrator.stopProxy()
    }

    /// A reconnect while the listener is stopped (a config restart in
    /// flight) still closes the stranded sockets the restart preserved.
    func testAReconnectWithTheListenerStoppedStillSweeps() async throws {
        let orchestrator = orchestrator(reachable: NIOLockedValueBox(false))
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let offVPN = try await tracked(orchestrator, local: "192.168.2.20")
        await orchestrator.stopProxy(scope: .allButDedicated)
        gone.withLockedValue { _ = $0.insert("192.168.2.20") }

        await orchestrator.handleVPNStateChange(.connected)

        let settled5 = try await until { !offVPN.isActive }

        XCTAssertTrue(settled5)
        XCTAssertTrue(migrations(orchestrator.eventLog.events).contains(
            "transition=connected phase=paths pass=0 upstream_closed=0 direct_closed=1 unchecked=0"))
    }

    /// On-prem: the probe finds the upstream, so the routing phase closes nothing.
    func testAReachableUpstreamKeepsItsChannelsInTheRoutingPhase() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))

        XCTAssertEqual(migrations(orchestrator.eventLog.events).last { $0.contains("phase=routing") },
                       "transition=disconnected phase=routing reason=lost routing=upstream upstream_closed=0")
        await orchestrator.stopProxy()
    }

    /// A disconnect while the listener is stopped still closes stranded
    /// sockets at once, and its routing phase runs once the start probe
    /// decides routing: an upstream tunnel the restart preserved would stall
    /// on proxies behind the gone VPN (#156).
    func testADisconnectWithTheListenerStoppedRoutesOnceTheStartProbeDecides() async throws {
        let reachable = NIOLockedValueBox(true)
        let orchestrator = orchestrator(reachable: reachable)
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        let preserved = try await tracked(orchestrator, local: "192.168.2.20", route: .upstream)
        await orchestrator.stopProxy(scope: .allButDedicated)
        reachable.withLockedValue { $0 = false }

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        let settled6 = try await until {
            migrations(orchestrator.eventLog.events).last?.hasPrefix("transition=disconnected phase=paths pass=0 ") ?? false
        }

        XCTAssertTrue(settled6, "the path sweep ran with the listener stopped")
        XCTAssertTrue(preserved.isActive, "its path is current and routing is not decided yet")

        try await orchestrator.startProxy()

        XCTAssertFalse(preserved.isActive)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last { $0.contains("phase=routing") },
                       "transition=disconnected phase=routing reason=user routing=direct upstream_closed=1")
        await orchestrator.stopProxy()
    }

    /// Calls `onListening` when the listener logs that it is up: after the
    /// start probe committed, before startup reports running.
    private final class ListeningHook: LogSink, @unchecked Sendable {
        let onListening: @Sendable () -> Void
        init(_ onListening: @escaping @Sendable () -> Void) { self.onListening = onListening }
        var minLevel: LogLevel { .debug }
        func flush(timeout: TimeInterval) -> Bool { true }
        func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
            if message.hasPrefix("Local proxy listening on") { onListening() }
        }
    }

    /// A disconnect that lands after the start probe committed (while the
    /// listener binds) made that verdict stale; startup decides again and
    /// runs the routing phase before it reports running.
    func testADisconnectAfterTheStartProbeIsRoutedBeforeRunning() async throws {
        let reachable = NIOLockedValueBox(true)
        let box = NIOLockedValueBox<ProxyOrchestrator?>(nil)
        let hook = ListeningHook {
            guard let orchestrator = box.withLockedValue({ $0 }) else { return }
            reachable.withLockedValue { $0 = false }
            Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        }
        let orchestrator = orchestrator(reachable: reachable, logger: hook)
        await orchestrator.handleVPNStateChange(.connected)
        let preserved = try await tracked(orchestrator, local: "192.168.2.20", route: .upstream)
        box.withLockedValue { $0 = orchestrator }

        try await orchestrator.startProxy()

        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .userInitiated), "the disconnect landed during startup")
        XCTAssertTrue(orchestrator.snapshot.directModeCause.routesClientTrafficDirectly)
        XCTAssertFalse(preserved.isActive, "the deferred routing phase ran before .running")
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last { $0.contains("phase=routing") },
                       "transition=disconnected phase=routing reason=user routing=direct upstream_closed=1")
        await orchestrator.stopProxy()
    }
}
