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

/// What a read of the own key found. A failed read is not absence.
package enum VPNDNSOwnKeyState: Equatable, Sendable {
    case present
    case absent
    case unreadable(String)
}

/// Only `added` makes the key this session's: configd removes a temporary key only with the session that added it.
package enum VPNDNSPublishResult: Equatable, Sendable {
    case added
    /// The path already holds a key: another session's, or one a closed session left.
    case collision
    case failed
}

/// The dynamic store as the publisher sees it: the VPN's keys read-only, and one key of its own.
package protocol VPNDNSStore: AnyObject {
    func dns(service: String) -> [String: VPNDNSValue]?
    func overridesPrimary(service: String) -> Bool
    func primaryService() -> String?
    func ownKeyState() -> VPNDNSOwnKeyState
    /// A temporary value of this store's session, which configd removes when the session ends.
    func publishOwnKey(_ value: [String: VPNDNSValue]) -> VPNDNSPublishResult
    /// True once the key is gone, an absent key included.
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
    /// Makes every failover server socket again, after the machine's path changed.
    func renewServerSockets()
    /// Asks the reserved probe name through the relay's own UDP and TCP listener.
    func probe() -> DNSFailoverProbe
    /// Real queries Conduit answered and left unanswered, both monotonic.
    var conduitProgress: DNSFailoverProgress { get }
}

package struct VPNDNSOverrideArm: Equatable, Sendable {
    package var service: String
    package var servers: [String]
    package var owner: pid_t

    package init(service: String, servers: [String], owner: pid_t) {
        self.service = service
        self.servers = servers
        self.owner = owner
    }
}

