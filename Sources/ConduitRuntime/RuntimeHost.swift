// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import ConduitShared
import ProxyPAC
import RuntimeEvents

private struct RuntimeVPNFlapWindowConfig: Sendable {
    var graceSeconds: TimeInterval
    var minVisibleSeconds: TimeInterval
}

/// Why `RuntimeHost.open` refused the startup inputs. The workflow's own type stays internal; the entry point gets the typed
/// `config.workflow.observed` event and reports it, as it reports a failed load.
package struct RuntimeOpenRefusal: Error, Sendable {
    package let event: RuntimeEvent
}

/// The one shared runtime host (decisions 0013 and 0031): the app hosts it in
/// process behind its framed clients, and `ConduitDaemon` runs it. It alone owns
/// the runtime's lifecycle, recovery and persistence. It lives in
/// `ConduitRuntime`, not an executable, so the tests drive it over
/// `FakeMachine`. It may link `PlatformMac` (Keychain, CFNetwork PAC,
/// SCDynamicStore, helper XPC, networksetup wrappers) but imports no AppKit or
/// SwiftUI.
@MainActor
package final class RuntimeHost {
    /// The root's writer authority (decision 0017). The host holds a reference, so the
    /// lease stays open while the host runs, whatever its caller drops. Stop does
    /// not release it; the entry point's own pin does.
    private let stateSession: StateRootSession
    /// This host's one lifetime (decision 0014): the workflow's store contexts, the control service and every snapshot it projects name
    /// it. The store's baseline namespace is a separate authority.
    let incarnation: ControlHostIncarnation
    /// The one configuration owner of this host (decisions 0031 and 0032). It holds the sole store privately, and every reload, Start
    /// and Stop is admitted through it.
    let workflow: RuntimeConfigurationWorkflow
    /// The presentation revision this host stamps its control snapshots with, and the last body it stamped (`RuntimeHostControlOwner`).
    /// One value, replaced in place, so it holds no history.
    var presentation = RuntimeHostPresentation()
    /// The revision of each collection its control snapshots pin, from the kernel values they were taken from. Four fixed slots.
    var collections = RuntimeHostCollections()
    /// Told when the host's safe state may have changed, so the control service composed over it captures a new snapshot. Set only by
    /// that composition; nil when no service is composed.
    var onControlStateChange: (@MainActor () -> Void)?
    /// Told once, when the quit's physical work has ended, so the composed control service ends its streams. Set only by that composition.
    var onControlShutdown: (@MainActor () -> Void)?
    /// The control operations this host admitted at the service's fence and has not launched yet. The service bounds them: its ordinary
    /// capacity, and at most one queued Stop per module, whose replacement is dropped here in the same fence turn.
    var controlAdmissions: [ControlOperationID: RuntimeControlAdmission] = [:]
    /// The latest control Stop admitted for each module and the revision its fence took, so a repeated Stop joins it while that fence is
    /// still the module's latest admission. Three fixed slots.
    var controlStops = PrivateModuleSlots<RuntimeControlStop?>(proxy: nil, dns: nil, tunnels: nil)
    /// The private updates admitted and not launched yet, with their frozen inputs. The composition's one frozen-input slot bounds it to one.
    var privateUpdates: [ControlOperationID: RuntimePrivateUpdate] = [:]
    /// The quit's one reserved draft flush, once a quit opened it.
    var quitFlush: RuntimeQuitFlush?
    /// The latest Test DNS probe, which every later one runs after: its port, an identity of its own, and the probe. Cleared by the probe
    /// itself in the owner turn it ends, and only while it is still the latest, so a request never joins an answer already given.
    var dnsLivenessProbe: (port: Int, identity: UUID, answer: Task<Bool, Never>)?
    /// Start, Stop and reload calls begun and not yet finished. A settle reads it, so a call that has not yet reached the lane or the
    /// workflow, still waiting for launch recovery, is seen.
    var pendingAdmissions = 0
    let environment: RuntimeEnvironment
    let logger: any LogSink
    let eventWriter: RuntimeEventFileWriter
    /// Writes `snapshot.json` on its own serial drain. Callers submit and never wait for the file.
    private let snapshotWriter: any SnapshotArtifactWriting

    private(set) var config: ProxyConfig
    private(set) var platformConfig: PlatformIntegrationConfig
    private(set) var configGeneration = 0

    let orchestrator: ProxyOrchestrator
    let credentialManager: CredentialManager
    /// The saved password's read at proxy start, so a Keychain prompt lands
    /// then and not inside a handshake burst (#98). Internal so a test can join it.
    var credentialWarmup: Task<Void, Never>?
    /// Base client every privileged side effect goes through, wrapped by
    /// `auditedPrivilegeClient`. Injectable so tests can drive the platform
    /// side-effect paths (apply on start, revert on a failed start) without
    /// touching the real system configuration.
    private let privilegeClient: any PrivilegeClient
    private let auditedPrivilegeClient: any PrivilegeClient
    /// The subprocess runner behind the `networksetup` and `launchctl`
    /// managers, and the directories they write. Supplied by `effects`, so a
    /// host test never rewrites the machine it runs on.
    private let commandRunner: @Sendable (String, [String]) throws -> CommandResult
    /// The stale-listener probe the system proxy manager asks; the effects supply it, so no manager reaches the real port by default.
    private let loopbackPortProbe: @Sendable (Int) -> Bool
    /// Whether a resolver answers on a local port, from `effects`, so launch recovery never waits on the real port 53 under test.
    private let dnsResponds: @Sendable (Int) -> Bool
    private let homeDirectory: URL
    private let resolverDirectory: String
    /// One serialised pass per config reload: the runtime takes the edit,
    /// the surfaces whose contents changed are re-applied, and each flipped
    /// platform flag applies or clears the surface it names, with the
    /// ownership guard from #13. The host's one applied baseline.
    let reconciler: RuntimeReconciler

    // Platform side-effect coordinators. Startup applies nothing until
    // `startRuntime()` is called; what `init` does start is launch recovery,
    // which only hands back what a crashed run left applied.
    /// Prior values of the platform settings we change, so teardown restores
    /// rather than blanket-clearing. Shared by every side-effect manager.
    private lazy var platformStateJournal = PlatformStateJournal(
        fileURL: environment.platformStateFile,
        logger: logger,
        eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }
    )
    lazy var systemConduit = SystemProxyManager(
        privilegeClient: auditedPrivilegeClient,
        journal: platformStateJournal,
        commandRunner: commandRunner,
        portProbe: loopbackPortProbe,
        locationRecovery: locationRecovery,
        configProvider: orchestrator.configSnapshotProvider
    )
    lazy var environmentManager = EnvironmentManager(
        journal: platformStateJournal,
        homeDirectory: homeDirectory,
        commandRunner: commandRunner,
        eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) }
    )
    private lazy var environmentDriftRepair = EnvironmentDriftRepair(
        manager: environmentManager,
        eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) },
        logger: logger
    )
    /// With the journal: a resolver file is ours only if we recorded it, and
    /// that record is what lets a stop under a switch that is already off
    /// remove our file and leave one the user keeps by hand for the same
    /// domain (#13).
    lazy var dnsManager = DNSManager(
        privilegeClient: auditedPrivilegeClient,
        resolverDirectory: resolverDirectory,
        journal: platformStateJournal
    )
    lazy var systemDNSManager = SystemDNSManager(
        privilegeClient: auditedPrivilegeClient,
        journal: platformStateJournal,
        legacySnapshotFile: environment.legacySavedDNSFile,
        commandRunner: commandRunner,
        respondsOnPort: dnsResponds,
        locationRecovery: locationRecovery,
        configProvider: orchestrator.configSnapshotProvider
    )
    private let networkLocationStoreFactory: @Sendable (any PrivilegeClient) -> (any NetworkLocationStoring)?
    let networkLocationObserver: any NetworkLocationObserving
    /// The system wake source, from `effects`: observed from open until the quit (`RuntimeHostWake.swift`).
    let systemWakeObserver: any SystemWakeObserving
    /// Bounds the work a burst of wakes can start: one running and one pending pass per repair.
    let wakeDeliveries = SystemWakeDeliveries()
    private let networkLocationLimits: NetworkLocationLimits
    /// At most one pending retry for a drift repair withheld by the contention budget.
    private var proxyRepairRetry: Task<Void, Never>?
    /// The shell environment drift pass (#175): one in flight, one wanted after it, one retry, one periodic tick.
    private var environmentDriftInFlight = false
    /// The trigger of the pass wanted after the one in flight.
    private var environmentDriftPending: EnvironmentDriftRepair.Trigger?
    private var environmentRepairRetry: Task<Void, Never>?
    private var environmentDriftTimer: Task<Void, Never>?
    private let environmentDriftInterval: Duration
    /// A failed re-apply of the system proxy or the environment, reported and retried through the drift passes (#194, narrow).
    private(set) lazy var reapplyRetry: ConfigReapplyRetry = {
        let retry = ConfigReapplyRetry(schedule: reapplyRetrySchedule) { [weak self] event, level in
            guard let self else { return }
            self.orchestrator.eventLog.append(event)
            self.logger.log(level, "Config: \(event.event) \(event.detail ?? "")", category: .system)
        }
        retry.attempt = { [weak self] surface, token in
            await self?.retryReapply(surface, token: token) ?? .notWanted(reason: "host_gone")
        }
        return retry
    }()
    private let reapplyRetrySchedule: ConfigReapplyRetry.Schedule
    private lazy var locationRecovery: LocationSettingsRecovery? = {
        guard let store = networkLocationStoreFactory(auditedPrivilegeClient) else { return nil }
        let eventLog = orchestrator.eventLog
        let logger = logger
        return LocationSettingsRecovery(store: store, journal: platformStateJournal, limits: networkLocationLimits) { event in
            eventLog.append(event)
            logger.log(.notice, "Network location: \(event.event) \(event.detail ?? "")", category: .system)
        }
    }()
    private var locationReconcileInFlight = false
    private var locationReconcileWanted = false
    private var proxySettingsReconcileInFlight = false
    private var proxySettingsReconcileWanted = false
    /// The path source, from `effects`. Production is `NetworkMonitor`; a harness
    /// injects `FakeNetworkPathObserver`, so no test reads the machine's network.
    let networkPathObserver: any NetworkPathObserving
    /// The hops from the observers and the orchestrator's callbacks onto the
    /// main actor. Internal so the tests can `drain()` them instead of
    /// sleeping.
    let deliveries = ObserverDeliveries()
    private let proxySettingsNotifications = CoalescedObserverDelivery()
    /// Blocking platform work that needs no answer on the spot: serial, so a
    /// Stop's clear lands after the apply of a Start it overtook. The
    /// orchestrator's TCP relay commands run here too (`init`).
    let platformWork: PlatformWork
    private var dnsRelayRestartInFlight = false
    private var dnsReconcileInFlight = false
    private var dnsReconcileWanted = false
    let vpnStatusMonitor: VPNStatusObserving
    private let vpnFlapWindowBox: NIOLockedValueBox<RuntimeVPNFlapWindowConfig>
    /// Internal for the host's tests: whether the health probe runs beside the DNS module it watches.
    private(set) var dnsHealthTimer: DispatchSourceTimer?
    /// The health timer's one observation: the relay restart for the run that armed it found the pipeline still unresponsive. Control
    /// snapshots project it as the DNS error while the kernel runs the forwarder and reports no error of its own (`snapshot()`).
    private(set) var dnsRelayUnresponsive = false {
        didSet { if dnsRelayUnresponsive != oldValue { onControlStateChange?() } }
    }
    /// Whether the proxy module's surfaces are up: a proxy Start completed them, and no teardown of the proxy has begun since. Its
    /// split-DNS entry files exist only in that window, so VPN transitions and repairs must not apply them outside it.
    var runtimeStarted = false
    /// The one settle in flight. It stays set until the join it started has finished, whatever its caller saw
    /// (`settleStoppedEffects`). The join holds the root's session, not this host.
    var stoppedEffectsJoin: StoppedEffectsJoin?
    /// Settles admitted and not yet finished on this host: 0 or 1. Read-only, and internal for `@testable` tests, which
    /// wait on it to know that a settle has been admitted. It is not a public or package API.
    var stoppedEffectsJoinCount: Int { stoppedEffectsJoin == nil ? 0 : 1 }
    /// One lifecycle lane per module, fixed at three (decision 0031): which Start or Stop of the module is the latest, and a repeat of the
    /// effect in flight joins it. See `LifecycleLane` and `RuntimeHostLifecycle.swift`.
    let lanes = PrivateModuleSlots(
        proxy: LifecycleLane(name: "proxy"),
        dns: LifecycleLane(name: "dns"),
        tunnels: LifecycleLane(name: "tunnels")
    )
    /// The effect holding each lane while one runs, so an identical request can join it. A newer effect replaces it.
    var laneEffects = PrivateModuleSlots<RuntimeLifecycleEffect?>(proxy: nil, dns: nil, tunnels: nil)
    /// The single process quit, once one has begun, so a second caller joins it rather than tearing down again.
    var quit: Task<Void, Never>?
    /// Set once the quit's physical work has ended, so a control service composed after it starts shut down. Sticky.
    var quitEnded = false
    /// The latest generation any module lane has begun. Internal so a test can wait for a stop to have begun rather than time it: the
    /// stop's first visible effect is queued behind the work the test is holding. A whole-host operation advances every lane together.
    var lifecycleGeneration: Int { ControlModule.allCases.map { lanes[$0].current }.max() ?? 0 }
    /// Every lane generation begun, summed: it moves on any module's Start or Stop, so a settle compares it.
    var lifecycleBegun: Int { ControlModule.allCases.reduce(0) { $0 + lanes[$1].current } }
    /// Reload passes waiting for a start or stop to finish. Internal for the
    /// tests, for the same reason.
    var passesWaitingForLifecycle: Int { ControlModule.allCases.reduce(0) { $0 + lanes[$1].idleWaiterCount } }
    /// Whether no module lane has an operation in flight.
    var lanesIdle: Bool { ControlModule.allCases.allSatisfy { lanes[$0].isIdle } }

    /// Waits until each of `modules`' lanes is idle at once.
    func waitUntilIdle(_ modules: Set<ControlModule>) async {
        while let busy = ControlModule.allCases.first(where: { modules.contains($0) && !lanes[$0].isIdle }) {
            await lanes[busy].waitUntilIdle()
        }
    }
    /// VPN-gating policy for split-DNS entry files (single source of truth).
    /// Fed by `handleVPNStateChange`; every resolver-file apply path consults
    /// `entriesWanted`.
    var splitDNSGate = SplitDNSVPNGate()
    /// A failed entry-file write or removal, retried once the helper is
    /// seen available (#165).
    var splitDNSRepair = SplitDNSEntryFileRepair()
    /// While a repair is pending, asks the helper for its status every
    /// `splitDNSHelperCheckInterval` (backed off); gone otherwise. This host
    /// hears of no install, so the check is its only helper observation.
    private var splitDNSHelperCheck: Task<Void, Never>?
    private let splitDNSHelperCheckInterval: Duration
    private var splitDNSRetryInFlight = false
    /// Whether the last intercept-file refresh a switch action ran failed.
    /// The resolver flag's baseline covers it too, and a split-DNS retry
    /// writes no intercept files, so a repair does not stand in for it.
    private var resolverSwitchInterceptRefreshFailed = false
    /// The queue place (`SplitDNSEntryFileRepair.queue()`) of the refresh that last set the flag above. A refresh's result lands only if
    /// no refresh queued after it has landed, so a late completion never erases a newer failure.
    private var resolverSwitchInterceptRefreshPlace = 0

    /// Records an intercept refresh's result for the switch, unless a refresh queued after it already landed.
    private func recordInterceptRefresh(failed: Bool, place: Int) {
        guard place > resolverSwitchInterceptRefreshPlace else { return }
        resolverSwitchInterceptRefreshPlace = place
        resolverSwitchInterceptRefreshFailed = failed
    }
    /// Where the helper check and the preflight read the helper's status, from `effects`. `nil`
    /// makes no observation, so a test never reaches the installed helper.
    let helperStatusSource: (any HelperLifecycleManaging)?
    /// The preflight's held helper verdict, its generation and its two passes (`RuntimeHostPreflight.swift`).
    var preflight = RuntimeHostPreflightState()
    /// Stamps VPN reports on the monitor's callback; the split-DNS gate
    /// and the orchestrator each apply only reports newer than the last
    /// they applied, since deliveries can land out of order (#155).
    private let vpnSequencer = VPNObservationSequencer()
    private var splitDNSGateOrder = VPNObservationOrder()
    /// Launch-time crash recovery for the system-proxy, system-DNS and
    /// resolver-file surfaces. Started by `init` and joined by
    /// `awaitLaunchRecovery()` — see `LaunchRecovery` for why it is neither
    /// inline nor unordered.
    private var launchRecovery: LaunchRecovery?
    /// The process start `status()` reports. The entry point passes it in, so
    /// the host reads no clock of its own for status.
    private let startedAt: Date
    /// Ends the process after a terminal stop. The entry point passes
    /// `exit(0)`; the host itself never exits, so a test can observe the call.
    let terminalExit: @MainActor () -> Void

    /// Opens the host over its one configuration owner (decisions 0031 and 0032). The startup observation goes through the store before
    /// the orchestrator and the reconciler take their baselines, so every baseline comes from that observation. A caller that runs a
    /// startup migration runs it before this call, under the same session. Nothing else reads or writes configuration at open.
    ///
    /// Throws `RuntimeOpenRefusal` when the startup inputs are refused, and then no host is built. Throws `CancellationError` when the
    /// calling task was cancelled before construction, such as by a quit that began while the observation was out: no host is built, so
    /// no launch recovery, observer or timer starts. The observation writes nothing, so nothing started is abandoned.
    package static func open(
        stateSession: StateRootSession,
        logger: any LogSink,
        startupAllowsMissing: Bool,
        startedAt: Date,
        terminalExit: @escaping @MainActor () -> Void,
        effects: RuntimeHostEffects,
        networkLocationLimits: NetworkLocationLimits = .init(),
        environmentDriftInterval: Duration = .seconds(300),
        reapplyRetrySchedule: ConfigReapplyRetry.Schedule = .standard,
        splitDNSHelperCheckInterval: Duration = SplitDNSEntryFileRepair.helperCheckInterval
    ) async throws -> RuntimeHost {
        let store = ConfigurationStore(
            session: stateSession,
            access: effects.stateFiles,
            work: PlatformWork(label: "io.github.srps.Conduit.configuration-store")
        )
        // One incarnation for this host's whole life: its workflow's store contexts, its service, its snapshots and its replies.
        let incarnation = ControlHostIncarnation(rawValue: UUID())
        let workflow = RuntimeConfigurationWorkflow(store: store, incarnation: incarnation, startupAllowsMissing: startupAllowsMissing)
        let opened: RuntimeConfigurationWorkflow.Opened
        do {
            opened = try await workflow.open()
        } catch let refusal as RuntimeConfigurationWorkflow.OpenRefusal {
            throw RuntimeOpenRefusal(event: RuntimeEvent(payload: .configWorkflow(refusal.event)))
        }
        // Checked in the turn that constructs: construction starts recovery and the observers, and nothing after it is cancellable.
        try Task.checkCancellation()
        let host = RuntimeHost(
            stateSession: stateSession,
            logger: logger,
            loadedConfiguration: opened,
            incarnation: incarnation,
            workflow: workflow,
            startedAt: startedAt,
            terminalExit: terminalExit,
            effects: effects,
            networkLocationLimits: networkLocationLimits,
            environmentDriftInterval: environmentDriftInterval,
            reapplyRetrySchedule: reapplyRetrySchedule,
            splitDNSHelperCheckInterval: splitDNSHelperCheckInterval
        )
        host.emitConfigurationEvents(opened.events)
        return host
    }

    /// - Parameters:
    ///   - stateSession: the root's writer authority, taken before the load
    ///     that produced `loadedConfiguration` (decision 0028). The host keeps
    ///     it for its lifetime, and its environment is the resolved one. It also
    ///     carries whether the config file predated this launch, which tells an
    ///     upgrade from a fresh install to the resolver-file recovery
    ///     (`DNSManager.recoverLegacyOwnership`).
    ///   - startedAt: the process start that `status()` reports.
    ///   - terminalExit: called once a terminal stop (`stopRuntime(exitAfterStop:
    ///     true)`) has flushed its events. The entry point passes `exit(0)`.
    ///   - effects: every machine-facing adapter and owned path (decision 0033).
    ///     Production passes the real ones from `ConduitDaemon`; a simulator or
    ///     test passes fakes and scratch paths. Nothing is defaulted here.
    private init(
        stateSession: StateRootSession,
        logger: any LogSink,
        loadedConfiguration: RuntimeConfigurationWorkflow.Opened,
        incarnation: ControlHostIncarnation,
        workflow: RuntimeConfigurationWorkflow,
        startedAt: Date,
        terminalExit: @escaping @MainActor () -> Void,
        effects: RuntimeHostEffects,
        networkLocationLimits: NetworkLocationLimits = .init(),
        environmentDriftInterval: Duration = .seconds(300),
        reapplyRetrySchedule: ConfigReapplyRetry.Schedule = .standard,
        splitDNSHelperCheckInterval: Duration = SplitDNSEntryFileRepair.helperCheckInterval
    ) {
        self.incarnation = incarnation
        self.startedAt = startedAt
        self.terminalExit = terminalExit
        self.dnsResponds = effects.dnsResponds
        self.environmentDriftInterval = environmentDriftInterval
        self.reapplyRetrySchedule = reapplyRetrySchedule
        self.networkPathObserver = effects.networkPath
        self.networkLocationObserver = effects.networkLocation
        self.systemWakeObserver = effects.wake
        self.networkLocationStoreFactory = effects.networkLocationStoreFactory
        self.networkLocationLimits = networkLocationLimits
        self.stateSession = stateSession
        self.workflow = workflow
        self.environment = stateSession.environment
        let environment = stateSession.environment
        self.logger = logger
        self.config = loadedConfiguration.config
        self.platformConfig = loadedConfiguration.platformConfig
        self.commandRunner = effects.commandRunner
        self.loopbackPortProbe = effects.loopbackPortProbe
        self.homeDirectory = effects.homeDirectory
        self.resolverDirectory = effects.resolverDirectory
        self.reconciler = RuntimeReconciler(
            config: loadedConfiguration.config,
            platformConfig: loadedConfiguration.platformConfig
        )
        let flapBox = NIOLockedValueBox(
            RuntimeVPNFlapWindowConfig(
                graceSeconds: loadedConfiguration.config.vpnFlapGraceSeconds,
                minVisibleSeconds: loadedConfiguration.config.vpnFlapMinVisibleSeconds
            )
        )
        self.vpnFlapWindowBox = flapBox
        // The diagnostics log and its writers come before any privileged adapter. `RuntimeEventLog.setSink` does not
        // replay records appended before it, so the sink is bound here, before the factory can emit. An event from the
        // adapter's construction or from its first command then reaches the log and `events.ndjson` exactly once. The
        // log is the orchestrator's log below, shared with the diagnostic writers.
        let diagnosticsEventLog = RuntimeEventLog()
        let eventWriter = RuntimeEventFileWriter(
            fileURL: environment.eventsFile,
            logger: logger,
            destinationGuard: diagnosticDestinationGuard(
                for: .runtimeEvents, in: environment, writerLeaseFile: stateSession.writerLeaseFile
            ),
            eventLog: diagnosticsEventLog
        )
        self.eventWriter = eventWriter
        diagnosticsEventLog.setSink { [eventWriter] event in eventWriter.record(event) }
        self.snapshotWriter = makeSnapshotArtifactWriter(
            fileURL: environment.snapshotFile,
            logger: logger,
            destinationGuard: diagnosticDestinationGuard(
                for: .snapshot, in: environment, writerLeaseFile: stateSession.writerLeaseFile
            ),
            eventLog: diagnosticsEventLog
        )
        let privilege = effects.privilege({ diagnosticsEventLog.append($0) })
        self.privilegeClient = privilege.client
        self.helperStatusSource = privilege.helperStatus
        self.splitDNSHelperCheckInterval = splitDNSHelperCheckInterval
        self.auditedPrivilegeClient = AuditingPrivilegeClient(
            base: self.privilegeClient,
            eventSink: { diagnosticsEventLog.append($0) }
        )
        // The flap-window readers close over the box, not a copy of its values: a reload's new timings reach the monitor.
        self.vpnStatusMonitor = effects.vpnStatusMonitor(
            { flapBox.withLockedValue { $0.graceSeconds } },
            { flapBox.withLockedValue { $0.minVisibleSeconds } }
        )

        let tunnelResolverManager = TunnelResolverManager(
            privilegeClient: auditedPrivilegeClient,
            logger: logger,
            resolverDirectory: effects.resolverDirectory
        )
        // The connection audit writer reports a refused destination on the same log as the other diagnostic writers (#222).
        let auditSink = Self.makeAuditSink(
            for: loadedConfiguration.config,
            environment: environment,
            writerLeaseFile: stateSession.writerLeaseFile,
            logger: logger,
            eventLog: diagnosticsEventLog
        )
        // The relay's helper commands go through the same queue as the surface work, off the owner (#47). The DNS module's slot orders
        // them, so their place in the queue only delays them.
        let platformWork = PlatformWork(label: "io.github.srps.Conduit.daemon.platform-work")
        self.platformWork = platformWork
        let relayClient = auditedPrivilegeClient
        let orchestrator = ProxyOrchestrator(
            config: loadedConfiguration.config,
            logger: logger,
            relayCommand: { step in
                try await platformWork.run {
                    Result { try relayClient.execute(step.operation, values: step.values) }
                }.get()
            },
            authenticatorProvider: nil,
            pacEvaluator: effects.pacEvaluator,
            auditSink: auditSink,
            eventLog: diagnosticsEventLog,
            resolverManager: tunnelResolverManager,
            portHolderProbe: effects.portHolderProbe
        )
        self.orchestrator = orchestrator

        // The saved-password store is `effects.credentials`: production is the login Keychain. A host over a fake
        // machine gets an in-memory store, or it would read and write the installed app's credentials.
        let credentialManager = CredentialManager(
            identityProvider: { [snapshotProvider = orchestrator.configSnapshotProvider] in
                let c = snapshotProvider()
                return (domain: c.domain, username: c.username, profileName: c.profileName)
            },
            store: effects.credentials
        )
        self.credentialManager = credentialManager

        // `effects.gss == .system` keeps the factory's own GSS construction, so the Kerberos recovery and `auth.*`
        // event sink are bound there (see `RuntimeGSSSource`).
        let authenticatorProvider = credentialBasedAuthenticatorProvider(
            configProvider: orchestrator.configSnapshotProvider,
            credentialProvider: credentialManager,
            kerberosTicketRecovery: effects.kerberosTicketRecovery,
            outcomeHandler: { [weak orchestrator] outcome, host, reason, diagnostics in
                orchestrator?.reportAuthOutcome(outcome, host: host, reason: reason, diagnostics: diagnostics)
            },
            eventSink: { [eventLog = orchestrator.eventLog] event in eventLog.append(event) },
            kerberosTokenProvider: effects.gss.tokenProviderOverride
        )
        orchestrator.setAuthenticatorProvider(authenticatorProvider)

        // The hop to the main actor is kept: deliveries share one ordering with the other observers. The state is read
        // when the delivery runs, not taken from the value emitted earlier. A delivery queued before a later state
        // (the final stop, for one) must not submit an older snapshot after it. The canonical snapshot is the only
        // source, so no second revision counter is needed.
        orchestrator.onSnapshotChange = { [weak self, deliveries] _ in
            deliveries.deliver {
                guard let self else { return }
                self.writeSnapshotFile(snapshot: self.orchestrator.snapshot)
                self.onControlStateChange?()
            }
        }
        // `onConfigChange` is not wired. The orchestrator fires it only from `applyConfigChange`, which here runs only the reconciler's
        // pushes of inputs this host already adopted, and its delivery lands later. A writer there would move `config` outside
        // `adoptHostView`, which keeps the accepted view, the flap window and `configGeneration` together.
        // `onEvent` is not wired either: the kernel records each ladder outcome as a typed `proxy_recovery.*` event and logs it.
        self.networkPathObserver.setOnChange { [weak self, deliveries] change in
            deliveries.deliver {
                await self?.handleNetworkChange(change)
            }
        }
        // The interface name is read on the monitor's own delivery, not
        // after the hop, so a queued transition cannot lend its tunnel's
        // name to the one delivered before it.
        // Weak on both: the monitor stores this closure, so a strong capture
        // of the monitor would keep a stopped host's observer alive forever.
        self.vpnStatusMonitor.setOnChange { [weak self, deliveries, vpnSequencer, weak monitor = self.vpnStatusMonitor] state in
            let interfaceName = monitor?.connectedInterfaceName
            let sequence = vpnSequencer.next()
            deliveries.deliver {
                await self?.handleVPNStateChange(state, interfaceName: interfaceName, sequence: sequence)
            }
        }
        reconciler.host = self

        // Crash recovery: a run that was `SIGKILL`ed never tore down, so the
        // machine can still point at its dead proxy port and the helper's relay
        // at its dead forwarder, and launch is when the journal's record of
        // what was there before is most likely still the truth. Without this
        // the host leaves them until its next start or stop, which may be
        // never. Three calls in a fixed order, off the main actor.
        //
        // This host is never built from a failed load: its entry points run
        // `recoverWithoutConfiguration` instead, which skips only the
        // resolver-file ownership inference, so the scan here always has a
        // config.
        let dnsRecovery = systemDNSManager
        let proxyRecovery = systemConduit
        let resolverRecovery = dnsManager
        let legacyResolvers = LaunchRecovery.LegacyResolverInput(
            configs: [loadedConfiguration.config],
            configFilePredatesLaunch: stateSession.configFilePredatesLaunch,
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
        startLocationObserver()
        startWakeObserver()
        startEnvironmentDriftTimer()
    }

    /// The connection audit sink the orchestrator records each closed connection to, the composition's only one: off (the default) is the
    /// no-op sink; on, a bounded file at `auditLogPath`, or the root's `audit.ndjson` when no path is set, with `auditLogMaxBytes`. The
    /// guard protects the same resources as the other writers, the writer lease included, so a configured path that aliases one is refused
    /// with one fixed event and the runtime keeps serving.
    ///
    /// Built once, from the configuration the host opened with. A reload does not re-resolve it.
    private static func makeAuditSink(
        for config: ProxyConfig,
        environment: RuntimeEnvironment,
        writerLeaseFile: URL,
        logger: any LogSink,
        eventLog: RuntimeEventLog
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
        // An explicit path may leave the state directory, never land on a protected resource (#222).
        return FileConnectionAuditSink(
            fileURL: url,
            maxBytes: config.auditLogMaxBytes,
            logger: logger,
            destinationGuard: diagnosticDestinationGuard(
                for: .connectionAudit, in: environment, writerLeaseFile: writerLeaseFile
            ),
            eventLog: eventLog
        )
    }

    /// Waits for launch-time crash recovery before this host touches a
    /// platform surface. Free after the first call. Internal so a test that
    /// asserts on what recovery did joins it rather than polls.
    ///
    /// Joined at the head of `startRuntime`, `stopRuntime` and
    /// `performReload`. Every other path that touches a surface is
    /// reachable only after one of those has run: the reconciler's passes
    /// are queued by `performReload` alone, the network and VPN
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
    package func markReady(mode: String) async {
        await awaitLaunchRecovery()
        orchestrator.eventLog.append(RuntimeEvent(kind: .lifecycle, event: "daemon.ready", detail: "mode=\(mode)"))
        writeReadyFile()
        // The ready file precedes the snapshot write; readiness never promises the snapshot is already visible.
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        await flushEvents()
    }

    package func status() -> ControlDaemonStatus {
        var status = ControlDaemonStatus(snapshot: orchestrator.snapshot, config: config)
        status.daemon = ControlDaemonMetadata(
            processID: Int(ProcessInfo.processInfo.processIdentifier),
            executableName: "ConduitDaemon",
            startedAt: startedAt
        )
        status.configGeneration = configGeneration
        return status
    }

    /// The proxy module's surfaces, once its listener is up: the system proxy, the environment, and the split-DNS entry files with a sweep
    /// of stranded intercept files. One `platformWork` block under the proxy's token, so a proxy Stop issued while it is out queues its
    /// clears behind it. The DNS module captures the prior DNS servers it restores itself (`startDNSModule`).
    func applyProxySurfaces(_ start: RuntimeLifecycleEffect, config: ProxyConfig, platform: PlatformIntegrationConfig) async throws {
        let token = start.token(.proxy)
        let systemProxy = systemConduit
        let environment = environmentManager
        let resolvers = dnsManager
        let logger = self.logger
        let localPACURL = orchestrator.snapshot.bindings.localPACURL
        let vpnConnected = splitDNSGate.entriesWanted
        let gateReportSeen = splitDNSGateOrder.applied
        let interceptReadyAtStart = orchestrator.snapshot.bindings.dnsInterceptReady
        let forwarderRunningAtStart = orchestrator.snapshot.dnsRunState == .running
        let entryPlace = splitDNSRepair.queue()
        let entryFiles = await platformWork.run { () -> SplitDNSEntryFileRepair.Observation? in
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
            var entryFiles: SplitDNSEntryFileRepair.Observation?
            if platform.manageDNSResolvers {
                resolvers.serialized {
                    guard !token.isSuperseded else { return }
                    // With the VPN down, `apply` sweeps the entry files rather than writing them.
                    let operation: SplitDNSEntryFileRepair.Operation = vpnConnected ? .apply : .remove
                    let outcome: SplitDNSEntryFileRepair.Outcome
                    do {
                        try resolvers.apply(config: config, logger: logger, vpnConnected: vpnConnected)
                        outcome = .succeeded(operation)
                    } catch {
                        outcome = .failed(operation, error)
                        logger.log(.warning, "Could not apply DNS resolvers (non-fatal): \(error.localizedDescription)", category: .system)
                    }
                    // Refreshed from the DNS module's state at the start: with no
                    // forwarder running no intercept resolver file may exist, so
                    // this sweeps any a killed instance stranded. Only a start can
                    // repair that; a SIGKILL never runs cleanup.
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
                    // Under the same lock, against the input the operation wrote, and after the sweep: a file it removed is no residue.
                    entryFiles = SplitDNSEntryFileRepair.Observation.after(outcome, config: config, dnsManager: resolvers)
                }
            }
            return entryFiles
        }
        await recordSplitDNS(entryFiles, source: .start, startedAt: entryPlace)
        // A stop issued while the apply was out queued its clears behind
        // it, so the machine ends cleared; what must not happen now is the
        // rest of a start for a runtime that is down.
        try continueStart(start)
        // The proxy's surfaces are up from this turn, the one that decides
        // the correction below: a VPN transition taken while it is out then
        // acts as for a running proxy, and a Stop's teardown, which clears
        // this, is never undone by the start that it overtook.
        runtimeStarted = true
        // A VPN transition handled while the apply was out could act only
        // as a stopped runtime does, so it wrote nothing for a tunnel that
        // came up; put the entry files where the gate is now. A drop and a
        // reconnect leave the gate where the apply saw it, with the drop's
        // removal queued behind the apply, so any report the gate took since
        // writes them again.
        let gateMoved = splitDNSGate.entriesWanted != vpnConnected
            || (splitDNSGate.entriesWanted && splitDNSGateOrder.applied != gateReportSeen)
        if platform.manageDNSResolvers, gateMoved {
            await reconcileEntryFiles(config: config, runtimeStarted: true)
        }
    }

    /// Joins the work a stopped host still runs: its credential warm-up, and the observer deliveries admitted before
    /// this call with their cascades. Those are the only two waits. Other OS callbacks that may arrive later are not
    /// covered, and no other lifecycle work is joined here. The caller chooses the deadline; nothing here picks one.
    ///
    /// Contract (decision 0033):
    /// - `.settled` means exactly this: the credential warm-up captured when the settle began, and the observer
    ///   deliveries admitted before it with their cascades, have finished, and the runtime was down at that moment. It
    ///   is not a claim that every writer, task or OS callback has ended.
    /// - The caller keeps this host, and so the root, through its final diagnostic flush, and drops them only after
    ///   that flush. A timed-out settle is not a release: the caller keeps the host and pins it, as the harness does
    ///   for an unconfirmed shutdown, until a later settle reports `.settled`.
    /// - One join is in flight per host, and a settle that finds one returns `.busy` before it allocates anything.
    ///   A join runs past the caller's deadline. It holds the root's `StateRootSession` directly, as a defensive
    ///   measure, so the root is not released while it still runs. That is not a write-quiescence claim.
    /// - A start, a stop, or an adopted reload admitted while the join is pending makes the result `.superseded`.
    package func settleStoppedEffects(until deadline: ContinuousClock.Instant) async -> StoppedEffectsSettlement {
        guard stoppedEffectsJoin == nil else { return .busy }
        if let pending = stoppedEffectsPending() { return pending }
        guard ContinuousClock.now < deadline else { return .deadlineExpired }
        let join = StoppedEffectsJoin(
            lifecycleGeneration: lifecycleBegun,
            configGeneration: configGeneration,
            intentGeneration: workflow.generation
        )
        stoppedEffectsJoin = join
        let warmup = credentialWarmup
        let deliveries = self.deliveries
        let session = stateSession
        join.armDeadline(deadline)
        // The join holds the root's session itself, so the root stays claimed until the warm-up and deliveries have
        // finished, whether or not the caller's deadline or the host's owner has gone. It holds the host weakly: the
        // result is computed on the main actor from the host's state, and only if the host is still there.
        Task { @MainActor [weak self] in
            await warmup?.value
            await deliveries.drain()
            withExtendedLifetime(session) {}
            self?.finishStoppedEffectsJoin(join)
        }
        return await join.outcome()
    }

    /// The runtime input the machine holds: the reconciler's baseline, which moves only when a push reports the input held. Machine-acting
    /// paths read this. The host's `config` is the accepted view that status reports, and it can run ahead of the machine.
    var heldRuntimeConfig: ProxyConfig { reconciler.lastReconciledConfig }

    /// The platform flags the reconciler has completed actions for. A flag moves when its action lands, so cleanup clears against this
    /// baseline. It is not a reading of each surface's physical state: the reconciler also adopts a flag with no action to run while the
    /// runtime is down. Retries, reconciles, drift and the start apply read the desired flags (`platformConfig`), because a switch that
    /// failed to land is what they must retry, and the baseline still names the old value for it.
    var completedPlatformBaseline: PlatformIntegrationConfig { reconciler.lastReconciledPlatformConfig }

    /// Whether the host's actual runtime is down: every module lane is idle, no proxy or DNS is up, and no tunnel is
    /// bound. The `runtimeStarted` flag is one input, not the answer, since a reload can leave DNS up while it is false.
    private var runtimeIsDown: Bool {
        lanesIdle && !runtimeStarted && modulesDown() == Self.allModules
    }

    /// What keeps a settle from answering `.settled` now, or nil. A settle asks when it begins and its join asks when it finishes, in this
    /// one order, so the same host state gets the same answer at either end. Every answer fails closed. A configuration operation comes
    /// first, since it may still write. Then a Start, Stop or reload call not yet finished, a call still waiting for launch recovery
    /// included, or a runtime still up. A pass in flight is the last answer: with no call pending and the runtime down, it is the only
    /// work left.
    private func stoppedEffectsPending() -> StoppedEffectsSettlement? {
        guard workflow.isIdle else { return .configurationPending }
        guard pendingAdmissions == 0, runtimeIsDown else { return .runtimeActive }
        guard !reconciler.hasPassInFlight else { return .reconcilePending }
        return nil
    }

    /// Frees the slot and answers `.settled` only if lifecycle, configuration and intent generations are unchanged and nothing is
    /// pending (`stoppedEffectsPending`).
    private func finishStoppedEffectsJoin(_ join: StoppedEffectsJoin) {
        if stoppedEffectsJoin === join { stoppedEffectsJoin = nil }
        guard lifecycleBegun == join.lifecycleGeneration, configGeneration == join.configGeneration,
              workflow.generation == join.intentGeneration else {
            join.finish(.superseded)
            return
        }
        join.finish(stoppedEffectsPending() ?? .settled)
    }

    /// An explicit reload-and-reconcile (decision 0032), counted and captured from this call: the host's own facade of `performReload`.
    @discardableResult
    package func reloadConfiguration() async -> RuntimeReloadDecision {
        // Counted from the call, so a settle that starts while this reload waits for recovery sees it as pending work.
        pendingAdmissions += 1
        defer { pendingAdmissions -= 1 }
        return await performReload(capturedAt: workflow.generation, requestID: nil)
    }

    /// The one reload, which the facade and the control command both run. The workflow observes the files through the store, read-only,
    /// and decides what may apply. The caller captured `captured` before its first suspension, launch recovery included, and counts
    /// itself pending from then, so an admission made during that wait makes this reload stale. A stale or held observation changes no
    /// applied view, reconciler baseline or configuration generation. `requestID` is the client request the store context names.
    func performReload(capturedAt captured: Int, requestID: ControlRequestID?) async -> RuntimeReloadDecision {
        await awaitLaunchRecovery()
        let outcome = await workflow.reload(capturedAt: captured, requestID: requestID)
        emitConfigurationEvents(outcome.events)
        // An adopted observation changes the host view a pending settle read, whether or not its runtime input may apply.
        if outcome.adopted {
            stoppedEffectsJoin?.finish(.superseded)
        }
        switch outcome.answer {
        case .decided(let decision):
            writeSnapshotFile(snapshot: orchestrator.snapshot)
            return decision
        case .eligible(let runtime, let platform):
            // Every eligible reload counts, an unchanged one included.
            adoptHostView(runtime: runtime, platform: platform)
        }
        logNonBlockingConfigProblems()
        // The pass acts, and the answer calls it current, only while this reload's observation still stands (decision 0032): no newer
        // Start or Stop, no fence, and no later adoption of another accepted view, by a reload or an apply, which moves `configGeneration`.
        // Weak: the reconciler keeps the last admission for its retry.
        let view = configGeneration
        let stands: @MainActor () -> Bool = { [weak self, workflow] in
            guard let self else { return false }
            return workflow.isLatest(captured) && !workflow.stopFenced && self.configGeneration == view
        }
        // Queued and then awaited: a caller that reloads and then stops must
        // see the machine the reload left, and the control path has no
        // editor to hand back to while the pass runs. What the pass does is
        // the `RuntimeReconcilerHost` conformance below.
        reconciler.reconcile(config: config, platformConfig: platformConfig, isCurrent: stands)
        await reconciler.drain()
        // Read once after the drain, with the same predicate: anything that replaced this observation during the pass may have stopped it.
        let currentAtEnd = stands()
        logger.log(.notice, "Configuration reloaded.", category: .general)
        // Submitted, not awaited, as in `startRuntime`.
        writeSnapshotFile(snapshot: orchestrator.snapshot)
        return .adopted(.reconcileAttempted(currentAtEnd: currentAtEnd))
    }

    /// The one emitter for `config.workflow.*` (decision 0031). Each typed value becomes its record, and the log line is derived from it.
    func emitConfigurationEvents(_ events: [ConfigurationWorkflowEvent]) {
        for event in events {
            let record = RuntimeEvent(payload: .configWorkflow(event))
            orchestrator.eventLog.append(record)
            logger.log(Self.configurationLogLevel(event), "Config: \(record.event) \(record.detail ?? "")", category: .system)
        }
    }

    private static func configurationLogLevel(_ event: ConfigurationWorkflowEvent) -> LogLevel {
        switch event {
        case .observed(let observed):
            switch observed.observation {
            case .adopted: .notice
            case .refused: .warning
            }
        case .committed(let committed):
            switch committed.write {
            case .persisted, .unchanged: .notice
            case .notPersisted, .unknown, .conflict, .notAttempted: .warning
            }
        case .held, .superseded:
            .warning
        }
    }

    /// Converges the prepared pair through the reconciler under this Start's admission, then updates the host view. A newer observation
    /// or write that replaced the captured pair while the push waited holds the Start; it is not rebound to that input (decision 0037).
    func pushVerifiedInput(_ prepared: RuntimeConfigurationWorkflow.PreparedStart) async -> Bool {
        guard workflow.isCurrent(prepared) else { return false }
        // Through the reconciler, so the orchestrator push is one serialized pass that carries this Start's admission. The reconciler's
        // baseline moves only to what a push reports as held, so an abandoned push leaves the baseline honest.
        let verified = prepared.input
        reconciler.reconcile(config: verified.runtime, platformConfig: verified.platform, isCurrent: { [workflow] in
            workflow.isCurrent(prepared)
        })
        await reconciler.drain()
        guard workflow.isCurrent(prepared) else { return false }
        // The store still holds the pair this Start captured, so a reload since then observed the same bytes. A Start counts only when it
        // changes the accepted pair, which is after a held reload: the reload verified the observation the store adopted, and this
        // explicit Start committed it. An external edit with no reload is never adopted here: its baseline conflict holds the Start
        // (decision 0027).
        if ConfigDiff(old: config, new: verified.runtime).inputChanged || platformConfig != verified.platform {
            adoptHostView(runtime: verified.runtime, platform: verified.platform)
        }
        // The pair is adopted with no suspension since the check above, so the members' fences clear now (decision 0035).
        return workflow.authorize(prepared)
    }

    /// The one writer of the accepted host view after `open`: the runtime and platform inputs status reports, the VPN monitor's
    /// flap-window timings, and `configGeneration`, which counts adoptions of this view. The view is not a durable or applied counter; the
    /// machine-acting paths read the reconciler's baselines. The caller logs the non-blocking validation problems once.
    func adoptHostView(runtime: ProxyConfig, platform: PlatformIntegrationConfig) {
        config = runtime
        platformConfig = platform
        vpnFlapWindowBox.withLockedValue { window in
            window.graceSeconds = runtime.vpnFlapGraceSeconds
            window.minVisibleSeconds = runtime.vpnFlapMinVisibleSeconds
        }
        configGeneration += 1
    }

    /// The errors `LocalProxyServer.start` deliberately ignores. A blocking
    /// one surfaces as the start failure itself; a non-blocking one — an
    /// intercept rule whose files will be withheld — surfaces nowhere else in
    /// this host. The app shows its own banner from the draft; headless, the
    /// log is the banner.
    func logNonBlockingConfigProblems() {
        for error in config.validate() where !error.blocksProxyStart {
            logger.log(.warning, "Config validation: \(error.localizedDescription)", category: .system)
        }
    }

    /// The intercept resolver file refresh for `config`, with the DNS module's bindings read in this turn, to run on `platformWork`. The
    /// rule is `DNSManager.refreshInterceptFiles`. The platform is the caller's: a pass refreshes with the flags it is applying, and a
    /// settle with the flags it is landing. It is never read live from the host, because the host's flags can be ahead of the pass.
    private func interceptRefresh(for config: ProxyConfig, platform: PlatformIntegrationConfig) -> @Sendable () throws -> Void {
        guard platform.manageDNSResolvers else { return {} }
        let resolvers = dnsManager, logger = self.logger
        let interceptReady = orchestrator.snapshot.bindings.dnsInterceptReady
        let forwarderRunning = orchestrator.snapshot.dnsRunState == .running
        return {
            try resolvers.refreshInterceptFiles(
                config: config, interceptReady: interceptReady, forwarderRunning: forwarderRunning, logger: logger
            )
        }
    }

    /// Event first, log line derived from it.
    func recordLifecycle(_ event: RuntimeEvent, level: LogLevel = .notice) {
        orchestrator.eventLog.append(event)
        logger.log(level, "Lifecycle: \(event.event) \(event.detail ?? "")", category: .general)
    }

    func testUpstream(named name: String) async -> ProbeResult? {
        await orchestrator.testUpstream(named: name)
    }

    /// The readiness and shutdown flush: audit, events, then the snapshot, inside one `DiagnosticFlushPhase`
    /// (see `DiagnosticFlush`). Every writer is awaited. The logger's own flush stays a separate, bounded,
    /// synchronous call; moving the whole runtime owner off the main actor is #47.
    @discardableResult
    package func flushEvents() async -> DiagnosticFlushReport {
        reportWriterLoss()
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(),
            audit: orchestrator.auditSink,
            events: eventWriter,
            snapshot: snapshotWriter,
            eventLog: orchestrator.eventLog,
            logger: logger
        )
        if !report.allConfirmed {
            logger.log(.warning, "Observability flush not fully confirmed: audit=\(report.audit.rawValue) events=\(report.events.rawValue) snapshot=\(report.snapshot.rawValue).", category: .general)
        }
        logger.flush(timeout: 2)
        return report
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

    /// Only a material change resets DNS transports and refetches PAC; the
    /// DNS reconcile runs for every report, since a VPN client can rewrite
    /// service DNS with no material path change (#101, `NetworkPathReports`).
    func startLocationObserver() {
        networkLocationObserver.start(onChange: { [weak self, deliveries] result in
            deliveries.deliver { await self?.handleLocationChange(result) }
        }, onSettingsChange: { [weak self, deliveries, proxySettingsNotifications] in
            proxySettingsNotifications.deliver(using: deliveries) {
                guard let self else { return }
                self.recordLifecycle(RuntimeEvent(kind: .config, event: "platform.settings_observed",
                                                  detail: "surface=proxies source=preferences"))
                await self.reconcileSystemProxyIfRunning()
            }
        })
    }

    private func handleLocationChange(_ result: Result<String, NetworkSettingsError>) async {
        switch result {
        case .success(let locationID):
            recordLifecycle(RuntimeEvent(kind: .config, event: "platform.location_observed", detail: "location=\(locationID)"))
        case .failure(let error):
            recordLifecycle(RuntimeEvent(kind: .config, event: "platform.location_failed", detail: "operation=observe reason=\(error.localizedDescription)"))
            return
        }
        guard !locationReconcileInFlight else { locationReconcileWanted = true; return }
        locationReconcileInFlight = true
        defer { locationReconcileInFlight = false }
        repeat {
            locationReconcileWanted = false
            await awaitLaunchRecovery()
            // A location switch touches both modules' surfaces, so it waits for both lanes and each surface checks its own module.
            await waitUntilIdle([.proxy, .dns])
            let state = runtimeState()
            let proxyToken = lanes.proxy.observationToken
            let dnsToken = lanes.dns.observationToken
            let proxy = systemConduit, dns = systemDNSManager
            let config = heldRuntimeConfig, platform = platformConfig
            let pacURL = orchestrator.snapshot.bindings.localPACURL
            let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
            let events = orchestrator.eventLog, logger = logger
            let proxyRetry = await platformWork.run { () -> Duration? in
                var retry: Duration?
                do {
                    if !proxyToken.isSuperseded {
                        retry = try proxy.reconcileLocation(config: config, mode: platform.systemProxyMode, localPACURL: pacURL,
                                                            apply: platform.manageSystemProxy && state.proxyIsUp)
                    }
                } catch {
                    let event = RuntimeEvent(kind: .config, event: "platform.location_failed", detail: "operation=reconcile surface=systemProxy reason=\(error.localizedDescription)")
                    events.append(event)
                    logger.log(.warning, "Network location: \(event.detail ?? "")", category: .system)
                }
                do {
                    if !dnsToken.isSuperseded {
                        try dns.reconcileLocation(apply: platform.manageSystemDNS && state.dnsIsUp, forwarderPort: forwarderPort, logger: logger)
                    }
                } catch {
                    let event = RuntimeEvent(kind: .config, event: "platform.location_failed", detail: "operation=reconcile surface=systemDNS reason=\(error.localizedDescription)")
                    events.append(event)
                    logger.log(.warning, "Network location: \(event.detail ?? "")", category: .system)
                }
                return retry
            }
            if let proxyRetry { scheduleProxyRepairRetry(after: proxyRetry) }
        } while locationReconcileWanted
    }

    private func handleNetworkChange(_ path: NetworkPathState) async {
        await NetworkPathReports.receive(
            path, orchestrator: orchestrator,
            act: { [orchestrator] change in await orchestrator.handleNetworkChange(change) },
            reconcileSystemDNS: { [weak self] in await self?.reconcileSystemDNSIfRunning() },
            reconcileSystemProxy: { [weak self] in
                self?.deliveries.deliver { [weak self] in await self?.reconcileSystemProxyIfRunning() }
            }
        )
    }

    private func handleVPNStateChange(_ state: VPNObservedState, interfaceName: String?, sequence: UInt64) async {
        // Gate update and decision must stay in one turn, and the entry-file
        // work is queued in it: the decision reads the gate's current state,
        // and a second VPN transition interleaving at a suspension point
        // would make this handler act on the newer flip instead of its own
        // (the gate's documented contract). Queued in that turn, each flip's
        // work lands on `platformWork` in the order the flips were taken.
        // Entry files live and die with the tunnel — see `SplitDNSVPNGate`.
        // `runtimeStarted` is passed rather than used as a guard: it gates
        // *applying* files, never removing them, because a runtime that died
        // with its files applied is exactly the case that strands them
        // against unreachable servers.
        // A report older than one the gate already took is not the tunnel's
        // state; the orchestrator still sees it and drops it itself.
        let entriesWantedChanged = splitDNSGateOrder.admit(sequence) ? splitDNSGate.update(state) : false
        // Its own delivery, which queues its work in a later turn whatever this one awaits, so it is asked for here.
        deliveries.deliver { [weak self] in await self?.reconcileSystemProxyIfRunning() }
        if platformConfig.manageDNSResolvers, entriesWantedChanged {
            await reconcileEntryFiles(config: config, runtimeStarted: runtimeStarted)
        }
        // The orchestrator hears of the transition after its entry files landed, as it did when they were written inline.
        await orchestrator.handleVPNStateChange(state, interfaceName: interfaceName, sequence: sequence)
        await reconcileSystemDNSIfRunning()
    }

    /// Puts the entry files where the gate wants them now (`SplitDNSVPNGate.entryFileOperation`). Decided, given its place in the repair's
    /// order and queued on `platformWork` in this turn, so work decided after it lands after it; recorded once it returns. The VPN
    /// transitions and the corrections after a write queued with an older gate state all come through here.
    func reconcileEntryFiles(config: ProxyConfig, runtimeStarted: Bool) async {
        guard let operation = splitDNSGate.entryFileOperation(runtimeStarted: runtimeStarted) else { return }
        let resolvers = dnsManager, logger = self.logger
        let place = splitDNSRepair.queue()
        let observed = await platformWork.run {
            // The operation and its residue under one lock, against the input it wrote.
            resolvers.serialized {
                SplitDNSEntryFileRepair.Observation.after(
                    SplitDNSVPNGate.perform(operation, config: config, dnsManager: resolvers, logger: logger),
                    config: config, dnsManager: resolvers
                )
            }
        }
        await recordSplitDNS(observed, source: .vpnTransition, startedAt: place)
    }

    // MARK: - Split-DNS entry-file repair (#165)

    /// Feeds an entry-file outcome to `splitDNSRepair`, event first, and keeps the helper check running while something is pending. The
    /// observation was read on `platformWork` beside the operation, so recording reads no disk here. `startedAt` is the operation's place
    /// (`SplitDNSEntryFileRepair.queue()`), taken in the turn it was queued.
    func recordSplitDNS(
        _ observed: SplitDNSEntryFileRepair.Observation?,
        source: SplitDNSEntryFileRepair.Source,
        startedAt: Int
    ) async {
        guard let observed else { return }
        let residue = observed.outcome.failure == nil && splitDNSRepair.pending != nil && observed.residue
        let wasPending = splitDNSRepair.pending != nil
        splitDNSRepair.record(observed.outcome, source: source, startedAt: startedAt, residue: residue, report: recordSplitDNSEvent)
        // A new episode starts its check at the first interval, not at the
        // back-off a check left over from the last episode is sleeping on.
        if !wasPending, splitDNSRepair.pending != nil { endSplitDNSHelperCheck() }
        scheduleSplitDNSHelperCheck()
        // Settled by something other than a retry (a VPN flip, a start, a
        // config change): the switch's action has landed all the same.
        if wasPending { await settleResolverSwitchBaseline(platform: platformConfig) }
    }

    private func recordSplitDNSEvent(_ event: RuntimeEvent, level: LogLevel) {
        orchestrator.eventLog.append(event)
        logger.log(level, "Split DNS: \(event.event) \(event.detail ?? "")", category: .system)
    }

    /// One observation of the helper for the split-DNS repair. A retry waits for the
    /// start or stop in flight, so `runtimeStarted` is settled when it reads it.
    ///
    /// A dispatched retry ends the helper check: the retry's completion
    /// schedules the next one from the attempt count it leaves, rather than
    /// a check sleeping on the count from before it. Returns whether it
    /// dispatched one.
    @discardableResult
    func observeHelperForSplitDNS(available: Bool, trigger: String) -> Bool {
        guard splitDNSRepair.shouldRetry(helperAvailable: available), !splitDNSRetryInFlight else { return false }
        splitDNSRetryInFlight = true
        endSplitDNSHelperCheck()
        deliveries.deliver { [weak self] in await self?.retrySplitDNSEntryFiles(trigger: trigger) }
        return true
    }

    private func retrySplitDNSEntryFiles(trigger: String) async {
        defer { splitDNSRetryInFlight = false }
        await awaitLaunchRecovery()
        // Entry files are the proxy module's surface.
        await waitUntilIdle([.proxy])
        // The decision and the queueing in one turn: the write acts on the
        // gate state it was decided from (`SplitDNSEntryFileRepair.retry`).
        let managed = platformConfig.manageDNSResolvers
        guard let operation = splitDNSRepair.planRetry(
            trigger: trigger, gate: splitDNSGate, resolversManaged: managed, runtimeStarted: runtimeStarted, report: recordSplitDNSEvent
        ) else { return }
        let resolvers = dnsManager, logger = self.logger, config = self.config
        let place = splitDNSRepair.queue()
        let outcome = await platformWork.run {
            resolvers.serialized {
                SplitDNSEntryFileRepair.runRetry(operation, resolversManaged: managed, config: config, dnsManager: resolvers, logger: logger)
            }
        }
        // A retry sweeps the residue itself.
        await recordSplitDNS(SplitDNSEntryFileRepair.Observation(outcome: outcome, residue: false), source: .retry, startedAt: place)
    }

    /// A settled repair did what the resolver switch's action had to, so the
    /// reconciler's baseline follows (`markResolverSwitchLanded`), whatever
    /// settled it: entry files that landed must be torn down when the switch
    /// next turns off, and a baseline left behind diffs that flip as no
    /// change. With the switch off the settling operation is the whole
    /// teardown. With it on, it writes only entry files, so an intercept
    /// refresh the switch-on owes is retried here first; one that fails
    /// again is reported (`platform.split_dns_intercept_refresh_failed`),
    /// and the next DNS start or DNS-affecting config change rewrites them.
    /// `platform` is the desired flags the switch is landing, carried by the caller. The baseline has not moved yet at this point, so it
    /// cannot say whether the switch is on. The baseline follows in this turn, since no refresh result changes it; the refresh is queued
    /// on `platformWork` in this turn too, with a queue place, so its result never replaces a newer refresh's (`recordInterceptRefresh`).
    /// A failure is reported either way.
    private func settleResolverSwitchBaseline(platform: PlatformIntegrationConfig) async {
        guard splitDNSRepair.pending == nil else { return }
        reconciler.markResolverSwitchLanded(manageDNSResolvers: platform.manageDNSResolvers)
        guard platform.manageDNSResolvers, resolverSwitchInterceptRefreshFailed else { return }
        let refresh = interceptRefresh(for: heldRuntimeConfig, platform: platform)
        let place = splitDNSRepair.queue()
        let failure = await platformWork.run { () -> String? in
            do {
                try refresh()
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        recordInterceptRefresh(failed: failure != nil, place: place)
        guard let failure else { return }
        recordSplitDNSEvent(
            RuntimeEvent(kind: .config, event: "platform.split_dns_intercept_refresh_failed", detail: "reason=\(failure)"),
            level: .warning
        )
    }

    /// While a repair is pending, one backed-off helper read at a time: a
    /// helper installed outside the app reports nothing.
    private func scheduleSplitDNSHelperCheck() {
        guard splitDNSRepair.pending != nil, splitDNSHelperCheck == nil, let helper = helperStatusSource else { return }
        let base = splitDNSHelperCheckInterval
        splitDNSHelperCheck = Task { @MainActor [weak self] in
            while let delay = self?.splitDNSHelperCheckDelay(base: base) {
                // Cancelled: a retry took over, a new episode restarted the
                // check, or quit. Whoever cancelled it has cleared the handle.
                do { try await Task.sleep(for: delay) }
                catch { return }
                guard self?.splitDNSRepair.pending != nil else { break }
                // A raw reading: `.busy` is not `.installed`, so a helper
                // still serving another request is no evidence (#210).
                let reading = await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .utility).async { continuation.resume(returning: helper.status) }
                }
                guard !Task.isCancelled else { return }
                if self?.observeHelperForSplitDNS(available: reading == .installed, trigger: "helper_check") == true { return }
            }
            self?.splitDNSHelperCheck = nil
        }
    }

    private func endSplitDNSHelperCheck() {
        splitDNSHelperCheck?.cancel()
        splitDNSHelperCheck = nil
    }

    /// `nil` once nothing is pending, which ends the check.
    private func splitDNSHelperCheckDelay(base: Duration) -> Duration? {
        splitDNSRepair.pending == nil ? nil : splitDNSRepair.helperCheckDelay(base: base)
    }

    /// Same bounded proxy-drift recovery as the app, guarded against a later stop.
    func reconcileSystemProxyIfRunning() async {
        scheduleEnvironmentDriftPass(trigger: .observed)
        guard platformConfig.manageSystemProxy else { return }
        guard !proxySettingsReconcileInFlight else { proxySettingsReconcileWanted = true; return }
        proxySettingsReconcileInFlight = true
        defer { proxySettingsReconcileInFlight = false; proxySettingsReconcileWanted = false }
        repeat {
            proxySettingsReconcileWanted = false
            await awaitLaunchRecovery()
            await waitUntilIdle([.proxy])
            guard platformConfig.manageSystemProxy, runtimeState().proxyIsUp else { return }
            let token = lanes.proxy.observationToken
            let proxy = systemConduit, config = heldRuntimeConfig, platform = platformConfig
            let pacURL = orchestrator.snapshot.bindings.localPACURL
            let events = orchestrator.eventLog, logger = logger
            let retry = await platformWork.run { () -> Duration? in
                guard !token.isSuperseded else { return nil }
                do {
                    return try proxy.reconcileLocation(config: config, mode: platform.systemProxyMode, localPACURL: pacURL, apply: true)
                } catch {
                    let event = RuntimeEvent(kind: .config, event: "platform.location_failed",
                                             detail: "operation=reconcile surface=systemProxy reason=\(error.localizedDescription)")
                    events.append(event)
                    logger.log(.warning, "Network location: \(event.detail ?? "")", category: .system)
                    return nil
                }
            }
            if let retry { scheduleProxyRepairRetry(after: retry) }
        } while proxySettingsReconcileWanted
    }

    // MARK: - Shell environment drift (#175)

    /// One environment drift pass after the work in flight. Fed by every
    /// trigger of the system proxy drift pass, and by the periodic tick:
    /// none of those triggers is guaranteed after a silent wipe.
    private func scheduleEnvironmentDriftPass(trigger: EnvironmentDriftRepair.Trigger) {
        deliveries.deliver { [weak self] in await self?.reconcileEnvironmentDriftIfRunning(trigger: trigger) }
    }

    /// Off the main actor: three profile reads and six `launchctl getenv`,
    /// and a repair only when something drifted. Coalesced like the system
    /// proxy pass, and checked against the lifecycle under the manager's
    /// lock before it writes (`EnvironmentManager.repair`).
    private func reconcileEnvironmentDriftIfRunning(trigger: EnvironmentDriftRepair.Trigger) async {
        guard platformConfig.manageEnvironmentVariables else { return }
        guard !environmentDriftInFlight else {
            environmentDriftPending = trigger.coalesced(with: environmentDriftPending)
            return
        }
        environmentDriftInFlight = true
        defer { environmentDriftInFlight = false; environmentDriftPending = nil }
        var trigger = trigger
        repeat {
            environmentDriftPending = nil
            await awaitLaunchRecovery()
            await waitUntilIdle([.proxy])
            guard platformConfig.manageEnvironmentVariables, runtimeState().proxyIsUp else { return }
            let token = lanes.proxy.observationToken
            let repair = environmentDriftRepair, config = heldRuntimeConfig
            let generation = environmentManager.generation, passTrigger = trigger
            let retry = await platformWork.run {
                repair.run(config: config, generation: generation, trigger: passTrigger, isCurrent: { !token.isSuperseded })
            }
            if let retry { scheduleEnvironmentRepairRetry(after: retry) }
            guard let next = environmentDriftPending else { break }
            trigger = next
        } while true
    }

    /// One pass when a withheld repair's window reopens, since no trigger
    /// may follow. A newer schedule replaces it.
    private func scheduleEnvironmentRepairRetry(after delay: Duration) {
        environmentRepairRetry?.cancel()
        environmentRepairRetry = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return } // Cancelled by a newer schedule; that one runs instead.
            await self?.reconcileEnvironmentDriftIfRunning(trigger: .retry)
        }
    }

    /// The periodic tick: one task for the host's lifetime. `Task.sleep`
    /// runs on the continuous clock, so a tick due during sleep fires once
    /// after wake rather than once per missed interval.
    private func startEnvironmentDriftTimer() {
        let interval = environmentDriftInterval
        environmentDriftTimer = Task { @MainActor [weak self] in
            while true {
                do { try await Task.sleep(for: interval) }
                catch { return }
                guard let self else { return }
                self.scheduleEnvironmentDriftPass(trigger: .timer)
            }
        }
    }

    /// One retry of a failed re-apply (#194): the drift pass for `surface`, run once and judged.
    private func retryReapply(_ surface: ConfigReapplyRetry.Surface, token: LifecycleLane.Token) async -> ConfigReapplyRetry.Outcome {
        await awaitLaunchRecovery()
        await waitUntilIdle([.proxy])
        guard !token.isSuperseded else { return .notWanted(reason: "superseded") }
        guard runtimeState().proxyIsUp else { return .notWanted(reason: "proxy_stopped") }
        let config = heldRuntimeConfig, platform = platformConfig
        switch surface {
        case .systemProxy:
            guard platform.manageSystemProxy else { return .notWanted(reason: "switch_off") }
            let (outcome, retry) = await SystemProxyReapplyRetry.run(
                manager: systemConduit, work: platformWork, config: config, mode: platform.systemProxyMode,
                localPACURL: orchestrator.snapshot.bindings.localPACURL, token: token,
                fence: reconciler.platformRequest, events: orchestrator.eventLog, logger: logger)
            if let retry { scheduleProxyRepairRetry(after: retry) }
            return outcome
        case .environment:
            guard platform.manageEnvironmentVariables else { return .notWanted(reason: "switch_off") }
            let repair = environmentDriftRepair, generation = environmentManager.generation
            let pass = await platformWork.run {
                repair.pass(config: config, generation: generation, trigger: .retry, isCurrent: { !token.isSuperseded })
            }
            if let retry = pass.retry { scheduleEnvironmentRepairRetry(after: retry) }
            return pass.settled ? .applied : .failed(reason: pass.reason ?? "unsettled")
        }
    }

    /// One pass when a contended repair budget reopens, since no notification
    /// may follow.
    private func scheduleProxyRepairRetry(after delay: Duration) {
        proxyRepairRetry?.cancel()
        proxyRepairRetry = Task { [weak self] in
            do { try await Task.sleep(for: delay) }
            catch { return } // Cancelled by a newer schedule; that one runs instead.
            await self?.reconcileSystemProxyIfRunning()
        }
    }

    /// The system DNS reconcile, without a debounce: off the main
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
    func reconcileSystemDNSIfRunning() async {
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
            await waitUntilIdle([.dns])
            guard systemDNSReconcileIsDue else { break }
            let token = lanes.dns.observationToken
            let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
            await platformWork.run { [logger] in
                guard !token.isSuperseded else { return }
                manager.reconcile(logger: logger, forwarderPort: forwarderPort)
            }
        } while dnsReconcileWanted && systemDNSReconcileIsDue
        dnsReconcileWanted = false
    }

    private var systemDNSReconcileIsDue: Bool {
        platformConfig.manageSystemDNS && orchestrator.snapshot.dnsRunState == .running
    }

    /// Arms the probe for the DNS run that holds the lane now, and starts its observation clear.
    func startDNSHealthTimer(forwarderPort: Int) {
        stopDNSHealthTimer()
        let manager = systemDNSManager
        // Taken when the timer is armed, not when a probe completes: a probe still out when a Stop or a newer Start begins names the
        // run that asked for it, so its reading is never taken for the newer run's.
        let token = lanes.dns.observationToken
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        timer.schedule(deadline: .now() + 30, repeating: 30)
        timer.setEventHandler { [weak self, manager] in
            let alive = manager.probeLiveness()
            Task { @MainActor in
                self?.handleDNSHealthResult(alive: alive, forwarderPort: forwarderPort, armedBy: token)
            }
        }
        dnsHealthTimer = timer
        timer.resume()
    }

    func stopDNSHealthTimer() {
        dnsHealthTimer?.cancel()
        dnsHealthTimer = nil
        dnsRelayUnresponsive = false
    }

    /// One probe reading for the run whose timer `token` armed. Internal so the host's tests can report a reading; the probe itself asks
    /// port 53 through the injected effect. A reading for a run a Stop or newer Start superseded, or taken while the kernel no longer
    /// runs the forwarder, describes no current pipeline and is dropped.
    func handleDNSHealthResult(alive: Bool, forwarderPort: Int, armedBy token: LifecycleLane.Token) {
        guard !token.isSuperseded, orchestrator.snapshot.dnsRunState == .running else { return }
        if alive {
            dnsRelayUnresponsive = false
            return
        }
        // The restart and the probe after it run off the main actor, one at a time.
        guard !dnsRelayRestartInFlight else { return }
        dnsRelayRestartInFlight = true

        logger.log(.warning, "DNS liveness probe failed. Attempting relay restart.", category: .system)
        let manager = systemDNSManager
        deliveries.deliver { [weak self, platformWork, logger] in
            let outcome = await platformWork.run {
                manager.restartRelayIfManaged(forwarderPort: forwarderPort, logger: logger)
            }
            self?.finishDNSRelayRestart(outcome, armedBy: token)
        }
    }

    /// The restart's own final probe is the reading. It is reported whatever happened since, and it sets the observation only for the
    /// run that asked for it, while the kernel still runs the forwarder.
    private func finishDNSRelayRestart(_ outcome: SystemDNSManager.RelayRestart, armedBy token: LifecycleLane.Token) {
        dnsRelayRestartInFlight = false
        switch outcome {
        case .notManaged:
            // A stop finished while the restart was out.
            return
        case .restarted:
            orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "dns.relay_restarted", detail: "source=health_timer"))
        case .unresponsive:
            orchestrator.eventLog.append(RuntimeEvent(kind: .health, event: "dns.pipeline_unresponsive", detail: "source=health_timer"))
        }
        guard !token.isSuperseded, orchestrator.snapshot.dnsRunState == .running else { return }
        dnsRelayUnresponsive = outcome == .unresponsive
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

    /// Hands the snapshot to the writer's drain. Encoding, the destination guard and the replacement all run there,
    /// never on this actor, and a failed write is reported by the writer's own events.
    func writeSnapshotFile(snapshot: ProxyOrchestratorSnapshot) {
        reportWriterLoss()
        snapshotWriter.submit(snapshot)
    }


    package nonisolated static let prettyEncoder: JSONEncoder = CanonicalJSON.encoder(prettyPrinted: true)
}

