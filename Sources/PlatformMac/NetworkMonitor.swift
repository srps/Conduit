// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import ProxyKernel

/// Tier C signal in `docs/design-vpn-flap-resilience.md`: general network path
/// changes (Wi-Fi roams, IPv6 RA shifts, wake events). Used for PAC re-fetch,
/// DNS reconcile, and the description string in logs. **No longer used to infer
/// VPN state** — that's Tier B's job (`VPNStatusMonitor`).
///
/// Reports every debounced update as a `NetworkPathState`. Whether one changed
/// anything material is the orchestrator's call
/// (`ProxyOrchestrator.admitNetworkPath`), so both hosts dedupe alike and the
/// decision is a `RuntimeEvent` (#101).
package final class NetworkMonitor {
    /// `NWPathMonitor` reports several updates per wake or roam within a second.
    package static let defaultDebounceInterval: TimeInterval = 2

    private final class Handler: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable (NetworkPathState) -> Void)?
        var value: (@Sendable (NetworkPathState) -> Void)? {
            get { lock.withLock { callback } }
            set { lock.withLock { callback = newValue } }
        }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.NetworkMonitor")
    private let debounceInterval: TimeInterval
    private let handler = Handler()
    private var debouncer: TrailingDebouncer<NetworkPathState>?

    /// Fires once per burst of path updates with the newest path. Read at
    /// delivery, so it may be assigned before or after `start()`.
    package var onChange: (@Sendable (NetworkPathState) -> Void)? {
        get { handler.value }
        set { handler.value = newValue }
    }

    package init(debounceInterval: TimeInterval = NetworkMonitor.defaultDebounceInterval) {
        self.debounceInterval = debounceInterval
    }

    package func start() {
        let handler = self.handler
        let debouncer = TrailingDebouncer<NetworkPathState>(interval: debounceInterval, queue: queue) { path in
            handler.value?(path)
        }
        self.debouncer = debouncer
        monitor.pathUpdateHandler = { path in
            debouncer.signal(Self.state(of: path))
        }
        monitor.start(queue: queue)
    }

    package func stop() {
        debouncer?.cancel()
        debouncer = nil
        monitor.cancel()
    }

    /// A field-for-field copy: `NWPath` cannot be constructed in a test, so
    /// the fingerprint and diff live on `NetworkPathState` instead.
    static func state(of path: NWPath) -> NetworkPathState {
        NetworkPathState(
            status: status(of: path.status),
            interfaces: path.availableInterfaces.map {
                NetworkPathState.Interface(name: $0.name, type: typeName(of: $0.type))
            },
            gateways: path.gateways.map(gatewayName(of:)),
            supportsIPv4: path.supportsIPv4,
            supportsIPv6: path.supportsIPv6,
            supportsDNS: path.supportsDNS,
            isExpensive: path.isExpensive,
            isConstrained: path.isConstrained
        )
    }

    private static func status(of status: NWPath.Status) -> NetworkPathState.Status {
        switch status {
        case .satisfied: return .satisfied
        case .unsatisfied: return .unsatisfied
        case .requiresConnection: return .requiresConnection
        @unknown default: return .unsatisfied
        }
    }

    private static func typeName(of type: NWInterface.InterfaceType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .wiredEthernet: return "wired"
        case .cellular: return "cellular"
        case .loopback: return "loopback"
        case .other: return "other"
        @unknown default: return "unknown"
        }
    }

    /// The gateway's address. `NWPath` gives each one port 0.
    private static func gatewayName(of endpoint: NWEndpoint) -> String {
        if case .hostPort(let host, _) = endpoint {
            return "\(host)"
        }
        return "\(endpoint)"
    }
}
