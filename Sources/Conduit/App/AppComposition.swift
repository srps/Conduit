// SPDX-License-Identifier: Apache-2.0
import ConduitRuntime
import ConduitShared
import Foundation
import PlatformMac
import ProxyAuth
import ProxyKernel
import ProxyPAC

/// Everything one app composition runs against, named once (decision 0033). The runtime's machine effects go to the one `RuntimeHost`
/// the app opens; the rest are the app's own administration: helper install, credential enrollment, the login item, the PAC preview's
/// evaluator and the updater. Production, the dev instance and the harness each build one value; nothing is chosen by omission.
struct AppComposition {
    /// The host's machine effects.
    let effects: RuntimeHostEffects
    /// What the app's file log is judged by, over the authoritative protected-destination guard.
    let appLogGuard: AppLogGuardEffect
    /// Install and uninstall from Settings. The helper's status is the host's preflight reading.
    let helperLifecycle: any HelperLifecycleManaging
    /// Where Settings saves and clears the proxy password. The same store the host's effects read.
    let credentialStore: any SecretStore
    let loginItemManager: LoginItemManager
    /// The PAC preview's own evaluator, fed the draft's URL. The runtime routes through the host's.
    let pacEvaluator: any PacEvaluator
    let updaterLauncher: any UpdaterLaunching
    let updateReports: any UpdateReportSource
    let updaterAvailability: UpdaterAvailability
    let currentVersion: String
    /// The explicit launch overrides, committed save-only before the controls are enabled.
    let launchOverrides: AppLaunchOverrides
    let timing: AppTiming
    let hostSchedules: AppHostSchedules
}

/// Wraps the authoritative destination guard the app's file log is built with: the one `diagnosticDestinationGuard(for:
/// .appLog, …)` maps from the held state root, holding that root's session. A wrapper must delegate every admission to it,
/// and keep it, so it can add a wait but never admit what the authoritative guard refuses or drop the root's authority. Production and the dev instance name `.identity`; the harness names
/// a delegating hold, so a scenario can hold the app's own final drain.
struct AppLogGuardEffect: Sendable {
    let wrap: @Sendable (any RecordFileDestinationGuarding) -> any RecordFileDestinationGuarding

    static let identity = AppLogGuardEffect { $0 }
}

/// The app's own waits. Production values by default; a harness shortens the one a scenario waits on.
struct AppTiming {
    /// The pause after the last Settings edit before it is saved (#171).
    var settingsSaveDebounce: Duration = .seconds(1)
    /// How long an install waits for the LaunchDaemon to bind its socket before the preflight is read again.
    var helperSocketBindWait: Duration = .seconds(1)
    /// How long after a `busy` helper reading the preflight is read again.
    var helperBusyRecheckDelay: Duration = .seconds(15)
    /// The whole Quit wait (decision 0039): fence, final saves and cleanup confirmation, counted once.
    var quitTotal: Duration = AppTiming.quitTotal
    /// The update coordinator's wait before each automatic check, its own default: the schedule (`UpdateCheckSchedule`) says how long.
    var updateCheckSleep: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }

    static let quitTotal: Duration = .seconds(10)
}

/// The host's repair and retry schedules. Production uses the host's own defaults.
struct AppHostSchedules {
    var networkLocationLimits = NetworkLocationLimits()
    var environmentDriftInterval: Duration = .seconds(300)
    var reapplyRetrySchedule: ConfigReapplyRetry.Schedule = .standard
    var splitDNSHelperCheckInterval: Duration = SplitDNSEntryFileRepair.helperCheckInterval
}

/// `--port N`, `--no-system-proxy` and `--no-env`. They are saved, save-only, before the controls are enabled, so a later Start uses them
/// and the next launch reads them; an override never runs from an unsaved draft.
struct AppLaunchOverrides: Equatable {
    var port: Int?
    var disableSystemProxy = false
    var disableEnvironment = false

    var isEmpty: Bool { port == nil && !disableSystemProxy && !disableEnvironment }

