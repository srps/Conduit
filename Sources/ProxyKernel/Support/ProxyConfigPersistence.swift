// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// Writes bytes that already exist. A caller encodes first, so a value that
/// cannot be encoded leaves the directory and any existing file untouched. Every physical configuration write goes through
/// here, the runtime file and both sidecars alike.
private func writeData(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

/// The bytes of one configuration file, or its absence. A missing file is an outcome, so the caller decides what it means.
package enum ConfigurationFileInput: Sendable, Equatable {
    case missing
    case present(Data)
}

/// Reads one configuration file through the bounded reader under `root`'s budget (decisions 0021 and 0026). Only a missing file
/// is an outcome, and every other read failure is returned as its typed error. Nothing is decoded or written here.
package func observeConfigurationFile(at url: URL, root: ConfigurationFileRoot) -> Result<ConfigurationFileInput, ConfigurationFileError> {
    do throws(ConfigurationFileError) {
        return .success(.present(try ConfigurationFileReader.read(at: url, limit: root.maximumBytes)))
    } catch {
        if case .missing = error {
            return .success(.missing)
        }
        return .failure(error)
    }
}

/// The refusal a failed read carries. Every failure keeps its step, its errno and a close failure that followed it (`summary`).
/// Only fixed words are reported, with the source path the loader already names.
private func unreadableConfigurationError(_ error: ConfigurationFileError, source: String) -> ConfigurationLoadError {
    ConfigurationLoadError(source: source, reason: "The configuration file could not be read: \(error.summary).")
}

/// Decodes one sidecar's observed bytes (decision 0026). The strict filter and one typed decode follow, so a refusal happens
/// before the typed value exists. A missing sidecar is nil. Nothing is read or written here.
private func decodeSidecar<Value: Decodable>(
    _ type: Value.Type,
    root: ConfigurationFileRoot,
    observed: ConfigurationFileObservation
) throws -> Value? {
    switch observed.read {
    case .failure(let error):
        throw unreadableConfigurationError(error, source: observed.source)
    case .success(.missing):
        return nil
    case .success(.present(let data)):
        return try decodePresentSidecar(type, root: root, data: data, source: observed.source)
    }
}

/// The strict filter and one typed decode of a sidecar's bytes. Both the observed path and the store's post-write path use it.
private func decodePresentSidecar<Value: Decodable>(_ type: Value.Type, root: ConfigurationFileRoot, data: Data, source: String) throws -> Value {
    let filtered = try ConfigurationFileGate.filter(data, root: root, source: source)
    do {
        return try CanonicalJSON.decoder().decode(type, from: filtered.bytes)
    } catch {
        throw ConfigurationLoadError(source: source, reason: "The configuration is not valid Conduit JSON.")
    }
}

/// Reads and gates one sidecar from its file (decision 0026). A missing sidecar is nil. Nothing is written here.
private func loadSidecar<Value: Decodable>(_ type: Value.Type, root: ConfigurationFileRoot, from url: URL) throws -> Value? {
    try decodeSidecar(type, root: root, observed: ConfigurationFileObservation(source: url.path, read: observeConfigurationFile(at: url, root: root)))
}

/// One configuration file as one read observed it: the path the loader names in its errors, and the typed read result.
package struct ConfigurationFileObservation: Sendable {
    package let source: String
    package let read: Result<ConfigurationFileInput, ConfigurationFileError>

    package init(source: String, read: Result<ConfigurationFileInput, ConfigurationFileError>) {
        self.source = source
        self.read = read
    }
}

/// The three configuration files, and whether the journal exists, as one observation (decisions 0021, 0023 and 0026). The store
/// and the legacy loader decode the same value through `ConfigurationFrozenLoader`, so neither has a second parser.
package struct ConfigurationFrozenObservation: Sendable {
    package let runtime: ConfigurationFileObservation
    package let platform: ConfigurationFileObservation
    package let preferences: ConfigurationFileObservation
    /// Whether the journal exists. It decides only whether a missing runtime file may be defaults, as it always did.
    package let journalPresent: Bool

    package init(
        runtime: ConfigurationFileObservation,
        platform: ConfigurationFileObservation,
        preferences: ConfigurationFileObservation,
        journalPresent: Bool
    ) {
        self.runtime = runtime
        self.platform = platform
        self.preferences = preferences
        self.journalPresent = journalPresent
    }

    /// Observes the three files of a runtime environment, each under its own budget, and the journal's presence. Each file is
    /// read once.
    package static func observe(in environment: RuntimeEnvironment) -> ConfigurationFrozenObservation {
        ConfigurationFrozenObservation(
            runtime: ConfigurationFileObservation(
                source: environment.configFile.path,
                read: observeConfigurationFile(at: environment.configFile, root: ConfigurationFileSchema.runtime(.runtimeOnly))
            ),
            platform: ConfigurationFileObservation(
                source: environment.platformConfigFile.path,
                read: observeConfigurationFile(at: environment.platformConfigFile, root: ConfigurationFileSchema.platformSidecar)
            ),
            preferences: ConfigurationFileObservation(
                source: environment.preferencesFile.path,
                read: observeConfigurationFile(at: environment.preferencesFile, root: ConfigurationFileSchema.preferencesSidecar)
            ),
            journalPresent: FileManager.default.fileExists(atPath: environment.platformStateFile.path)
        )
    }
}

/// The components one frozen observation decodes to. Nothing here is written: staging and writing belong to the caller.
package struct ConfigurationFrozenLoad: Sendable {
    package let runtime: ProxyConfigMigrationResult
    package let platform: PlatformConfigMigrationResult
    package let preferences: AppPreferencesMigrationResult
    package let runtimeFilePresent: Bool
    package let platformSidecarPresent: Bool
    package let preferencesSidecarPresent: Bool
}

/// The one pure load and decode over a frozen observation (decisions 0021, 0023 and 0026). It is the only place that decodes the
/// runtime file and the sidecars at startup: the legacy loader and the verified store both call it. The order of checks, the
/// refusals and the legacy fallbacks are the ones the loader always had. Nothing is read, staged or written here.
package enum ConfigurationFrozenLoader {
    package static func decode(_ observation: ConfigurationFrozenObservation, allowMissing: Bool) throws -> ConfigurationFrozenLoad {
        let platformSidecar = try decodeSidecar(PlatformIntegrationConfig.self, root: ConfigurationFileSchema.platformSidecar,
                                                observed: observation.platform)
        let preferencesSidecar = try decodeSidecar(AppPreferences.self, root: ConfigurationFileSchema.preferencesSidecar,
                                                   observed: observation.preferences)
        let requirements = RuntimeFileRequirements(platform: platformSidecar == nil, preferences: preferencesSidecar == nil)
        let hasState = platformSidecar != nil || preferencesSidecar != nil || observation.journalPresent
        let loaded = try loadRuntimeFile(observed: observation.runtime, requirements: requirements, allowMissing: allowMissing && !hasState)
        let runtimeFilePresent: Bool
        if case .success(.present) = observation.runtime.read { runtimeFilePresent = true } else { runtimeFilePresent = false }
        return ConfigurationFrozenLoad(
            runtime: loaded.result,
            platform: PlatformConfigPersistence.resolve(sidecar: platformSidecar, legacy: loaded.platform),
            preferences: AppPreferencesPersistence.resolve(sidecar: preferencesSidecar, legacy: loaded.preferences),
            runtimeFilePresent: runtimeFilePresent,
            platformSidecarPresent: platformSidecar != nil,
            preferencesSidecarPresent: preferencesSidecar != nil
        )
    }
}

/// The warning for a migration file that could not be staged or written. It names the file and the error, and nothing else.
private func migrationWarning(_ label: String, _ url: URL, _ error: Error) -> String {
    "\(label) migrated in memory but could not be written to \(url.path): \(error.localizedDescription)"
}

/// The exact bytes a sidecar save writes (decision 0026): canonical pretty JSON, checked against the approved sidecar budget
/// before any byte is written. Only the typed `stagedData` functions of the two sidecars call this, so the budget is never a
/// caller's choice. The value's own checks run before it, in the typed function.
private func stagedSidecarData<Value: Encodable>(_ value: Value, file: ConfigurationSidecarFile) throws -> Data {
    let data = try CanonicalJSON.encoder(prettyPrinted: true).encode(value)
    let limit = DomainResourceLimits.sidecarFileBytes
    guard data.count <= limit else {
        throw ConfigurationSidecarSaveRefusal(file: file, cause: .fileSize(encodedBytes: data.count, limit: limit))
    }
    return data
}

/// The in-memory migration of one document. The schema transforms run from the version the file says it was written at,
/// so a file that omits its version migrates as version 0, the way it always did.
private func migratedConfig(_ document: RuntimeFileDocument) -> (config: ProxyConfig, migrated: Bool) {
    guard document.originalSchemaVersion < ProxyConfig.currentSchemaVersion else {
        return (document.config, false)
    }
    var migrated = ProxyConfigPersistence.migrate(document.config, from: document.originalSchemaVersion)
    migrated.schemaVersion = ProxyConfig.currentSchemaVersion
    return (migrated, true)
}

/// One frozen read of the runtime file, in memory: its migrated config and the legacy components the same read carried.
private struct RuntimeFileLoad {
    let result: ProxyConfigMigrationResult
    let platform: LegacyComponent<PlatformIntegrationConfig>
    let preferences: LegacyComponent<AppPreferences>
}

/// Decodes the runtime file's observed bytes once. A missing file is defaults when `allowMissing` is set, and a refusal otherwise.
/// Nothing is written here.
private func loadRuntimeFile(
    observed: ConfigurationFileObservation,
    requirements: RuntimeFileRequirements,
    allowMissing: Bool
) throws -> RuntimeFileLoad {
    switch observed.read {
    case .failure(let error):
        throw unreadableConfigurationError(error, source: observed.source)
    case .success(.missing):
        guard allowMissing else {
            throw ConfigurationLoadError(source: observed.source, reason: "The configuration file could not be read: \(ConfigurationFileError.missing.summary).")
        }
        return RuntimeFileLoad(
            result: ProxyConfigMigrationResult(config: GenericDefaults.shared.makeConfig(), migrated: false, warnings: []),
            platform: .notRequired,
            preferences: .notRequired
        )
    case .success(.present(let data)):
        let document = try RuntimeFileDocument.decode(data, requirements: requirements, source: observed.source)
        let (config, migrated) = migratedConfig(document)
        return RuntimeFileLoad(
            result: ProxyConfigMigrationResult(config: config, migrated: migrated, warnings: []),
            platform: document.platform,
            preferences: document.preferences
        )
    }
}

/// The runtime file read from `url` under the runtime budget, decoded for `requirements`. Used by the single-file entry points.
private func loadRuntimeFile(at url: URL, requirements: RuntimeFileRequirements, allowMissing: Bool) throws -> RuntimeFileLoad {
    try loadRuntimeFile(
        observed: ConfigurationFileObservation(source: url.path, read: observeConfigurationFile(at: url, root: ConfigurationFileSchema.runtime(requirements))),
        requirements: requirements,
        allowMissing: allowMissing
    )
}

package struct ProxyConfigMigrationResult: Sendable {
    package let config: ProxyConfig
    package let migrated: Bool
    package let warnings: [String]
}

package struct RuntimeConfigurationLoadResult {
    package let config: ProxyConfig
    package let platformConfig: PlatformIntegrationConfig
    package let appPreferences: AppPreferences
    package let migrated: Bool
    package let warnings: [String]

    package init(config: ProxyConfig, platformConfig: PlatformIntegrationConfig, appPreferences: AppPreferences, migrated: Bool, warnings: [String]) {
        self.config = config
        self.platformConfig = platformConfig
        self.appPreferences = appPreferences
        self.migrated = migrated
        self.warnings = warnings
    }
}

// MARK: - Runtime Config Persistence

package enum ProxyConfigPersistence {
    /// Loads a config and brings it up to the current schema **in memory**,
    /// without rewriting the file.
    ///
    /// Migration is not optional for a reader. A transform exists because the
    /// old persisted value no longer means what the current code needs it to
    /// mean, so a caller that skips it runs against a config the code has
    /// already disowned — the v2 DoH rewrite, for instance, would leave the
    /// headless CLIs holding provider hostnames that cannot be reached on the
    /// networks the transform exists for. The only thing that distinguishes
    /// this from `loadMigrating` is whether the result is written back, which
    /// is what keeps `pm-proxy` side-effect-free.
    package static func load(from url: URL, allowMissing: Bool = true) throws -> ProxyConfig {
        try loadMigrating(from: url, saveMigrated: false, allowMissing: allowMissing).config
    }

    package static func load(in environment: RuntimeEnvironment, allowMissing: Bool = true) throws -> ProxyConfig {
        // Runtime-only hosts do not create configuration sidecars. Their
        // snapshots/events still distinguish a reused state directory from a
        // genuine first run. --minimal is the explicit file-free runtime mode.
        let runtimeArtifacts = [environment.snapshotFile, environment.eventsFile,
                                environment.configDirectory.appendingPathComponent("ready.json")]
        let hasPriorState = hasConfigurationState(in: environment)
            || runtimeArtifacts.contains { FileManager.default.fileExists(atPath: $0.path) }
        return try load(from: environment.configFile, allowMissing: allowMissing && !hasPriorState)
    }

    private static func hasConfigurationState(in environment: RuntimeEnvironment) -> Bool {
        [environment.platformConfigFile, environment.preferencesFile, environment.platformStateFile]
            .contains { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// Loads every configuration component from one pass. Each sidecar is read once, and the runtime file is read once. A
    /// legacy component is taken from the runtime read only where its sidecar was absent, so the sidecar read decides what
    /// the runtime read keeps. Every migration write is staged before the first write, and the writes keep their order.
    package static func loadAllMigrating(
        in environment: RuntimeEnvironment,
        allowMissing: Bool = true,
        validateRuntime: (ProxyConfig) throws -> Void = { _ in }
    ) throws -> RuntimeConfigurationLoadResult {
        // Each file is read once, then decoded by the one frozen loader. A valid runtime file must not hide a broken sidecar,
        // so every candidate is resolved before migration can write any file.
        let frozen = try ConfigurationFrozenLoader.decode(ConfigurationFrozenObservation.observe(in: environment), allowMissing: allowMissing)
        let runtime = frozen.runtime
        let platform = frozen.platform
        let preferences = frozen.preferences
        try validateRuntime(runtime.config)
        var warnings = platform.warnings + preferences.warnings + runtime.warnings
        // Stage every migration write before the first physical write (decision 0026). One candidate that cannot be staged stops
        // every migration write, so no sidecar or runtime rewrite is made from a partial set. That failure is kept apart from the
        // legacy warnings, and the in-memory result and the original files stay as they are.
        var stagingFailures: [String] = []
        var platformBytes: Data?
        var preferencesBytes: Data?
        var runtimeBytes: Data?
        if platform.migrated {
            do {
                platformBytes = try PlatformConfigPersistence.stagedData(for: platform.config)
            } catch {
                stagingFailures.append(migrationWarning("Platform config", environment.platformConfigFile, error))
            }
        }
        if preferences.migrated {
            do {
                preferencesBytes = try AppPreferencesPersistence.stagedData(for: preferences.preferences)
            } catch {
                stagingFailures.append(migrationWarning("App preferences", environment.preferencesFile, error))
            }
        }
        if runtime.migrated {
            do {
                runtimeBytes = try stagedFileData(for: runtime.config)
            } catch {
                stagingFailures.append(migrationWarning("Config schema", environment.configFile, error))
            }
        }
        warnings += stagingFailures
        // After every stage has succeeded, a physical failure is reported and not rolled back: each write is attempted on its own.
        if stagingFailures.isEmpty {
            if let platformBytes {
                do {
                    try writeData(platformBytes, to: environment.platformConfigFile)
                } catch {
                    warnings.append(migrationWarning("Platform config", environment.platformConfigFile, error))
                }
            }
            if let preferencesBytes {
                do {
                    try writeData(preferencesBytes, to: environment.preferencesFile)
                } catch {
                    warnings.append(migrationWarning("App preferences", environment.preferencesFile, error))
                }
            }
            // The runtime rewrite waits until every other migration write has succeeded, as it always did.
            if let runtimeBytes, warnings.isEmpty {
                do {
                    try writeStagedConfigurationFile(runtimeBytes, to: environment.configFile)
                } catch {
                    warnings.append(migrationWarning("Config schema", environment.configFile, error))
                }
            }
        }
        return RuntimeConfigurationLoadResult(
            config: runtime.config,
            platformConfig: platform.config,
            appPreferences: preferences.preferences,
            migrated: runtime.migrated || platform.migrated || preferences.migrated,
            warnings: warnings
        )
    }

    /// Loads the runtime file only: no legacy component is read or extracted. A migrated result is written back when
    /// `saveMigrated` is set, and the write's failure is reported as a warning.
    package static func loadMigrating(from url: URL, saveMigrated: Bool = true, allowMissing: Bool = true) throws -> ProxyConfigMigrationResult {
        let result = try loadRuntimeFile(at: url, requirements: .runtimeOnly, allowMissing: allowMissing).result
        guard result.migrated, saveMigrated else {
            return result
        }
        do {
            try save(result.config, to: url)
            return result
        } catch {
            return ProxyConfigMigrationResult(
                config: result.config,
                migrated: true,
                warnings: [migrationWarning("Config schema", url, error)]
            )
        }
    }

    /// Decodes bytes that came from argv or a caller, through the same gate as a file: the physical cap, the strict filter,
    /// one typed decode, the newer-schema refusal and the in-memory migration. Nothing is written.
    package static func decode(_ data: Data, source: String) throws -> ProxyConfig {
        let document = try RuntimeFileDocument.decode(data, requirements: .runtimeOnly, source: source)
        return migratedConfig(document).config
    }

    /// Loads an import source. It reads the file under the same budget as a startup load, and it refuses a missing file.
    package static func loadImport(from url: URL) throws -> ProxyConfig {
        try loadRuntimeFile(at: url, requirements: .runtimeOnly, allowMissing: false).result.config
    }

    /// Applies every schema transform between `previousVersion` and
    /// `ProxyConfig.currentSchemaVersion`. Each step is guarded by the version
    /// that introduced it, so a config two versions behind picks up both.
    ///
    /// Transforms rewrite *stale defaults*, never user choices — the test for
    /// "did the user touch this?" is whether the persisted value still equals
    /// the default it shipped with.
    package static func migrate(_ config: ProxyConfig, from previousVersion: Int) -> ProxyConfig {
        var migrated = config

        // v2: DoH providers moved from hostnames to IP literals. A forwarder
        // cannot resolve `cloudflare-dns.com` on exactly the networks where it
        // needs DoH, and filtered networks block the provider hostnames while
        // passing their IPs. See `DNSSection.defaultDoHProviders`.
        if previousVersion < 2, migrated.dohProviders == DNSSection.legacyHostnameDoHProviders {
            migrated.dohProviders = DNSSection.defaultDoHProviders
        }

        return migrated
    }

    /// Saves `config` only after its bytes are staged and checked. A refusal throws before any directory or file is created or replaced.
    package static func save(_ config: ProxyConfig, to url: URL) throws {
        try writeStagedConfigurationFile(stagedFileData(for: config), to: url)
    }

    /// Replaces a configuration file (the runtime file or a sidecar) with bytes a caller already staged and checked, through the
    /// same atomic write a save uses. The verified replacement in PlatformMac calls this, so there is one physical write path. It
    /// does not check the bytes: the caller owns that, and the caller must hold the root's writer lease (decision 0017).
    package static func writeStagedConfigurationFile(_ data: Data, to url: URL) throws {
        try writeData(data, to: url)
    }

    /// The exact bytes a save writes, checked in memory (decision 0023). The
    /// config must be representable in the schema-two file, the bytes must
    /// decode through the same format, and the decoded sections must equal the
    /// input. No deliberate marker difference is excluded: the file writes each
    /// section's values as given, so any difference is a silent change, and a
    /// silent change is refused.
    package static func stagedFileData(for config: ProxyConfig) throws -> Data {
        try stagedFile(for: config).bytes
    }

    /// The bytes a save writes, and the value those bytes decode to. The exact round-trip below already decodes them, so that value
    /// is returned as it is: a store adopts it without a second decode of the same bytes.
    package static func stagedFile(for config: ProxyConfig) throws -> StagedFile {
        // The resource policy comes first: an over-limit config is refused before it is encoded, and before any directory
        // is created, so the save writes nothing.
        if let violation = config.resourceViolation() {
            throw ConfigurationResourceRefusal(violation: violation)
        }
        if let refusal = config.fileRepresentabilityRefusal() { throw refusal }
        let data = try CanonicalJSON.encoder(prettyPrinted: true).encode(config)
        // The loader refuses any runtime file past the physical budget, so the writer refuses to create one. This is the same
        // budget, checked on the bytes it would write, not a new cap.
        guard data.count <= ConfigurationFileReader.maximumBytes else {
            throw ConfigurationFileSizeRefusal(encodedBytes: data.count, limit: ConfigurationFileReader.maximumBytes)
        }
        let decoded: ProxyConfig
        do {
            decoded = try CanonicalJSON.decoder().decode(ProxyConfig.self, from: data)
        } catch {
            // The encoder just produced these bytes. A failure here is a bug in the
            // format, not in the input, so it is refused under the generic field.
            throw ConfigFileRepresentabilityError(field: "config", requirement: .unchangedDecoding)
        }
        if let mismatch = ConfigFileRepresentabilityError.firstMismatch(frozen: config, decoded: decoded) {
            throw mismatch
        }
        return StagedFile(bytes: data, value: decoded)
    }

    /// Staged bytes and the value they decode to. The value equals the input, because the exact round-trip checked it.
    package struct StagedFile: Sendable {
        package let bytes: Data
        package let value: ProxyConfig
    }

    package static func save(_ config: ProxyConfig, in environment: RuntimeEnvironment) throws {
        try save(config, to: environment.configFile)
    }

    /// The legacy platform value of the runtime file. A caller reads it only when the platform sidecar is absent, so this is
    /// one read of the runtime file for that caller.
    package static func legacyPlatform(in environment: RuntimeEnvironment) throws -> LegacyComponent<PlatformIntegrationConfig> {
        try loadRuntimeFile(at: environment.configFile,
                            requirements: RuntimeFileRequirements(platform: true, preferences: false),
                            allowMissing: true).platform
    }

    /// The legacy preferences value of the runtime file. A caller reads it only when the preferences sidecar is absent.
    package static func legacyPreferences(in environment: RuntimeEnvironment) throws -> LegacyComponent<AppPreferences> {
        try loadRuntimeFile(at: environment.configFile,
                            requirements: RuntimeFileRequirements(platform: false, preferences: true),
                            allowMissing: true).preferences
    }
}

/// A save refused because a value crosses its approved resource ceiling (decisions 0021 and 0022). It is raised before any
/// byte is encoded or written. It names the field and the limit, never the value.
package struct ConfigurationResourceRefusal: Error, LocalizedError, Sendable {
    package let violation: DomainResourceViolation

    package init(violation: DomainResourceViolation) {
        self.violation = violation
    }

    package var errorDescription: String? {
        "Cannot save the configuration: \(violation.description). Nothing was written and the previous file is unchanged. Reduce the entries to the limit."
    }

    /// Emitted with the save refusal, under the same event name as a representability refusal.
    package var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: "config.save_rejected", detail: errorDescription)
    }
}

/// A save refused because its encoded bytes exceed the runtime file budget (decision 0021). The loader would refuse the file,
/// so the writer refuses it first. Only the byte count is reported.
package struct ConfigurationFileSizeRefusal: Error, LocalizedError, Sendable {
    package let encodedBytes: Int
    package let limit: Int

    package init(encodedBytes: Int, limit: Int) {
        self.encodedBytes = encodedBytes
        self.limit = limit
    }

    package var errorDescription: String? {
        "Cannot save the configuration: its encoded form is \(encodedBytes) bytes, past the \(limit)-byte runtime file limit. Nothing was written and the previous file is unchanged."
    }

    package var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: "config.save_rejected", detail: errorDescription)
    }
}

