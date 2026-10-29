// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOEmbedded
import XCTest
@testable import ProxyKernel

/// #148, #156: a confirmed transition closes the sockets whose path it
/// removed, at once and again as routes settle; a flap holds the sweeps.
final class VPNTunnelMigrationTests: XCTestCase {
    private func migrations(_ events: [RuntimeEvent]) -> [String] {
        events.filter { $0.event == "vpn.tunnels_migrated" }.compactMap(\.detail)
    }

    /// Local addresses that are gone, and those whose peer the kernel now
    /// reaches through another interface; every other socket is current.
    private let gone = NIOLockedValueBox<Set<String>>([])
    private let moved = NIOLockedValueBox<Set<String>>([])

    /// While set, every check waits on it, standing in for a slow sweep.
    private let paused = NIOLockedValueBox<DispatchSemaphore?>(nil)
    private let checking = NIOLockedValueBox(false)

    /// The one re-sweep delay; it passes only when a test releases it.
    private let resweep = Duration.seconds(2)
    private let delays = HeldDelays()

    private var paths: ClosureSocketPaths {
        let gone = self.gone, moved = self.moved
        let paused = self.paused, checking = self.checking
        return ClosureSocketPaths { query in
            if let pause = paused.withLockedValue({ $0 }) {
                checking.withLockedValue { $0 = true }
                pause.wait()
            }
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

    /// Stopped, with every held delay cancelled, when the test ends.
    @RuntimeActor
    private func orchestrator(
        reachable: NIOLockedValueBox<Bool> = NIOLockedValueBox(true), logger: any LogSink = DiscardingLogSink(),
        probe: (@Sendable () async -> Void)? = nil
    ) -> ProxyOrchestrator {
        let orchestrator = ProxyOrchestrator(config: config(), logger: logger,
            authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
            connectivityProbe: { upstreams in
                await probe?()
                let up = reachable.withLockedValue { $0 }
                return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: up) })
            },
            socketPaths: paths, strandedResweepDelays: [resweep],
            strandedResweepSleep: { [delays] in try await delays.sleep($0) })
        addTeardownBlock { [delays] in
            delays.finish()
            await orchestrator.stopProxy()
            XCTAssertFalse(delays.overused, "a second re-sweep delay started while one was held")
        }
        return orchestrator
    }

    /// A connected socket from `local`, tracked by `orchestrator`. Sweeps
    /// read its addresses and close it from other threads, and the owner
    /// resumes on any thread, so it runs on a thread-safe testing loop.
    @RuntimeActor private func tracked(
        _ orchestrator: ProxyOrchestrator, local: String, route: OutboundSocketRegistry.Route = .direct
    ) async throws -> NIOAsyncTestingChannel {
        let channel = NIOAsyncTestingChannel()
        // A sweep or a refused registration may have closed it already.
        addTeardownBlock {
            let left = try await channel.finish(acceptAlreadyClosed: true)
            XCTAssertTrue(left.isClean)
        }
        channel.localAddress = try SocketAddress(ipAddress: local, port: 50_000)
        try await channel.connect(to: SocketAddress(ipAddress: "192.0.2.10", port: route == .upstream ? 3128 : 443)).get()
        try orchestrator.sockets.register(channel, route: route, target: "origin.test:443")
        return channel
    }

    /// Runs what each channel's loop has queued. A sweep closes a socket
    /// from another thread through its loop, so `isActive` reads settled
    /// only after the loop ran every close requested before this call.
    @RuntimeActor private func drain(_ channels: NIOAsyncTestingChannel...) async {
        for channel in channels { await channel.testingEventLoop.run() }
    }

    /// Reports `.connected` and runs its one re-sweep, so the transition
    /// owes nothing. A re-sweep that finds nothing reports nothing, so a
    /// socket whose address goes while the re-sweep is held reports it. The
    /// sweep task appends that report and drops what the transition owes in
    /// one turn of the owner, after its last await: once the report is seen
    /// nothing is owed.
    @RuntimeActor private func connectAndSettle(_ orchestrator: ProxyOrchestrator) async throws {
        let sentinel = try await tracked(orchestrator, local: "192.168.2.99")
        await orchestrator.handleVPNStateChange(.connected)
        try await until { self.delays.held == self.resweep }
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=connected phase=paths pass=0 upstream_closed=0 direct_closed=0 unchecked=0")
        gone.withLockedValue { _ = $0.insert("192.168.2.99") }
        XCTAssertEqual(delays.release(), resweep)
        try await until({
            self.migrations(orchestrator.eventLog.events).last
                == "transition=connected phase=paths pass=1 upstream_closed=0 direct_closed=1 unchecked=0"
        }, else: "\(migrations(orchestrator.eventLog.events))")
        await drain(sentinel)
        XCTAssertFalse(sentinel.isActive)
    }

    /// Ends the test if `condition` does not hold within 3 s.
    @RuntimeActor private func until(
        _ condition: () async -> Bool, else failure: @autoclosure () -> String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while !(await condition()) {
            _ = try XCTUnwrap(ContinuousClock.now < deadline ? true : nil, "timed out \(failure())", file: file, line: line)
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// The sweep does not wait for the connectivity probe: the probe can
    /// take its whole connect budget while stranded sockets stall.
    @RuntimeActor func testADisconnectClosesStrandedSocketsWhileItsProbeRuns() async throws {
        let reachable = NIOLockedValueBox(true)
        let holdProbe = NIOLockedValueBox(false)
        let gate = Gate()
        let orchestrator = orchestrator(reachable: reachable, probe: {
            if holdProbe.withLockedValue({ let hold = $0; $0 = false; return hold }) { await gate.wait() }
        })
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        try await until { self.delays.held == self.resweep }
        let overVPN = try await tracked(orchestrator, local: "10.20.30.40", route: .upstream)
        let overWiFi = try await tracked(orchestrator, local: "192.168.2.20")
        reachable.withLockedValue { $0 = false }
        holdProbe.withLockedValue { $0 = true }
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }

        let disconnect = Task { @RuntimeActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        addTeardownBlock {
            await gate.open()
            await disconnect.value
        }
        try await until { await gate.holding }
        try await until { !overVPN.isActive }
        await gate.open()
        await disconnect.value

        await drain(overWiFi)
        XCTAssertTrue(overWiFi.isActive)
        let events = migrations(orchestrator.eventLog.events)
        XCTAssertTrue(events.contains("transition=disconnected phase=paths pass=0 upstream_closed=1 direct_closed=0 unchecked=0"), "\(events)")
        XCTAssertEqual(events.last { $0.contains("phase=routing") }, "transition=disconnected phase=routing reason=user routing=direct upstream_closed=0")
    }

    /// Routes settle after the VPN report: a DIRECT socket whose route moves
    /// onto the tunnel only after the first pass is closed by a re-sweep.
    @RuntimeActor func testAReSweepClosesASocketWhosePathMovedAfterTheFirstPass() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let offVPN = try await tracked(orchestrator, local: "192.168.2.20")

        await orchestrator.handleVPNStateChange(.connected)
        try await until { self.delays.held == self.resweep }
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last,
                       "transition=connected phase=paths pass=0 upstream_closed=0 direct_closed=0 unchecked=0")
        await drain(offVPN)
        XCTAssertTrue(offVPN.isActive, "its route had not moved yet")
        moved.withLockedValue { _ = $0.insert("192.168.2.20") }

        XCTAssertEqual(delays.release(), resweep)
        try await until({
            self.migrations(orchestrator.eventLog.events).last
                == "transition=connected phase=paths pass=1 upstream_closed=0 direct_closed=1 unchecked=0"
        }, else: "\(migrations(orchestrator.eventLog.events))")
        await drain(offVPN)
        XCTAssertFalse(offVPN.isActive)
    }

    /// A route missing mid-flap is not a gone path: the pending re-sweeps of
    /// the transition before the flap wait it out, and run once it recovers.
    @RuntimeActor func testAFlapHoldsThePendingReSweepsUntilItRecovers() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        // Each sweep task waits on its delay, so it is done cancelling once replaced.
        try await until { self.delays.held == self.resweep }
        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertEqual(delays.cancelled, 1)
        try await until { self.delays.held == self.resweep }
        let onVPN = try await tracked(orchestrator, local: "10.20.30.40")

        await orchestrator.handleVPNStateChange(.reasserting)
        XCTAssertNil(delays.held, "the flap held the owed re-sweep")
        XCTAssertEqual(delays.cancelled, 2)
        moved.withLockedValue { _ = $0.insert("10.20.30.40") }
        await drain(onVPN)
        XCTAssertTrue(onVPN.isActive, "the flap held the re-sweep")

        await orchestrator.handleVPNStateChange(.connected)
        try await until { self.delays.held == self.resweep }
        await drain(onVPN)
        XCTAssertTrue(onVPN.isActive, "the recovery waits out the re-sweep delay")
        XCTAssertEqual(delays.release(), resweep)
        try await until({
            self.migrations(orchestrator.eventLog.events).last
                == "transition=connected phase=paths pass=1 upstream_closed=0 direct_closed=1 unchecked=0"
        }, else: "\(migrations(orchestrator.eventLog.events))")
        await drain(onVPN)
        XCTAssertFalse(onVPN.isActive, "the recovery ran the owed re-sweep")
    }

    /// A flap that begins while a sweep is still checking paths stops it
    /// before it closes anything: the verdicts were taken mid-transition.
    @RuntimeActor func testAFlapDuringASweepsCheckStopsItsClosures() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        let socket = try await tracked(orchestrator, local: "10.20.30.40")
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }
        let pause = DispatchSemaphore(value: 0)
        paused.withLockedValue { $0 = pause }
        addTeardownBlock { [paused] in
            paused.withLockedValue { $0 = nil }
            pause.signal()
        }

        await orchestrator.handleVPNStateChange(.connected)
        try await until { self.checking.withLockedValue { $0 } }
        await orchestrator.handleVPNStateChange(.reasserting)
        paused.withLockedValue { $0 = nil }
        pause.signal()
        // The cancelled pass dropped its verdicts and reached its re-sweep delay.
        try await until { self.delays.cancelled == 1 }

        await drain(socket)
        XCTAssertTrue(socket.isActive)
        XCTAssertFalse(migrations(orchestrator.eventLog.events).contains { $0.contains("phase=paths") })
    }

    /// A flap with no owed sweeps closes nothing while it lasts. Its recovery
    /// closes, after the first re-sweep delay, only sockets whose address is
    /// gone (the tunnel came back on another address): a route that moved is
    /// not judged after a flap.
    @RuntimeActor func testAFlapRecoveryClosesOnlySocketsWhoseAddressIsGone() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        // The connect owes no sweep before any socket of the flap is tracked.
        try await connectAndSettle(orchestrator)
        let settled = migrations(orchestrator.eventLog.events).count
        let oldAddress = try await tracked(orchestrator, local: "10.20.30.40")
        let routeMoved = try await tracked(orchestrator, local: "10.20.30.41")
        await orchestrator.handleVPNStateChange(.reasserting)
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }
        moved.withLockedValue { _ = $0.insert("10.20.30.41") }
        XCTAssertNil(delays.held, "nothing is swept during the flap")
        await drain(oldAddress)
        XCTAssertTrue(oldAddress.isActive, "nothing is swept during the flap")

        await orchestrator.handleVPNStateChange(.connected)
        try await until { self.delays.held == self.resweep }
        await drain(oldAddress)
        XCTAssertTrue(oldAddress.isActive, "the recovery waits before judging addresses")
        XCTAssertEqual(delays.release(), resweep)
        try await until({
            self.migrations(orchestrator.eventLog.events).count > settled
        }, else: "\(migrations(orchestrator.eventLog.events))")
        await drain(oldAddress, routeMoved)
        XCTAssertFalse(oldAddress.isActive)
        XCTAssertTrue(routeMoved.isActive)
        XCTAssertEqual(Array(migrations(orchestrator.eventLog.events).dropFirst(settled)),
                       ["transition=flap_recovered phase=addresses pass=1 upstream_closed=0 direct_closed=1 unchecked=0"])
        XCTAssertNil(delays.held)
    }

    /// A connected VPN moving to another tunnel interface is a transition:
    /// the old tunnel's sockets are swept.
    @RuntimeActor func testATunnelChangeWhileConnectedSweeps() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected, interfaceName: "utun4")
        // Its first pass ran: it cannot judge the socket below.
        try await until { self.delays.held == self.resweep }
        let onOldTunnel = try await tracked(orchestrator, local: "10.20.30.40")
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }

        await orchestrator.handleVPNStateChange(.connected, interfaceName: "utun5")
        try await until { !onOldTunnel.isActive }
        XCTAssertEqual(orchestrator.snapshot.vpnInterfaceName, "utun5")
        XCTAssertTrue(migrations(orchestrator.eventLog.events).contains {
            $0.hasPrefix("transition=tunnel_changed phase=paths pass=0 ") && $0.contains(" direct_closed=1 ")
        })
    }

    /// A flap that a wake recovers, not a monitor report, still runs the
    /// recovery's sweep: the monitor's later `.connected` changes nothing.
    @RuntimeActor func testAWakeRecoveryRunsTheHeldSweep() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        try await connectAndSettle(orchestrator)
        let oldAddress = try await tracked(orchestrator, local: "10.20.30.40")
        await orchestrator.handleVPNStateChange(.reasserting)
        gone.withLockedValue { _ = $0.insert("10.20.30.40") }

        await orchestrator.handleSystemWake()
        XCTAssertEqual(orchestrator.snapshot.vpnState, .connected)
        try await until { self.delays.held == self.resweep }
        XCTAssertEqual(delays.release(), resweep)
        try await until({
            self.migrations(orchestrator.eventLog.events).last
                == "transition=flap_recovered phase=addresses pass=1 upstream_closed=0 direct_closed=1 unchecked=0"
        }, else: "\(migrations(orchestrator.eventLog.events))")
        await drain(oldAddress)
        XCTAssertFalse(oldAddress.isActive)
    }

    /// The first report after startup is a real transition: `unknown →
    /// connected` sweeps like any other (#160).
    @RuntimeActor func testTheFirstConnectedReportSweeps() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        let beforeVPN = try await tracked(orchestrator, local: "192.168.2.20")
        gone.withLockedValue { _ = $0.insert("192.168.2.20") }
        await orchestrator.handleVPNStateChange(.connected)
        try await until { !beforeVPN.isActive }
    }

    private actor Gate {
        private var waiter: CheckedContinuation<Void, Never>?
        private var opened = false
        func wait() async {
            guard !opened else { return }
            await withCheckedContinuation { waiter = $0 }
        }
        var holding: Bool { waiter != nil }
        func open() { opened = true; waiter?.resume(); waiter = nil }
    }

    /// Re-sweep delays that pass only when the test releases them. One is
    /// held at a time, as one sweep task runs at a time; a second while one
    /// is held is refused and marks the fixture overused.
    private final class HeldDelays: Sendable {
        private struct Held: Sendable {
            let id: Int
            let delay: Duration
            let waiter: CheckedContinuation<Void, any Error>
        }
        private struct State: Sendable {
            var held: Held?
            var started = 0
            var cancelled = 0
            var overused = false
            var finished = false
        }
        private let state = NIOLockedValueBox(State())

        var held: Duration? { state.withLockedValue { $0.held?.delay } }
        /// Delays cancelled while held, or started by a cancelled sweep.
        var cancelled: Int { state.withLockedValue { $0.cancelled } }
        var overused: Bool { state.withLockedValue { $0.overused } }

        func sleep(_ delay: Duration) async throws {
            let id = state.withLockedValue { $0.started += 1; return $0.started }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    // One locked step with the cancellation check, so a cancel between them is not missed.
                    let holds = self.state.withLockedValue { (state: inout State) -> Bool in
                        if Task.isCancelled {
                            state.cancelled += 1
                            return false
                        }
                        guard !state.finished else { return false }
                        guard state.held == nil else {
                            state.overused = true
                            return false
                        }
                        state.held = Held(id: id, delay: delay, waiter: waiter)
                        return true
                    }
                    if !holds { waiter.resume(throwing: CancellationError()) }
                }
            } onCancel: {
                let held = self.state.withLockedValue { (state: inout State) -> Held? in
                    guard let held = state.held, held.id == id else { return nil }
                    state.held = nil
                    state.cancelled += 1
                    return held
                }
                held?.waiter.resume(throwing: CancellationError())
            }
        }

        /// Passes the held delay, and returns it.
        func release() -> Duration? {
            let held = state.withLockedValue { (state: inout State) -> Held? in
                defer { state.held = nil }
                return state.held
            }
            held?.waiter.resume()
            return held?.delay
        }

        /// Cancels the held delay and every later one.
        func finish() {
            let held = state.withLockedValue { (state: inout State) -> Held? in
                defer { state.held = nil }
                state.finished = true
                return state.held
            }
            held?.waiter.resume(throwing: CancellationError())
        }
    }

    /// A reconnect that runs while the disconnect handler waits on its probe
    /// owns routing; the stale handler must not sweep on its old verdict.
    @RuntimeActor func testADisconnectSupersededDuringItsProbeSkipsTheRoutingSweep() async throws {
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

        let disconnect = Task { @RuntimeActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        addTeardownBlock {
            await gate.open()
            await disconnect.value
        }
        try await until { await gate.holding }
        reachable.withLockedValue { $0 = true }
        await orchestrator.handleVPNStateChange(.connected)
        await gate.open()
        await disconnect.value

        let routing = migrations(orchestrator.eventLog.events).filter { $0.contains("phase=routing") }
        XCTAssertEqual(routing, ["transition=disconnected phase=routing reason=user skipped=superseded"])
    }

    /// A reconnect while the listener is stopped (a config restart in
    /// flight) still closes the stranded sockets the restart preserved.
    @RuntimeActor func testAReconnectWithTheListenerStoppedStillSweeps() async throws {
        let orchestrator = orchestrator(reachable: NIOLockedValueBox(false))
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        try await until { self.delays.held == self.resweep }
        let offVPN = try await tracked(orchestrator, local: "192.168.2.20")
        await orchestrator.stopProxy(scope: .allButDedicated)
        gone.withLockedValue { _ = $0.insert("192.168.2.20") }

        await orchestrator.handleVPNStateChange(.connected)

        try await until { !offVPN.isActive }
        XCTAssertTrue(migrations(orchestrator.eventLog.events).contains(
            "transition=connected phase=paths pass=0 upstream_closed=0 direct_closed=1 unchecked=0"))
    }

    /// On-prem: the probe finds the upstream, so the routing phase closes nothing.
    @RuntimeActor func testAReachableUpstreamKeepsItsChannelsInTheRoutingPhase() async throws {
        let orchestrator = orchestrator()
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))

        XCTAssertEqual(migrations(orchestrator.eventLog.events).last { $0.contains("phase=routing") },
                       "transition=disconnected phase=routing reason=lost routing=upstream upstream_closed=0")
    }

    /// A disconnect while the listener is stopped still closes stranded
    /// sockets at once, and its routing phase runs once the start probe
    /// decides routing: an upstream tunnel the restart preserved would stall
    /// on proxies behind the gone VPN (#156).
    @RuntimeActor func testADisconnectWithTheListenerStoppedRoutesOnceTheStartProbeDecides() async throws {
        let reachable = NIOLockedValueBox(true)
        let orchestrator = orchestrator(reachable: reachable)
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        let preserved = try await tracked(orchestrator, local: "192.168.2.20", route: .upstream)
        await orchestrator.stopProxy(scope: .allButDedicated)
        reachable.withLockedValue { $0 = false }

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        // The path sweep ran with the listener stopped.
        try await until {
            migrations(orchestrator.eventLog.events).last?.hasPrefix("transition=disconnected phase=paths pass=0 ") ?? false
        }
        await drain(preserved)
        XCTAssertTrue(preserved.isActive, "its path is current and routing is not decided yet")

        try await orchestrator.startProxy()

        await drain(preserved)
        XCTAssertFalse(preserved.isActive)
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last { $0.contains("phase=routing") },
                       "transition=disconnected phase=routing reason=user routing=direct upstream_closed=1")
    }

    /// Calls `onListening` when the listener logs that it is up: after the
    /// start probe committed, before startup reports running.
    private final class ListeningHook: LogSink, @unchecked Sendable {
        let onListening: @Sendable () -> Void
        init(_ onListening: @escaping @Sendable () -> Void) { self.onListening = onListening }
        var minLevel: LogLevel { .debug }
        func flush(timeout: TimeInterval) -> Bool { true }
        func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome { .drained }
        func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
            if message.hasPrefix("Local proxy listening on") { onListening() }
        }
    }

    /// A disconnect that lands after the start probe committed (while the
    /// listener binds) made that verdict stale; startup decides again and
    /// runs the routing phase before it reports running.
    @RuntimeActor func testADisconnectAfterTheStartProbeIsRoutedBeforeRunning() async throws {
        let reachable = NIOLockedValueBox(true)
        let box = NIOLockedValueBox<ProxyOrchestrator?>(nil)
        let disconnect = NIOLockedValueBox<Task<Void, Never>?>(nil)
        let hook = ListeningHook {
            guard let orchestrator = box.withLockedValue({ $0 }) else { return }
            reachable.withLockedValue { $0 = false }
            disconnect.withLockedValue {
                $0 = Task { @RuntimeActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
            }
        }
        let orchestrator = orchestrator(reachable: reachable, logger: hook)
        addTeardownBlock { await disconnect.withLockedValue({ $0 })?.value }
        await orchestrator.handleVPNStateChange(.connected)
        let preserved = try await tracked(orchestrator, local: "192.168.2.20", route: .upstream)
        box.withLockedValue { $0 = orchestrator }

        try await orchestrator.startProxy()

        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .userInitiated), "the disconnect landed during startup")
        XCTAssertTrue(orchestrator.snapshot.directModeCause.routesClientTrafficDirectly)
        await drain(preserved)
        XCTAssertFalse(preserved.isActive, "the deferred routing phase ran before .running")
        XCTAssertEqual(migrations(orchestrator.eventLog.events).last { $0.contains("phase=routing") },
                       "transition=disconnected phase=routing reason=user routing=direct upstream_closed=1")
    }
}
