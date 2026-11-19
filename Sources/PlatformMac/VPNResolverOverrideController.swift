// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel

/// Set before an apply is sent and cleared after a release returns, so the helper's write never parses without them.
package final class VPNDNSOverrideSubstitutions: Sendable {
    private let box = NIOLockedValueBox<[String: [String]]>([:])

    package init() {}

    package var current: [String: [String]] { box.withLockedValue { $0 } }

    fileprivate func set(_ substitutions: [String: [String]]) {
        box.withLockedValue { $0 = substitutions }
    }
}

/// One `pass` runs at a time; `release` may run beside one and lands after it on the serial `work` queue.
@RuntimeActor
package final class VPNResolverOverrideController {
    package struct Inputs: Sendable {
        package var manageSystemDNS: Bool
        package var relayServing: Bool
        package var entriesWanted: Bool
        package var reading: PushedResolverReading
        package var serversInUse: Set<String>

        package init(
            manageSystemDNS: Bool,
            relayServing: Bool,
            entriesWanted: Bool,
            reading: PushedResolverReading,
            serversInUse: Set<String>
        ) {
            self.manageSystemDNS = manageSystemDNS
            self.relayServing = relayServing
            self.entriesWanted = entriesWanted
            self.reading = reading
            self.serversInUse = serversInUse
        }
    }

    package enum Support: Sendable, Equatable {
        case unknown
        case supported
        case unsupported
    }

    package static let maximumTrackedServices = 16
    /// A client rewrite that beats the monitor leaves no reading of the helper's write, so after this a status decides.
    package static let readingSettle: Duration = .seconds(5)

    package let substitutions = VPNDNSOverrideSubstitutions()
    package private(set) var support = Support.unknown
    package private(set) var record: VPNDNSOverrideState?
    private(set) var suspended: [String: ContinuousClock.Instant] = [:]
    package private(set) var wakeAt: ContinuousClock.Instant?
    package var onWake: (@RuntimeActor () -> Void)?

    private let client: any PrivilegeClient
    private let work: PlatformWork
    private let now: @Sendable () -> ContinuousClock.Instant
    private let sleep: @Sendable (ContinuousClock.Instant) async throws -> Void
    private let emit: @RuntimeActor (RuntimeEvent, LogLevel) -> Void
    private var wakeTask: Task<Void, Never>?

    private var unconfirmedApply: VPNDNSOverrideState?
    private var unconfirmedApplySequence: UInt64 = 0
    private var accountedApplySequence: UInt64 = 0
    private var restorePendingReported = false
    private var unconfirmedRelease = false
    private var appliesInFlight = 0
    private var releaseInFlight: UInt64?
    private var lastApplySent: UInt64 = 0
    private var applies: [String: [ContinuousClock.Instant]] = [:]
    private var lastApplies: [String: VPNResolverOverrideLandedApply] = [:]
    private var backoffStep = 0
    private var backoffUntil: ContinuousClock.Instant?
    /// Until a reading shows `127.0.0.1`, one with the originals predates the helper's write, not a client rewrite.
    private var writeSeen = false
    private var keyRewritten = false
    private var appliedAt: ContinuousClock.Instant?
    private var issued: UInt64 = 0
    private var settled: UInt64 = 0

    package init(
        client: any PrivilegeClient,
        work: PlatformWork,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (ContinuousClock.Instant) async throws -> Void = {
            try await Task.sleep(until: $0, clock: .continuous)
        },
        emit: @escaping @RuntimeActor (RuntimeEvent, LogLevel) -> Void
    ) {
        self.client = client
        self.work = work
        self.now = now
        self.sleep = sleep
        self.emit = emit
    }

    package var mayHoldRecord: Bool {
        record != nil || unconfirmedApply != nil || unconfirmedRelease || appliesInFlight > 0
    }

    package func decide(_ inputs: Inputs) -> VPNResolverOverrideAction {
        VPNResolverOverridePolicy.decide(VPNResolverOverrideInput(
            helperSupports: support != .unsupported,
            manageSystemDNS: inputs.manageSystemDNS,
            relayServing: inputs.relayServing,
            entriesWanted: inputs.entriesWanted,
            reading: inputs.reading,
            serversInUse: inputs.serversInUse,
            record: record,
            now: now(),
            applies: applies,
            keyRewritten: keyRewritten,
            lastApplies: lastApplies,
            backoffUntil: backoffUntil,
            suspended: suspended
        ))
    }

    package func pass(_ inputs: @RuntimeActor () -> Inputs, pollStatus: Bool) async {
        var current = inputs()
        observe(current)
        var action = decide(current)
        let applying = if case .apply = action { true } else { false }
        let statusDue = (pollStatus && mayHoldRecord) || keyLeftOverride(current.reading)
            || (applying && (support == .unknown || mayHoldRecord))
        if statusDue {
            await status(current.reading)
            current = inputs()
            observe(current)
            action = decide(current)
        }
        switch action {
        case .none:
            return
        case .wait(let until):
            armWake(at: until)
        case .suspend(let service, let cap):
            if suspended.count >= Self.maximumTrackedServices,
               let oldest = suspended.min(by: { $0.value < $1.value })?.key {
                suspended[oldest] = nil
            }
            let at = now()
            suspended[service] = at
            let detail = "service=\(service) cap=\(cap.rawValue)"
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_suspended", detail: detail), .warning)
            armWake(at: at + VPNResolverOverridePolicy.suspensionLifetime)
        case .apply(let service, let expected):
            await apply(service: service, expected: expected)
        case .release(let reason):
            await release(reason)
        }
    }

    /// Bypasses the policy: the release that must land before system DNS is cleared.
    package func release(_ reason: VPNResolverOverrideReleaseReason) async {
        guard mayHoldRecord else { return }
        if let pending = releaseInFlight, pending > lastApplySent { return }
        let sequence = issue()
        releaseInFlight = sequence
        let result = await call(.release)
        if releaseInFlight == sequence { releaseInFlight = nil }
        let fresh = settle(sequence)
        switch result {
        case .success(.released):
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_released", detail: "reason=\(reason.rawValue)"), .notice)
            guard fresh else { return }
            forgetRecord()
        case .success(.unsupported):
            if fresh { markUnsupported() }
        case .success(let reply):
            failed("release", reason: "unexpected_reply_\(Self.name(reply))")
            if fresh { unconfirmedRelease = true }
        case .failure(let error):
            failed("release", reason: error.localizedDescription)
            if fresh { unconfirmedRelease = true }
        }
    }

    package func dnsStopped() {
        applies = [:]
        suspended = [:]
        cancelWake()
        if !mayHoldRecord { support = .unknown }
    }

    private func armWake(at deadline: ContinuousClock.Instant) {
        if let armed = wakeAt, armed <= deadline { return }
        wakeTask?.cancel()
        wakeAt = deadline
        let sleep = self.sleep
        wakeTask = Task { @RuntimeActor [weak self] in
            do {
                try await sleep(deadline)
            } catch {
                if Task.isCancelled { return }
            }
            guard let self, self.wakeAt == deadline else { return }
            self.wakeAt = nil
            self.wakeTask = nil
            self.onWake?()
        }
    }

    private func cancelWake() {
        wakeTask?.cancel()
        wakeTask = nil
        wakeAt = nil
    }

    private func status(_ reading: PushedResolverReading) async {
        let sequence = issue()
        let result = await call(.status)
        guard settle(sequence) else { return }
        switch result {
        case .success(.status(let held, let lastRelease, let restorePending)):
            support = .supported
            confirm(held, lastRelease: lastRelease, restorePending: restorePending, reading: reading)
        case .success(.unsupported):
            markUnsupported()
        case .success(let reply):
            failed("status", reason: "unexpected_reply_\(Self.name(reply))")
        case .failure(let error):
            failed("status", reason: error.localizedDescription)
        }
    }

    private func apply(service: String, expected: [String]) async {
        let attempt = VPNDNSOverrideState(serviceID: service, originals: expected)
        // Before the call; the held record stays, as the helper releases it only once this apply passes its checks.
        var substitutions = record.map { [$0.serviceID: $0.originals] } ?? [:]
        substitutions[service] = expected
        self.substitutions.set(substitutions)
        appliesInFlight += 1
        let sequence = issue()
        lastApplySent = sequence
        let result = await call(.apply(service: service, expected: expected))
        appliesInFlight -= 1
        let fresh = settle(sequence)
        switch result {
        case .success(.applied):
            landed(attempt, sequence: sequence, detail: "")
            guard fresh else { return }
            record = attempt
            appliedAt = now()
            unconfirmedApply = nil
            writeSeen = false
            keyRewritten = false
            self.substitutions.set([service: expected])
        case .success(.unsupported):
            if fresh { markUnsupported() }
        case .success(.refused(.writeFailed)):
            failed("apply", reason: VPNDNSOverrideRefusal.writeFailed.rawValue)
            if fresh { unconfirm(attempt, sequence: sequence) }
        case .success(.refused(let refusal)):
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_refused", detail: "reason=\(refusal.rawValue)"), .warning)
            if refusal == .relayNotServing { armBackoff() }
            guard fresh else { return }
            self.substitutions.set(record.map { [$0.serviceID: $0.originals] } ?? [:])
        case .success(let reply):
            failed("apply", reason: "unexpected_reply_\(Self.name(reply))")
            if fresh { unconfirm(attempt, sequence: sequence) }
        case .failure(let error):
            failed("apply", reason: error.localizedDescription)
            if fresh { unconfirm(attempt, sequence: sequence) }
        }
    }

    private func unconfirm(_ attempt: VPNDNSOverrideState, sequence: UInt64) {
        unconfirmedApply = attempt
        unconfirmedApplySequence = sequence
    }

    /// Counts an apply the helper holds once, whether its reply or a later status shows it.
    private func landed(_ attempt: VPNDNSOverrideState, sequence: UInt64, detail suffix: String) {
        guard sequence > accountedApplySequence else { return }
        accountedApplySequence = sequence
        if lastApplies[attempt.serviceID]?.servers != attempt.originals { note(attempt.serviceID, in: &applies) }
        noteLanded(attempt.serviceID, servers: attempt.originals)
        backoffStep = 0
        backoffUntil = nil
        let detail = "service=\(attempt.serviceID) servers=\(attempt.originals.count)\(suffix)"
        emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_applied", detail: detail), .notice)
    }

    private func call(_ request: VPNDNSOverrideRequest) async -> Result<VPNDNSOverrideReply, any Error> {
        let client = self.client
        return await work.run { Result { try client.vpnDNSOverride(request) } }
    }

    private func issue() -> UInt64 {
        issued += 1
        return issued
    }

    /// A reply may change state only while no later call has replied, so a late apply reply never undoes a release.
    private func settle(_ sequence: UInt64) -> Bool {
        guard sequence > settled else { return false }
        settled = sequence
        return true
    }

    private func confirm(
        _ held: VPNDNSOverrideState?, lastRelease: String?, restorePending: String?, reading: PushedResolverReading
    ) {
        let ours = [record, unconfirmedApply].compactMap { $0 }
        let releasedByHelper = record != nil && held == nil && !unconfirmedRelease
        let adopted = unconfirmedApply
        unconfirmedApply = nil
        unconfirmedRelease = false
        if let held, ours.contains(held) {
            if held != record {
                if held == adopted { landed(held, sequence: unconfirmedApplySequence, detail: " confirmed=status") }
                writeSeen = false
                keyRewritten = false
                appliedAt = now()
            }
            record = held
            let settled = writeSeen || appliedAt.map { now() - $0 >= Self.readingSettle } ?? true
            if settled, Self.ownServers(of: held, in: reading) { keyRewritten = true }
            substitutions.set([held.serviceID: held.originals])
            notePendingRestore(of: held, reason: restorePending)
        } else if releasedByHelper {
            forgetRecord()
            let known = lastRelease.flatMap(VPNDNSOverrideReleaseReason.init(rawValue:))?.rawValue
            let reason = VPNResolverOverrideReleaseReason.helper(known ?? "unknown")
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_released", detail: "reason=\(reason.rawValue)"), .notice)
            armBackoff()
        } else {
            // Another caller's record, or ours landed unseen: this app neither follows nor releases it.
            forgetRecord()
        }
    }

    private func notePendingRestore(of held: VPNDNSOverrideState, reason: String?) {
        guard let reason else {
            restorePendingReported = false
            return
        }
        guard !restorePendingReported else { return }
        restorePendingReported = true
        let known = VPNDNSOverrideReleaseReason(rawValue: reason)?.rawValue ?? "unknown"
        let detail = "service=\(held.serviceID) reason=helper:\(known)"
        emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_restore_pending", detail: detail), .warning)
    }

    private func forgetRecord() {
        record = nil
        unconfirmedApply = nil
        unconfirmedRelease = false
        restorePendingReported = false
        writeSeen = false
        keyRewritten = false
        appliedAt = nil
        substitutions.set([:])
    }

    private func markUnsupported() {
        support = .unsupported
        forgetRecord()
    }

    private func armBackoff() {
        backoffStep += 1
        backoffUntil = now() + VPNResolverOverridePolicy.backoff(step: backoffStep)
    }

    private func note(_ service: String, in history: inout [String: [ContinuousClock.Instant]]) {
        let at = now()
        for (key, times) in history {
            let recent = times.filter { at - $0 < VPNResolverOverridePolicy.applyWindow }
            history[key] = recent.isEmpty ? nil : recent
        }
        history[service, default: []].append(at)
        while history.count > Self.maximumTrackedServices,
              let oldest = history.min(by: { ($0.value.last ?? at) < ($1.value.last ?? at) })?.key {
            history[oldest] = nil
        }
    }

    private func noteLanded(_ service: String, servers: [String]) {
        lastApplies[service] = VPNResolverOverrideLandedApply(at: now(), servers: servers)
        while lastApplies.count > Self.maximumTrackedServices,
              let oldest = lastApplies.min(by: { $0.value.at < $1.value.at })?.key {
            lastApplies[oldest] = nil
        }
    }

    private func observe(_ inputs: Inputs) {
        if !inputs.entriesWanted {
            applies = [:]
            suspended = [:]
        }
        let at = now()
        for (service, since) in suspended.sorted(by: { $0.value < $1.value })
        where at - since >= VPNResolverOverridePolicy.suspensionLifetime {
            suspended[service] = nil
            emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_suspension_expired", detail: "service=\(service)"), .notice)
        }
        guard let record else { return }
        if inputs.reading.resolvers.contains(where: { $0.serviceID == record.serviceID && $0.overridden }) {
            writeSeen = true
            keyRewritten = false
        }
    }

    private func keyLeftOverride(_ reading: PushedResolverReading) -> Bool {
        guard let record, writeSeen, !keyRewritten else { return false }
        return Self.ownServers(of: record, in: reading)
    }

    private static func ownServers(of record: VPNDNSOverrideState, in reading: PushedResolverReading) -> Bool {
        reading.resolvers.contains { $0.serviceID == record.serviceID && !$0.overridden }
    }

    private func failed(_ operation: String, reason: String) {
        let detail = "operation=\(operation) reason=\(reason)"
        emit(RuntimeEvent(kind: .health, event: "dns.vpn_override_failed", detail: detail), .warning)
    }

    private static func name(_ reply: VPNDNSOverrideReply) -> String {
        switch reply {
        case .unsupported: "unsupported"
        case .applied: "applied"
        case .refused: "refused"
        case .released: "released"
        case .status: "status"
        }
    }
}
