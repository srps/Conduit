// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// #155: a connectivity probe that straddles a newer VPN transition, or that
/// a later-started probe overtook, must not change routing.
@MainActor
final class ConnectivityProbeSupersessionTests: XCTestCase {
    /// Scripted probes: each call takes the next reachability verdict and,
    /// if told to, parks until released, so a test picks the interleaving.
    private final class ProbeScript: @unchecked Sendable {
        private let lock = NIOLock()
        private var verdicts: [Bool] = []
        private var held: Set<Int> = []
        private var parked: [Int: CheckedContinuation<Void, Never>] = [:]
        private var calls = 0

        /// Queue the verdict for the next probe; `hold` parks it until `release`.
        func next(reachable: Bool, hold: Bool = false) -> Int {
            lock.withLock {
                let index = calls + verdicts.count
                verdicts.append(reachable)
                if hold { held.insert(index) }
                return index
            }
        }

        func probe(_ upstreams: [UpstreamProxy]) async -> UpstreamProbeSummary {
            let (index, reachable, hold) = lock.withLock { () -> (Int, Bool, Bool) in
                let index = calls
                calls += 1
                let reachable = verdicts.isEmpty ? true : verdicts.removeFirst()
                return (index, reachable, held.contains(index))
            }
            if hold {
                await withCheckedContinuation { continuation in
                    lock.withLockVoid { parked[index] = continuation }
                }
            }
            return UpstreamProbeSummary(results: upstreams.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: reachable) })
        }

        func isParked(_ index: Int) -> Bool { lock.withLock { parked[index] != nil } }
        var callCount: Int { lock.withLock { calls } }

        func release(_ index: Int) {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                held.remove(index)
                return parked.removeValue(forKey: index)
            }
            continuation?.resume()
        }
    }

    private func makeOrchestrator(_ script: ProbeScript) -> ProxyOrchestrator {
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        return ProxyOrchestrator(config: config, authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                 connectivityProbe: { await script.probe($0) })
    }

    private func waitUntilParked(_ script: ProbeScript, _ index: Int) async throws {
        for _ in 0..<2_000 where !script.isParked(index) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(script.isParked(index), "probe \(index) never ran")
    }

    private func details(_ orchestrator: ProxyOrchestrator, _ name: String) -> [String] {
        orchestrator.eventLog.events.filter { $0.event == name }.map { $0.detail ?? "" }
    }

    /// Disconnect probe sees unreachable upstreams; the reconnect commits
    /// while it is held. The stale verdict must not turn routing DIRECT on
    /// a working VPN, sweep, or report the disconnect's outcome.
    func testAStaleDisconnectProbeLeavesTheReconnectsRouting() async throws {
        for reconnectHeld in [false, true] {
            let script = ProbeScript()
            let orchestrator = makeOrchestrator(script)
            _ = script.next(reachable: true)            // start
            try await orchestrator.startProxy()
            _ = script.next(reachable: true)            // .unknown -> .connected
            await orchestrator.handleVPNStateChange(.connected)

            let disconnectProbe = script.next(reachable: false, hold: true)
            let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
            try await waitUntilParked(script, disconnectProbe)

            let reconnectProbe = script.next(reachable: true, hold: reconnectHeld)
            let reconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.connected) }
            if reconnectHeld {
                // Older result lands first, then the newer one.
                try await waitUntilParked(script, reconnectProbe)
                script.release(disconnectProbe)
                await disconnect.value
                script.release(reconnectProbe)
                await reconnect.value
            } else {
                await reconnect.value
                script.release(disconnectProbe)
                await disconnect.value
            }

            XCTAssertEqual(orchestrator.snapshot.vpnState, .connected)
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .none, "reconnectHeld=\(reconnectHeld)")
            XCTAssertNotEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")
            XCTAssertEqual(details(orchestrator, "connectivity.probe_superseded"),
                           ["by=transition probed_vpn=disconnected current_vpn=connected reachable=false"])
            XCTAssertEqual(details(orchestrator, "vpn.tunnels_migrated").filter { $0.contains("phase=routing") },
                           ["transition=disconnected phase=routing reason=user skipped=superseded"])
            XCTAssertTrue(details(orchestrator, "direct_mode.entered").isEmpty)
            XCTAssertFalse(orchestrator.eventLog.events.contains { $0.event == "vpn.disconnected.user" })
            XCTAssertEqual(orchestrator.eventLog.events.filter { $0.event == "vpn.connected" }.count, 2)
            await orchestrator.stopProxy()
        }
    }

    /// Reconnect probe sees reachable upstreams; a newer disconnect commits
    /// while it is held. The stale verdict must not lift direct mode while
    /// the VPN is down.
    func testAStaleReconnectProbeLeavesTheDisconnectsRouting() async throws {
        for disconnectHeld in [false, true] {
            let script = ProbeScript()
            let orchestrator = makeOrchestrator(script)
            _ = script.next(reachable: true)
            try await orchestrator.startProxy()
            _ = script.next(reachable: true)
            await orchestrator.handleVPNStateChange(.connected)
            _ = script.next(reachable: false)
            await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)

            let reconnectProbe = script.next(reachable: true, hold: true)
            let reconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.connected) }
            try await waitUntilParked(script, reconnectProbe)

            let disconnectProbe = script.next(reachable: false, hold: disconnectHeld)
            let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost)) }
            if disconnectHeld {
                try await waitUntilParked(script, disconnectProbe)
                script.release(reconnectProbe)
                await reconnect.value
                script.release(disconnectProbe)
                await disconnect.value
            } else {
                await disconnect.value
                script.release(reconnectProbe)
                await reconnect.value
            }

            XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .networkLost))
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected, "disconnectHeld=\(disconnectHeld)")
            XCTAssertEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")
            XCTAssertEqual(details(orchestrator, "connectivity.probe_superseded"),
                           ["by=transition probed_vpn=connected current_vpn=disconnected reachable=true"])
            // Only the cold-start connect reports; the stale reconnect does not.
            XCTAssertEqual(orchestrator.eventLog.events.filter { $0.event == "vpn.connected" }.count, 1)
            XCTAssertEqual(details(orchestrator, "vpn.tunnels_migrated").last,
                           "transition=disconnected phase=routing reason=lost routing=direct upstream_closed=0")
            await orchestrator.stopProxy()
        }
    }

    /// A PAC fetch that parks when told to; evaluation is the real one.
    private final class HeldPAC: PacEvaluator, @unchecked Sendable {
        private let lock = NIOLock()
        private var holdNext = false
        private var parked: CheckedContinuation<Void, Never>?
        private let evaluator = CFPACEvaluator()

        func holdNextFetch() { lock.withLockVoid { holdNext = true } }
        var isParked: Bool { lock.withLock { parked != nil } }
        func release() {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Never>? in defer { parked = nil }; return parked }
            continuation?.resume()
        }

        func fetchPAC(from urlString: String) async throws -> String {
            let hold = lock.withLock { () -> Bool in defer { holdNext = false }; return holdNext }
            if hold { await withCheckedContinuation { continuation in lock.withLockVoid { parked = continuation } } }
            return #"function FindProxyForURL(url, host) { return "PROXY 127.0.0.1:9"; }"#
        }

        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
            try evaluator.makeEvaluator(pacScript: pacScript)
        }

        func routeChain(for entries: [String]) -> PACChain {
            evaluator.routeChain(for: entries)
        }
    }

    /// The reconnect's probe commits, but a newer disconnect runs while its
    /// PAC refresh is pending: the reconnect must not report `vpn.connected`
    /// over the disconnected state.
    func testAReconnectSupersededDuringItsPACRefreshReportsNoOutcome() async throws {
        let script = ProbeScript()
        let pac = HeldPAC()
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false
        config.pacRoutingEnabled = true; config.pacURL = "http://pac.example.test/proxy.pac"
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink(),
                                             authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                             pacEvaluator: pac, connectivityProbe: { await script.probe($0) })
        _ = script.next(reachable: true)
        try await orchestrator.startProxy()
        _ = script.next(reachable: true)
        await orchestrator.handleVPNStateChange(.connected)
        _ = script.next(reachable: false)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        pac.holdNextFetch()
        let reconnectProbe = script.next(reachable: true)
        let reconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.connected) }
        for _ in 0..<2_000 where !(pac.isParked && script.callCount > reconnectProbe) { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertTrue(pac.isParked)
        let connectedBefore = details(orchestrator, "vpn.connected").count

        _ = script.next(reachable: false)
        let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost)) }
        for _ in 0..<2_000 where script.callCount <= reconnectProbe + 1 { try await Task.sleep(for: .milliseconds(1)) }
        pac.release()
        await reconnect.value
        await disconnect.value

        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .networkLost))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        XCTAssertEqual(details(orchestrator, "vpn.connected").count, connectedBefore, "the superseded reconnect reports nothing")
        XCTAssertEqual(details(orchestrator, "vpn.disconnected.lost").count, 1)
        await orchestrator.stopProxy()
    }

    /// Overlapping probes under one VPN state: a wake probe starts after the
    /// disconnect's and commits first. The older result yields to it, and
    /// the disconnect handler routes on the newer evidence.
    func testAnOlderProbeYieldsToANewerOneUnderTheSameTransition() async throws {
        let script = ProbeScript()
        let orchestrator = makeOrchestrator(script)
        _ = script.next(reachable: true)
        try await orchestrator.startProxy()
        _ = script.next(reachable: true)
        await orchestrator.handleVPNStateChange(.connected)

        let disconnectProbe = script.next(reachable: false, hold: true)
        let disconnect = Task { @MainActor in await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated)) }
        try await waitUntilParked(script, disconnectProbe)
        _ = script.next(reachable: true)            // wake: on-prem, upstream answers
        await orchestrator.handleSystemWake()
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)

        script.release(disconnectProbe)
        await disconnect.value

        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)
        XCTAssertEqual(details(orchestrator, "connectivity.probe_superseded"),
                       ["by=newer_probe probed_vpn=disconnected current_vpn=disconnected reachable=false"])
        XCTAssertEqual(details(orchestrator, "vpn.tunnels_migrated").last,
                       "transition=disconnected phase=routing reason=user routing=upstream upstream_closed=0")
        await orchestrator.stopProxy()
    }

    /// A VPN report during startup supersedes the start probe; the listener
    /// is not up, so nothing else probes. Startup probes again.
    func testStartupProbesAgainWhenAVPNReportSupersedesIt() async throws {
        let script = ProbeScript()
        let orchestrator = makeOrchestrator(script)
        let first = script.next(reachable: false, hold: true)
        let start = Task { @MainActor in try await orchestrator.startProxy() }
        try await waitUntilParked(script, first)
        await orchestrator.handleVPNStateChange(.connected)
        _ = script.next(reachable: true)
        script.release(first)
        try await start.value

        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)
        XCTAssertEqual(details(orchestrator, "connectivity.probe_superseded"),
                       ["by=transition probed_vpn=unknown current_vpn=connected reachable=false"])
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

    /// A reconnect that lands after the start probe committed, while the
    /// listener binds, finds the listener not yet running and reacts to
    /// nothing. Startup must decide again before it reports running, not
    /// publish the off-VPN DIRECT verdict.
    func testAVPNReportAfterTheStartProbeIsDecidedAgainBeforeRunning() async throws {
        let script = ProbeScript()
        _ = script.next(reachable: false)
        let box = NIOLockedValueBox<ProxyOrchestrator?>(nil)
        let hook = ListeningHook {
            guard let orchestrator = box.withLockedValue({ $0 }) else { return }
            box.withLockedValue { $0 = nil }
            _ = script.next(reachable: true)
            Task { @MainActor in await orchestrator.handleVPNStateChange(.connected) }
        }
        var config = ProxyConfig()
        config.localPort = 0; config.localPACEnabled = false; config.pacRoutingEnabled = false
        config.healthCheckIntervalSeconds = 3600
        config.upstreams = [UpstreamProxy(name: "fixture", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, logger: hook,
                                             authenticatorProvider: { _ in MockAuthenticator(scheme: "Basic", token: "fixture") },
                                             connectivityProbe: { await script.probe($0) })
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        box.withLockedValue { $0 = orchestrator }

        try await orchestrator.startProxy()

        XCTAssertEqual(orchestrator.snapshot.vpnState, .connected, "the reconnect landed during startup")
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none, "routing follows the reconnect")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "127.0.0.1:9")
        XCTAssertEqual(details(orchestrator, "connectivity.startup_rederived"), ["attempt=1 vpn=connected"])
        await orchestrator.stopProxy()
    }

    /// Hosts stamp reports on the monitor's callback. An older report that
    /// lands after a newer one is dropped, but a dropped disconnect still
    /// runs its address phase: the sockets it stranded are dead regardless.
    func testAnOlderVPNReportIsDroppedAndADroppedDisconnectStillSweepsAddresses() async throws {
        let script = ProbeScript()
        let orchestrator = makeOrchestrator(script)
        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected, sequence: 2)

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated), sequence: 1)

        XCTAssertEqual(orchestrator.snapshot.vpnState, .connected)
        XCTAssertEqual(details(orchestrator, "vpn.observation_stale"), ["state=disconnected sequence=1 applied=2"])
        let migrated = details(orchestrator, "vpn.tunnels_migrated")
        XCTAssertEqual(migrated.count, 1)
        XCTAssertTrue(migrated[0].hasPrefix("transition=disconnected phase=addresses reason=user "), migrated[0])
        await orchestrator.stopProxy()
    }

    func testTheSequencerStampsInCallOrderAndEachConsumerKeepsItsOwnPosition() {
        let sequencer = VPNObservationSequencer()
        let first = sequencer.next(), second = sequencer.next()
        XCTAssertLessThan(first, second)
        var gate = VPNObservationOrder(), orchestrator = VPNObservationOrder()
        XCTAssertTrue(gate.admit(second))
        XCTAssertFalse(gate.admit(first))
        XCTAssertTrue(orchestrator.admit(first), "a second consumer is not consumed by the first")
        XCTAssertTrue(orchestrator.admit(second))
    }
}
