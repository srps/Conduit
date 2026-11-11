// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Every `utun` the dynamic store names, read in one pass. A snapshot is the
/// whole truth at one instant, never a delta: whoever holds one needs no
/// earlier snapshot to interpret it. See
/// `docs/design-vpn-detection-level-triggered.md`.
package struct TunnelSnapshot: Hashable, Sendable {
    package struct Tunnel: Hashable, Sendable {
        /// `utun` and digits.
        package let interface: String
        /// The store holds `State:/Network/Interface/<interface>/IPv4` or
        /// `/IPv6`. False for a tunnel only a service key names: the
        /// interface itself is gone, which is what tells a removal from a
        /// flap.
        package let hasInterfaceKey: Bool
        /// `Addresses` of the interface IPv4 key, in store order. Empty when
        /// the key is absent, has no `Addresses`, or lists none.
        package let ipv4Addresses: [String]
        /// The interface IPv6 key lists a unicast address outside
        /// `fe80::/10`. Apple's service tunnels carry a link-local only.
        package let hasRoutableIPv6: Bool
        /// The `<id>` of a `State:/Network/Service/<id>/IPv4` or `/IPv6` key
        /// whose `InterfaceName` is this tunnel; the first in order when
        /// several name it. Not always a UUID.
        package let serviceID: String?
        /// `OverridePrimary` is 1 on a service IPv4 key naming this tunnel:
        /// a full tunnel.
        package let overridesPrimary: Bool

        package init(
            interface: String,
            hasInterfaceKey: Bool = true,
            ipv4Addresses: [String] = [],
            hasRoutableIPv6: Bool = false,
            serviceID: String? = nil,
            overridesPrimary: Bool = false
        ) {
            assert(hasInterfaceKey || ipv4Addresses.isEmpty, "addresses come from the interface key")
            self.interface = interface
            self.hasInterfaceKey = hasInterfaceKey
            self.ipv4Addresses = ipv4Addresses
            self.hasRoutableIPv6 = hasRoutableIPv6
            self.serviceID = serviceID
            self.overridesPrimary = overridesPrimary
        }
    }

    /// One per interface, in name order.
    package let tunnels: [Tunnel]

    package init(tunnels: [Tunnel] = []) {
        assert(Set(tunnels.map(\.interface)).count == tunnels.count, "one entry per interface")
        self.tunnels = tunnels.sorted { $0.interface < $1.interface }
    }
}

/// One attempt to read the store: the whole snapshot, or why there is none.
package enum TunnelReading: Hashable, Sendable {
    /// A store call that failed, and the store's own reason for it.
    package struct Failure: Hashable, Sendable, Error {
        package enum Step: String, Hashable, Sendable {
            case storeCreate = "store_create"
            case storeSubscribe = "store_subscribe"
            case storeRead = "store_read"
            /// Detaching a subscription's queue on cancel.
            case storeUnsubscribe = "store_unsubscribe"
        }

        package let step: Step
        /// `SCError()` read straight after the call failed.
        package let code: Int32

        package init(_ step: Step, code: Int32) {
            self.step = step
            self.code = code
        }
    }

    case snapshot(TunnelSnapshot)
    case failed(Failure)
}

/// Which snapshot entries count as the VPN being up. A value rather than a
/// rule inside the timer, so a later selector (one VPN service, IPv6-only
/// tunnels) is a different predicate and not a different state machine.
package struct VPNUpPredicate: Sendable {
    package let counts: @Sendable (TunnelSnapshot.Tunnel) -> Bool

    package init(_ counts: @escaping @Sendable (TunnelSnapshot.Tunnel) -> Bool) {
        self.counts = counts
    }

    /// Any utun whose interface IPv4 key lists an address: the rule
    /// `VPNStatusMonitor` applies today.
    package static let anyIPv4Tunnel = VPNUpPredicate { !$0.ipv4Addresses.isEmpty }

    package func holds(for snapshot: TunnelSnapshot) -> Bool {
        snapshot.tunnels.contains(where: counts)
    }
}
