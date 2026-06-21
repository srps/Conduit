// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Pure presentation / decision helpers for the menu-bar-first control
/// surface. Keeping these outside `StatusBarView` and `AppState` gives us
/// cheap unit coverage for the user-visible labels and restart-state
/// decisions without launching SwiftUI or constructing the full `AppState`
/// runtime.
package enum MenuBarPresentation {
    package static func proxyButtonTitle(for state: ProxyConnectionState) -> String {
        switch state {
        case .running, .degraded, .recovering:
            return "Stop Proxy"
        case .starting:
            return "Starting..."
        case .stopped, .failed:
            return "Start Proxy"
        }
    }

    /// Restart is useful for running/degraded/recovering/failed runtimes. It
    /// is disabled while starting (already in transition) and while stopped
    /// (there is nothing to restart; Start Proxy is the correct affordance).
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

    package static func endpoint(host: String?, port: Int?) -> String {
        guard let host, let port else { return "-" }
        return "\(host):\(port)"
    }

    /// Compact display form for long-running counters: a daily-driver daemon
    /// accumulates six-to-seven-digit request counts that overflow the
    /// metric cards. Below 1 000 the exact value shows; above, k/M/B units
    /// with one decimal while the leading part is a single digit ("1.2k",
    /// "12k", "999k", "1.2M"). Exact values stay available in the copyable
    /// status summary.
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

    package static func statusSubtitle(
        state: ProxyConnectionState,
        proxyError: String?,
        lastError: String?,
        directMode: Bool,
        directModeCause: DirectModeCause,
        healthSummary: String
    ) -> String {
        if let error = proxyError ?? lastError {
            return error
        }
        if directMode {
            return directModeCause.healthSummary
        }
        return healthSummary.isEmpty ? "Menu-bar controller active" : healthSummary
    }

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
