// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Why the proxy is currently in a direct/degraded connectivity state, or
/// `.none` when upstream routing is healthy.
///
/// The cause distinguishes unconditional direct routing (user intentionally
/// off-VPN, no upstreams configured) from VPN-connected degraded states
/// (transient network change, upstream probes failed). The orchestrator uses this
/// to decide request routing, log severity, error-rate alarm gating, reprobe
/// cadence, and the user-visible health summary string.
///
/// See `docs/design-vpn-flap-resilience.md`.
package enum DirectModeCause: String, Sendable, Equatable, Codable {
    /// Not in direct mode — requests route via the upstream pool normally.
    case none

    /// Grace-window state during a network path change. Fully silent: no logs,
    /// no error-rate alarm, no reprobe. Set by Phase 4 (`VPNObservedState.reasserting`).
    case transientNetworkChange

    /// User intentionally disconnected the VPN (or VPN dropped out of band).
    /// Expected: silent direct mode. Set by Phase 4 from
    /// `VPNObservedState.disconnected(.userInitiated | .networkLost)`.
    case vpnDisconnected

    /// Configuration has zero enabled upstream proxies. Expected: silent direct mode.
    /// Detected synchronously when `ProxyConfig.enabledUpstreams.isEmpty`.
    case noUpstreamsConfigured

    /// Upstreams are configured and the VPN appears up, but every upstream probe
    /// failed. Unexpected: keep the loud current behavior (`.error` logs on direct
    /// failures, error-rate warnings, fast reprobe cadence). This is the only cause
    /// that signals a real problem.
    case upstreamsUnreachable
}

extension DirectModeCause {
    /// Whether the orchestrator considers itself in a direct/degraded connectivity state.
    /// Provided so the `(Bool, DirectModeCause)` tuple consumed by `directModeProvider`
    /// stays consistent with the cause.
    package var isDirect: Bool {
        switch self {
        case .none: return false
        case .transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured, .upstreamsUnreachable:
            return true
        }
    }

    /// Whether new client requests should route directly while this cause is active.
    ///
    /// This is intentionally narrower than `isDirect`: VPN-connected failure
    /// states still keep request routing on the PAC/upstream path so strict
    /// corporate profiles do not bypass split-DNS or upstream proxy policy.
    package var routesClientTrafficDirectly: Bool {
        allowsUnconditionalDirectRouting
    }

    /// Whether the local PAC should advertise a DIRECT-only decision to browsers.
    ///
    /// Chromium-based browsers may resolve DIRECT targets with their own DNS
    /// stack. While VPN is connected or reasserting, keep those clients pointed
    /// at Conduit so the process uses macOS/VPN DNS even if the proxy is
    /// internally relaying directly.
    package var advertisesDirectOnlyPAC: Bool {
        routesClientTrafficDirectly
    }

    /// Whether normal upstream health checks should run while this cause is active.
    ///
    /// `.upstreamsUnreachable` is degraded-but-still-upstream-routed, so the
    /// health loop must keep running to detect recovery. Explicit direct states
    /// and transient VPN reassertion keep the health checker quiet.
    package var runsUpstreamHealthLoop: Bool {
        switch self {
        case .none, .upstreamsUnreachable:
            return true
        case .transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured:
            return false
        }
    }

    /// Whether the direct/degraded reprobe timer should run.
    package var usesDirectReprobeTimer: Bool {
        switch self {
        case .vpnDisconnected, .noUpstreamsConfigured, .upstreamsUnreachable:
            return true
        case .none, .transientNetworkChange:
            return false
        }
    }

    /// Whether a normal-mode PAC chain may fall back to DIRECT after an upstream
    /// attempt fails.
    ///
    /// Strict corporate VPN mode suppresses PAC's browser-style DIRECT fallback
    /// while the proxy is otherwise in normal upstream-routing mode.
    package var allowsUnconditionalDirectRouting: Bool {
        switch self {
        case .vpnDisconnected, .noUpstreamsConfigured:
            return true
        case .none, .transientNetworkChange, .upstreamsUnreachable:
            return false
        }
    }

    /// Whether this cause is *expected* (user intent, configuration absence, transient
    /// path change) versus *unexpected* (something went wrong despite VPN being up).
    /// Used to gate log severity, error-rate alarms, and reprobe cadence.
    package var isExpected: Bool {
        switch self {
        case .none, .upstreamsUnreachable: return false
        case .transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured: return true
        }
    }

    /// User-visible health summary string. Mapping from the design doc:
    /// `docs/design-vpn-flap-resilience.md` § "lastHealthSummary strings derive from cause".
    package var healthSummary: String {
        switch self {
        case .none: return ""  // .none uses the upstream-derived summary, not this string
        case .transientNetworkChange: return "Network changing…"
        case .vpnDisconnected: return "Direct (VPN off)"
        case .noUpstreamsConfigured: return "Direct (no upstreams configured)"
        case .upstreamsUnreachable: return "⚠ Upstreams unreachable"
        }
    }
}
