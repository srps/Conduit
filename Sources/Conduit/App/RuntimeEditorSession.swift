// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyControlBridge
import ProxyKernel

/// Drives the editor's private updates and admin writes over the actual clients, one at a time (decisions 0015, 0018 and 0035). It owns
/// the ledger; the app owns the drafts and asks for a save. Every request carries frozen values and the exact baselines the ledger
/// holds, and only its own settlement moves them.
///
/// Bounds: one operation in flight, driven by one task; one pending want per group and one latest login-item value. A refused admission
/// is not replayed by itself: the group stays wanted until the next trigger (an edit's pause, a commit, a snapshot after a stale
/// revision). An admission whose answer was lost is recovered by request lookup, never by sending the values again.
@MainActor
final class RuntimeEditorSession {
    /// What the app shows or records about one operation.
    enum Report {
        /// A configuration update was submitted; `held` says it saves only because the draft blocks a start.
        case submitted(RuntimeEditorLedger.Group, held: Bool)
        case settled(RuntimeEditorLedger.Submission, ControlOperationOutcome)
        case notAdmitted(RuntimeEditorLedger.Group?, ControlRejectionCode?)
        /// The draft could not be mapped into a request, or a file needs a reload; nothing was sent.
        case refusedLocally(RuntimeEditorLedger.Group, SettingsSaveRefusal)
        /// Admission or settlement could not be read; the files it could write need an explicit reload.
        case unknown(RuntimeEditorLedger.Group?)
        case launchAtLogin(enabled: Bool, verified: Bool)
    }

    /// How long one exchange, its admission lookup or its settlement read may take. Not the quit's budget.
    nonisolated static let exchangeBudget: Duration = .seconds(30)
    /// Refusals that recorded nothing (a stale revision, a full queue, a busy transport) in a row before a group is left for the next
    /// explicit trigger. Each retry waits for a new snapshot.
    static let staleRetryLimit = 3

    private let control: any RuntimeClient
    private let editor: PrivateEditorClient
    private let observer: RuntimeObserver
    let incarnation: ControlHostIncarnation
    private(set) var ledger: RuntimeEditorLedger
    /// The current drafts, read when an operation is frozen. Nil once the app that owns them is gone.
    private let drafts: @MainActor () -> (config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences)?
    /// The intent a Settings save carries per module: apply while running at the observed revision, otherwise save only. Nil once the
    /// app is gone.
    private let moduleIntents: @MainActor (_ holdApply: Bool) -> PrivateModuleSlots<PrivateModuleIntent>?
    private let report: @MainActor (Report) -> Void

    private var wanted: Set<RuntimeEditorLedger.Group> = []
    private var wantedLaunchAtLogin: Bool?
    private var staleRetries: [RuntimeEditorLedger.Group: Int] = [:]
    /// Groups the host recorded nothing for, tried again when the next snapshot arrives.
    private var retryOnSnapshot: Set<RuntimeEditorLedger.Group> = []
    private var drive: Task<Void, Never>?
    /// The operation a kick chose whose task has not run yet.
    private var starting: Operation?
    private var closed = false

    init(
        control: any RuntimeClient,
        editor: PrivateEditorClient,
        observer: RuntimeObserver,
        incarnation: ControlHostIncarnation,
        ledger: RuntimeEditorLedger,
        drafts: @escaping @MainActor () -> (config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences)?,
        moduleIntents: @escaping @MainActor (_ holdApply: Bool) -> PrivateModuleSlots<PrivateModuleIntent>?,
        report: @escaping @MainActor (Report) -> Void
    ) {
        self.control = control
        self.editor = editor
        self.observer = observer
        self.incarnation = incarnation
        self.ledger = ledger
        self.drafts = drafts
        self.moduleIntents = moduleIntents
        self.report = report
    }

    var isIdle: Bool { drive == nil }

    /// Joins the operation in flight and any it starts, for the quit and the tests. Bounded by the operations already wanted.
    func settle() async {
        while let drive { await drive.value }
    }

    func edited(_ group: RuntimeEditorLedger.Group) {
        ledger.edited(group)
    }

    /// Asks for `group`'s draft to be saved, after the operation in flight.
    func save(_ group: RuntimeEditorLedger.Group) {
        guard !closed else { return }
        wanted.insert(group)
        kick()
    }

