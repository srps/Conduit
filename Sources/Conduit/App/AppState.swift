// SPDX-License-Identifier: Apache-2.0
import AppKit
import Combine
import ConduitRuntime
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyAuth
import ProxyControlBridge
import ProxyKernel
import ProxyPAC
import RuntimeEvents
import SwiftUI

/// The app over the shared runtime host (decisions 0031 and 0039). It keeps the Settings drafts and their editing, presentation,
/// notifications, import and export, the PAC preview, updates, windows, onboarding, credential enrollment, helper installation and the
/// login item. The runtime, its lifecycle, recovery and persistence are the host's: every command and every private editor change goes
/// through the actual framed clients, and every presented value comes from their snapshots and pages.
@MainActor
final class AppState: ObservableObject {
    /// Where the composition is. Controls act only while `ready`.
    enum Phase: Equatable {
        /// The configuration is being migrated and the host opened, or the first editor read is out.
        case opening
        case ready
        /// The configuration could not be opened. Nothing was overwritten, and only a restart after a repair opens it.
        case refused
        /// The quit has begun.
        case quitting
    }

    @Published private(set) var phase: Phase = .opening
    /// The Settings drafts. They reach the runtime only through the editor's private updates.
    @Published var config: ProxyConfig
    @Published var platformConfig: PlatformIntegrationConfig
    @Published var appPreferences: AppPreferences
    @Published private(set) var updateStatus: UpdateCoordinator.Status
    @Published var isShowingOnboarding = false
    @Published var selectedSection: AppSection = .overview
    @Published var lastErrorMessage: String?
    /// The "Configuration problem" banner the last save set, so a later save that validates clears it and nothing else.
    private var configProblemMessage: String?
    /// The "not saved" banner the last unverified save of each kind set, so a later verified save of that kind clears it and nothing else.
    private var saveFailureShown: [SettingsSave: String] = [:]
    @Published private(set) var pacPreviewMessage: String?
    @Published private(set) var isPACPreviewRunning = false
    private(set) var pacPreviewTask: Task<Void, Never>?
    /// The host's latest preflight reading. Nil before one.
    @Published private(set) var activationPreflight: ControlPreflightItems?
    /// The helper verdict the host holds, for display.
    @Published private(set) var helperStatusState: HelperToolPrivilegeClient.Status = .notInstalled
    /// The latest helper reading was `busy`; a re-read is pending.
    @Published private(set) var helperCheckingAgain = false
    /// The caller policy the last install from Settings reported (#121); nil before one, and after an uninstall.
    @Published private(set) var helperCallerPolicy: HelperPinOutcome?
    /// The draft holds an edit that would start, stop or replace a bound endpoint, so it waits for a commit.
    @Published private(set) var listenerEditAwaitingCommit = false
    /// A file's baseline was dropped by a conflict or an unknown write: only an explicit reload lets the editor write it again.
    @Published private(set) var configurationNeedsReload = false
    /// Why no Start may run now: the explicit launch options were not saved, so the saved input is not what this launch asked for. Stop
    /// and Quit stay available. Cleared when the configuration draft is saved.
    @Published private(set) var activationHeld: String?

    let runtime = RuntimePresentationAdapter()
    let logStore: AppLogStore
    let credentialManager: CredentialManager
    let helperLifecycle: any HelperLifecycleManaging
    /// The app's own bounded event log: the app log's refusals, editor and helper decisions, the PAC preview. The host's events go to
    /// its own diagnostics.
    let eventLog: RuntimeEventLog

    /// The root's writer authority (decision 0028), held for the app's lifetime.
    private let stateSession: StateRootSession
    private let composition: AppComposition
    private let updateCoordinator: UpdateCoordinator
    private let notificationManager = NotificationManager()
    /// The identity the credential controls name, from the editor's saved values.
    private let credentialIdentity: NIOLockedValueBox<CredentialManager.Identity>
    private var cancellables: Set<AnyCancellable> = []
    /// Set while the app itself assigns the drafts (an observation, a reload), so the assignment is not an edit.
    private var assigningDrafts = false

    // The actual clients, once the host opened.
    private var control: (any RuntimeClient)?
    private var editorClient: PrivateEditorClient?
    private(set) var observer: RuntimeObserver?
    private(set) var editor: RuntimeEditorSession?
    private var incarnation: ControlHostIncarnation?

    /// The opening, joined by the quit and the harness.
    private(set) var opening: Task<Void, Never>?
    private var quitting: Task<RuntimeClientQuitResult?, Never>?
    /// Set when the quit begins. The opening checks it after every suspension, so it never finishes ready, seeds or saves after it.
    private var quitFence = false
    /// The debounced save the last edit scheduled.
    private var pendingSave: Task<Void, Never>?
    /// Ordinary commands in flight from the controls. Bounded: a click past it is dropped with a log line. Stops do not count here.
    private var commandsInFlight = 0
    static let maximumCommandsInFlight = 8
    /// A module's Stop lane (`send`): present while its one Stop is out, with the settlement of the one Stop wanted after it, if any.
    private struct StopLane {
        var wanted: (@MainActor (ControlOperationOutcome?) -> Void)?
    }
    private var stopLanes: [ControlModule: StopLane] = [:]
    /// One preflight read out, one wanted after it, and whether a wanted one names a replaced helper.
    private var preflightInFlight = false
    private var preflightWanted: Bool?
    private var helperRecheck: Task<Void, Never>?
    /// Notices the host did not admit, tried again on a later snapshot a bounded number of times.
    private var owedNotices = OwedNotices()
    private let pacPreviewWork = PlatformWork(label: "io.github.srps.Conduit.app.pac-preview")
    /// An install waits on a password dialog for as long as the user takes, so it has its own queue.
    private let helperLifecycleWork = PlatformWork(label: "io.github.srps.Conduit.app.helper-lifecycle")
    private var helperChangeInFlight = false
    /// The DNS module's last observed error while it ran, for the degraded notification's transition.
    private var lastDNSError: String?
    /// One explicit reload at a time; a second request while one runs is refused with a message.
    private(set) var reloading = false
    /// The login item refused the last registration; the next verified Settings save or successful proxy Start tries again.
    private var loginItemRegistrationOwed = false

    /// The app takes a prepared `StateRootSession` and its composition; there is no other construction path (decisions 0028 and 0033).
    init(stateSession: StateRootSession, composition: AppComposition) {
        let environment = stateSession.environment
        let eventLog = RuntimeEventLog()
        self.eventLog = eventLog
        let logStore = AppLogStore(
            destinationGuard: diagnosticDestinationGuard(for: .appLog, in: environment, writerLeaseFile: stateSession.writerLeaseFile),
            eventLog: eventLog
        )
        self.logStore = logStore
        self.stateSession = stateSession
        self.composition = composition
        self.helperLifecycle = composition.helperLifecycle
        // Display-only until the first editor read: nothing is saved from these, and every control waits for `ready`.
        self.config = GenericDefaults.shared.makeConfig()
        self.platformConfig = PlatformIntegrationConfig()
        self.appPreferences = AppPreferences()
        let identity = NIOLockedValueBox<CredentialManager.Identity>((domain: "", username: "", profileName: ""))
        self.credentialIdentity = identity
        self.credentialManager = CredentialManager(identityProvider: { identity.withLockedValue { $0 } }, store: composition.credentialStore)
        let hostBundle = Bundle.main
        let updateCoordinator = UpdateCoordinator(
            hostIdentifier: hostBundle.bundleIdentifier ?? "io.github.srps.Conduit",
            hostPath: hostBundle.bundlePath,
            currentVersion: composition.currentVersion,
            availability: composition.updaterAvailability,
            launcher: composition.updaterLauncher,
            store: UpdateStateStore(file: environment.updateStateFile),
            reports: composition.updateReports,
            sleep: composition.timing.updateCheckSleep,
            record: { [logStore] event in
                eventLog.append(event)
                logStore.log(.notice, "Updates: \(event.event) \(event.detail ?? "")", category: .system)
            }
        )
        self.updateCoordinator = updateCoordinator
        self.updateStatus = updateCoordinator.status
        observeDrafts()
        notificationManager.requestAuthorization()
        opening = Task { @MainActor [weak self] in await self?.open() }
    }

    /// Whether the controls may act now.
    var controlsEnabled: Bool { phase == .ready && runtime.isLive }

    /// Whether an edit has not been saved yet.
    var hasUnsavedEdit: Bool {
        guard let editor else { return false }
        return editor.ledger.isDirty(.configuration) || editor.ledger.isDirty(.preferences)
    }

    /// Where file logging appends when it is on.
    var logFileURL: URL { stateSession.environment.logFile }

    // MARK: - Opening

