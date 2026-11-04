// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// One settled network-path report: the newest path once a burst of
/// `NetworkMonitor` updates has gone quiet (`RuntimeHost` waits it out).
/// Each update of the burst already ran the leading edge as it arrived
/// (`ProxyOrchestrator.invalidateNetworkPath`, #198); this is the refresh.
///
/// The fingerprint (`ProxyOrchestrator.admitNetworkPath`) gates only the
/// PAC refetch: it costs a fetch, and ran every ~75 s for hours with nothing
/// changed (#101). The system DNS reconcile runs for every settled report,
/// material or not. A VPN
/// client (Cisco Secure Client) rewrites service DNS with no change to status,
/// interfaces, gateways or IP-family support, and the reconcile is what
/// re-pins 127.0.0.1. When nothing drifted it only reads the services' DNS
/// and logs nothing.
@RuntimeActor
package enum NetworkPathReports {
    /// Proxy reconciliation is requested before a material change can suspend
    /// in `act`; DNS reconciliation follows it. Both run for every report.
    /// Each host guards reconciliation with managed settings and readiness.
    ///
    /// The leading edge runs again first. It does nothing for a path the
    /// updates already carried, and it keeps a caller that hands in a report
    /// with no updates before it, or one whose updates have not landed yet,
    /// from refreshing before it invalidates.
    package static func receive(
        _ path: NetworkPathState,
        orchestrator: ProxyOrchestrator,
        act: @RuntimeActor (NetworkPathChange) async -> Void,
        reconcileSystemDNS: @RuntimeActor () async -> Void,
        reconcileSystemProxy: @RuntimeActor () async -> Void = {}
    ) async {
        // Repair a failed application or a VPN rewrite before a PAC refetch
        // can suspend the transition. Unchanged reports also retry drift.
        await reconcileSystemProxy()
        orchestrator.invalidateNetworkPath(path)
        if let change = orchestrator.admitNetworkPath(path) {
            await act(change)
        }
        await reconcileSystemDNS()
    }
}