// MARK: - Recovery without a configuration

extension RuntimeHost {
    /// The journal restores for a launch whose config failed to load, run by
    /// `ConduitDaemon.main` before it exits. No host is built from a failed
    /// load, so without this a daemon killed with the system proxy or system
    /// DNS applied, and relaunched over a broken file, left the machine on
    /// the dead run's listeners. The app runs this on a refused open too
    /// (`AppStateHarnessTests.testACorruptConfigIsRefusedKeepsItsBytesAndStillRestoresTheJournaledProxy`):
    /// both restores work from the journal's recorded prior values, and only
    /// the legacy resolver scan needs the config, so that one is reported
    /// skipped.
    ///
    /// Events go to `events.ndjson` as a host's would, and are returned for
    /// the tests. The machine effects are the host's `effects`, the same value
    /// production assembly builds for the daemon: the recovery takes the
    /// client, runner, DNS responder and location store from it, and routes the
    /// client's events to its own event log for this run. Its drain deadline
    /// and failure reporting are unchanged from the earlier configless path.
    @discardableResult
    package static func recoverWithoutConfiguration(
        stateSession: StateRootSession,
        logger: any LogSink,
        effects: RuntimeHostEffects
    ) async -> [RuntimeEvent] {
        // Only under the root's authority (decision 0028): the journal it restores is the one the session names.
        let environment = stateSession.environment
        let emitted = RuntimeEventLog(capacity: 2048)
        let writer = RuntimeEventFileWriter(
            fileURL: environment.eventsFile,
            logger: logger,
            destinationGuard: diagnosticDestinationGuard(
                for: .runtimeEvents, in: environment, writerLeaseFile: stateSession.writerLeaseFile
            ),
            eventLog: emitted
        )
        let emit: @Sendable (RuntimeEvent) -> Void = { event in
            emitted.append(event)
            writer.record(event)
        }
        let privilege = effects.privilege(emit)
        let audited = AuditingPrivilegeClient(base: privilege.client, eventSink: emit)
        let runner = effects.commandRunner
        let journal = PlatformStateJournal(fileURL: environment.platformStateFile, logger: logger, eventSink: emit)
        let locationRecovery = effects.networkLocationStoreFactory(audited).map {
            LocationSettingsRecovery(store: $0, journal: journal, emit: emit)
        }
        let systemDNS = SystemDNSManager(
            privilegeClient: audited,
            journal: journal,
            legacySnapshotFile: environment.legacySavedDNSFile,
            commandRunner: runner,
            respondsOnPort: effects.dnsResponds,
            locationRecovery: locationRecovery
        )
        let systemProxy = SystemProxyManager(
            privilegeClient: audited,
            journal: journal,
            commandRunner: runner,
            portProbe: effects.loopbackPortProbe,
            locationRecovery: locationRecovery
        )
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
        if await writer.drain(until: ContinuousClock.now.advanced(by: .seconds(2))) != .drained {
            logger.log(.warning, "Launch recovery events were not all written to \(environment.eventsFile.path) before the deadline.", category: .general)
        }
        return emitted.events
    }
}