    /// Asks for the login-item flag to be written. Admitted only while nothing is in flight or wanted, so it runs at once and a quit
    /// that begins while it is out names it as its prior update; never queued behind a save, where a quit would drop it. False when
    /// refused: nothing was accepted.
    func setLaunchAtLogin(_ enabled: Bool) -> Bool {
        guard !closed, drive == nil, wanted.isEmpty, wantedLaunchAtLogin == nil else { return false }
        wantedLaunchAtLogin = enabled
        kick()
        return true
    }

    /// A snapshot arrived: a save refused for a stale revision may be tried once more under the new one.
    func revisionsMayHaveMoved() {
        guard !retryOnSnapshot.isEmpty else { return }
        wanted.formUnion(retryOnSnapshot)
        retryOnSnapshot = []
        kick()
    }

    /// No operation starts after this, including one a kick created whose task has not run. The quit's own final saves run through
    /// `RuntimeClientQuit`. True when that unstarted operation was an admitted login-item write, which the quit cannot carry: the
    /// caller reports it.
    @discardableResult
    func close() -> Bool {
        closed = true
        wanted = []
        retryOnSnapshot = []
        wantedLaunchAtLogin = nil
        defer { starting = nil }
        if case .launchAtLogin? = starting { return true }
        return false
    }

    /// The app that owns the drafts is gone: no draft or intent is made up for it, nothing is sent and the ledger records nothing. The
    /// session closes, so no later trigger (a snapshot's retry, an own command's explained mismatch) starts anything either. Called from
    /// the drive, so no unstarted operation is pending.
    private func ownerGone() {
        close()
    }

    /// Replaces the ledger after an explicit reload's fresh read. Only while nothing is in flight.
    func rebuild(_ ledger: RuntimeEditorLedger) {
        precondition(drive == nil, "a reload rebuilds the editor only while nothing is in flight")
        self.ledger = ledger
        wanted = []
        retryOnSnapshot = []
        staleRetries = [:]
    }

    /// One of this app's own saved commands is about to be sent; recorded before it is, so a save racing it can wait for its write.
    func ownCommandSent(_ command: ControlRuntimeCommand, requestID: ControlRequestID) {
        ledger.ownCommandSent(command, requestID: requestID)
    }

    /// Records how one of this app's own saved commands ended: its causal write, chained on its exact prior, or, when it may have written
    /// and no such write can be read, the loss of the authority it may have changed. A save its write had refused goes again.
    func ownCommandEnded(outcome: ControlOperationOutcome?, requestID: ControlRequestID) {
        ledger.ownCommandEnded(requestID, outcome: outcome)
        resubmitAnExplainedMismatch()
    }

    /// One of this app's own saved commands was never run: not sent, refused locally or rejected at admission. It wrote nothing.
    func ownCommandNotRun(requestID: ControlRequestID) {
        ledger.ownCommandNotRun(requestID)
        resubmitAnExplainedMismatch()
    }

    /// A save refused only because an own write had moved the file goes again, under the baseline that write left.
    private func resubmitAnExplainedMismatch() {
        guard ledger.takeExplainedMismatch(), !closed, ledger.needsSubmission(.configuration), ledger.isDirty(.configuration) else { return }
        save(.configuration)
    }

    // MARK: - The drive

    private func kick() {
        guard drive == nil, !closed else { return }
        guard let next = nextOperation() else { return }
        starting = next
        drive = Task { @MainActor [weak self] in
            // A close between the kick and this turn starts nothing.
            self?.starting = nil
            if self?.closed == false { await self?.run(next) }
            self?.drive = nil
            self?.kick()
        }
    }

    private enum Operation {
        case save(RuntimeEditorLedger.Group)
        case launchAtLogin(Bool)
    }

    private func nextOperation() -> Operation? {
        if let enabled = wantedLaunchAtLogin {
            wantedLaunchAtLogin = nil
            return .launchAtLogin(enabled)
        }
        for group in [RuntimeEditorLedger.Group.configuration, .preferences] where wanted.contains(group) {
            wanted.remove(group)
            guard ledger.needsSubmission(group) else { continue }
            return .save(group)
        }
        return nil
    }

    private func run(_ operation: Operation) async {
        switch operation {
        case .launchAtLogin(let enabled):
            await runLaunchAtLogin(enabled)
        case .save(.configuration):
            await runConfiguration()
        case .save(.preferences):
            await runPreferences()
        }
    }

