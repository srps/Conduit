// SPDX-License-Identifier: Apache-2.0
import ProxyKernel

/// The side of `AppState` a reconcile pass talks to. A protocol rather than
/// a set of closures so the tests can stand in a recording host, and so the
/// reconciler can hold it weakly: it is owned by the host it calls back.
@MainActor
protocol RuntimeReconcilerHost: AnyObject {
    /// Pushes a config edit into the running subsystems. Suspends, which is
    /// the whole reason passes are serialised.
    func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async
    /// Read after `applyConfigChange` returns, from the orchestrator
    /// snapshot rather than the presentation mirror: the mirror is an async
    /// hop behind.
    func runtimeState() -> RuntimeReconciler.RuntimeState
    /// Re-applies the surfaces whose *contents* the config edit changed —
    /// resolver files, the system proxy, the environment block — using
    /// nothing but what the pass carries. Called only when the config
    /// changed; a flag-only save skips it.
    func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass)
    /// A platform decision, called before its side effect so the event
    /// stream carries the decision whether or not the side effect lands.
    func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action)
    /// Runs one flag action through the manager the start and stop paths
    /// use. Returns whether it landed.
    func perform(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        platform: PlatformIntegrationConfig
    ) -> Bool
}

/// Pushes config edits into the running subsystems, one serialised pass per
/// save.
///
/// Historically the GUI only persisted edits to disk and the runtime kept
/// the old values until the next full restart (the daemon path always called
/// `applyConfigChange`; the app never did). `reconcile` runs after every
/// save and no-ops when nothing changed since the last pass.
///
/// The platform integration flags are reconciled in the same pass, once the
/// runtime has settled: `PlatformIntegrationReconciler` turns the flag diff
/// into actions, and each runs through the host's manager calls. When one
/// save changes both a flag and the config behind its surface — the
/// Configure sections save on disappear, so one window close can carry both
/// — the flag's apply wins and the config-driven re-apply is skipped: both
/// would write the same thing, and the second write can cost an admin
/// prompt.
///
/// Three rules this type exists to hold, each with a test:
///
/// - **Passes are serialised, not merely ordered.** `applyConfigChange`
///   suspends, and a second save in that window would otherwise run its
///   actions first and let the first, on resuming, put a surface back to
///   what its by-then-stale flags said. Each pass waits for the one before
///   it, so the machine ends in the state of the last save.
/// - **A pass reads the flags of the save that queued it**, never the
///   live ones. By the time a queued pass runs, a later save may have moved
///   a flag again, and reading the live value re-applied a surface this
///   pass was about to clear and the next pass was about to apply.
/// - **A failed action leaves its flag unreconciled** so the next save
///   diffs it again and retries — unless a later pass has moved that flag
///   since, in which case that pass owns it.
@MainActor
final class RuntimeReconciler {
    struct RuntimeState: Equatable {
        var proxyIsUp: Bool
        var dnsIsUp: Bool
    }

    /// Everything a pass decided from, handed to the host for the
    /// config-driven half. The host reads `platform` from here and nothing
    /// else, which is what keeps the second rule above true.
    struct Pass {
        let diff: ConfigDiff
        let old: ProxyConfig
        let new: ProxyConfig
        let platform: PlatformIntegrationConfig
        let runtime: RuntimeState
        let platformActions: [PlatformIntegrationReconciler.Action]

        /// Whether this pass already applies or clears the resolver files
        /// because their switch flipped; the config-driven resolver
        /// reconcile then stands aside.
        var resolversFollowTheirFlag: Bool {
            platformActions.contains { action in
                switch action {
                case .applyResolverEntries, .refreshInterceptFiles, .clearResolvers: return true
                default: return false
                }
            }
        }
    }

    /// Snapshot of the config the running subsystems were last reconciled
    /// against. `reconcile` diffs the current config against this to drive
    /// `applyConfigChange` and the platform side effects — the `$config`
    /// sink can't be used for that because it mirrors every keystroke into
    /// `orchestrator.config`, which would make an internally-derived diff
    /// permanently empty. Lifecycle toggles that mutate config themselves
    /// (start/stopDNS) call `markReconciled(config:)` so their own save
    /// doesn't re-trigger the subsystem they just started or stopped.
    private(set) var lastReconciledConfig: ProxyConfig
    /// The platform integration flags the machine was last brought in line
    /// with. Same role as `lastReconciledConfig` for the other half of a
    /// save: a flag that changed since is a surface to apply or clear now,
    /// not at the next restart (#13). Lifecycle code never writes these
    /// flags, so unlike its sibling nothing has to absorb its own edits.
    private(set) var lastReconciledPlatformConfig: PlatformIntegrationConfig

    weak var host: (any RuntimeReconcilerHost)?

    /// The pass in flight, awaited by the next one. `generation` lets the
    /// last pass in a chain tell it is last and release the handle, so the
    /// chain of awaited predecessors it retains can go with it.
    private var task: Task<Void, Never>?
    private var generation = 0

