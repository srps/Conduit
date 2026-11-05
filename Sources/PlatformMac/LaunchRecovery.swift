// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Launch-time crash recovery for the platform surfaces a `SIGKILL` can strand,
/// run off the calling actor and joined before anything else touches them.
/// The shared `RuntimeHost` starts one as it is built, and its configless
/// recovery runs one when no host can be built, with the same three calls in
/// the same order.
///
/// Two properties, and the type exists because they pull in opposite directions.
///
/// **It must not run inline.** `SystemDNSManager.restoreIfNeeded` waits up to
/// two seconds for a resolver to answer on `127.0.0.1:53` and then reads
/// `networksetup -getdnsservers` for every service;
/// `SystemProxyManager.restoreIfNeeded` spawns roughly four `networksetup`
/// subprocesses per service before it decides anything. Its caller is a host's
/// `@RuntimeActor` initialiser — for the app, one that runs before the menu bar
/// exists — so run inline that work is several seconds during which the host
/// is on screen nowhere and answering nothing. None of it needs the owner:
/// both managers are `Sendable` and talk only to subprocesses, sockets
/// and the journal file.
///
/// **It must still happen first.** Recovery restores the *previous* session's
/// settings, so it cannot be left to land whenever. A `clear()` arriving after
/// a start's `apply()` puts the crashed session's settings back over the ones
/// the user just asked for; an `apply()` arriving first makes recovery's own
/// probe find our new listener and conclude nothing is orphaned, so the crash
/// it exists to repair goes unrepaired. `join()` is how the ordering the
/// inline version got for free survives the move: every path that touches a
/// platform surface awaits it before doing so.
@RuntimeActor
package final class LaunchRecovery {
    /// Dropped once joined, so the second and later `join()`s cost nothing and
    /// the closure's captures do not outlive the recovery.
    private var task: Task<LaunchRecoveryDecisions, Never>?

    /// Starts `work` on `platformWork`, the caller's blocking-work queue. The
    /// work blocks its thread for seconds, so it must not run on the calling
    /// actor or on the concurrency pool, which every task and actor shares. The
    /// detached task only queues it and waits. When it is queued is not what
    /// orders it: every surface path awaits `join()` first.
    package init(on platformWork: PlatformWork, work: @escaping @Sendable () -> LaunchRecoveryDecisions) {
        task = Task.detached(priority: .utility) { await platformWork.run(work) }
    }

    /// Waits for recovery to finish. Returns immediately once it has. Only the first joiner to resume gets the decisions, so a later
    /// joiner cannot replay them over what that first one has done since.
    @discardableResult
    package func join() async -> LaunchRecoveryDecisions? {
        guard let task else { return nil }
        let decisions = await task.value
        guard self.task != nil else { return nil }
        self.task = nil
        return decisions
    }
}

// MARK: - Outcomes and events

/// What one launch-time recovery step decided, returned by
/// `SystemDNSManager.restoreIfNeeded`, `SystemProxyManager.restoreIfNeeded`
/// and `DNSManager.recoverLegacyOwnership` so the host can emit the event
/// before any log line (`LaunchRecovery.report`).
package enum LaunchRecoveryOutcome: Equatable, Sendable {
    package enum NothingToDo: String, Sendable {
        /// The journal holds no record for the surface: the last run tore down.
        case nothingRecorded = "nothing_recorded"
        /// Resolver files: the journal already settled their ownership.
        case alreadySettled = "already_settled"
        /// Resolver files: no config file before this launch, so no earlier
        /// release could have written any. Settled without a scan.
        case freshInstall = "fresh_install"
        /// Resolver files: the manager runs without a journal.
        case noJournal = "no_journal"
    }

    package enum Skipped: String, Sendable {
        /// The config failed to load, and legacy resolver ownership is
        /// inferred from the configured domains.
        case configUnavailable = "config_unavailable"
        /// The journal cannot be read, so it cannot say what is ours.
        case journalUnreadable = "journal_unreadable"
    }

    package enum RestoreGround: Equatable, Sendable {
        /// The records were over seven days old, so no one was asked who owns them.
        case stale
        case ownerGone(OwnershipEvidence)
    }

    case nothingToDo(NothingToDo)
    /// Recorded prior values put back and the surface released.
    case restored(RestoreGround)
    /// A live listener is serving the settings the records describe (another
    /// session is running), so they were left alone.
    case declinedLiveListener(OwnershipEvidence)
    /// No evidence said who owns the settings: the liveness probe timed out, so
    /// a session may still serve them and only be slow. Left alone. `witness`
    /// is why the helper's relay witness did not decide first, for system DNS.
    case declinedInconclusiveProbe(witness: RelayWitnessGap?)
    /// System DNS: a resolver answers but no interface points at loopback any
    /// more, so the records describe nothing and were dropped without a write.
    case discardedStaleRecords
    /// Resolver files an earlier release wrote, recognised and recorded (and
    /// removed, with the switch off).
    case adoptedLegacyFiles(LegacyResolverAdoption)
    case skipped(Skipped)
    /// The restore threw, or kept records because part of it did not land;
    /// the next launch retries from those records.
    case failed(reason: String)
}

