// SPDX-License-Identifier: Apache-2.0
import Foundation

/// What the VPN-state-observation layer (Tier B utun observer + Tier C NWPathMonitor
/// fallback) currently believes about the VPN. Single source of truth consumed by
/// `ProxyOrchestrator.handleVPNStateChange(_:)`. See `docs/design-vpn-flap-resilience.md`.
///
/// The orchestrator's transition table (Phase 4) maps these values to `DirectModeCause`
/// and the resulting routing/log decisions. This type itself encodes only the
/// *observation* — what we see — not the *reaction* — what we do about it.
package enum VPNObservedState: Sendable, Equatable, Codable {
    /// Bootstrap state. Observers haven't reported anything yet, or have reported
    /// data that doesn't yet add up to a definitive answer (e.g. process just
    /// started, no utun seen, NWPathMonitor hasn't fired).
    case unknown

    /// At least one utun interface has Link active and an IPv4 address assigned.
    /// VPN is considered up for routing purposes.
    case connected

    /// A previously-connected utun dropped its Link (or removed its IPv4 address)
    /// and we're inside the configurable grace window waiting to see if it recovers.
    /// Phase 4 maps this to `DirectModeCause.transientNetworkChange` — fully silent;
    /// active streams ride out the flap via TCP keepalive.
    case reasserting

    /// VPN is definitively down. The reason informs the orchestrator's response:
    /// user-initiated → fast-path direct mode immediately; networkLost → same but
    /// log at .warning; unknown → tier-C-fallback case where we couldn't observe
    /// utun directly (rare; modern VPNs all show up as utun).
    case disconnected(reason: VPNDisconnectReason)
}

/// Why we transitioned into `.disconnected`. Drives log severity and snapshot
/// `DirectModeCause` (Phase 4 transition table).
package enum VPNDisconnectReason: Sendable, Equatable, Codable {
    /// The utun interface was *removed* from the SCDynamicStore — i.e. the VPN
    /// client deallocated it (user clicked Disconnect, or it tore down for any
    /// other intentional reason). Unambiguous: act fast.
    case userInitiated

    /// The utun interface stayed present but Link was inactive past the grace
    /// window. Network failure, unsupported handoff, or a long flap. Logged at
    /// `.warning` because something genuinely went wrong, but the user response
    /// is the same as `.userInitiated`: switch to direct mode.
    case networkLost

    /// Tier C fallback only. We never saw a utun interface and `NWPathMonitor`
    /// reports no `.other` interface (the heuristic we used pre-Tier-B).
    /// Indistinguishable from "no VPN configured at all" — treat as disconnected
    /// but don't infer user intent.
    case unknown
}

extension VPNObservedState {
    /// `true` iff the VPN is up enough for routing-via-upstream to be expected
    /// to work. False during reasserting (we're hopeful but the kernel is
    /// dropping packets) and disconnected (definitely down).
    package var isConnected: Bool {
        switch self {
        case .connected: return true
        case .unknown, .reasserting, .disconnected: return false
        }
    }

    /// `true` iff this state should trigger silent control-plane behavior. During
    /// `.reasserting`, do not flip direct-mode for new requests yet — the kernel
    /// may resume delivery within seconds and active streams must not be torn down.
    package var isReasserting: Bool {
        if case .reasserting = self { return true }
        return false
    }
}
