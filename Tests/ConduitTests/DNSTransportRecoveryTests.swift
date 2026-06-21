// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyKernel

/// Asserts the orchestrator emits a `dns.transports_reset` structured event
/// (kind `.health`, detail `source=<reason>`) at the three call sites that
/// recycle the DNS forwarder's DoH `URLSession`s after a network event:
///
///   * `handleSystemWake()` — wake from sleep.
///   * `handleVPNStateChange(.reasserting → .connected)` — flap recovered.
///   * `handleVPNStateChange(.disconnected → .connected)` — outage recovered.
///
/// The implementation lives in `LocalDNSForwarder.resetUpstreamTransports(reason:)`
/// + `ProxyOrchestrator.resetDNSTransportsForRecovery(source:)`. These tests
/// pin the *event surface* (kind, name, source tag, count) so log pipelines
/// and `pmctl events` can group on it without parsing prose. Mechanical reset
/// behaviour is covered by `DNSForwarderIntegrationTests`.
@MainActor
final class DNSTransportRecoveryTests: XCTestCase {

    private func makeOrchestrator() -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }

    private func transportResetEvents(
        in log: RuntimeEventLog,
        since: Date
    ) -> [RuntimeEvent] {
        log.events.filter { $0.event == "dns.transports_reset" && $0.timestamp >= since }
    }

    // MARK: - handleNetworkChange

    func testNetworkChangeEmitsTransportResetWhenDNSRunning() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        var config = orchestrator.config
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 16_000 + Int.random(in: 0..<1000)
        await orchestrator.applyConfigChange(config)
        await orchestrator.startDNS()
        defer { Task { @MainActor in await orchestrator.stopDNS() } }
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")

        let cutoff = Date()
        await orchestrator.handleNetworkChange(description: "Wi-Fi path changed")

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(resets.first?.detail, "source=network_change")
    }

    // MARK: - handleSystemWake

    func testSystemWakeEmitsTransportResetWithSystemWakeSource() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        // Prime: walk through a stable .connected state so wake has a real
        // baseline to recover into.
        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()

        await orchestrator.handleSystemWake()

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(resets.count, 1, "System wake must emit exactly one dns.transports_reset")
        XCTAssertEqual(resets.first?.kind, .health,
                       "dns.transports_reset must be classified as a health event so menu-bar / pmctl group it with upstream probes")
        XCTAssertEqual(resets.first?.detail, "source=system_wake",
                       "Source tag pins the call site so log pipelines can group on it")
    }

    // MARK: - .reasserting -> .connected (flap recovery)

    func testFlapRecoveryEmitsTransportResetWithFlapSource() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)
        let cutoff = Date()

        await orchestrator.handleVPNStateChange(.connected)

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(resets.count, 1, "Flap recovery must emit exactly one dns.transports_reset")
        XCTAssertEqual(resets.first?.detail, "source=vpn_flap_recovered",
                       "Source tag distinguishes flap from full reconnect")
    }

    // MARK: - .disconnected -> .connected (real-outage recovery)

    func testReconnectAfterDisconnectEmitsTransportResetWithReconnectSource() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        let cutoff = Date()

        await orchestrator.handleVPNStateChange(.connected)

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(resets.count, 1, "Reconnect must emit exactly one dns.transports_reset")
        XCTAssertEqual(resets.first?.detail, "source=vpn_reconnected",
                       "Source tag distinguishes full reconnect from sub-window flap")
    }

    // MARK: - Negative cases

    func testReassertingTransitionDoesNotEmitTransportReset() async throws {
        // The flap *start* is a silent-grace transition — no reset until
        // recovery. The reset is what restores reachable transports; tearing
        // them down at flap-start would orphan in-flight DoH lookups for the
        // duration of the grace window.
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()

        await orchestrator.handleVPNStateChange(.reasserting)

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertTrue(resets.isEmpty,
                      ".reasserting (grace start) must NOT recycle transports — recovery is what triggers the reset")
    }

    func testRepeatedConnectedStateProducesNoTransportResetStorm() async throws {
        // Idempotence guard at the top of handleVPNStateChange short-circuits
        // duplicate states. Confirm the reset path also benefits — no event
        // storm if a flaky observer fires .connected repeatedly.
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()

        for _ in 0..<5 {
            await orchestrator.handleVPNStateChange(.connected)
        }

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertTrue(resets.isEmpty,
                      "Repeated identical .connected calls must not re-trigger transport resets")
    }

    // MARK: - End-to-end transition sequence

    func testFullNetworkTransitionEmitsExactlyThreeTransportResets() async throws {
        // The `network-transition` scenario: wake → flap → reconnect.
        // Each phase emits exactly one reset with its own source tag. The
        // full sequence is the contract pmctl/menu-bar consume to render
        // recovery progress.
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()

        await orchestrator.handleSystemWake()
        await orchestrator.handleVPNStateChange(.reasserting)
        try await Task.sleep(for: .milliseconds(20))
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))
        await orchestrator.handleVPNStateChange(.connected)

        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        let sources = resets.compactMap { $0.detail }
        XCTAssertEqual(resets.count, 3,
                       "Wake + flap + reconnect must emit three resets (got \(sources))")
        XCTAssertEqual(Set(sources), [
            "source=system_wake",
            "source=vpn_flap_recovered",
            "source=vpn_reconnected"
        ], "Each phase must carry its distinct source tag")
    }
}
