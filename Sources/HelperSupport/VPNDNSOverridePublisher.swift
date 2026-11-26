// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Darwin
import Foundation
import ProxyKernel

// Single-threaded by contract: the helper calls it from its one loop, and `FakeMachine` from under a lock.

package enum VPNDNSValue: Equatable, Sendable {
    case string(String)
    case number(Int)
    case bool(Bool)
    case strings([String])
    case numbers([Int])
}

/// The dynamic store as the publisher sees it: the VPN's keys read-only, and one key of its own.
package protocol VPNDNSStore: AnyObject {
    func dns(service: String) -> [String: VPNDNSValue]?
    func overridesPrimary(service: String) -> Bool
    func primaryService() -> String?
    func ownKeyExists() -> Bool
    /// A temporary value of this store's session, which configd removes when the session ends.
    func publishOwnKey(_ value: [String: VPNDNSValue]) -> Bool
    func removeOwnKey() -> Bool
    /// Ends the session, so configd removes its temporary key, and opens a fresh one.
    func closeSession()
}

/// The fail-safe relay the own key names; `DNSFailoverRelay` is the real one.
package protocol VPNDNSFailoverRelay: AnyObject {
    /// Set only while both the UDP and the TCP half listen.
    var listeningPort: Int? { get }
    var mode: DNSFailoverMode { get }
    func setMode(_ mode: DNSFailoverMode)
    func setFailoverServers(_ servers: [String])
    /// Asks Conduit's forwarder the reserved probe name.
    func probe() -> DNSFailoverProbeOutcome
}

package struct VPNDNSOverrideArm: Equatable, Sendable {
    package var service: String
    package var servers: [String]
    package var owner: pid_t?

    package init(service: String, servers: [String], owner: pid_t?) {
        self.service = service
        self.servers = servers
        self.owner = owner
    }
}

package enum VPNDNSOverrideOutcome: Equatable, Sendable {
    case armed(service: String, servers: Int, owner: pid_t?)
    case published(service: String, port: Int)
    case publishFailed(service: String)
    case withdrawn(service: String, reason: VPNDNSOverrideReason)
    case removalRefused(service: String)
    case probeMissed(service: String, verdict: DNSFailoverProbeOutcome, consecutive: Int)

    package var logLine: String {
        let prefix = "vpn-dns-override"
        switch self {
        case .armed(let service, let servers, let owner):
            return "\(prefix) armed service=\(HelperAudit.safe(service)) servers=\(servers) owner=\(owner.map(String.init) ?? "none")"
        case .published(let service, let port):
            return "\(prefix) published service=\(HelperAudit.safe(service)) port=\(port)"
        case .publishFailed(let service):
            return "\(prefix) publish_failed service=\(HelperAudit.safe(service))"
        case .withdrawn(let service, let reason):
            return "\(prefix) withdrawn service=\(HelperAudit.safe(service)) reason=\(reason.rawValue)"
        case .removalRefused(let service):
            return "\(prefix) removal_refused service=\(HelperAudit.safe(service)); session closed"
        case .probeMissed(let service, let verdict, let consecutive):
            return "\(prefix) probe service=\(HelperAudit.safe(service)) verdict=\(verdict.word) consecutive=\(consecutive)"
        }
    }

    package var isFailure: Bool {
        switch self {
        case .publishFailed, .removalRefused: return true
        default: return false
        }
    }
}

extension DNSFailoverProbeOutcome {
    var word: String {
        switch self {
        case .notRunning: return "not_running"
        case .answered: return "answered"
        case .refused: return "refused"
        case .silent: return "silent"
        case .failed(let why): return "failed(\(HelperAudit.bounded(why)))"
        }
    }
}