    /// Migrates the files under the held session, opens the one host, composes its clients under the shipping profile, seeds the drafts
    /// from one editor observation, then commits any launch override save-only. Controls stay disabled until this returns ready.
    private func open() async {
        guard let loaded = await migrate() else { return await refuseOpening() }
        guard !quitFence else { return }
        if loaded.appPreferences.fileLoggingEnabled { logStore.logFileURL = stateSession.environment.logFile }
        for warning in loaded.warnings { logStore.log(.warning, warning, category: .system) }
        if loaded.migrated { logStore.log(.notice, "Configuration files migrated to the current schema.", category: .system) }

        let host: RuntimeHost
        do {
            host = try await RuntimeHost.open(
                stateSession: stateSession,
                logger: logStore,
                startupAllowsMissing: true,
                startedAt: Date(),
                // The app's process lifetime is AppKit's; it never asks the host for a terminal stop.
                terminalExit: {},
                effects: composition.effects,
                networkLocationLimits: composition.hostSchedules.networkLocationLimits,
                environmentDriftInterval: composition.hostSchedules.environmentDriftInterval,
                reapplyRetrySchedule: composition.hostSchedules.reapplyRetrySchedule,
                splitDNSHelperCheckInterval: composition.hostSchedules.splitDNSHelperCheckInterval
            )
        } catch is CancellationError {
            // The quit cancelled the opening, and the factory refused before building the host: no recovery, observer or timer started.
            logStore.log(.notice, "The quit began before the runtime opened; it was not opened.", category: .system)
            return
        } catch let refusal as RuntimeOpenRefusal {
            reportOpeningFailure(refusal.event, message: refusal.event.detail ?? refusal.event.event)
            return await refuseOpening()
        } catch {
            reportOpeningFailure(nil, message: error.localizedDescription)
            return await refuseOpening()
        }
        guard let composed = compose(host) else { return refuseUnlessQuitting() }
        // Kept in the turn the host was built, before any await, so a quit from here on reaches the host whatever the opening does next.
        control = composed.clients.control
        editorClient = composed.clients.editor
        await connect(composed.clients, rowBudget: composed.profile.collectionRowBudget)
    }

    /// The existing startup migration, off the main actor. Nil, with its event and banner, when the files do not load.
    private func migrate() async -> RuntimeConfigurationLoadResult? {
        let environment = stateSession.environment
        let result: Result<RuntimeConfigurationLoadResult, ConfigurationLoadError> = await PlatformWork(
            label: "io.github.srps.Conduit.app.migration"
        ).run {
            do {
                return .success(try ProxyConfigPersistence.loadAllMigrating(in: environment))
            } catch let error as ConfigurationLoadError {
                return .failure(error)
            } catch {
                return .failure(ConfigurationLoadError(source: environment.configFile.path, reason: error.localizedDescription))
            }
        }
        switch result {
        case .success(let loaded):
            return loaded
        case .failure(let failure):
            reportOpeningFailure(failure.event, message: failure.localizedDescription)
            return nil
        }
    }

    private func reportOpeningFailure(_ event: RuntimeEvent?, message: String) {
        if let event { eventLog.append(event) }
        lastErrorMessage = message + " Restart Conduit after repairing the file."
        logStore.log(.error, lastErrorMessage ?? message, category: .system)
    }

    /// A refused open keeps every byte, runs the journal's configless recovery and shows the banner. No draft is saved.
    private func refuseOpening() async {
        // A quit that began first owns the process's end; no recovery starts after its fence.
        guard !quitFence else { return }
        let events = await RuntimeHost.recoverWithoutConfiguration(
            stateSession: stateSession, logger: logStore, effects: composition.effects
        )
        for event in events { eventLog.append(event) }
        guard !quitFence else { return }
        phase = .refused
        updateCoordinator.onStatus = { [weak self] status in self?.updateStatus = status }
        updateCoordinator.start(automaticChecks: false)
    }

    /// The host's clients under the one shipping profile. The host is not kept here: the clients hold the composition.
    private func compose(_ host: RuntimeHost) -> (clients: RuntimeInMemoryClients, profile: RuntimeServiceProfile)? {
        do {
            let profile = try RuntimeServiceProfile.inProcessApp()
            return (try host.makeInMemoryControlClient(profile: profile), profile)
        } catch {
            reportOpeningFailure(nil, message: "The runtime's control service could not be composed: \(error.localizedDescription).")
            return nil
        }
    }

    /// The first snapshot names the incarnation. Then one editor read seeds every draft and baseline together.
    private func connect(_ clients: RuntimeInMemoryClients, rowBudget: ControlRowBudget) async {
        let deadline = RuntimeDeadline.after(RuntimeEditorSession.exchangeBudget, from: .now)
        let incarnation: ControlHostIncarnation
        do {
            incarnation = try await clients.control.readSnapshot(deadline: deadline).stamp.incarnation
        } catch {
            // A quit reads the incarnation itself; its fence is not this opening's failure.
            guard !quitFence else { return }
            reportOpeningFailure(nil, message: "The runtime opened, but its status could not be read (\(error)).")
            return refuseUnlessQuitting()
        }
        self.incarnation = incarnation
        guard !quitFence else { return }
        let observation: PrivateEditorObservation
        do {
            observation = try await read(clients.editor, incarnation: incarnation, deadline: deadline)
        } catch {
            guard !quitFence else { return }
            reportOpeningFailure(nil, message: "The runtime opened, but its configuration could not be read (\(error)).")
            return refuseUnlessQuitting()
        }
        guard !quitFence else { return }
        let observer = RuntimeObserver(control: clients.control, presentation: runtime, incarnation: incarnation, rowBudget: rowBudget)
        self.observer = observer
        guard let seeded = seed(observation) else { return refuseUnlessQuitting() }
        // Weak: the session's operation in flight and the observer's tasks can outlive the app, after a quit whose total ended first, and
        // must never reach it then. With the app gone the session reads no draft and makes none up, so it starts nothing.
        editor = RuntimeEditorSession(
            control: clients.control, editor: clients.editor, observer: observer, incarnation: incarnation, ledger: seeded,
            drafts: { [weak self] in
                guard let self else { return nil }
                return (self.config, self.platformConfig, self.appPreferences)
            },
            moduleIntents: { [weak self] holdApply in self?.settingsModuleIntents(holdApply: holdApply) },
            report: { [weak self] report in self?.handle(report) }
        )
        observer.onSnapshot = { [weak self] snapshot in self?.observed(snapshot) }
        observer.onEvents = { [weak self] events in self?.observed(events) }
        observer.onFailure = { [logStore] reason in
            logStore.log(.warning, "Runtime observation: \(reason).", category: .system)
        }
        runtime.onDemand = { [weak observer] in observer?.scheduleRefresh() }
        observer.start()
        await commitLaunchOverrides()
        guard !quitFence else { return }
        finishOpening()
    }

    private func refuseUnlessQuitting() {
        guard !quitFence else { return }
        phase = .refused
    }

    private func read(
        _ editor: PrivateEditorClient, incarnation: ControlHostIncarnation, deadline: RuntimeDeadline
    ) async throws -> PrivateEditorObservation {
        let answer = try await editor.read(
            requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
            budget: try deadline.wireBudget(at: .now, cappedAt: RuntimeEditorSession.exchangeBudget), deadline: deadline
        )
        switch answer {
        case .observation(let observation): return observation
        case .refused(let code): throw RuntimeClientError.wire(code == .changedIncarnation ? .changedIncarnation : .invalidValue)
        case .admission: throw RuntimeClientError.unexpectedReply
        }
    }

    /// The drafts and their baselines from one observation, assigned without counting as edits.
    private func seed(_ observation: PrivateEditorObservation) -> RuntimeEditorLedger? {
        let values: (config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences)
        do {
            values = try PrivateConfigurationBridge.makeValues(from: observation)
        } catch {
            reportOpeningFailure(nil, message: "The runtime's configuration could not be shown (\(error)).")
            return nil
        }
        assignDrafts(values.config, values.platform, values.preferences)
        credentialIdentity.withLockedValue { $0 = (values.config.domain, values.config.username, values.config.profileName) }
        applySavedHostSettings(values.config)
        return RuntimeEditorLedger(
            observation: observation, config: values.config, platform: values.platform, preferences: values.preferences
        )
    }

    /// Explicit launch overrides are written save-only before any control can use them (decision 0015). One that is not verified holds
    /// every Start until the configuration draft is saved: a Start must not run the input this launch asked to replace.
    private func commitLaunchOverrides() async {
        let overrides = composition.launchOverrides
        guard !overrides.isEmpty, let editor else { return }
        let (config, platform) = overrides.applied(to: self.config, platformConfig)
        if config != self.config { self.config = config }
        if platform != platformConfig { platformConfig = platform }
        cancelPendingSave()
        if !overrides.isSatisfied(by: editor.ledger.saved.config, editor.ledger.saved.platform) {
            editor.save(.configuration)
            await editor.settle()
        }
        refreshActivationHold()
    }

