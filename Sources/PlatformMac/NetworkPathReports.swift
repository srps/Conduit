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
    /// `act` runs first and only for a material change; `reconcileSystemDNS`
    /// runs after it for every report. The host decides inside
    /// `reconcileSystemDNS` whether system DNS is managed and running.
    package static func receive(
        _ path: NetworkPathState,
        orchestrator: ProxyOrchestrator,
        act: @MainActor (NetworkPathChange) async -> Void,
        reconcileSystemDNS: @MainActor () async -> Void
    ) async {
        if let change = orchestrator.admitNetworkPath(path) {
            await act(change)
        }
        await reconcileSystemDNS()
    }
}