    init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig, host: (any RuntimeReconcilerHost)? = nil) {
        self.lastReconciledConfig = config
        self.lastReconciledPlatformConfig = platformConfig
        self.host = host
    }

    /// For a config change that is already live in the runtime — a
    /// lifecycle flip, or an orchestrator-originated edit — so the next
    /// save does not re-apply it.
    func markReconciled(config: ProxyConfig) {
        lastReconciledConfig = config
    }

    /// For a flag change nothing was applied under yet: the launch-flag
    /// session overrides.
    func markReconciled(platformConfig: PlatformIntegrationConfig) {
        lastReconciledPlatformConfig = platformConfig
    }

    /// Whether a pass is queued or running. Tests read it; `drain` waits it out.
    var hasPassInFlight: Bool { task != nil }

    /// Waits for every queued pass, including ones queued while waiting.
    func drain() async {
        while let task {
            await task.value
        }
    }

    func reconcile(config new: ProxyConfig, platformConfig newPlatform: PlatformIntegrationConfig) {
        let old = lastReconciledConfig
        let oldPlatform = lastReconciledPlatformConfig
        guard old != new || oldPlatform != newPlatform else { return }
        lastReconciledConfig = new
        lastReconciledPlatformConfig = newPlatform
        let diff = ConfigDiff(old: old, new: new)

        // Before the queued pass, not in it: these need no runtime state, and
        // a quit right after the save would lose whatever the pass has not
        // reached. See `PlatformIntegrationReconciler.immediateActions`.
        for action in PlatformIntegrationReconciler.immediateActions(old: oldPlatform, new: newPlatform) {
            run(action, config: new, previousConfig: old, from: oldPlatform, to: newPlatform)
        }

        let previous = task
        generation += 1
        let generation = generation
        task = Task { @MainActor in
            await previous?.value
            guard let host else { return }
            if old != new {
                await host.applyConfigChange(new, from: old)
            }

            let runtime = host.runtimeState()
            let pass = Pass(
                diff: diff,
                old: old,
                new: new,
                platform: newPlatform,
                runtime: runtime,
                platformActions: PlatformIntegrationReconciler.actions(
                    old: oldPlatform,
                    new: newPlatform,
                    proxyIsUp: runtime.proxyIsUp,
                    dnsIsUp: runtime.dnsIsUp
                )
            )

            if old != new {
                host.reapplyConfigDrivenSurfaces(for: pass)
            }
            for action in pass.platformActions {
                run(action, config: new, previousConfig: old, from: oldPlatform, to: newPlatform)
            }
            if self.generation == generation {
                task = nil
            }
        }
    }

    /// Event first, side effect second: a flag flip is a config decision,
    /// and log lines are derived from events, not the other way round.
    private func run(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        from oldPlatform: PlatformIntegrationConfig,
        to newPlatform: PlatformIntegrationConfig
    ) {
        guard let host else { return }
        host.recordPlatformDecision(action)
        if !host.perform(action, config: config, previousConfig: previousConfig, platform: newPlatform) {
            leaveUnreconciled(action, from: oldPlatform, ifStill: newPlatform)
        }
    }

    /// A failed action leaves its flag where the machine is, not where the
    /// switch is, so the next save diffs it again and retries. Only if no
    /// later pass has moved the flag since: that pass owns it now.
    private func leaveUnreconciled(
        _ action: PlatformIntegrationReconciler.Action,
        from old: PlatformIntegrationConfig,
        ifStill new: PlatformIntegrationConfig
    ) {
        switch action {
        case .applySystemProxy, .clearSystemProxy:
            guard lastReconciledPlatformConfig.manageSystemProxy == new.manageSystemProxy,
                  lastReconciledPlatformConfig.systemProxyMode == new.systemProxyMode else { return }
            lastReconciledPlatformConfig.manageSystemProxy = old.manageSystemProxy
            lastReconciledPlatformConfig.systemProxyMode = old.systemProxyMode
        case .applyEnvironment, .clearEnvironment:
            guard lastReconciledPlatformConfig.manageEnvironmentVariables == new.manageEnvironmentVariables else { return }
            lastReconciledPlatformConfig.manageEnvironmentVariables = old.manageEnvironmentVariables
        case .applyResolverEntries, .refreshInterceptFiles, .clearResolvers:
            guard lastReconciledPlatformConfig.manageDNSResolvers == new.manageDNSResolvers else { return }
            lastReconciledPlatformConfig.manageDNSResolvers = old.manageDNSResolvers
        case .applySystemDNS, .clearSystemDNS:
            guard lastReconciledPlatformConfig.manageSystemDNS == new.manageSystemDNS else { return }
            lastReconciledPlatformConfig.manageSystemDNS = old.manageSystemDNS
        case .setLaunchAtLogin:
            guard lastReconciledPlatformConfig.launchAtLogin == new.launchAtLogin else { return }
            lastReconciledPlatformConfig.launchAtLogin = old.launchAtLogin
        }
    }
}
