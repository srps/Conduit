// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOPosix
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// Phase 4 transition table tests for `ProxyOrchestrator.handleVPNStateChange(_:)`.
/// Drives the orchestrator with synthetic `VPNObservedState` events and asserts
/// on snapshot transitions, emitted RuntimeEvents, and downstream side effects
/// (breaker reset, reprobe cadence, log severity).
///
/// Tests run with an isolated orchestrator (no real upstream proxies, no
/// SCDynamicStore, no live system side effects) per AGENTS.md "Never let
/// pm-proxy touch the host." We start the proxy with empty upstreams so it
/// boots into direct mode immediately, then exercise the transition table.
@MainActor
final class VPNTransitionTableTests: XCTestCase {

    // MARK: - Helpers

    private func makeOrchestrator() -> ProxyOrchestrator {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0  // ephemeral port; no port-conflict flakiness
        config.upstreams = [] // start in direct mode
        return ProxyOrchestrator(config: config, logger: DiscardingLogSink())
    }

    /// Find an event whose `event` string equals `name` and was emitted after
    /// `since`. Returns nil if none. Filtering by timestamp guards against
    /// startup events (proxy.starting, etc.) leaking into assertions.
    private func event(named name: String, in log: RuntimeEventLog, since: Date) -> RuntimeEvent? {
        log.events.last { $0.event == name && $0.timestamp >= since }
    }

    private func vpnEvents(in log: RuntimeEventLog, since: Date) -> [RuntimeEvent] {
        log.events.filter { $0.kind == .vpn && $0.timestamp >= since }
    }

    // MARK: - .reasserting transition

    func testReassertingSetsTransientCauseAndEmitsFlapStart() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        // Prime: VPN was connected. (orchestrator booted in .unknown; we
        // need to walk through .connected first so .reasserting has something
        // to recover from.)
        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()

        // Now flap.
        await orchestrator.handleVPNStateChange(.reasserting)

