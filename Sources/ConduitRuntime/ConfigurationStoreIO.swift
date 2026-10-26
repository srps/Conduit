// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// A value staged for one file: the exact bytes a write puts down, and the value the store adopts once that write verifies. The value is
/// decoded from those bytes through the shared decode, so the store never normalizes a second way. `comparison` says whether the candidate
/// is the store's current value, decided in the same physical step.
struct ConfigurationStagedFile<Value: Sendable>: Sendable {
    let bytes: Data
    let value: Value
    let comparison: ConfigurationCanonicalComparison
}

/// Whether a candidate is the store's current value. It is decided on the store's worker by the canonical bytes the shared stager gives
/// each value, never by `==`: synthesized `String ==` calls canonically equivalent but byte-distinct text equal, and a save must keep the
/// exact bytes it was asked for (decisions 0015 and 0023). It compares values, not the file's raw bytes, so formatting and unknown fields
/// on disk never force a rewrite. Nothing is retained: each operation encodes the current value again. That extra encode, and its temporary
/// bytes, are part of the actual-adapter measurement.
enum ConfigurationCanonicalComparison: Equatable, Sendable {
    /// The canonical bytes are equal, so the decoded values are equal.
    case same
    case different
    /// The current value has no canonical encoding, for a known staging refusal. A load may adopt such a value so that it can be repaired, so
    /// it is not a valid candidate's value, and the candidate is written.
    case currentNotRepresentable(ConfigurationStagingRefusal)
}

/// A staging result. A refusal carries the closed reason the staging step reported, and no value.
enum ConfigurationStaged<Value: Sendable>: Sendable {
    case ready(Value)
    case refused(ConfigurationStagingRefusal)
}

/// Both coupled candidates. They are staged together, before any write.
struct ConfigurationStagedRuntimeAndPlatform: Sendable {
    let runtime: ConfigurationStagedFile<ProxyConfig>
    let platform: ConfigurationStagedFile<PlatformIntegrationConfig>
}

/// One load observation: the shared decode of the observed bytes, or the refusal, and the baseline each file's observed bytes give.
/// A baseline is nil when its read failed.
struct ConfigurationLoadObservation: Sendable {
    let outcome: Result<ConfigurationFrozenLoad, ConfigurationLoadRefusal>
    let baselines: ConfigurationSlots<ConfigurationFileBaseline?>
    /// For each sidecar the observation found missing, whether its decoded value differs from the store's previous value by canonical bytes.
    /// It is false for the runtime file and for a present sidecar, whose own baseline decides. Computed on the worker, so the MainActor makes
    /// no O(size) comparison.
    var valueMoved = ConfigurationSlots(runtime: false, platform: false, preferences: false)
}

/// The physical steps of the configuration store. Each is a function of its inputs that the store runs on `PlatformWork`, so no
/// read, parse, stage, hash or write runs on the MainActor. Every read goes through the one bounded reader, and every decode through
/// the kernel's shared functions.
enum ConfigurationStoreIO {
    /// Reads the three files once, checks the journal's presence through the access seam, and decodes the observation with the frozen
    /// loader. Nothing is written. Each file's baseline comes from the bytes that were decoded. `previous` is the store's current values, so a
    /// missing sidecar's value change is found here by canonical bytes.
    static func observeAndDecode(
        plan: StateRootPlan,
        access: any StateFileAccessing,
        allowMissing: Bool,
        previous: ConfigurationValues?
    ) -> ConfigurationLoadObservation {
        let runtime = ConfigurationFileObservation(source: plan.config.path, read: observe(plan.config, access: access))
        let platform = ConfigurationFileObservation(source: plan.platformConfig.path, read: observe(plan.platformConfig, access: access))
        let preferences = ConfigurationFileObservation(source: plan.preferences.path, read: observe(plan.preferences, access: access))
        let baselines = ConfigurationSlots<ConfigurationFileBaseline?>(
            runtime: ConfigurationFileBaseline(observing: runtime.read),
            platform: ConfigurationFileBaseline(observing: platform.read),
            preferences: ConfigurationFileBaseline(observing: preferences.read)
        )
        // An unreadable file refuses before any decode, in the fixed component order.
        if let refusal = unreadable(runtime, .runtime) ?? unreadable(platform, .platform) ?? unreadable(preferences, .preferences) {
            return ConfigurationLoadObservation(outcome: .failure(refusal), baselines: baselines)
        }
        // The journal's presence decides whether a missing runtime file may be defaults. An unknown presence holds the load.
        switch access.entryPresence(plan.journal) {
        case .failure(let error):
            return ConfigurationLoadObservation(outcome: .failure(.journalPresenceUnknown(error)), baselines: baselines)
        case .success(let journalPresent):
            let observation = ConfigurationFrozenObservation(
                runtime: runtime,
                platform: platform,
                preferences: preferences,
                journalPresent: journalPresent
            )
            let frozen: ConfigurationFrozenLoad
            do {
                frozen = try ConfigurationFrozenLoader.decode(observation, allowMissing: allowMissing)
            } catch {
                return ConfigurationLoadObservation(outcome: .failure(loadRefusal(for: error)), baselines: baselines)
            }
            let platformMoved = missingSidecarMoved(
                present: frozen.platformSidecarPresent, loaded: frozen.platform.config, previous: previous?.platform,
                stage: PlatformConfigPersistence.stagedData(for:)
            )
            let preferencesMoved = missingSidecarMoved(
                present: frozen.preferencesSidecarPresent, loaded: frozen.preferences.preferences, previous: previous?.preferences,
                stage: AppPreferencesPersistence.stagedData(for:)
            )
            switch (platformMoved, preferencesMoved) {
            case (.success(let platform), .success(let preferences)):
                var observed = ConfigurationLoadObservation(outcome: .success(frozen), baselines: baselines)
                observed.valueMoved = ConfigurationSlots(runtime: false, platform: platform, preferences: preferences)
                return observed
            case (.failure(let code), _), (_, .failure(let code)):
                // A failure no known refusal describes is not a classification, so the load is refused with its code, never adopted.
                return ConfigurationLoadObservation(outcome: .failure(.unexpected(code: code.code)), baselines: baselines)
            }
        }
    }