    private func runConfiguration() async {
        guard let draft = drafts() else { return ownerGone() }
        // The bridge refuses a value past an approved ceiling before mapping anything (decision 0021); the client reports a refusal its
        // producer threw only as a closed code, so the same check runs here first and names the field and the ceiling, never the value.
        if let violation = draft.config.resourceViolation() {
            return report(.refusedLocally(.configuration, .resourceLimit(violation)))
        }
        // The store's staging refuses a value its file cannot hold exactly, but its receipt says only `staging_refused`; the same staging
        // runs here first so the refusal names the field and the requirement.
        if let refusal = draft.config.runtimeFileRefusal() {
            return report(.refusedLocally(.configuration, .notStorable(field: refusal.field, requirement: refusal.requirement)))
        }
        let holdApply = !draft.config.startBlockingProblems.isEmpty
        // Read in the drafts' turn, before the ledger records a submission, so an app gone by now leaves nothing half-submitted.
        guard let modules = moduleIntents(holdApply) else { return ownerGone() }
        let requestID = ControlRequestID(rawValue: UUID())
        guard let submission = ledger.submitConfiguration(draft.config, draft.platform, requestID: requestID) else {
            // A file lost its baseline; only an explicit reload lets the editor write it again. Nothing is sent.
            return report(.refusedLocally(.configuration, .needsReload))
        }
        let incarnation = incarnation
        let deadline = RuntimeDeadline.after(Self.exchangeBudget, from: .now)
        let baselines = submission.baselines
        report(.submitted(.configuration, held: holdApply))
        let admission = await admit(.configuration, requestID: requestID) { [editor] in
            try await editor.submit(requestID: requestID, deadline: deadline) {
                guard let runtime = baselines.runtime, let platform = baselines.platform else {
                    throw PrivateConfigurationWireError.invalidValue
                }
                return try PrivateConfigurationBridge.makeRequest(
                    config: draft.config, platform: draft.platform, requestID: requestID, incarnation: incarnation,
                    budget: try deadline.wireBudget(at: .now, cappedAt: Self.exchangeBudget),
                    runtimeBaseline: runtime, platformBaseline: platform, modules: modules
                )
            }
        }
        await settle(submission, admission: admission, group: .configuration)
    }

    private func runPreferences() async {
        guard let draft = drafts() else { return ownerGone() }
        // As for the configuration: the bridge's own ceiling, checked before freezing, so the refusal names the field.
        if let violation = DomainResourceCheck.text(draft.preferences.preferredBrowserTestURL, .browserTestURL) {
            return report(.refusedLocally(.preferences, .resourceLimit(violation)))
        }
        let requestID = ControlRequestID(rawValue: UUID())
        guard let submission = ledger.submitPreferences(draft.preferences, requestID: requestID) else {
            return report(.refusedLocally(.preferences, .needsReload))
        }
        let incarnation = incarnation
        let deadline = RuntimeDeadline.after(Self.exchangeBudget, from: .now)
        let baselines = submission.baselines
        report(.submitted(.preferences, held: false))
        let admission = await admit(.preferences, requestID: requestID) { [editor] in
            try await editor.submitPreferences(requestID: requestID, deadline: deadline) {
                guard let preferences = baselines.preferences else { throw PrivateConfigurationWireError.invalidValue }
                return try PrivateConfigurationBridge.makePreferencesRequest(
                    preferences: draft.preferences, requestID: requestID, incarnation: incarnation,
                    budget: try deadline.wireBudget(at: .now, cappedAt: Self.exchangeBudget), preferencesBaseline: preferences
                )
            }
        }
        await settle(submission, admission: admission, group: .preferences)
    }

    private func runLaunchAtLogin(_ enabled: Bool) async {
        let requestID = ControlRequestID(rawValue: UUID())
        guard let submission = ledger.submitLaunchAtLogin(enabled, requestID: requestID),
              let baseline = submission.baselines.platform else {
            return report(.launchAtLogin(enabled: enabled, verified: false))
        }
        let deadline = RuntimeDeadline.after(Self.exchangeBudget, from: .now)
        let admission = await admit(nil, requestID: requestID) { [control, incarnation] in
            try await control.submit(
                .setLaunchAtLogin(enabled, ifPlatformBaseline: baseline), requestID: requestID,
                expectedIncarnation: incarnation, deadline: deadline
            )
        }
        let outcome = await settle(submission, admission: admission, group: nil)
        var verified = false
        if case .completed(let completion)? = outcome, case .platformWrite(let write) = completion.result {
            verified = write.write.isVerified
        }
        report(.launchAtLogin(enabled: enabled, verified: verified))
    }

