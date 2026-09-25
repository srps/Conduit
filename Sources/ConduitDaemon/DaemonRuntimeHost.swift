// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import ConduitShared
import ProxyPAC

private struct DaemonVPNFlapWindowConfig: Sendable {
    var graceSeconds: TimeInterval
    var minVisibleSeconds: TimeInterval
}

private final class DaemonPrivilegeAuditEventSink: @unchecked Sendable {
    private let lock = NSLock()
    private var sink: (@Sendable (RuntimeEvent) -> Void)?

    func set(_ sink: @escaping @Sendable (RuntimeEvent) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        self.sink = sink
    }

    func emit(_ event: RuntimeEvent) {
        let current = lock.withLock { sink }
        current?(event)
    }
}

/// Daemon-owned runtime host.
///
/// This is the production-daemon counterpart to the runtime ownership that
/// still lives in `AppState` as a temporary in-process fallback. Keeping the
/// host in the `ConduitDaemon` target avoids dragging AppKit/SwiftUI into
/// daemon code while still allowing it to link `PlatformMac` (Keychain,
/// CFNetwork PAC, SCDynamicStore, helper XPC, networksetup wrappers).
@MainActor
final class DaemonRuntimeHost {
    let environment: RuntimeEnvironment
    let logger: any LogSink
    let eventWriter: RuntimeEventFileWriter

    private(set) var config: ProxyConfig
    private(set) var platformConfig: PlatformIntegrationConfig
    private(set) var appPreferences: AppPreferences
    private(set) var configGeneration = 0

    let orchestrator: ProxyOrchestrator
    private let credentialManager: CredentialManager
    /// Base client every privileged side effect goes through, wrapped by
    /// `auditedPrivilegeClient`. Injectable so tests can drive the platform
    /// side-effect paths (apply on start, revert on a failed start) without
    /// touching the real system configuration.
    private let privilegeClient: any PrivilegeClient
    private let auditedPrivilegeClient: any PrivilegeClient
    private let privilegeAuditSink = DaemonPrivilegeAuditEventSink()
    /// The subprocess runner behind the `networksetup` and `launchctl`
    /// managers, and the directories they write. Injectable for the same
    /// reason as `privilegeClient`: a host test must not rewrite the machine
    /// it runs on. Same seams as `AppState`.
    private let commandRunner: @Sendable (String, [String]) throws -> CommandResult
    private let homeDirectory: URL
    private let resolverDirectory: String
    /// One serialised pass per config reload: the runtime takes the edit,
    /// the surfaces whose contents changed are re-applied, and each flipped
    /// platform flag applies or clears the surface it names. The same type
    /// the app runs per save, so the daemon has the ownership guard from
    /// #13 rather than a twin of it.
    private let reconciler: RuntimeReconciler

    // Platform side-effect coordinators. Default daemon startup applies
    // nothing until `startRuntime()` is called (future control socket
    // command); what `init` does start is launch recovery, which only hands
    // back what a crashed run left applied.
    /// Prior values of the platform settings we change, so teardown restores
    /// rather than blanket-clearing. Shared by every side-effect manager.
    private lazy var platformStateJournal = PlatformStateJournal(fileURL: environment.platformStateFile, logger: logger)
    private lazy var systemConduit = SystemProxyManager(
        privilegeClient: auditedPrivilegeClient,
        journal: platformStateJournal,
        commandRunner: commandRunner
    )
    private lazy var environmentManager = EnvironmentManager(
        journal: platformStateJournal,
        homeDirectory: homeDirectory,
        commandRunner: commandRunner
    )
    /// With the journal: a resolver file is ours only if we recorded it, and
    /// that record is what lets a stop under a switch that is already off
    /// remove our file and leave one the user keeps by hand for the same
    /// domain (#13).
    private lazy var dnsManager = DNSManager(
        privilegeClient: auditedPrivilegeClient,
        resolverDirectory: resolverDirectory,
        journal: platformStateJournal
    )
    private lazy var systemDNSManager = SystemDNSManager(
        privilegeClient: auditedPrivilegeClient,
        journal: platformStateJournal,
        legacySnapshotFile: environment.legacySavedDNSFile,
        commandRunner: commandRunner
    )
    private let networkMonitor = NetworkMonitor()
    /// The hops from the observers and the orchestrator's callbacks onto the
    /// main actor. Internal so the tests can `drain()` them instead of
    /// sleeping. Same shape as `AppState`.
    let deliveries = ObserverDeliveries()
    /// Blocking platform work that needs no answer on the spot. See
    /// `AppState.platformWork`.
    private let platformWork = PlatformWork(label: "io.github.srps.Conduit.daemon.platform-work")
    private var dnsRelayRestartInFlight = false
    private var dnsReconcileInFlight = false
    private var dnsReconcileWanted = false
    private let vpnStatusMonitor: VPNStatusObserving
    private let vpnFlapWindowBox: NIOLockedValueBox<DaemonVPNFlapWindowConfig>
    private var dnsHealthTimer: DispatchSourceTimer?
    /// Whether `startRuntime()` ran (and `stopRuntime()` hasn't). Platform
    /// side-effects (resolver files, system proxy, env vars) only exist in
    /// that window, so VPN transitions and config reloads must not touch
    /// them outside it.
    private var runtimeStarted = false
    /// `startRuntime` / `stopRuntime`: which is the latest, and a repeat of
    /// the one in flight joins it. See `LifecycleLane`. Twin of
    /// `AppState.proxyLane`.
    private let runtimeLane = LifecycleLane(name: "runtime")
    /// How many starts and stops have begun. Internal so a test can wait for
    /// a stop to have begun rather than time it: the stop's first visible
    /// effect is queued behind the work the test is holding.
    var lifecycleGeneration: Int { runtimeLane.current }
    /// VPN-gating policy for split-DNS entry files (single source of truth
    /// shared with `AppState`). Fed by `handleVPNStateChange`; every
    /// resolver-file apply path consults `entriesWanted`.
    private var splitDNSGate = SplitDNSVPNGate()
    /// Launch-time crash recovery for the system-proxy, system-DNS and
    /// resolver-file surfaces. Started by `init` and joined by
    /// `awaitLaunchRecovery()` — see `LaunchRecovery` for why it is neither
    /// inline nor unordered. Twin of `AppState.launchRecovery`.
    private var launchRecovery: LaunchRecovery?

