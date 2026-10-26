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

/// The sidecar a runtime rewrite must verify first, when the runtime file carries legacy values the sidecar would otherwise hold (decision
/// 0026). It is checked in the same physical step as the rewrite, after the platform file has verified, and it is always re-verified.
private struct ConfigurationPreservationCheck: Sendable {
    let component: ConfigurationComponent
    let file: StateRootFile
    let baseline: ConfigurationFileBaseline
    /// Whether the sidecar existed when this baseline was adopted or verified. An absent baseline needs the sidecar saved first.
    let present: Bool
}

/// The runtime file bytes a missing sidecar takes its values from (decisions 0023 and 0026). The sidecar's first write checks them in the
/// same physical step, immediately before its replacement, so it never shadows legacy values the store did not adopt.
private struct ConfigurationSourceCheck: Sendable {
    let file: StateRootFile
    let baseline: ConfigurationFileBaseline
}

/// The checks a runtime rewrite runs in its physical step, or the hold that stops it before any read.
private enum ConfigurationPreservationPlan {
    case success([ConfigurationPreservationCheck])
    case failure(ConfigurationPreservationHold)
}

/// What one physical step returned. A held step replaced nothing. A replacement carries its outcome, and the baseline of the verified
/// bytes. The hash of those bytes is computed on `PlatformWork`.
private enum ConfigurationWriteAttempt: Sendable {
    /// A preservation check held the replacement. The component names the sidecar whose check held it.
    case held(ConfigurationPreservationHold, ConfigurationComponent)
    /// The source check of a missing sidecar did not verify, so nothing was replaced.
    case sourceChanged
    case sourceUnreadable(ConfigurationFileError)
    case sourceRefused(ConfigurationFileReplacementRefusal)
    /// The workflow's claim was revoked before the replacement, so no write was made.
    case revoked
    case replaced(ConfigurationFileReplacementOutcome, verifiedBaseline: ConfigurationFileBaseline?)
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
        /// The legacy components whose values the runtime file carries, so a rewrite of it would drop them (the runtime record only). It
        /// is recomputed on each reload, and a verified canonical runtime write clears it.
        var carriedLegacy: Set<ConfigurationComponent> = []
        /// The runtime file baseline a missing sidecar takes its values from, from the same observation even when no legacy key is present,
        /// because the defaults depend on those bytes too. A present sidecar and the runtime record have none. The store's own verified runtime
        /// write moves it, and the sidecar's first verified write clears it.
        var source: ConfigurationFileBaseline?
    }

    private let incarnation = UUID()
    /// The root's writer authority. The store keeps it for its whole life, so the lease stays held while the store or any physical step it
    /// queued still runs. The session's paths are the only files this store writes.
    private let session: StateRootSession
    private let access: any StateFileAccessing
    private let work: PlatformWork
    private var records = ConfigurationSlots(runtime: Record(), platform: Record(), preferences: Record())
    private(set) var values: ConfigurationValues?
    /// Whether one operation holds the store's single slot. It is set before the first suspension and cleared when the call returns.
    private(set) var isBusy = false

    /// Built over the root's session. The bootstrap is the one writer-owned capability, and it pairs a plan with the lease it was resolved
    /// under, so a foreign plan cannot be paired with this lease. Other roots can validly own their own sessions and stores.
    init(session: StateRootSession, access: any StateFileAccessing, work: PlatformWork) {
        self.session = session
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
    /// `allowMissing` is the startup's explicit choice (the loader's own `allowMissing`), so the reload and the open keep the combinations
    /// the loader accepts. The store never chooses it.
    func load(context: ConfigurationOperationContext, allowMissing: Bool) async -> ConfigurationStoreAdmission<ConfigurationLoadReport> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        let currentPlan = session.plan
        let access = self.access
        // The current values go to the worker by copy, so the missing-sidecar comparison runs there.
        let previous = values
        let observed = await work.run {
            ConfigurationStoreIO.observeAndDecode(plan: currentPlan, access: access, allowMissing: allowMissing, previous: previous)
        }
        return .admitted(ConfigurationLoadReport(context: context, outcome: adopt(observed)))
    }

    /// Whether the store's current observation found the component's file. An absent file is uncommitted, and it is not a verified
    /// persistence fact.
    func isPresent(_ component: ConfigurationComponent) -> Bool {
        records[component].present
    }

    /// Commits the runtime and platform files as one coupled operation (decisions 0015 and 0025). Both candidates stage before the
    /// first write, and a staging refusal of either starts no write. The platform file is considered first. A present file whose
    /// verified value already equals the candidate is verified without a save, and the others are saved only when they differ. The runtime
    /// file is saved only once the platform file is verified, so a runtime rewrite cannot drop legacy platform values the platform file
    /// does not yet hold. A rewrite that would drop legacy preference values also waits for the preferences sidecar to verify, in the same
    /// physical step (decision 0026). Each write is conditional on its own baseline (decision 0027). There is no rollback and no retry.
    func commitRuntimeAndPlatform(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        expecting expected: ConfigurationSlots<ConfigurationBaselineToken?>,
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim
    ) async -> ConfigurationStoreAdmission<RuntimePlatformCommitResult> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        // Each component's authority is decided on its own. A refused file keeps its own reason. A file that is authorized is held
        // behind the other one, and it reports that hold, not the other file's reason.
        switch (authority(expected.runtime, for: .runtime), authority(expected.platform, for: .platform)) {
        case (.success(let runtimeBaseline), .success(let platformBaseline)):
            return .admitted(await commitCoupled(
                runtime, platform, runtimeBaseline, platformBaseline, context: context, claim: claim
            ))
        case (.failure(let runtimeReason), .failure(let platformReason)):
            return .admitted(RuntimePlatformCommitResult(
                context: context,
                runtime: .notAttempted(runtimeReason),
                platform: .notAttempted(platformReason)
            ))
        case (.failure(let runtimeReason), .success):
            return .admitted(RuntimePlatformCommitResult(
                context: context,
                runtime: .notAttempted(runtimeReason),
                platform: .notAttempted(.heldBehindRuntime)
            ))
        case (.success, .failure(let platformReason)):
            return .admitted(RuntimePlatformCommitResult(
                context: context,
                runtime: .notAttempted(.heldBehindPlatform),
                platform: .notAttempted(platformReason)
            ))
        }
    }

    /// Commits the preferences file, independently of the runtime and platform commit. It uses the same physical path and slot.
    func commitPreferences(
        _ preferences: AppPreferences,
        expecting expected: ConfigurationBaselineToken?,
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim
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
        let source = session.plan.preferences.path
        let current = values?.preferences
        switch await work.run({ ConfigurationStoreIO.stagePreferences(preferences, current: current, source: source) }) {
        case .refused(let reason):
            return .admitted(PreferencesCommitResult(context: context, preferences: .notAttempted(.stagingRefused(reason))))
        case .ready(let staged):
            let outcome = await commit(
                staged.bytes,
                component: .preferences,
                baseline: baseline,
                sameValue: staged.comparison == .same,
                preservation: [],
                context: context,
                claim: claim
            )
            if outcome.isVerified {
                values?.preferences = staged.value
            }
            return .admitted(PreferencesCommitResult(context: context, preferences: outcome))
        }
    }

    /// Persists DNS's lifecycle intent into the runtime file alone, the Stop exception of decision 0015: a disable must not wait on a
    /// latched, changed or unrelated platform file, and it requests no sidecar creation. The candidate is the store's current runtime value
    /// with only `dnsForwarderEnabled` set, staged, compared and written through the same steps as every runtime write: the conditional
    /// replacement on the runtime baseline (decision 0027) and the preservation checks for legacy sidecar values the runtime file carries
    /// (decision 0026). It returns the runtime fact only, never a verified pair, so it authorizes no apply.
    func commitDNSLifecycle(
        enabled: Bool,
        expecting expected: ConfigurationBaselineToken?,
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim
    ) async -> ConfigurationStoreAdmission<DNSLifecycleCommitResult> {
        guard !isBusy else { return .busy }
        isBusy = true
        defer { isBusy = false }
        let baseline: ConfigurationFileBaseline
        switch authority(expected, for: .runtime) {
        case .success(let value):
            baseline = value
        case .failure(let reason):
            return .admitted(DNSLifecycleCommitResult(context: context, runtime: .notAttempted(reason)))
        }
        guard var edited = values?.runtime else {
            preconditionFailure("a runtime baseline is held only with adopted values")
        }
        edited.dnsForwarderEnabled = enabled
        let candidate = edited
        let current = values?.runtime
        let staged = await work.run { ConfigurationStoreIO.stageRuntime(candidate, current: current) }
        let file: ConfigurationStagedFile<ProxyConfig>
        switch staged {
        case .ready(let value):
            file = value
        case .refused(let reason):
            return .admitted(DNSLifecycleCommitResult(context: context, runtime: .notAttempted(.stagingRefused(reason))))
        }
        let sameRuntime = file.comparison == .same
        var preservation: [ConfigurationPreservationCheck] = []
        if !(sameRuntime && records[.runtime].present) {
            switch runtimePreservation(alreadyVerified: []) {
            case .success(let checks):
                preservation = checks
            case .failure(let hold):
                return .admitted(DNSLifecycleCommitResult(context: context, runtime: .notAttempted(.preservationHeld(hold))))
            }
        }
        let outcome = await commit(
            file.bytes,
            component: .runtime,
            baseline: baseline,
            sameValue: sameRuntime,
            preservation: preservation,
            context: context,
            claim: claim
        )
        if outcome.isVerified {
            values?.runtime = file.value
        }
        return .admitted(DNSLifecycleCommitResult(context: context, runtime: outcome))
    }

    /// The sidecar checks a runtime rewrite needs, so legacy values the runtime file carries are not dropped unseen (decision 0026). A
    /// sidecar this operation already verified needs none. A carried sidecar with no authoritative baseline holds the rewrite before any read.
    private func runtimePreservation(alreadyVerified: Set<ConfigurationComponent>) -> ConfigurationPreservationPlan {
        var checks: [ConfigurationPreservationCheck] = []
        for sidecar in [ConfigurationComponent.platform, .preferences]
        where records[.runtime].carriedLegacy.contains(sidecar) && !alreadyVerified.contains(sidecar) {
            guard let baseline = records[sidecar].baseline else { return .failure(.noAuthoritativeSidecarBaseline) }
            checks.append(ConfigurationPreservationCheck(
                component: sidecar,
                file: session.configurationFile(for: sidecar),
                baseline: baseline,
                present: records[sidecar].present
            ))
        }
        return .success(checks)
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
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim
    ) async -> RuntimePlatformCommitResult {
        let platformSource = session.plan.platformConfig.path
        let current = (runtime: values?.runtime, platform: values?.platform)
        let staged = await work.run {
            ConfigurationStoreIO.stageRuntimeAndPlatform(runtime, platform, current: current, platformSource: platformSource)
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
            sameValue: pair.platform.comparison == .same,
            preservation: [],
            context: context,
            claim: claim
        )
        guard platformOutcome.isVerified else {
            return RuntimePlatformCommitResult(context: context, runtime: .notAttempted(.heldBehindPlatform), platform: platformOutcome)
        }
        values?.platform = pair.platform.value
        // The guard runs only when the runtime file would be rewritten. A verified unchanged runtime file drops nothing, so it stays independent.
        // Decided by canonical bytes on the worker when the pair was staged. The platform commit above changes no runtime value, and it verified
        // the platform file in this operation, so only the preferences sidecar is checked.
        let sameRuntime = pair.runtime.comparison == .same
        let rewritesRuntime = !(sameRuntime && records[.runtime].present)
        var preservation: [ConfigurationPreservationCheck] = []
        if rewritesRuntime {
            switch runtimePreservation(alreadyVerified: [.platform]) {
            case .success(let checks):
                preservation = checks
            case .failure(let hold):
                return RuntimePlatformCommitResult(context: context, runtime: .notAttempted(.preservationHeld(hold)), platform: platformOutcome)
            }
        }
        let runtimeOutcome = await commit(
            pair.runtime.bytes,
            component: .runtime,
            baseline: runtimeBaseline,
            sameValue: sameRuntime,
            preservation: preservation,
            context: context,
            claim: claim
        )
        if runtimeOutcome.isVerified {
            values?.runtime = pair.runtime.value
        }
        var result = RuntimePlatformCommitResult(context: context, runtime: runtimeOutcome, platform: platformOutcome)
        // The exact pair is this commit's staged candidates, and only when both receipts verified. The store's per-file values are not used.
        if let runtimeReceipt = runtimeOutcome.verifiedReceipt, let platformReceipt = platformOutcome.verifiedReceipt {
            result.verifiedInput = VerifiedRuntimePlatformInput(
                runtime: pair.runtime.value,
                platform: pair.platform.value,
                runtimeReceipt: runtimeReceipt,
                platformReceipt: platformReceipt
            )
        }
        return result
    }

    /// Verifies a present component whose verified value already is the candidate, without writing it, and saves every other candidate.
    /// `sameValue` is the worker's canonical comparison of the current value and the candidate, so formatting and unknown fields on disk
    /// never force a rewrite (decision 0018), and a byte-distinct candidate that `==` would call equal is written. The raw bytes are then
    /// verified against the baseline.
    private func commit(
        _ bytes: Data,
        component: ConfigurationComponent,
        baseline: ConfigurationFileBaseline,
        sameValue: Bool,
        preservation: [ConfigurationPreservationCheck],
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim
    ) async -> ConfigurationWriteOutcome {
        if sameValue, records[component].present {
            return await verifyCurrent(component, baseline: baseline, context: context)
        }
        return await write(bytes, component: component, baseline: baseline, preservation: preservation, context: context, claim: claim)
    }

    /// One conditional replacement of one file, and the store's bookkeeping for its result. Every physical step runs on `PlatformWork`.
    /// A preservation check runs first, in the same `PlatformWork` step and immediately before the replacement, so the sidecar is verified
    /// at the moment the runtime bytes are replaced. The check is a read only: it never writes the sidecar. A missing sidecar's first write
    /// checks its runtime source the same way, so a runtime file edited since the store established it is not shadowed. Neither check is a
    /// multi-file atomic claim (decision 0027): a change after the check and before the replacement is not excluded.
    private func write(
        _ bytes: Data,
        component: ConfigurationComponent,
        baseline: ConfigurationFileBaseline,
        preservation: [ConfigurationPreservationCheck],
        context: ConfigurationOperationContext,
        claim: ConfigurationWriteClaim
    ) async -> ConfigurationWriteOutcome {
        // Refused before any I/O: a verified write names a newer version, and the version never wraps.
        guard Self.canAdvance(records[component].version) else { return .notAttempted(.versionExhausted) }
        let session = self.session
        let access = self.access
        let source = sourceCheck(for: component)
        let attempt = await work.run { () -> ConfigurationWriteAttempt in
            if let source {
                switch VerifiedConfigurationFileReplacement.verifyUnchanged(source.file, expecting: source.baseline, access: access) {
                case .unchanged:
                    break
                case .changed:
                    return .sourceChanged
                case .refused(let refusal):
                    return .sourceRefused(refusal)
                case .notVerified(let error):
                    return .sourceUnreadable(error)
                }
            }
            for check in preservation {
                switch VerifiedConfigurationFileReplacement.verifyUnchanged(check.file, expecting: check.baseline, access: access) {
                case .unchanged where check.present:
                    break
                case .unchanged:
                    return .held(.sidecarAbsent, check.component)
                case .changed:
                    return .held(.sidecarChanged, check.component)
                case .refused(let refusal):
                    return .held(.refused(refusal), check.component)
                case .notVerified(let error):
                    return .held(.sidecarUnreadable(error), check.component)
                }
            }
            // Checked after the preservation read and immediately before the replacement (decision 0015). Once the replacement starts,
            // its read-back runs to the end whatever the claim says, so its persistence facts are kept.
            guard claim.isCurrent() else { return .revoked }
            let outcome = session.replaceConfigurationFile(component, staged: bytes, expecting: baseline, access: access)
            // The read-back equals the staged bytes, so the new baseline is the identity of those bytes, hashed off the MainActor.
            if case .verifiedPersisted = outcome {
                return .replaced(outcome, verifiedBaseline: ConfigurationFileBaseline(observing: .present(bytes)))
            }
            return .replaced(outcome, verifiedBaseline: nil)
        }
        switch attempt {
        case .held(let hold, let sidecar):
            // Only a changed sidecar latches. An unreadable or absent one keeps its baseline, so a later check can establish it.
            if case .sidecarChanged = hold {
                latch(sidecar)
            }
            return .notAttempted(.preservationHeld(hold))
        case .sourceChanged:
            // The runtime bytes differ from the ones the store established, so both files latch, as an observed conflict does.
            latch(component)
            latch(.runtime)
            return .notAttempted(.sourceChanged)
        case .sourceUnreadable(let error):
            return .notAttempted(.sourceUnreadable(error))
        case .sourceRefused(let refusal):
            return .notAttempted(.refused(refusal))
        case .revoked:
            // Nothing was written, so no baseline changes and nothing latches. The next admission decides the file's fate.
            return .notAttempted(.superseded)
        case .replaced(let outcome, let verifiedBaseline):
            return settle(outcome, verifiedBaseline: verifiedBaseline, component: component, context: context)
        }
    }

    /// The store's bookkeeping for one replacement's result. A verified canonical write clears the component's legacy presence, because the
    /// file now holds only its canonical values. Every other outcome keeps it.
    private func settle(
        _ outcome: ConfigurationFileReplacementOutcome,
        verifiedBaseline: ConfigurationFileBaseline?,
        component: ConfigurationComponent,
        context: ConfigurationOperationContext
    ) -> ConfigurationWriteOutcome {
        switch outcome {
        case .verifiedPersisted(let reported):
            guard let verified = verifiedBaseline else { preconditionFailure("a persisted write carries its verified baseline") }
            records[component].baseline = verified
            records[component].present = true
            records[component].carriedLegacy = []
            records[component].source = nil
            // A sidecar still missing takes its values from the new runtime bytes. They hold no legacy keys, and a carried legacy value
            // needed its sidecar verified first, so the sidecar's effective value is unchanged and its version stays.
            if component == .runtime {
                for sidecar in [ConfigurationComponent.platform, .preferences] where !records[sidecar].present {
                    records[sidecar].source = verified
                }
            }
            // The version advances here, after the claim and the canAdvance check above. The busy slot keeps every other operation from changing it in between.
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

    /// The source check a write of this component needs: only a missing sidecar has one.
    private func sourceCheck(for component: ConfigurationComponent) -> ConfigurationSourceCheck? {
        guard component != .runtime, !records[component].present else { return nil }
        guard let source = records[component].source else {
            preconditionFailure("an authorized missing sidecar carries the runtime baseline it was observed with")
        }
        return ConfigurationSourceCheck(file: session.configurationFile(for: .runtime), baseline: source)
    }

    private func verification(_ component: ConfigurationComponent, baseline: ConfigurationFileBaseline) async -> ConfigurationFileVerification {
        let file = session.configurationFile(for: component)
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
            // A missing sidecar's value comes from the runtime file, so a change of that value is a change of the sidecar, though its own
            // absence is the same. The worker decided it by canonical bytes. A runtime edit that leaves the value's bytes as they were keeps
            // the sidecar's token.
            func advances(_ component: ConfigurationComponent) -> Bool {
                records[component].baseline != observed.baselines[component] || observed.valueMoved[component]
            }
            for component in ConfigurationComponent.allCases where advances(component) && !Self.canAdvance(records[component].version) {
                latchAll()
                return .refused(.versionExhausted(component))
            }
            let advancing = ConfigurationComponent.allCases.filter(advances)
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
                // The version changes only when the observed identity differs from the baseline in force, or a missing sidecar's value moved,
                // so a reload of unlatched, unchanged bytes keeps its tokens. A latch clears the baseline, so a reload after a latch always takes
                // a newer version.
                if advancing.contains(component) {
                    records[component].version += 1
                }
                records[component].baseline = baseline
                records[component].present = loaded[component].present
                records[component].source = component == .runtime || loaded[component].present ? nil : observed.baselines.runtime
            }
            // Recomputed from this observation only, so a rewrite that dropped the values is seen as absent on the next reload.
            records[.runtime].carriedLegacy = frozen.runtimeCarriesLegacy
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

    /// Whether one more file version exists. Versions never wrap, so a component at the maximum is refused before any change that needs
    /// a newer version. Latching needs none, because a nil baseline already refuses every token.
    private static func canAdvance(_ version: UInt64) -> Bool {
        version < UInt64.max
    }
}