/// The sidecar a save writes. Its label is what a refusal names, so the banner says which file kept its previous contents.
package enum ConfigurationSidecarFile: Sendable, Equatable {
    case platform
    case preferences

    package var label: String {
        switch self {
        case .platform: "the platform settings"
        case .preferences: "the app preferences"
        }
    }
}

/// A sidecar save refused before any byte is written (decision 0026). It names the sidecar and the ceiling that crossed, never
/// the value. The sidecar keeps its previous contents. The runtime file is saved separately, so the message says only that.
package struct ConfigurationSidecarSaveRefusal: Error, LocalizedError, Sendable {
    package enum Cause: Sendable, Equatable {
        case resourceLimit(DomainResourceViolation)
        case fileSize(encodedBytes: Int, limit: Int)
    }

    package let file: ConfigurationSidecarFile
    package let cause: Cause

    package init(file: ConfigurationSidecarFile, cause: Cause) {
        self.file = file
        self.cause = cause
    }

    package var errorDescription: String? {
        let detail: String
        switch cause {
        case .resourceLimit(let violation):
            detail = violation.description
        case .fileSize(let encodedBytes, let limit):
            detail = "its encoded form is \(encodedBytes) bytes, past the \(limit)-byte sidecar limit"
        }
        return "Cannot save \(file.label): \(detail). The file keeps its previous contents; the other settings are saved separately."
    }

    /// Emitted with the refusal under the save path's event name, `config.save_rejected`, which names the field and never the value.
    package var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: "config.save_rejected", detail: errorDescription)
    }
}

