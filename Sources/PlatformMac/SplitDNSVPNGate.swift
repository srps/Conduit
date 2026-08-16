// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Single source of truth for the VPN-gating policy on split-DNS entry
/// files, shared by `AppState` (GUI host) and `DaemonRuntimeHost` (daemon
/// host) so the two cannot drift apart. Each host owns one instance, feeds
/// it VPN monitor states, and consults `entriesWanted` on every
/// resolver-file apply path; how and when to act on a flip (run-state
/// guards, isolation) stays host-specific.
///
/// Why the gate exists: split-DNS entry files (`/etc/resolver/<domain>` →
/// corporate DNS servers) point at tunnel-internal servers, and the
/// override applies to *everything* matching the domain — including the VPN
/// gateway's own public hostname when it falls under a managed domain.
/// With the VPN down the override blackholes those lookups, so the VPN
/// client cannot resolve its gateway to reconnect: a bootstrap deadlock
/// only a file removal breaks. Entry files must therefore exist only while
/// the tunnel that makes their servers reachable is up.
package struct SplitDNSVPNGate: Sendable {
    /// Last state emitted by the VPN monitor.
    package private(set) var lastVPNState: VPNObservedState = .unknown

    package init() {}

    /// Entry files are withheld only when the VPN is *definitively* down.
    /// `.unknown` (monitor hasn't primed yet) and `.reasserting` (flap grace
    /// window) keep them: wrongly removing files during a flap churns
    /// resolver state, while wrongly keeping them is self-correcting — the
    /// fuser settles to `.disconnected` within the grace window and the
    /// transition handler removes them then.
    ///
    /// That self-correction depends on the monitor eventually reaching a
    /// verdict, which it does *only* because `primeInitialState` reports an
    /// empty utun sweep as `.disconnected` via `markNoTunnelsPresent`. Without
    /// that, launching with the VPN already down parked the state in
    /// `.unknown` forever — no utun ever transitioned, so nothing emitted —
    /// and these files stayed installed against unreachable servers. If you
    /// weaken the priming path, this `.unknown` default becomes fail-deadly.
    package var entriesWanted: Bool {
        if case .disconnected = lastVPNState { return false }
        return true
    }

    /// Records a new VPN state. Returns `true` when the wanted-state
    /// flipped, i.e. the host should apply or clear the entry files
    /// (subject to its own run-state guards) via `reconcileEntryFiles`.
    package mutating func update(_ state: VPNObservedState) -> Bool {
        let wantedBefore = entriesWanted
        lastVPNState = state
        return wantedBefore != entriesWanted
    }

    /// What a host should do to the entry files right now.
    package enum EntryFileAction: Equatable, Sendable {
        case apply
        case remove
        case nothing
    }

    /// The gating policy, as a pure function of what the VPN state wants and
    /// whether the proxy runtime is up.
    ///
    /// The asymmetry is the point. *Writing* entry files is gated on a running
    /// runtime — files pointing into a tunnel are a side effect of running the
    /// proxy, and creating them while it is down strands overrides nobody
    /// owns. *Removing* them is gated on nothing at all.
    ///
    /// Both hosts used to gate removal on the runtime too, reasoning that
    /// "outside the start/stop window no platform side-effects exist to
    /// reconcile". That is false in exactly the case that matters: when the
    /// proxy dies or fails to start *while the files are applied*, the side
    /// effects very much still exist, and a VPN drop then leaves
    /// `/etc/resolver/<domain>` pointing at servers only the tunnel could
    /// reach. Every lookup under those domains blackholes machine-wide —
    /// including the VPN gateway's own hostname when it falls under a managed
    /// domain, which is the bootstrap deadlock this gate exists to prevent.
    /// Removal must never be conditional on the health of the thing whose
    /// failure creates the need for it.
    ///
    /// Removal is also unconditional rather than presence-checked: deleting a
    /// file that is not there is free, and the check would be one more way to
    /// wrongly decide there is nothing to clean up.
    package func action(runtimeStarted: Bool) -> EntryFileAction {
        guard entriesWanted else { return .remove }
        return runtimeStarted ? .apply : .nothing
    }

    /// Acts on the current policy decision: writes the entry files when the VPN
    /// came up under a running proxy, removes them whenever the VPN is down and
    /// they are still on disk. Failures are logged, not thrown — a VPN
    /// transition handler has no caller to propagate to.
    ///
    /// The decision reads the gate's *current* state, so call this
    /// synchronously (same isolation context) right after the `update(_:)`
    /// whose result you are acting on — an `update(_:)` interleaved between the
    /// two changes what this does.
    package func reconcileEntryFiles(
        config: ProxyConfig,
        dnsManager: DNSManager,
        logger: any LogSink,
        runtimeStarted: Bool
    ) {
        let decision = action(runtimeStarted: runtimeStarted)
        do {
            switch decision {
            case .apply:
                try dnsManager.applyEntryFiles(config: config, logger: logger)
            case .remove:
                try dnsManager.clearEntryFiles(config: config, logger: logger)
            case .nothing:
                break
            }
        } catch {
            logger.log(
                .warning,
                "Could not \(decision == .apply ? "apply" : "remove") split-DNS entry files on VPN transition: \(error.localizedDescription)",
                category: .system
            )
        }
    }
}
