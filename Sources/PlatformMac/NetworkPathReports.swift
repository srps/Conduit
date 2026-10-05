// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// One debounced `NetworkMonitor` report, taken the same way by both hosts.
///
/// The fingerprint (`ProxyOrchestrator.admitNetworkPath`) gates only the
/// DoH transport reset and the PAC refetch: those drop in-flight queries and
/// cost a fetch, and ran every ~75 s for hours with nothing changed (#101).
/// The system DNS reconcile runs for every report, material or not. A VPN
/// client (Cisco Secure Client) rewrites service DNS with no change to status,
/// interfaces, gateways or IP-family support, and the reconcile is what
/// re-pins 127.0.0.1. When nothing drifted it only reads the services' DNS
/// and logs nothing.
@MainActor
package enum NetworkPathReports {
    /// Proxy reconciliation is requested before a material change can suspend
    /// in `act`; DNS reconciliation follows it. Both run for every report.
    /// Each host guards reconciliation with managed settings and readiness.
    package static func receive(
        _ path: NetworkPathState,
        orchestrator: ProxyOrchestrator,
        act: @MainActor (NetworkPathChange) async -> Void,
        reconcileSystemDNS: @MainActor () async -> Void,
        reconcileSystemProxy: @MainActor () async -> Void = {}
    ) async {
        // Repair a failed application or a VPN rewrite before a PAC refetch
        // can suspend the transition. Unchanged reports also retry drift.
        await reconcileSystemProxy()
        if let change = orchestrator.admitNetworkPath(path) {
            await act(change)
        }
        await reconcileSystemDNS()
    }
}