    static func parse(_ arguments: [String]) -> AppLaunchOverrides {
        var overrides = AppLaunchOverrides()
        if let index = arguments.firstIndex(of: "--port"), index + 1 < arguments.count, let port = Int(arguments[index + 1]) {
            overrides.port = port
        }
        overrides.disableSystemProxy = arguments.contains("--no-system-proxy")
        overrides.disableEnvironment = arguments.contains("--no-env")
        return overrides
    }

    /// The drafts with the overrides applied.
    func applied(to config: ProxyConfig, _ platform: PlatformIntegrationConfig) -> (ProxyConfig, PlatformIntegrationConfig) {
        var config = config
        var platform = platform
        if let port { config.localPort = port }
        if disableSystemProxy { platform.manageSystemProxy = false }
        if disableEnvironment { platform.manageEnvironmentVariables = false }
        return (config, platform)
    }

    /// Whether saved values already hold every override, field by field, so a Start from them runs what this launch asked for.
    func isSatisfied(by config: ProxyConfig, _ platform: PlatformIntegrationConfig) -> Bool {
        (port.map { config.localPort == $0 } ?? true)
            && (!disableSystemProxy || !platform.manageSystemProxy)
            && (!disableEnvironment || !platform.manageEnvironmentVariables)
    }
}

extension AppComposition {
    /// The installed app: the helper, the login Keychain, system Kerberos, the live observers, CFNetwork PAC with the app's plaintext
    /// fetch fallback, the workspace wake adapter, `networksetup` and `launchctl`, and `/etc/resolver`.
    @MainActor
    static func production(arguments: [String] = CommandLine.arguments) -> AppComposition {
        let hostBundle = Bundle.main
        return AppComposition(
            effects: RuntimeHostEffects(
                // One helper client over the host's event sink, used as both the client and the status source.
                privilege: { eventSink in
                    let helper = HelperToolPrivilegeClient(eventSink: eventSink)
                    return RuntimePrivilegeAdapters(client: helper, helperStatus: helper)
                },
                credentials: KeychainStore(),
                kerberosTicketRecovery: SystemKerberosTicketRecovery(),
                gss: .system,
                pacEvaluator: AppState.makePACEvaluator(insecureFetcher: AppState.curlPACFetcher),
                portHolderProbe: PortHolderProbe(),
                loopbackPortProbe: { LoopbackPortProbe.isServed(port: $0) },
                commandRunner: CommandRunner.host,
                dnsResponds: { SystemDNSManager.dnsResponds(onPort: $0) },
                networkPath: NetworkMonitor(debounceInterval: NetworkMonitor.defaultDebounceInterval),
                networkLocation: NetworkLocationMonitor(),
                networkLocationStoreFactory: { SystemNetworkLocationStore(privilegeClient: $0) },
                vpnStatusMonitor: { graceSeconds, minVisibleSeconds in
                    VPNStatusMonitor(graceSecondsProvider: graceSeconds, minVisibleSecondsProvider: minVisibleSeconds)
                },
                wake: WorkspaceSystemWakeObserver(),
                homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
                resolverDirectory: "/etc/resolver",
                stateFiles: StateFileAccess.operatingSystem()
            ),
            appLogGuard: .identity,
            helperLifecycle: HelperToolPrivilegeClient(),
            credentialStore: KeychainStore(),
            loginItemManager: LoginItemManager(),
            pacEvaluator: AppState.makePACEvaluator(insecureFetcher: AppState.curlPACFetcher),
            updaterLauncher: SystemUpdaterLauncher(hostURL: hostBundle.bundleURL),
            updateReports: DistributedUpdateReports(),
            updaterAvailability: UpdaterAvailability.of(hostBundle: hostBundle),
            currentVersion: (hostBundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "unbundled",
            launchOverrides: AppLaunchOverrides.parse(arguments),
            timing: AppTiming(),
            hostSchedules: AppHostSchedules()
        )
    }
}