/// A save refused because the schema-two file cannot hold a required value
/// exactly. It is raised before any byte is written, so the previous file is
/// unchanged. `field` is a config path and `requirement` is fixed text; the
/// value itself is never echoed.
package struct ConfigFileRepresentabilityError: Error, LocalizedError, Sendable {
    package enum Requirement: String, Sendable {
        case finiteNumber = "finite numbers"
        case runtimeRange = "durations within this field's supported range"
        case wholeMilliseconds = "whole milliseconds"
        case wholeMinutes = "whole minutes"
        case unchangedDecoding = "values that decode unchanged"
    }

    package let field: String
    package let requirement: Requirement

    package init(field: String, requirement: Requirement) {
        self.field = field
        self.requirement = requirement
    }

    package var errorDescription: String? {
        "Cannot save \(field): the schema 2 file holds \(requirement.rawValue) exactly, so nothing was written and the previous file is unchanged. Change the value to one the file can hold."
    }

    /// Emitted by `AppState.persistConfiguration`, the app's save path, when a
    /// save is refused. Its `saveConfig` also holds the apply, so the runtime keeps
    /// the last config it applied (`config.apply_held` covers the validation case).
    package var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: "config.save_rejected", detail: errorDescription)
    }

    /// The first field that the schema-two file cannot hold exactly, or nil.
    /// Finiteness comes first, so a NaN is refused as a non-finite value, not as
    /// a unit mismatch. Then the runtime's range: a finite JSON number round-trips,
    /// but a value the runtime cannot hold would be written and then refused at
    /// the boundary, so the save refuses it first (decision 0023). Only the two
    /// legacy keys have a unit (whole ms and whole minutes).
    fileprivate static func firstRefusal(for config: ProxyConfig) -> ConfigFileRepresentabilityError? {
        // Both checks read the one duration inventory. Finiteness is checked over all of it
        // before the runtime range, so a NaN is never reported as a range problem.
        if let nonFinite = RuntimeDurationField.allCases.first(where: { !$0.seconds(in: config).isFinite }) {
            return ConfigFileRepresentabilityError(field: nonFinite.path, requirement: .finiteNumber)
        }
        if let outOfRange = config.firstUnrepresentableDuration() {
            return ConfigFileRepresentabilityError(field: outOfRange.path, requirement: .runtimeRange)
        }
        if DurationUnits.exactMilliseconds(config.health.connectionCheckTimeout) == nil {
            return ConfigFileRepresentabilityError(field: "health.connectionCheckTimeout", requirement: .wholeMilliseconds)
        }
        if DurationUnits.exactMinutes(config.health.directConnectTTL) == nil {
            return ConfigFileRepresentabilityError(field: "health.directConnectTTL", requirement: .wholeMinutes)
        }
        return nil
    }

    /// The first section whose decoded value differs from the input, or nil.
    fileprivate static func firstMismatch(frozen: ProxyConfig, decoded: ProxyConfig) -> ConfigFileRepresentabilityError? {
        let sections: [(name: String, matches: Bool)] = [
            ("schemaVersion", frozen.schemaVersion == decoded.schemaVersion),
            ("profileName", frozen.profileName == decoded.profileName),
            ("proxy", frozen.proxy == decoded.proxy),
            ("auth", frozen.auth == decoded.auth),
            ("upstreams", frozen.upstreams == decoded.upstreams),
            ("routing", frozen.routing == decoded.routing),
            ("dns", frozen.dns == decoded.dns),
            ("tunnels", frozen.tunnels == decoded.tunnels),
            ("health", frozen.health == decoded.health),
            ("logging", frozen.logging == decoded.logging),
        ]
        guard let changed = sections.first(where: { !$0.matches }) else { return nil }
        return ConfigFileRepresentabilityError(field: changed.name, requirement: .unchangedDecoding)
    }
}

