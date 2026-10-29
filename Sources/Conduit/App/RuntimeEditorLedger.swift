// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import ProxyKernel

/// The Settings editor's authority over its drafts (decisions 0015, 0018, 0027 and 0035): the exact store baselines it may write under,
/// the local edit versions of its drafts, and its one operation in flight. A pure value, so the app, the quit's producers and the
/// model tests run the same transitions.
///
/// Rules, from the editor contract:
/// - A baseline advances only from this editor's own causal answer to a request it submitted: its update's receipt, its own admin
///   write, or its own saved command's write chained on the exact prior it held. A status, a reload, another client's write or a fresh
///   read never moves one.
/// - A draft is clean only while its local edit version is the version some own receipt verified. An edit made after a submission
///   keeps its newer version, so no receipt can mark it clean; values are never compared to decide.
/// - One operation in flight. A later save waits for it, so it is submitted under the baselines that operation's receipt left, never
///   beside it under older ones.
/// - A write whose state is unknown, or a refused one, drops that file's baseline: nothing is written to it again until an explicit
///   reload rebuilds the editor from a fresh read.
/// - An own saved command (a DNS Stop's disable save, a saved Start's commit) is known from its sending until it ends. While one that may
///   write a file is out, a `baselineMismatch` on that file is held for it to explain: its chained write moving the baseline past the
///   refused one explains it, and the refused draft may go again; its end without one leaves the mismatch unexplained, and the file
///   loses its authority. A chained write that nothing still out can lead to is an own write this editor cannot place, so it too drops
///   the file's authority rather than waiting forever.
struct RuntimeEditorLedger: Sendable {
    /// What one operation saves.
    enum Group: Sendable, Hashable {
        /// The runtime and platform files, as one private update.
        case configuration
        /// The preferences file.
        case preferences
    }

    /// The one operation in flight.
    struct Submission: Sendable, Equatable {
        enum Kind: Sendable, Equatable {
            case configuration(ProxyConfig, PlatformIntegrationConfig)
            case preferences(AppPreferences)
            case launchAtLogin(Bool)
        }

        let requestID: ControlRequestID
        let kind: Kind
        /// The draft's edit version when it was frozen. Zero for the admin write, which carries no draft.
        let version: UInt64
        /// The baselines it was submitted under.
        let baselines: PrivateComponentSlots<PrivateBaseline?>
    }

    /// A saved command's write this editor caused, waiting until the baseline it was conditional on is the one held. Bounded.
    struct ChainedWrite: Sendable, Equatable {
        let file: ControlConfigWorkflowFile
        let prior: PrivateBaseline
        let write: ControlComponentWrite
        /// The DNS bit the runtime file holds after it, for a runtime write.
        let dnsForwarderEnabled: Bool?
    }

    /// Own saved commands that can be out at once: the app's ordinary command cap and one reserved Stop per module (`AppState.send`). A
    /// command past it is not tracked silently: the files it may write lose their baselines.
    static let maximumOwnCommands = 11
    /// Two files for each own command. A write past it is not evicted silently: its file loses its baseline, so the editor stops writing
    /// it until an explicit reload.
    static let maximumChainedWrites = 2 * maximumOwnCommands

    private(set) var baselines: PrivateComponentSlots<PrivateBaseline?>
    /// The values the files hold at `baselines`, as far as this editor knows: the startup or reload observation, then its own verified
    /// writes. The quit's clean runtime fallback and the listener classification read them; cleanliness never does.
    private(set) var saved: (config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences)
    private(set) var configurationVersion: UInt64 = 0
    private(set) var preferencesVersion: UInt64 = 0
    private(set) var savedConfigurationVersion: UInt64 = 0
    private(set) var savedPreferencesVersion: UInt64 = 0
    private(set) var active: Submission?
    private(set) var chained: [ChainedWrite] = []
    /// Own saved commands sent and not yet ended, with the files each may write. Bounded by `maximumOwnCommands`.
    private(set) var ownCommands: [ControlRequestID: [ControlConfigWorkflowFile]] = [:]
    /// Files whose own submission met `baselineMismatch` while an own command could still explain it, with the baseline it carried.
    private(set) var heldMismatches: [ControlConfigWorkflowFile: PrivateBaseline] = [:]
    /// A held mismatch was explained by the own write that caused it, so the refused draft may be submitted again. Taken once.
    private var explainedMismatch = false
    /// The configuration draft version the last mismatch refused.
    private var mismatchRefusedVersion: UInt64?