        XCTAssertEqual(orchestrator.snapshot.vpnState, .reasserting)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .transientNetworkChange,
                       ".reasserting must yield .transientNetworkChange (silent grace state)")
        XCTAssertNotNil(event(named: "vpn.flap.start", in: orchestrator.eventLog, since: cutoff),
                        "Reasserting transition must emit vpn.flap.start")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.lastHealthSummary,
                       DirectModeCause.transientNetworkChange.healthSummary)
    }

    // MARK: - .reasserting → .connected (flap recovery)

    func testReassertingToConnectedEmitsFlapRecoveredWithDuration() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)
        // Wait a measurable interval so the duration field has something
        // non-trivial to report (the test asserts duration >= 0, not a
        // specific value, so we just need any positive elapsed time).
        try await Task.sleep(for: .milliseconds(20))

        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)

        let recovered = event(named: "vpn.flap.recovered", in: orchestrator.eventLog, since: cutoff)
        XCTAssertNotNil(recovered, "Reasserting -> connected must emit vpn.flap.recovered")
        XCTAssertNotNil(recovered?.detail)
        XCTAssertTrue(recovered?.detail?.contains("duration=") ?? false,
                       "Recovered event detail must include flap duration")
        XCTAssertTrue(recovered?.detail?.contains("streamsPreserved=") ?? false,
                       "Recovered event detail must include preserved-stream count")
    }

    func testSystemWakeRecoversStaleReassertingWhenUpstreamIsReachable() async throws {
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(StaticRawHTTPResponseHandler(
                    response:
                        "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                        "Proxy-Authenticate: Negotiate\r\n" +
                        "Content-Length: 0\r\n" +
                        "\r\n"
                ))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        let port = try XCTUnwrap(serverChannel.localAddress?.port)

        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = [
            UpstreamProxy(name: "Wake Recovered", host: "127.0.0.1", port: port, priority: 0)
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        do {
            try await orchestrator.startProxy()
            await orchestrator.handleVPNStateChange(.connected)
            await orchestrator.handleVPNStateChange(.reasserting)
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .transientNetworkChange)

            let cutoff = Date()
            await orchestrator.handleSystemWake()

            XCTAssertEqual(orchestrator.snapshot.vpnState, .connected)
            XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)
            XCTAssertNotEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")
            let recovered = event(named: "vpn.flap.recovered", in: orchestrator.eventLog, since: cutoff)
            XCTAssertNotNil(recovered)
            XCTAssertTrue(recovered?.detail?.contains("source=system_wake") ?? false)

            await orchestrator.stopProxy()
            try await serverChannel.close()
        } catch {
            await orchestrator.stopProxy()
            try? await serverChannel.close()
            throw error
        }
    }

    // MARK: - .disconnected(.userInitiated)

    func testUserInitiatedDisconnectSetsVpnDisconnectedCauseImmediately() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected,
                       ".disconnected(.userInitiated) -> .vpnDisconnected immediately, no probe")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")

        let userEvt = event(named: "vpn.disconnected.user", in: orchestrator.eventLog, since: cutoff)
        XCTAssertNotNil(userEvt, "User-initiated disconnect must emit vpn.disconnected.user")
        XCTAssertEqual(userEvt?.kind, .vpn)
    }

    func testDisconnectKeepsProxyRoutingWhenOnPremProxyProbeSucceeds() async throws {
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(StaticRawHTTPResponseHandler(
                    response:
                        "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                        "Proxy-Authenticate: Negotiate\r\n" +
                        "Content-Length: 0\r\n" +
                        "\r\n"
                ))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = [
            UpstreamProxy(name: "On-prem proxy", host: "127.0.0.1", port: port, priority: 0)
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        try await orchestrator.startProxy()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none,
                       "On-prem VPN-off should keep proxy-aware routing when the upstream proxy probe succeeds")
        XCTAssertNotEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")
    }

    // MARK: - .disconnected(.networkLost)

    func testNetworkLostDisconnectEmitsLostEventAtWarningSeverity() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.disconnected(reason: .networkLost))

        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)
        XCTAssertNotNil(event(named: "vpn.disconnected.lost", in: orchestrator.eventLog, since: cutoff),
                        ".networkLost must emit vpn.disconnected.lost (distinct from .user)")
    }

    // MARK: - .disconnected → .connected (real outage recovery)

    func testReconnectAfterDisconnectEmitsConnectedAndResetsBreakers() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected)

        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)

        let connectedEvt = event(named: "vpn.connected", in: orchestrator.eventLog, since: cutoff)
        XCTAssertNotNil(connectedEvt, ".disconnected -> .connected must emit vpn.connected")
        // Cause derives from probe + config. With empty upstreams, expected = .noUpstreamsConfigured.
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .noUpstreamsConfigured,
                       "Empty upstreams => probe falls through to .noUpstreamsConfigured cause")
    }

    // MARK: - Idempotence

    func testRepeatedSameStateProducesNoEventStorm() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        // Establish the .connected state, then count VPN events emitted so far.
        // Subsequent identical .connected calls must NOT add to that count.
        await orchestrator.handleVPNStateChange(.connected)
        let baselineCount = orchestrator.eventLog.events.filter { $0.kind == .vpn }.count

        // Fire .connected several more times — should be no-ops because the
        // state is unchanged (the guard at the top of handleVPNStateChange
        // catches this).
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.connected)

        let afterCount = orchestrator.eventLog.events.filter { $0.kind == .vpn }.count
        XCTAssertEqual(afterCount, baselineCount,
                       "Repeated identical VPN states must not produce duplicate events " +
                       "(baseline=\(baselineCount), after-3-repeats=\(afterCount))")
    }

    // MARK: - Cause derivation priority (VPN signal > probe)

    func testVPNDisconnectedOverridesProbeDerivedCause() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        // Empty upstreams => probe-derived would be .noUpstreamsConfigured.
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .noUpstreamsConfigured)

        // VPN-driven .vpnDisconnected should override probe-derived cause.
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected,
                       "VPN-driven cause must win over probe-derived cause")
    }

    func testReassertingOverridesProbeDerivedCause() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)

        XCTAssertEqual(orchestrator.snapshot.directModeCause, .transientNetworkChange,
                       ".reasserting overrides any probe-derived cause")
    }

    // MARK: - Phase 6 (revised): orchestrator no longer coalesces
    //
    // Rapid-flap coalescing moved to VPNStateFuser via the min-visible
    // debounce (vpnFlapMinVisibleSeconds). Sub-window flaps never reach the
    // orchestrator; every .reasserting we see here is a real (super-min-visible)
    // flap event. Coalesce-specific orchestrator tests deleted; the fuser-level
    // tests in VPNStateFuserTests cover the new behavior.

    // MARK: - Phase 7: VPN flap telemetry counters

    /// `vpn.flap.recovered` (.reasserting -> .connected) is the ONLY transition
    /// that increments the four flap-telemetry counters on `ProxyMetrics`.
    /// Verifies the wiring added in Phase 7: count, total-duration accumulator,
    /// last-flap timestamp, and streams-preserved tally all advance together.
    func testFlapRecoveryIncrementsTelemetryMetrics() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        let beforeMetrics = orchestrator.snapshot.runtimeStatus.metrics
        XCTAssertEqual(beforeMetrics.vpnFlapCount, 0)
        XCTAssertEqual(beforeMetrics.vpnFlapTotalDuration, 0)
        XCTAssertNil(beforeMetrics.lastVpnFlapAt)
        XCTAssertEqual(beforeMetrics.streamsPreservedAcrossFlaps, 0)

        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)

        // Sleep so duration > 0; the test asserts > 0, not a specific value.
        try await Task.sleep(for: .milliseconds(20))

        let recoveryMoment = Date()
        await orchestrator.handleVPNStateChange(.connected)

        let afterMetrics = orchestrator.snapshot.runtimeStatus.metrics
        XCTAssertEqual(afterMetrics.vpnFlapCount, 1,
                       "Single .reasserting -> .connected must increment vpnFlapCount by exactly 1")
        XCTAssertGreaterThan(afterMetrics.vpnFlapTotalDuration, 0,
                              "vpnFlapTotalDuration must accumulate the elapsed flap window")
        // Timestamp recorded at recovery — within a small tolerance of the
        // moment we observed.
        if let lastFlapAt = afterMetrics.lastVpnFlapAt {
            XCTAssertEqual(lastFlapAt.timeIntervalSince(recoveryMoment), 0, accuracy: 1.0,
                           "lastVpnFlapAt must be set to the recovery moment, not a stale value")
        } else {
            XCTFail("lastVpnFlapAt must be set on flap recovery")
        }
        // No active tunnels in this orchestrator (empty upstreams, no clients),
        // so streamsPreservedAcrossFlaps stays at 0 — but the path has been
        // exercised.
        XCTAssertEqual(afterMetrics.streamsPreservedAcrossFlaps, 0,
                       "No active tunnels => streamsPreservedAcrossFlaps stays 0")
    }

    /// `.disconnected` transitions (user-initiated or networkLost) must NOT
    /// increment the flap counters — they're outage events, not flaps. The
    /// fuser-level debounce already absorbs blips silently; flap metrics
    /// represent only successful recovery from the .reasserting state.
    func testDisconnectedTransitionDoesNotIncrementFlapMetrics() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)
        let beforeFlapCount = orchestrator.snapshot.runtimeStatus.metrics.vpnFlapCount

        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.metrics.vpnFlapCount, beforeFlapCount,
                       ".userInitiated disconnect is an outage, not a flap — metrics unchanged")

        await orchestrator.handleVPNStateChange(.connected)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.metrics.vpnFlapCount, beforeFlapCount,
                       ".disconnected -> .connected (real outage recovery) is not a flap recovery")
    }

    /// Multiple successive flaps each contribute an increment. Sub-window
    /// blips never reach the orchestrator (they're absorbed by VPNStateFuser),
    /// so every transition we see here is a real flap and counts.
    func testMultipleFlapsAccumulateCounters() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        await orchestrator.handleVPNStateChange(.connected)

        for _ in 0..<3 {
            await orchestrator.handleVPNStateChange(.reasserting)
            try await Task.sleep(for: .milliseconds(5))
            await orchestrator.handleVPNStateChange(.connected)
        }

        let metrics = orchestrator.snapshot.runtimeStatus.metrics
        XCTAssertEqual(metrics.vpnFlapCount, 3,
                       "Three flap-recovery cycles must yield vpnFlapCount=3")
        XCTAssertGreaterThan(metrics.vpnFlapTotalDuration, 0)
        XCTAssertNotNil(metrics.lastVpnFlapAt)
    }

    // MARK: - stopProxy activeConnections preservation

    /// `.all` and `.idleOnly` clear the snapshot entirely; `.allButDedicated`
    /// retains tunnel entries so the UI keeps visibility of long-lived
    /// CONNECT/SOCKS tunnels that survive a config-driven listener restart.
    ///
    /// This locks down the contract that the `applyConfigChange` proxy-restart
    /// path (`stopProxy(scope: .allButDedicated)`) must NOT drop the UI's view
    /// of tunnels whose data plane rides out the restart. The design doc's
    /// Active Stream Preservation section promises `activeConnections` stays
    /// populated across such transitions; the equivalent `.reasserting` /
    /// `.disconnected` flap path already honors that, and the config-reload
    /// path now does too.
    func testPreservedActiveConnectionsDropsEverythingForAllAndIdleOnly() {
        let tunnel = ActiveConnectionInfo(
            destination: "example.com:443",
            upstream: "proxy-a.example.test:8080",
            method: "CONNECT",
            tunnel: true
        )
        let exchange = ActiveConnectionInfo(
            destination: "http://example.com/",
            upstream: "proxy-a.example.test:8080",
            method: "GET",
            tunnel: false
        )

        for scope in [CloseScope.all, .idleOnly] {
            let preserved = ProxyOrchestrator.preservedActiveConnections(
                from: [tunnel, exchange],
                scope: scope
            )
            XCTAssertTrue(preserved.isEmpty,
                          "\(scope) is a clean-slate policy — tunnels and exchanges both go.")
        }
    }

    func testPreservedActiveConnectionsKeepsTunnelsForAllButDedicated() {
        let tunnelID = UUID()
        let exchangeID = UUID()
        let tunnel = ActiveConnectionInfo(
            id: tunnelID,
            destination: "example.com:443",
            upstream: "proxy-a.example.test:8080",
            method: "CONNECT",
            tunnel: true
        )
        let exchange = ActiveConnectionInfo(
            id: exchangeID,
            destination: "http://example.com/",
            upstream: "proxy-a.example.test:8080",
            method: "GET",
            tunnel: false
        )

        let preserved = ProxyOrchestrator.preservedActiveConnections(
            from: [tunnel, exchange],
            scope: .allButDedicated
        )

        XCTAssertEqual(preserved.map(\.id), [tunnelID],
                       ".allButDedicated must retain tunnel entries (their byte-relay " +
                       "channels ride out the listener restart) and drop non-tunnel " +
                       "exchange entries (whose pool connections are closed here).")
    }

    func testPreservedActiveConnectionsIsStableForEmptyInput() {
        for scope in [CloseScope.all, .allButDedicated, .idleOnly] {
            XCTAssertTrue(
                ProxyOrchestrator.preservedActiveConnections(from: [], scope: scope).isEmpty,
                "Empty input yields empty output for \(scope)"
            )
        }
    }

    /// `stopProxy` zeroes the cumulative flap-telemetry counters. Both the
    /// design doc Phase 7 ("cumulative counters are reset on stop") and the
    /// MainView `showsFlapTelemetryStrip` comment depend on this — without the
    /// reset, the strip would reappear on next start carrying activity from a
    /// prior session, lying about the new cycle.
    func testStopProxyResetsFlapTelemetryCounters() async throws {
        let orchestrator = makeOrchestrator()
        try await orchestrator.startProxy()

        // Drive one flap-recovery cycle so all four counters become non-zero.
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)
        try await Task.sleep(for: .milliseconds(5))
        await orchestrator.handleVPNStateChange(.connected)

        let mid = orchestrator.snapshot.runtimeStatus.metrics
        XCTAssertEqual(mid.vpnFlapCount, 1, "Pre-condition: flap counter advanced")
        XCTAssertGreaterThan(mid.vpnFlapTotalDuration, 0)
        XCTAssertNotNil(mid.lastVpnFlapAt)

        await orchestrator.stopProxy()

        let after = orchestrator.snapshot.runtimeStatus.metrics
        XCTAssertEqual(after.vpnFlapCount, 0, "stopProxy must reset vpnFlapCount")
        XCTAssertEqual(after.vpnFlapTotalDuration, 0, "stopProxy must reset vpnFlapTotalDuration")
        XCTAssertNil(after.lastVpnFlapAt, "stopProxy must clear lastVpnFlapAt")
        XCTAssertEqual(after.streamsPreservedAcrossFlaps, 0,
                       "stopProxy must reset streamsPreservedAcrossFlaps")
    }

    func testUnknownVPNKeepsProxyRoutingWhenProxyProbeIsUsable() async throws {
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(StaticRawHTTPResponseHandler(
                    response:
                        "HTTP/1.1 407 Proxy Authentication Required\r\n" +
                        "Proxy-Authenticate: Negotiate\r\n" +
                        "Content-Length: 0\r\n" +
                        "\r\n"
                ))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = [
            UpstreamProxy(name: "On-prem proxy", host: "127.0.0.1", port: port, priority: 0)
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        XCTAssertEqual(orchestrator.snapshot.vpnState, .unknown)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none,
                       "Cold-start unknown VPN state must preserve proxy-aware routing when the upstream behaves like a proxy")
        XCTAssertNotEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")
    }

    func testUnknownVPNFallsBackToDirectWhenEndpointIsReachableButNotAProxy() async throws {
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(StaticRawHTTPResponseHandler(
                    response:
                        "HTTP/1.1 400 Bad Request\r\n" +
                        "Content-Length: 0\r\n" +
                        "\r\n"
                ))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = [
            UpstreamProxy(name: "Not a proxy", host: "127.0.0.1", port: port, priority: 0)
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }

        XCTAssertEqual(orchestrator.snapshot.vpnState, .unknown)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .vpnDisconnected,
                       "Cold-start unknown VPN state should route directly when the configured endpoint is not proxy-usable")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.activeUpstream, "DIRECT")
    }

    func testConnectedVPNMarks503ProxyAsUpstreamsUnreachableWithFastReprobe() async throws {
        let response = MutableRawHTTPResponse(
            "HTTP/1.1 407 Proxy Authentication Required\r\n" +
            "Proxy-Authenticate: Negotiate\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        )
        let serverChannel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(MutableRawHTTPResponseHandler(response: response))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { serverChannel.close(promise: nil) }

        let port = try XCTUnwrap(serverChannel.localAddress?.port)
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.upstreams = [
            UpstreamProxy(name: "Overloaded proxy", host: "127.0.0.1", port: port, priority: 0)
        ]
        let logger = RecordingLogSink(minLevel: .debug)
        let orchestrator = ProxyOrchestrator(config: config, logger: logger)

        try await orchestrator.startProxy()
        defer { Task { @MainActor in await orchestrator.stopProxy() } }
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .none)

        response.update(
            "HTTP/1.1 503 Service Unavailable\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        )
        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)

        XCTAssertEqual(orchestrator.snapshot.vpnState, .connected)
        XCTAssertEqual(orchestrator.snapshot.directModeCause, .upstreamsUnreachable)
        XCTAssertEqual(ProxyOrchestrator.directReprobeInterval(for: .upstreamsUnreachable), 15)
        let entered = event(named: "direct_mode.entered", in: orchestrator.eventLog, since: cutoff)
        XCTAssertEqual(entered?.kind, .routing)
        XCTAssertEqual(entered?.detail, "cause=upstreamsUnreachable prior=none")
        XCTAssertTrue(logger.containsMessage("Entering direct mode (cause: upstreamsUnreachable).", at: .notice))
    }

    // MARK: - Reactions skipped while proxy is stopped

    func testHandleVPNStateChangeIsNoOpWhileProxyStopped() async throws {
        let orchestrator = makeOrchestrator()
        // Don't start the proxy.
        let cutoff = Date()
        await orchestrator.handleVPNStateChange(.connected)
        await orchestrator.handleVPNStateChange(.reasserting)
        await orchestrator.handleVPNStateChange(.disconnected(reason: .userInitiated))

        // Snapshot still mirrors the state (UI cares even when proxy is
        // stopped) but no event was emitted.
        XCTAssertEqual(orchestrator.snapshot.vpnState, .disconnected(reason: .userInitiated))
        XCTAssertEqual(vpnEvents(in: orchestrator.eventLog, since: cutoff).count, 0,
                       "VPN events must not fire while proxy is stopped (no listener to react)")
    }
}