extension ProxyConfig {
    fileprivate func fileRepresentabilityRefusal() -> ConfigFileRepresentabilityError? {
        ConfigFileRepresentabilityError.firstRefusal(for: self)
    }
}

/// A load refused with a fixed reason. Every sidecar and runtime load reports one of these, and it names no value.
package struct ConfigurationLoadError: Error, LocalizedError, Sendable {
    package let source: String
    package let reason: String

    package init(source: String, reason: String) {
        self.source = source
        self.reason = reason
    }

    package var errorDescription: String? {
        "Cannot load \(source). \(reason) Repair the file and retry; no replacement configuration was applied."
    }

    package var event: RuntimeEvent {
        RuntimeEvent(kind: .config, event: "config.load_rejected", detail: errorDescription)
    }

    /// Startup failures have no orchestrator yet. Still emit canonical NDJSON.
    package func report(to logger: any LogSink) {
        let event = self.event
        do {
            let data = try CanonicalJSON.encoder().encode(event)
            FileHandle.standardError.write(data + Data([0x0a]))
        } catch {
            logger.log(.error, "Could not encode config rejection event: \(error.localizedDescription)", category: .general)
        }
        logger.log(.error, event.detail ?? event.event, category: .general)
    }
}

// MARK: - Platform Config Persistence