    // MARK: - Admission and settlement

    private enum Admission {
        case admitted(ControlOperationID)
        case notAdmitted(ControlRejectionCode?)
        case refusedLocally(SettingsSaveRefusal)
        case unknown
    }

    /// One exchange. A lost answer after a possible send is looked up by request ID once, never resent.
    private func admit(
        _ group: RuntimeEditorLedger.Group?,
        requestID: ControlRequestID,
        _ exchange: @escaping () async throws -> ControlAdmission
    ) async -> Admission {
        do {
            switch try await exchange() {
            case .accepted(let operation), .joined(let operation): return .admitted(operation)
            case .rejected(let code): return .notAdmitted(code)
            }
        } catch RuntimeClientError.notSent {
            return .notAdmitted(nil)
        } catch RuntimeClientError.localRefusal(let code) {
            return .refusedLocally(.clientRefused(code))
        } catch RuntimeClientError.admissionUnknown {
            return await lookUpAdmission(requestID)
        } catch PrivateConfigurationBridgeError.resourceLimit(let violation),
                PrivateConfigurationWireError.resourceLimitExceeded(let violation) {
            return .refusedLocally(.resourceLimit(violation))
        } catch PrivateConfigurationBridgeError.tooLarge, PrivateConfigurationWireError.frameTooLarge {
            return .refusedLocally(.tooLarge)
        } catch let error as PrivateConfigurationWireError {
            return .refusedLocally(.notRepresentable(error))
        } catch {
            return .unknown
        }
    }

    private func lookUpAdmission(_ requestID: ControlRequestID) async -> Admission {
        do {
            let lookup = try await control.lookupAdmission(
                of: requestID, expectedIncarnation: incarnation, deadline: .after(Self.exchangeBudget, from: .now)
            )
            switch lookup {
            case .admission(.accepted(let operation)), .admission(.joined(let operation)): return .admitted(operation)
            case .admission(.rejected(let code)): return .notAdmitted(code)
            case .unknown: return .unknown
            }
        } catch {
            return .unknown
        }
    }

    @discardableResult
    private func settle(
        _ submission: RuntimeEditorLedger.Submission, admission: Admission, group: RuntimeEditorLedger.Group?
    ) async -> ControlOperationOutcome? {
        switch admission {
        case .admitted(let operation):
            guard let outcome = await observer.settlement(of: operation) else {
                ledger.settlementUnknown(submission.requestID)
                report(.unknown(group))
                return nil
            }
            ledger.settled(submission.requestID, incarnation: incarnation, outcome: outcome)
            if let group { staleRetries[group] = nil }
            report(.settled(submission, outcome))
            resubmitAnExplainedMismatch()
            return outcome
        case .notAdmitted(let code):
            ledger.notAdmitted(submission.requestID)
            if let group, code == .staleRevision || code == .queueFull || code == nil {
                // The host recorded nothing. The draft stays wanted until the next snapshot, a bounded number of times in a row.
                let tries = staleRetries[group, default: 0] + 1
                if tries <= Self.staleRetryLimit {
                    staleRetries[group] = tries
                    retryOnSnapshot.insert(group)
                } else {
                    staleRetries[group] = nil
                }
            }
            report(.notAdmitted(group, code))
        case .refusedLocally(let reason):
            ledger.notAdmitted(submission.requestID)
            if let group { report(.refusedLocally(group, reason)) }
        case .unknown:
            ledger.settlementUnknown(submission.requestID)
            report(.unknown(group))
        }
        return nil
    }
}

extension ProxyConfig {
    /// The refusal, by field and requirement, of the store's own staging of this value as the schema-two runtime file
    /// (`ProxyConfigPersistence.stagedFile`, the step the sole writer runs before any write). Nil when it stages. Any other staging
    /// failure is left to the store, whose receipt reports it.
    func runtimeFileRefusal() -> ConfigFileRepresentabilityError? {
        do {
            _ = try ProxyConfigPersistence.stagedFile(for: self)
            return nil
        } catch let refusal as ConfigFileRepresentabilityError {
            return refusal
        } catch {
            return nil
        }
    }
}