    init(observation: PrivateEditorObservation, config: ProxyConfig, platform: PlatformIntegrationConfig, preferences: AppPreferences) {
        baselines = PrivateComponentSlots(
            runtime: observation.components.runtime.baseline,
            platform: observation.components.platform.baseline,
            preferences: observation.components.preferences.baseline
        )
        saved = (config, platform, preferences)
    }

    // MARK: - Drafts

    mutating func edited(_ group: Group) {
        switch group {
        case .configuration: configurationVersion += 1
        case .preferences: preferencesVersion += 1
        }
    }

    func isDirty(_ group: Group) -> Bool {
        switch group {
        case .configuration: configurationVersion != savedConfigurationVersion
        case .preferences: preferencesVersion != savedPreferencesVersion
        }
    }

    /// Whether the draft of `group` has a version no submission covers: dirty, and not the version of the operation in flight.
    func needsSubmission(_ group: Group) -> Bool {
        guard isDirty(group) else { return false }
        guard let active else { return true }
        switch (group, active.kind) {
        case (.configuration, .configuration): return active.version != configurationVersion
        case (.preferences, .preferences): return active.version != preferencesVersion
        default: return true
        }
    }

    /// The files `group` writes, each of which must hold a baseline before anything is submitted.
    static func files(of group: Group) -> [ControlConfigWorkflowFile] {
        switch group {
        case .configuration: [.runtime, .platform]
        case .preferences: [.preferences]
        }
    }

    /// The files whose baseline was dropped, so only an explicit reload can write them again.
    var filesNeedingReload: [ControlConfigWorkflowFile] {
        ControlConfigWorkflowFile.allCases.filter { baselines[$0] == nil }
    }

    func canSubmit(_ group: Group) -> Bool {
        active == nil && Self.files(of: group).allSatisfy { baselines[$0] != nil }
    }

    // MARK: - Submissions

    /// Freezes the configuration draft as the one operation in flight. Nil when one is already in flight or a file holds no baseline.
    mutating func submitConfiguration(
        _ config: ProxyConfig, _ platform: PlatformIntegrationConfig, requestID: ControlRequestID
    ) -> Submission? {
        guard canSubmit(.configuration) else { return nil }
        let submission = Submission(
            requestID: requestID, kind: .configuration(config, platform), version: configurationVersion, baselines: baselines
        )
        active = submission
        return submission
    }

    mutating func submitPreferences(_ preferences: AppPreferences, requestID: ControlRequestID) -> Submission? {
        guard canSubmit(.preferences) else { return nil }
        let submission = Submission(
            requestID: requestID, kind: .preferences(preferences), version: preferencesVersion, baselines: baselines
        )
        active = submission
        return submission
    }

    mutating func submitLaunchAtLogin(_ enabled: Bool, requestID: ControlRequestID) -> Submission? {
        guard active == nil, baselines.platform != nil else { return nil }
        let submission = Submission(requestID: requestID, kind: .launchAtLogin(enabled), version: 0, baselines: baselines)
        active = submission
        return submission
    }

    /// The host did not admit the operation in flight, or its admission is known to have recorded nothing: no file was written. It no
    /// longer counts as own work that may yet move a file, so a mismatch or a chained write that waited on it is settled now rather than
    /// left stranded.
    mutating func notAdmitted(_ requestID: ControlRequestID) {
        guard active?.requestID == requestID else { return }
        active = nil
        reconcile()
    }

    /// The operation in flight was admitted and its settlement could not be read: what it wrote is unknown, so every file it could write
    /// loses its baseline.
    mutating func settlementUnknown(_ requestID: ControlRequestID) {
        guard let active, active.requestID == requestID else { return }
        self.active = nil
        dropBaselines(of: active.kind)
        reconcile()
    }