    /// Whether a missing sidecar's loaded value differs from the previous one. A loaded value that a known staging refusal keeps from being
    /// encoded is counted as moved, so the load still adopts it for repair and every older token is retired. An unexpected failure keeps
    /// only its code.
    private static func missingSidecarMoved<Value>(
        present: Bool,
        loaded: Value,
        previous: Value?,
        stage: (Value) throws -> Data
    ) -> Result<Bool, UnexpectedStagingCode> {
        guard !present else { return .success(false) }
        // A first load has nothing to compare, and its own baseline already changes, so no value is encoded.
        guard let previous else { return .success(true) }
        let loadedBytes: Data
        switch canonicalBytes(loaded, stage: stage) {
        case .bytes(let bytes):
            loadedBytes = bytes
        case .refused(.unexpected(let code)):
            return .failure(UnexpectedStagingCode(code: code))
        case .refused:
            return .success(true)
        }
        switch compare(current: previous, candidate: loadedBytes, stage: stage) {
        case .success(let comparison): return .success(comparison != .same)
        case .failure(let code): return .failure(code)
        }
    }

    /// A staging failure that no known refusal describes. Only its code is kept.
    struct UnexpectedStagingCode: Error, Equatable {
        let code: Int
    }

    /// One value's canonical bytes through its shared stager, or the closed reason the stager refused them.
    private enum CanonicalBytes {
        case bytes(Data)
        case refused(ConfigurationStagingRefusal)
    }

    private static func canonicalBytes<Value>(_ value: Value, stage: (Value) throws -> Data) -> CanonicalBytes {
        do {
            return .bytes(try stage(value))
        } catch {
            return .refused(stagingRefusal(for: error))
        }
    }

    /// Compares a candidate's staged bytes with the canonical bytes of the store's current value. No current value is a difference. A known
    /// refusal of the current value is its own case, and an unexpected one is returned as a failure, never as a classification.
    private static func compare<Value>(
        current: Value?,
        candidate: Data,
        stage: (Value) throws -> Data
    ) -> Result<ConfigurationCanonicalComparison, UnexpectedStagingCode> {
        guard let current else { return .success(.different) }
        switch canonicalBytes(current, stage: stage) {
        case .bytes(let bytes):
            return .success(bytes == candidate ? .same : .different)
        case .refused(.unexpected(let code)):
            return .failure(UnexpectedStagingCode(code: code))
        case .refused(let refusal):
            return .success(.currentNotRepresentable(refusal))
        }
    }

    /// Stages the runtime and platform candidates together, each compared with the store's current value. A refusal of either stops the
    /// whole stage before any write. A comparison that fails in a way no known refusal describes is a staging refusal with its code.
    static func stageRuntimeAndPlatform(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        current: (runtime: ProxyConfig?, platform: PlatformIntegrationConfig?),
        platformSource: String
    ) -> ConfigurationStaged<ConfigurationStagedRuntimeAndPlatform> {
        switch (stageRuntime(runtime, current: current.runtime), stagePlatform(platform, current: current.platform, source: platformSource)) {
        case (.ready(let runtimeFile), .ready(let platformFile)):
            return .ready(ConfigurationStagedRuntimeAndPlatform(runtime: runtimeFile, platform: platformFile))
        case (.refused(let reason), _), (_, .refused(let reason)):
            return .refused(reason)
        }
    }

