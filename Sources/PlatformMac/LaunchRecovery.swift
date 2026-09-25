// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// Launch-time crash recovery for the platform surfaces a `SIGKILL` can strand,
/// run off the calling actor and joined before anything else touches them.
/// Both runtime hosts start one in their initialiser — `AppState` and
/// `DaemonRuntimeHost` — with the same three calls in the same order.
///
/// Two properties, and the type exists because they pull in opposite directions.
///
/// **It must not run inline.** `SystemDNSManager.restoreIfNeeded` waits up to
/// two seconds for a resolver to answer on `127.0.0.1:53` and then reads
/// `networksetup -getdnsservers` for every service;
/// `SystemProxyManager.restoreIfNeeded` spawns roughly four `networksetup`
/// subprocesses per service before it decides anything. Its caller is a host's
/// `@MainActor` initialiser — for the app, one that runs before the menu bar
/// exists — so run inline that work is several seconds during which the host
/// is on screen nowhere and answering nothing. None of it needs the main
/// actor: both managers are `Sendable` and talk only to subprocesses, sockets
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
@MainActor
package final class LaunchRecovery {
    /// Dropped once joined, so the second and later `join()`s cost nothing and
    /// the closure's captures do not outlive the recovery.
    private var task: Task<Void, Never>?

    /// Starts `work` immediately on a detached background task.
    ///
    /// Detached rather than `Task { }`: a plain `Task` created in a `@MainActor`
    /// context inherits that isolation and would run the whole thing back on the
    /// main actor, which is the freeze this type exists to remove.
    package init(work: @escaping @Sendable () -> Void) {
        task = Task.detached(priority: .utility, operation: work)
    }

    /// Waits for recovery to finish. Returns immediately once it has.
    package func join() async {
        guard let task else { return }
        await task.value
        self.task = nil
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

    case nothingToDo(NothingToDo)
    /// Recorded prior values put back and the surface released. `stale`:
    /// the records were over seven days old and were restored without a probe.
    case restored(stale: Bool)
    /// A live listener is serving the settings the records describe (another
    /// session is running), so they were left alone.
    case declinedLiveListener
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
    nonisolated package static func recoverPlatformSurfaces(
        systemDNS: SystemDNSManager,
        systemProxy: SystemProxyManager,
        resolvers: DNSManager?,
        legacyResolvers: LegacyResolverInput?,
        emit: (RuntimeEvent) -> Void,
        logger: (any LogSink)?
    ) {
        report(systemDNS.restoreIfNeeded(logger: logger), surface: .systemDNS, emit: emit, logger: logger)
        report(systemProxy.restoreIfNeeded(logger: logger), surface: .systemProxy, emit: emit, logger: logger)
        guard let legacyResolvers, let resolvers else {
            report(.skipped(.configUnavailable), surface: .resolverFile, emit: emit, logger: logger)
            return
        }
        let outcome = resolvers.recoverLegacyOwnership(
            configs: legacyResolvers.configs,
            configFilePredatesLaunch: legacyResolvers.configFilePredatesLaunch,
            resolversManaged: legacyResolvers.resolversManaged,
            logger: logger
        )
        report(outcome, surface: .resolverFile, emit: emit, logger: logger)
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
        case .restored(let stale):
            name = "platform.launch_recovery_restored"
            detail = "\(subject) stale=\(stale)"
        case .declinedLiveListener:
            name = "platform.launch_recovery_declined"
            detail = "\(subject) reason=live_listener"
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
        case .restored(let stale):
            return (.warning, stale
                ? "\(what): the recorded state was older than 7 days; restored the previous settings."
                : "\(what): found settings recorded by a run that never tore down (likely a crash); restored the previous settings.")
        case .declinedLiveListener:
            return (.debug, "\(what): recorded state exists and a local listener is still serving it; left alone.")
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
