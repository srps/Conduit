// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package enum VPNResolverOverrideDisarmReason: String, Hashable, Sendable {
    case gate
    case notInUse = "not_in_use"
    case manageOff = "manage_off"
    case relayNotServing = "relay_not_serving"
    case stop
}

package struct VPNResolverOverrideArm: Hashable, Sendable {
    package var service: String
    package var servers: [String]

    package init(service: String, servers: [String]) {
        self.service = service
        self.servers = servers
    }
}

package enum VPNResolverOverrideAction: Hashable, Sendable {
    case none
    case arm(VPNResolverOverrideArm)
    case disarm(VPNResolverOverrideDisarmReason)
}

package struct VPNResolverOverrideInput: Sendable {
    package var helperSupports: Bool
    package var manageSystemDNS: Bool
    package var relayServing: Bool
    package var entriesWanted: Bool
    package var reading: PushedResolverReading
    package var serversInUse: Set<String>
    /// Confirmed, or sent without a reply: either may be held by the helper.
    package var armed: VPNResolverOverrideArm?

    package init(
        helperSupports: Bool,
        manageSystemDNS: Bool,
        relayServing: Bool,
        entriesWanted: Bool,
        reading: PushedResolverReading,
        serversInUse: Set<String>,
        armed: VPNResolverOverrideArm?
    ) {
        self.helperSupports = helperSupports
        self.manageSystemDNS = manageSystemDNS
        self.relayServing = relayServing
        self.entriesWanted = entriesWanted
        self.reading = reading
        self.serversInUse = serversInUse
        self.armed = armed
    }
}

/// Arming is intent; the helper publishes and withdraws its own key by itself (decision 0049).
package enum VPNResolverOverridePolicy {
    package static func decide(_ input: VPNResolverOverrideInput) -> VPNResolverOverrideAction {
        switch wanted(input) {
        case .withheld(let reason):
            return input.armed == nil ? .none : .disarm(reason)
        case .tunnel(let target):
            guard input.helperSupports else { return .none }
            return input.armed == target ? .none : .arm(target)
        }
    }

    private enum Wanted {
        case tunnel(VPNResolverOverrideArm)
        case withheld(VPNResolverOverrideDisarmReason)
    }

    /// Every server must be in use, so internal names reach the tunnel's servers before public names leave them.
    private static func wanted(_ input: VPNResolverOverrideInput) -> Wanted {
        guard input.manageSystemDNS else { return .withheld(.manageOff) }
        guard input.relayServing else { return .withheld(.relayNotServing) }
        guard input.entriesWanted else { return .withheld(.gate) }
        let fullTunnels = input.reading.resolvers.filter(\.overridesPrimary)
        guard fullTunnels.count == 1, let tunnel = fullTunnels.first else { return .withheld(.notInUse) }
        guard tunnel.servers.allSatisfy(input.serversInUse.contains) else { return .withheld(.notInUse) }
        return .tunnel(VPNResolverOverrideArm(service: tunnel.serviceID, servers: tunnel.servers))
    }
}
