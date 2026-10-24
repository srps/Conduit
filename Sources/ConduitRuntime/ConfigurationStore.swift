// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// A baseline the store issued for one component. It names this store incarnation and the file version current for the component.
/// A verified write, an unknown write, a refused reload or a changed observation makes it stale. Only the store issues one.
struct ConfigurationBaselineToken: Equatable, Sendable {
    let storeIncarnation: UUID
    let component: ConfigurationComponent
    let version: UInt64

    fileprivate init(storeIncarnation: UUID, component: ConfigurationComponent, version: UInt64) {
        self.storeIncarnation = storeIncarnation
        self.component = component
        self.version = version
    }
}

/// A persistence fact for one component. Only the store mints it, and only after its own verified read-back or verification (decision
/// 0018). It is not proof of power-loss durability, and it does not say that a runtime apply happened.
struct ConfigurationReceipt: Equatable, Sendable {
    let storeIncarnation: UUID
    let component: ConfigurationComponent
    let version: UInt64
    let context: ConfigurationOperationContext

    fileprivate init(storeIncarnation: UUID, component: ConfigurationComponent, version: UInt64, context: ConfigurationOperationContext) {
        self.storeIncarnation = storeIncarnation
        self.component = component
        self.version = version
        self.context = context
    }
}

/// What one physical write returned, with the baseline of the verified bytes. The hash of those bytes is computed on `PlatformWork`.
private struct ConfigurationWriteAttempt: Sendable {
    let outcome: ConfigurationFileReplacementOutcome
    let verifiedBaseline: ConfigurationFileBaseline?
}

extension ConfigurationWriteOutcome {
    /// Whether the component's current verified bytes are the candidate, by a save or by verification alone.
    var isVerified: Bool {
        switch self {
        case .persisted, .unchanged: true
        case .notPersisted, .unknown, .conflict, .notAttempted: false
        }
    }
}

/// The single writer of one writable configuration root's three files, for one process incarnation (decisions 0015, 0017, 0018,
/// 0020, 0023, 0025 and 0027).
///
/// It holds the parsed values and one baseline per file. Every physical step runs on `PlatformWork`, one operation at a time: a call
/// made while another is in flight returns `.busy` at once and queues nothing. It reports typed persistence facts with the caller's
/// context. It has no intent counter, no Start or Stop, no apply, no lease release, no request ledger and no queue. The workflow that
/// adopts it owns those, and it checks its own intent and fences after each await.
///
/// The store does not mint an apply-authorizing revision from file bytes. Its per-file versions count its own verified content
/// transitions and its observed changes. They are not intent generations, and they never wrap.
@MainActor
final class ConfigurationStore {
    /// What the store knows about one file. A nil baseline means there is no authoritative baseline, and it holds until a reload.
    private struct Record: Sendable {
        var baseline: ConfigurationFileBaseline?
        var version: UInt64 = 0
        var present = false
    }

    private let incarnation = UUID()
    private let plan: StateRootPlan
    private let lease: StateWriterLease
    private let access: any StateFileAccessing
    private let work: PlatformWork
    private var records = ConfigurationSlots(runtime: Record(), platform: Record(), preferences: Record())
    private(set) var values: ConfigurationValues?
    /// Whether one operation holds the store's single slot. It is set before the first suspension and cleared when the call returns.
    private(set) var isBusy = false

    /// Admits only a writer-owned plan whose root is the leased root and whose four files resolve inside it. A read-only input
    /// or a foreign plan is refused here, before any read or write is possible.
    init(plan: StateRootPlan, lease: StateWriterLease, access: any StateFileAccessing, work: PlatformWork) throws(ConfigurationStoreRefusal) {
        guard plan.configAccess == .writerOwned else { throw .readOnlyConfigAccess }
        guard plan.root == lease.root else { throw .leaseMismatch }
        try Self.admit(plan.config, as: .config, in: plan.root)
        try Self.admit(plan.platformConfig, as: .platformConfig, in: plan.root)
        try Self.admit(plan.preferences, as: .preferences, in: plan.root)
        try Self.admit(plan.journal, as: .journal, in: plan.root)
        self.plan = plan
        self.lease = lease
        self.access = access
        self.work = work
    }