    /// Holds every Start while the saved values do not hold the launch options, and releases the hold only once they do, read field by
    /// field from what this editor's own verified writes or its last read saved: a later save that turned a `--no-system-proxy` switch
    /// back on does not release it, so no Start runs contrary to the launch's own options.
    private func refreshActivationHold() {
        let overrides = composition.launchOverrides
        guard !overrides.isEmpty, let editor else { return }
        if overrides.isSatisfied(by: editor.ledger.saved.config, editor.ledger.saved.platform) {
            if activationHeld != nil, lastErrorMessage == activationHeld { lastErrorMessage = nil }
            activationHeld = nil
        } else if activationHeld == nil {
            activationHeld = "The launch options were not saved, so nothing starts until Settings saving them succeeds."
            lastErrorMessage = activationHeld
            logStore.log(.warning, activationHeld ?? "", category: .system)
        }
    }

    /// Whether a Start may be sent now. A held activation is reported instead.
    private func mayStart() -> Bool {
        guard let activationHeld else { return true }
        lastErrorMessage = activationHeld
        return false
    }

    private func finishOpening() {
        phase = .ready
        isShowingOnboarding = config.authMode == .ntlmv2 && !credentialManager.hasSavedCredentials(for: config)
        updateCoordinator.onStatus = { [weak self] status in self?.updateStatus = status }
        updateCoordinator.start(automaticChecks: appPreferences.automaticUpdateChecks)
        updateStatus = updateCoordinator.status
        refreshPreflight()
    }

    // MARK: - Drafts

