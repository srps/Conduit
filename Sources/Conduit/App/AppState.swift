// SPDX-License-Identifier: Apache-2.0
import AppKit
import PlatformMac
import ProxyAuth
import ProxyKernel
import ProxyPAC
import Combine
import Foundation
import NIOConcurrencyHelpers
import SwiftUI

/// Thread-safe mirror of the two `vpnFlap*Seconds` config fields the
/// `VPNStatusMonitor` reads from its `monitorQueue` callback context. The
/// AppState `$config` Combine sink writes to this box on every config edit so
/// Settings-driven slider changes propagate to the next flap without
/// recreating the monitor. Mirrors the `configBox` pattern used by
/// `ProxyOrchestrator` for the same cross-isolation-context reason.
private struct VPNFlapWindowConfig: Sendable {
    var graceSeconds: TimeInterval
    var minVisibleSeconds: TimeInterval
}

private final class PrivilegeAuditEventSink: @unchecked Sendable {
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

@MainActor
final class AppState: ObservableObject {
    @Published var config: ProxyConfig
    @Published var platformConfig: PlatformIntegrationConfig
    @Published var appPreferences: AppPreferences
    @Published var isShowingSettings = false
    @Published var isShowingLogs = false
    @Published var isShowingOnboarding = false
    @Published var lastErrorMessage: String?
    @Published private(set) var activationPreflight: ActivationPreflight = .noAdmin
    @Published private(set) var helperStatusState: HelperToolPrivilegeClient.Status = .notInstalled

    let runtime = RuntimePresentationAdapter()

    let logStore: AppLogStore
    let credentialManager: CredentialManager
    let privilegeClient: HelperToolPrivilegeClient
    private let auditedPrivilegeClient: any PrivilegeClient
    private let runtimeEnvironment: RuntimeEnvironment
    private let orchestrator: ProxyOrchestrator

    private lazy var systemConduit = SystemProxyManager(privilegeClient: auditedPrivilegeClient)
    private lazy var environmentManager = EnvironmentManager()
    private lazy var dnsManager = DNSManager(privilegeClient: auditedPrivilegeClient)
    private lazy var systemDNSManager = SystemDNSManager(
        savedDNSFile: runtimeEnvironment.savedDNSFile,
        privilegeClient: auditedPrivilegeClient
    )
    private let loginItemManager = LoginItemManager()
    private let networkMonitor = NetworkMonitor()
    private let vpnStatusMonitor: VPNStatusObserving
    private let vpnFlapWindowBox: NIOLockedValueBox<VPNFlapWindowConfig>
    // AppState's configBox + $config mirror sink were dropped.
    // The auth factory now reads from `orchestrator.configSnapshotProvider`
    // (single source of truth for the live config); AppState's writes flow
    // back through `orchestrator.config = newConfig` (Combine sink below).
    /// Active PAC evaluator. `CFPACEvaluator` is the sole production backend
    /// after removing the JavaScriptCore resolver.
    /// The orchestrator and the Settings "Test PAC URL" preview share this
    /// single instance — no risk of the test page taking a different path
    /// than the live routing decisions.
    private let pacEvaluator: any PacEvaluator
    private let notificationManager = NotificationManager()
    private var cancellables: Set<AnyCancellable> = []
    private var preflightRefreshID = UUID()
    private var dnsReconcileWork: DispatchWorkItem?
    private var dnsHealthTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    /// Snapshot of the config the running subsystems were last reconciled
    /// against. `saveConfig()` diffs the current config against this to drive
    /// `orchestrator.applyConfigChange(_:from:)` + platform side-effects
    /// (resolver files, system proxy, env vars) — the `$config` sink can't be
    /// used for that because it mirrors every keystroke into
    /// `orchestrator.config`, which would make an internally-derived diff
    /// permanently empty. Lifecycle toggles that mutate config themselves
    /// (start/stopDNS) update this snapshot directly so their own save
    /// doesn't re-trigger the subsystem they just started or stopped.
    private var lastReconciledConfig: ProxyConfig
    /// VPN-gating policy for split-DNS entry files (single source of truth
    /// shared with `DaemonRuntimeHost`). Fed by `handleVPNStateChange`;
    /// every resolver-file apply path consults `entriesWanted`.
    private var splitDNSGate = SplitDNSVPNGate()

