// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import ProxyKernel

/// Phase 7 of `docs/design-vpn-flap-resilience.md`: unit tests for the
/// pure mapping helpers that translate runtime VPN / direct-mode state
/// into the strings, colors, and derived numbers `MainView` puts on
/// screen. The data layer (`ProxyOrchestrator`, `ProxyMetrics`) has its
/// own dedicated tests; these cover the UI mapping in isolation so a
/// regression to the user-visible label set fails before we ship.
final class VPNStatusFormatterTests: XCTestCase {

    // MARK: - VPN state → label

    func testLabelCoversEveryVPNObservedStateBranch() {
        XCTAssertEqual(VPNStatusFormatter.label(for: .connected), "Connected")
        XCTAssertEqual(VPNStatusFormatter.label(for: .reasserting), "Reconnecting…")
        XCTAssertEqual(VPNStatusFormatter.label(for: .disconnected(reason: .userInitiated)),
                       "Disconnected (user)")
        XCTAssertEqual(VPNStatusFormatter.label(for: .disconnected(reason: .networkLost)),
                       "Disconnected (network lost)")
        XCTAssertEqual(VPNStatusFormatter.label(for: .disconnected(reason: .unknown)),
                       "Disconnected")
        XCTAssertEqual(VPNStatusFormatter.label(for: .unknown), "Not detected")
    }

    // MARK: - Active connections split

    func testActiveConnectionsLabelOmitsStalledSuffixWhenZero() {
        XCTAssertEqual(VPNStatusFormatter.activeConnectionsLabel(active: 0, stalled: 0),
                       "Active 0")
        XCTAssertEqual(VPNStatusFormatter.activeConnectionsLabel(active: 5, stalled: 0),
                       "Active 5")
    }

    func testActiveConnectionsLabelShowsStalledSuffixWhenPositive() {
        XCTAssertEqual(VPNStatusFormatter.activeConnectionsLabel(active: 5, stalled: 3),
                       "Active 5 (3 stalled)")
        XCTAssertEqual(VPNStatusFormatter.activeConnectionsLabel(active: 1, stalled: 1),
                       "Active 1 (1 stalled)")
    }

    // MARK: - Stalled tunnel count

    func testStalledTunnelCountIsZeroWhenVPNIsConnected() {
        XCTAssertEqual(
            VPNStatusFormatter.stalledTunnelCount(vpnState: .connected,
                                                  activeTunnelCount: 7),
            0,
            "Active CONNECT tunnels are not 'stalled' while the VPN is up."
        )
    }

    func testStalledTunnelCountIsZeroWhenVPNStateIsUnknown() {
        XCTAssertEqual(
            VPNStatusFormatter.stalledTunnelCount(vpnState: .unknown,
                                                  activeTunnelCount: 7),
            0,
            "We don't surface 'stalled' for the .unknown observer state — the " +
            "label would be misleading when we don't actually know the VPN " +
            "is down."
        )
    }

    func testStalledTunnelCountReflectsActiveCountWhenReasserting() {
        XCTAssertEqual(
            VPNStatusFormatter.stalledTunnelCount(vpnState: .reasserting,
                                                  activeTunnelCount: 3),
            3
        )
    }

    func testStalledTunnelCountIsZeroWhenDisconnected() {
        XCTAssertEqual(
            VPNStatusFormatter.stalledTunnelCount(vpnState: .disconnected(reason: .networkLost),
                                                  activeTunnelCount: 2),
            0
        )
        XCTAssertEqual(
            VPNStatusFormatter.stalledTunnelCount(vpnState: .disconnected(reason: .userInitiated),
                                                  activeTunnelCount: 1),
            0
        )
    }

    // MARK: - Probes/min cadence derivation

    func testProbesPerMinuteIsZeroWhenNotInDirectMode() {
        XCTAssertEqual(VPNStatusFormatter.probesPerMinute(for: .none), 0)
    }

    func testProbesPerMinuteIsFourWhenUpstreamsUnreachable() {
        XCTAssertEqual(
            VPNStatusFormatter.probesPerMinute(for: .upstreamsUnreachable),
            4,
            "Unexpected direct mode runs the 15s reprobe cadence → 4/min."
        )
    }

    func testProbesPerMinuteIsOneForTimedExpectedDirectModeCauses() {
        XCTAssertEqual(VPNStatusFormatter.probesPerMinute(for: .vpnDisconnected), 1)
        XCTAssertEqual(VPNStatusFormatter.probesPerMinute(for: .noUpstreamsConfigured), 1)
    }

    func testProbesPerMinuteIsZeroForSilentGraceState() {
        // `.transientNetworkChange` is the `.reasserting` grace window.
        // `ProxyOrchestrator.handleVPNStateChange(.reasserting)` explicitly
        // does NOT call `startDirectModeReprobeTimer()`; the system is
        // waiting for the VPN observer, not probing upstreams. The chip
        // must say 0, not 1 — otherwise it contradicts the "Reconnecting…"
        // label rendered in the same strip.
        XCTAssertEqual(VPNStatusFormatter.probesPerMinute(for: .transientNetworkChange), 0)
    }

    // MARK: - Flaps tooltip

    func testFlapsTooltipReturnsNilInZeroState() {
        XCTAssertNil(VPNStatusFormatter.flapsTooltip(
            count: 0, totalDuration: 0, lastFlapAt: nil
        ))
    }

    func testFlapsTooltipPluralizesCount() {
        let single = VPNStatusFormatter.flapsTooltip(
            count: 1, totalDuration: 0.5, lastFlapAt: nil
        )
        XCTAssertNotNil(single)
        XCTAssertTrue(single!.hasPrefix("1 user-visible VPN flap "),
                      "Expected singular phrasing, got: \(single!)")

        let many = VPNStatusFormatter.flapsTooltip(
            count: 7, totalDuration: 12.34, lastFlapAt: nil
        )
        XCTAssertNotNil(many)
        XCTAssertTrue(many!.hasPrefix("7 user-visible VPN flaps "),
                      "Expected plural phrasing, got: \(many!)")
    }

    func testFlapsTooltipFormatsTotalDurationWithOneDecimal() {
        let tooltip = VPNStatusFormatter.flapsTooltip(
            count: 3, totalDuration: 12.345, lastFlapAt: nil
        )
        XCTAssertNotNil(tooltip)
        XCTAssertTrue(tooltip!.contains("12.3s total"),
                      "Total duration should round to one decimal; got: \(tooltip!)")
    }

    func testFlapsTooltipIncludesRelativeLastFlapWhenDateProvided() {
        let now = Date()
        let twoMinutesAgo = now.addingTimeInterval(-120)
        let tooltip = VPNStatusFormatter.flapsTooltip(
            count: 5, totalDuration: 8.0, lastFlapAt: twoMinutesAgo, now: now
        )
        XCTAssertNotNil(tooltip)
        XCTAssertTrue(tooltip!.contains(" last "),
                      "Tooltip should embed the relative-time phrase; got: \(tooltip!)")
        XCTAssertTrue(tooltip!.contains("8.0s total"))
    }

    func testFlapsTooltipOmitsLastFlapWhenDateIsNil() {
        let tooltip = VPNStatusFormatter.flapsTooltip(
            count: 2, totalDuration: 1.5, lastFlapAt: nil
        )
        XCTAssertNotNil(tooltip)
        XCTAssertFalse(tooltip!.contains(" last "),
                       "Tooltip must not invent a 'last flap' phrase when the " +
                       "date is nil; got: \(tooltip!)")
    }
}