    private func observeDrafts() {
        $config.dropFirst().sink { [weak self] draft in self?.draftChanged(.configuration, config: draft) }.store(in: &cancellables)
        $platformConfig.dropFirst().sink { [weak self] _ in self?.draftChanged(.configuration, config: nil) }.store(in: &cancellables)
        $appPreferences.dropFirst().sink { [weak self] _ in self?.draftChanged(.preferences, config: nil) }.store(in: &cancellables)
        $appPreferences
            .map(\.automaticUpdateChecks)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] enabled in
                guard let self, !self.quitFence else { return }
                self.updateCoordinator.setAutomaticChecks(enabled)
            }
            .store(in: &cancellables)
    }

    /// `@Published` emits before it assigns, so the draft a listener classification needs is the emitted one.
    private func draftChanged(_ group: RuntimeEditorLedger.Group, config draft: ProxyConfig?) {
        guard !assigningDrafts else { return }
        editor?.edited(group)
        if let draft { refreshListenerEditAwaitingCommit(draft: draft) }
        scheduleSave()
    }

    private func assignDrafts(_ config: ProxyConfig, _ platform: PlatformIntegrationConfig, _ preferences: AppPreferences) {
        assigningDrafts = true
        defer { assigningDrafts = false }
        self.config = config
        self.platformConfig = platform
        self.appPreferences = preferences
        refreshListenerEditAwaitingCommit(draft: config)
    }

    /// Where a commit came from, for its event.
    enum CommitTrigger: String {
        case submit
        case apply
        case sectionClose = "section_close"
        case quit
    }

    /// Saves after edits pause (#171). Two kinds of configuration edit wait for a commit instead (`holdsBackUnsavedEdit`).
    func scheduleSave() {
        pendingSave?.cancel()
        // The quit froze its final saves; an edit after it schedules nothing.
        guard !quitFence else { return }
        let delay = composition.timing.settingsSaveDebounce
        pendingSave = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                // Cancelled by a newer edit or by a save that already ran.
                return
            }
            guard let self else { return }
            self.pendingSave = nil
            self.editor?.save(.preferences)
            guard !self.holdsBackUnsavedEdit(trigger: "pause") else { return }
            self.submitConfiguration()
        }
    }

    /// Whether an unsaved configuration edit must wait for a commit rather than be saved by a pause: it blocks a proxy start, or it would
    /// start, stop or replace a bound endpoint. The whole value waits. Event first.
    private func holdsBackUnsavedEdit(trigger: String) -> Bool {
        guard let editor, editor.ledger.isDirty(.configuration) else { return false }
        // Only an unsaved runtime change can introduce a problem: a platform toggle beside an already-saved invalid runtime value saves.
        let runtimeChanged = config != editor.ledger.saved.config
        let blocking = runtimeChanged ? config.startBlockingProblems : []
        let detail: String
        if !blocking.isEmpty {
            detail = "reason=start_blocking_problems problems=\(blocking.count) trigger=\(trigger)"
        } else if ConfigDiff(old: editor.ledger.saved.config, new: config).replacesListeners {
            detail = "reason=listener_change trigger=\(trigger)"
        } else {
            return false
        }
        record(RuntimeEvent(kind: .config, event: "config.autosave_held", detail: detail), level: .info)
        return true
    }

    /// Commits the drafts now: Return in a field, Apply, or a section going away. The only way a held listener edit reaches the runtime.
    func commitPendingEdit(trigger: CommitTrigger) {
        if hasUnsavedEdit {
            let listener = editor.map { ConfigDiff(old: $0.ledger.saved.config, new: config).replacesListeners } ?? false
            record(RuntimeEvent(kind: .config, event: "config.edit_committed",
                                detail: "trigger=\(trigger.rawValue) listener_change=\(listener)"), level: .info)
        }
        saveConfig()
    }

    /// Commits after the active field has handed over its text, one hop after `endEditing`.
    @discardableResult
    func commitPendingEdit(trigger: CommitTrigger, afterEnding endEditing: () -> Void) -> Task<Void, Never> {
        endEditing()
        return Task { @MainActor in self.commitPendingEdit(trigger: trigger) }
    }

    /// Saves both drafts now, through the editor.
    func saveConfig() {
        cancelPendingSave()
        guard phase == .ready, let editor else { return }
        editor.save(.preferences)
        submitConfiguration()
    }

    /// Waits for the save an edit scheduled and the editor's operations it started. For the harness.
    func awaitPendingSave() async {
        await pendingSave?.value
        await editor?.settle()
    }

    private func cancelPendingSave() {
        pendingSave?.cancel()
        pendingSave = nil
    }

    private func submitConfiguration() {
        guard phase == .ready || phase == .opening, let editor, editor.ledger.isDirty(.configuration) else { return }
        editor.save(.configuration)
        refreshConfigurationProblem()
    }

    /// Surfaces validation problems at edit time. The save is not blocked: the runtime re-validates at start.
    private func refreshConfigurationProblem() {
        let validationErrors = config.validate()
        if let first = validationErrors.first {
            let summary = validationErrors.count > 1
                ? "\(first.localizedDescription) (+\(validationErrors.count - 1) more)"
                : first.localizedDescription
            let message = "Configuration problem: \(summary)"
            lastErrorMessage = message
            configProblemMessage = message
            for error in validationErrors { logStore.log(.warning, "Config validation: \(error.localizedDescription)") }
        } else if let shown = configProblemMessage {
            configProblemMessage = nil
            if lastErrorMessage == shown { lastErrorMessage = nil }
        }
    }

    private func refreshListenerEditAwaitingCommit(draft: ProxyConfig) {
        guard let editor else { return }
        let awaiting = ConfigDiff(old: editor.ledger.saved.config, new: draft).replacesListeners
        if listenerEditAwaitingCommit != awaiting { listenerEditAwaitingCommit = awaiting }
    }

    /// The intent a Settings save carries: each running module applies the saved pair at the revision the latest snapshot named; a stopped
    /// one only saves. A draft that blocks a start, or a save before the controls are ready, saves only.
    private func settingsModuleIntents(holdApply: Bool) -> PrivateModuleSlots<PrivateModuleIntent> {
        let saveOnly = PrivateModuleSlots<PrivateModuleIntent>(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
        guard !holdApply, phase == .ready, runtime.isLive, let modules = runtime.stamp?.modules else { return saveOnly }
        func intent(_ running: Bool, _ revision: ControlLifecycleRevision) -> PrivateModuleIntent {
            running ? .applyWhileRunning(ifLifecycleRevision: revision) : .saveOnly
        }
        let proxyRunning = [.running, .degraded, .recovering].contains(runtime.runtimeStatus.state)
        return PrivateModuleSlots(
            proxy: intent(proxyRunning, modules.proxy),
            dns: intent([.running, .warning].contains(runtime.dnsRunState), modules.dns),
            tunnels: intent([.running, .warning].contains(runtime.tunnelsRunState), modules.tunnels)
        )
    }

    /// One editor operation's answer.
    private func handle(_ report: RuntimeEditorSession.Report) {
        switch report {
        case .submitted(.configuration, let held):
            if held, let first = config.startBlockingProblems.first {
                record(RuntimeEvent(kind: .config, event: "config.apply_held",
                                    detail: "trigger=commit reason=start_blocking_problems check=\(first.check) problems=\(config.startBlockingProblems.count)"),
                       level: .notice)
            }
        case .submitted(.preferences, _):
            break
        case .settled(let submission, let outcome):
            settledEdit(submission, outcome)
        case .notAdmitted(let group, let code):
            // The host recorded nothing; nothing was written.
            notice(.rejected(SettingsSave(group), .notAdmitted(code)))
        case .refusedLocally(let group, let refusal):
            // Refused before anything was sent.
            notice(.rejected(SettingsSave(group), refusal))
            switch refusal {
            case .needsReload:
                lastErrorMessage = "Settings can't be saved until the configuration is reloaded from disk."
            case .resourceLimit, .notStorable, .tooLarge, .notRepresentable, .clientRefused, .notAdmitted, .editorBusy:
                lastErrorMessage = "Settings could not be saved (\(refusal.detail))."
            }
        case .unknown(let group):
            notice(.unverified(.save, .whole(SettingsSave(group), .unknown), reloadNeeded: true))
            lastErrorMessage = "Whether Settings were saved is unknown. Reload the configuration from disk before editing again."
        case .launchAtLogin(let enabled, let verified):
            launchAtLoginSettled(enabled, verified: verified)
        }
        refreshReloadNeed()
        followHostOwnedIntent()
    }

    private func settledEdit(_ submission: RuntimeEditorLedger.Submission, _ outcome: ControlOperationOutcome) {
        guard let editor else { return }
        let saved = editor.ledger.saved
        credentialIdentity.withLockedValue { $0 = (saved.config.domain, saved.config.username, saved.config.profileName) }
        applySavedHostSettings(saved.config)
        refreshListenerEditAwaitingCommit(draft: config)
        for unverified in SettingsSaveNotice.unverified(
            outcome, of: SettingsSave(submission.kind), trigger: .save, reloadNeeded: !editor.ledger.filesNeedingReload.isEmpty
        ) {
            notice(unverified)
        }
        let save = SettingsSave(submission.kind)
        if case .configurationSettled(let receipt) = outcome,
           !receipt.runtime.write.isVerified || !receipt.platform.write.isVerified {
            // A mismatch an own command's write may still explain is resubmitted once it does; it is no failure yet.
            if editor.ledger.heldMismatches.isEmpty {
                showSaveFailure(save, "Settings were not saved: \(Self.describe(receipt.runtime.write)) / \(Self.describe(receipt.platform.write)).")
            }
        } else if case .preferencesSettled(let receipt) = outcome, !receipt.preferences.write.isVerified {
            showSaveFailure(save, "Preferences were not saved: \(Self.describe(receipt.preferences.write)).")
        } else if case .failed(let failure) = outcome {
            lastErrorMessage = failure.humanDescription
        } else if Self.verified(outcome), let shown = saveFailureShown.removeValue(forKey: save), lastErrorMessage == shown {
            // A later verified save of the same files, an automatic resubmission included, ends the failure that banner reported.
            lastErrorMessage = nil
        }
        // The launch options' hold ends only once the saved values hold them.
        if activationHeld != nil { refreshActivationHold() }
        if loginItemRegistrationOwed, Self.verified(outcome) {
            registerLoginItem(editor.ledger.saved.platform.launchAtLogin)
        }
        refreshPreflight()
    }

    private func showSaveFailure(_ save: SettingsSave, _ message: String) {
        lastErrorMessage = message
        saveFailureShown[save] = message
    }

    /// Whether a save's receipt verified every file it wrote.
    private static func verified(_ outcome: ControlOperationOutcome) -> Bool {
        switch outcome {
        case .configurationSettled(let receipt): receipt.runtime.write.isVerified && receipt.platform.write.isVerified
        case .preferencesSettled(let receipt): receipt.preferences.write.isVerified
        default: false
        }
    }

    /// One editor notice, event first, log line derived from it.
    private func notice(_ notice: SettingsSaveNotice) {
        record(notice.event, level: .warning)
    }

    private static func describe(_ write: ControlConfigWorkflowWrite) -> String {
        switch write {
        case .persisted, .unchanged: "saved"
        case .notPersisted: "not written"
        case .unknown: "write state unknown; reload from disk"
        case .conflict: "the file changed on disk; reload from disk"
        case .notAttempted: "not attempted"
        }
    }

    private func refreshReloadNeed() {
        let needs = !(editor?.ledger.filesNeedingReload.isEmpty ?? true)
        if configurationNeedsReload != needs { configurationNeedsReload = needs }
    }

    /// The forwarder's enabled bit is host-owned intent: a DNS Start or Stop moves it, no Settings field edits it, and the host merges its
    /// own over whatever a draft carries. So the draft follows the saved bit, without counting as an edit and without touching any value
    /// the user edits; a stale draft bit would otherwise read as a DNS section change, holding every later pause save as a listener edit.
    private func followHostOwnedIntent() {
        guard let saved = editor?.ledger.saved.config.dnsForwarderEnabled, config.dnsForwarderEnabled != saved else { return }
        assigningDrafts = true
        config.dnsForwarderEnabled = saved
        assigningDrafts = false
        refreshListenerEditAwaitingCommit(draft: config)
    }

    /// The log levels follow the saved configuration, the one the runtime runs.
    private func applySavedHostSettings(_ config: ProxyConfig) {
        logStore.minStderrLevel = config.verboseLogging ? .debug : .notice
        logStore.minBufferedLevel = config.verboseLogging ? .debug : .notice
    }

    /// The explicit reload (decision 0032): the host re-reads the files and reconciles, then one fresh editor read rebuilds clean drafts.
    /// Unsaved edits are discarded by this choice.
    func reloadConfigurationFromDisk() {
        guard phase == .ready, let editor, let editorClient, let incarnation else { return }
        guard !reloading else {
            lastErrorMessage = "A reload from disk is already running."
            return
        }
        reloading = true
        cancelPendingSave()
        reloadTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                self.reloading = false
                self.reloadTask = nil
            }
            await editor.settle()
            _ = await self.settle(.reload)
            do {
                let deadline = RuntimeDeadline.after(RuntimeEditorSession.exchangeBudget, from: .now)
                let observation = try await self.read(editorClient, incarnation: incarnation, deadline: deadline)
                guard !self.quitFence else { return }
                // A save an edit started during the reload is out: the drafts are kept, and nothing is rebuilt under it.
                guard editor.isIdle else {
                    self.lastErrorMessage = "Settings were being saved during the reload, so nothing was reloaded. Reload again."
                    return
                }
                guard let ledger = self.seed(observation) else { return }
                editor.rebuild(ledger)
                self.lastErrorMessage = nil
                self.refreshReloadNeed()
                // The fresh drafts are the files' values: the launch options go again over them, and the hold follows what is saved.
                if self.activationHeld != nil { await self.commitLaunchOverrides() }
            } catch {
                self.lastErrorMessage = "The configuration could not be read again (\(error))."
            }
        }
    }

    /// The explicit reload running now, for the harness.
    private(set) var reloadTask: Task<Void, Never>?

    // MARK: - Import and export

    /// The import passes the same gate as a startup load; the draft is assigned only after it passes, then saved as a commit.
    func importConfiguration(from url: URL) throws {
        // A panel answered after the quit began starts nothing.
        guard !quitFence else { return }
        let imported = try ProxyConfigPersistence.loadImport(from: url)
        config = imported
        saveConfig()
    }

    /// Writes the draft to a file the user chose. The destination passes the state root's own guard first, so an export cannot write
    /// over the configuration, the journal, the lease or any other runtime file.
    func exportConfiguration(to url: URL) throws {
        guard !quitFence else { return }
        let guardian = diagnosticDestinationGuard(
            for: .connectionAudit, in: stateSession.environment, writerLeaseFile: stateSession.writerLeaseFile
        )
        try guardian.admit(destination: url)
        // A file leaving the process: the canonical encoder the configuration file itself uses (Unix-epoch timestamps, sorted keys).
        try CanonicalJSON.encoder(prettyPrinted: true).encode(config).write(to: url, options: .atomic)
    }

    // MARK: - Credentials

    func savePassword(_ password: String) {
        // After the quit's fence no app administration starts: the store is not written, and the host is not told.
        guard !quitFence else { return }
        do {
            // The only plaintext entry in the credential pipeline is the `SecureField` string, released when this returns.
            let hash: SecretBytes = try NTLMAuth.ntHash(for: password)
            try credentialManager.saveHash(hash, for: config)
            isShowingOnboarding = false
            logStore.log(.notice, "Saved proxy credentials to Keychain.", category: .auth)
            notifyCredentialsChanged()
        } catch {
            lastErrorMessage = error.localizedDescription
            logStore.log(.error, "Could not save credentials: \(error.localizedDescription)", category: .auth)
        }
    }

    func clearCredentials() {
        guard !quitFence else { return }
        do {
            try credentialManager.clear(for: config)
            isShowingOnboarding = true
            logStore.log(.notice, "Cleared saved credentials.", category: .auth)
            notifyCredentialsChanged()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    /// The host drops the credential it caches. A notice the host did not admit is owed and sent again on a later snapshot.
    private func notifyCredentialsChanged() {
        guard !quitFence else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            let admitted = await self.submitNotice(.credentialsChanged)
            self.owedNotices.credentialsChanged = admitted ? 0 : self.owedNotices.credentialsChanged + 1
        }
    }

    // MARK: - Lifecycle controls

    func toggleProxy() {
        guard controlsEnabled, let modules = runtime.stamp?.modules else { return }
        switch runtime.runtimeStatus.state {
        case .starting:
            return
        case .running, .degraded, .recovering:
            send(.stop(.proxy)) { [weak self] outcome in self?.proxyStopped(outcome) }
        case .stopped, .failed:
            guard mayStart() else { return }
            // A saved Start, with DNS's conditional companion (decisions 0036 and 0037). No draft value rides along.
            send(.start(.proxy, ifModuleRevision: modules.proxy, conditionalDNSRevision: modules.dns)) { [weak self] outcome in
                self?.proxyStarted(outcome, restart: false)
            }
        }
    }

    func restartProxy() {
        guard controlsEnabled, let stamp = runtime.stamp, let modules = stamp.modules,
              MenuBarPresentation.canRestartProxy(for: runtime.runtimeStatus.state), mayStart() else { return }
        lastErrorMessage = nil
        logStore.log(.notice, "Restarting proxy runtime from menu bar.", category: .proxy)
        send(.restart(.proxy, ifLifecycleRevision: stamp.lifecycleRevision, conditionalDNSRevision: modules.dns)) { [weak self] outcome in
            self?.proxyStarted(outcome, restart: true)
        }
    }

    func toggleDNS() {
        guard controlsEnabled, let modules = runtime.stamp?.modules else { return }
        switch MenuBarPresentation.moduleToggleAction(for: runtime.dnsRunState) {
        case .stop: send(.stop(.dns)) { _ in }
        case .none: break
        case .start:
            guard mayStart() else { return }
            send(.start(.dns, ifModuleRevision: modules.dns)) { [weak self] outcome in
                self?.moduleStarted(outcome, module: .dns)
            }
        }
    }

    func toggleTunnels() {
        guard controlsEnabled, let modules = runtime.stamp?.modules else { return }
        switch MenuBarPresentation.moduleToggleAction(for: runtime.tunnelsRunState) {
        case .stop: send(.stop(.tunnels)) { _ in }
        case .none: break
        case .start:
            guard mayStart() else { return }
            send(.start(.tunnels, ifModuleRevision: modules.tunnels)) { [weak self] outcome in
                self?.moduleStarted(outcome, module: .tunnels)
            }
        }
    }

    func testDNS() {
        guard controlsEnabled else { return }
        send(.testDNS) { _ in }
    }

    /// One command through the framed client and its settlement. A saved command's own causal writes are handed to the editor.
    ///
    /// A Stop is never dropped behind ordinary work: each module has a Stop lane of its own, as the host's Stop lanes do, outside the
    /// ordinary cap. A lane holds one Stop out and at most one wanted after it; a Stop asked for while one is out is sent again once that
    /// one ends, so a Start admitted in between cannot outlive it, and only the latest caller's settlement is kept.
    private func send(_ command: ControlRuntimeCommand, settled: @escaping @MainActor (ControlOperationOutcome?) -> Void) {
        guard !quitFence else { return }
        if case .stop(let module) = command {
            guard stopLanes[module] == nil else {
                stopLanes[module]?.wanted = settled
                return
            }
            stopLanes[module] = StopLane()
            return dispatch(command, settled: settled) { [weak self] in
                guard let self, let wanted = self.stopLanes.removeValue(forKey: module)?.wanted else { return }
                self.send(command, settled: wanted)
            }
        }
        guard commandsInFlight < Self.maximumCommandsInFlight else {
            logStore.log(.warning, "Lifecycle: \(command.kind.rawValue) dropped; \(Self.maximumCommandsInFlight) commands are in flight.",
                         category: .system)
            return
        }
        commandsInFlight += 1
        dispatch(command, settled: settled) { [weak self] in self?.commandsInFlight -= 1 }
    }

    private func dispatch(
        _ command: ControlRuntimeCommand,
        settled: @escaping @MainActor (ControlOperationOutcome?) -> Void,
        ended: @escaping @MainActor () -> Void
    ) {
        let requestID = ControlRequestID(rawValue: UUID())
        // Known to the editor from this turn, before the send, so a save submitted while it is out can wait for its write.
        editor?.ownCommandSent(command, requestID: requestID)
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { ended() }
            let end = await self.settle(command, requestID: requestID)
            switch end {
            case .settled(let outcome): self.editor?.ownCommandEnded(outcome: outcome, requestID: requestID)
            case .notRun: self.editor?.ownCommandNotRun(requestID: requestID)
            case .unknown: self.editor?.ownCommandEnded(outcome: nil, requestID: requestID)
            }
            self.refreshReloadNeed()
            self.followHostOwnedIntent()
            settled(end.outcome)
            self.refreshPreflight()
        }
    }

    /// How a command ended, as far as the app can know.
    private enum CommandEnd {
        case settled(ControlOperationOutcome)
        /// Not sent, refused locally, or rejected at admission: nothing ran.
        case notRun
        /// Admitted, or possibly admitted, and no settlement was read.
        case unknown

        var outcome: ControlOperationOutcome? {
            if case .settled(let outcome) = self { return outcome }
            return nil
        }
    }

    /// Submits and reads the settlement. A lost admission is looked up by request ID, never resent.
    private func settle(_ command: ControlRuntimeCommand, requestID: ControlRequestID = ControlRequestID(rawValue: UUID())) async
        -> CommandEnd
    {
        guard let control, let observer, let incarnation else { return .notRun }
        let deadline = RuntimeDeadline.after(RuntimeEditorSession.exchangeBudget, from: .now)
        let admission: ControlAdmission
        do {
            admission = try await control.submit(command, requestID: requestID, expectedIncarnation: incarnation, deadline: deadline)
        } catch RuntimeClientError.admissionUnknown {
            do {
                guard case .admission(let recorded) = try await control.lookupAdmission(
                    of: requestID, expectedIncarnation: incarnation, deadline: deadline
                ) else {
                    logStore.log(.warning, "Lifecycle: the admission of \(command.kind.rawValue) is unknown.", category: .system)
                    return .unknown
                }
                admission = recorded
            } catch {
                logStore.log(.warning, "Lifecycle: the admission of \(command.kind.rawValue) could not be looked up (\(error)).",
                             category: .system)
                return .unknown
            }
        } catch RuntimeClientError.notSent, RuntimeClientError.localRefusal {
            logStore.log(.warning, "Lifecycle: \(command.kind.rawValue) was not sent.", category: .system)
            return .notRun
        } catch {
            logStore.log(.warning, "Lifecycle: \(command.kind.rawValue) may have been sent; its answer was lost (\(error)).",
                         category: .system)
            return .unknown
        }
        switch admission {
        case .accepted(let operation), .joined(let operation):
            guard let outcome = await observer.settlement(of: operation) else { return .unknown }
            return .settled(outcome)
        case .rejected(let code):
            logStore.log(.warning, "Lifecycle: \(command.kind.rawValue) refused: \(code.humanDescription)", category: .system)
            return .notRun
        }
    }

    /// Submits a notice and says whether the host admitted it.
    private func submitNotice(_ command: ControlRuntimeCommand) async -> Bool {
        guard let control, let incarnation else { return false }
        do {
            let admission = try await control.submit(
                command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation,
                deadline: .after(RuntimeEditorSession.exchangeBudget, from: .now)
            )
            if case .rejected = admission { return false }
            return true
        } catch RuntimeClientError.admissionUnknown {
            // It may have been admitted; a notice is not replayed blindly.
            return true
        } catch {
            return false
        }
    }

    private func proxyStarted(_ outcome: ControlOperationOutcome?, restart: Bool) {
        let started: Bool
        if case .configurationSettled(let receipt)? = outcome {
            started = receipt.modules.contains(ControlModuleReceipt(module: .proxy, result: .started))
            // Overtaken by a newer Start or a Stop: neither a success nor a failure of this Start.
            if receipt.modules.contains(ControlModuleReceipt(module: .proxy, result: .superseded)) { return }
        } else {
            started = false
        }
        if case .superseded? = outcome { return }
        if started {
            notificationManager.post(title: restart ? "Proxy Restarted" : "Proxy Enabled", body: "Local proxy is running.")
            // A Start that came up repairs a registration lost outside the app, to the saved flag. An overtaken one returned above.
            if let saved = editor?.ledger.saved.platform.launchAtLogin { registerLoginItem(saved) }
        } else if outcome != nil {
            let title = restart ? "Proxy Restart Failed" : "Proxy Start Failed"
            notificationManager.post(title: title, body: "The proxy did not start. Open Conduit for details.")
        }
    }

    private func proxyStopped(_ outcome: ControlOperationOutcome?) {
        guard case .completed? = outcome else { return }
        notificationManager.post(title: "Proxy Disabled", body: "System proxy settings have been cleared.")
    }

    private func moduleStarted(_ outcome: ControlOperationOutcome?, module: ControlModule) {
        guard case .configurationSettled(let receipt)? = outcome,
              receipt.modules.contains(ControlModuleReceipt(module: module, result: .failed)) else { return }
        switch module {
        case .dns: notificationManager.post(title: "DNS Forwarder Failed", body: "The DNS forwarder did not start.")
        case .tunnels: notificationManager.post(title: "Tunnels Failed", body: "Tunnel listeners failed to bind.")
        case .proxy: break
        }
    }

    // MARK: - Login item

    /// The login-item flag is administration: it is written alone, under the exact platform baseline, and the registration follows only a
    /// verified write (decision 0015). It is admitted only while the editor is idle; a flip while a save is out is refused, never queued
    /// where a quit would drop it.
    func setLaunchAtLogin(_ enabled: Bool) {
        guard controlsEnabled, let editor else { return }
        guard editor.setLaunchAtLogin(enabled) else {
            notice(.rejected(.launchAtLogin, .editorBusy))
            lastErrorMessage = "Settings are being saved. Change Launch at login again once they are."
            return
        }
    }

    private func launchAtLoginSettled(_ enabled: Bool, verified: Bool) {
        guard let editor else { return }
        assigningDrafts = true
        platformConfig.launchAtLogin = editor.ledger.saved.platform.launchAtLogin
        assigningDrafts = false
        guard verified else {
            lastErrorMessage = "Launch at login was not saved."
            return
        }
        registerLoginItem(enabled)
    }

    /// Registers or removes the login item to match the saved flag. A refusal is owed for this session and tried again on the next
    /// verified Settings save or successful proxy Start. Nothing registers after the quit's fence (decisions 0015 and 0039), and nothing
    /// reconciles at launch (ROADMAP #194).
    private func registerLoginItem(_ enabled: Bool) {
        guard !quitFence else { return }
        if composition.loginItemManager.setEnabled(enabled, logger: logStore) {
            loginItemRegistrationOwed = false
        } else {
            loginItemRegistrationOwed = true
            lastErrorMessage = "Launch at login was saved, but the login item could not be \(enabled ? "registered" : "removed")."
        }
    }

    // MARK: - Observation

    private func observed(_ snapshot: ControlRuntimeSnapshot) {
        editor?.revisionsMayHaveMoved()
        payOwedNotices()
        let dnsError = snapshot.dnsRunState == .running ? snapshot.dnsError : nil
        if let dnsError, lastDNSError == nil {
            notificationManager.post(title: "DNS Forwarder Degraded", body: dnsError)
        }
        lastDNSError = dnsError
    }

    /// Typed recovery events classify the generic notifications; no event is paired with a snapshot.
    private func observed(_ events: [ControlRuntimeEvent]) {
        for event in events {
            if case .configWorkflow(.held(phase: .start, input: _, reason: .inputReplaced))? = event.typed {
                // Decision 0037: a newer write replaced the input a Start captured, so the host held its remaining work (the whole Start,
                // or only its DNS companion) and tore down what that work brought up. It is never retried; say so rather than report
                // nothing. The explanation grants nothing and names no module.
                lastErrorMessage = Self.startInterrupted
                notificationManager.post(title: "Start Interrupted", body: Self.startInterrupted)
                continue
            }
            guard case .proxyRecovery(let recovery)? = event.typed else { continue }
            switch recovery {
            case .recovered:
                notificationManager.post(title: "Proxy Recovered", body: "Connectivity restored.")
            case .failed(authenticationLikely: true):
                notificationManager.post(title: "Authentication Failed", body: "Your proxy credentials may be stale. Re-enter your password in Settings.")
            case .failed(authenticationLikely: false):
                notificationManager.post(title: "Proxy Recovery Failed", body: "The proxy could not recover its upstream.")
            }
        }
    }

    /// Module-neutral: the event can stand for a whole Start held or for only its DNS companion beside a proxy that stays up, so it names
    /// no module and claims nothing the snapshot does not show.
    static let startInterrupted = "A settings change replaced the configuration a Start was using, so part of that Start was held. "
        + "Check which modules are running, and start the one you need again."

    private func payOwedNotices() {
        if owedNotices.credentialsChanged > 0, owedNotices.credentialsChanged <= OwedNotices.attempts {
            notifyCredentialsChanged()
        }
        if let helperReplaced = owedNotices.preflight, owedNotices.preflightAttempts <= OwedNotices.attempts {
            owedNotices.preflight = nil
            refreshPreflight(helperReplaced: helperReplaced)
        }
    }

    // MARK: - Preflight and helper

    var helperStatus: HelperToolPrivilegeClient.Status { helperStatusState }

    /// One preflight read through the host; a request while one is out asks for one more after it.
    func refreshPreflight(helperReplaced: Bool = false) {
        guard phase == .ready else { return }
        guard !preflightInFlight else {
            preflightWanted = (preflightWanted ?? false) || helperReplaced
            return
        }
        preflightInFlight = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            let outcome = await self.settle(.refreshPreflight(helperReplaced: helperReplaced)).outcome
            self.preflightInFlight = false
            if case .completed(let completion)? = outcome, case .preflight(let observation) = completion.result {
                self.owedNotices.preflightAttempts = 0
                self.apply(observation.reading)
            } else if outcome == nil {
                self.owedNotices.preflight = helperReplaced || (self.owedNotices.preflight ?? false)
                self.owedNotices.preflightAttempts += 1
            }
            if let wanted = self.preflightWanted {
                self.preflightWanted = nil
                self.refreshPreflight(helperReplaced: wanted)
            }
        }
    }

    private func apply(_ reading: ControlPreflightReading) {
        switch reading {
        case .observed(let items):
            activationPreflight = items
            helperStatusState = HelperToolPrivilegeClient.Status(items.helper)
            helperCheckingAgain = items.helperReadBusy
            if items.helperReadBusy { scheduleHelperRecheck() } else { cancelHelperRecheck() }
        case .unavailable(.busy):
            helperCheckingAgain = true
            scheduleHelperRecheck()
        case .unavailable(.notObserved):
            break
        }
    }

    /// A `busy` reading asks for another observation rather than a verdict (STYLE rule 11). One re-read at a time.
    private func scheduleHelperRecheck() {
        guard helperRecheck == nil else { return }
        let delay = composition.timing.helperBusyRecheckDelay
        helperRecheck = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: delay) } catch { return }
            self?.helperRecheck = nil
            self?.refreshPreflight()
        }
    }

    private func cancelHelperRecheck() {
        helperRecheck?.cancel()
        helperRecheck = nil
    }

    /// Installs through the installer the app ships, which pins the helper to this build (#121).
    func installHelper() {
        changeHelper(
            "install",
            // The LaunchDaemon takes a moment to bind its socket.
            refreshAfter: composition.timing.helperSocketBindWait,
            { lifecycle in try lifecycle.installHelper() },
            succeeded: { appState, policy in
                appState.helperCallerPolicy = policy
                return (
                    RuntimeEvent(kind: .lifecycle, event: "helper.installed", detail: "caller_policy=\(policy.rawValue)"),
                    policy == .unenforced ? .warning : .notice
                )
            }
        )
    }

    func uninstallHelper() {
        changeHelper(
            "uninstall",
            refreshAfter: .zero,
            { lifecycle in try lifecycle.uninstallHelper() },
            succeeded: { appState, _ in
                appState.helperCallerPolicy = nil
                return (RuntimeEvent(kind: .lifecycle, event: "helper.uninstalled"), .notice)
            }
        )
    }

    /// An install or uninstall, off the main actor, one at a time. Event first, log line derived from it. A success tells the host the
    /// helper was replaced, so the verdict it held for the old one is not kept.
    private func changeHelper<Outcome: Sendable>(
        _ operation: String,
        refreshAfter delay: Duration,
        _ change: @escaping @Sendable (any HelperLifecycleManaging) throws -> Outcome,
        succeeded: @escaping @MainActor (AppState, Outcome) -> (RuntimeEvent, LogLevel)
    ) {
        guard !helperChangeInFlight, !quitFence else { return }
        helperChangeInFlight = true
        Task { @MainActor [weak self, helperLifecycleWork, helperLifecycle] in
            let result: Result<Outcome, HelperChangeFailure> = await helperLifecycleWork.run {
                do {
                    return .success(try change(helperLifecycle))
                } catch {
                    return .failure(HelperChangeFailure(reason: error.localizedDescription))
                }
            }
            guard let self else { return }
            self.helperChangeInFlight = false
            switch result {
            case .failure(let failure):
                let reason = failure.reason
                let event = RuntimeEvent(kind: .lifecycle, event: "helper.\(operation)_failed", detail: "reason=\(reason)")
                self.eventLog.append(event)
                self.logStore.log(.error, "Helper: \(event.event) \(event.detail ?? "")", category: .system)
                self.lastErrorMessage = reason
                return
            case .success(let outcome):
                self.cancelHelperRecheck()
                let (event, level) = succeeded(self, outcome)
                self.eventLog.append(event)
                self.logStore.log(level, "Helper: \(event.event) \(event.detail ?? "")", category: .system)
            }
            if delay > .zero {
                do { try await Task.sleep(for: delay) } catch { return }
            }
            self.refreshPreflight(helperReplaced: true)
        }
    }

    private struct HelperChangeFailure: Error {
        let reason: String
    }

    // MARK: - Updates

    func checkForUpdates() {
        guard !quitFence else { return }
        updateCoordinator.checkNow()
    }

    // MARK: - PAC preview

    func refreshPACResolutionPreview() {
        guard !isPACPreviewRunning, !quitFence else { return }
        let pacURL = config.pacURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let target: URL
        do {
            guard !pacURL.isEmpty else { throw PACResolverError.invalidURL }
            target = try PACPreviewTarget.parse(appPreferences.preferredBrowserTestURL)
        } catch {
            recordPACPreviewFailure(error)
            return
        }
        isPACPreviewRunning = true
        pacPreviewMessage = nil
        let evaluator = composition.pacEvaluator
        let work = pacPreviewWork
        pacPreviewTask = Task {
            defer {
                isPACPreviewRunning = false
                pacPreviewTask = nil
            }
            do {
                let script = try await evaluator.fetchPAC(from: pacURL)
                let outcome = await work.run {
                    Result { try evaluator.resolveProxyChain(for: target, pacScript: script) }
                }
                let result = try outcome.get()
                let answer = result.isEmpty ? "no entries (routed through the configured upstreams)" : result.joined(separator: "; ")
                let event = RuntimeEvent(kind: .routing, event: "pac.preview_completed", detail: "target=\(target.absoluteString) chain=\(answer)")
                eventLog.append(event)
                logStore.log(.info, event.detail ?? answer, category: .pac)
                pacPreviewMessage = "\(target.absoluteString): \(answer)"
            } catch {
                recordPACPreviewFailure(error)
            }
        }
    }

    private func recordPACPreviewFailure(_ error: any Error) {
        let event = RuntimeEvent(kind: .routing, event: "pac.preview_failed", detail: error.localizedDescription)
        eventLog.append(event)
        let message = event.detail ?? "PAC preview failed."
        logStore.log(.warning, message, category: .pac)
        pacPreviewMessage = message
        lastErrorMessage = message
    }

    func revealHealthTestURL() {
        guard !quitFence, let url = URL(string: appPreferences.preferredBrowserTestURL) else { return }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Quit

    /// Begins the quit, once, in this turn: the fence, the phase and the one deadline are taken here, and so is the final intent, the
    /// drafts frozen as they are now, so no later edit or dispatch delay changes what the quit saves or how long it may take. False when
    /// it had already begun: the caller joins that one, unchanged and with no new budget.
    func beginQuit() -> Bool {
        guard quitting == nil else { return false }
        let deadline = ContinuousClock.now.advanced(by: composition.timing.quitTotal)
        quitFence = true
        phase = .quitting
        // An opening that has not built the host yet builds none: the factory refuses a cancelled caller before construction.
        opening?.cancel()
        cancelPendingSave()
        updateCoordinator.stop()
        cancelHelperRecheck()
        if editor?.close() == true {
            // Admitted one turn ago and never sent: the quit's flush carries no admin write, so the flip is reported, not kept.
            notice(.unverified(.quit, .whole(.launchAtLogin, .quitBegan), reloadNeeded: nil))
        }
        let final = editor.flatMap { editor in incarnation.map { finalSaves(editor.ledger, incarnation: $0) } }
        let prior = editor?.ledger.active
        quitting = Task { @MainActor [weak self] in
            await self?.quit(until: deadline, final: final, prior: prior)
        }
        return true
    }

    /// The quit's result, once it has run.
    func finishQuit() async -> RuntimeClientQuitResult? {
        await quitting?.value
    }

    /// The client Quit with one total budget (decision 0039): the fence, the final frozen saves and cleanup confirmation, counted once.
    /// It applies nothing and saves no disable. Nothing app-owned runs after it under a fresh budget.
    private func quit(
        until deadline: ContinuousClock.Instant,
        final: FinalSaves?,
        prior: RuntimeEditorLedger.Submission?
    ) async -> RuntimeClientQuitResult? {
        if control == nil, let opening {
            // No client exists yet: the opening is joined, bounded by the same deadline. It was cancelled, so it builds no host after
            // this; one it built before the cancellation composed its clients in that same turn and is quit below.
            await Self.firstOf(opening, orDeadline: deadline)
        }
        guard let control, let editorClient else {
            logStore.log(.notice, "Quit: no runtime was opened; nothing was fenced or saved.", category: .system)
            runtime.observationEnded()
            return nil
        }
        let incarnation: ControlHostIncarnation
        if let known = self.incarnation {
            incarnation = known
        } else {
            // The opening built the host and was fenced before it read the incarnation.
            do {
                incarnation = try await control.readSnapshot(
                    deadline: .after(max(.zero, ContinuousClock.now.duration(to: deadline)), from: .now)
                ).stamp.incarnation
            } catch {
                logStore.log(.warning, "Quit: the runtime's status could not be read (\(error)); nothing was fenced.", category: .system)
                runtime.observationEnded()
                return nil
            }
        }
        // An editor not yet seeded when the quit began has no draft of the user's to save.
        let result = await RuntimeClientQuit.quit(
            control: control, editor: editorClient, incarnation: incarnation,
            total: max(.zero, ContinuousClock.now.duration(to: deadline)), now: .now,
            priorUpdate: prior?.requestID,
            configuration: final?.configuration, preferences: final?.preferences
        )
        recordQuit(result, prior: prior.map { SettingsSave($0.kind) })
        observer?.stop()
        runtime.observationEnded()
        return result
    }

    /// Returns when `task` ends or `deadline` passes, whichever is first. The task is not cancelled; only this wait ends.
    private static func firstOf(_ task: Task<Void, Never>, orDeadline deadline: ContinuousClock.Instant) async {
        let signal = FirstSignal()
        await withCheckedContinuation { continuation in
            signal.arm(continuation)
            Task {
                await task.value
                signal.fire()
            }
            Task {
                do {
                    try await Task.sleep(until: deadline, clock: .continuous)
                } catch {
                    // Cancelled sleeps cannot happen here: nothing holds this task to cancel it. Firing is idempotent either way.
                }
                signal.fire()
            }
        }
    }

    /// The final saves the quit declares: each dirty draft not already in flight, save-only, under the baselines the prior operation's own
    /// settlement leaves. A file that settlement left without one keeps the verified baseline the save was frozen under, as an unsettled
    /// prior does: it is only the save's precondition, which the host compares with the file before writing, so a file the prior or anyone
    /// else moved is refused unwritten, and the save is not left undeclarable to hold the host's flush window open to the deadline. A
    /// runtime draft that blocks a start is replaced by the last value saved, so it never becomes the next launch's configuration, and the
    /// platform edit beside it is still written.
    typealias FinalSaves = (
        configuration: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivateConfigurationRequest)?,
        preferences: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivatePreferencesRequest)?
    )

    private func finalSaves(_ ledger: RuntimeEditorLedger, incarnation: ControlHostIncarnation) -> FinalSaves {
        var configuration: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivateConfigurationRequest)?
        var preferences: (@Sendable (ControlRequestID, RuntimeQuitStep) throws -> PrivatePreferencesRequest)?
        // A file whose baseline was dropped cannot be written before an explicit reload, and no settlement restores one, so its group
        // is not declared: a declared save that is never admitted would hold the host's flush window open until the deadline.
        for group in [RuntimeEditorLedger.Group.configuration, .preferences] where ledger.needsSubmission(group) {
            if RuntimeEditorLedger.files(of: group).contains(where: { ledger.baselines[$0] == nil }) {
                record(RuntimeEvent(kind: .config, event: "config.edit_discarded",
                                    detail: "trigger=quit reason=needs_reload file=\(SettingsSave(group).files)"),
                       level: .warning)
            }
        }
        let writable = { (group: RuntimeEditorLedger.Group) in
            ledger.needsSubmission(group) && RuntimeEditorLedger.files(of: group).allSatisfy { ledger.baselines[$0] != nil }
        }
        if writable(.configuration) {
            let draft = config
            let platform = platformConfig
            let blocking = draft.startBlockingProblems
            // A value past an approved ceiling is refused before it is sent, and one the runtime file cannot hold is refused by the
            // store's staging, which refuses the whole request: so each too gives way to the last saved runtime value and the platform
            // edit beside it is still written.
            let violation = draft.resourceViolation()
            let unstorable = blocking.isEmpty && violation == nil ? draft.runtimeFileRefusal() : nil
            if let first = blocking.first {
                record(RuntimeEvent(kind: .config, event: "config.edit_discarded",
                                    detail: "trigger=quit reason=start_blocking_problems check=\(first.check) problems=\(blocking.count)"),
                       level: .notice)
            } else if let violation {
                record(RuntimeEvent(kind: .config, event: "config.edit_discarded",
                                    detail: "trigger=quit reason=resource_limit field=\(violation.field) limit=\(violation.limit)"),
                       level: .notice)
            } else if let unstorable {
                record(RuntimeEvent(kind: .config, event: "config.edit_discarded",
                                    detail: "trigger=quit reason=not_storable field=\(unstorable.field) requirement=\(SettingsSaveRefusal.code(unstorable.requirement))"),
                       level: .notice)
            } else {
                record(RuntimeEvent(kind: .config, event: "config.edit_committed",
                                    detail: "trigger=\(CommitTrigger.quit.rawValue) listener_change=\(ConfigDiff(old: ledger.saved.config, new: draft).replacesListeners)"),
                       level: .info)
            }
            let keepsDraft = blocking.isEmpty && violation == nil && unstorable == nil
            configuration = { requestID, prior in
                let after = ledger.afterQuitPrior(prior, incarnation: incarnation)
                let baselines = ledger.quitSaveBaselines(after: after)
                guard let runtime = baselines.runtime, let platformBaseline = baselines.platform else {
                    throw PrivateConfigurationWireError.invalidValue
                }
                return try PrivateConfigurationBridge.makeRequest(
                    config: keepsDraft ? draft : after.saved.config, platform: platform, requestID: requestID, incarnation: incarnation,
                    budget: try ControlWireBudget(0), runtimeBaseline: runtime, platformBaseline: platformBaseline,
                    modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
                )
            }
        }
        if writable(.preferences) {
            let draft = appPreferences
            preferences = { requestID, prior in
                guard let baseline = ledger.quitSaveBaselines(after: ledger.afterQuitPrior(prior, incarnation: incarnation)).preferences
                else {
                    throw PrivateConfigurationWireError.invalidValue
                }
                return try PrivateConfigurationBridge.makePreferencesRequest(
                    preferences: draft, requestID: requestID, incarnation: incarnation, budget: try ControlWireBudget(0),
                    preferencesBaseline: baseline
                )
            }
        }
        return (configuration, preferences)
    }

    /// Unresolved steps are reported as they are; nothing is retried or replaced.
    private func recordQuit(_ result: RuntimeClientQuitResult, prior: SettingsSave?) {
        switch result.quit {
        case .settled(.completed): break
        default: logStore.log(.warning, "Quit: \(result.quit)", category: .system)
        }
        // Each save the quit waited for, event first: a receipt that did not verify, or a step that never settled, is not a saved edit.
        // The editor has ended, so no reload follows and none is named.
        var saves: [(SettingsSaveTrigger, SettingsSave, RuntimeQuitStep)] = [
            (.quit, .configuration, result.configuration), (.quit, .preferences, result.preferences),
        ]
        if let prior { saves.insert((.quitPrior, prior, result.priorUpdate), at: 0) }
        for (trigger, save, step) in saves {
            let end: SettingsSaveEnd
            switch step {
            case .notDeclared:
                continue
            case .settled(let outcome):
                for unverified in SettingsSaveNotice.unverified(outcome, of: save, trigger: trigger, reloadNeeded: nil) { notice(unverified) }
                continue
            case .rejected(let code): end = .notAdmitted(code)
            case .notRecorded(let reason): end = .notRecorded(reason)
            case .clientFailure(.notSent), .clientFailure(.localRefusal): end = .notSent
            case .clientFailure: end = .clientFailure
            case .unsettled: end = .unsettled
            case .skipped: end = .quitNotAdmitted
            }
            notice(.unverified(trigger, .whole(save, end), reloadNeeded: nil))
        }
        if let failure = result.observationFailure {
            logStore.log(.warning, "Quit: observation ended early (\(failure)).", category: .system)
        }
    }

    // MARK: - Events

    /// Event first, log line derived from it.
    private func record(_ event: RuntimeEvent, level: LogLevel = .notice) {
        eventLog.append(event)
        logStore.log(level, "Settings: \(event.event) \(event.detail ?? "")", category: .system)
    }

    // MARK: - PAC evaluator

    /// The CFNetwork PAC evaluator with the app's plaintext fetch fallback. `package` so `PACEvaluatorSettingsTests` pins the wiring.
    package nonisolated static func makePACEvaluator(
        insecureFetcher: @Sendable @escaping (URL) async throws -> String
    ) -> any PacEvaluator {
        CFPACEvaluator(insecureFetcher: insecureFetcher)
    }

    /// Ceiling on a fetched PAC document. A PAC is JavaScript evaluated on every routing decision, so an unbounded fetch hands an
    /// arbitrary-sized script to the hot path; exceeding the ceiling fails the fetch rather than truncating it.
    nonisolated static let pacMaxOutputBytes = PACFetchLimits.maxScriptBytes

    /// Plaintext-URL PAC fetcher for `CFPACEvaluator.init(insecureFetcher:)`, through curl, never through Conduit's own proxy.
    @Sendable
    nonisolated static func curlPACFetcher(_ url: URL) async throws -> String {
        guard url.user == nil, url.password == nil else {
            throw PACResolverError.fetchFailed("PAC URLs must not contain embedded credentials.")
        }
        return try await Task.detached(priority: .utility) {
            let result: CommandResult
            do {
                result = try CommandRunner.run(
                    launchPath: "/usr/bin/curl",
                    arguments: [
                        "--silent", "--show-error", "--location", "--fail", "--max-time", "15",
                        // The PAC decides how the proxy routes; fetching it through that proxy sends the request around the loop.
                        "--noproxy", "*",
                        url.absoluteString,
                    ],
                    maxOutputBytes: AppState.pacMaxOutputBytes
                )
            } catch let error as CommandRunnerError {
                // One error type for every failure on this path.
                throw PACResolverError.fetchFailed(error.localizedDescription)
            }
            guard result.exitCode == 0 else {
                let message = [result.standardError, result.standardOutput].filter { !$0.isEmpty }.joined(separator: " | ")
                throw PACResolverError.fetchFailed(message.isEmpty ? "curl exited with code \(result.exitCode)." : message)
            }
            return result.standardOutput
        }.value
    }
}