/// Who owns the settings a surface's records describe, as far as OS evidence
/// says. Launch recovery restores only on `ownerGone`.
package enum SurfaceOwnership: Equatable, Sendable {
    case ownerGone(OwnershipEvidence)
    case anotherSessionLive(OwnershipEvidence)
    /// The probe got no answer in time. `witness` is why the helper's relay
    /// witness did not decide first; `nil` for a surface without one.
    case unknown(witness: RelayWitnessGap?)

    package init(probe: LoopbackLiveness, witness: RelayWitnessGap?) {
        switch probe {
        case .notLive: self = .ownerGone(.portRefused)
        case .live: self = .anotherSessionLive(.portAnswered)
        case .inconclusive: self = .unknown(witness: witness)
        }
    }
}

package enum OwnershipEvidence: String, Sendable {
    /// The helper's relay target refused a query twice: no forwarder serves it.
    case relayTargetRefused = "relay_target_refused"
    case relayTargetAnswered = "relay_target_answered"
    case portRefused = "port_refused"
    case portAnswered = "port_answered"
}

/// Why the helper's relay witness did not decide system DNS ownership, so the
/// `:53` probe did.
package enum RelayWitnessGap: String, Sendable {
    /// No helper, or one that predates `dns-relay-status`.
    case noStatus = "no_status"
    /// The helper could not be asked: not reachable, busy, or refusing.
    case helperUnavailable = "helper_unavailable"
    case relayNotRunning = "relay_not_running"
    case targetSilent = "target_silent"
    /// The target refused, but the second reading did not agree.
    case refusalUnconfirmed = "refusal_unconfirmed"
}

/// What launch recovery decided for the two network surfaces.
package struct LaunchRecoveryDecisions: Equatable, Sendable {
    package var systemDNS: LaunchRecoveryOutcome
    package var systemProxy: LaunchRecoveryOutcome

    package init(systemDNS: LaunchRecoveryOutcome, systemProxy: LaunchRecoveryOutcome) {
        self.systemDNS = systemDNS
        self.systemProxy = systemProxy
    }
}

/// What the one-time legacy resolver scan found. `report` is its log line.
package struct LegacyResolverAdoption: Equatable, Sendable {
    package var adopted: [String]
    package var foreign: [String]
    package var unjudged: [String]
    package var removed: Bool
    package var report: String
}

extension LaunchRecovery {
    /// The configuration-dependent input to the legacy resolver scan. The
    /// hosts pass `nil` when the config failed to load: the journal restores
    /// need only the journal, but the scan reads the configured domains.
    package struct LegacyResolverInput: Sendable {
        package var configs: [ProxyConfig]
        package var configFilePredatesLaunch: Bool
        package var resolversManaged: Bool

        package init(configs: [ProxyConfig], configFilePredatesLaunch: Bool, resolversManaged: Bool) {
            self.configs = configs
            self.configFilePredatesLaunch = configFilePredatesLaunch
            self.resolversManaged = resolversManaged
        }
    }

    /// The recovery every host runs, in this order: system DNS, system proxy,
    /// then legacy resolver ownership. Each step's outcome is emitted as an
    /// event and then logged. Blocking: run it through `LaunchRecovery.init`,
    /// or where nothing else is left to wait on.
    @discardableResult
    nonisolated package static func recoverPlatformSurfaces(
        systemDNS: SystemDNSManager,
        systemProxy: SystemProxyManager,
        resolvers: DNSManager?,
        legacyResolvers: LegacyResolverInput?,
        emit: (RuntimeEvent) -> Void,
        logger: (any LogSink)?
    ) -> LaunchRecoveryDecisions {
        let systemDNSOutcome = systemDNS.restoreIfNeeded(logger: logger)
        report(systemDNSOutcome, surface: .systemDNS, emit: emit, logger: logger)
        let systemProxyOutcome = systemProxy.restoreIfNeeded(logger: logger)
        report(systemProxyOutcome, surface: .systemProxy, emit: emit, logger: logger)
        let decisions = LaunchRecoveryDecisions(systemDNS: systemDNSOutcome, systemProxy: systemProxyOutcome)
        guard let legacyResolvers, let resolvers else {
            report(.skipped(.configUnavailable), surface: .resolverFile, emit: emit, logger: logger)
            return decisions
        }
        let outcome = resolvers.recoverLegacyOwnership(
            configs: legacyResolvers.configs,
            configFilePredatesLaunch: legacyResolvers.configFilePredatesLaunch,
            resolversManaged: legacyResolvers.resolversManaged,
            logger: logger
        )
        report(outcome, surface: .resolverFile, emit: emit, logger: logger)
        return decisions
    }

