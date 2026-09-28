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

    // MARK: - handleNetworkPath

    private static func wifi(gateway: String = "192.168.1.1", satisfied: Bool = true) -> NetworkPathState {
        NetworkPathState(
            status: satisfied ? .satisfied : .unsatisfied,
            interfaces: [.init(name: "en0", type: "wifi")],
            gateways: [gateway],
            supportsIPv4: true, supportsIPv6: true, supportsDNS: true
        )
    }

    private func startOrchestratorWithDNS() async throws -> ProxyOrchestrator {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        var config = orchestrator.config
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        await orchestrator.applyConfigChange(config)
        await orchestrator.startDNS()
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")
        return orchestrator
    }

    func testNetworkChangeEmitsTransportResetWhenDNSRunning() async throws {
        let orchestrator = try await startOrchestratorWithDNS()
        defer { Task { @MainActor in await orchestrator.stopDNS(); await orchestrator.stopProxy() } }

        let cutoff = Date()
        let acted = await orchestrator.handleNetworkPath(Self.wifi())

        XCTAssertTrue(acted, "the first path is always acted on")
        let resets = transportResetEvents(in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(resets.count, 1)
        XCTAssertEqual(resets.first?.detail, "source=network_change")

        let change = try XCTUnwrap(orchestrator.eventLog.events.last { $0.event == "network.path_changed" })
        XCTAssertEqual(change.kind, .health)
        XCTAssertEqual(
            change.detail,
            "satisfied=true dns=reset pac=refresh changed=initial unchanged_before=0 "
                + "path=satisfied; interfaces en0/wifi; gateways 192.168.1.1; supports ipv4,ipv6,dns"
        )
        XCTAssertLessThanOrEqual(change.timestamp, resets[0].timestamp, "the path event precedes what it decided")
    }

    /// #101: `NWPathMonitor` delivered an update every ~75 s for hours with
    /// nothing material changed, and each one reset the DoH transports and
    /// refetched the PAC. Identical updates must do neither.
    func testIdenticalPathUpdatesResetNothing() async throws {
        let orchestrator = try await startOrchestratorWithDNS()
        defer { Task { @MainActor in await orchestrator.stopDNS(); await orchestrator.stopProxy() } }
        await orchestrator.handleNetworkPath(Self.wifi())

        let cutoff = Date()
        var acted = 0
        for _ in 0..<20 {
            if await orchestrator.handleNetworkPath(Self.wifi()) { acted += 1 }
        }

        let since = orchestrator.eventLog.events.filter { $0.timestamp >= cutoff }
        XCTAssertEqual(acted, 0)
        XCTAssertEqual(transportResetEvents(in: orchestrator.eventLog, since: cutoff).count, 0)
        XCTAssertEqual(since.filter { $0.event == "network.path_changed" }.count, 0,
                       "no path_changed, so no pac=refresh")
        let unchanged = since.filter { $0.event == "network.path_unchanged" }
        XCTAssertEqual(unchanged.compactMap { $0.detail?.split(separator: " ").first.map(String.init) },
                       ["count=1", "count=2", "count=4", "count=8", "count=16"],
                       "coalesced: counts 1, 2, 4, 8, 16 of 20")
    }

    /// A Wi-Fi roam keeps the interface and moves the gateway. It must still
    /// act, and the event and NOTICE line must say what moved.
    func testGatewayChangeResetsOnceAndNamesTheField() async throws {
        let logger = RecordingLogSink(minLevel: .notice)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: logger)
        try await orchestrator.startProxy()
        await orchestrator.startDNS()
        defer { Task { @MainActor in await orchestrator.stopDNS(); await orchestrator.stopProxy() } }
        XCTAssertEqual(orchestrator.snapshot.dnsRunState, .running, "DNS forwarder must bind for this test")
        await orchestrator.handleNetworkPath(Self.wifi())
        for _ in 0..<3 { await orchestrator.handleNetworkPath(Self.wifi()) }

        let cutoff = Date()
        let acted = await orchestrator.handleNetworkPath(Self.wifi(gateway: "10.0.0.1"))

        XCTAssertTrue(acted)
        XCTAssertEqual(transportResetEvents(in: orchestrator.eventLog, since: cutoff).count, 1)
        let change = try XCTUnwrap(orchestrator.eventLog.events.last { $0.event == "network.path_changed" })
        XCTAssertEqual(
            change.detail,
            "satisfied=true dns=reset pac=refresh changed=gateways unchanged_before=3 gateways=192.168.1.1->10.0.0.1 "
                + "path=satisfied; interfaces en0/wifi; gateways 10.0.0.1; supports ipv4,ipv6,dns"
        )
        let line = try XCTUnwrap(logger.entries().last { $0.message.hasPrefix("Network path changed") })
        XCTAssertEqual(line.level, .notice, "proxy.log keeps NOTICE and above")
        XCTAssertTrue(line.message.contains("gateways=192.168.1.1->10.0.0.1"), line.message)
        XCTAssertLessThanOrEqual(change.timestamp, line.timestamp)
    }

    /// The event is the record and the log line derives from it (AGENTS:
    /// structured events first). An unsatisfied path decides "skip" inside
    /// the same event rather than through a second one (#40).
    func testNetworkChangeEmitsThePathEventBeforeItsLogLine() async throws {
        let logger = RecordingLogSink(minLevel: .info)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = []
        let orchestrator = ProxyOrchestrator(config: config, logger: logger)
        await orchestrator.handleNetworkPath(Self.wifi())

        let cutoff = Date()
        await orchestrator.handleNetworkPath(Self.wifi(satisfied: false))

        let change = try XCTUnwrap(orchestrator.eventLog.events.last { $0.event == "network.path_changed" })
        XCTAssertEqual(change.kind, .health)
        XCTAssertEqual(
            change.detail,
            "satisfied=false dns=idle pac=skipped_unsatisfied changed=status unchanged_before=0 "
                + "status=satisfied->unsatisfied path=unsatisfied; interfaces en0/wifi; gateways 192.168.1.1; supports ipv4,ipv6,dns"
        )
        let line = try XCTUnwrap(logger.entries().last { $0.message.hasPrefix("Network path changed (status=satisfied->unsatisfied)") })
        XCTAssertEqual(line.level, .notice)
        XCTAssertLessThanOrEqual(change.timestamp, line.timestamp)
        XCTAssertFalse(
            orchestrator.eventLog.events.contains { $0.timestamp >= cutoff && $0.event == "pac.refresh_skipped" },
            "the skip is a token on the path event, not a second event"
        )
        XCTAssertTrue(transportResetEvents(in: orchestrator.eventLog, since: cutoff).isEmpty, "DNS was not running")
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