/// The fallback the shared loader takes when it refuses a legacy component's value (decisions 0023 and 0026). The fixed text of
/// that fallback is written only here: `warning` is the legacy `[String]` text, and the store carries the case itself.
package enum ConfigurationLegacyFallback: Equatable, Sendable {
    case legacyPlatformRefusedUsingDefaults
    case legacyPreferencesRefusedUsingDefaults

    package var warning: String {
        switch self {
        case .legacyPlatformRefusedUsingDefaults:
            "Legacy platform settings in the configuration file could not be read; default platform settings are used."
        case .legacyPreferencesRefusedUsingDefaults:
            "Legacy app preferences in the configuration file could not be read; default preferences are used."
        }
    }
}

package struct PlatformConfigMigrationResult: Sendable {
    package let config: PlatformIntegrationConfig
    package let migrated: Bool
    package let warnings: [String]
    /// The fallback taken for a refused legacy value, or nil. Only `resolve` sets it, and the same case's text is then in `warnings`.
    package let fallback: ConfigurationLegacyFallback?

    package init(
        config: PlatformIntegrationConfig,
        migrated: Bool,
        warnings: [String],
        fallback: ConfigurationLegacyFallback? = nil
    ) {
        self.config = config
        self.migrated = migrated
        self.warnings = warnings
        self.fallback = fallback
    }
}

