// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// What a runtime push left the orchestrator holding. The pass records `held` as its runtime baseline. It is the input the call completed
/// with, and nothing about listeners or surfaces: those are read through `runtimeState()` and the platform actions, not here.
package enum RuntimeConfigApplication: Equatable {
    /// The orchestrator holds this input. It is the value the call assigned, not a later read of the orchestrator: the app's presentation
    /// mirror can change that value while the call is suspended.
    case held(ProxyConfig)
    /// The call applied nothing, so the baseline stays where it was and the next pass diffs again.
    case notHeld
}

/// The side of a runtime host (`AppState`, `RuntimeHost`) a reconcile pass talks to. A protocol rather than a set of closures so the tests
/// can stand in a recording host, and so the reconciler can hold it weakly: it is owned by the host it calls back.
@RuntimeActor
package protocol RuntimeReconcilerHost: AnyObject {
    /// Pushes a config edit into the running subsystems. Suspends, which is the whole reason passes are serialised. The result is the
    /// runtime input the call leaves held; the pass records it, and never reads the orchestrator afterwards.
    func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async -> RuntimeConfigApplication
    /// Read after `applyConfigChange` returns, from the orchestrator snapshot rather than the presentation mirror: the mirror is an async
    /// hop behind.
    func runtimeState() -> RuntimeReconciler.RuntimeState
    /// Returns once no start or stop is in flight, so the pass that follows reads the runtime and acts on the surfaces after the
    /// lifecycle's platform work has landed rather than beside it.
    func awaitLifecycleIdle() async
    /// Re-applies the surfaces whose *contents* the config edit changed — resolver files, the system proxy, the environment block — using
    /// nothing but what the pass carries. Called only when the config changed; a flag-only save skips it. Async so a host can run the
    /// `networksetup` and `launchctl` writes off the owner.
    func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass) async
    /// A platform decision, called before its side effect so the event stream carries the decision whether or not the side effect lands.
    func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action)
    /// Runs one flag action of a pass through the manager the start and stop paths use. `previousPlatform` is the flags it moves from, so a
    /// host can say whether a switch turned on or only the mode changed. Returns whether it landed. Async so a host can queue the blocking
    /// manager calls off this actor; it queues them in the turn it is called, which is the turn the pass checked its admission.
    func perform(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        platform: PlatformIntegrationConfig,
        previousPlatform: PlatformIntegrationConfig
    ) async -> Bool
    /// Runs an action that needs no runtime (`PlatformIntegrationReconciler.immediateActions`) before the save's pass is queued, so a quit
    /// right after the save keeps it. Synchronous: the host answers it with no blocking effect. Returns whether it landed.
    func performImmediate(
        _ action: PlatformIntegrationReconciler.Action,
        platform: PlatformIntegrationConfig,
        previousPlatform: PlatformIntegrationConfig
    ) -> Bool
}

