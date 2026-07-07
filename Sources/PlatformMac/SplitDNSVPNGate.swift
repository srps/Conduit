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

    /// Acts on a wanted-state flip: writes the entry files when the VPN
    /// came up, removes them when it went down. Failures are logged, not
    /// thrown — a VPN transition handler has no caller to propagate to.
    package func reconcileEntryFiles(config: ProxyConfig, dnsManager: DNSManager, logger: any LogSink) {
        do {
            if entriesWanted {
                try dnsManager.applyEntryFiles(config: config, logger: logger)
            } else {
                try dnsManager.clearEntryFiles(config: config, logger: logger)
            }
        } catch {
            logger.log(
                .warning,
                "Could not \(entriesWanted ? "apply" : "remove") split-DNS entry files on VPN transition: \(error.localizedDescription)",
                category: .system
            )
        }
    }
}
