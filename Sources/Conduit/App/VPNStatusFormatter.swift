// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel
import SwiftUI

/// Phase 7 of `docs/design-vpn-flap-resilience.md`: pure mapping helpers that
/// translate runtime VPN / direct-mode state into the strings, colors, and
/// derived numbers `MainView` puts on screen.
///
/// Lives outside `MainView` for two reasons:
///
/// - **Testability.** SwiftUI computed properties are awkward to drive from
///   XCTest without standing up a view tree; static methods on a namespace
///   enum are trivially testable. The data layer (`ProxyOrchestrator`,
///   `ProxyMetrics`) is exhaustively tested; the UI mapping deserves the
///   same treatment.
/// - **Single source of truth.** If we ever surface the same flap telemetry
///   in a menu-bar popover or the floating window, the mapping should be
///   shared, not copy-pasted.
enum VPNStatusFormatter {

    // MARK: - VPN state → label / color

    /// Per-reason VPN status label. Replaces the bare `"Connected"` /
    /// `"Disconnected"` rendering so users can distinguish "I clicked
    /// Disconnect" from "the network just dropped" without opening the log
    /// viewer.
    static func label(for state: VPNObservedState) -> String {
        switch state {
        case .connected:
            return "Connected"
        case .reasserting:
            return "Reconnecting…"
        case .disconnected(.userInitiated):
            return "Disconnected (user)"
        case .disconnected(.networkLost):
            return "Disconnected (network lost)"
        case .disconnected(.unknown):
            return "Disconnected"
        case .unknown:
            return "Not detected"
        }
    }

    /// Color hint for the VPN status row. `.reasserting` is amber to flag
    /// the transient state; an outright disconnect is `.secondary` because
    /// it isn't an error — the proxy works fine in direct mode.
    static func color(for state: VPNObservedState) -> Color {
        switch state {
        case .connected: return .primary
        case .reasserting: return Color(nsColor: .systemOrange)
        case .disconnected, .unknown: return .secondary
        }
    }

    // MARK: - Active connections split

    /// Render `Active 5 (3 stalled)` when there are stalled tunnels;
    /// otherwise `Active 5`. The `(N stalled)` suffix is meaningful only
    /// when `stalled > 0`.
    static func activeConnectionsLabel(active: Int, stalled: Int) -> String {
        if stalled > 0 {
            return "Active \(active) (\(stalled) stalled)"
        }
        return "Active \(active)"
    }

    /// "Stalled" tunnels = active CONNECT tunnels held alive by kernel
    /// keepalive during the short `.reasserting` VPN flap window. Once the
    /// app has settled into an intentional direct-mode state, active tunnels
    /// are just active; calling them stalled makes expected direct mode look
    /// broken.
    ///
    /// Pass `activeTunnelCount` already filtered for `tunnel == true`;
    /// this helper only decides whether to surface it.
    static func stalledTunnelCount(vpnState: VPNObservedState,
                                   activeTunnelCount: Int) -> Int {
        switch vpnState {
        case .reasserting:
            return activeTunnelCount
        case .connected, .disconnected, .unknown:
            return 0
        }
    }

    // MARK: - Probes/min derivation

    /// Approximate "probes per minute" derived from the direct-mode reprobe
    /// cadence the orchestrator actually runs:
    ///
    /// - `.upstreamsUnreachable` → 15 s cadence → 4/min
    /// - `.vpnDisconnected`, `.noUpstreamsConfigured` → 60 s cadence → 1/min
    /// - `.transientNetworkChange` → silent grace window, no timer armed → 0/min
    /// - `.none` → not in direct mode, no probing → 0/min
    ///
    /// `.transientNetworkChange` is the silent grace state during a VPN flap:
    /// `ProxyOrchestrator.handleVPNStateChange(.reasserting)` explicitly does
    /// not call `startDirectModeReprobeTimer()` — the design is to wait for
    /// the VPN observer to fire `.connected` or for the grace window to
    /// expire into `.disconnected`, not to probe upstreams. The chip must
    /// mirror that or it contradicts the "Reconnecting…" label next to it.
    ///
    /// We don't surface a true windowed rate counter (would require its own
    /// state machine); the cadence-derived value reflects the timer the
    /// orchestrator has actually armed for each cause.
    static func probesPerMinute(for cause: DirectModeCause) -> Int {
        switch cause {
        case .none, .transientNetworkChange:
            return 0
        case .upstreamsUnreachable:
            return 4
        case .vpnDisconnected, .noUpstreamsConfigured:
            return 1
        }
    }

    // MARK: - Flaps chip tooltip

    /// One-line summary of the cumulative flap counters. Surfaces
    /// `lastVpnFlapAt` and `vpnFlapTotalDuration`, which otherwise live
    /// only in the NDJSON status stream — putting them in a hover tooltip
    /// keeps the strip uncluttered while still using the data we collect.
    ///
    /// Returns `nil` when there's nothing to show (e.g. zero-state).
    ///
    /// `relativeFormatter` is injected for deterministic tests; production
    /// callers pass `nil` and the helper constructs a fresh formatter
    /// per call. (Per-call cost is microseconds; we avoid a MainActor-
    /// pinned static or a non-Sendable static the compiler would reject.)
    static func flapsTooltip(count: Int,
                             totalDuration: TimeInterval,
                             lastFlapAt: Date?,
                             now: Date = Date(),
                             relativeFormatter: RelativeDateTimeFormatter? = nil)
        -> String? {
        guard count > 0 else { return nil }

        let label = count == 1 ? "1 user-visible VPN flap" : "\(count) user-visible VPN flaps"

        let totalSeconds = String(format: "%.1f", totalDuration)
        let totalPiece = "\(totalSeconds)s total"

        if let lastFlapAt {
            let formatter = relativeFormatter ?? makeRelativeFormatter()
            let relative = formatter.localizedString(for: lastFlapAt, relativeTo: now)
            return "\(label) · last \(relative) · \(totalPiece)"
        }
        return "\(label) · \(totalPiece)"
    }

    private static func makeRelativeFormatter() -> RelativeDateTimeFormatter {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f
    }
}