    /// - Parameters:
    ///   - configFilePredatesLaunch: whether the config file existed before
    ///     `loadedConfiguration` was read. The load writes a migrated or
    ///     default file back, so only the caller that loaded can know; it is
    ///     what tells an upgrade from a fresh install to the resolver-file
    ///     recovery (`DNSManager.recoverLegacyOwnership`). Same read as
    ///     `AppState.init`.
    init(
        environment: RuntimeEnvironment,
        logger: any LogSink,
        loadedConfiguration: RuntimeConfigurationLoadResult,
        configFilePredatesLaunch: Bool,
        vpnStatusMonitor: VPNStatusObserving? = nil,
        privilegeClient: (any PrivilegeClient)? = nil,
        credentialStore: (any SecretStore)? = nil,
        commandRunner: (@Sendable (String, [String]) throws -> CommandResult)? = nil,
        homeDirectory: URL? = nil,
        resolverDirectory: String? = nil
    ) {
        self.environment = environment
        self.logger = logger
        self.config = loadedConfiguration.config
        self.platformConfig = loadedConfiguration.platformConfig
        self.appPreferences = loadedConfiguration.appPreferences
        self.commandRunner = commandRunner ?? { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        }
        self.homeDirectory = homeDirectory ?? FileManager.default.homeDirectoryForCurrentUser
        self.resolverDirectory = resolverDirectory ?? "/etc/resolver"
        self.reconciler = RuntimeReconciler(
            config: loadedConfiguration.config,
            platformConfig: loadedConfiguration.platformConfig
        )
        let flapBox = NIOLockedValueBox(
            DaemonVPNFlapWindowConfig(
                graceSeconds: loadedConfiguration.config.vpnFlapGraceSeconds,
                minVisibleSeconds: loadedConfiguration.config.vpnFlapMinVisibleSeconds
            )
        )
        self.vpnFlapWindowBox = flapBox
        self.privilegeClient = privilegeClient ?? HelperToolPrivilegeClient(
            eventSink: { [privilegeAuditSink] event in privilegeAuditSink.emit(event) }
        )
        self.auditedPrivilegeClient = AuditingPrivilegeClient(
            base: self.privilegeClient,
            eventSink: { [privilegeAuditSink] event in privilegeAuditSink.emit(event) }
        )
        self.eventWriter = RuntimeEventFileWriter(fileURL: environment.eventsFile, logger: logger)
        self.vpnStatusMonitor = vpnStatusMonitor ?? VPNStatusMonitor(
            graceSecondsProvider: { flapBox.withLockedValue { $0.graceSeconds } },
            minVisibleSecondsProvider: { flapBox.withLockedValue { $0.minVisibleSeconds } }
        )

        let pacEvaluator = CFPACEvaluator()
        let tunnelResolverManager = TunnelResolverManager(
            privilegeClient: auditedPrivilegeClient,
            logger: logger
        )
        let orchestrator = ProxyOrchestrator(
            config: loadedConfiguration.config,
            logger: logger,
            privilegeClient: auditedPrivilegeClient,
            authenticatorProvider: nil,
            pacEvaluator: pacEvaluator,
            resolverManager: tunnelResolverManager,
            portHolderProbe: PortHolderProbe()
        )
        self.orchestrator = orchestrator

        // The login Keychain in production. A host over a fake machine
        // injects an in-memory store, or it would read and write the
        // installed app's credentials. Same seam as `AppState`.
        let credentialManager = CredentialManager(
            identityProvider: { [snapshotProvider = orchestrator.configSnapshotProvider] in
                let c = snapshotProvider()
                return (domain: c.domain, username: c.username, profileName: c.profileName)
            },
            store: credentialStore ?? KeychainStore()
        )
        self.credentialManager = credentialManager

        let authenticatorProvider = credentialBasedAuthenticatorProvider(
            configProvider: orchestrator.configSnapshotProvider,
            credentialProvider: credentialManager,
            outcomeHandler: { [weak orchestrator] outcome, host, reason in
                orchestrator?.reportAuthOutcome(outcome, host: host, reason: reason)
            },
            eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }
        )
        orchestrator.setAuthenticatorProvider(authenticatorProvider)
        orchestrator.eventLog.setSink { [eventWriter] event in eventWriter.record(event) }
        privilegeAuditSink.set { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }

        orchestrator.onSnapshotChange = { [weak self, deliveries] snapshot in
            deliveries.deliver {
                self?.writeSnapshotFile(snapshot: snapshot)
            }
        }
        orchestrator.onConfigChange = { [weak self, deliveries] updatedConfig in
            deliveries.deliver {
                self?.config = updatedConfig
            }
        }
        orchestrator.onEvent = { [weak self, deliveries] event in
            deliveries.deliver {
                self?.handle(orchestratorEvent: event)
            }
        }
        networkMonitor.onChange = { [weak self, deliveries] change in
            deliveries.deliver {
                await self?.handleNetworkChange(change)
            }
        }
        // The interface name is read on the monitor's own delivery, not
        // after the hop, so a queued transition cannot lend its tunnel's
        // name to the one delivered before it. Same shape as `AppState`.
        // Weak on both: the monitor stores this closure, so a strong capture
        // of the monitor would keep a stopped host's observer alive forever.
        self.vpnStatusMonitor.setOnChange { [weak self, deliveries, weak monitor = self.vpnStatusMonitor] state in
            let interfaceName = monitor?.connectedInterfaceName
            deliveries.deliver {
                await self?.handleVPNStateChange(state, interfaceName: interfaceName)
            }
        }
        reconciler.host = self

