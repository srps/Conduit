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
/// anything material, and so resets DNS transports and refetches PAC, is the
/// orchestrator's call (`ProxyOrchestrator.admitNetworkPath`), so both hosts
/// dedupe alike and the decision is a `RuntimeEvent` (#101). The hosts' DNS
/// reconcile runs for every report (`NetworkPathReports`).
///
/// A cancelled `NWPathMonitor` never reports again, and a host stops and
/// restarts its observers on one adapter (#260), so each start makes a fresh
/// monitor and debouncer and each stop cancels them. A report is delivered
/// only under the generation of the start that made it, so a late one from a
/// stopped monitor is dropped.
///
/// Checked by hand: every mutable property is in `state`, under `lock`; the
/// callback is called, and the monitor started and cancelled, outside it.
package final class NetworkMonitor: NetworkPathObserving, @unchecked Sendable {
    /// `NWPathMonitor` reports several updates per wake or roam within a second.
    package static let defaultDebounceInterval: TimeInterval = 2

    private struct State {
        var onChange: (@Sendable (NetworkPathState) -> Void)?
        /// Advanced by every start and every stop that ends one.
        var generation: UInt64 = 0
        var active: (monitor: NWPathMonitor, debouncer: TrailingDebouncer<NetworkPathState>)?
    }

    private let queue = DispatchQueue(label: "io.github.srps.Conduit.NetworkMonitor")
    private let debounceInterval: TimeInterval
    private let lock = NSLock()
    private var state = State()

    /// Fires once per burst of path updates with the newest path. Read at
    /// delivery, so it may be assigned before or after `start()`.
    package var onChange: (@Sendable (NetworkPathState) -> Void)? {
        get { lock.withLock { state.onChange } }
        set { lock.withLock { state.onChange = newValue } }
    }

    package func setOnChange(_ onChange: @Sendable @escaping (NetworkPathState) -> Void) {
        self.onChange = onChange
    }

    package init(debounceInterval: TimeInterval = NetworkMonitor.defaultDebounceInterval) {
        self.debounceInterval = debounceInterval
    }

    deinit {
        state.active?.debouncer.cancel()
        state.active?.monitor.cancel()
    }

    /// Starts a fresh monitor. A start while one is observing does nothing.
    package func start() {
        let monitor: NWPathMonitor? = lock.withLock {
            guard state.active == nil else { return nil }
            state.generation &+= 1
            let generation = state.generation
            let debouncer = TrailingDebouncer<NetworkPathState>(interval: debounceInterval, queue: queue) { [weak self] path in
                self?.deliver(path, armedAs: generation)
            }
            let monitor = NWPathMonitor()
            monitor.pathUpdateHandler = { path in
                debouncer.signal(Self.state(of: path))
            }
            state.active = (monitor, debouncer)
            return monitor
        }
        monitor?.start(queue: queue)
    }

    /// Cancels the monitor observing now, if any.
    package func stop() {
        let active = lock.withLock { () -> (monitor: NWPathMonitor, debouncer: TrailingDebouncer<NetworkPathState>)? in
            defer { state.active = nil }
            if state.active != nil { state.generation &+= 1 }
            return state.active
        }
        active?.debouncer.cancel()
        active?.monitor.cancel()
    }

    /// One debounced report from the start that armed `generation`. The callback is read in the same locked step as the check, so a
    /// report claimed before a stop can reach only the callback it read then, and one from a stopped monitor reaches none.
    private func deliver(_ path: NetworkPathState, armedAs generation: UInt64) {
        let callback = lock.withLock { state.generation == generation ? state.onChange : nil }
        callback?(path)
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
