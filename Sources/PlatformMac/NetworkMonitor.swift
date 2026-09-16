// SPDX-License-Identifier: Apache-2.0
import Foundation
import Network
import ProxyKernel

/// Tier C signal in `docs/design-vpn-flap-resilience.md`: general network path
/// changes (Wi-Fi roams, IPv6 RA shifts, wake events). Used for PAC re-fetch,
/// DNS reconcile, and the description string in logs. **No longer used to infer
/// VPN state** — that's Tier B's job (`VPNStatusMonitor`).
package final class NetworkMonitor {
    package struct PathChange: Sendable, Equatable {
        /// Interface names, joined, for log lines.
        package let description: String
        package let interfaces: [String]
        /// `NWPath.status == .satisfied`.
        package let satisfied: Bool

        package init(description: String, interfaces: [String], satisfied: Bool) {
            self.description = description
            self.interfaces = interfaces
            self.satisfied = satisfied
        }
    }

    /// `NWPathMonitor` reports several updates per wake or roam within a second.
    package static let defaultDebounceInterval: TimeInterval = 2

    private final class Handler: @unchecked Sendable {
        private let lock = NSLock()
        private var callback: (@Sendable (PathChange) -> Void)?
        var value: (@Sendable (PathChange) -> Void)? {
            get { lock.withLock { callback } }
            set { lock.withLock { callback = newValue } }
        }
    }

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.NetworkMonitor")
    private let debounceInterval: TimeInterval
    private let handler = Handler()
    private var debouncer: TrailingDebouncer<PathChange>?

    /// Fires once per burst of path updates with the newest path. Read at
    /// delivery, so it may be assigned before or after `start()`.
    package var onChange: (@Sendable (PathChange) -> Void)? {
        get { handler.value }
        set { handler.value = newValue }
    }

    package init(debounceInterval: TimeInterval = NetworkMonitor.defaultDebounceInterval) {
        self.debounceInterval = debounceInterval
    }

    package func start() {
        let handler = self.handler
        let debouncer = TrailingDebouncer<PathChange>(interval: debounceInterval, queue: queue) { change in
            handler.value?(change)
        }
        self.debouncer = debouncer
        monitor.pathUpdateHandler = { path in
            let interfaces = path.availableInterfaces.map(\.name)
            debouncer.signal(PathChange(
                description: interfaces.joined(separator: ", "),
                interfaces: interfaces,
                satisfied: path.status == .satisfied
            ))
        }
        monitor.start(queue: queue)
    }

    package func stop() {
        debouncer?.cancel()
        debouncer = nil
        monitor.cancel()
    }
}