    init(vpnStatusMonitor: VPNStatusObserving? = nil) {
        let runtimeEnvironment = AppState.runtimeEnvironment()
        let logStore = AppLogStore()
        let loadedConfiguration = ProxyConfigPersistence.loadAllMigrating(in: runtimeEnvironment)
        for warning in loadedConfiguration.warnings {
            logStore.log(.warning, warning, category: .system)
        }
        if loadedConfiguration.migrated {
            logStore.log(.notice, "Configuration files migrated to the current schema.", category: .system)
        }
        let initialConfig = loadedConfiguration.config
        let privilegeClient = HelperToolPrivilegeClient()
        let privilegeAuditEventSink = PrivilegeAuditEventSink()
        let auditedPrivilegeClient = AuditingPrivilegeClient(
            base: privilegeClient,
            eventSink: { event in privilegeAuditEventSink.emit(event) }
        )
        self.runtimeEnvironment = runtimeEnvironment
        self.logStore = logStore
        self.privilegeClient = privilegeClient
        self.auditedPrivilegeClient = auditedPrivilegeClient
        self.config = initialConfig
        self.lastReconciledConfig = initialConfig
        self.platformConfig = loadedConfiguration.platformConfig
        self.appPreferences = loadedConfiguration.appPreferences
        // Mirror the two flap-window values into a thread-safe box so the
        // monitor's monitorQueue callback context can read them without
        // hopping back to MainActor on every utun event. The `$config` sink
        // below keeps the box current as Settings sliders edit the values.
        let flapBox = NIOLockedValueBox(
            VPNFlapWindowConfig(
                graceSeconds: initialConfig.vpnFlapGraceSeconds,
                minVisibleSeconds: initialConfig.vpnFlapMinVisibleSeconds
            )
        )
        self.vpnFlapWindowBox = flapBox
        // Default monitor reads the current grace + min-visible windows lazily
        // from the box on every flap, so Settings changes take effect without
        // restarting the monitor. Tests / pm-sim can inject a
        // FakeVPNStatusObserver via the parameter to bypass SCDynamicStore.
        self.vpnStatusMonitor = vpnStatusMonitor
            ?? VPNStatusMonitor(
                graceSecondsProvider: { flapBox.withLockedValue { $0.graceSeconds } },
                minVisibleSecondsProvider: { flapBox.withLockedValue { $0.minVisibleSeconds } }
            )
        // The orchestrator no longer constructs its own PAC evaluator
        // (concretes live in the ProxyPAC target).
        // AppState owns the concrete evaluator both for the orchestrator's
        // PAC routing path AND for the Settings "Test PAC URL" flow below —
        // one instance, two callers.
        //
        // The `insecureFetcher:` injection point lets AppState (which
        // links `PlatformMac`) provide a curl-backed fallback for plaintext
        // PAC URLs that ATS would otherwise block — preserves today's
        // corporate-network behaviour without re-introducing a kernel-side
        // `Process()` shellout.
        //
        let pacEvaluator = AppState.makePACEvaluator(
            insecureFetcher: AppState.curlPACFetcher
        )
        logStore.log(.notice, "PAC: using CFNetwork evaluator.", category: .pac)
        self.pacEvaluator = pacEvaluator

        // Construct orchestrator BEFORE the auth factory + credential
        // manager so they can capture `orchestrator.configSnapshotProvider`.
        // Single source of truth for the live config replaces the former
        // AppState `configBox` mirror + `$config` Combine sink.
        let auditSink = AppState.makeAuditSink(
            for: initialConfig,
            environment: runtimeEnvironment,
            logger: logStore
        )
        let tunnelResolverManager = TunnelResolverManager(
            privilegeClient: auditedPrivilegeClient,
            logger: logStore
        )
        let orchestrator = ProxyOrchestrator(
            config: initialConfig,
            logger: logStore,
            privilegeClient: auditedPrivilegeClient,
            authenticatorProvider: nil,  // Wired below via setAuthenticatorProvider.
            pacEvaluator: pacEvaluator,
            auditSink: auditSink,
            resolverManager: tunnelResolverManager
        )
        self.orchestrator = orchestrator
        let eventLog = orchestrator.eventLog
        privilegeAuditEventSink.set { event in eventLog.append(event) }

        // CredentialManager's identity-provider reads from the orchestrator's
        // snapshot — same source as the auth factory. Active config drives
        // the Keychain account key (`domain|username|profileName`).
        let credentialManager = CredentialManager(
            identityProvider: { [snapshotProvider = orchestrator.configSnapshotProvider] in
                let c = snapshotProvider()
                return (domain: c.domain, username: c.username, profileName: c.profileName)
            }
        )
        self.credentialManager = credentialManager

        // Wire the auth factory now that the orchestrator exists. The
        // closure captures `orchestrator.configSnapshotProvider` directly —
        // no second NIOLockedValueBox in AppState.
        let authenticatorProvider = credentialBasedAuthenticatorProvider(
            configProvider: orchestrator.configSnapshotProvider,
            credentialProvider: credentialManager,
            outcomeHandler: { [weak orchestrator] outcome, host, reason in
                orchestrator?.reportAuthOutcome(outcome, host: host, reason: reason)
            }
        )
        orchestrator.setAuthenticatorProvider(authenticatorProvider)

        if let portArg = AppState.parsePortArgument() {
            self.config.localPort = portArg
        }
        if AppState.hasFlag("--no-system-proxy") {
            self.platformConfig.manageSystemProxy = false
        }
        if AppState.hasFlag("--no-env") {
            self.platformConfig.manageEnvironmentVariables = false
        }
        orchestrator.config = config
        orchestrator.onSnapshotChange = { [weak self] snapshot in
            Task { @MainActor in
                self?.runtime.apply(snapshot: snapshot)
            }
        }
        orchestrator.onConfigChange = { [weak self] updatedConfig in
            Task { @MainActor in
                guard let self, self.config != updatedConfig else { return }
                self.config = updatedConfig
                // Orchestrator-originated changes are already live in the
                // runtime — record them as reconciled so the next saveConfig
                // doesn't re-apply them.
                self.lastReconciledConfig = updatedConfig
            }
        }
        orchestrator.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(orchestratorEvent: event)
            }
        }
        runtime.apply(snapshot: orchestrator.snapshot)

