// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

/// The writer authority one runtime process holds for its canonical state root
/// (decisions 0017, 0020 and 0028).
///
/// Only `StateRootBootstrap.acquire` makes one, so no owner can hold a root's
/// writable files without its lease. The session keeps the lease until it is
/// released or dropped, and the lease closes then. A production owner keeps its
/// session until the process exits: the app and the daemon each pin theirs in a
/// process-lifetime slot, so no host or view model dropping early gives up the
/// root while the process runs.
///
/// The session's `environment` names the resolved targets. A writer uses those
/// paths, so a symbolic link is written through and kept, never replaced. The
/// environment is not write authority by itself: a writer takes its paths from a
/// session it was built with.
package final class StateRootSession: Sendable {
    /// The four authoritative files, each at its resolved target.
    package let plan: StateRootPlan
    /// The runtime environment over the resolved targets. Its directory is the
    /// canonical root. The snapshot, event and log paths are the requested ones,
    /// since they are diagnostic destinations and not authority.
    package let environment: RuntimeEnvironment
    /// Whether the configuration file existed before this process held the root.
    /// It is read under the lease, before a load or migration can write the file,
    /// and it tells an upgrade from a fresh install (`LaunchRecovery`).
    package let configFilePredatesLaunch: Bool
    /// The writer lease's file, as a neutral URL: a diagnostic guard refuses it as a protected destination, so
    /// an alias cannot write the lock. Only the URL is exposed. The lease object stays private, and holding
    /// this URL grants no write authority.
    package let writerLeaseFile: URL
    private let lease: StateWriterLease

    fileprivate init(
        plan: StateRootPlan,
        environment: RuntimeEnvironment,
        configFilePredatesLaunch: Bool,
        lease: StateWriterLease
    ) {
        self.plan = plan
        self.environment = environment
        self.configFilePredatesLaunch = configFilePredatesLaunch
        self.writerLeaseFile = URL(
            fileURLWithPath: plan.root.path + "/" + StateRootReservedName.writerLock.fileName
        )
        self.lease = lease
    }

    /// Ends this process's authority over the root. Only tests call it, after
    /// their owned work has quiesced. Internal, so only a `@testable` import
    /// reaches it and no production target can give up the root.
    func releaseForTesting() -> StateWriterRelease {
        lease.release()
    }

    /// The resolved file of one configuration component. The map is exhaustive, so a component added to `ConfigurationComponent` does not
    /// compile until it names its file.
    package func configurationFile(for component: ConfigurationComponent) -> StateRootFile {
        switch component {
        case .runtime: plan.config
        case .platform: plan.platformConfig
        case .preferences: plan.preferences
        }
    }

    /// One conditional, verified replacement of a component's resolved file (decisions 0015, 0021 and 0027). It delegates to
    /// `VerifiedConfigurationFileReplacement.replace` under this session's lease. The caller supplies the component, the staged bytes and the
    /// baseline it authorizes, and never a path or a lease. It is synchronous, so the store runs it on `PlatformWork`.
    package func replaceConfigurationFile(
        _ component: ConfigurationComponent,
        staged: Data,
        expecting baseline: ConfigurationFileBaseline,
        access: any StateFileAccessing
    ) -> ConfigurationFileReplacementOutcome {
        VerifiedConfigurationFileReplacement.replace(
            staged, at: configurationFile(for: component), under: lease, access: access, expecting: baseline
        )
    }
}

/// Why a process did not take its state root (decisions 0017 and 0028). Each
/// case is an explicit startup refusal, and none carries an owner or a value.
package enum StateRootAcquisitionFailure: Error, Equatable, Sendable {
    /// Another process holds this root's writer authority. Nothing under the root
    /// was read, migrated, seeded or recovered by this process.
    case busy
    case leaseFailed(StateWriterFailure)
    case refused(StateRootFailure)
}

