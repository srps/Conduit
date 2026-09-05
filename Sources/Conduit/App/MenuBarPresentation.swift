// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Pure presentation / decision helpers for the menu-bar-first control
/// surface. Keeping these outside `StatusBarView` and `AppState` gives us
/// cheap unit coverage for the user-visible labels, the status-item glyph,
/// and the restart-state decisions without launching SwiftUI or constructing
/// the full `AppState` runtime.
package enum MenuBarPresentation {

    // MARK: - Status item glyph

    /// The menu bar image is template-rendered, so colour cannot carry state
    /// and the shape has to. Four glyphs cover every `ProxyConnectionState`
    /// plus direct mode:
    ///
    /// - stopped → `network.slash`
    /// - direct (VPN off, no upstreams, path changing) → `network`
    /// - proxied → `network.badge.shield.half.filled`
    /// - needs attention (degraded, recovering, failed, upstreams unreachable)
    ///   → `exclamationmark.triangle`
    ///
    /// Starting shares the glyph of the state it is heading for; the popover
    /// spells out the transition. A menu bar icon that animates is noise.
    package static func menuBarSymbol(state: ProxyConnectionState, directModeCause: DirectModeCause) -> String {
        switch state {
        case .stopped:
            return "network.slash"
        case .failed, .degraded, .recovering:
            return "exclamationmark.triangle"
        case .starting, .running:
            switch directModeCause {
            case .none:
                return "network.badge.shield.half.filled"
            case .vpnDisconnected, .noUpstreamsConfigured, .transientNetworkChange:
                return "network"
            case .upstreamsUnreachable:
                return "exclamationmark.triangle"
            }
        }
    }

    // MARK: - State line

    /// The one sentence in the popover header. It merges the old title,
    /// subtitle, badge, and mode chips into the way the user thinks about
    /// the proxy: "proxied via X", "direct, VPN off", "stopped", "failed:
    /// port in use".
    package static func stateLine(
        state: ProxyConnectionState,
        directModeCause: DirectModeCause,
        activeUpstream: String?,
        proxyError: String?
    ) -> String {
        switch state {
        case .stopped:
            return "Stopped"
        case .starting:
            return "Starting…"
        case .failed:
            if let proxyError, !proxyError.isEmpty {
                return "Failed: \(proxyError)"
            }
            return "Failed"
        case .running, .degraded, .recovering:
            if directModeCause.isDirect {
                return directLine(for: directModeCause)
            }
            let via = activeUpstream.map { " via \($0)" } ?? ""
            switch state {
            case .degraded: return "Degraded\(via)"
            case .recovering: return "Recovering\(via)"
            default: return "Proxied\(via)"
            }
        }
    }

    private static func directLine(for cause: DirectModeCause) -> String {
        switch cause {
        case .vpnDisconnected: return "Direct, VPN off"
        case .noUpstreamsConfigured: return "Direct, no upstreams configured"
        case .transientNetworkChange: return "Direct, network changing"
        case .upstreamsUnreachable: return "Direct, upstreams unreachable"
        case .none: return "Direct"
        }
    }

    /// The line under the state line. An app-level error wins because it is
    /// the thing the user has to act on; otherwise the health summary, the
    /// VPN state, and the uptime are joined with middle dots. Empty parts are
    /// dropped so a stopped proxy reads "VPN connected" rather than
    /// " · VPN connected · ".
    package static func stateDetail(
        lastError: String?,
        healthSummary: String,
        vpnLabel: String,
        uptime: String?
    ) -> String {
        if let lastError, !lastError.isEmpty {
            return lastError
        }
        var parts: [String] = []
        if !healthSummary.isEmpty { parts.append(healthSummary) }
        if !vpnLabel.isEmpty { parts.append("VPN \(lowercasedFirst(vpnLabel))") }
        if let uptime, !uptime.isEmpty { parts.append("\(uptime) up") }
        return parts.joined(separator: " · ")
    }

    private static func lowercasedFirst(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.lowercased() + value.dropFirst()
    }

    /// The popover shows the active upstream as a row and everything else as
    /// one line of counts: only one upstream should be carrying traffic, the
    /// rest are checked fallbacks that matter in aggregate until one is
    /// needed. "4 fallbacks · 3 healthy · 1 open"; nil when there is nothing
    /// to summarise.
    package static func upstreamSummaryLine(closed: Int, halfOpen: Int, open: Int, activeShown: Bool) -> String? {
        let total = closed + halfOpen + open
        guard total > 0 else { return nil }
        let noun = activeShown ? "fallback" : "upstream"
        var parts = ["\(total) \(noun)\(total == 1 ? "" : "s")"]
        if closed > 0 { parts.append("\(closed) healthy") }
        if halfOpen > 0 { parts.append("\(halfOpen) probing") }
        if open > 0 { parts.append("\(open) open") }
        return parts.joined(separator: " · ")
    }

    /// `activeUpstream` is an endpoint ("host:port" or "DIRECT"); the user
    /// named the upstream, so show the name when the runtime knows it.
    package static func displayName(forActiveUpstream endpoint: String?, statuses: [UpstreamRuntimeStatus]) -> String? {
        guard let endpoint else { return nil }
        if let match = statuses.first(where: { $0.endpoint == endpoint }), !match.name.isEmpty {
            return match.name
        }
        return endpoint
    }

    /// "1.2k requests · 3 errors · 4 active" — the popover's single activity
    /// line, replacing three metric cards.
    package static func activityLine(requests: Int, errors: Int, active: Int) -> String {
        "\(compactCount(requests)) requests · \(compactCount(errors)) errors · \(compactCount(active)) active"
    }

    // MARK: - Switches

    /// A switch shows the state and is the control, so "on" has to mean
    /// "the user asked for it to run". Starting counts as on: the switch was
    /// just flipped and the subtitle says "Starting…".
    package static func proxySwitchIsOn(for state: ProxyConnectionState) -> Bool {
        switch state {
        case .running, .degraded, .recovering, .starting:
            return true
        case .stopped, .failed:
            return false
        }
    }

    /// The switch is disabled only while a transition is in flight.
    package static func proxySwitchIsEnabled(for state: ProxyConnectionState) -> Bool {
        state != .starting
    }

    package static func moduleSwitchIsOn(for state: ModuleRunState) -> Bool {
        switch state {
        case .running, .warning, .starting:
            return true
        case .stopped, .failed:
            return false
        }
    }

    package static func moduleSwitchIsEnabled(for state: ModuleRunState) -> Bool {
        state != .starting
    }

    /// What flipping a module's switch does. `.warning` is running with an
    /// error attached (partial tunnel bind, DNS health probe failing), so
    /// the switch shows on and flipping it must stop, not start a second
    /// set of listeners on top of the first. The lifecycle toggles in
    /// `AppState` decide through this so the switch and the action agree.
    package enum ModuleToggleAction: Equatable {
        case start
        case stop
        case none
    }

    package static func moduleToggleAction(for state: ModuleRunState) -> ModuleToggleAction {
        switch state {
        case .running, .warning:
            return .stop
        case .starting:
            return .none
        case .stopped, .failed:
            return .start
        }
    }

    // MARK: - Restart

    /// Restart is useful for running/degraded/recovering/failed runtimes. It
    /// is disabled while starting (already in transition) and while stopped
    /// (there is nothing to restart; the switch is the correct affordance).
    package static func canRestartProxy(for state: ProxyConnectionState) -> Bool {
        switch state {
        case .running, .degraded, .recovering, .failed:
            return true
        case .starting, .stopped:
            return false
        }
    }

    /// Whether restart should call the stop path before calling start. A failed
    /// runtime still gets stopped first so stale listeners, errors, and
    /// platform side effects are cleared before the new start attempt.
    package static func shouldStopBeforeRestart(for state: ProxyConnectionState) -> Bool {
        switch state {
        case .running, .degraded, .recovering, .failed:
            return true
        case .starting, .stopped:
            return false
        }
    }

    // MARK: - Formatting

    package static func endpoint(host: String?, port: Int?) -> String {
        guard let host, let port else { return "-" }
        return "\(host):\(port)"
    }

    /// Compact display form for long-running counters: a daily-driver daemon
    /// accumulates six-to-seven-digit request counts that overflow the
    /// metric cards. Below 1 000 the exact value shows; above, k/M/B units
    /// with one decimal while the leading part is a single digit ("1.2k",
    /// "12k", "999k", "1.2M"). Exact values stay available in the copyable
    /// diagnostics block.
    package static func compactCount(_ value: Int) -> String {
        let magnitude = abs(value)
        guard magnitude >= 1_000 else { return "\(value)" }

        let units: [(threshold: Double, suffix: String)] = [
            (1_000_000_000, "B"),
            (1_000_000, "M"),
            (1_000, "k"),
        ]
        for unit in units where Double(magnitude) >= unit.threshold {
            // Truncate (not round) so "999 950" shows as "999k", never the
            // misleading "1000k" or an early "1M".
            let scaled = Double(magnitude) / unit.threshold
            let truncated = (scaled * 10).rounded(.down) / 10
            let sign = value < 0 ? "-" : ""
            if truncated < 10, truncated != truncated.rounded(.down) {
                return "\(sign)\(String(format: "%.1f", truncated))\(unit.suffix)"
            }
            return "\(sign)\(Int(truncated.rounded(.down)))\(unit.suffix)"
        }
        return "\(value)"
    }

    /// Hours and minutes since the proxy started, or nil when it is not
    /// running. Extracted so the popover subtitle and the Overview card agree.
    package static func uptime(since startedAt: Date?, now: Date = .now) -> String? {
        guard let startedAt else { return nil }
        return uptimeFormatter.string(from: startedAt, to: now)
    }

    private static let uptimeFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.hour, .minute]
        formatter.unitsStyle = .abbreviated
        return formatter
    }()

    // MARK: - Diagnostics block

    package static func statusSummary(
        state: ProxyConnectionState,
        activeUpstream: String?,
        healthSummary: String,
        proxyEndpoint: String,
        dnsEndpoint: String,
        socksEndpoint: String,
        requestsHandled: Int,
        failedRequests: Int,
        activeConnectionCount: Int,
        directModeCause: DirectModeCause,
        vpnLabel: String
    ) -> String {
        """
        Conduit
        State: \(state.title)
        Active upstream: \(activeUpstream ?? "-")
        Health: \(healthSummary)
        HTTP: \(proxyEndpoint)
        DNS: \(dnsEndpoint)
        SOCKS: \(socksEndpoint)
        Requests: \(requestsHandled)
        Errors: \(failedRequests)
        Active connections: \(activeConnectionCount)
        Direct mode: \(directModeCause.rawValue)
        VPN: \(vpnLabel)
        """
    }
}