    static func stagePreferences(
        _ preferences: AppPreferences,
        current: AppPreferences?,
        source: String
    ) -> ConfigurationStaged<ConfigurationStagedFile<AppPreferences>> {
        let bytes: Data
        let value: AppPreferences
        do {
            bytes = try AppPreferencesPersistence.stagedData(for: preferences)
            value = try AppPreferencesPersistence.decode(bytes, source: source)
        } catch {
            return .refused(stagingRefusal(for: error))
        }
        return staged(bytes, value, current: current, stage: AppPreferencesPersistence.stagedData(for:))
    }

    /// The runtime candidate. The kernel's exact round-trip already decoded the bytes, so the value is taken from it and never decoded again.
    /// The coupled stage and the DNS lifecycle commit both use it.
    static func stageRuntime(_ config: ProxyConfig, current: ProxyConfig?) -> ConfigurationStaged<ConfigurationStagedFile<ProxyConfig>> {
        let file: ProxyConfigPersistence.StagedFile
        do {
            file = try ProxyConfigPersistence.stagedFile(for: config)
        } catch {
            return .refused(stagingRefusal(for: error))
        }
        return staged(file.bytes, file.value, current: current) { try ProxyConfigPersistence.stagedFile(for: $0).bytes }
    }

    private static func stagePlatform(
        _ config: PlatformIntegrationConfig,
        current: PlatformIntegrationConfig?,
        source: String
    ) -> ConfigurationStaged<ConfigurationStagedFile<PlatformIntegrationConfig>> {
        let bytes: Data
        let value: PlatformIntegrationConfig
        do {
            bytes = try PlatformConfigPersistence.stagedData(for: config)
            value = try PlatformConfigPersistence.decode(bytes, source: source)
        } catch {
            return .refused(stagingRefusal(for: error))
        }
        return staged(bytes, value, current: current, stage: PlatformConfigPersistence.stagedData(for:))
    }

    /// A staged candidate with its comparison against the current value, through the same stager.
    private static func staged<Value: Sendable>(
        _ bytes: Data,
        _ value: Value,
        current: Value?,
        stage: (Value) throws -> Data
    ) -> ConfigurationStaged<ConfigurationStagedFile<Value>> {
        switch compare(current: current, candidate: bytes, stage: stage) {
        case .success(let comparison):
            return .ready(ConfigurationStagedFile(bytes: bytes, value: value, comparison: comparison))
        case .failure(let unexpected):
            return .refused(.unexpected(code: unexpected.code))
        }
    }

    /// The closed reason of a staging failure. Known kernel refusals map to their own case. Any other failure keeps only its code, so no
    /// description or value can reach a result.
    static func stagingRefusal(for error: any Error) -> ConfigurationStagingRefusal {
        if error is ConfigurationResourceRefusal { return .resourceLimit }
        if error is ConfigurationFileSizeRefusal { return .fileSize }
        if let refusal = error as? ConfigurationSidecarSaveRefusal {
            switch refusal.cause {
            case .resourceLimit: return .sidecarResourceLimit
            case .fileSize: return .sidecarFileSize
            }
        }
        if let refusal = error as? ConfigFileRepresentabilityError {
            return .representability(field: ConfigurationFieldLabel(refusal.field), requirement: refusal.requirement)
        }
        return .unexpected(code: (error as NSError).code)
    }

    /// The closed reason of a decode failure. The loader's refusal keeps its fixed text when that text is short printable ASCII, and it names
    /// no value. Any other failure, or a loader reason outside that bound, keeps only its code.
    static func loadRefusal(for error: any Error) -> ConfigurationLoadRefusal {
        if let loadError = error as? ConfigurationLoadError, let reason = ConfigurationLoadReason(loadError.reason) {
            return .invalidContent(reason: reason)
        }
        return .unexpected(code: (error as NSError).code)
    }

    /// One file's bytes through the shared bounded observation. A foreign role is not possible here: the store admits only its four
    /// configuration roles, so a refusal from the seam is a bug and is not hidden.
    private static func observe(_ file: StateRootFile, access: any StateFileAccessing) -> Result<ConfigurationFileInput, ConfigurationFileError> {
        switch VerifiedConfigurationFileReplacement.observe(file, access: access) {
        case .observed(let input):
            return .success(input)
        case .notObserved(let error):
            return .failure(error)
        case .refused:
            preconditionFailure("the store admits only writer-owned configuration roles")
        }
    }

    private static func unreadable(_ observed: ConfigurationFileObservation, _ component: ConfigurationComponent) -> ConfigurationLoadRefusal? {
        if case .failure(let error) = observed.read {
            return .unreadable(component, error)
        }
        return nil
    }
}