    // MARK: - Own causal answers

    /// The settlement of the operation in flight, matched by its request ID. Any other outcome is not this editor's and changes nothing.
    mutating func settled(_ requestID: ControlRequestID, incarnation: ControlHostIncarnation, outcome: ControlOperationOutcome) {
        guard let active, active.requestID == requestID else { return }
        self.active = nil
        switch (active.kind, outcome) {
        case (.configuration(let config, let platform), .configurationSettled(let receipt)):
            guard receipt.requestID == requestID, receipt.incarnation == incarnation, receipt.prior == nil else {
                return dropBaselines(of: active.kind)
            }
            let runtime = adopt(receipt.runtime, file: .runtime, submittedUnder: active.baselines.runtime)
            let platformVerified = adopt(receipt.platform, file: .platform, submittedUnder: active.baselines.platform)
            if runtime {
                saved.config = config
                if let enabled = receipt.committedDNSForwarderEnabled { saved.config.dnsForwarderEnabled = enabled }
            }
            if platformVerified {
                let launchAtLogin = saved.platform.launchAtLogin
                saved.platform = platform
                saved.platform.launchAtLogin = launchAtLogin
            }
            if runtime && platformVerified { savedConfigurationVersion = active.version }
            for write in [receipt.runtime.write, receipt.platform.write] {
                if case .notAttempted(.baselineMismatch) = write { mismatchRefusedVersion = active.version }
            }
        case (.preferences(let preferences), .preferencesSettled(let receipt)):
            guard receipt.requestID == requestID, receipt.incarnation == incarnation else { return dropBaselines(of: active.kind) }
            if adopt(receipt.preferences, file: .preferences, submittedUnder: active.baselines.preferences) {
                saved.preferences = preferences
                savedPreferencesVersion = active.version
            }
        case (.launchAtLogin(let enabled), .completed(let completion)):
            guard case .platformWrite(let write) = completion.result else { return dropBaselines(of: active.kind) }
            if adopt(write, file: .platform, submittedUnder: active.baselines.platform) { saved.platform.launchAtLogin = enabled }
        case (_, .failed(.storeBusy)):
            // The store's one slot was taken, so nothing was captured or written: the only failure proven to precede any write. Every
            // baseline holds.
            break
        case (_, .failed):
            // Any other failure can stand for work that ran (the service replaces an outcome it cannot encode with an internal failure),
            // so what the files hold is unknown.
            dropBaselines(of: active.kind)
        default:
            // An outcome this operation cannot settle with, such as a supersession, says nothing exact about the files.
            dropBaselines(of: active.kind)
        }
        reconcile()
    }

    /// One of this app's own saved commands is about to be sent. Recorded before the send, so a save submitted while it is out knows a
    /// mismatch on the files it may write can be its doing.
    mutating func ownCommandSent(_ command: ControlRuntimeCommand, requestID: ControlRequestID) {
        let files = Self.filesWritten(by: command)
        guard !files.isEmpty else { return }
        guard ownCommands.count < Self.maximumOwnCommands else {
            // It cannot be tracked, so what it writes could not be placed: its files give up their authority now.
            for file in files { drop(file) }
            return
        }
        ownCommands[requestID] = files
    }

    /// How one of this app's own saved commands ended. Its causal write, chained on its exact prior, advances a baseline only while that
    /// baseline is exactly the prior; one that arrives before the receipt that leads to its prior waits, bounded, for it. When it may have
    /// written and no such write can be read (its settlement was lost, or it failed, partially completed or was superseded after it may
    /// have written) the files it may write lose their authority. A Stop that completed with no write, a store-busy failure and a saved
    /// Start's closed failure (which it reports only when no commit ran, `ControlCompletion`) wrote nothing.
    mutating func ownCommandEnded(_ requestID: ControlRequestID, outcome: ControlOperationOutcome?) {
        guard let files = ownCommands.removeValue(forKey: requestID) else { return }
        defer { reconcile() }
        if let outcome {
            let writes = Self.chainedWrites(of: outcome, requestID: requestID)
            if !writes.isEmpty {
                for write in writes { chain(write) }
                return
            }
            switch outcome {
            case .completed, .failed(.storeBusy):
                return
            case .failed(let code) where code != .internalFailure && files.contains(.platform):
                // An internal failure can stand for an outcome the service could not encode after work ran, so it is not proof.
                return
            case .configurationSettled, .preferencesSettled, .superseded, .partiallyCompleted, .failed:
                break
            }
        }
        for file in files { drop(file) }
    }

