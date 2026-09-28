// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel
@testable import ProxyPAC

/// #96: a VPN transition changes the network the PAC was fetched and
/// evaluated on, so the orchestrator drops the engine's answers and fetches
/// the PAC again, ignoring the failure backoff.
@MainActor
final class VPNPACRefreshTests: XCTestCase {

    /// Serves one script off the VPN and another on it, the way a corporate
    /// PAC server does. Evaluation is the real CFNetwork evaluator.
    private final class NetworkPAC: PacEvaluator, @unchecked Sendable {
        static let offVPN = #"function FindProxyForURL(url, host) { return "PROXY policy-detection.example:80"; }"#
        static let onVPN = #"function FindProxyForURL(url, host) { return "PROXY corp.example:8080"; }"#

        private let state = NIOLockedValueBox((onVPN: false, failing: false, fetches: 0))
        private let evaluator = CFPACEvaluator()

        var fetches: Int { state.withLockedValue { $0.fetches } }
        func setOnVPN(_ value: Bool) { state.withLockedValue { $0.onVPN = value } }
        func setFailing(_ value: Bool) { state.withLockedValue { $0.failing = value } }

        func fetchPAC(from urlString: String) async throws -> String {
            let (onVPN, failing) = state.withLockedValue { state -> (Bool, Bool) in
                state.fetches += 1
                return (state.onVPN, state.failing)
            }
            if failing { throw PACResolverError.fetchFailed("PAC host unreachable") }
            return onVPN ? Self.onVPN : Self.offVPN
        }

        func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating {
            try evaluator.makeEvaluator(pacScript: pacScript)
        }

        func routeChain(for entries: [String]) -> PACChain {
            evaluator.routeChain(for: entries)
        }
    }

    private func makeOrchestrator(pac: NetworkPAC) -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink(), pacEvaluator: pac)
    }

    private func events(named name: String, in log: RuntimeEventLog, since: Date) -> [RuntimeEvent] {
        log.events.filter { $0.event == name && $0.timestamp >= since }
    }

    /// Cold start: the PAC loads before the VPN observer primes. The priming
    /// `.connected` verdict fetches it again.
    func testPrimingToConnectedFetchesThePACAgain() async throws {
        let pac = NetworkPAC()
        let orchestrator = makeOrchestrator(pac: pac)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }
        XCTAssertEqual(pac.fetches, 1, "the proxy start loads the PAC once")

        pac.setOnVPN(true)
        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(pac.fetches, 2, "the VPN-connected transition fetches the PAC again")
        let invalidated = events(named: "pac.routes_invalidated", in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(invalidated.count, 1)
        XCTAssertTrue(invalidated.first?.detail?.contains("reason=vpn_connected") ?? false,
                      "detail: \(invalidated.first?.detail ?? "nil")")
        XCTAssertEqual(events(named: "pac.refreshed", in: orchestrator.eventLog, since: cutoff).count, 1)
    }

    /// The app's proxy.log keeps NOTICE and above and it writes no
    /// events.ndjson, so both the drop and the reload show there.
    func testTheDropAndTheReloadAreVisibleAtNotice() async throws {
        let pac = NetworkPAC()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.pacRoutingEnabled = true
        config.pacURL = "http://pac.example.test/proxy.pac"
        let log = RecordingLogSink(minLevel: .notice)
        let orchestrator = ProxyOrchestrator(config: config, logger: log, pacEvaluator: pac)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        pac.setOnVPN(true)
        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertTrue(log.containsMessage("PAC answers dropped (vpn_connected)", at: .notice))
        XCTAssertTrue(log.containsMessage("Reloaded PAC routing rules from http://pac.example.test/proxy.pac after vpn_connected",
                                          at: .notice))
        XCTAssertEqual(events(named: "pac.refreshed", in: orchestrator.eventLog, since: cutoff).map(\.detail),
                       ["url=http://pac.example.test/proxy.pac after=vpn_connected"])
    }

    /// A full outage and reconnect: each side of it fetches the PAC.
    func testDisconnectAndReconnectEachFetchThePAC() async throws {
        let pac = NetworkPAC()
        pac.setOnVPN(true)
        let orchestrator = makeOrchestrator(pac: pac)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }
        await orchestrator.handleVPNStateChange(.connected)
        let primed = pac.fetches

        pac.setOnVPN(false)
        var cutoff = Date()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        XCTAssertEqual(pac.fetches, primed + 1, "the disconnect fetches the off-VPN PAC")
        let dropped = events(named: "pac.routes_invalidated", in: orchestrator.eventLog, since: cutoff)
        XCTAssertTrue(dropped.first?.detail?.contains("reason=vpn_disconnected") ?? false,
                      "detail: \(dropped.first?.detail ?? "nil")")

        pac.setOnVPN(true)
        cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertEqual(pac.fetches, primed + 2, "the reconnect fetches the on-VPN PAC")
        let reconnected = events(named: "pac.routes_invalidated", in: orchestrator.eventLog, since: cutoff)
        XCTAssertTrue(reconnected.first?.detail?.contains("reason=vpn_connected") ?? false,
                      "detail: \(reconnected.first?.detail ?? "nil")")
    }

    /// A PAC server that failed off the VPN is in backoff; the VPN coming up
    /// is a different network, so the fetch runs anyway.
    func testReconnectFetchesDespiteTheFailureBackoff() async throws {
        let pac = NetworkPAC()
        pac.setFailing(true)
        let orchestrator = makeOrchestrator(pac: pac)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }
        XCTAssertEqual(pac.fetches, 1)

        pac.setFailing(false)
        pac.setOnVPN(true)
        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(pac.fetches, 2, "the backoff does not hold back the VPN-connected fetch")
        XCTAssertTrue(events(named: "pac.refresh_backoff", in: orchestrator.eventLog, since: cutoff).isEmpty)
        XCTAssertEqual(events(named: "pac.refreshed", in: orchestrator.eventLog, since: cutoff).count, 1)
    }

    /// A flap keeps the network; it neither drops the routes nor fetches.
    func testFlapRecoveryLeavesThePACAlone() async throws {
        let pac = NetworkPAC()
        pac.setOnVPN(true)
        let orchestrator = makeOrchestrator(pac: pac)
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }
        await orchestrator.handleVPNStateChange(.connected)
        let primed = pac.fetches

        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(pac.fetches, primed)
        XCTAssertTrue(events(named: "pac.routes_invalidated", in: orchestrator.eventLog, since: cutoff).isEmpty)
    }
}