package enum VPNDNSOverrideOutcome: Equatable, Sendable {
    case armed(service: String, servers: Int, owner: pid_t)
    case published(service: String, port: Int)
    case publishFailed(service: String)
    /// A key this session did not add holds the path: someone else's, so it is left alone and nothing is published.
    case publishCollision(service: String)
    case withdrawn(service: String, reason: VPNDNSOverrideReason)
    case removalRefused(service: String)
    /// The session was closed after a refused removal, and no read has yet shown the key gone; retried each tick.
    case cleanupPending(service: String, reason: VPNDNSOverrideReason)
    case probeMissed(service: String, probe: DNSFailoverProbe, consecutive: Int)
    /// The probe answered, but since the last tick Conduit answered none of the real queries it left unanswered.
    case queriesUnanswered(service: String, unanswered: Int)

    package var logLine: String {
        let prefix = "vpn-dns-override"
        switch self {
        case .armed(let service, let servers, let owner):
            return "\(prefix) armed service=\(HelperAudit.safe(service)) servers=\(servers) owner=\(owner)"
        case .published(let service, let port):
            return "\(prefix) published service=\(HelperAudit.safe(service)) port=\(port)"
        case .publishCollision(let service):
            return "\(prefix) publish_collision service=\(HelperAudit.safe(service)); the key at the path is not this session's, left alone"
        case .publishFailed(let service):
            return "\(prefix) publish_failed service=\(HelperAudit.safe(service))"
        case .withdrawn(let service, let reason):
            return "\(prefix) withdrawn service=\(HelperAudit.safe(service)) reason=\(reason.rawValue)"
        case .removalRefused(let service):
            return "\(prefix) removal_refused service=\(HelperAudit.safe(service)); session closed"
        case .cleanupPending(let service, let reason):
            return "\(prefix) cleanup_pending service=\(HelperAudit.safe(service)) reason=\(reason.rawValue)"
        case .probeMissed(let service, let probe, let consecutive):
            return "\(prefix) probe service=\(HelperAudit.safe(service)) verdict=\(probe.verdict.word) "
                + "udp=\(probe.udp.word) tcp=\(probe.tcp.word) consecutive=\(consecutive)"
        case .queriesUnanswered(let service, let unanswered):
            return "\(prefix) queries_unanswered service=\(HelperAudit.safe(service)) unanswered=\(unanswered); counted as silent"
        }
    }

    package var isFailure: Bool {
        switch self {
        case .publishFailed, .publishCollision, .removalRefused, .cleanupPending: return true
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
    /// The longest a published key may go without a confirmed answer, whatever the reasons the ticks gave: refused,
    /// silent, a probe socket that failed or any mix of them. It is the silent streak's span, so no faster rule changes.
    package static let unverifiedSecondsToWithdraw = 30

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
    /// The key may still exist after a refused removal; nothing is published until a read shows it gone.
    package private(set) var cleanupPending = false
    private var pendingReason: VPNDNSOverrideReason = .disarmed
    private var publishedPort: Int?
    private var failoverService: String?
    private var probeOK = false
    private var lastVerdict: DNSFailoverProbeOutcome?
    private var consecutiveRefused = 0
    private var consecutiveSilent = 0
    private var lastConfirmed: UInt64?
    private var lastProgress = DNSFailoverProgress(answered: 0, unanswered: 0)
    private var lastPrimary: String??
    private let now: () -> UInt64

    /// `now` is monotonic nanoseconds.
    package init(
        store: any VPNDNSStore,
        relay: any VPNDNSFailoverRelay,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        report: @escaping (VPNDNSOverrideOutcome) -> Void
    ) {
        self.store = store
        self.relay = relay
        self.now = now
        self.report = report
    }

    package static func isValidArm(service: String, servers: [String]) -> Bool {
        VPNDNSOverrideValidation.isServiceID(service) && service != HelperConstants.vpnDNSOverrideServiceID
            && (1...VPNDNSOverrideValidation.maximumServers).contains(servers.count)
            && servers.allSatisfy(VPNDNSOverrideValidation.isTunnelServer)
    }

    /// False for an arm out of shape; it changes nothing then. The owner is required: its exit is what withdraws the key
    /// at once, so the caller arms only an owner it is watching.
    package func arm(service: String, servers: [String], owner: pid_t) -> Bool {
        guard Self.isValidArm(service: service, servers: servers) else { return false }
        arm = VPNDNSOverrideArm(service: service, servers: servers, owner: owner)
        failoverService = service
        consecutiveRefused = 0
        consecutiveSilent = 0
        let verdict = relay.probe().verdict
        lastProgress = relay.conduitProgress
        lastVerdict = verdict
        probeOK = verdict == .answered
        lastConfirmed = probeOK ? now() : nil
        if probeOK { toConduit() }
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
        if let arm, arm.owner != caller {
            relay.setMode(.vpn)
        } else {
            toConduit()
        }
        sync()
    }

    package func relayRestarted() {
        if arm == nil { toConduit() } else { relay.setMode(.vpn) }
        sync()
    }

    /// Every 10 s while armed or while a cleanup is pending.
    package var wantsTicks: Bool { arm != nil || cleanupPending }

    package func tick() {
        guard let arm else {
            sync()
            return
        }
        let probe = relay.probe()
        var verdict = probe.verdict
        let progress = relay.conduitProgress
        let unanswered = progress.unanswered - lastProgress.unanswered
        let answered = progress.answered - lastProgress.answered
        lastProgress = progress
        if verdict == .answered, unanswered > 0, answered == 0 {
            // A synthetic answer must not hide a forwarder that drops every real query.
            report(.queriesUnanswered(service: arm.service, unanswered: unanswered))
            verdict = .silent
        }
        switch verdict {
        case .answered:
            resetProbe()
            probeOK = true
            lastConfirmed = now()
            toConduit()
        case .refused:
            consecutiveSilent = 0
            consecutiveRefused = min(consecutiveRefused + 1, Self.refusedTicksToWithdraw)
            if consecutiveRefused >= Self.refusedTicksToWithdraw { probeOK = false }
            relay.setMode(.vpn)
            report(.probeMissed(service: arm.service, probe: probe, consecutive: consecutiveRefused))
        case .silent:
            consecutiveRefused = 0
            consecutiveSilent = min(consecutiveSilent + 1, Self.silentTicksToWithdraw)
            if consecutiveSilent >= Self.silentTicksToWithdraw { probeOK = false }
            relay.setMode(.vpn)
            report(.probeMissed(service: arm.service, probe: probe, consecutive: consecutiveSilent))
        case .notRunning:
            relay.setMode(.vpn)
        case .failed:
            // The helper's own socket failed: no word on the forwarder, so the mode stays, but no confirmation either.
            report(.probeMissed(service: arm.service, probe: probe, consecutive: 0))
        }
        lastVerdict = verdict
        if verdict != .answered, probeOK, let confirmed = lastConfirmed,
           now() &- confirmed >= UInt64(Self.unverifiedSecondsToWithdraw) * 1_000_000_000 {
            probeOK = false
        }
        sync()
    }

    /// After any event: publishes, republishes or withdraws the key to match what holds now.
    package func sync() {
        refreshFailoverServers()
        if cleanupPending {
            withdraw(pendingReason)
            if cleanupPending { return }
        }
        guard let arm else {
            withdraw(.disarmed)
            return
        }
        if let hold = hold(arm) {
            withdraw(hold)
            return
        }
        guard !published || store.ownKeyState() == .absent, let port = relay.listeningPort else { return }
        switch store.publishOwnKey(Self.ownKey(port: port)) {
        case .added:
            published = true
            publishedPort = port
            report(.published(service: arm.service, port: port))
        case .collision:
            published = false
            report(.publishCollision(service: arm.service))
        case .failed:
            published = false
            report(.publishFailed(service: arm.service))
        }
    }

    package func status(caller: pid_t?) -> HelperVPNDNSOverrideStatus? {
        guard let arm else { return nil }
        let reason = published ? nil : (hold(arm)?.rawValue ?? "publish_failed")
        return HelperVPNDNSOverrideStatus(
            serviceID: arm.service, servers: arm.servers, published: published, reason: reason,
            owned: arm.owner == caller, port: published ? publishedPort : nil
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
        guard probeOK else {
            switch lastVerdict {
            case .silent: return .targetSilent
            case .refused, nil: return .targetRefused
            default: return .targetUnverified
            }
        }
        return nil
    }

    /// Removes the key only while it is this session's: published, or awaiting a cleanup. A key at the path this session
    /// did not add is never removed. A read that fails is not taken for absence; the removal is tried anyway, and a
    /// refused one closes the session and stays pending until a read shows the key gone.
    private func withdraw(_ reason: VPNDNSOverrideReason) {
        let service = failoverService ?? "none"
        guard published || cleanupPending else { return }
        let state = store.ownKeyState()
        if state != .absent, !store.removeOwnKey() {
            if !cleanupPending { report(.removalRefused(service: service)) }
            store.closeSession()
            published = false
            if store.ownKeyState() != .absent {
                // The key that should be gone still names the relay: its lookups go where they would without it.
                relay.setMode(.vpn)
                if !cleanupPending || pendingReason != reason { report(.cleanupPending(service: service, reason: reason)) }
                cleanupPending = true
                pendingReason = reason
                return
            }
        }
        let shown = cleanupPending ? pendingReason : reason
        published = false
        cleanupPending = false
        report(.withdrawn(service: service, reason: shown))
    }

    private func refreshFailoverServers() {
        guard let service = arm?.service ?? failoverService else { return }
        var servers: [String] = []
        if case .strings(let listed)? = store.dns(service: service)?["ServerAddresses"] {
            servers = VPNDNSOverrideValidation.failoverServers(listed)
        }
        relay.setFailoverServers(servers)
        let primary = store.primaryService()
        if let seen = lastPrimary, seen != primary { relay.renewServerSockets() }
        lastPrimary = primary
    }

    /// While a cleanup is pending the relay stays on the VPN's servers.
    private func toConduit() {
        if !cleanupPending { relay.setMode(.conduit) }
    }

    private func resetProbe() {
        consecutiveRefused = 0
        consecutiveSilent = 0
    }
}