/// Resumes one waiter at the first of several signals; later signals do nothing.
private final class FirstSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?

    func arm(_ continuation: CheckedContinuation<Void, Never>) {
        lock.withLock { self.continuation = continuation }
    }

    func fire() {
        let waiting = lock.withLock { () -> CheckedContinuation<Void, Never>? in
            defer { continuation = nil }
            return continuation
        }
        waiting?.resume()
    }
}

/// Notices the host did not admit, owed to it. Each is one flag or count, never a queue.
private struct OwedNotices {
    static let attempts = 3
    var credentialsChanged = 0
    var preflight: Bool?
    var preflightAttempts = 0
}

extension HelperToolPrivilegeClient.Status {
    /// The wire verdict, case for case. The helper's own refusal text is not carried on the wire.
    init(_ wire: ControlHelperStatus) {
        switch wire {
        case .installed: self = .installed
        case .outdated: self = .outdated
        case .notInstalled: self = .notInstalled
        case .notResponding: self = .notResponding
        case .busy: self = .busy
        case .waitingForConsoleUser: self = .waitingForConsoleUser
        case .unauthorized: self = .unauthorized
        case .callerNotAccepted: self = .callerNotAccepted(message: "")
        }
    }
}

extension ControlPreflightItems {
    /// The banner text: which surfaces may prompt for admin. Empty when none would.
    var summary: String {
        var parts: [String] = []
        if systemProxy.willPromptAdmin { parts.append("system proxy") }
        if splitDNS.willPromptAdmin { parts.append("DNS resolvers") }
        if parts.isEmpty { return "" }
        return "May need admin for: " + parts.joined(separator: ", ")
    }
}