        // Crash recovery, as in `AppState.init`: a run that was `SIGKILL`ed
        // never tore down, so the machine can still point at its dead proxy
        // port and the helper's relay at its dead forwarder, and launch is when
        // the journal's record of what was there before is most likely still
        // the truth. Without this the daemon leaves them until its next start
        // or stop, and in runtime-host mode (no `--start-runtime`) that may be
        // never. Same three calls in the same order, off the main actor.
        //
        // The app skips only the resolver-file ownership inference when its
        // config failed to load; this host is never built from a failed load
        // (`ConduitDaemon.main` runs the journal restores itself and exits,
        // see `recoverWithoutConfiguration`), so the scan always has a config.
        let dnsRecovery = systemDNSManager
        let proxyRecovery = systemConduit
        let resolverRecovery = dnsManager
        let legacyResolvers = LaunchRecovery.LegacyResolverInput(
            configs: [loadedConfiguration.config],
            configFilePredatesLaunch: configFilePredatesLaunch,
            resolversManaged: loadedConfiguration.platformConfig.manageDNSResolvers
        )
        let eventLog = orchestrator.eventLog
        launchRecovery = LaunchRecovery { [logger] in
            LaunchRecovery.recoverPlatformSurfaces(
                systemDNS: dnsRecovery,
                systemProxy: proxyRecovery,
                resolvers: resolverRecovery,
                legacyResolvers: legacyResolvers,
                emit: { eventLog.append($0) },
                logger: logger
            )
        }
    }

    /// Waits for launch-time crash recovery before this host touches a
    /// platform surface. Free after the first call. Twin of
    /// `AppState.awaitLaunchRecovery`, and internal for the same reason: a
    /// test that asserts on what recovery did joins it rather than polls.
    ///
    /// Joined at the head of `startRuntime`, `stopRuntime` and
    /// `reloadConfiguration`. Every other path that touches a surface is
    /// reachable only after one of those has run: the reconciler's passes
    /// are queued by `reloadConfiguration` alone, the network and VPN
    /// monitors and the DNS health timer are started by `startRuntime` (or
    /// by a reload's `.applySystemDNS`), after its join. The VPN handler in
    /// particular must not join: two transitions suspended on the join could
    /// resume out of order, and `SplitDNSVPNGate` acts on the latest one.
    func awaitLaunchRecovery() async {
        await launchRecovery?.join()
        launchRecovery = nil
    }

    /// Publishes readiness: `daemon.ready`, `daemon-ready.json` and a
    /// snapshot. Joins launch recovery first, so readiness never precedes it:
    /// a consumer that acts on `daemon.ready` must not find the machine still
    /// pointed at a crashed run's dead listeners. An await, so the main actor
    /// stays free while recovery runs.
    func markReady(mode: String) async {
        await awaitLaunchRecovery()
        orchestrator.eventLog.append(RuntimeEvent(kind: .lifecycle, event: "daemon.ready", detail: "mode=\(mode)"))
        writeReadyFile()
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        flushEvents()
    }

    func status() -> ControlDaemonStatus {
        var status = ControlDaemonStatus(snapshot: orchestrator.snapshot, config: config)
        status.daemon = ControlDaemonMetadata(
            processID: Int(ProcessInfo.processInfo.processIdentifier),
            executableName: "ConduitDaemon",
            startedAt: ConduitDaemon.startedAt
        )
        status.configGeneration = configGeneration
        return status
    }

    /// The surface work runs on `platformWork` in two blocks, one on each
    /// side of the forwarder start, in the order it always ran: the proxy's
    /// surfaces and the capture of the prior DNS servers, then the forwarder,
    /// then the interfaces pointed at it and the intercept files. Off the
    /// main actor because it is 15 to 30 helper round trips and `networksetup`
    /// reads on a machine with several services (#47). The `runtimeLane` token
    /// is checked after every suspension and, under each manager's lock,
    /// before every manager step; see `LifecycleLane`.
    func startRuntime() async throws {
        await awaitLaunchRecovery()
        logNonBlockingConfigProblems()
        guard let token = await admit(.start, "runtime_start") else { return }
        defer { runtimeLane.end(token) }
        do {
            try await orchestrator.startProxy()
        } catch {
            // A failed start must not leave the machine pointing at listeners
            // that are not there. These side effects outlive the process and
            // are not self-healing — a system PAC setting naming a dead PAC
            // port, or `/etc/resolver` files naming a dead forwarder, break
            // networking for *every* client on the machine, and the only other
            // path that clears them is an explicit stop that nobody is going to
            // issue for a daemon that never came up. `stopRuntime` is
            // idempotent, so this is safe wherever in the sequence we failed.
            logger.log(
                .warning,
                "Runtime start failed (\(error.displayDescription)) — reverting system proxy, environment and DNS resolver settings so they cannot point at listeners that are not running.",
                category: .system
            )
            await stopRuntime()
            throw error
        }
        // A stop issued while the listeners came up has already queued its
        // clears; applying now would put the surfaces back after them.
        guard isCurrent(token, "runtime_start") else { return }

        let config = self.config
        let platform = platformConfig
        let systemProxy = systemConduit
        let environment = environmentManager
        let resolvers = dnsManager
        let systemDNS = systemDNSManager
        let logger = self.logger
        let localPACURL = orchestrator.snapshot.bindings.localPACURL
        let vpnConnected = splitDNSGate.entriesWanted
        let interceptReadyAtStart = orchestrator.snapshot.bindings.dnsInterceptReady
        let forwarderRunningAtStart = orchestrator.snapshot.dnsRunState == .running
        await platformWork.run {
            if platform.manageSystemProxy {
                systemProxy.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try systemProxy.apply(config: config, mode: platform.systemProxyMode, logger: logger, localPACURL: localPACURL)
                    } catch {
                        logger.log(.warning, "Could not apply system proxy settings (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            if platform.manageEnvironmentVariables {
                environment.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try environment.apply(config: config, logger: logger)
                    } catch {
                        logger.log(.warning, "Could not apply environment variables (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            if platform.manageDNSResolvers {
                resolvers.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try resolvers.apply(config: config, logger: logger, vpnConnected: vpnConnected)
                    } catch {
                        logger.log(.warning, "Could not apply DNS resolvers (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                    // The forwarder cannot be running yet, so no intercept resolver
                    // file may exist — sweep any a killed instance stranded. Only a
                    // start can repair that; a SIGKILL never runs cleanup.
                    do {
                        try resolvers.refreshInterceptFiles(
                            config: config,
                            interceptReady: interceptReadyAtStart,
                            forwarderRunning: forwarderRunningAtStart,
                            logger: logger
                        )
                    } catch {
                        logger.log(.warning, "Could not sweep stale intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            if config.dnsForwarderEnabled, platform.manageSystemDNS {
                systemDNS.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try systemDNS.saveCurrentDNS(logger: logger)
                    } catch {
                        logger.log(.warning, "Could not save current DNS state (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
        }
        // A stop issued while the apply was out queued its clears behind
        // it, so the machine ends cleared; what must not happen now is the
        // rest of a start for a runtime that is down.
        guard isCurrent(token, "runtime_start") else { return }
        // A VPN transition handled while the apply was out reconciled the
        // entry files then, possibly before the apply wrote them from the
        // gate it was queued with. Twin of the check in `AppState.startProxy`.
        if platform.manageDNSResolvers, splitDNSGate.entriesWanted != vpnConnected {
            splitDNSGate.reconcileEntryFiles(
                config: config,
                dnsManager: dnsManager,
                logger: logger,
                runtimeStarted: true
            )
        }

        if config.dnsForwarderEnabled {
            await orchestrator.startDNS()
            guard isCurrent(token, "runtime_start") else { return }
            let forwarderRunning = orchestrator.snapshot.dnsRunState == .running
            let interceptReady = orchestrator.snapshot.bindings.dnsInterceptReady
            let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
            await platformWork.run {
                if platform.manageSystemDNS, forwarderRunning {
                    systemDNS.serialized {
                        guard !token.isSuperseded else { return }
                        do {
                            try systemDNS.apply(forwarderPort: forwarderPort, logger: logger)
                        } catch {
                            logger.log(.warning, "Could not set system DNS (non-fatal): \(error.localizedDescription)", category: .system)
                        }
                    }
                }
                // `apply` above wrote the split-DNS entry files only; the intercept
                // files are written here, once the forwarder and the transparent
                // proxy they point clients at are both listening.
                guard platform.manageDNSResolvers else { return }
                resolvers.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try resolvers.refreshInterceptFiles(
                            config: config,
                            interceptReady: interceptReady,
                            forwarderRunning: forwarderRunning,
                            logger: logger
                        )
                    } catch {
                        logger.log(.warning, "Could not apply intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            guard isCurrent(token, "runtime_start") else { return }
            if platform.manageSystemDNS, forwarderRunning {
                // Whether or not `apply` succeeded — see `AppState.startDNS`.
                startDNSHealthTimer(forwarderPort: forwarderPort)
            }
        }

        if config.tunnelDefinitions.contains(where: \.enabled) {
            await orchestrator.startTunnels()
            guard isCurrent(token, "runtime_start") else { return }
        }

        networkMonitor.start()
        vpnStatusMonitor.start()
        runtimeStarted = true
        logger.log(.notice, "Daemon runtime started.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
    }

    /// Joins launch recovery first, the shutdown path included, and this is
    /// where the daemon parts from the app. `AppState.performTerminationCleanup`
    /// does not join because `applicationWillTerminate` is synchronous: waiting
    /// there would block the main thread at quit. Nothing here is synchronous —
    /// `SIGTERM` reaches this through a `Task`, so the join is a suspension
    /// that leaves the main actor free, bounded by recovery's own probe and
    /// subprocesses, well inside launchd's exit timeout. Joining buys what the
    /// app has to argue is safe without: the stop's clears never overlap
    /// recovery's, and `exit(0)` never cuts a restore off half way.
    ///
    /// The surface work runs on `platformWork` in two blocks, one on each side
    /// of the orchestrator stops, so each lands behind the apply of any start
    /// it overtook. A stop overtaken in turn by a later start does nothing
    /// more once it notices, since that start owns the surfaces; except a stop
    /// on the way to `exit`, which always finishes: nothing after it runs.
    /// A stop while a stop is out joins it rather than queueing another
    /// teardown, except, again, the one on the way to `exit`, which must reach
    /// it: it supersedes the one in flight, which then stops at its next step.
    func stopRuntime(exitAfterStop: Bool = false) async {
        await awaitLaunchRecovery()
        guard let token = await admit(.stop, "runtime_stop", coalescing: !exitAfterStop) else { return }
        defer { runtimeLane.end(token) }
        let terminal = exitAfterStop
        runtimeStarted = false
        stopDNSHealthTimer()
        vpnStatusMonitor.stop()
        networkMonitor.stop()

        let config = self.config
        let platform = platformConfig
        let systemProxy = systemConduit
        let environment = environmentManager
        let resolvers = dnsManager
        let systemDNS = systemDNSManager
        let logger = self.logger
        await platformWork.run {
            systemDNS.serialized {
                guard terminal || !token.isSuperseded else { return }
                guard platform.manageSystemDNS || systemDNS.hasSavedState() else { return }
                do {
                    try systemDNS.clear(logger: logger)
                } catch {
                    logger.log(.warning, "Could not restore system DNS: \(error.localizedDescription)", category: .system)
                }
            }
        }
        guard terminal || isCurrent(token, "runtime_stop") else { return }
        await orchestrator.stopTunnels()
        await orchestrator.stopDNS()
        await orchestrator.stopProxy()
        guard terminal || isCurrent(token, "runtime_stop") else { return }

        // Each surface is cleared when its flag is on *or* when the journal
        // says the surface is ours, as in `AppState.stopProxy`. The flag alone
        // skipped the clear whenever the switch had gone off since the
        // surface was applied; the reload reconciles that flip now, so what
        // is left for the guard is the residue: a clear the machine refused,
        // a crash between the flip and the reload, a config file edited by
        // hand (#13). The ownership reads happen inside the block, after
        // whatever was queued ahead of it has landed.
        await platformWork.run {
            systemProxy.serialized {
                guard terminal || !token.isSuperseded else { return }
                guard platform.manageSystemProxy || systemProxy.hasManagedState() else { return }
                do {
                    try systemProxy.clear(logger: logger)
                } catch {
                    logger.log(.warning, "Could not clear system proxy settings: \(error.localizedDescription)", category: .system)
                }
            }
            environment.serialized {
                guard terminal || !token.isSuperseded else { return }
                guard platform.manageEnvironmentVariables || environment.hasManagedState() else { return }
                do {
                    try environment.clear(logger: logger)
                } catch {
                    logger.log(.warning, "Could not clear environment variables: \(error.localizedDescription)", category: .system)
                }
            }
            resolvers.serialized {
                guard terminal || !token.isSuperseded else { return }
                if platform.manageDNSResolvers {
                    do {
                        try resolvers.clear(config: config, logger: logger)
                    } catch {
                        logger.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
                    }
                } else if resolvers.hasManagedState() {
                    // Switch off: only what the journal names as ours, never a file
                    // for a configured domain we did not write.
                    do {
                        try resolvers.clearRecorded(configs: [config], logger: logger)
                    } catch {
                        logger.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
                    }
                }
            }
        }
        guard terminal || isCurrent(token, "runtime_stop") else { return }

        logger.log(.notice, "Daemon runtime stopped.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        flushEvents()
        if exitAfterStop {
            exit(0)
        }
    }

    func reloadConfiguration() async {
        await awaitLaunchRecovery()
        let loaded: RuntimeConfigurationLoadResult
        do {
            loaded = try ProxyConfigPersistence.loadAllMigrating(in: environment, allowMissing: false) { candidate in
                if let problem = candidate.validate().first(where: \.blocksProxyStart) { throw problem }
            }
        } catch {
            let event = RuntimeEvent(kind: .config, event: "config.reload_rejected", detail: error.localizedDescription)
            orchestrator.eventLog.append(event)
            logger.log(.error, event.detail ?? event.event, category: .system)
            return
        }
        for warning in loaded.warnings {
            logger.log(.warning, warning, category: .system)
        }
        config = loaded.config
        platformConfig = loaded.platformConfig
        appPreferences = loaded.appPreferences
        logNonBlockingConfigProblems()
        vpnFlapWindowBox.withLockedValue { window in
            window.graceSeconds = config.vpnFlapGraceSeconds
            window.minVisibleSeconds = config.vpnFlapMinVisibleSeconds
        }
        configGeneration += 1
        // Queued and then awaited: a caller that reloads and then stops must
        // see the machine the reload left, and the control path has no
        // editor to hand back to while the pass runs. What the pass does is
        // the `RuntimeReconcilerHost` conformance below.
        reconciler.reconcile(config: config, platformConfig: platformConfig)
        await reconciler.drain()
        logger.log(.notice, "Daemon configuration reloaded.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
    }

    /// The errors `LocalProxyServer.start` deliberately ignores. A blocking
    /// one surfaces as the start failure itself; a non-blocking one — an
    /// intercept rule whose files will be withheld — surfaced nowhere in this
    /// host, because the GUI's twin (`AppState.saveConfig`) is where the
    /// banner lives. Headless, the log is the banner.
    private func logNonBlockingConfigProblems() {
        for error in config.validate() where !error.blocksProxyStart {
            logger.log(.warning, "Config validation: \(error.localizedDescription)", category: .system)
        }
    }

    /// Intercept resolver files for the reconciler's passes, which still run
    /// on this actor. Twin of `AppState.refreshInterceptFiles`; the rule is
    /// `DNSManager.refreshInterceptFiles`.
    private func refreshInterceptFiles(for config: ProxyConfig) throws {
        guard platformConfig.manageDNSResolvers else { return }
        try dnsManager.refreshInterceptFiles(
            config: config,
            interceptReady: orchestrator.snapshot.bindings.dnsInterceptReady,
            forwarderRunning: orchestrator.snapshot.dnsRunState == .running,
            logger: logger
        )
    }

    /// Admits a start or stop, or joins the identical one in flight and
    /// returns `nil`. Twin of `AppState.admit`.
    private func admit(
        _ kind: LifecycleLane.Kind,
        _ operation: String,
        coalescing: Bool = true
    ) async -> LifecycleLane.Token? {
        switch runtimeLane.begin(kind, coalescing: coalescing) {
        case .run(let token):
            return token
        case .coalesced(let generation):
            recordLifecycle(runtimeLane.coalescedEvent(operation: operation, joining: generation))
            await runtimeLane.join(generation)
            return nil
        }
    }

    /// Whether the start or stop holding `token` may go on. When not, says
    /// so with a `lifecycle.superseded` event. Twin of `AppState.isCurrent`.
    private func isCurrent(_ token: LifecycleLane.Token, _ operation: String) -> Bool {
        guard !token.isSuperseded else {
            recordLifecycle(runtimeLane.supersededEvent(operation: operation, token: token))
            return false
        }
        return true
    }

    /// Event first, log line derived from it.
    private func recordLifecycle(_ event: RuntimeEvent) {
        orchestrator.eventLog.append(event)
        logger.log(.notice, "Lifecycle: \(event.event) \(event.detail ?? "")", category: .general)
    }

    func testUpstream(named name: String) async -> ProbeResult? {
        await orchestrator.testUpstream(named: name)
    }

    func flushEvents() {
        let auditFlushed = orchestrator.auditSink.flush(timeout: 2)
        reportWriterLoss()
        if !eventWriter.flushReportingTimeout(auditFlushed: auditFlushed, eventLog: orchestrator.eventLog) {
            logger.log(.warning, "Observability shutdown flush deadline exceeded.", category: .general)
        }
        logger.flush(timeout: 2)
    }

    private var lastWriterLoss: UInt64 = 0

    private func reportWriterLoss() {
        let statistics = ["events": eventWriter.statistics, "audit": orchestrator.auditSink.statistics,
                          "console": logger.statistics]
        let loss = statistics.values.reduce(UInt64(0)) { $0 &+ $1.droppedRecords &+ $1.failedRecords &+ $1.flushTimeouts }
        guard loss != lastWriterLoss else { return }
        lastWriterLoss = loss
        do {
            let data = try CanonicalJSON.encoder().encode(statistics)
            orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "observability.writer_loss",
                detail: String(decoding: data, as: UTF8.self)))
        } catch {
            logger.log(.warning, "Failed to encode writer statistics: \(error.localizedDescription)", category: .general)
        }
    }

    private func handle(orchestratorEvent event: ProxyOrchestratorEvent) {
        switch event {
        case .proxyRecovered(let activeUpstream):
            logger.log(.notice, "Daemon observed proxy recovery via \(activeUpstream ?? "unknown upstream").", category: .network)
        case .proxyRecoveryFailed(let summary, let authenticationLikely):
            let suffix = authenticationLikely ? " authenticationLikely=true" : ""
            logger.log(.warning, "Daemon observed proxy recovery failure: \(summary)\(suffix)", category: .network)
        }
    }

    private func handleNetworkChange(_ change: NetworkMonitor.PathChange) async {
        await orchestrator.handleNetworkChange(description: change.description, pathSatisfied: change.satisfied)
        await reconcileSystemDNSIfRunning()
    }

    private func handleVPNStateChange(_ state: VPNObservedState, interfaceName: String?) async {
        // Gate update and reconcile must stay on the same side of any await:
        // reconcileEntryFiles reads the gate's current state, and a second
        // VPN transition interleaving at a suspension point would make this
        // handler act on the newer flip instead of its own (the gate's
        // documented contract). Entry files live and die with the tunnel —
        // see `SplitDNSVPNGate`. `runtimeStarted` is passed rather than used
        // as a guard: it gates *applying* files, never removing them, because
        // a runtime that died with its files applied is exactly the case that
        // strands them against unreachable servers.
        let entriesWantedChanged = splitDNSGate.update(state)
        if platformConfig.manageDNSResolvers, entriesWantedChanged {
            splitDNSGate.reconcileEntryFiles(
                config: config,
                dnsManager: dnsManager,
                logger: logger,
                runtimeStarted: runtimeStarted
            )
        }

        await orchestrator.handleVPNStateChange(state, interfaceName: interfaceName)
        await reconcileSystemDNSIfRunning()
    }

    /// Twin of `AppState.runDNSReconcile`, without the debounce: off the main
    /// actor, because it is one `networksetup` read per interface and a
    /// helper round trip for each that drifted. Nothing follows it in either
    /// caller, so the suspension lets nothing in that was not already let in
    /// by the orchestrator call before it.
    ///
    /// One in flight, one wanted. Every path and VPN notification is its own
    /// delivery, and while a helper is held each would otherwise add a pass
    /// to the queue, to drain later as so many stale ones. A trigger that
    /// finds a pass out asks for one more after it, since that pass may have
    /// read the machine before the change behind this trigger.
    private func reconcileSystemDNSIfRunning() async {
        guard systemDNSReconcileIsDue else { return }
        guard !dnsReconcileInFlight else {
            dnsReconcileWanted = true
            return
        }
        dnsReconcileInFlight = true
        defer { dnsReconcileInFlight = false }
        let manager = systemDNSManager
        repeat {
            dnsReconcileWanted = false
            await platformWork.run { [logger] in manager.reconcile(logger: logger) }
        } while dnsReconcileWanted && systemDNSReconcileIsDue
        dnsReconcileWanted = false
    }

    private var systemDNSReconcileIsDue: Bool {
        platformConfig.manageSystemDNS && orchestrator.snapshot.dnsRunState == .running
    }

    private func startDNSHealthTimer(forwarderPort: Int) {
        stopDNSHealthTimer()
        let manager = systemDNSManager
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self, manager] in
            let alive = manager.probeLiveness()
            Task { @MainActor in
                self?.handleDNSHealthResult(alive: alive, forwarderPort: forwarderPort)
            }
        }
        dnsHealthTimer = timer
        timer.resume()
    }

    private func stopDNSHealthTimer() {
        dnsHealthTimer?.cancel()
        dnsHealthTimer = nil
    }

    /// Internal so the host's tests can report a failed probe; the probe
    /// itself asks the real port 53.
    func handleDNSHealthResult(alive: Bool, forwarderPort: Int) {
        // Twin of `AppState.handleDNSHealthResult`: the restart and the probe
        // after it run off the main actor, one at a time.
        if alive { return }
        guard !dnsRelayRestartInFlight else { return }
        dnsRelayRestartInFlight = true

        logger.log(.warning, "DNS liveness probe failed. Attempting relay restart.", category: .system)
        let manager = systemDNSManager
        deliveries.deliver { [weak self, platformWork, logger] in
            let outcome = await platformWork.run {
                manager.restartRelayIfManaged(forwarderPort: forwarderPort, logger: logger)
            }
            self?.finishDNSRelayRestart(outcome)
        }
    }

    private func finishDNSRelayRestart(_ outcome: SystemDNSManager.RelayRestart) {
        dnsRelayRestartInFlight = false
        switch outcome {
        case .notManaged:
            // A stop finished while the restart was out.
            break
        case .restarted:
            orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "dns.relay_restarted", detail: "source=daemon_health_timer"))
        case .unresponsive:
            orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "dns.pipeline_unresponsive", detail: "source=daemon_health_timer"))
        }
    }

    private func writeReadyFile() {
        let readyURL = environment.configDirectory.appendingPathComponent("daemon-ready.json")
        do {
            try FileManager.default.createDirectory(at: readyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.prettyEncoder.encode(status())
            try data.write(to: readyURL, options: .atomic)
        } catch {
            logger.log(.warning, "Failed to write daemon-ready.json: \(error.localizedDescription)", category: .general)
        }
    }

    private func writeSnapshotFile(snapshot: ProxyOrchestratorSnapshot) {
        reportWriterLoss()
        do {
            try FileManager.default.createDirectory(at: environment.snapshotFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.prettyEncoder.encode(snapshot)
            try data.write(to: environment.snapshotFile, options: .atomic)
        } catch {
            logger.log(.warning, "Failed to write snapshot.json: \(error.localizedDescription)", category: .general)
        }
    }

    nonisolated static let prettyEncoder: JSONEncoder = CanonicalJSON.encoder(prettyPrinted: true)
}

// MARK: - Recovery without a configuration

extension DaemonRuntimeHost {
    /// The journal restores for a launch whose config failed to load, run by
    /// `ConduitDaemon.main` before it exits. No host is built from a failed
    /// load, so without this a daemon killed with the system proxy or system
    /// DNS applied, and relaunched over a broken file, left the machine on
    /// the dead run's listeners. The app restores in that case too
    /// (`AppStateHarnessTests.testCorruptConfigStillRestoresJournaledProxyOnLaunch`):
    /// both restores work from the journal's recorded prior values, and only
    /// the legacy resolver scan needs the config, so that one is reported
    /// skipped.
    ///
    /// Events go to `events.ndjson` as a host's would, and are returned for
    /// the tests. The seams are `init`'s.
    @discardableResult
    static func recoverWithoutConfiguration(
        environment: RuntimeEnvironment,
        logger: any LogSink,
        privilegeClient: (any PrivilegeClient)? = nil,
        commandRunner: (@Sendable (String, [String]) throws -> CommandResult)? = nil
    ) async -> [RuntimeEvent] {
        let writer = RuntimeEventFileWriter(fileURL: environment.eventsFile, logger: logger)
        let emitted = NIOLockedValueBox<[RuntimeEvent]>([])
        let emit: @Sendable (RuntimeEvent) -> Void = { event in
            emitted.withLockedValue { $0.append(event) }
            writer.record(event)
        }
        let base = privilegeClient ?? HelperToolPrivilegeClient(eventSink: emit)
        let audited = AuditingPrivilegeClient(base: base, eventSink: emit)
        let runner = commandRunner ?? { launchPath, arguments in
            try CommandRunner.run(launchPath: launchPath, arguments: arguments)
        }
        let journal = PlatformStateJournal(fileURL: environment.platformStateFile, logger: logger)
        let systemDNS = SystemDNSManager(
            privilegeClient: audited,
            journal: journal,
            legacySnapshotFile: environment.legacySavedDNSFile,
            commandRunner: runner
        )
        let systemProxy = SystemProxyManager(privilegeClient: audited, journal: journal, commandRunner: runner)
        let recovery = LaunchRecovery {
            LaunchRecovery.recoverPlatformSurfaces(
                systemDNS: systemDNS,
                systemProxy: systemProxy,
                resolvers: nil,
                legacyResolvers: nil,
                emit: emit,
                logger: logger
            )
        }
        await recovery.join()
        if !writer.flush() {
            logger.log(.warning, "Launch recovery events were not all written to \(environment.eventsFile.path) before the deadline.", category: .general)
        }
        return emitted.withLockedValue { $0 }
    }
}

// MARK: - RuntimeReconcilerHost

/// The daemon's side of a reconcile pass. Each method is the twin of the one
/// in `AppState`, over this host's managers and logger; the rules about what
/// a pass may read live in `RuntimeReconciler`, not here.
extension DaemonRuntimeHost: RuntimeReconcilerHost {
    func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async {
        await orchestrator.applyConfigChange(new, from: old)
    }

    func runtimeState() -> RuntimeReconciler.RuntimeState {
        let snapshot = orchestrator.snapshot
        let proxyIsUp: Bool
        switch snapshot.runtimeStatus.state {
        case .running, .degraded, .recovering: proxyIsUp = true
        default: proxyIsUp = false
        }
        return RuntimeReconciler.RuntimeState(proxyIsUp: proxyIsUp, dnsIsUp: snapshot.dnsRunState == .running)
    }

    /// Pushes a config edit into the applied platform state. The
    /// orchestrator reconciles its own listeners in `applyConfigChange`, but
    /// resolver files, the system proxy and the environment block are written
    /// by this host; without this a reload leaves them describing the old
    /// config (a removed split-DNS entry keeps its `/etc/resolver` file until
    /// the next full stop). Reads `pass.platform` and nothing live, as the
    /// reconciler's contract requires.
    func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass) {
        let old = pass.old
        let new = pass.new
        let platform = pass.platform

        if pass.diff.dnsChanged, platform.manageDNSResolvers, !pass.resolversFollowTheirFlag,
           pass.runtime.proxyIsUp || pass.runtime.dnsIsUp {
            DNSResolverReconciliation.run(
                after: "config reload",
                logger: logger,
                reconcile: {
                    try dnsManager.reconcile(old: old, new: new, logger: logger, vpnConnected: splitDNSGate.entriesWanted)
                },
                // `applyConfigChange` restarted the forwarder if the DNS
                // section changed, possibly onto a different port, and
                // `reconcile` does not rewrite intercept files. Re-point them
                // at the listeners that came back, or remove them if none did.
                // Runs whatever the reconcile did: see
                // `DNSResolverReconciliation`.
                refreshInterceptFiles: {
                    try refreshInterceptFiles(for: new)
                }
            )
        }

        if pass.diff.proxyChanged, pass.runtime.proxyIsUp {
            if platform.manageSystemProxy, !pass.platformActions.contains(.applySystemProxy) {
                do {
                    try systemConduit.apply(
                        config: new,
                        mode: platform.systemProxyMode,
                        logger: logger,
                        localPACURL: orchestrator.snapshot.bindings.localPACURL
                    )
                } catch {
                    logger.log(.warning, "Could not re-apply system proxy after config reload: \(error.localizedDescription)", category: .system)
                }
            }
            if platform.manageEnvironmentVariables, !pass.platformActions.contains(.applyEnvironment) {
                do {
                    try environmentManager.apply(config: new, logger: logger)
                } catch {
                    logger.log(.warning, "Could not re-apply environment variables after config reload: \(error.localizedDescription)", category: .system)
                }
            }
        }
    }

    func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action) {
        orchestrator.eventLog.append(
            RuntimeEvent(kind: .config, event: "config.platform_integration", detail: String(describing: action))
        )
    }

    /// Runs one platform-flag action through the manager the start and stop
    /// paths use, with their warning-not-throw treatment. Returns whether the
    /// action landed, so the reconciler can leave the flag unreconciled for
    /// the next reload to retry.
    func perform(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        platform: PlatformIntegrationConfig
    ) -> Bool {
        func attempt(_ failure: String, _ body: () throws -> Void) -> Bool {
            do {
                try body()
                return true
            } catch {
                logger.log(.warning, "\(failure): \(error.localizedDescription)", category: .system)
                return false
            }
        }

        switch action {
        case .applySystemProxy:
            return attempt("Could not apply system proxy settings after the setting changed") {
                try systemConduit.apply(
                    config: config,
                    mode: platform.systemProxyMode,
                    logger: logger,
                    localPACURL: orchestrator.snapshot.bindings.localPACURL
                )
            }
        case .clearSystemProxy:
            // The managers report a partial teardown by keeping their records,
            // not by throwing, so the journal is the oracle for "landed":
            // records left means the next reload must try again.
            return attempt("Could not clear system proxy after the setting changed") {
                try systemConduit.clear(logger: logger)
            } && !systemConduit.hasManagedState()
        case .applyEnvironment:
            return attempt("Could not apply environment variables after the setting changed") {
                try environmentManager.apply(config: config, logger: logger)
            }
        case .clearEnvironment:
            return attempt("Could not clear environment variables after the setting changed") {
                try environmentManager.clear(logger: logger)
            } && !environmentManager.hasManagedState()
        case .applyResolverEntries:
            if dnsManager.isApplied(config: config, vpnConnected: splitDNSGate.entriesWanted) {
                // The write is skipped; the record must not be. See `adoptAppliedFiles`.
                dnsManager.adoptAppliedFiles(config: config, vpnConnected: splitDNSGate.entriesWanted)
                logger.log(.debug, "DNS resolvers already configured correctly, skipped.", category: .system)
                return true
            }
            return attempt("Could not apply DNS resolvers after the setting changed") {
                try dnsManager.apply(config: config, logger: logger, vpnConnected: splitDNSGate.entriesWanted)
            }
        case .refreshInterceptFiles:
            return attempt("Could not apply intercept resolver files after the setting changed") {
                try refreshInterceptFiles(for: config)
            }
        case .clearResolvers:
            // Only what the journal names as ours. The switch is off now, so
            // a file for a configured domain we never wrote is the user's.
            return attempt("Could not clear DNS resolvers after the setting changed") {
                try dnsManager.clearRecorded(configs: [previousConfig, config], logger: logger)
            } && !dnsManager.hasManagedState()
        case .applySystemDNS:
            // The same three steps as `startRuntime`, in the same order: the
            // prior state is captured before the interfaces are pointed at
            // the relay, and the health timer runs whether or not the apply
            // succeeded, because its relay restart is the retry.
            let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
            let saved = attempt("Could not save current DNS state (non-fatal)") {
                try systemDNSManager.saveCurrentDNS(logger: logger)
            }
            let applied = attempt("Could not set system DNS after the setting changed") {
                try systemDNSManager.apply(forwarderPort: forwarderPort, logger: logger)
            }
            startDNSHealthTimer(forwarderPort: forwarderPort)
            return saved && applied
        case .clearSystemDNS:
            // Timer first: left running, its 30 s probe would restart the
            // relay the user just asked to remove.
            stopDNSHealthTimer()
            return attempt("Could not restore system DNS after the setting changed") {
                try systemDNSManager.clear(logger: logger)
            } && !systemDNSManager.hasSavedState()
        case .setLaunchAtLogin:
            // The login item is the app's `SMAppService` registration. A
            // LaunchDaemon has none to keep, so the flag reconciles by being
            // ignored here; the app applies it when it next runs.
            return true
        }
    }
}

private extension ProxyOrchestratorBindings {
    var localPACURL: String? {
        guard let host = localPACHost, let port = localPACPort else { return nil }
        return "http://\(host):\(port)/proxy.pac"
    }
}
