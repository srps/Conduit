// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import ProxyKernel

/// Tier C signal in `docs/design-vpn-flap-resilience.md`: general network path
/// changes (Wi-Fi roams, IPv6 RA shifts, wake events). Used for PAC re-fetch,
/// DNS reconcile, and the description string in logs. **No longer used to infer
/// VPN state** — that's Tier B's job (`VPNStatusMonitor`).
package final class NetworkMonitor {
    package init() {}
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.NetworkMonitor")
    /// Callback fires on `(description, interfaces)` for every path change.
    /// VPN state was previously the first parameter (derived from
    /// `path.usesInterfaceType(.other)`); the heuristic was both noisy
    /// (NWPathMonitor fires multiple times per VPN transition) and inaccurate
    /// (third-party VPN clients don't always report as `.other`). See `VPNStatusMonitor`.
    package var onChange: (@Sendable (String, [String]) -> Void)?

    package func start() {
        let callback = onChange
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.map(\.name)
            let description = interfaces.joined(separator: ", ")
            callback?(description, interfaces)
        }
        monitor.start(queue: queue)
    }

    package func stop() {
        monitor.cancel()
    }
}
