// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// Persisted JSON uses the canonical pair (AGENTS: files that leave the process
/// use `CanonicalJSON`). A fresh encoder and decoder per call, so no shared
/// instance carries state between saves.
private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    try writeData(CanonicalJSON.encoder(prettyPrinted: true).encode(value), to: url)
}

/// Writes bytes that already exist. A caller encodes first, so a value that
/// cannot be encoded leaves the directory and any existing file untouched.
private func writeData(_ data: Data, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try data.write(to: url, options: .atomic)
}

/// Reads one sidecar JSON file. A file that is absent is nil. A file that exists but cannot be read or decoded is refused.
private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) throws -> T? {
    let data: Data
    do {
        data = try Data(contentsOf: url)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
        return nil
    } catch {
        throw ConfigurationLoadError(source: url.path, reason: "The configuration file could not be read.")
    }
    do {
        return try CanonicalJSON.decoder().decode(type, from: data)
    } catch {
        throw ConfigurationLoadError(source: url.path, reason: "The configuration is not valid Conduit JSON.")
    }
}

/// The bytes of the runtime file, or its absence. A missing file is an outcome, so the caller decides what it means.
private enum RuntimeFileRead {
    case missing
    case present(Data)
}

/// Reads the runtime file through the bounded reader (decision 0021). Only a missing file is an outcome. Every other read
/// failure is refused with a fixed reason, and no path or byte is echoed.
private func readRuntimeFile(at url: URL) throws -> RuntimeFileRead {
    do {
        return .present(try RuntimeConfigurationFileReader.read(at: url))
    } catch let failure as RuntimeConfigurationFileError {
        if case .missing = failure {
            return .missing
        }
        // Every failure keeps its step, its errno and a close failure that followed it (`summary`). Only fixed words are
        // reported, with the source path the loader already names.
        throw ConfigurationLoadError(source: url.path, reason: "The configuration file could not be read: \(failure.summary).")
    }
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

/// Reads and gates the runtime file once. A missing file is defaults when `allowMissing` is set, and a refusal otherwise.
/// Nothing is written here.
private func loadRuntimeFile(at url: URL, requirements: RuntimeFileRequirements, allowMissing: Bool) throws -> RuntimeFileLoad {
    switch try readRuntimeFile(at: url) {
    case .missing:
        guard allowMissing else {
            throw ConfigurationLoadError(source: url.path, reason: "The configuration file could not be read: \(RuntimeConfigurationFileError.missing.summary).")
        }
        return RuntimeFileLoad(
            result: ProxyConfigMigrationResult(config: GenericDefaults.shared.makeConfig(), migrated: false, warnings: []),
            platform: .notRequired,
            preferences: .notRequired
        )
    case .present(let data):
        let document = try RuntimeFileDocument.decode(data, requirements: requirements, source: url.path)
        let (config, migrated) = migratedConfig(document)
        return RuntimeFileLoad(
            result: ProxyConfigMigrationResult(config: config, migrated: migrated, warnings: []),
            platform: document.platform,
            preferences: document.preferences
        )
    }
}

package struct ProxyConfigMigrationResult {
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
    /// the runtime read keeps. Every candidate is staged before the first write, and the writes keep their order.
    package static func loadAllMigrating(
        in environment: RuntimeEnvironment,
        allowMissing: Bool = true,
        validateRuntime: (ProxyConfig) throws -> Void = { _ in }
    ) throws -> RuntimeConfigurationLoadResult {
        let platformSidecar = try PlatformConfigPersistence.readSidecar(in: environment)
        let preferencesSidecar = try AppPreferencesPersistence.readSidecar(in: environment)
        let requirements = RuntimeFileRequirements(platform: platformSidecar == nil, preferences: preferencesSidecar == nil)
        let hasState = platformSidecar != nil || preferencesSidecar != nil
            || FileManager.default.fileExists(atPath: environment.platformStateFile.path)
        let loaded = try loadRuntimeFile(at: environment.configFile, requirements: requirements,
                                         allowMissing: allowMissing && !hasState)
        let runtime = loaded.result
        // Stage every candidate before migration can write any files. A valid runtime file must not hide a broken
        // sidecar, and the sidecars were read above, so nothing is read again here.
        let platform = PlatformConfigPersistence.resolve(sidecar: platformSidecar, legacy: loaded.platform)
        let preferences = AppPreferencesPersistence.resolve(sidecar: preferencesSidecar, legacy: loaded.preferences)
        try validateRuntime(runtime.config)
        var warnings = platform.warnings + preferences.warnings + runtime.warnings
        if platform.migrated {
            do {
                try PlatformConfigPersistence.save(platform.config, in: environment)
            } catch {
                warnings.append("Platform config migrated in memory but could not be written to \(environment.platformConfigFile.path): \(error.localizedDescription)")
            }
        }
        if preferences.migrated {
            do {
                try AppPreferencesPersistence.save(preferences.preferences, in: environment)
            } catch {
                warnings.append("App preferences migrated in memory but could not be written to \(environment.preferencesFile.path): \(error.localizedDescription)")
            }
        }
        if runtime.migrated && warnings.isEmpty {
            do {
                try save(runtime.config, in: environment)
            } catch {
                warnings.append("Config schema migrated in memory but could not be written to \(environment.configFile.path): \(error.localizedDescription)")
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
                warnings: ["Config schema migrated in memory but could not be written to \(url.path): \(error.localizedDescription)"]
            )
        }
    }

    /// Decodes bytes that came from argv or a caller, through the same gate as a file: the physical cap, the strict
    /// filter, one typed decode, the newer-schema refusal and the in-memory migration. Nothing is written.
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
        try writeData(stagedFileData(for: config), to: url)
    }

    /// The exact bytes a save writes, checked in memory (decision 0023). The
    /// config must be representable in the schema-two file, the bytes must
    /// decode through the same format, and the decoded sections must equal the
    /// input. No deliberate marker difference is excluded: the file writes each
    /// section's values as given, so any difference is a silent change, and a
    /// silent change is refused.
    package static func stagedFileData(for config: ProxyConfig) throws -> Data {
        // The resource policy comes first: an over-limit config is refused before it is encoded, and before any directory
        // is created, so the save writes nothing.
        if let violation = config.resourceViolation() {
            throw ConfigurationResourceRefusal(violation: violation)
        }
        if let refusal = config.fileRepresentabilityRefusal() { throw refusal }
        let data = try CanonicalJSON.encoder(prettyPrinted: true).encode(config)
        // The loader refuses any runtime file past the physical budget, so the writer refuses to create one. This is the same
        // budget, checked on the bytes it would write, not a new cap.
        guard data.count <= RuntimeConfigurationFileReader.maximumBytes else {
            throw ConfigurationFileSizeRefusal(encodedBytes: data.count, limit: RuntimeConfigurationFileReader.maximumBytes)
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
        return data
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

// MARK: - Platform Config Persistence

package struct PlatformConfigMigrationResult {
    package let config: PlatformIntegrationConfig
    package let migrated: Bool
    package let warnings: [String]
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

    /// The platform config with its migration state. The runtime file is read only when the sidecar is absent, and a
    /// migrated value is written back when `saveMigrated` is set.
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
                warnings: ["Platform config migrated in memory but could not be written to \(environment.platformConfigFile.path): \(error.localizedDescription)"]
            )
        }
    }

    /// The platform sidecar, read once. Nil when the file is absent.
    package static func readSidecar(in environment: RuntimeEnvironment) throws -> PlatformIntegrationConfig? {
        try loadJSON(PlatformIntegrationConfig.self, from: environment.platformConfigFile)
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
            return PlatformConfigMigrationResult(
                config: PlatformIntegrationConfig(),
                migrated: false,
                warnings: ["Legacy platform settings in the configuration file could not be read; default platform settings are used."]
            )
        case .notRequired:
            return PlatformConfigMigrationResult(config: PlatformIntegrationConfig(), migrated: false, warnings: [])
        }
    }

    package static func save(_ config: PlatformIntegrationConfig, in environment: RuntimeEnvironment) throws {
        try writeJSON(config, to: environment.platformConfigFile)
    }
}

// MARK: - App Preferences Persistence

package struct AppPreferencesMigrationResult {
    package let preferences: AppPreferences
    package let migrated: Bool
    package let warnings: [String]
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
                warnings: ["App preferences migrated in memory but could not be written to \(environment.preferencesFile.path): \(error.localizedDescription)"]
            )
        }
    }

    /// The preferences sidecar, read once. Nil when the file is absent.
    package static func readSidecar(in environment: RuntimeEnvironment) throws -> AppPreferences? {
        try loadJSON(AppPreferences.self, from: environment.preferencesFile)
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
            return AppPreferencesMigrationResult(
                preferences: AppPreferences(),
                migrated: false,
                warnings: ["Legacy app preferences in the configuration file could not be read; default preferences are used."]
            )
        case .notRequired:
            return AppPreferencesMigrationResult(preferences: AppPreferences(), migrated: false, warnings: [])
        }
    }

    package static func save(_ prefs: AppPreferences, in environment: RuntimeEnvironment) throws {
        try writeJSON(prefs, to: environment.preferencesFile)
    }
}