        networkMonitor.onChange = { [weak self] description, _ in
            Task { @MainActor in
                self?.handleNetworkChange(description: description)
            }
        }
        self.vpnStatusMonitor.setOnChange { [weak self] state in
            Task { @MainActor in
                self?.handleVPNStateChange(state)
            }
        }
        $config
            .sink { [weak self] config in
                guard let self else { return }
                self.orchestrator.config = config
                // Mirror the two flap-window fields into the cross-thread box so
                // the monitor's next link-down/grace timer reads the freshest
                // user-edited values.
                self.vpnFlapWindowBox.withLockedValue { window in
                    window.graceSeconds = config.vpnFlapGraceSeconds
                    window.minVisibleSeconds = config.vpnFlapMinVisibleSeconds
                }
                // AppState no longer maintains its own configBox; the
                // orchestrator's `config` setter is the single write point
                // and feeds `orchestrator.configSnapshotProvider` (which
                // the auth factory captured at AppState init). Kept this
                // Combine sink for the vpnFlapWindowBox mirror above.
            }
            .store(in: &cancellables)
        $config
            .map(\.verboseLogging)
            .removeDuplicates()
            .sink { [weak self] verbose in
                self?.logStore.minStderrLevel = verbose ? .debug : .notice
                self?.logStore.minBufferedLevel = verbose ? .debug : .notice
            }
            .store(in: &cancellables)
        logStore.minStderrLevel = config.verboseLogging ? .debug : .notice
        logStore.minBufferedLevel = config.verboseLogging ? .debug : .notice
        notificationManager.requestAuthorization()
        networkMonitor.start()
        self.vpnStatusMonitor.start()
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.handleSystemWake() }
        }
        systemDNSManager.restoreIfNeeded(logger: logStore)
        isShowingOnboarding = config.authMode == .ntlmv2 && !credentialManager.hasSavedCredentials(for: config)
        refreshPreflight()
    }

    private static func parsePortArgument() -> Int? {
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--port"), idx + 1 < args.count, let port = Int(args[idx + 1]) {
            return port
        }
        return nil
    }

    /// Constructs the PAC evaluator backend.
    /// Internal-test-visibility (`package`) so `PACEvaluatorSettingsTests`
    /// can pin the wiring contract without standing up the full AppState
    /// (which touches Keychain, NSWorkspace, NWPathMonitor, etc.).
    /// `CFPACEvaluator` is now the only production implementation.
    package nonisolated static func makePACEvaluator(
        insecureFetcher: @Sendable @escaping (URL) async throws -> String
    ) -> any PacEvaluator {
        CFPACEvaluator(insecureFetcher: insecureFetcher)
    }

    /// Construct the connection audit sink the orchestrator should emit
    /// per-connection records to. Honours `LoggingSection.auditLogEnabled`:
    /// when off (the default), returns the no-op `DiscardingConnectionAuditSink`
    /// so the orchestrator's emit funnel is harmless. When on, anchors the
    /// `FileConnectionAuditSink` at `auditLogPath` (or
    /// `$state-dir/audit.ndjson` if no override) with `auditLogMaxBytes`.
    ///
    /// Hot-reload caveat: the sink is captured
    /// at orchestrator construction, so toggling the audit toggle in
    /// Settings requires a daemon restart to re-resolve. Acceptable
    /// because audit is itself a deploy-time config
    /// decision, not something flipped per session. A subsequent
    /// reload-aware path can swap the sink behind a `NIOLockedValueBox`.
    private nonisolated static func makeAuditSink(
        for config: ProxyConfig,
        environment: RuntimeEnvironment,
        logger: any LogSink
    ) -> any ConnectionAuditSink {
        guard config.auditLogEnabled else {
            return DiscardingConnectionAuditSink()
        }
        let url: URL
        if let path = config.auditLogPath, !path.isEmpty {
            url = URL(fileURLWithPath: path)
        } else {
            url = environment.configDirectory.appendingPathComponent("audit.ndjson")
        }
        return FileConnectionAuditSink(
            fileURL: url,
            maxBytes: config.auditLogMaxBytes,
            logger: logger
        )
    }

    /// Plaintext-URL PAC fetcher for `CFPACEvaluator.init(insecureFetcher:)`.
    /// This logic previously lived inside the old resolver's curl fallback
    /// (which imported `CommandRunner` from `ConduitCore`).
    /// `CommandRunner` now lives in `PlatformMac`; `ProxyPAC` can no longer
    /// shell out, so the app target provides the closure. Headless daemons
    /// (`pm-proxy`, `pm-tunnel`) use the kernel default that throws, relying
    /// on a TLS-capable PAC URL instead.
    @Sendable
    private static func curlPACFetcher(_ url: URL) async throws -> String {
        guard url.user == nil, url.password == nil else {
            throw PACResolverError.fetchFailed("PAC URLs must not contain embedded credentials.")
        }
        return try await Task.detached(priority: .utility) {
            let result = try CommandRunner.run(
                launchPath: "/usr/bin/curl",
                arguments: [
                    "--silent",
                    "--show-error",
                    "--location",
                    "--fail",
                    "--max-time", "15",
                    url.absoluteString,
                ]
            )
            guard result.exitCode == 0 else {
                let message = [result.standardError, result.standardOutput]
                    .filter { !$0.isEmpty }
                    .joined(separator: " | ")
                throw PACResolverError.fetchFailed(
                    message.isEmpty ? "curl exited with code \(result.exitCode)." : message
                )
            }
            return result.standardOutput
        }.value
    }

    private static func hasFlag(_ flag: String) -> Bool {
        CommandLine.arguments.contains(flag)
    }

    private static func runtimeEnvironment() -> RuntimeEnvironment {
        if let override = ProcessInfo.processInfo.environment["PM_CONFIG_DIR"],
           !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .isolated(stateDirectory: URL(fileURLWithPath: override, isDirectory: true))
        }
        return .userDefault()
    }

    // MARK: - Config

    func saveConfig() {
        do {
            try ProxyConfigPersistence.save(config, in: runtimeEnvironment)
            try PlatformConfigPersistence.save(platformConfig, in: runtimeEnvironment)
            try AppPreferencesPersistence.save(appPreferences, in: runtimeEnvironment)
            logStore.log(.debug, "Saved configuration.")
        } catch {
            lastErrorMessage = error.localizedDescription
            logStore.log(.warning, "Failed to save configuration: \(error.localizedDescription)")
        }
        reconcileRuntimeConfig()
        // Surface validation problems at edit time instead of at the next
        // proxy (re)start, where LocalProxyServer would reject the config
        // long after the user closed Settings. The save itself is not
        // blocked: the runtime re-validates at start, and refusing to
        // persist would silently discard the user's edits.
        let validationErrors = config.validate()
        if let first = validationErrors.first {
            let summary = validationErrors.count > 1
                ? "\(first.localizedDescription) (+\(validationErrors.count - 1) more)"
                : first.localizedDescription
            lastErrorMessage = "Configuration problem: \(summary)"
            for error in validationErrors {
                logStore.log(.warning, "Config validation: \(error.localizedDescription)")
            }
        }
        refreshPreflight()
    }

    /// Push config edits into the running subsystems. Historically the GUI
    /// only persisted edits to disk and the runtime kept the old values until
    /// the next full restart (the daemon path always called
    /// `applyConfigChange`; the app never did). Runs after every save; no-ops
    /// when nothing changed since the last reconcile.
    private func reconcileRuntimeConfig() {
        let old = lastReconciledConfig
        let new = config
        guard old != new else { return }
        lastReconciledConfig = new
        let diff = ConfigDiff(old: old, new: new)

        Task { @MainActor in
            await orchestrator.applyConfigChange(new, from: old)

            let proxyIsUp: Bool
            switch runtime.runtimeStatus.state {
            case .running, .degraded, .recovering: proxyIsUp = true
            default: proxyIsUp = false
            }

            if diff.dnsChanged, platformConfig.manageDNSResolvers,
               proxyIsUp || runtime.dnsRunState == .running {
                do {
                    try dnsManager.reconcile(old: old, new: new, logger: logStore, vpnConnected: splitDNSGate.entriesWanted)
                    // `applyConfigChange` above restarted the forwarder if the
                    // DNS section changed, possibly onto a different port, and
                    // `reconcile` does not rewrite intercept files. Re-point
                    // them at the listeners that came back — or remove them if
                    // none did.
                    try refreshInterceptFiles(for: new)
                } catch {
                    logStore.log(.warning, "Could not reconcile DNS resolver files after config change: \(error.localizedDescription)", category: .system)
                }
            }

            if diff.proxyChanged, proxyIsUp {
                if platformConfig.manageSystemProxy {
                    do {
                        try systemConduit.apply(
                            config: new,
                            mode: platformConfig.systemProxyMode,
                            logger: logStore,
                            localPACURL: orchestrator.snapshot.bindings.localPACURL
                        )
                    } catch {
                        logStore.log(.warning, "Could not re-apply system proxy after config change: \(error.localizedDescription)", category: .system)
                    }
                }
                if platformConfig.manageEnvironmentVariables {
                    do {
                        try environmentManager.apply(config: new, logger: logStore)
                    } catch {
                        logStore.log(.warning, "Could not re-apply environment variables after config change: \(error.localizedDescription)", category: .system)
                    }
                }
            }
        }
    }

    func importConfiguration(from url: URL) throws {
        let data = try Data(contentsOf: url)
        config = try JSONDecoder().decode(ProxyConfig.self, from: data)
        saveConfig()
    }

    func exportConfiguration(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    // MARK: - Credentials

    func savePassword(_ password: String) {
        do {
            // `NTLMAuth.ntHash` lives in `ProxyAuth`, so the
            // NTLMv2 hash is computed here (the app links `ProxyAuth`)
            // rather than inside `CredentialManager` (which is kernel-
            // bound and no longer links CommonCrypto).
            //
            // `NTLMAuth.ntHash(for:)` returns
            // `SecretBytes`; the hash is opaque from the moment it's
            // computed. The only plaintext-String entry in the
            // credential pipeline is the `password` parameter here —
            // that's an unavoidable SwiftUI `SecureField` boundary.
            // We let ARC release the `String` immediately after this
            // method returns; no long-lived copy escapes.
            let hash: SecretBytes = try NTLMAuth.ntHash(for: password)
            try credentialManager.saveHash(hash, for: config)
            isShowingOnboarding = false
            logStore.log(.notice, "Saved proxy credentials to Keychain.", category: .auth)
        } catch {
            lastErrorMessage = error.localizedDescription
            logStore.log(.error, "Could not save credentials: \(error.localizedDescription)", category: .auth)
        }
    }

    func clearCredentials() {
        do {
            try credentialManager.clear(for: config)
            isShowingOnboarding = true
            logStore.log(.notice, "Cleared saved credentials.", category: .auth)
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Proxy Lifecycle

    func toggleProxy() {
        guard runtime.runtimeStatus.state != .starting else { return }
        Task {
            if runtime.runtimeStatus.state == .running || runtime.runtimeStatus.state == .degraded || runtime.runtimeStatus.state == .recovering {
                await stopProxy()
            } else {
                try? await startProxy()
            }
            refreshPreflight()
        }
    }

    func restartProxy() {
        guard runtime.runtimeStatus.state != .starting else { return }
        Task {
            await restartProxyLifecycle()
            refreshPreflight()
        }
    }

    private func restartProxyLifecycle() async {
        lastErrorMessage = nil
        let shouldStopFirst = MenuBarPresentation.shouldStopBeforeRestart(for: runtime.runtimeStatus.state)

        if shouldStopFirst {
            logStore.log(.notice, "Restarting proxy runtime from menu bar.", category: .proxy)
            await stopProxy(postNotification: false)
        }

        do {
            try await startProxy(postNotification: false)
            notificationManager.post(title: "Proxy Restarted", body: runtime.runtimeStatus.activeUpstream ?? "Local proxy is running.")
        } catch {
            lastErrorMessage = error.localizedDescription
            notificationManager.post(title: "Proxy Restart Failed", body: error.localizedDescription)
        }
    }

    func startProxy() async throws {
        try await startProxy(postNotification: true)
    }

    private func startProxy(postNotification: Bool) async throws {
        guard runtime.runtimeStatus.state != .starting && runtime.runtimeStatus.state != .running else { return }

        do {
            try await orchestrator.startProxy()

            if platformConfig.manageSystemProxy {
                let localPACURL = orchestrator.snapshot.bindings.localPACURL
                if systemConduit.isApplied(config: config, mode: platformConfig.systemProxyMode, localPACURL: localPACURL) {
                    logStore.log(.debug, "System proxy already configured correctly, skipped.", category: .system)
                } else {
                    do {
                        try systemConduit.apply(
                            config: config,
                            mode: platformConfig.systemProxyMode,
                            logger: logStore,
                            localPACURL: localPACURL
                        )
                    } catch {
                        logStore.log(.warning, "Could not apply system proxy settings (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
            }
            if platformConfig.manageEnvironmentVariables {
                do {
                    try environmentManager.apply(config: config, logger: logStore)
                } catch {
                    logStore.log(.warning, "Could not apply environment variables (non-fatal): \(error.localizedDescription)", category: .system)
                }
            }
            if platformConfig.manageDNSResolvers {
                if dnsManager.isApplied(config: config, vpnConnected: splitDNSGate.entriesWanted) {
                    logStore.log(.debug, "DNS resolvers already configured correctly, skipped.", category: .system)
                } else {
                    do {
                        try dnsManager.apply(config: config, logger: logStore, vpnConnected: splitDNSGate.entriesWanted)
                    } catch {
                        logStore.log(.warning, "Could not apply DNS resolvers (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                }
                // The DNS forwarder cannot be running yet, so no intercept
                // resolver file may exist — sweep any that a previous instance
                // left behind. Termination cleanup removes them on a clean
                // quit, but a `SIGKILL` (an installer replacing the app, a
                // crash) never runs it, and the files it strands blackhole
                // their domains for every process on the machine until
                // someone deletes them by hand. Only a *start* can be trusted
                // to repair that, so repair it here.
                do {
                    try refreshInterceptFiles(for: config)
                } catch {
                    logStore.log(.warning, "Could not sweep stale intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
                }
            }
            loginItemManager.setEnabled(platformConfig.launchAtLogin, logger: logStore)

            saveConfig()
            if postNotification {
                notificationManager.post(title: "Proxy Enabled", body: runtime.runtimeStatus.activeUpstream ?? "Local proxy is running.")
            }
        } catch {
            if postNotification {
                notificationManager.post(title: "Proxy Start Failed", body: error.localizedDescription)
            }
            throw error
        }
    }

    func stopProxy() async {
        await stopProxy(postNotification: true)
    }

    private func stopProxy(postNotification: Bool) async {
        await orchestrator.stopProxy()

        if platformConfig.manageSystemProxy {
            if systemConduit.isCleared() {
                logStore.log(.debug, "System proxy already cleared, skipped.", category: .system)
            } else {
                do {
                    try systemConduit.clear(logger: logStore)
                } catch {
                    logStore.log(.warning, "Could not clear system proxy: \(error.localizedDescription)", category: .system)
                }
            }
        }
        if platformConfig.manageEnvironmentVariables {
            do {
                try environmentManager.clear(logger: logStore)
            } catch {
                logStore.log(.warning, "Could not clear environment variables: \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageDNSResolvers {
            if dnsManager.isCleared(config: config) {
                logStore.log(.debug, "DNS resolvers already cleared, skipped.", category: .system)
            } else {
                do {
                    try dnsManager.clear(config: config, logger: logStore)
                } catch {
                    logStore.log(.warning, "Could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
                }
            }
        }

        if postNotification {
            notificationManager.post(title: "Proxy Disabled", body: "System proxy settings have been cleared.")
        }
    }

    // MARK: - DNS Lifecycle

    func toggleDNS() {
        Task {
            if runtime.dnsRunState == .running {
                await stopDNS()
            } else if runtime.dnsRunState != .starting {
                await startDNS()
            }
        }
    }

    /// The single place that decides whether intercept resolver files may
    /// exist: they do exactly while the DNS forwarder and the transparent
    /// proxy are both listening. A file that outlives its listeners turns
    /// every intercepted domain into ENOTFOUND (forwarder down) or a refused
    /// connection (transparent proxy down) for every process on the machine,
    /// and `/etc/resolver` survives our exit — so err toward removing them.
    private func refreshInterceptFiles(for config: ProxyConfig) throws {
        guard platformConfig.manageDNSResolvers else { return }
        guard runtime.bindings.dnsInterceptReady else {
            // Only a surprise when DNS is supposedly up: at proxy start the
            // forwarder has not been asked to bind yet, so "not ready" is the
            // expected state and this pass exists purely to sweep strays.
            if runtime.dnsRunState == .running, !config.enabledInterceptRules.isEmpty {
                logStore.log(
                    .warning,
                    "DNS forwarder is running but the transparent proxy is not listening — intercept resolver files withheld rather than blackhole \(config.enabledInterceptRules.count) domain(s).",
                    category: .system
                )
            }
            try dnsManager.clearInterceptFiles(config: config, logger: logStore)
            return
        }
        try dnsManager.applyInterceptFiles(config: config, logger: logStore)
    }

    func startDNS() async {
        if platformConfig.manageSystemDNS {
            do {
                try systemDNSManager.saveCurrentDNS(logger: logStore)
            } catch {
                logStore.log(.warning, "Could not save current DNS state (non-fatal): \(error.localizedDescription)", category: .system)
            }
        }

        await orchestrator.startDNS()

        if runtime.dnsRunState == .running {
            config.dnsForwarderEnabled = true
            if platformConfig.manageSystemDNS {
                do {
                    try systemDNSManager.apply(forwarderPort: effectiveDNSForwarderPort, logger: logStore)
                    startDNSHealthTimer()
                } catch {
                    logStore.log(.warning, "Could not set system DNS (non-fatal): \(error.localizedDescription)", category: .system)
                }
            }
            // Intercept resolver files are written only from here — `apply` at
            // proxy start deliberately skips them, because at that point the
            // forwarder they name has not bound.
            do {
                try refreshInterceptFiles(for: config)
            } catch {
                logStore.log(.warning, "Could not apply intercept resolver files (non-fatal): \(error.localizedDescription)", category: .system)
            }
            // The flag flip above is our own lifecycle work, not a settings
            // edit — absorb it so the save below doesn't restart the
            // forwarder we just started.
            lastReconciledConfig = config
            saveConfig()
        } else if let err = runtime.dnsError {
            notificationManager.post(title: "DNS Forwarder Failed", body: err)
            if platformConfig.manageSystemDNS {
                try? systemDNSManager.clear(logger: logStore)
            }
        }
    }

    func stopDNS() async {
        stopDNSHealthTimer()

        if platformConfig.manageSystemDNS || systemDNSManager.hasSavedState() {
            do {
                try systemDNSManager.clear(logger: logStore)
            } catch {
                logStore.log(.warning, "Could not restore system DNS: \(error.localizedDescription)", category: .system)
            }
        }

        await orchestrator.stopDNS()

        // Remove intercept resolver files while we still can compute their
        // set — leaving them behind strands e.g. `*.cursor.sh` pointing at a
        // forwarder that no longer listens, which surfaces as ENOTFOUND /
        // dead lookups in every client that resolved through them.
        if platformConfig.manageDNSResolvers {
            do {
                try dnsManager.clearInterceptFiles(config: config, logger: logStore)
            } catch {
                logStore.log(.warning, "Could not remove intercept resolver files: \(error.localizedDescription)", category: .system)
            }
        }

        config.dnsForwarderEnabled = false
        // Lifecycle flip, not a settings edit — see startDNS.
        lastReconciledConfig = config
        saveConfig()
    }

    // MARK: - Tunnels Lifecycle

    func toggleTunnels() {
        Task {
            if runtime.tunnelsRunState == .running {
                await stopTunnels()
            } else if runtime.tunnelsRunState != .starting {
                await startTunnels()
            }
        }
    }

    func startTunnels() async {
        await orchestrator.startTunnels()

        if runtime.tunnelsRunState == .failed {
            notificationManager.post(title: "Tunnels Failed", body: runtime.tunnelsError ?? "All tunnel listeners failed to bind.")
        } else if runtime.tunnelsRunState == .running, let err = runtime.tunnelsError {
            notificationManager.post(title: "Tunnels Partially Started", body: err)
        }
        saveConfig()
    }

    func stopTunnels() async {
        await orchestrator.stopTunnels()
        saveConfig()
    }

    // MARK: - DNS Health & Diagnostics

    private func startDNSHealthTimer() {
        stopDNSHealthTimer()
        let manager = systemDNSManager
        dnsHealthTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            DispatchQueue.global(qos: .utility).async {
                let alive = manager.probeLiveness()
                Task { @MainActor in
                    self?.handleDNSHealthResult(alive: alive)
                }
            }
        }
    }

    private func stopDNSHealthTimer() {
        dnsHealthTimer?.invalidate()
        dnsHealthTimer = nil
    }

    private func handleDNSHealthResult(alive: Bool) {
        if alive {
            if runtime.dnsRunState == .failed {
                runtime.applyDNSHealthOverride(runState: .running, error: nil)
                logStore.log(.notice, "DNS pipeline recovered.", category: .system)
            }
            return
        }

        logStore.log(.warning, "DNS liveness probe failed. Attempting relay restart.", category: .system)
        do {
            try systemDNSManager.startRelay(forwarderPort: effectiveDNSForwarderPort, logger: logStore)
            if systemDNSManager.probeLiveness() {
                logStore.log(.notice, "DNS relay restarted successfully.", category: .system)
                return
            }
        } catch {
            logStore.log(.warning, "DNS relay restart failed: \(error.localizedDescription)", category: .system)
        }

        runtime.applyDNSHealthOverride(runState: nil, error: "DNS pipeline unresponsive")
        notificationManager.post(title: "DNS Forwarder Degraded", body: "The DNS relay is not responding. DNS resolution may fail.")
    }

    func testDNS() {
        let manager = systemDNSManager
        let logger = logStore
        let port = platformConfig.manageSystemDNS ? 53 : effectiveDNSForwarderPort
        DispatchQueue.global(qos: .userInitiated).async {
            logger.log(.notice, "DNS test: probing 127.0.0.1:\(port)...", category: .system)
            let alive = manager.probeLiveness(port: port)
            if alive {
                logger.log(.notice, "DNS test: PASS — received response from relay/forwarder pipeline.", category: .system)
            } else {
                logger.log(.warning, "DNS test: FAIL — no response from 127.0.0.1:\(port) within 2s.", category: .system)
            }
        }
    }

    private var effectiveDNSForwarderPort: Int {
        runtime.bindings.dnsPort ?? config.dnsForwarderPort
    }

    private func handle(orchestratorEvent event: ProxyOrchestratorEvent) {
        switch event {
        case .proxyRecovered(let activeUpstream):
            notificationManager.post(title: "Proxy Recovered", body: activeUpstream ?? "Connectivity restored.")
        case .proxyRecoveryFailed(let summary, let authenticationLikely):
            if authenticationLikely {
                notificationManager.post(title: "Authentication Failed", body: "Your proxy credentials may be stale. Re-enter your password in Settings.")
            } else {
                notificationManager.post(title: "Proxy Recovery Failed", body: summary)
            }
        }
    }

    // MARK: - Preflight

    func refreshPreflight() {
        let isRunning = runtime.runtimeStatus.state == .running
            || runtime.runtimeStatus.state == .degraded
            || runtime.runtimeStatus.state == .recovering
        let configSnapshot = config
        let platformConfigSnapshot = platformConfig
        let refreshID = UUID()
        preflightRefreshID = refreshID
        let privilegeClient = self.privilegeClient
        let systemConduit = self.systemConduit
        let dnsManager = self.dnsManager
        let vpnConnected = splitDNSGate.entriesWanted

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let helperStatus = privilegeClient.status
            let preflight = ActivationPreflightEvaluator.evaluate(
                config: configSnapshot,
                platformConfig: platformConfigSnapshot,
                isRunning: isRunning,
                helperStatus: helperStatus,
                systemConduit: systemConduit,
                dnsManager: dnsManager,
                vpnConnected: vpnConnected
            )
            Task { @MainActor [weak self] in
                guard let self, self.preflightRefreshID == refreshID else { return }
                self.helperStatusState = helperStatus
                self.activationPreflight = preflight
            }
        }
    }

    // MARK: - Helper Management

    var helperStatus: HelperToolPrivilegeClient.Status {
        helperStatusState
    }

    func installHelper() {
        guard let source = HelperBinaryLocator.sourcePath else {
            lastErrorMessage = "Helper binary not found in app bundle."
            logStore.log(.error, "Cannot install helper: binary not found in bundle.", category: .system)
            return
        }
        do {
            try privilegeClient.installHelper(from: source)
            logStore.log(.notice, "Privileged helper installed successfully.", category: .system)
            Task {
                try? await Task.sleep(for: .seconds(1))
                refreshPreflight()
            }
        } catch {
            lastErrorMessage = error.localizedDescription
            logStore.log(.error, "Failed to install helper: \(error.localizedDescription)", category: .system)
        }
    }

    func uninstallHelper() {
        do {
            try privilegeClient.uninstallHelper()
            logStore.log(.notice, "Privileged helper uninstalled.", category: .system)
            refreshPreflight()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func performTerminationCleanup() {
        runtime.stop()
        stopDNSHealthTimer()
        networkMonitor.stop()
        // Tier B observer owns an SCDynamicStore handle bound to a dispatch
        // queue plus pending grace/min-visible DispatchWorkItem timers. Without
        // this call, the kernel-side notification subscription leaks until
        // process exit and any pending timers continue running.
        vpnStatusMonitor.stop()
        if let wakeObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver)
            self.wakeObserver = nil
        }
        if platformConfig.manageSystemDNS || systemDNSManager.hasSavedState() {
            do {
                try systemDNSManager.clear(logger: logStore)
            } catch {
                logStore.log(.warning, "Termination cleanup could not restore system DNS: \(error.localizedDescription)", category: .system)
            }
        }
        orchestrator.performTerminationCleanup()

        if platformConfig.manageSystemProxy {
            do {
                try systemConduit.clear(logger: logStore)
            } catch {
                logStore.log(.warning, "Termination cleanup could not clear system proxy: \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageEnvironmentVariables {
            do {
                try environmentManager.clear(logger: logStore)
            } catch {
                logStore.log(.warning, "Termination cleanup could not clear environment variables: \(error.localizedDescription)", category: .system)
            }
        }
        if platformConfig.manageDNSResolvers {
            do {
                try dnsManager.clear(config: config, logger: logStore)
            } catch {
                logStore.log(.warning, "Termination cleanup could not clear DNS resolvers: \(error.localizedDescription)", category: .system)
            }
        }
    }

    // MARK: - Misc

    func refreshPACResolutionPreview() {
        guard !config.pacURL.isEmpty else { return }
        Task {
            do {
                let script = try await pacEvaluator.fetchPAC(from: config.pacURL)
                let result = try pacEvaluator.resolveProxyChain(for: URL(string: appPreferences.preferredBrowserTestURL)!, pacScript: script)
                logStore.log(.info, "PAC preview for \(appPreferences.preferredBrowserTestURL): \(result.joined(separator: "; "))", category: .pac)
            } catch {
                lastErrorMessage = error.localizedDescription
            }
        }
    }

    func revealHealthTestURL() {
        guard let url = URL(string: appPreferences.preferredBrowserTestURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Network

    private func handleSystemWake() {
        Task { @MainActor in
            await orchestrator.handleSystemWake()
        }
        // Sleep is when the VPN client (Cisco Secure Client) most often
        // rewrites interface DNS behind our back: on wake it re-establishes
        // the tunnel and re-asserts its own resolvers, silently undoing the
        // 127.0.0.1 override while our relay keeps answering port 53 (so the
        // 30 s liveness probe alone never notices). Reconcile re-pins the
        // interfaces and re-checks relay liveness immediately instead of
        // waiting for the next network-change event.
        if platformConfig.manageSystemDNS, runtime.dnsRunState == .running {
            scheduleDNSReconcile()
        }
    }

    private func handleNetworkChange(description: String) {
        Task { @MainActor in
            await orchestrator.handleNetworkChange(description: description)
        }

        if platformConfig.manageSystemDNS, runtime.dnsRunState == .running {
            scheduleDNSReconcile()
        }
        // Note: `autoEnableOnVPN` / `autoDisableOffVPN` retired in Phase 3 of
        // docs/design-vpn-flap-resilience.md. The behavior they encoded
        // ("toggle the whole proxy on VPN state change") is now subsumed by
        // direct mode: when off-VPN, direct mode is silent and fast; when
        // on-VPN, the proxy uses upstreams normally. No nuclear toggle needed.
    }

    /// Tier B observer reports a new VPN state. Phase 4 implements the
    /// transition table in the orchestrator (direct-mode flips, breaker
    /// reset, flap recovery, slow reprobe cadence, vpn.* events).
    private func handleVPNStateChange(_ state: VPNObservedState) {
        let entriesWantedChanged = splitDNSGate.update(state)

        Task { @MainActor in
            await orchestrator.handleVPNStateChange(state)
        }

        if platformConfig.manageSystemDNS, runtime.dnsRunState == .running {
            scheduleDNSReconcile()
        }

        // Entry files live and die with the tunnel (vpn-gw.corp.example
        // under corp.example deadlocks reconnection otherwise — see
        // `SplitDNSVPNGate`). Only touch them while the proxy is actually
        // up: outside that window no platform side-effects exist to
        // reconcile.
        guard platformConfig.manageDNSResolvers, entriesWantedChanged else { return }

        // The activation preflight consults the gate (deferred entry files
        // count as applied), so a gating flip invalidates it — recompute even
        // when the proxy is down, which is exactly when the preflight shows.
        refreshPreflight()

        let proxyIsUp: Bool
        switch runtime.runtimeStatus.state {
        case .running, .degraded, .recovering: proxyIsUp = true
        default: proxyIsUp = false
        }
        guard proxyIsUp else { return }

        splitDNSGate.reconcileEntryFiles(config: config, dnsManager: dnsManager, logger: logStore)
    }

    private func scheduleDNSReconcile() {
        dnsReconcileWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.systemDNSManager.reconcile(logger: self.logStore)
            // Follow up with an immediate liveness probe (off-main; it can
            // block up to 2 s) so a relay that died across sleep/VPN churn is
            // restarted now rather than at the next 30 s health tick.
            let manager = self.systemDNSManager
            DispatchQueue.global(qos: .utility).async {
                let alive = manager.probeLiveness()
                Task { @MainActor [weak self] in
                    guard let self, self.runtime.dnsRunState == .running else { return }
                    self.handleDNSHealthResult(alive: alive)
                }
            }
        }
        dnsReconcileWork = work
        // Must run on the main queue: `AppState` and `logStore` are `@MainActor`.
        // Dispatching to a utility queue and touching them there traps at runtime
        // (Swift 6 executor check) — observed when DNS apply triggers a network
        // change and this debounced reconcile fires ~1s later.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }
}