    /// The token for a component's current baseline, or nil when the store holds no authoritative baseline for it.
    func baselineToken(for component: ConfigurationComponent) -> ConfigurationBaselineToken? {
        let record = records[component]
        guard record.baseline != nil else { return nil }
        return ConfigurationBaselineToken(storeIncarnation: incarnation, component: component, version: record.version)
    }

    /// Opens or reloads the three files from one observation, read-only. The values and baselines adopt from the same bytes that were
    /// decoded. A missing file is absent and uncommitted, and nothing is written. A refused observation keeps the last values for
    /// display and holds no baseline, so no write can be authorized from it. A reload is the only way out of a latched conflict.
    func load(context: ConfigurationOperationContext) async -> ConfigurationStoreAdmission<ConfigurationLoadReport> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        let currentPlan = plan
        let access = self.access
        let observed = await work.run { ConfigurationStoreIO.observeAndDecode(plan: currentPlan, access: access) }
        return .admitted(ConfigurationLoadReport(context: context, outcome: adopt(observed)))
    }

    /// Commits the runtime and platform files as one coupled operation (decisions 0015 and 0025). Both candidates stage before the
    /// first write, and a staging refusal of either starts no write. The platform file is considered first. A present file whose
    /// verified value already equals the candidate is verified without a save, and the others are saved only when they differ. The runtime
    /// file is saved only once the platform file is verified, so a runtime rewrite cannot drop legacy platform values the platform file
    /// does not yet hold. Each write is conditional on its own baseline (decision 0027). There is no rollback and no retry.
    func commitRuntimeAndPlatform(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        expecting expected: ConfigurationSlots<ConfigurationBaselineToken?>,
        context: ConfigurationOperationContext
    ) async -> ConfigurationStoreAdmission<RuntimePlatformCommitResult> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        switch (authority(expected.runtime, for: .runtime), authority(expected.platform, for: .platform)) {
        case (.success(let runtimeBaseline), .success(let platformBaseline)):
            return .admitted(await commitCoupled(runtime, platform, runtimeBaseline, platformBaseline, context: context))
        case (.failure(let reason), _), (_, .failure(let reason)):
            return .admitted(RuntimePlatformCommitResult(context: context, runtime: .notAttempted(reason), platform: .notAttempted(reason)))
        }
    }

    /// Commits the preferences file, independently of the runtime and platform commit. It uses the same physical path and slot.
    func commitPreferences(
        _ preferences: AppPreferences,
        expecting expected: ConfigurationBaselineToken?,
        context: ConfigurationOperationContext
    ) async -> ConfigurationStoreAdmission<PreferencesCommitResult> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        let baseline: ConfigurationFileBaseline
        switch authority(expected, for: .preferences) {
        case .success(let value):
            baseline = value
        case .failure(let reason):
            return .admitted(PreferencesCommitResult(context: context, preferences: .notAttempted(reason)))
        }
        let source = plan.preferences.path
        switch await work.run({ ConfigurationStoreIO.stagePreferences(preferences, source: source) }) {
        case .refused(let reason):
            return .admitted(PreferencesCommitResult(context: context, preferences: .notAttempted(.stagingRefused(reason))))
        case .ready(let staged):
            let outcome = await commit(
                staged.bytes,
                component: .preferences,
                baseline: baseline,
                sameValue: values?.preferences == staged.value,
                context: context
            )
            if outcome.isVerified {
                values?.preferences = staged.value
            }
            return .admitted(PreferencesCommitResult(context: context, preferences: outcome))
        }
    }

    /// Checks the requested components against their baselines without writing. A changed file is reported and latched, not adopted,
    /// and an unchanged file that existed gets a receipt for its current version.
    func verifyUnchanged(
        _ components: Set<ConfigurationComponent>,
        expecting expected: ConfigurationSlots<ConfigurationBaselineToken?>,
        context: ConfigurationOperationContext
    ) async -> ConfigurationStoreAdmission<ConfigurationVerifyResult> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        var outcomes = ConfigurationSlots<ConfigurationVerifyOutcome?>(runtime: nil, platform: nil, preferences: nil)
        for component in ConfigurationComponent.allCases where components.contains(component) {
            outcomes[component] = await verify(component, expecting: expected[component], context: context)
        }
        return .admitted(ConfigurationVerifyResult(context: context, outcomes: outcomes))
    }

    /// Test seam: moves one component's version to its maximum, so the exhaustion path runs without 2^64 writes. It is internal, so only
    /// `@testable` tests reach it.
    func exhaustVersionForTesting(_ component: ConfigurationComponent) {
        records[component].version = UInt64.max
    }

    // MARK: - Coupled commit and physical steps

    private func commitCoupled(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        _ runtimeBaseline: ConfigurationFileBaseline,
        _ platformBaseline: ConfigurationFileBaseline,
        context: ConfigurationOperationContext
    ) async -> RuntimePlatformCommitResult {
        let platformSource = plan.platformConfig.path
        let staged = await work.run {
            ConfigurationStoreIO.stageRuntimeAndPlatform(runtime, platform, platformSource: platformSource)
        }
        let pair: ConfigurationStagedRuntimeAndPlatform
        switch staged {
        case .ready(let value):
            pair = value
        case .refused(let reason):
            return RuntimePlatformCommitResult(
                context: context,
                runtime: .notAttempted(.stagingRefused(reason)),
                platform: .notAttempted(.stagingRefused(reason))
            )
        }
        let platformOutcome = await commit(
            pair.platform.bytes,
            component: .platform,
            baseline: platformBaseline,
            sameValue: values?.platform == pair.platform.value,
            context: context
        )
        guard platformOutcome.isVerified else {
            return RuntimePlatformCommitResult(context: context, runtime: .notAttempted(.heldBehindPlatform), platform: platformOutcome)
        }
        values?.platform = pair.platform.value
        let runtimeOutcome = await commit(
            pair.runtime.bytes,
            component: .runtime,
            baseline: runtimeBaseline,
            sameValue: values?.runtime == pair.runtime.value,
            context: context
        )
        if runtimeOutcome.isVerified {
            values?.runtime = pair.runtime.value
        }
        return RuntimePlatformCommitResult(context: context, runtime: runtimeOutcome, platform: platformOutcome)
    }

    /// Verifies a present component whose verified value already is the candidate, without writing it, and saves every other candidate.
    /// The comparison is of parsed values through the existing equality, so formatting and unknown fields never force a rewrite
    /// (decision 0018). The bytes are then verified against the baseline.
    private func commit(
        _ bytes: Data,
        component: ConfigurationComponent,
        baseline: ConfigurationFileBaseline,
        sameValue: Bool,
        context: ConfigurationOperationContext
    ) async -> ConfigurationWriteOutcome {
        if sameValue, records[component].present {
            return await verifyCurrent(component, baseline: baseline, context: context)
        }
        return await write(bytes, component: component, baseline: baseline, context: context)
    }

    /// One conditional replacement of one file, and the store's bookkeeping for its result. Every physical step runs on `PlatformWork`.
    private func write(
        _ bytes: Data,
        component: ConfigurationComponent,
        baseline: ConfigurationFileBaseline,
        context: ConfigurationOperationContext
    ) async -> ConfigurationWriteOutcome {
        // Refused before any I/O: a verified write names a newer version, and the version never wraps.
        guard Self.canAdvance(records[component].version) else { return .notAttempted(.versionExhausted) }
        let file = file(for: component)
        let lease = self.lease
        let access = self.access
        let attempt = await work.run { () -> ConfigurationWriteAttempt in
            let outcome = VerifiedConfigurationFileReplacement.replace(bytes, at: file, under: lease, access: access, expecting: baseline)
            // The read-back equals the staged bytes, so the new baseline is the identity of those bytes, hashed off the MainActor.
            if case .verifiedPersisted = outcome {
                return ConfigurationWriteAttempt(outcome: outcome, verifiedBaseline: ConfigurationFileBaseline(observing: .present(bytes)))
            }
            return ConfigurationWriteAttempt(outcome: outcome, verifiedBaseline: nil)
        }
        switch attempt.outcome {
        case .verifiedPersisted(let reported):
            guard let verified = attempt.verifiedBaseline else { preconditionFailure("a persisted write carries its verified baseline") }
            records[component].baseline = verified
            records[component].present = true
            // Checked before the write. The busy slot keeps every other operation from changing the version in between.
            records[component].version += 1
            return .persisted(receipt(component, context: context), reportedWriteError: reported)
        case .verifiedNotPersisted(let error):
            // The read-back shows the observed prior, which is the baseline still in force.
            return .notPersisted(error)
        case .unknown(let reason, let error):
            // The file may hold the staged bytes, the prior or neither. No baseline may authorize a write until a reload.
            latch(component)
            return .unknown(reason, reportedWriteError: error)
        case .conflict:
            // Another party changed the file after its baseline was observed (decision 0027). The latch holds until a reload, even if
            // the file later returns to the old bytes.
            latch(component)
            return .conflict
        case .notStarted(let error):
            return .notAttempted(.preReadFailed(error))
        case .refused(let refusal):
            return .notAttempted(.refused(refusal))
        }
    }

    /// Verifies a present component whose content already is the candidate, without writing it. A change found here latches the baseline.
    private func verifyCurrent(
        _ component: ConfigurationComponent,
        baseline: ConfigurationFileBaseline,
        context: ConfigurationOperationContext
    ) async -> ConfigurationWriteOutcome {
        switch await verification(component, baseline: baseline) {
        case .unchanged:
            return .unchanged(receipt(component, context: context))
        case .changed:
            latch(component)
            return .conflict
        case .refused(let refusal):
            return .notAttempted(.refused(refusal))
        case .notVerified(let error):
            return .notAttempted(.preReadFailed(error))
        }
    }

    private func verify(
        _ component: ConfigurationComponent,
        expecting token: ConfigurationBaselineToken?,
        context: ConfigurationOperationContext
    ) async -> ConfigurationVerifyOutcome {
        let baseline: ConfigurationFileBaseline
        switch authority(token, for: component) {
        case .success(let value):
            baseline = value
        case .failure(let reason):
            return .notAttempted(reason)
        }
        switch await verification(component, baseline: baseline) {
        case .unchanged:
            return records[component].present ? .unchanged(receipt(component, context: context)) : .unchangedAbsent
        case .changed:
            latch(component)
            return .changed
        case .refused(let refusal):
            return .notAttempted(.refused(refusal))
        case .notVerified(let error):
            return .notVerified(error)
        }
    }

    private func verification(_ component: ConfigurationComponent, baseline: ConfigurationFileBaseline) async -> ConfigurationFileVerification {
        let file = file(for: component)
        let access = self.access
        return await work.run {
            VerifiedConfigurationFileReplacement.verifyUnchanged(file, expecting: baseline, access: access)
        }
    }

    // MARK: - Adoption and authority

    /// Adopts one load observation on the MainActor. A refusal keeps the values for display, and it holds no baseline for any file. A changed
    /// baseline that needs a newer version is refused before anything is adopted.
    private func adopt(_ observed: ConfigurationLoadObservation) -> ConfigurationLoadOutcome {
        switch observed.outcome {
        case .failure(let refusal):
            latchAll()
            return .refused(refusal)
        case .success(let frozen):
            for component in ConfigurationComponent.allCases
            where records[component].baseline != observed.baselines[component] && !Self.canAdvance(records[component].version) {
                latchAll()
                return .refused(.versionExhausted(component))
            }
            values = ConfigurationValues(
                runtime: frozen.runtime.config,
                platform: frozen.platform.config,
                preferences: frozen.preferences.preferences
            )
            // The frozen loader gives the runtime file no fallback, and it sets a legacy fallback only when it refuses a malformed legacy value.
            // A missing sidecar takes the runtime file's legacy value when that file carries one, and the defaults when its keys are absent
            // (decisions 0023 and 0026).
            precondition(frozen.runtime.warnings.isEmpty, "the frozen loader emits no warning for the runtime file")
            let loaded = ConfigurationSlots(
                runtime: ConfigurationComponentLoad(present: frozen.runtimeFilePresent, migrationPending: frozen.runtime.migrated),
                platform: ConfigurationComponentLoad(
                    present: frozen.platformSidecarPresent,
                    migrationPending: frozen.platform.migrated,
                    fallback: frozen.platform.fallback
                ),
                preferences: ConfigurationComponentLoad(
                    present: frozen.preferencesSidecarPresent,
                    migrationPending: frozen.preferences.migrated,
                    fallback: frozen.preferences.fallback
                )
            )
            for component in ConfigurationComponent.allCases {
                let baseline = observed.baselines[component]
                // The version changes only when the observed identity differs from the baseline in force, so a reload of unlatched, unchanged
                // bytes keeps its tokens. A latch clears the baseline, so a reload after a latch always takes a newer version.
                if records[component].baseline != baseline {
                    records[component].version += 1
                }
                records[component].baseline = baseline
                records[component].present = loaded[component].present
            }
            return .adopted(loaded)
        }
    }

    /// Ends a component's authority until a reload. A nil baseline authorizes nothing, so every token issued before this point is refused,
    /// and no version changes here. A reload after the latch takes a newer version even when the bytes are the old ones, so those tokens
    /// stay refused for good.
    private func latch(_ component: ConfigurationComponent) {
        records[component].baseline = nil
    }

    private func latchAll() {
        for component in ConfigurationComponent.allCases {
            latch(component)
        }
    }

    /// The baseline a token may authorize, or the reason it may not. A token from another incarnation or an older version is refused,
    /// and it does not change the current baseline.
    private func authority(
        _ token: ConfigurationBaselineToken?,
        for component: ConfigurationComponent
    ) -> Result<ConfigurationFileBaseline, ConfigurationNotAttemptedReason> {
        let record = records[component]
        guard let baseline = record.baseline else { return .failure(.noAuthoritativeBaseline) }
        guard let token, token.storeIncarnation == incarnation, token.component == component, token.version == record.version else {
            return .failure(.baselineMismatch)
        }
        return .success(baseline)
    }

    private func receipt(_ component: ConfigurationComponent, context: ConfigurationOperationContext) -> ConfigurationReceipt {
        ConfigurationReceipt(storeIncarnation: incarnation, component: component, version: records[component].version, context: context)
    }

    private func file(for component: ConfigurationComponent) -> StateRootFile {
        switch component {
        case .runtime: plan.config
        case .platform: plan.platformConfig
        case .preferences: plan.preferences
        }
    }

    /// Whether one more file version exists. Versions never wrap, so a component at the maximum is refused before any change that needs
    /// a newer version. Latching needs none, because a nil baseline already refuses every token.
    private static func canAdvance(_ version: UInt64) -> Bool {
        version < UInt64.max
    }

    private static func admit(_ file: StateRootFile, as role: StateRootRole, in root: CanonicalStateRoot) throws(ConfigurationStoreRefusal) {
        guard file.role == role else { throw .roleMismatch(file.role) }
        guard file.path.hasPrefix(root.path + "/") else { throw .fileOutsideRoot(role) }
    }
}