    /// One of this app's own saved commands never ran (not sent, refused locally, rejected at admission): it wrote nothing.
    mutating func ownCommandNotRun(_ requestID: ControlRequestID) {
        guard ownCommands.removeValue(forKey: requestID) != nil else { return }
        reconcile()
    }

    /// Whether a held mismatch was explained since this was last asked, and the draft it refused is still the current one, so it may be
    /// submitted again. A newer edit keeps its own trigger (a pause or a commit), so a held edit is never saved by this.
    mutating func takeExplainedMismatch() -> Bool {
        guard explainedMismatch else { return false }
        defer {
            explainedMismatch = false
            mismatchRefusedVersion = nil
        }
        return mismatchRefusedVersion == configurationVersion
    }

    /// The configuration files a saved command may write: a DNS Stop its disable save, a saved Start or Restart its commit.
    static func filesWritten(by command: ControlRuntimeCommand) -> [ControlConfigWorkflowFile] {
        switch command {
        case .stop(.dns): [.runtime]
        case .start, .restart: [.runtime, .platform]
        default: []
        }
    }

    /// A DNS Stop's disable save, or a saved Start's or Restart's commit, as chained writes.
    static func chainedWrites(of outcome: ControlOperationOutcome, requestID: ControlRequestID) -> [ChainedWrite] {
        switch outcome {
        case .completed(let completion):
            guard case .dnsDisable(let disable) = completion.result, let prior = disable.prior else { return [] }
            return [ChainedWrite(file: .runtime, prior: prior, write: disable.runtime, dnsForwarderEnabled: false)]
        case .configurationSettled(let receipt):
            guard receipt.requestID == requestID, let prior = receipt.prior else { return [] }
            var writes: [ChainedWrite] = []
            if let runtime = prior.runtime {
                writes.append(ChainedWrite(
                    file: .runtime, prior: runtime, write: receipt.runtime, dnsForwarderEnabled: receipt.committedDNSForwarderEnabled
                ))
            }
            if let platform = prior.platform {
                writes.append(ChainedWrite(file: .platform, prior: platform, write: receipt.platform, dnsForwarderEnabled: nil))
            }
            return writes
        default:
            return []
        }
    }

    // MARK: - Quit

    /// This ledger as the quit's read of the operation that was in flight leaves it: that operation's own settlement applied, exactly as
    /// `settled` would, and nothing else. A final save is submitted under its baselines; an unsettled prior leaves them as they were.
    func afterQuitPrior(_ prior: RuntimeQuitStep, incarnation: ControlHostIncarnation) -> RuntimeEditorLedger {
        var ledger = self
        if let active, case .settled(let outcome) = prior {
            ledger.settled(active.requestID, incarnation: incarnation, outcome: outcome)
        }
        return ledger
    }

    /// The baselines a quit's final save is submitted under, given `after`, this ledger as the prior's settlement leaves it: each file's
    /// from `after` when that settlement left one (a verified own receipt's wins), otherwise the verified baseline this ledger held when
    /// the save was frozen, as for an unsettled prior. Only the save's precondition, which the host compares with the file before writing
    /// and refuses for a file anyone moved; it gives no authority back to `after` or to this ledger.
    func quitSaveBaselines(after: RuntimeEditorLedger) -> PrivateComponentSlots<PrivateBaseline?> {
        PrivateComponentSlots(
            runtime: after.baselines.runtime ?? baselines.runtime,
            platform: after.baselines.platform ?? baselines.platform,
            preferences: after.baselines.preferences ?? baselines.preferences
        )
    }