/// Acquires one state root's writer authority, then resolves its layout under
/// that authority (decisions 0017, 0020 and 0028).
///
/// The order is fixed, and the entry points rely on it. A pure name check runs
/// first and touches nothing, so a refused name leaves no directory and no lock
/// file. The only change to the root before the lease is held is the creation of
/// a missing root and its missing ancestors, owner-only and outermost first. The
/// lease comes next. No file under the root is read, created or chmod'ed before it
/// is held. The layout is resolved under the lease, the configuration's prior
/// existence is taken, and the session is built. A refusal drops the lease, which
/// closes it and reports a failed close through `onReleaseFailure`. Nothing above
/// the root is loaded, migrated, seeded or recovered on a refusal.
///
/// Blocking. Run it on `PlatformWork`, never on the MainActor.
package enum StateRootBootstrap {
    package static func acquire(
        _ environment: RuntimeEnvironment,
        createRootIfMissing: Bool,
        fileSystem: any StateRootFileSystem,
        leasing: any StateWriterLeasing,
        onReleaseFailure: @escaping @Sendable (StateWriterReleaseFailure) -> Void
    ) -> Result<StateRootSession, StateRootAcquisitionFailure> {
        do {
            try StateRootLayout.preflightWritableNames(environment)
        } catch {
            return .failure(.refused(error))
        }
        let root: CanonicalStateRoot
        do {
            root = try StateRootLayout.prepareRoot(
                environment.configDirectory.path, createIfMissing: createRootIfMissing, fileSystem: fileSystem
            )
        } catch {
            return .failure(.refused(error))
        }
        // The root directory's identity before the lease and again after the layout. A replacement at the
        // same path between them is refused. This is a check, not a compare-and-swap: a retarget after the
        // last check is not excluded.
        let rootBefore: StateRootFileIdentity?
        do {
            rootBefore = try fileSystem.identity(at: root.path)
        } catch {
            return .failure(.refused(.rootUnavailable(errno: error.errno)))
        }
        let lease: StateWriterLease
        switch leasing.acquire(root: root, onReleaseFailure: onReleaseFailure) {
        case .acquired(let held):
            lease = held
        case .busy:
            return .failure(.busy)
        case .failed(let failure):
            return .failure(.leaseFailed(failure))
        }
        // Every refusal below returns and drops `lease`, so its destructor closes it.
        let plan: StateRootPlan
        do {
            plan = try StateRootLayout.resolve(environment, configAccess: .writerOwned, fileSystem: fileSystem)
        } catch {
            return .failure(.refused(error))
        }
        let rootAfter: StateRootFileIdentity?
        do {
            rootAfter = try fileSystem.identity(at: root.path)
        } catch {
            return .failure(.refused(.rootUnavailable(errno: error.errno)))
        }
        guard plan.root == root, rootBefore != nil, rootAfter == rootBefore else {
            return .failure(.refused(.rootChanged))
        }
        let predates: Bool
        do {
            predates = try fileSystem.entryKind(at: plan.config.path) != .missing
        } catch {
            return .failure(.refused(.pathUnavailable(.config, errno: error.errno)))
        }
        return .success(StateRootSession(
            plan: plan,
            environment: resolvedEnvironment(environment, plan: plan),
            configFilePredatesLaunch: predates,
            lease: lease
        ))
    }

    /// The requested environment with its four authoritative paths replaced by
    /// the resolved targets, and its directory replaced by the canonical root.
    private static func resolvedEnvironment(_ requested: RuntimeEnvironment, plan: StateRootPlan) -> RuntimeEnvironment {
        RuntimeEnvironment(
            configDirectory: URL(fileURLWithPath: plan.root.path, isDirectory: true),
            configFile: URL(fileURLWithPath: plan.config.path),
            platformStateFile: URL(fileURLWithPath: plan.journal.path),
            exportDefaultFile: requested.exportDefaultFile,
            platformConfigFile: URL(fileURLWithPath: plan.platformConfig.path),
            preferencesFile: URL(fileURLWithPath: plan.preferences.path),
            snapshotFile: requested.snapshotFile,
            eventsFile: requested.eventsFile,
            logFile: requested.logFile
        )
    }
}