/// Publishes the helper's own key while it is safe (decision 0049) and never writes the VPN's keys.
package final class VPNDNSOverridePublisher {
    package static let tickSeconds = 10
    package static let refusedTicksToWithdraw = 2
    package static let silentTicksToWithdraw = 3

    package static func ownKey(port: Int) -> [String: VPNDNSValue] {
        [
            "ServerAddresses": .strings(["127.0.0.1"]),
            "ServerPort": .number(port),
            "SupplementalMatchDomains": .strings([""]),
            "SupplementalMatchOrders": .numbers([0]),
        ]
    }

    private let store: any VPNDNSStore
    private let relay: any VPNDNSFailoverRelay
    private let report: (VPNDNSOverrideOutcome) -> Void
    package private(set) var arm: VPNDNSOverrideArm?
    package private(set) var published = false
    private var publishedPort: Int?
    private var failoverService: String?
    private var probeOK = false
    private var lastVerdict: DNSFailoverProbeOutcome?
    private var consecutiveRefused = 0
    private var consecutiveSilent = 0

    package init(
        store: any VPNDNSStore,
        relay: any VPNDNSFailoverRelay,
        report: @escaping (VPNDNSOverrideOutcome) -> Void
    ) {
        self.store = store
        self.relay = relay
        self.report = report
    }

    /// False for an arm out of shape; it changes nothing then.
    package func arm(service: String, servers: [String], owner: pid_t?) -> Bool {
        guard VPNDNSOverrideValidation.isServiceID(service), service != HelperConstants.vpnDNSOverrideServiceID,
              (1...VPNDNSOverrideValidation.maximumServers).contains(servers.count),
              servers.allSatisfy(VPNDNSOverrideValidation.isTunnelServer) else { return false }
        arm = VPNDNSOverrideArm(service: service, servers: servers, owner: owner)
        failoverService = service
        consecutiveRefused = 0
        consecutiveSilent = 0
        let verdict = relay.probe()
        lastVerdict = verdict
        probeOK = verdict == .answered
        if probeOK { relay.setMode(.conduit) }
        report(.armed(service: service, servers: servers.count, owner: owner))
        sync()
        return true
    }

    package func disarm(_ reason: VPNDNSOverrideReason) {
        arm = nil
        resetProbe()
        withdraw(reason)
    }

    package func ownerExited(_ pid: pid_t) {
        guard let arm, arm.owner == pid else { return }
        self.arm = nil
        resetProbe()
        relay.setMode(.vpn)
        withdraw(.ownerExited)
    }

    /// A caller that does not own the arm starts the relay on the VPN's servers until a probe answers.
    package func relayStarted(caller: pid_t?) {
        if let arm, arm.owner == nil || arm.owner != caller {
            relay.setMode(.vpn)
        } else {
            relay.setMode(.conduit)
        }
        sync()
    }

    package func relayRestarted() {
        relay.setMode(arm == nil ? .conduit : .vpn)
        sync()
    }

    package func tick() {
        guard let arm else { return }
        let verdict = relay.probe()
        switch verdict {
        case .answered:
            resetProbe()
            probeOK = true
            relay.setMode(.conduit)
        case .refused:
            consecutiveSilent = 0
            consecutiveRefused = min(consecutiveRefused + 1, Self.refusedTicksToWithdraw)
            if consecutiveRefused >= Self.refusedTicksToWithdraw { probeOK = false }
            relay.setMode(.vpn)
            report(.probeMissed(service: arm.service, verdict: verdict, consecutive: consecutiveRefused))
        case .silent:
            consecutiveRefused = 0
            consecutiveSilent = min(consecutiveSilent + 1, Self.silentTicksToWithdraw)
            if consecutiveSilent >= Self.silentTicksToWithdraw { probeOK = false }
            relay.setMode(.vpn)
            report(.probeMissed(service: arm.service, verdict: verdict, consecutive: consecutiveSilent))
        case .notRunning:
            relay.setMode(.vpn)
        case .failed:
            // The helper's own socket failed; that says nothing about the forwarder.
            report(.probeMissed(service: arm.service, verdict: verdict, consecutive: 0))
            sync()
            return
        }
        lastVerdict = verdict
        sync()
    }

    /// After any event: publishes, republishes or withdraws the key to match what holds now.
    package func sync() {
        refreshFailoverServers()
        guard let arm else {
            withdraw(.disarmed)
            return
        }
        if let hold = hold(arm) {
            withdraw(hold)
            return
        }
        guard !published || !store.ownKeyExists(), let port = relay.listeningPort else { return }
        if store.publishOwnKey(Self.ownKey(port: port)) {
            published = true
            publishedPort = port
            report(.published(service: arm.service, port: port))
        } else {
            published = false
            report(.publishFailed(service: arm.service))
        }
    }

    package func status(caller: pid_t?) -> HelperVPNDNSOverrideStatus? {
        guard let arm else { return nil }
        let reason = published ? nil : (hold(arm)?.rawValue ?? "publish_failed")
        return HelperVPNDNSOverrideStatus(
            serviceID: arm.service, servers: arm.servers, published: published, reason: reason,
            owned: arm.owner != nil && arm.owner == caller, port: published ? publishedPort : nil
        )
    }

    private func hold(_ arm: VPNDNSOverrideArm) -> VPNDNSOverrideReason? {
        guard let dns = store.dns(service: arm.service), case .strings(let listed)? = dns["ServerAddresses"],
              VPNDNSOverrideValidation.failoverServers(listed) == arm.servers else { return .vpnChanged }
        if let supplemental = dns["SupplementalMatchDomains"], supplemental != .strings([]) { return .vpnChanged }
        guard store.overridesPrimary(service: arm.service), store.primaryService() == arm.service else {
            return .vpnChanged
        }
        guard relay.listeningPort != nil else { return .relayStopped }
        guard probeOK else { return lastVerdict == .silent ? .targetSilent : .targetRefused }
        return nil
    }

    private func withdraw(_ reason: VPNDNSOverrideReason) {
        let exists = store.ownKeyExists()
        guard published || exists else { return }
        if exists, !store.removeOwnKey() {
            report(.removalRefused(service: failoverService ?? "none"))
            store.closeSession()
        }
        published = false
        report(.withdrawn(service: failoverService ?? "none", reason: reason))
    }

    private func refreshFailoverServers() {
        guard let service = arm?.service ?? failoverService else { return }
        var servers: [String] = []
        if case .strings(let listed)? = store.dns(service: service)?["ServerAddresses"] {
            servers = VPNDNSOverrideValidation.failoverServers(listed)
        }
        relay.setFailoverServers(servers)
    }

    private func resetProbe() {
        consecutiveRefused = 0
        consecutiveSilent = 0
    }
}
