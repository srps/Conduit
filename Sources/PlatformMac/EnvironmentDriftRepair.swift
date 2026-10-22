// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Notices when the shell-environment surface no longer holds what Conduit
/// applied, and puts it back (#175). Both hosts run one pass per trigger
/// (wake, network, VPN, proxy-settings notification, and a periodic tick)
/// on their platform queue, while the proxy runs and the switch is on.
///
/// Something stripped the block from every profile and unset the launchd
/// variables without going through `EnvironmentManager.clear`, and nothing
/// noticed: the journal still said applied, and shells and GUI apps ran
/// without the proxy until the switch was flipped.
///
/// Bounded the way location drift repair is: at most `maximumRepairs`
/// repair attempts within `window`, whether they wrote, failed half way, or
/// wrote nothing. A program that keeps stripping the block, or a `setenv`
/// that keeps failing, would otherwise turn every notification into a
/// rewrite. Past the budget the repair is withheld with one event, and the
/// host retries once when the window reopens. A surface that cannot be
/// repaired (an unsafe profile, an unreadable variable) is reported once per
/// episode, not on every pass.
///
/// An episode ends when anything else applies or clears: the manager's
/// generation then differs from the one this repair left behind, so a
/// config change, a restart or the switch going off starts a new budget.
package final class EnvironmentDriftRepair: @unchecked Sendable {
    /// What asked for a pass. The raw value is the events' `trigger=`.
    package enum Trigger: String, Sendable {
        /// A wake, network, VPN or proxy-settings report.
        case observed
        /// The periodic tick.
        case timer
        /// A withheld repair's window reopened.
        case retry

        /// The trigger a host keeps for one pass that coalesces `self` with a
        /// pending one. A tick or retry outranks a notification: only they
        /// may attempt after a failure, and a notification merged into
        /// one must not inherit that right, nor take it away.
        package func coalesced(with pending: Trigger?) -> Trigger {
            guard let pending else { return self }
            return pending == .observed ? self : pending
        }
    }

    package struct Limits: Sendable {
        package var maximumRepairs: Int
        package var window: Duration

        package init(maximumRepairs: Int = 3, window: Duration = .seconds(30 * 60)) {
            precondition(maximumRepairs > 0 && window > .zero)
            self.maximumRepairs = maximumRepairs
            self.window = window
        }
    }

    private let manager: EnvironmentManager
    private let eventSink: @Sendable (RuntimeEvent) -> Void
    private let logger: (any LogSink)?
    private let limits: Limits
    private let now: @Sendable () -> ContinuousClock.Instant
    private let lock = NSLock()
    /// Repair attempts within the window; never more than `maximumRepairs`.
    private var repairs: [ContinuousClock.Instant] = []
    /// The manager's generation after this repair's last apply; any other
    /// value means something else applied or cleared since.
    private var episodeGeneration: UInt64?
    /// The last attempt failed. Reports then wait for the tick or a retry:
    /// a failure that writes nothing would otherwise spend the budget on
    /// the next burst of notifications and postpone recovery by a window.
    private var lastAttemptFailed = false
    private var withheldReported = false
    /// The failure last reported, so a pass that finds the same one again
    /// stays quiet until something changes.
    private var reportedFailure: String?

    package init(
        manager: EnvironmentManager,
        eventSink: @escaping @Sendable (RuntimeEvent) -> Void,
        logger: (any LogSink)?,
        limits: Limits = Limits(),
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }
    ) {
        self.manager = manager
        self.eventSink = eventSink
        self.logger = logger
        self.limits = limits
        self.now = now
    }

    /// Forgets the budget and what was reported: the switch went off, or a
    /// new runtime started, so a later drift is a new episode.
    package func reset() {
        lock.withLock {
            repairs = []
            withheldReported = false
            reportedFailure = nil
        }
    }

    /// What one pass found and did.
    package struct PassOutcome: Equatable, Sendable {
        /// When to retry a repair the budget withheld.
        package var retry: Duration?
        /// The surface holds what `config` asks for: it was clean, or a
        /// repair wrote all of it. Nothing else counts, not even a pass that
        /// found nothing it could repair beside a profile it may not edit.
        package var settled: Bool
        /// Why it is not settled, as an event's `reason=`.
        package var reason: String?

        static let settledNow = PassOutcome(retry: nil, settled: true, reason: nil)
        static func unsettled(_ reason: String, retry: Duration? = nil) -> PassOutcome {
            PassOutcome(retry: retry, settled: false, reason: reason)
        }
    }

    /// One pass. Returns when to retry a repair the budget withheld; `pass`
    /// says more.
    @discardableResult
    package func run(config: ProxyConfig, generation: UInt64, trigger: Trigger, isCurrent: () -> Bool) -> Duration? {
        pass(config: config, generation: generation, trigger: trigger, isCurrent: isCurrent).retry
    }

    /// One pass, and its verdict. `generation` is the manager's, read by the
    /// host together with `config` before it queued the pass, so a newer
    /// apply that lands first supersedes it. `isCurrent` is the host's
    /// lifecycle check, evaluated under the manager's lock immediately
    /// before any write.
    package func pass(config: ProxyConfig, generation: UInt64, trigger: Trigger, isCurrent: () -> Bool) -> PassOutcome {
        let backingOff: Bool = lock.withLock {
            if episodeGeneration != generation {
                episodeGeneration = generation
                repairs = []
                withheldReported = false
                reportedFailure = nil
                lastAttemptFailed = false
            }
            return lastAttemptFailed && trigger == .observed
        }
        guard !backingOff else { return .unsettled("backing_off") }
        let drift = manager.inspect(config: config)
        guard drift.hasDrift else {
            if drift.isClean {
                lock.withLock { reportedFailure = nil; withheldReported = false; lastAttemptFailed = false }
            } else if lock.withLock({ reportedFailure == nil }) {
                // Nothing to repair, but something cannot be inspected or
                // edited: say so once, not on every tick, and not again
                // after a partial repair already named it.
                reportFailureOnce(reason: drift.unsafeProfiles.isEmpty ? "unreadable" : "unsafe_file", drift: drift)
            }
            if drift.isClean { return .settledNow }
            return .unsettled(drift.unsafeProfiles.isEmpty ? "unreadable" : "unsafe_file")
        }
        // While withheld, only the first pass of the episode reports: the
        // drift and the withheld repair, once each.
        let (retry, firstWithheld) = budget()
        if retry == nil || firstWithheld {
            emit("platform.environment_drift", "trigger=\(trigger.rawValue) " + Self.describe(drift), level: .warning)
        }
        if let retry {
            if firstWithheld {
                emit("platform.environment_repair_withheld",
                     "repairs=\(limits.maximumRepairs) window_seconds=\(limits.window.components.seconds) "
                         + "retry_seconds=\(retry.components.seconds + (retry.components.attoseconds > 0 ? 1 : 0))",
                     level: .warning)
            }
            return .unsettled("repair_withheld", retry: retry)
        }

        let result: EnvironmentManager.ApplyResult?
        do {
            result = try manager.repair(config: config, ifGeneration: generation, isCurrent: isCurrent, logger: logger)
        } catch {
            // It may have written a profile before it threw: an attempt.
            chargeAttempt(failed: true)
            reportFailureOnce(reason: "apply_error", drift: drift, extra: "error=\(String(describing: error))")
            return .unsettled("apply_error")
        }
        guard let result else {
            emit("platform.environment_repair_superseded", "trigger=\(trigger.rawValue)", level: .info)
            return .unsettled("superseded")
        }
        // A profile left alone counts as left, even beside a repaired
        // variable, and even one that turned unsafe after the inspection:
        // the surface is not what was applied.
        var profilesLeft = Set(drift.unsafeProfiles.keys)
        for (target, outcome) in result.profiles {
            if case .skipped = outcome { profilesLeft.insert(target) }
        }
        let notPublished = Set(result.launchd.failed + result.launchd.withheld + result.launchd.unreadable)
        // Every variable not published counts, even one that drifted after
        // the inspection.
        let launchdLeft = notPublished.union(drift.unreadableLaunchd).sorted()
        let repaired = profilesLeft.isEmpty && launchdLeft.isEmpty
        chargeAttempt(failed: !repaired)
        if repaired {
            lock.withLock { reportedFailure = nil }
            emit("platform.environment_repaired",
                 "trigger=\(trigger.rawValue) profiles=\(drift.profiles.count) launchd=\(drift.launchd.count)", level: .notice)
        } else {
            reportFailureOnce(reason: "partial", drift: drift,
                              extra: "profiles_left=\(profilesLeft.map(\.rawValue).sorted().joined(separator: ",")) "
                                  + "launchd_left=\(launchdLeft.joined(separator: ","))")
        }
        return repaired ? .settledNow : .unsettled("partial")
    }

    /// One attempt against the budget, and the generation it left behind.
    private func chargeAttempt(failed: Bool) {
        let after = manager.generation
        lock.withLock {
            repairs.append(now())
            episodeGeneration = after
            lastAttemptFailed = failed
        }
    }

    /// Nil when a repair may write now; otherwise how long until the window
    /// reopens, and whether this is the episode's first withheld pass.
    private func budget() -> (retry: Duration?, firstWithheld: Bool) {
        lock.withLock {
            let instant = now()
            repairs.removeAll { instant - $0 >= limits.window }
            guard repairs.count >= limits.maximumRepairs, let oldest = repairs.min() else {
                withheldReported = false
                return (nil, false)
            }
            let retry = limits.window - (instant - oldest)
            defer { withheldReported = true }
            return (retry, !withheldReported)
        }
    }

    private func reportFailureOnce(reason: String, drift: EnvironmentManager.Drift, extra: String = "") {
        let detail = (["reason=\(reason)", Self.describe(drift), extra].filter { !$0.isEmpty }).joined(separator: " ")
        let isNew = lock.withLock {
            guard reportedFailure != detail else { return false }
            reportedFailure = detail
            return true
        }
        if isNew { emit("platform.environment_repair_failed", detail, level: .warning) }
    }

    /// Names and states only: never a variable's value or a profile's text.
    static func describe(_ drift: EnvironmentManager.Drift) -> String {
        var parts: [String] = []
        if !drift.profiles.isEmpty {
            parts.append("profiles=" + drift.profiles.map { "\($0.key.rawValue):\($0.value.rawValue)" }.sorted().joined(separator: ","))
        }
        if !drift.launchd.isEmpty { parts.append("launchd=" + drift.launchd.joined(separator: ",")) }
        if !drift.unsafeProfiles.isEmpty {
            parts.append("unsafe=" + drift.unsafeProfiles.map { "\($0.key.rawValue):\($0.value.rawValue)" }.sorted().joined(separator: ","))
        }
        if !drift.unreadableLaunchd.isEmpty { parts.append("unreadable=" + drift.unreadableLaunchd.joined(separator: ",")) }
        return parts.joined(separator: " ")
    }

    /// Event first, log line derived from it.
    private func emit(_ name: String, _ detail: String, level: LogLevel) {
        let event = RuntimeEvent(kind: .config, event: name, detail: detail)
        eventSink(event)
        logger?.log(level, "Shell environment: \(event.event) \(event.detail ?? "")", category: .system)
    }
}