    /// Emits the event for `outcome`, then logs the line derived from it.
    nonisolated package static func report(
        _ outcome: LaunchRecoveryOutcome,
        surface: PlatformSurface,
        emit: (RuntimeEvent) -> Void,
        logger: (any LogSink)?
    ) {
        let event = event(for: outcome, surface: surface)
        emit(event)
        let (level, message) = logLine(for: outcome, surface: surface, event: event)
        logger?.log(level, message, category: .system)
    }

    nonisolated package static func event(for outcome: LaunchRecoveryOutcome, surface: PlatformSurface) -> RuntimeEvent {
        let subject = "surface=\(surface.rawValue)"
        let name: String
        let detail: String
        switch outcome {
        case .nothingToDo(let reason):
            name = "platform.launch_recovery_nothing_to_do"
            detail = "\(subject) reason=\(reason.rawValue)"
        case .restored(.stale):
            name = "platform.launch_recovery_restored"
            detail = "\(subject) stale=true"
        case .restored(.ownerGone(let evidence)):
            name = "platform.launch_recovery_restored"
            detail = "\(subject) stale=false evidence=\(evidence.rawValue)"
        case .declinedLiveListener(let evidence):
            name = "platform.launch_recovery_declined"
            detail = "\(subject) reason=live_listener evidence=\(evidence.rawValue)"
        case .declinedInconclusiveProbe(let witness):
            name = "platform.launch_recovery_declined"
            detail = "\(subject) reason=probe_inconclusive" + (witness.map { " witness=\($0.rawValue)" } ?? "")
        case .discardedStaleRecords:
            name = "platform.launch_recovery_discarded"
            detail = "\(subject) reason=no_interface_points_at_loopback"
        case .adoptedLegacyFiles(let adoption):
            name = "platform.launch_recovery_adopted"
            detail = "\(subject) adopted=\(adoption.adopted.count) removed=\(adoption.removed) "
                + "foreign=\(adoption.foreign.count) unjudged=\(adoption.unjudged.count)"
        case .skipped(let reason):
            name = "platform.launch_recovery_skipped"
            detail = "\(subject) reason=\(reason.rawValue)"
        case .failed(let reason):
            name = "platform.launch_recovery_failed"
            detail = "\(subject) reason=\(reason)"
        }
        return RuntimeEvent(kind: .lifecycle, event: name, detail: detail)
    }

    nonisolated private static func logLine(
        for outcome: LaunchRecoveryOutcome,
        surface: PlatformSurface,
        event: RuntimeEvent
    ) -> (LogLevel, String) {
        let what = "Launch recovery (\(event.detail ?? surface.rawValue))"
        switch outcome {
        case .nothingToDo:
            return (.debug, "\(what): nothing to do.")
        case .restored(.stale):
            return (.warning, "\(what): the recorded state was older than 7 days; restored the previous settings.")
        case .restored(.ownerGone):
            return (.warning, "\(what): found settings recorded by a run that never tore down (likely a crash); restored the previous settings.")
        case .declinedLiveListener:
            return (.debug, "\(what): recorded state exists and a local listener is still serving it; left alone.")
        case .declinedInconclusiveProbe:
            let clearedBy = surface == .systemDNS
                ? "a DNS Start or Stop, a Quit, or a reboot that ends the helper's relay"
                : "a proxy Start or Stop, or a Quit"
            return (.notice, "\(what): recorded state exists and nothing said whether a session still serves it; left alone until \(clearedBy), or a later launch that can tell.")
        case .discardedStaleRecords:
            return (.notice, "\(what): saved state exists but no interface points at 127.0.0.1 any more; dropped the stale records.")
        case .adoptedLegacyFiles(let adoption):
            return (.warning, "\(what): \(adoption.report)")
        case .skipped:
            return (.notice, "\(what): skipped.")
        case .failed:
            return (.error, "\(what): failed; what it could not put back stays recorded for the next launch to retry.")
        }
    }
}