package enum PlatformConfigPersistence {
    /// The platform config for a caller that loads it alone. A present sidecar is returned without reading the runtime file.
    /// Otherwise the legacy value is migrated and its sidecar written, as a full load does. Any warning is thrown, so a failed
    /// migration write is reported rather than dropped.
    package static func load(in environment: RuntimeEnvironment) throws -> PlatformIntegrationConfig {
        let result = try loadMigrating(in: environment)
        if let warning = result.warnings.first {
            throw ConfigurationLoadError(source: environment.platformConfigFile.path, reason: warning)
        }
        return result.config
    }

    /// The platform config with its migration state. The runtime file is read only when the sidecar is absent, and a migrated
    /// value is written back when `saveMigrated` is set.
    package static func loadMigrating(in environment: RuntimeEnvironment, saveMigrated: Bool = true) throws -> PlatformConfigMigrationResult {
        if let sidecar = try readSidecar(in: environment) {
            return resolve(sidecar: sidecar, legacy: .notRequired)
        }
        let candidate = resolve(sidecar: nil, legacy: try ProxyConfigPersistence.legacyPlatform(in: environment))
        guard candidate.migrated, saveMigrated else {
            return candidate
        }
        do {
            try save(candidate.config, in: environment)
            return candidate
        } catch {
            return PlatformConfigMigrationResult(
                config: candidate.config,
                migrated: true,
                warnings: [migrationWarning("Platform config", environment.platformConfigFile, error)]
            )
        }
    }

    /// The platform sidecar, read once through the bounded sidecar gate (decision 0026). Nil when the file is absent.
    package static func readSidecar(in environment: RuntimeEnvironment) throws -> PlatformIntegrationConfig? {
        try loadSidecar(PlatformIntegrationConfig.self, root: ConfigurationFileSchema.platformSidecar, from: environment.platformConfigFile)
    }

    /// The typed value of bytes a platform save staged, through the same gate and decode as a read. A store adopts its values from
    /// the bytes it verified, so it never decodes a second way.
    package static func decode(_ data: Data, source: String) throws -> PlatformIntegrationConfig {
        try decodePresentSidecar(PlatformIntegrationConfig.self, root: ConfigurationFileSchema.platformSidecar, data: data, source: source)
    }

    /// The platform candidate: the sidecar when one was read, else the runtime file's legacy value. A refused legacy value
    /// falls back to the defaults, with a warning that names no value. Nothing is written.
    package static func resolve(sidecar: PlatformIntegrationConfig?, legacy: LegacyComponent<PlatformIntegrationConfig>) -> PlatformConfigMigrationResult {
        if let sidecar {
            return PlatformConfigMigrationResult(config: sidecar, migrated: false, warnings: [])
        }
        switch legacy {
        case .decoded(let migrated):
            return PlatformConfigMigrationResult(config: migrated, migrated: true, warnings: [])
        case .refused:
            let fallback = ConfigurationLegacyFallback.legacyPlatformRefusedUsingDefaults
            return PlatformConfigMigrationResult(
                config: PlatformIntegrationConfig(),
                migrated: false,
                warnings: [fallback.warning],
                fallback: fallback
            )
        case .notRequired:
            return PlatformConfigMigrationResult(config: PlatformIntegrationConfig(), migrated: false, warnings: [])
        }
    }

    /// The exact bytes a platform save writes, staged and checked against the sidecar budget before any write.
    package static func stagedData(for config: PlatformIntegrationConfig) throws -> Data {
        try stagedSidecarData(config, file: .platform)
    }

    package static func save(_ config: PlatformIntegrationConfig, in environment: RuntimeEnvironment) throws {
        try writeData(try stagedData(for: config), to: environment.platformConfigFile)
    }
}

