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

    // Platform side-effect coordinators. Default daemon
    // startup does not apply side effects until `startRuntime()` is called
    // (future control socket command).
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
    private let vpnStatusMonitor: VPNStatusObserving
    private let vpnFlapWindowBox: NIOLockedValueBox<DaemonVPNFlapWindowConfig>
    private var dnsHealthTimer: DispatchSourceTimer?
    /// Whether `startRuntime()` ran (and `stopRuntime()` hasn't). Platform
    /// side-effects (resolver files, system proxy, env vars) only exist in
    /// that window, so VPN transitions and config reloads must not touch
    /// them outside it.
    private var runtimeStarted = false
    /// VPN-gating policy for split-DNS entry files (single source of truth
    /// shared with `AppState`). Fed by `handleVPNStateChange`; every
    /// resolver-file apply path consults `entriesWanted`.
    private var splitDNSGate = SplitDNSVPNGate()

    init(
        environment: RuntimeEnvironment,
        logger: any LogSink,
        loadedConfiguration: RuntimeConfigurationLoadResult,
        vpnStatusMonitor: VPNStatusObserving? = nil,
        privilegeClient: (any PrivilegeClient)? = nil,
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

        let credentialManager = CredentialManager(
            identityProvider: { [snapshotProvider = orchestrator.configSnapshotProvider] in
                let c = snapshotProvider()
                return (domain: c.domain, username: c.username, profileName: c.profileName)
            }
        )
        self.credentialManager = credentialManager

        let authenticatorProvider = credentialBasedAuthenticatorProvider(
            configProvider: orchestrator.configSnapshotProvider,
            credentialProvider: credentialManager,
            outcomeHandler: { [weak orchestrator] outcome, host, reason in
                orchestrator?.reportAuthOutcome(outcome, host: host, reason: reason)
            }
        )
        orchestrator.setAuthenticatorProvider(authenticatorProvider)
        orchestrator.eventLog.setSink { [eventWriter] event in eventWriter.record(event) }
        privilegeAuditSink.set { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }

        orchestrator.onSnapshotChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.writeSnapshotFile(snapshot: snapshot)
            }
        }
        orchestrator.onConfigChange = { [weak self] updatedConfig in
            Task { @MainActor in
                self?.config = updatedConfig
            }
        }
        orchestrator.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(orchestratorEvent: event)
            }
        }
        networkMonitor.onChange = { [weak self] description, _ in
            Task { @MainActor in
                await self?.handleNetworkChange(description: description)
            }
        }
        self.vpnStatusMonitor.setOnChange { [weak self] state in
            Task { @MainActor in
                await self?.handleVPNStateChange(state)
            }
        }
        reconciler.host = self
    }

    func markReady(mode: String) {
        orchestrator.eventLog.append(RuntimeEvent(kind: .lifecycle, event: "daemon.ready", detail: "mode=\(mode)"))
        writeReadyFile()
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        eventWriter.flush()
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

    func startRuntime() async throws {
        logNonBlockingConfigProblems()
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

        if platformConfig.manageSystemProxy {
            do {
                try systemConduit.apply(
                    config: config,
                    mode: platformConfig.systemProxyMode,
                    logger: logger,
                    localPACURL: orchestrator.snapshot.bindings.localPACURL
                )
            } catch {
                logger.log(.warning, "Could not apply system proxy settings (non-fatal): \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageEnvironmentVariables {
            do {
                try environmentManager.apply(config: config, logger: logger)
            } catch {
                logger.log(.warning, "Could not apply environment variables (non-fatal): \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageDNSResolvers {
            do {
                try dnsManager.apply(config: config, logger: logger, vpnConnected: splitDNSGate.entriesWanted)
            } catch {
                logger.log(.warning, "Could not apply DNS resolvers (non-fatal): \(error.localizedDescription)", category: .system)
            }
            // The forwarder cannot be running yet, so no intercept resolver
            // file may exist — sweep any a killed instance stranded. Only a
            // start can repair that; a SIGKILL never runs cleanup.
            do {
                try refreshInterceptFiles(for: config)
            } catch {
                logger.log(.warning, "Could not sweep stale intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
            }
        }

        if config.dnsForwarderEnabled {
            if platformConfig.manageSystemDNS {
                do {
                    try systemDNSManager.saveCurrentDNS(logger: logger)
                } catch {
                    logger.log(.warning, "Could not save current DNS state (non-fatal): \(error.localizedDescription)", category: .system)
                }
            }
            await orchestrator.startDNS()
            if platformConfig.manageSystemDNS, orchestrator.snapshot.dnsRunState == .running {
                let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
                do {
                    try systemDNSManager.apply(forwarderPort: forwarderPort, logger: logger)
                } catch {
                    logger.log(.warning, "Could not set system DNS (non-fatal): \(error.localizedDescription)", category: .system)
                }
                // Whether or not `apply` succeeded — see `AppState.startDNS`.
                startDNSHealthTimer(forwarderPort: forwarderPort)
            }
            // `apply` above wrote the split-DNS entry files only; the intercept
            // files are written here, once the forwarder and the transparent
            // proxy they point clients at are both listening.
            do {
                try refreshInterceptFiles(for: config)
            } catch {
                logger.log(.warning, "Could not apply intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
            }
        }

        if config.tunnelDefinitions.contains(where: \.enabled) {
            await orchestrator.startTunnels()
        }

        networkMonitor.start()
        vpnStatusMonitor.start()
        runtimeStarted = true
        logger.log(.notice, "Daemon runtime started.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
    }

    func stopRuntime(exitAfterStop: Bool = false) async {
        runtimeStarted = false
        stopDNSHealthTimer()
        vpnStatusMonitor.stop()
        networkMonitor.stop()

        if platformConfig.manageSystemDNS || systemDNSManager.hasSavedState() {
            do {
                try systemDNSManager.clear(logger: logger)
            } catch {
                logger.log(.warning, "Could not restore system DNS: \(error.localizedDescription)", category: .system)
            }
        }
        await orchestrator.stopTunnels()
        await orchestrator.stopDNS()
        await orchestrator.stopProxy()

        // Each surface is cleared when its flag is on *or* when the journal
        // says the surface is ours, as in `AppState.stopProxy`. The flag alone
        // skipped the clear whenever the switch had gone off since the
        // surface was applied; the reload reconciles that flip now, so what
        // is left for the guard is the residue: a clear the machine refused,
        // a crash between the flip and the reload, a config file edited by
        // hand (#13).
        if platformConfig.manageSystemProxy || systemConduit.hasManagedState() {
            do {
                try systemConduit.clear(logger: logger)
            } catch {
                logger.log(.warning, "Could not clear system proxy settings: \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageEnvironmentVariables || environmentManager.hasManagedState() {
            do {
                try environmentManager.clear(logger: logger)
            } catch {
                logger.log(.warning, "Could not clear environment variables: \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageDNSResolvers {
            do {
                try dnsManager.clear(config: config, logger: logger)
            } catch {
                logger.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
            }
        } else if dnsManager.hasManagedState() {
            // Switch off: only what the journal names as ours, never a file
            // for a configured domain we did not write.
            do {
                try dnsManager.clearRecorded(configs: [config], logger: logger)
            } catch {
                logger.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
            }
        }

        logger.log(.notice, "Daemon runtime stopped.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        eventWriter.flush()
        if exitAfterStop {
            exit(0)
        }
    }

    func reloadConfiguration() async {
        let loaded = ProxyConfigPersistence.loadAllMigrating(in: environment)
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

    /// The single place that decides whether intercept resolver files may
    /// exist: they do exactly while the DNS forwarder and the transparent
    /// proxy are both listening. Twin of `AppState.refreshInterceptFiles` —
    /// a resolver file outlives this process, so a listener that is down must
    /// mean no file rather than a blackholed domain.
    private func refreshInterceptFiles(for config: ProxyConfig) throws {
        guard platformConfig.manageDNSResolvers else { return }
        guard orchestrator.snapshot.bindings.dnsInterceptReady else {
            // Only a surprise when DNS is supposedly up — see the twin.
            if orchestrator.snapshot.dnsRunState == .running, !config.enabledInterceptRules.isEmpty {
                logger.log(
                    .warning,
                    "DNS forwarder is running but the transparent proxy is not listening — intercept resolver files withheld rather than blackhole \(config.enabledInterceptRules.count) domain(s).",
                    category: .system
                )
            }
            try dnsManager.clearInterceptFiles(config: config, logger: logger)
            return
        }
        try dnsManager.applyInterceptFiles(config: config, logger: logger)
    }

    func testUpstream(named name: String) async -> ProbeResult? {
        await orchestrator.testUpstream(named: name)
    }

    func flushEvents() {
        eventWriter.flush()
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

    private func handleNetworkChange(description: String) async {
        await orchestrator.handleNetworkChange(description: description)
        if platformConfig.manageSystemDNS, orchestrator.snapshot.dnsRunState == .running {
            systemDNSManager.reconcile(logger: logger)
        }
    }

    private func handleVPNStateChange(_ state: VPNObservedState) async {
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

        await orchestrator.handleVPNStateChange(state)
        if platformConfig.manageSystemDNS, orchestrator.snapshot.dnsRunState == .running {
            systemDNSManager.reconcile(logger: logger)
        }
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

    private func handleDNSHealthResult(alive: Bool, forwarderPort: Int) {
        // Twin of `AppState.handleDNSHealthResult`.
        if alive { return }

        logger.log(.warning, "DNS liveness probe failed. Attempting relay restart.", category: .system)
        do {
            try systemDNSManager.startRelay(forwarderPort: forwarderPort, logger: logger)
            if systemDNSManager.probeLiveness() {
                logger.log(.notice, "DNS relay restarted successfully.", category: .system)
                orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "dns.relay_restarted", detail: "source=daemon_health_timer"))
                return
            }
        } catch {
            logger.log(.warning, "DNS relay restart failed: \(error.localizedDescription)", category: .system)
        }

        orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "dns.pipeline_unresponsive", detail: "source=daemon_health_timer"))
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
