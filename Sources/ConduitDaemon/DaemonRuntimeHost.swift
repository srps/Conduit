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
    private let privilegeClient: HelperToolPrivilegeClient
    private let auditedPrivilegeClient: any PrivilegeClient
    private let privilegeAuditSink = DaemonPrivilegeAuditEventSink()

    // Platform side-effect coordinators. Default daemon
    // startup does not apply side effects until `startRuntime()` is called
    // (future control socket command).
    private lazy var systemConduit = SystemProxyManager(privilegeClient: auditedPrivilegeClient)
    private lazy var environmentManager = EnvironmentManager()
    private lazy var dnsManager = DNSManager(privilegeClient: auditedPrivilegeClient)
    private lazy var systemDNSManager = SystemDNSManager(
        savedDNSFile: environment.savedDNSFile,
        privilegeClient: auditedPrivilegeClient
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
        vpnStatusMonitor: VPNStatusObserving? = nil
    ) {
        self.environment = environment
        self.logger = logger
        self.config = loadedConfiguration.config
        self.platformConfig = loadedConfiguration.platformConfig
        self.appPreferences = loadedConfiguration.appPreferences
        let flapBox = NIOLockedValueBox(
            DaemonVPNFlapWindowConfig(
                graceSeconds: loadedConfiguration.config.vpnFlapGraceSeconds,
                minVisibleSeconds: loadedConfiguration.config.vpnFlapMinVisibleSeconds
            )
        )
        self.vpnFlapWindowBox = flapBox
        self.privilegeClient = HelperToolPrivilegeClient()
        self.auditedPrivilegeClient = AuditingPrivilegeClient(
            base: privilegeClient,
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
            resolverManager: tunnelResolverManager
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
        try await orchestrator.startProxy()

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
                do {
                    try systemDNSManager.apply(
                        forwarderPort: orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort,
                        logger: logger
                    )
                    startDNSHealthTimer(forwarderPort: orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort)
                } catch {
                    logger.log(.warning, "Could not set system DNS (non-fatal): \(error.localizedDescription)", category: .system)
                }
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

        if platformConfig.manageSystemProxy {
            do {
                try systemConduit.clear(logger: logger)
            } catch {
                logger.log(.warning, "Could not clear system proxy settings: \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageEnvironmentVariables {
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
        }

        logger.log(.notice, "Daemon runtime stopped.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        eventWriter.flush()
        if exitAfterStop {
            exit(0)
        }
    }

    func reloadConfiguration() async {
        let oldConfig = config
        let loaded = ProxyConfigPersistence.loadAllMigrating(in: environment)
        for warning in loaded.warnings {
            logger.log(.warning, warning, category: .system)
        }
        config = loaded.config
        platformConfig = loaded.platformConfig
        appPreferences = loaded.appPreferences
        vpnFlapWindowBox.withLockedValue { window in
            window.graceSeconds = config.vpnFlapGraceSeconds
            window.minVisibleSeconds = config.vpnFlapMinVisibleSeconds
        }
        configGeneration += 1
        await orchestrator.applyConfigChange(config)
        reconcilePlatformSideEffects(old: oldConfig, new: config)
        logger.log(.notice, "Daemon configuration reloaded.", category: .general)
        writeSnapshotFile(snapshot: orchestrator.snapshot)
    }

    /// Push config edits into the applied platform state. The orchestrator
    /// reconciles its own listeners via `applyConfigChange`, but resolver
    /// files, system proxy, and env vars are written by this host — without
    /// this, a daemon config reload leaves them describing the old config
    /// (e.g. a removed split-DNS entry keeps its /etc/resolver file until
    /// the next full stop). Twin of `AppState.reconcileRuntimeConfig`.
    private func reconcilePlatformSideEffects(old: ProxyConfig, new: ProxyConfig) {
        guard runtimeStarted, old != new else { return }
        let diff = ConfigDiff(old: old, new: new)

        if diff.dnsChanged, platformConfig.manageDNSResolvers {
            do {
                try dnsManager.reconcile(old: old, new: new, logger: logger, vpnConnected: splitDNSGate.entriesWanted)
            } catch {
                logger.log(.warning, "Could not reconcile DNS resolver files after config reload: \(error.localizedDescription)", category: .system)
            }
        }

        if diff.proxyChanged {
            if platformConfig.manageSystemProxy {
                do {
                    try systemConduit.apply(
                        config: new,
                        mode: platformConfig.systemProxyMode,
                        logger: logger,
                        localPACURL: orchestrator.snapshot.bindings.localPACURL
                    )
                } catch {
                    logger.log(.warning, "Could not re-apply system proxy after config reload: \(error.localizedDescription)", category: .system)
                }
            }
            if platformConfig.manageEnvironmentVariables {
                do {
                    try environmentManager.apply(config: new, logger: logger)
                } catch {
                    logger.log(.warning, "Could not re-apply environment variables after config reload: \(error.localizedDescription)", category: .system)
                }
            }
        }
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
        let entriesWantedChanged = splitDNSGate.update(state)

        await orchestrator.handleVPNStateChange(state)
        if platformConfig.manageSystemDNS, orchestrator.snapshot.dnsRunState == .running {
            systemDNSManager.reconcile(logger: logger)
        }

        // Entry files live and die with the tunnel (see `SplitDNSVPNGate`).
        // Only touch them inside the start/stop window — outside it no
        // platform side-effects exist to reconcile.
        guard platformConfig.manageDNSResolvers, entriesWantedChanged, runtimeStarted else { return }
        splitDNSGate.reconcileEntryFiles(config: config, dnsManager: dnsManager, logger: logger)
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

private extension ProxyOrchestratorBindings {
    var localPACURL: String? {
        guard let host = localPACHost, let port = localPACPort else { return nil }
        return "http://\(host):\(port)/proxy.pac"
    }
}