// MARK: - App Preferences Persistence

package struct AppPreferencesMigrationResult: Sendable {
    package let preferences: AppPreferences
    package let migrated: Bool
    package let warnings: [String]
    /// The fallback taken for a refused legacy value, or nil. Only `resolve` sets it, and the same case's text is then in `warnings`.
    package let fallback: ConfigurationLegacyFallback?

    package init(
        preferences: AppPreferences,
        migrated: Bool,
        warnings: [String],
        fallback: ConfigurationLegacyFallback? = nil
    ) {
        self.preferences = preferences
        self.migrated = migrated
        self.warnings = warnings
        self.fallback = fallback
    }
}

package enum AppPreferencesPersistence {
    /// The preferences for a caller that loads them alone. It follows `PlatformConfigPersistence.load`: a present sidecar
    /// is returned without reading the runtime file, and any warning is thrown.
    package static func load(in environment: RuntimeEnvironment) throws -> AppPreferences {
        let result = try loadMigrating(in: environment)
        if let warning = result.warnings.first {
            throw ConfigurationLoadError(source: environment.preferencesFile.path, reason: warning)
        }
        return result.preferences
    }

    /// The preferences with their migration state. The runtime file is read only when the sidecar is absent, and a migrated
    /// value is written back when `saveMigrated` is set.
    package static func loadMigrating(in environment: RuntimeEnvironment, saveMigrated: Bool = true) throws -> AppPreferencesMigrationResult {
        if let sidecar = try readSidecar(in: environment) {
            return resolve(sidecar: sidecar, legacy: .notRequired)
        }
        let candidate = resolve(sidecar: nil, legacy: try ProxyConfigPersistence.legacyPreferences(in: environment))
        guard candidate.migrated, saveMigrated else {
            return candidate
        }
        do {
            try save(candidate.preferences, in: environment)
            return candidate
        } catch {
            return AppPreferencesMigrationResult(
                preferences: candidate.preferences,
                migrated: true,
                warnings: [migrationWarning("App preferences", environment.preferencesFile, error)]
            )
        }
    }

    /// The preferences sidecar, read once through the bounded sidecar gate (decision 0026). Nil when the file is absent.
    package static func readSidecar(in environment: RuntimeEnvironment) throws -> AppPreferences? {
        try loadSidecar(AppPreferences.self, root: ConfigurationFileSchema.preferencesSidecar, from: environment.preferencesFile)
    }

    /// The typed preferences of bytes a preferences save staged, through the same gate and decode as a read (see the platform form).
    package static func decode(_ data: Data, source: String) throws -> AppPreferences {
        try decodePresentSidecar(AppPreferences.self, root: ConfigurationFileSchema.preferencesSidecar, data: data, source: source)
    }

    /// The preferences candidate: the sidecar when one was read, else the runtime file's legacy value. Follows
    /// `PlatformConfigPersistence.resolve`.
    package static func resolve(sidecar: AppPreferences?, legacy: LegacyComponent<AppPreferences>) -> AppPreferencesMigrationResult {
        if let sidecar {
            return AppPreferencesMigrationResult(preferences: sidecar, migrated: false, warnings: [])
        }
        switch legacy {
        case .decoded(let migrated):
            return AppPreferencesMigrationResult(preferences: migrated, migrated: true, warnings: [])
        case .refused:
            let fallback = ConfigurationLegacyFallback.legacyPreferencesRefusedUsingDefaults
            return AppPreferencesMigrationResult(
                preferences: AppPreferences(),
                migrated: false,
                warnings: [fallback.warning],
                fallback: fallback
            )
        case .notRequired:
            return AppPreferencesMigrationResult(preferences: AppPreferences(), migrated: false, warnings: [])
        }
    }

    /// The exact bytes a preferences save writes. The browser URL is checked as raw UTF-8 before any encoding and before the
    /// typed decode's blank fallback (decision 0026). No other value is normalized, so the bytes hold what the caller gave.
    package static func stagedData(for prefs: AppPreferences) throws -> Data {
        if let violation = DomainResourceCheck.text(prefs.preferredBrowserTestURL, .browserTestURL) {
            throw ConfigurationSidecarSaveRefusal(file: .preferences, cause: .resourceLimit(violation))
        }
        return try stagedSidecarData(prefs, file: .preferences)
    }

    package static func save(_ prefs: AppPreferences, in environment: RuntimeEnvironment) throws {
        try writeData(try stagedData(for: prefs), to: environment.preferencesFile)
    }
}
