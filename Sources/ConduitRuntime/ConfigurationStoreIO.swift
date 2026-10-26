// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// A value staged for one file: the exact bytes a write puts down, and the value the store adopts once that write verifies. The value is
/// decoded from those bytes through the shared decode, so the store never normalizes a second way.
struct ConfigurationStagedFile<Value: Sendable>: Sendable {
    let bytes: Data
    let value: Value
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
}

/// The physical steps of the configuration store. Each is a function of its inputs that the store runs on `PlatformWork`, so no
/// read, parse, stage, hash or write runs on the MainActor. Every read goes through the one bounded reader, and every decode through
/// the kernel's shared functions.
enum ConfigurationStoreIO {
    /// Reads the three files once, checks the journal's presence through the access seam, and decodes the observation with the frozen
    /// loader. Nothing is written. Each file's baseline comes from the bytes that were decoded.
    static func observeAndDecode(plan: StateRootPlan, access: any StateFileAccessing, allowMissing: Bool) -> ConfigurationLoadObservation {
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
            do {
                let frozen = try ConfigurationFrozenLoader.decode(observation, allowMissing: allowMissing)
                return ConfigurationLoadObservation(outcome: .success(frozen), baselines: baselines)
            } catch {
                return ConfigurationLoadObservation(outcome: .failure(loadRefusal(for: error)), baselines: baselines)
            }
        }
    }

    /// Stages the runtime and platform candidates together. A refusal of either stops the whole stage before any write.
    static func stageRuntimeAndPlatform(
        _ runtime: ProxyConfig,
        _ platform: PlatformIntegrationConfig,
        platformSource: String
    ) -> ConfigurationStaged<ConfigurationStagedRuntimeAndPlatform> {
        switch (stageRuntime(runtime), stagePlatform(platform, source: platformSource)) {
        case (.ready(let runtimeFile), .ready(let platformFile)):
            return .ready(ConfigurationStagedRuntimeAndPlatform(runtime: runtimeFile, platform: platformFile))
        case (.refused(let reason), _), (_, .refused(let reason)):
            return .refused(reason)
        }
    }

    static func stagePreferences(_ preferences: AppPreferences, source: String) -> ConfigurationStaged<ConfigurationStagedFile<AppPreferences>> {
        do {
            let bytes = try AppPreferencesPersistence.stagedData(for: preferences)
            return .ready(ConfigurationStagedFile(bytes: bytes, value: try AppPreferencesPersistence.decode(bytes, source: source)))
        } catch {
            return .refused(stagingRefusal(for: error))
        }
    }

    /// The runtime candidate. The kernel's exact round-trip already decoded the bytes, so the value is taken from it and never decoded again.
    private static func stageRuntime(_ config: ProxyConfig) -> ConfigurationStaged<ConfigurationStagedFile<ProxyConfig>> {
        do {
            let staged = try ProxyConfigPersistence.stagedFile(for: config)
            return .ready(ConfigurationStagedFile(bytes: staged.bytes, value: staged.value))
        } catch {
            return .refused(stagingRefusal(for: error))
        }
    }

    private static func stagePlatform(
        _ config: PlatformIntegrationConfig,
        source: String
    ) -> ConfigurationStaged<ConfigurationStagedFile<PlatformIntegrationConfig>> {
        do {
            let bytes = try PlatformConfigPersistence.stagedData(for: config)
            return .ready(ConfigurationStagedFile(bytes: bytes, value: try PlatformConfigPersistence.decode(bytes, source: source)))
        } catch {
            return .refused(stagingRefusal(for: error))
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