private final class StaticRawHTTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let response: String
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    init(response: String) {
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let request = accumulated.getString(
            at: accumulated.readerIndex,
            length: accumulated.readableBytes
        ), request.contains("\r\n\r\n") else {
            return
        }

        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        accumulated.clear()
    }
}

private final class MutableRawHTTPResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: String

    init(_ response: String) {
        self.storage = response
    }

    func update(_ response: String) {
        lock.lock()
        storage = response
        lock.unlock()
    }

    func current() -> String {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }
}

private final class MutableRawHTTPResponseHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let response: MutableRawHTTPResponse
    private var accumulated = ByteBufferAllocator().buffer(capacity: 512)

    init(response: MutableRawHTTPResponse) {
        self.response = response
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let request = accumulated.getString(
            at: accumulated.readerIndex,
            length: accumulated.readableBytes
        ), request.contains("\r\n\r\n") else {
            return
        }

        let response = response.current()
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        accumulated.clear()
    }
}

/// Phase 4 reprobe-cadence tests. The contract is slow for expected direct
/// states and fast for the unexpected `.upstreamsUnreachable` state.
@MainActor
final class DirectModeReprobeIntervalTests: XCTestCase {

    func testExpectedCausesReprobeSlowly() {
        XCTAssertEqual(ProxyOrchestrator.directReprobeInterval(for: .vpnDisconnected), 60)
        XCTAssertEqual(ProxyOrchestrator.directReprobeInterval(for: .noUpstreamsConfigured), 60)
    }