    // MARK: - Internals

    private static func files(of kind: Submission.Kind) -> [ControlConfigWorkflowFile] {
        switch kind {
        case .configuration: [.runtime, .platform]
        case .preferences: [.preferences]
        case .launchAtLogin: [.platform]
        }
    }

    private mutating func dropBaselines(of kind: Submission.Kind) {
        for file in Self.files(of: kind) { drop(file) }
    }

    /// The file loses its authority until an explicit reload, with every fact that could only have moved it.
    private mutating func drop(_ file: ControlConfigWorkflowFile) {
        baselines[file] = nil
        chained.removeAll { $0.file == file }
        heldMismatches[file] = nil
    }

    private mutating func chain(_ write: ChainedWrite) {
        // A file that already lost its baseline gains nothing from a chain; only a reload restores it.
        guard baselines[write.file] != nil else { return }
        guard chained.count < Self.maximumChainedWrites else {
            // The chain cannot be kept whole, so the file's authority is given up rather than one fact dropped.
            return drop(write.file)
        }
        chained.append(write)
    }

    /// Whether an own operation still out may yet move `file`'s baseline: the submission in flight, or a saved command not yet ended.
    private func ownWorkMayMove(_ file: ControlConfigWorkflowFile) -> Bool {
        if let active, Self.files(of: active.kind).contains(file) { return true }
        return ownCommands.values.contains { $0.contains(file) }
    }

    /// One file's write: a verified write moves its baseline; a write that cannot have changed the file keeps it; a conflict or an unknown
    /// write drops it. A mismatch is held while an own command still out, or its write still waiting to be chained, may explain it.
    /// True when the file now holds what was submitted.
    private mutating func adopt(
        _ write: ControlComponentWrite, file: ControlConfigWorkflowFile, submittedUnder submitted: PrivateBaseline?
    ) -> Bool {
        switch write.write {
        case .persisted, .unchanged:
            // A receipt moves a baseline still held. It never restores one an own write of unknown effect took away while this was
            // out: that write may still land after this one, so only an explicit reload gives the file its authority back.
            if baselines[file] != nil { baselines[file] = write.baseline }
            return write.baseline != nil
        case .notAttempted(.baselineMismatch):
            guard let submitted, baselines[file] == submitted else {
                // An own chained write already moved the baseline past the one refused: explained, so the draft may go again.
                if baselines[file] != nil { explainedMismatch = true }
                return false
            }
            if ownWorkMayMove(file) || chained.contains(where: { $0.file == file }) {
                heldMismatches[file] = submitted
            } else {
                drop(file)
            }
            return false
        case .notPersisted, .notAttempted:
            return false
        case .conflict, .unknown:
            drop(file)
            return false
        }
    }

    /// Applies what can be applied, then settles what can no longer change: an obsolete chained write is pruned, a held mismatch is
    /// explained or lost, and a chained write nothing still out can lead to drops its file's authority.
    private mutating func reconcile() {
        // A write conditional on an older version of the held namespace can never become current: the file has moved past it.
        chained.removeAll { entry in
            guard let held = baselines[entry.file] else { return true }
            return entry.prior.namespace == held.namespace && entry.prior.version < held.version
        }
        var progressed = true
        while progressed {
            progressed = false
            for (index, entry) in chained.enumerated() where baselines[entry.file] == entry.prior {
                chained.remove(at: index)
                if adopt(entry.write, file: entry.file, submittedUnder: entry.prior), entry.file == .runtime,
                   let enabled = entry.dnsForwarderEnabled {
                    saved.config.dnsForwarderEnabled = enabled
                }
                progressed = true
                break
            }
        }
        for (file, refused) in heldMismatches {
            if baselines[file] != refused {
                heldMismatches[file] = nil
                if baselines[file] != nil { explainedMismatch = true }
            } else if !ownWorkMayMove(file), !chained.contains(where: { $0.file == file }) {
                drop(file)
            }
        }
        for file in Set(chained.map(\.file)) where !ownWorkMayMove(file) {
            drop(file)
        }
    }
}
