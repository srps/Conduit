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

/// What a read of a VPN key found. A failed read is neither absence nor a change.
package enum VPNDNSRead: Equatable, Sendable {
    case absent
    /// The store failed; for the legacy restore, also a key holding a field that cannot be written back.
    case unreadable(String)
    case value([String: VPNDNSValue])
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
    func dns(service: String) -> VPNDNSRead
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
    func stop()
    func setFailoverServers(_ servers: [String])
    /// Makes every failover server socket again, after the machine's path changed.
    func renewServerSockets()
    /// Asks the reserved probe name through the relay's own UDP and TCP listener.
    func probe() -> DNSFailoverProbe
    /// Asks Conduit again, directly and over the same half, the last real question it left unanswered there.
    func recheck(_ transport: DNSFailoverTransport) -> DNSFailoverProbeOutcome
    /// Real queries Conduit answered and left unanswered over one half, both monotonic.
    func conduitProgress(_ transport: DNSFailoverTransport) -> DNSFailoverProgress
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
    /// The VPN's key could not be read: the relay keeps the servers it last read from it.
    case failoverServersKept(service: String, reason: String)
    /// The probe answered, but Conduit last left real queries over this half unanswered and answered none since, nor
    /// the recheck over it.
    case queriesUnanswered(service: String, transport: DNSFailoverTransport, unanswered: Int, recheck: DNSFailoverProbeOutcome)
    /// `stop-dns-relay` came while a cleanup was pending: the relay stays up on the VPN's servers until it completes.
    case relayStopDeferred(service: String)
    case relayStoppedAfterCleanup(service: String)

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
        case .failoverServersKept(let service, let reason):
            return "\(prefix) failover_servers_kept service=\(HelperAudit.safe(service)) reason=\"\(HelperAudit.bounded(reason))\"; "
                + "the VPN's key is unreadable"
        case .queriesUnanswered(let service, let transport, let unanswered, let recheck):
            return "\(prefix) queries_unanswered service=\(HelperAudit.safe(service)) transport=\(transport.rawValue) "
                + "unanswered=\(unanswered) "
                + "recheck=\(recheck.word); counted as silent"
        case .relayStopDeferred(let service):
            return "\(prefix) relay_stop_deferred service=\(HelperAudit.safe(service)); "
                + "the relay stays on the VPN's servers until the key's cleanup completes"
        case .relayStoppedAfterCleanup(let service):
            return "\(prefix) relay_stopped service=\(HelperAudit.safe(service)); the key's cleanup completed"
        }
    }

    package var isFailure: Bool {
        switch self {
        case .publishFailed, .publishCollision, .removalRefused, .cleanupPending, .failoverServersKept: return true
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
    private static let unverifiedNanoseconds = UInt64(unverifiedSecondsToWithdraw) * 1_000_000_000

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
    /// A relay stop held back by the cleanup: it runs before anything is published, unless a Start supersedes it.
    package private(set) var relayStopPending = false
    private var pendingReason: VPNDNSOverrideReason = .disarmed
    private var publishedPort: Int?
    private var failoverService: String?
    private var probeOK = false
    private var lastVerdict: DNSFailoverProbeOutcome?
    private var consecutiveRefused = 0
    private var consecutiveSilent = 0
    /// The halves over which Conduit left real queries unanswered and has answered none since: a probe answer alone
    /// does not confirm it, and the relay stays on the VPN's servers, until it answers a real query over that half or
    /// the recheck over it.
    private var failing: Set<DNSFailoverTransport> = []
    private var lastConfirmed: UInt64?
    private var lastProgress: [DNSFailoverTransport: DNSFailoverProgress] = [:]
    private var lastPrimary: String??
    private var serversUnreadable = false
    private let now: () -> UInt64
    private let expiry: VPNDNSOverrideExpiry?

    /// `now` is monotonic nanoseconds. `expiry`, when given, carries the published key's deadline to a watchdog.
    package init(
        store: any VPNDNSStore,
        relay: any VPNDNSFailoverRelay,
        now: @escaping () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
        expiry: VPNDNSOverrideExpiry? = nil,
        report: @escaping (VPNDNSOverrideOutcome) -> Void
    ) {
        self.store = store
        self.relay = relay
        self.now = now
        self.expiry = expiry
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
        step { armed(service: service, servers: servers, owner: owner) }
        return true
    }

    private func armed(service: String, servers: [String], owner: pid_t) {
        arm = VPNDNSOverrideArm(service: service, servers: servers, owner: owner)
        failoverService = service
        consecutiveRefused = 0
        consecutiveSilent = 0
        let probe = relay.probe()
        let verdict = screened(probe.verdict, service: service, unanswered: consumeProgress())
        lastVerdict = verdict
        probeOK = verdict == .answered
        lastConfirmed = probeOK ? now() : nil
        if probeOK { toConduit() } else if !failing.isEmpty { relay.setMode(.vpn) }
        report(.armed(service: service, servers: servers.count, owner: owner))
        reconcile()
    }

    package func disarm(_ reason: VPNDNSOverrideReason) {
        step {
            arm = nil
            resetProbe()
            withdraw(reason)
        }
    }

    package func ownerExited(_ pid: pid_t) {
        step {
            guard let arm, arm.owner == pid else { return }
            self.arm = nil
            resetProbe()
            relay.setMode(.vpn)
            withdraw(.ownerExited)
        }
    }

    /// A caller that does not own the arm starts the relay on the VPN's servers until a probe answers.
    package func relayStarted(caller: pid_t?) {
        step {
            relayStopPending = false
            if let arm, arm.owner != caller {
                relay.setMode(.vpn)
            } else {
                toConduit()
            }
            reconcile()
        }
    }

    package func relayRestarted() {
        step {
            if arm == nil { toConduit() } else { relay.setMode(.vpn) }
            reconcile()
        }
    }

    /// `stop-dns-relay`, after the disarm: a key whose cleanup is pending keeps the relay answering, on the VPN's servers,
    /// until the cleanup completes. True when the relay stopped now.
    @discardableResult
    package func stopRelay() -> Bool {
        step { stoppedRelay() }
    }

    private func stoppedRelay() -> Bool {
        guard cleanupPending else {
            relayStopPending = false
            relay.stop()
            return true
        }
        relay.setMode(.vpn)
        if !relayStopPending { report(.relayStopDeferred(service: failoverService ?? "none")) }
        relayStopPending = true
        return false
    }

    /// Every 10 s while armed or while a cleanup is pending.
    package var wantsTicks: Bool { arm != nil || cleanupPending }

    package func tick() {
        step { ticked() }
    }

    private func ticked() {
        guard let arm else {
            reconcile()
            return
        }
        let probe = relay.probe()
        let unanswered = consumeProgress()
        let verdict = screened(probe.verdict, service: arm.service, unanswered: unanswered)
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
        if verdict != .answered, probeOK, !confirmedWithinBound { probeOK = false }
        reconcile()
    }

    /// After every event of the helper's loop: a key past the bound goes even when no tick has run since.
    package func checkExpiry() {
        step {
            guard published, !confirmedWithinBound else { return }
            reconcile()
        }
    }

    /// After any event: publishes, republishes or withdraws the key to match what holds now.
    package func sync() {
        step { reconcile() }
    }

    private func reconcile() {
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
        step {
            guard let arm else { return nil }
            let reason = published ? nil : (hold(arm)?.rawValue ?? "publish_failed")
            return HelperVPNDNSOverrideStatus(
                serviceID: arm.service, servers: arm.servers, published: published, reason: reason,
                owned: arm.owner == caller, port: published ? publishedPort : nil
            )
        }
    }

    /// Each entry point is one step: the watchdog cannot remove the key in the middle of it, and a removal it made since
    /// the last step retires this session's publication before anything reads or touches the key.
    private func step<T>(_ body: () -> T) -> T {
        guard let expiry else { return body() }
        return expiry.step { removedByWatchdog in
            if removedByWatchdog, published {
                published = false
                report(.withdrawn(service: failoverService ?? "none", reason: .targetUnverified))
            }
            let result = body()
            return (result, published ? lastConfirmed.map { $0 &+ Self.unverifiedNanoseconds } : nil)
        }
    }

    private func hold(_ arm: VPNDNSOverrideArm) -> VPNDNSOverrideReason? {
        let dns: [String: VPNDNSValue]
        switch store.dns(service: arm.service) {
        case .value(let value): dns = value
        case .unreadable: return .vpnUnreadable
        case .absent: return .vpnChanged
        }
        guard case .strings(let listed)? = dns["ServerAddresses"],
              VPNDNSOverrideValidation.failoverServers(listed) == arm.servers else { return .vpnChanged }
        if let supplemental = dns["SupplementalMatchDomains"], supplemental != .strings([]) { return .vpnChanged }
        guard store.overridesPrimary(service: arm.service), store.primaryService() == arm.service else {
            return .vpnChanged
        }
        guard relay.listeningPort != nil, !relayStopPending else { return .relayStopped }
        guard probeOK, confirmedWithinBound else {
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
        if relayStopPending {
            relayStopPending = false
            relay.stop()
            report(.relayStoppedAfterCleanup(service: service))
        }
    }

    /// An unreadable key keeps the servers last read: only a read that shows them gone or changed replaces them.
    private func refreshFailoverServers() {
        guard let service = arm?.service ?? failoverService else { return }
        switch store.dns(service: service) {
        case .value(let dns):
            serversUnreadable = false
            var servers: [String] = []
            if case .strings(let listed)? = dns["ServerAddresses"] { servers = VPNDNSOverrideValidation.failoverServers(listed) }
            relay.setFailoverServers(servers)
        case .absent:
            serversUnreadable = false
            relay.setFailoverServers([])
        case .unreadable(let reason):
            if !serversUnreadable { report(.failoverServersKept(service: service, reason: reason)) }
            serversUnreadable = true
        }
        let primary = store.primaryService()
        if let seen = lastPrimary, seen != primary { relay.renewServerSockets() }
        lastPrimary = primary
    }

    /// What the relay counted since the last read, per half: a half whose latest real query went unanswered is failing,
    /// one whose latest was answered is not. Returns the unanswered queries per half.
    private func consumeProgress() -> [DNSFailoverTransport: Int] {
        var unanswered: [DNSFailoverTransport: Int] = [:]
        for transport in DNSFailoverTransport.allCases {
            let progress = relay.conduitProgress(transport)
            let last = lastProgress[transport] ?? .zero
            lastProgress[transport] = progress
            guard progress.answered != last.answered || progress.unanswered != last.unanswered else { continue }
            unanswered[transport] = progress.unanswered - last.unanswered
            if progress.lastUnanswered { failing.insert(transport) } else { failing.remove(transport) }
        }
        return unanswered
    }

    /// A synthetic answer must not hide a forwarder that drops real queries, nor end that failure while the lookups go
    /// to the VPN's servers and Conduit gets none to answer: only the recheck over the failing half can.
    private func screened(
        _ verdict: DNSFailoverProbeOutcome, service: String, unanswered: [DNSFailoverTransport: Int]
    ) -> DNSFailoverProbeOutcome {
        guard verdict == .answered, !failing.isEmpty else { return verdict }
        for transport in DNSFailoverTransport.allCases where failing.contains(transport) {
            let recheck = relay.recheck(transport)
            if recheck == .answered {
                failing.remove(transport)
            } else {
                report(.queriesUnanswered(
                    service: service, transport: transport, unanswered: unanswered[transport] ?? 0, recheck: recheck
                ))
            }
        }
        return failing.isEmpty ? .answered : .silent
    }

    private var confirmedWithinBound: Bool {
        lastConfirmed.map { now() &- $0 < Self.unverifiedNanoseconds } ?? false
    }

    /// While a cleanup is pending, or Conduit drops real queries, the relay stays on the VPN's servers.
    private func toConduit() {
        if !cleanupPending, failing.isEmpty { relay.setMode(.conduit) }
    }

    private func resetProbe() {
        consecutiveRefused = 0
        consecutiveSilent = 0
    }
}