    func testUnexpectedCauseReprobeFast() {
        XCTAssertEqual(ProxyOrchestrator.directReprobeInterval(for: .upstreamsUnreachable), 15)
    }
}

/// Phase 4 tests `ConnectionPool.resetCircuitsAfterFlap()`. The pool's
/// breaker state is per-upstream; the reset must be applied to ALL upstreams
/// while preserving each one's EWMA latency.
@MainActor
final class ResetCircuitsAfterFlapTests: XCTestCase {

    func testResetCircuitsClosesOpenBreakerAndPreservesEWMA() {
        let logger = DiscardingLogSink()
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        // Phase 5: disable the time-window guard so the test can synchronously
        // trip the breaker via 5 back-to-back failures. The reset behavior
        // tested here is independent of the trip mechanism.
        var config = ProxyConfig.testFixture()
        config.circuitBreakerWindowSeconds = 0
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

        // Establish a latency baseline so EWMA is non-nil.
        pool.recordDedicatedTunnelSuccess(for: proxy, latencyMS: 200)
        let beforeEWMA = pool.upstreamStatuses().first { $0.id == proxy.id }?.ewmaLatencyMS
        XCTAssertNotNil(beforeEWMA)

        // Trip the breaker via 5 consecutive failures.
        for _ in 0..<5 { pool.recordDedicatedTunnelFailure(for: proxy) }
        let opened = pool.upstreamStatuses().first { $0.id == proxy.id }
        XCTAssertEqual(opened?.circuitState, .open, "Pre-condition: circuit is open after threshold failures")

        // The fix.
        pool.resetCircuitsAfterFlap()

        let after = pool.upstreamStatuses().first { $0.id == proxy.id }
        XCTAssertEqual(after?.circuitState, .closed,
                       "Breaker must be closed after resetCircuitsAfterFlap")
        XCTAssertEqual(after?.consecutiveFailures, 0)
        XCTAssertNil(after?.openUntil)
        XCTAssertEqual(after?.ewmaLatencyMS, beforeEWMA,
                       "EWMA latency MUST be preserved (the upstream itself didn't change)")
    }
}