// MARK: - RuntimeReconcilerHost

/// The host's side of a reconcile pass, over this host's managers and logger;
/// the rules about what a pass may read live in `RuntimeReconciler`, not here.
extension RuntimeHost: RuntimeReconcilerHost {
    /// The host has no presentation mirror, so the orchestrator's config after the push is the input it holds.
    package func applyConfigChange(_ new: ProxyConfig, from old: ProxyConfig) async -> RuntimeConfigApplication {
        await orchestrator.applyConfigChange(new, from: old)
        return .held(orchestrator.config)
    }

    /// A reload's pass waits for any start or stop in flight on every module lane, so the one reconciler acts on the shared input
    /// after the lifecycle's platform work rather than beside it.
    package func awaitLifecycleIdle() async {
        await waitUntilIdle(Self.allModules)
    }

    package func runtimeState() -> RuntimeReconciler.RuntimeState {
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
    package func reapplyConfigDrivenSurfaces(for pass: RuntimeReconciler.Pass) async {
        let old = pass.old
        let new = pass.new
        let platform = pass.platform

        if pass.diff.dnsChanged, platform.manageDNSResolvers, !pass.resolversFollowTheirFlag,
           pass.runtime.proxyIsUp || pass.runtime.dnsIsUp {
            // With the tunnel up the reconcile writes the new entries; either
            // way it removes the files the new config no longer names, and a
            // refused removal there leaves a file only the journal names.
            // Decided, and queued on `platformWork`, in this turn: the gate
            // state and the DNS bindings are the ones this pass read.
            let vpnConnected = splitDNSGate.entriesWanted
            let operation: SplitDNSEntryFileRepair.Operation = vpnConnected ? .apply : .remove
            let resolvers = dnsManager, resolverLog = logger
            // `applyConfigChange` restarted the forwarder if the DNS
            // section changed, possibly onto a different port, and
            // `reconcile` does not rewrite intercept files. Re-point them
            // at the listeners that came back, or remove them if none did.
            // Runs whatever the reconcile did: see
            // `DNSResolverReconciliation`.
            let refresh = interceptRefresh(for: new, platform: platform)
            let place = splitDNSRepair.queue()
            let entryFiles = await platformWork.run { () -> SplitDNSEntryFileRepair.Observation? in
                // The reconcile, the refresh and the residue under one lock, so no other resolver write lands between them.
                resolvers.serialized { () -> SplitDNSEntryFileRepair.Observation? in
                    var entryFiles: SplitDNSEntryFileRepair.Outcome?
                    DNSResolverReconciliation.run(
                        after: "config reload",
                        logger: resolverLog,
                        reconcile: {
                            do {
                                try resolvers.reconcile(old: old, new: new, logger: resolverLog, vpnConnected: vpnConnected)
                                entryFiles = .succeeded(operation)
                            } catch {
                                entryFiles = .failed(operation, error)
                                throw error
                            }
                        },
                        refreshInterceptFiles: refresh
                    )
                    return entryFiles.map { SplitDNSEntryFileRepair.Observation.after($0, config: new, dnsManager: resolvers) }
                }
            }
            await recordSplitDNS(entryFiles, source: .configChange, startedAt: place)
        }

        // The listener endpoint is in every advertised surface; the bypass
        // list is in the shell environment always and in the system proxy
        // only in manual mode, where it is `ExceptionsList`. PAC mode's
        // served script is refreshed by the routing reload itself, but its
        // URL is in the system proxy: a local PAC server that started,
        // stopped or moved has to be advertised where it now listens.
        let pacEndpointMoved = pass.diff.localPACEndpointChanged && platform.systemProxyMode == .pac
        let systemProxyFollows = pass.diff.proxyChanged || pacEndpointMoved
            || (pass.diff.advertisedBypassChanged && platform.systemProxyMode == .manual)
        let environmentFollows = pass.diff.proxyChanged || pass.diff.advertisedBypassChanged
        if pass.runtime.proxyIsUp, pass.diff.advertisedBypassChanged, !pass.diff.proxyChanged {
            let surfaces = [
                platform.manageEnvironmentVariables && !pass.platformActions.contains(.applyEnvironment) ? "environment" : nil,
                platform.manageSystemProxy && systemProxyFollows && !pass.platformActions.contains(.applySystemProxy) ? "system_proxy" : nil,
            ].compactMap { $0 }
            if !surfaces.isEmpty {
                // Event first: the writes below are a config decision.
                let event = RuntimeEvent(kind: .config, event: "config.advertised_bypass_changed",
                                         detail: "surfaces=\(surfaces.joined(separator: ","))")
                orchestrator.eventLog.append(event)
                logger.log(.notice, "Config reload: bypass list changed; re-applying \(surfaces.joined(separator: " and ")). \(event.event) \(event.detail ?? "")", category: .system)
            }
        }
        if pass.runtime.proxyIsUp, pacEndpointMoved, !pass.diff.proxyChanged, platform.manageSystemProxy,
           !pass.platformActions.contains(.applySystemProxy) {
            // Event first: the write below is a config decision.
            let event = RuntimeEvent(kind: .config, event: "config.advertised_pac_changed", detail: "surfaces=system_proxy")
            orchestrator.eventLog.append(event)
            logger.log(.notice, "Config reload: local PAC endpoint changed; re-applying system proxy. \(event.event) \(event.detail ?? "")", category: .system)
        }
        guard pass.runtime.proxyIsUp else { return }
        let reapplySystemProxy = systemProxyFollows && platform.manageSystemProxy
            && !pass.platformActions.contains(.applySystemProxy)
        let reapplyEnvironment = environmentFollows && platform.manageEnvironmentVariables
            && !pass.platformActions.contains(.applyEnvironment)
        guard reapplySystemProxy || reapplyEnvironment else { return }
        // Off the main actor, and a failure, partial environment applies
        // included, is reported and retried.
        let systemProxy = systemConduit, environment = environmentManager, log = logger
        let mode = platform.systemProxyMode, pacURL = orchestrator.snapshot.bindings.localPACURL
        let token = lanes.proxy.observationToken
        let failures = await platformWork.run { () -> [(ConfigReapplyRetry.Surface, String)] in
            var failures: [(ConfigReapplyRetry.Surface, String)] = []
            if reapplySystemProxy {
                do {
                    try systemProxy.apply(config: new, mode: mode, logger: log, localPACURL: pacURL)
                } catch {
                    failures.append((.systemProxy, error.localizedDescription))
                }
            }
            if reapplyEnvironment {
                do {
                    if let shortfall = try environment.apply(config: new, logger: log).shortfall {
                        failures.append((.environment, shortfall))
                    }
                } catch {
                    failures.append((.environment, "apply_error error=\(error.localizedDescription)"))
                }
            }
            return failures
        }
        for (surface, reason) in failures {
            reapplyRetry.failed(surface, cause: .configChange, reason: reason, token: token)
        }
    }

    package func recordPlatformDecision(_ action: PlatformIntegrationReconciler.Action) {
        orchestrator.eventLog.append(
            RuntimeEvent(kind: .config, event: "config.platform_integration", detail: String(describing: action))
        )
    }

    /// Runs one platform-flag action through the manager the start and stop
    /// paths use, with their warning-not-throw treatment. Returns whether the
    /// action landed, so the reconciler can leave the flag unreconciled for
    /// the next reload to retry.
    ///
    /// What the action reads from the host is taken in the turn it is called,
    /// and its manager calls are queued on `platformWork` in that turn, so
    /// they land in the order the pass decided them, beside the lifecycle's
    /// own blocks, and never hold this actor (#47). What the host records
    /// after the block returns names the run it was decided under: a retry
    /// carries that run's proxy token, and a split-DNS outcome its place in
    /// the repair's queue order, with the residue read beside it.
    package func perform(
        _ action: PlatformIntegrationReconciler.Action,
        config: ProxyConfig,
        previousConfig: ProxyConfig,
        platform: PlatformIntegrationConfig,
        previousPlatform: PlatformIntegrationConfig
    ) async -> Bool {
        let logger = self.logger
        switch action {
        case .applySystemProxy:
            // Also for a mode change with the switch left on.
            return await applySystemProxySwitch(config: config, platform: platform,
                                                cause: previousPlatform.manageSystemProxy ? .modeChange : .switchOn)
        case .clearSystemProxy:
            // The managers report a partial teardown by keeping their records,
            // not by throwing, so the journal is the oracle for "landed":
            // records left means the next reload must try again.
            let systemProxy = systemConduit
            return await platformWork.run {
                attemptFlagStep("Could not clear system proxy after the setting changed", logger: logger) {
                    try systemProxy.clear(logger: logger)
                } && !systemProxy.hasManagedState()
            }
        case .applyEnvironment:
            return await applyEnvironmentSwitch(config: config)
        case .clearEnvironment:
            let environment = environmentManager
            return await platformWork.run {
                attemptFlagStep("Could not clear environment variables after the setting changed", logger: logger) {
                    try environment.clear(logger: logger)
                } && !environment.hasManagedState()
            }
        case .applyResolverEntries:
            // The switch turned on: entry files follow the gate, as in a
            // config change. The outcome feeds the split-DNS repair, since
            // this pass skips the config-change reconcile.
            let resolvers = dnsManager
            let vpnConnected = splitDNSGate.entriesWanted
            let operation: SplitDNSEntryFileRepair.Operation = vpnConnected ? .apply : .remove
            let entryPlace = splitDNSRepair.queue()
            let (observed, applied) = await platformWork.run { () -> (SplitDNSEntryFileRepair.Observation, Bool) in
                // One operation under the manager's lock, as the lifecycle's resolver blocks take it, with its residue read in it.
                resolvers.serialized { () -> (SplitDNSEntryFileRepair.Observation, Bool) in
                    if resolvers.isApplied(config: config, vpnConnected: vpnConnected) {
                        // The write is skipped; the record must not be. See `adoptAppliedFiles`.
                        resolvers.adoptAppliedFiles(config: config, vpnConnected: vpnConnected)
                        logger.log(.debug, "DNS resolvers already configured correctly, skipped.", category: .system)
                        return (SplitDNSEntryFileRepair.Observation.after(.succeeded(operation), config: config, dnsManager: resolvers), true)
                    }
                    var outcome = SplitDNSEntryFileRepair.Outcome.succeeded(operation)
                    let applied = attemptFlagStep("Could not apply DNS resolvers after the setting changed", logger: logger) {
                        do {
                            try resolvers.apply(config: config, logger: logger, vpnConnected: vpnConnected)
                        } catch {
                            outcome = .failed(operation, error)
                            throw error
                        }
                    }
                    return (SplitDNSEntryFileRepair.Observation.after(outcome, config: config, dnsManager: resolvers), applied)
                }
            }
            await recordSplitDNS(observed, source: .switchOn, startedAt: entryPlace)
            // A VPN transition taken while the apply was out queued its own
            // entry-file work behind it; put the files where the gate is now
            // all the same, as `applyProxySurfaces` does.
            if splitDNSGate.entriesWanted != vpnConnected {
                await reconcileEntryFiles(config: config, runtimeStarted: runtimeStarted)
            }
            return applied
        case .refreshInterceptFiles:
            // Over the DNS module's bindings when the pass decided this action.
            let refresh = interceptRefresh(for: config, platform: platform)
            let place = splitDNSRepair.queue()
            let refreshed = await platformWork.run {
                attemptFlagStep("Could not apply intercept resolver files after the setting changed", logger: logger) {
                    try refresh()
                }
            }
            recordInterceptRefresh(failed: !refreshed, place: place)
            return refreshed
        case .clearResolvers:
            // Only what the journal names as ours. The switch is off now, so
            // a file for a configured domain we never wrote is the user's.
            // The teardown is what a pending repair retries with the switch
            // off, so a failed one is recorded for it: a later VPN drop no
            // longer touches entry files with the switch off.
            let resolvers = dnsManager
            let entryPlace = splitDNSRepair.queue()
            let (observed, cleared) = await platformWork.run { () -> (SplitDNSEntryFileRepair.Observation, Bool) in
                resolvers.serialized { () -> (SplitDNSEntryFileRepair.Observation, Bool) in
                    var failure: String?
                    let cleared = attemptFlagStep("Could not clear DNS resolvers after the setting changed", logger: logger) {
                        do {
                            try resolvers.clearRecorded(configs: [previousConfig, config], logger: logger)
                        } catch {
                            failure = error.localizedDescription
                            throw error
                        }
                    } && !resolvers.hasManagedState()
                    let outcome = SplitDNSEntryFileRepair.Outcome(
                        operation: .remove,
                        failure: cleared ? nil : failure ?? SplitDNSEntryFileRepair.recordedFilesRemainReason
                    )
                    return (SplitDNSEntryFileRepair.Observation.after(outcome, config: config, dnsManager: resolvers), cleared)
                }
            }
            await recordSplitDNS(observed, source: .switchOff, startedAt: entryPlace)
            return cleared
        case .applySystemDNS:
            // The same three steps as `startRuntime`, in the same order: the
            // prior state is captured before the interfaces are pointed at
            // the relay, and the health timer runs whether or not the apply
            // succeeded, because its relay restart is the retry. A DNS Stop
            // begun while the apply was out tears down after this settles
            // (`quiesceEffects`), so it stops the timer armed here.
            let systemDNS = systemDNSManager
            let forwarderPort = orchestrator.snapshot.bindings.dnsPort ?? config.dnsForwarderPort
            let landed = await platformWork.run { () -> Bool in
                let saved = attemptFlagStep("Could not save current DNS state (non-fatal)", logger: logger) {
                    try systemDNS.saveCurrentDNS(logger: logger)
                }
                let applied = attemptFlagStep("Could not set system DNS after the setting changed", logger: logger) {
                    try systemDNS.apply(forwarderPort: forwarderPort, logger: logger)
                }
                return saved && applied
            }
            startDNSHealthTimer(forwarderPort: forwarderPort)
            return landed
        case .clearSystemDNS:
            // Timer first: left running, its 30 s probe would restart the
            // relay the user just asked to remove.
            stopDNSHealthTimer()
            let systemDNS = systemDNSManager
            return await platformWork.run {
                attemptFlagStep("Could not restore system DNS after the setting changed", logger: logger) {
                    try systemDNS.clear(logger: logger)
                } && !systemDNS.hasSavedState()
            }
        case .setLaunchAtLogin:
            return performImmediate(action, platform: platform, previousPlatform: previousPlatform)
        }
    }

    /// The login item is the app's `SMAppService` registration. A
    /// LaunchDaemon has none to keep, so the flag reconciles by being
    /// ignored here; the app applies it when it next runs. It is the only
    /// immediate action, and it has no machine effect.
    package func performImmediate(
        _ action: PlatformIntegrationReconciler.Action,
        platform: PlatformIntegrationConfig,
        previousPlatform: PlatformIntegrationConfig
    ) -> Bool {
        guard case .setLaunchAtLogin = action else {
            preconditionFailure("\(action) is not an immediate action")
        }
        return true
    }

    /// The system proxy switch turned on, or its mode changed: a failure is reported to the
    /// retry, and the completed baseline does not move for it, so the switch is
    /// still owed when the retry looks again sooner (#194).
    private func applySystemProxySwitch(config: ProxyConfig, platform: PlatformIntegrationConfig,
                                        cause: ConfigReapplyRetry.Cause) async -> Bool {
        let systemProxy = systemConduit, logger = self.logger
        let mode = platform.systemProxyMode, localPACURL = orchestrator.snapshot.bindings.localPACURL
        let token = lanes.proxy.observationToken
        let failure = await platformWork.run { () -> String? in
            do {
                try systemProxy.apply(config: config, mode: mode, logger: logger, localPACURL: localPACURL)
                return nil
            } catch {
                return error.localizedDescription
            }
        }
        guard let failure else { return true }
        reapplyRetry.failed(.systemProxy, cause: cause, reason: failure, token: token)
        return false
    }

    /// The environment switch turned on: a partial apply lands the
    /// flag, and is reported and retried like a failure (#194).
    private func applyEnvironmentSwitch(config: ProxyConfig) async -> Bool {
        let environment = environmentManager, logger = self.logger
        let token = lanes.proxy.observationToken
        let (landed, failure) = await platformWork.run { () -> (Bool, String?) in
            do {
                return (true, try environment.apply(config: config, logger: logger).shortfall)
            } catch {
                return (false, "apply_error error=\(error.localizedDescription)")
            }
        }
        if let failure {
            reapplyRetry.failed(.environment, cause: .switchOn, reason: failure, token: token)
        }
        return landed
    }
}

/// One manager call of a flag action, on `platformWork`: a failure is a warning and an action that did not land, never a throw.
private func attemptFlagStep(_ failure: String, logger: any LogSink, _ body: () throws -> Void) -> Bool {
    do {
        try body()
        return true
    } catch {
        logger.log(.warning, "\(failure): \(error.localizedDescription)", category: .system)
        return false
    }
}

private extension ProxyOrchestratorBindings {
    var localPACURL: String? {
        guard let host = localPACHost, let port = localPACPort else { return nil }
        return "http://\(host):\(port)/proxy.pac"
    }
}