/// Converges saved runtime and platform intent through one worker with one replaceable pending request.
/// Diffs use the input the last completed push reported as held; queueing or abandoning a request never changes that baseline.
/// Each platform flag advances only when its action lands, while config-driven surface work remains owed until re-applied.
/// A flag action supersedes a content re-apply for the same surface, avoiding duplicate writes and admin prompts.
/// Admission is checked between effects. Stop waits only for an effect already running, since queued passes may await its lane.
@RuntimeActor
package final class RuntimeReconciler {
    package struct RuntimeState: Equatable {
        package var proxyIsUp: Bool
        package var dnsIsUp: Bool

        package init(proxyIsUp: Bool, dnsIsUp: Bool) {
            self.proxyIsUp = proxyIsUp
            self.dnsIsUp = dnsIsUp
        }
    }

    /// Everything a pass decided from, handed to the host for the config-driven half. The host reads `platform` from here and nothing else,
    /// which is what keeps the flag rule true.
    package struct Pass {
        package let diff: ConfigDiff
        package let old: ProxyConfig
        package let new: ProxyConfig
        package let platform: PlatformIntegrationConfig
        package let runtime: RuntimeState
        package let platformActions: [PlatformIntegrationReconciler.Action]

        /// Whether this pass already applies or clears the resolver files because their switch flipped; the config-driven resolver reconcile
        /// then stands aside.
        package var resolversFollowTheirFlag: Bool {
            platformActions.contains { action in
                switch action {
                case .applyResolverEntries, .refreshInterceptFiles, .clearResolvers: return true
                default: return false
                }
            }
        }
    }

    /// The config the running subsystems hold, as far as the last push that landed knows. `reconcile` diffs the current config against this to
    /// drive `applyConfigChange` and the platform side effects. The `$config` sink can't be used for that because it mirrors every keystroke
    /// into `orchestrator.config`, which would make an internally-derived diff permanently empty. Lifecycle toggles that mutate config
    /// themselves (start/stopDNS) call `markReconciled(dnsForwarderEnabled:)` so their own save doesn't re-trigger the subsystem they just
    /// started or stopped.
    package private(set) var lastReconciledConfig: ProxyConfig
    /// The platform integration flags the machine was last brought in line with. Same role as `lastReconciledConfig` for the other half of a
    /// save: a flag that changed since is a surface to apply or clear now, not at the next restart (#13). Lifecycle code never writes these
    /// flags, so unlike its sibling nothing has to absorb its own edits.
    package private(set) var lastReconciledPlatformConfig: PlatformIntegrationConfig
    /// What the last save asked for. The baseline above advances to what the machine holds and never to a request; this does not, so
    /// `retryRequest` can reach it again without whatever the host has been edited to since (#176).
    package private(set) var requestedConfig: ProxyConfig
    package private(set) var requestedPlatformConfig: PlatformIntegrationConfig {
        didSet { platformRequest.set(requestedPlatformConfig) }
    }
    /// `requestedPlatformConfig`, readable from the platform queue. A save moves it at once, but its flag actions are queued only when its
    /// pass runs, so platform work queued before a save can run after the save asked to clear: work that must not act on a switch a later
    /// save moved checks this under its manager's lock (#194).
    package nonisolated let platformRequest: PlatformRequestFence

    package weak var host: (any RuntimeReconcilerHost)?

    /// A request the worker has not taken yet. The worker takes it when the previous pass has ended, and a request that arrives first replaces
    /// it.
    private struct PassRequest {
        let config: ProxyConfig
        let platformConfig: PlatformIntegrationConfig
        /// The caller's admission, checked synchronously before each step that acts. Nil admits every step.
        let isCurrent: (@RuntimeActor () -> Bool)?
    }

    /// The config-driven surfaces a pushed input changed and no admitted pass has re-applied yet. One record: a later push widens `old` to
    /// keep the whole diff, and the pass that re-applies it clears it.
    private struct OwedSurfaces {
        let old: ProxyConfig
        let new: ProxyConfig
    }

    /// The one worker, queued or running. Nil when no pass is pending or running.
    private var worker: Task<Void, Never>?
    /// The newest request the worker has not taken yet.
    private var pending: PassRequest?
    /// The effect now running, if any: the orchestrator push, the config-driven re-apply, or one flag action with its host settlement.
    /// Quiescence waits for this one handle and for nothing queued, since a queued pass may itself wait for a lifecycle lane the caller
    /// holds.
    private var activeEffect: Task<Void, Never>?
    /// The admission the last request was recorded under. `retryRequest` runs under this one and no other, so a retry never outlives the
    /// authority the request had.
    private var requestedAdmission: (@RuntimeActor () -> Bool)?
    private var surfacesOwed: OwedSurfaces?

    /// Waits for the effect already running, if one is. It does not wait for queued passes, which may be waiting on the lane the caller
    /// holds. A caller fences its admission first, so no later effect can start, and the one running effect is all that is left to wait for.
    package func quiesceEffects() async {
        await activeEffect?.value
    }

    package init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig, host: (any RuntimeReconcilerHost)? = nil) {
        self.lastReconciledConfig = config
        self.lastReconciledPlatformConfig = platformConfig
        self.requestedConfig = config
        self.platformRequest = PlatformRequestFence(platformConfig)
        self.requestedPlatformConfig = platformConfig
        self.host = host
    }

    /// For the DNS lifecycle's own flag flip, already live in the runtime, so the next save does not re-apply it. Only that field: absorbing
    /// the whole config also absorbed a Settings edit still waiting for its save (#171), which then never reached the platform surfaces.
    package func markReconciled(dnsForwarderEnabled: Bool) {
        lastReconciledConfig.dnsForwarderEnabled = dnsForwarderEnabled
        requestedConfig.dnsForwarderEnabled = dnsForwarderEnabled
    }

    /// For a flag change nothing was applied under yet: the launch-flag session overrides.
    package func markReconciled(platformConfig: PlatformIntegrationConfig) {
        lastReconciledPlatformConfig = platformConfig
        requestedPlatformConfig = platformConfig
    }

    /// For the split-DNS repair (#165): a retry carried out the resolver switch's action that did not land, so the baseline takes the flag the
    /// last save asked for. Without this the next flip back diffs equal and runs nothing: a teardown repaired by a retry, then the switch
    /// turned on again, wrote no entry files. Only that flag, and only while the request still holds the value the retry acted on.
    package func markResolverSwitchLanded(manageDNSResolvers: Bool) {
        guard requestedPlatformConfig.manageDNSResolvers == manageDNSResolvers else { return }
        lastReconciledPlatformConfig.manageDNSResolvers = manageDNSResolvers
    }

    /// Whether a pass is queued or running. Tests read it; `drain` waits it out, and a settle reads it.
    package var hasPassInFlight: Bool { worker != nil }

    /// Whether the baseline is behind `config`: an action that did not land left it there, so the next save retries that action.
    package func lags(config: ProxyConfig, platformConfig: PlatformIntegrationConfig) -> Bool {
        ConfigDiff(old: lastReconciledConfig, new: config).inputChanged || lastReconciledPlatformConfig != platformConfig
    }

    /// Whether an action the last save asked for did not land.
    package var requestLags: Bool {
        lags(config: requestedConfig, platformConfig: requestedPlatformConfig)
    }

    /// Runs the last save's request again, for an action that did not land, under the admission that save was recorded with. Not the host's
    /// current config: an edit made since is the host's to save, under its own gate.
    package func retryRequest() {
        reconcile(config: requestedConfig, platformConfig: requestedPlatformConfig, isCurrent: requestedAdmission)
    }

    /// Waits for every queued pass, including ones queued while waiting.
    package func drain() async {
        while let worker {
            await worker.value
        }
    }

    /// At quit, for an edit no save has reached: runs only the actions that need no runtime (the login item), so the next launch is registered
    /// the way the saved file says. Nothing else is queued; termination cleanup is tearing the runtime surfaces down.
    package func reconcileImmediateActions(platformConfig newPlatform: PlatformIntegrationConfig) {
        let oldPlatform = lastReconciledPlatformConfig
        let actions = PlatformIntegrationReconciler.immediateActions(old: oldPlatform, new: newPlatform)
        guard !actions.isEmpty else { return }
        requestedPlatformConfig.launchAtLogin = newPlatform.launchAtLogin
        for action in actions {
            runImmediate(action, from: oldPlatform, to: newPlatform)
        }
    }

    /// Records what `new` asks for, and queues one pass that brings the machine to it. The pass diffs against what the machine holds when it
    /// runs. `isCurrent` is the caller's admission: checked here first, so a lapsed admission records nothing, and then before each step that
    /// acts, so once it fails the pass runs no further step. A caller with no admission passes `nil`, which admits every step.
    package func reconcile(
        config new: ProxyConfig,
        platformConfig newPlatform: PlatformIntegrationConfig,
        isCurrent: (@RuntimeActor () -> Bool)? = nil
    ) {
        guard isCurrent?() ?? true else { return }
        requestedConfig = new
        requestedPlatformConfig = newPlatform
        requestedAdmission = isCurrent
        // Flags that need no runtime run before the queued pass, so a quit right after the save keeps them.
        // See `PlatformIntegrationReconciler.immediateActions`.
        let immediatePlatform = lastReconciledPlatformConfig
        for action in PlatformIntegrationReconciler.immediateActions(old: immediatePlatform, new: newPlatform) {
            runImmediate(action, from: immediatePlatform, to: newPlatform)
        }

        // Nothing waits when no pass is running and the machine already holds the save: no runtime input is behind, no surface is owed,
        // and no flag differs. A pass that is running still takes the request, since it may act on what the request changed.
        guard worker != nil || surfacesOwed != nil || lags(config: new, platformConfig: newPlatform) else { return }
        pending = PassRequest(config: new, platformConfig: newPlatform, isCurrent: isCurrent)
        guard worker == nil else { return }
        worker = Task { await self.work() }
    }

    /// Takes the pending request and runs it, then whatever arrived meanwhile, until none is left. The worker is released in the same turn
    /// that finds nothing pending, so a request is never queued behind a worker that has stopped.
    private func work() async {
        while let request = pending {
            pending = nil
            await runPass(request)
        }
        worker = nil
    }

    private func runPass(_ request: PassRequest) async {
        // After the lifecycle's work, never beside it: a start's platform block still out on the host's queue acts on the config and flags it
        // read when it began, and a pass landing in the middle would clear a surface the block then applies again.
        await host?.awaitLifecycleIdle()
        guard let host else { return }
        // A newer request arrived while this one waited for the lifecycle. The newer one diffs from what the machine holds when it runs, so
        // this one does nothing: no stale push, no stale action.
        guard pending == nil else { return }
        let admitted = { request.isCurrent?() ?? true }
        guard admitted() else { return }

        let old = lastReconciledConfig
        let oldPlatform = lastReconciledPlatformConfig
        let newPlatform = request.platformConfig
        if ConfigDiff(old: old, new: request.config).inputChanged {
            let target = request.config
            var application = RuntimeConfigApplication.notHeld
            await runEffect { application = await host.applyConfigChange(target, from: old) }
            // The baseline moves only to input the push reports as held. A push that held nothing leaves it, so the next pass diffs the
            // change again. The flags still settle: they need no runtime input.
            if case .held(let held) = application {
                lastReconciledConfig = held
                surfacesOwed = OwedSurfaces(old: surfacesOwed?.old ?? old, new: held)
            }
            await host.awaitLifecycleIdle()
            guard admitted() else { return }
        }
        // The input the runtime holds now: the push's result, which can differ from the request as the app's DNS flag does, or the old
        // input when the push held nothing. The platform actions carry this one.
        let new = lastReconciledConfig

        let runtime = host.runtimeState()
        let platformActions = PlatformIntegrationReconciler.actions(
            old: oldPlatform,
            new: newPlatform,
            proxyIsUp: runtime.proxyIsUp,
            dnsIsUp: runtime.dnsIsUp
        )
        if let owed = surfacesOwed {
            let surfaces = Pass(
                diff: ConfigDiff(old: owed.old, new: owed.new),
                old: owed.old,
                new: owed.new,
                platform: newPlatform,
                runtime: runtime,
                platformActions: platformActions
            )
            await runEffect { await host.reapplyConfigDrivenSurfaces(for: surfaces) }
            surfacesOwed = nil
            guard admitted() else { return }
        }
        for action in platformActions {
            guard admitted() else { return }
            await runFlagEffect { await self.run(action, config: new, previousConfig: old, from: oldPlatform, to: newPlatform, host: host) }
        }
        // An action suspends while its work is out. One that landed was recorded at the value this pass carried; a lapsed admission records
        // nothing more.
        guard admitted() else { return }
        // Complete: a flag group no action named this pass already holds the save's value, or the runtime is down and the start path owns
        // the surface from here. A named group was settled by its own action, and a failed one stays unreconciled for the next save.
        for group in FlagGroup.allCases where !platformActions.contains(where: { FlagGroup($0) == group }) {
            adopt(group, from: newPlatform)
        }
    }

    /// Runs one effect and holds its handle while it runs, so quiescence can wait on it. The handle is the only effect state there is: one
    /// effect runs at a time, because only the worker starts one.
    private func runEffect(_ body: @escaping @RuntimeActor () async -> Void) async {
        let effect = Task { await body() }
        activeEffect = effect
        await effect.value
        activeEffect = nil
    }

    /// A flag action as the one effect running. Unlike `runEffect`, `body` begins in this turn, so the host queues the action's platform
    /// work in the turn the pass checked its admission; the handle only marks when the action ends, which is what quiescence waits for.
    private func runFlagEffect(_ body: @RuntimeActor () async -> Void) async {
        // Finish-only: nothing is ever yielded, and the buffer holds none.
        let (ended, end) = AsyncStream.makeStream(of: Void.self, bufferingPolicy: .bufferingNewest(0))
        activeEffect = Task { for await _ in ended {} }
        await body()
        end.finish()
        activeEffect = nil
    }

    /// Event first, side effect second: a flag flip is a config decision, and log lines are derived from events, not the other way round.
    /// A landed action is recorded at the value its pass carried, whatever was requested while it was out.
    private func run(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        from oldPlatform: PlatformIntegrationConfig,
        to newPlatform: PlatformIntegrationConfig,
        host: any RuntimeReconcilerHost
    ) async {
        host.recordPlatformDecision(action)
        let landed = await host.perform(
            action, config: config, previousConfig: previousConfig, platform: newPlatform, previousPlatform: oldPlatform
        )
        if landed { adopt(action, from: newPlatform) }
    }

    /// An immediate action, before any pass: the event, then the host's synchronous answer.
    private func runImmediate(
        _ action: PlatformIntegrationReconciler.Action,
        from oldPlatform: PlatformIntegrationConfig,
        to newPlatform: PlatformIntegrationConfig
    ) {
        guard let host else { return }
        host.recordPlatformDecision(action)
        if host.performImmediate(action, platform: newPlatform, previousPlatform: oldPlatform) { adopt(action, from: newPlatform) }
    }

    /// Records one flag action as reconciled, at the value it carried, once it landed. A failed action records nothing, so the next pass
    /// diffs it again.
    private func adopt(_ action: PlatformIntegrationReconciler.Action, from new: PlatformIntegrationConfig) {
        if let group = FlagGroup(action) {
            adopt(group, from: new)
        } else {
            lastReconciledPlatformConfig.launchAtLogin = new.launchAtLogin
        }
    }

    private func adopt(_ group: FlagGroup, from new: PlatformIntegrationConfig) {
        switch group {
        case .systemProxy:
            lastReconciledPlatformConfig.manageSystemProxy = new.manageSystemProxy
            lastReconciledPlatformConfig.systemProxyMode = new.systemProxyMode
        case .environment:
            lastReconciledPlatformConfig.manageEnvironmentVariables = new.manageEnvironmentVariables
        case .resolvers:
            lastReconciledPlatformConfig.manageDNSResolvers = new.manageDNSResolvers
        case .systemDNS:
            lastReconciledPlatformConfig.manageSystemDNS = new.manageSystemDNS
        }
    }

    /// The flags an action moves, grouped as the baseline records them. Launch at login runs before a pass and is recorded by its own action.
    private enum FlagGroup: CaseIterable {
        case systemProxy
        case environment
        case resolvers
        case systemDNS

        init?(_ action: PlatformIntegrationReconciler.Action) {
            switch action {
            case .applySystemProxy, .clearSystemProxy: self = .systemProxy
            case .applyEnvironment, .clearEnvironment: self = .environment
            case .applyResolverEntries, .refreshInterceptFiles, .clearResolvers: self = .resolvers
            case .applySystemDNS, .clearSystemDNS: self = .systemDNS
            case .setLaunchAtLogin: return nil
            }
        }
    }
}

/// The platform flags the last save asked for, readable from any thread. Written only by `RuntimeReconciler`.
package final class PlatformRequestFence: @unchecked Sendable {
    private let lock = NSLock()
    private var value: PlatformIntegrationConfig

    init(_ value: PlatformIntegrationConfig) {
        self.value = value
    }

    package var current: PlatformIntegrationConfig { lock.withLock { value } }

    fileprivate func set(_ value: PlatformIntegrationConfig) {
        lock.withLock { self.value = value }
    }
}