extension StateRootAcquisitionFailure {
    /// The refusal as a `config.*` event (decision 0017). The entry point prints
    /// its detail before it exits, so no line is written that the event does not
    /// name. The detail carries fixed codes only: no owner, no path and no value.
    package var event: RuntimeEvent {
        switch self {
        case .busy:
            RuntimeEvent(
                kind: .config,
                event: "config.state_root_busy",
                detail: "state_root=busy: another Conduit process holds this state directory. This process attempted no configuration load, migration, seed or recovery; quit that instance and start again."
            )
        case .leaseFailed(let failure):
            RuntimeEvent(kind: .config, event: "config.state_root_refused", detail: "reason=\(failure.code)")
        case .refused(let failure):
            RuntimeEvent(kind: .config, event: "config.state_root_refused", detail: failure.detail)
        }
    }
}

extension StateWriterReleaseFailure {
    /// A lease that was dropped without an explicit release, and whose close
    /// could not be confirmed. The lock may still be held, so the entry point
    /// reports it rather than discarding it (decision 0017).
    package var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: "config.state_root_release_failed", detail: "reason=lease_close_failed errno=\(errno)")
    }
}

extension StateRootAcquisitionFailure {
    /// The exit status of a process that did not take its root. Busy is
    /// `EX_TEMPFAIL`: the other owner may finish, and nothing was changed.
    package var exitStatus: Int32 {
        switch self {
        case .busy: EX_TEMPFAIL
        case .leaseFailed: EX_IOERR
        case .refused: EX_CONFIG
        }
    }
}

extension StateWriterFailure {
    fileprivate var code: String {
        switch self {
        case .lockOpenFailed(let errno): "lease_open_failed errno=\(errno)"
        case .lockFailed(let errno): "lease_failed errno=\(errno)"
        case .lockNotRegularFile: "lease_not_regular_file"
        case .lockReplaced: "lease_replaced"
        case .statFailed(let errno): "lease_stat_failed errno=\(errno)"
        case .closeFailed(let errno): "lease_close_failed errno=\(errno)"
        }
    }
}

extension StateRootFailure {
    /// The fixed-code detail of this refusal. A refusal of a writer-owned name
    /// also says what the fixed name is, and that nothing was copied.
    fileprivate var detail: String {
        switch self {
        case .rootMissing: "reason=root_missing"
        case .rootUnavailable(let errno): "reason=root_unavailable errno=\(errno)"
        case .rootNotDirectory: "reason=root_not_directory"
        case .rootIsFilesystemRoot: "reason=root_is_filesystem_root"
        case .invalidName(let role): "reason=invalid_name role=\(role.code)"
        case .parentUnavailable(let role, let errno): "reason=parent_unavailable role=\(role.code) errno=\(errno)"
        case .pathUnavailable(let role, let errno): "reason=path_unavailable role=\(role.code) errno=\(errno)"
        case .notRegularFile(let role): "reason=not_regular_file role=\(role.code)"
        case .outsideRoot(let role): "reason=outside_root role=\(role.code)"
        case .unsupportedFileName(let role):
            "reason=unsupported_file_name role=\(role.code) slot=\(role.fixedLeaf): move or rename the file to that name beneath the state directory and start again. Nothing was copied or imported."
        case .rootChanged: "reason=root_changed"
        case .reservedName(let role, let reserved): "reason=reserved_name role=\(role.code) resource=\(reserved.fileName)"
        case .overlap(let first, let second): "reason=overlap roles=\(first.code),\(second.code)"
        case .caseSensitivityUnavailable(let errno): "reason=case_unavailable errno=\(errno)"
        case .caseSensitivityUnknown: "reason=case_unknown"
        }
    }
}

extension StateRootRole {
    fileprivate var code: String {
        switch self {
        case .config: "config"
        case .platformConfig: "platform_config"
        case .preferences: "preferences"
        case .journal: "journal"
        }
    }
}
