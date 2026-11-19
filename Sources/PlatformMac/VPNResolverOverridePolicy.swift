// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

package enum VPNResolverOverrideReleaseReason: Hashable, Sendable {
    case gate
    case notInUse
    case manageOff
    case relayNotServing
    case stop
    case helper(String)

    package var rawValue: String {
        switch self {
        case .gate: "gate"
        case .notInUse: "not_in_use"
        case .manageOff: "manage_off"
        case .relayNotServing: "relay_not_serving"
        case .stop: "stop"
        case .helper(let reason): "helper:\(reason)"
        }
    }
}

package enum VPNResolverOverrideAction: Hashable, Sendable {
    case none
    case apply(service: String, expected: [String])
    case release(VPNResolverOverrideReleaseReason)
    case wait(until: ContinuousClock.Instant)
    case suspend(service: String, cap: VPNResolverOverrideCap)
}

package enum VPNResolverOverrideCap: String, Hashable, Sendable {
    case applied
}

package struct VPNResolverOverrideLandedApply: Hashable, Sendable {
    package var at: ContinuousClock.Instant
    package var servers: [String]

    package init(at: ContinuousClock.Instant, servers: [String]) {
        self.at = at
        self.servers = servers
    }
}

package struct VPNResolverOverrideInput: Sendable {
    package var helperSupports: Bool
    package var manageSystemDNS: Bool
    package var relayServing: Bool
    package var entriesWanted: Bool
    package var reading: PushedResolverReading
    package var serversInUse: Set<String>
    package var record: VPNDNSOverrideState?
    package var now: ContinuousClock.Instant
    /// Only applies whose servers differ from the previous landed apply's.
    package var applies: [String: [ContinuousClock.Instant]]
    package var keyRewritten: Bool
    package var lastApplies: [String: VPNResolverOverrideLandedApply]
    package var backoffUntil: ContinuousClock.Instant?
    package var suspended: [String: ContinuousClock.Instant]

    package init(
        helperSupports: Bool,
        manageSystemDNS: Bool,
        relayServing: Bool,
        entriesWanted: Bool,
        reading: PushedResolverReading,
        serversInUse: Set<String>,
        record: VPNDNSOverrideState?,
        now: ContinuousClock.Instant,
        applies: [String: [ContinuousClock.Instant]] = [:],
        keyRewritten: Bool = false,
        lastApplies: [String: VPNResolverOverrideLandedApply] = [:],
        backoffUntil: ContinuousClock.Instant? = nil,
        suspended: [String: ContinuousClock.Instant] = [:]
    ) {
        self.helperSupports = helperSupports
        self.manageSystemDNS = manageSystemDNS
        self.relayServing = relayServing
        self.entriesWanted = entriesWanted
        self.reading = reading
        self.serversInUse = serversInUse
        self.record = record
        self.now = now
        self.applies = applies
        self.keyRewritten = keyRewritten
        self.lastApplies = lastApplies
        self.backoffUntil = backoffUntil
        self.suspended = suspended
    }
}

package enum VPNResolverOverridePolicy {
    package static let maximumApplies = 3
    package static let applyWindow: Duration = .seconds(600)
    /// Spaces landed applies (at most 6 writes a minute); a refusal writes nothing and waits for a reading or tick.
    package static let minimumApplySpacing: Duration = .seconds(10)
    /// Not shorter than `applyWindow`, so an expired suspension finds its cap's history gone.
    package static let suspensionLifetime: Duration = .seconds(600)
    package static let backoffBase: Duration = .seconds(60)
    package static let backoffCeiling: Duration = .seconds(600)

    package static func backoff(step: Int) -> Duration {
        precondition(step >= 1, "a backoff follows at least one release")
        let doublings = min(step - 1, 4)
        return min(backoffBase * (1 << doublings), backoffCeiling)
    }

    package static func decide(_ input: VPNResolverOverrideInput) -> VPNResolverOverrideAction {
        guard input.helperSupports || input.record != nil else { return .none }
        let target: PushedResolver
        switch wanted(input) {
        case .withheld(let reason):
            guard let record = input.record else { return .none }
            return reason == .notInUse && holds(record, through: input) ? .none : .release(reason)
        case .tunnel(let resolver):
            target = resolver
        }
        if let record = input.record, record.serviceID == target.serviceID, record.originals == target.servers,
           !input.keyRewritten {
            return .none
        }
        guard !target.overridden else { return .none }
        if let since = input.suspended[target.serviceID], input.now - since < suspensionLifetime { return .none }
        if let until = input.backoffUntil, input.now < until { return .none }
        let last = input.lastApplies[target.serviceID]
        if last?.servers != target.servers {
            let recent = (input.applies[target.serviceID] ?? []).filter { input.now - $0 < applyWindow }.count
            guard recent < maximumApplies else { return .suspend(service: target.serviceID, cap: .applied) }
        }
        if let last, input.now - last.at < minimumApplySpacing {
            return .wait(until: last.at + minimumApplySpacing)
        }
        return .apply(service: target.serviceID, expected: target.servers)
    }

    /// Holds through a flap only while every original stays in use, so a set that drops one releases first (0049).
    private static func holds(_ record: VPNDNSOverrideState, through input: VPNResolverOverrideInput) -> Bool {
        let resolvers = input.reading.resolvers
        guard !resolvers.contains(where: { $0.overridesPrimary || $0.serviceID == record.serviceID }) else { return false }
        return record.originals.allSatisfy(input.serversInUse.contains)
    }

    private enum Wanted {
        case tunnel(PushedResolver)
        case withheld(VPNResolverOverrideReleaseReason)
    }

    /// Every server must be in use, so internal names reach the tunnel's servers before public names leave them.
    private static func wanted(_ input: VPNResolverOverrideInput) -> Wanted {
        guard input.manageSystemDNS else { return .withheld(.manageOff) }
        guard input.relayServing else { return .withheld(.relayNotServing) }
        guard input.entriesWanted else { return .withheld(.gate) }
        let fullTunnels = input.reading.resolvers.filter(\.overridesPrimary)
        guard fullTunnels.count == 1, let tunnel = fullTunnels.first else { return .withheld(.notInUse) }
        guard tunnel.servers.allSatisfy(input.serversInUse.contains) else { return .withheld(.notInUse) }
        return .tunnel(tunnel)
    }
}
