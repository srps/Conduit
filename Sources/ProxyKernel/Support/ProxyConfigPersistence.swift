// SPDX-License-Identifier: Apache-2.0
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

private struct SchemaVersionEnvelope: Decodable {
    let schemaVersion: Int?
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

    package static func loadAllMigrating(
        in environment: RuntimeEnvironment,
        allowMissing: Bool = true,
        validateRuntime: (ProxyConfig) throws -> Void = { _ in }
    ) throws -> RuntimeConfigurationLoadResult {
        // Stage every candidate before migration can write any files. A valid
        // runtime file must not hide a broken platform or preference sidecar.
        let runtime = try loadMigrating(from: environment.configFile, saveMigrated: false,
                                        allowMissing: allowMissing && !hasConfigurationState(in: environment))
        let platform = try PlatformConfigPersistence.loadMigrating(in: environment, saveMigrated: false)
        let preferences = try AppPreferencesPersistence.loadMigrating(in: environment, saveMigrated: false)
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

    package static func loadMigrating(from url: URL, saveMigrated: Bool = true, allowMissing: Bool = true) throws -> ProxyConfigMigrationResult {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile && allowMissing {
            return ProxyConfigMigrationResult(config: GenericDefaults.shared.makeConfig(), migrated: false, warnings: [])
        } catch {
            throw ConfigurationLoadError(source: url.path, reason: "The configuration file could not be read.")
        }
        let decoded = try decode(data, source: url.path)

        let previousVersion = (try? CanonicalJSON.decoder().decode(SchemaVersionEnvelope.self, from: data).schemaVersion) ?? 0
        let needsMigration = previousVersion < ProxyConfig.currentSchemaVersion
        guard needsMigration else {
            return ProxyConfigMigrationResult(config: decoded, migrated: false, warnings: [])
        }

        var migrated = migrate(decoded, from: previousVersion)
        migrated.schemaVersion = ProxyConfig.currentSchemaVersion
        guard saveMigrated else {
            return ProxyConfigMigrationResult(config: migrated, migrated: true, warnings: [])
        }
        do {
            try save(migrated, to: url)
            return ProxyConfigMigrationResult(config: migrated, migrated: true, warnings: [])
        } catch {
            return ProxyConfigMigrationResult(
                config: migrated,
                migrated: true,
                warnings: ["Config schema migrated in memory but could not be written to \(url.path): \(error.localizedDescription)"]
            )
        }
    }

    package static func decode(_ data: Data, source: String) throws -> ProxyConfig {
        let decoded: ProxyConfig
        do {
            decoded = try CanonicalJSON.decoder().decode(ProxyConfig.self, from: data)
        } catch {
            // Do not echo configuration content (which may contain secrets).
            throw ConfigurationLoadError(source: source, reason: "The configuration is not valid Conduit JSON.")
        }
        guard decoded.schemaVersion <= ProxyConfig.currentSchemaVersion else {
            throw ConfigurationLoadError(source: source, reason: "The configuration requires a newer version of Conduit.")
        }
        return decoded
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

    /// Saves `config` only after its bytes are staged and checked. A refusal
    /// throws before any directory or file is created or replaced.
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
        if let refusal = config.fileRepresentabilityRefusal() { throw refusal }
        let data = try CanonicalJSON.encoder(prettyPrinted: true).encode(config)
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
        case runtimeRange = "durations inside the runtime's nanosecond range"
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
    package static func load(in environment: RuntimeEnvironment) throws -> PlatformIntegrationConfig {
        try loadMigrating(in: environment).config
    }

    package static func loadMigrating(in environment: RuntimeEnvironment, saveMigrated: Bool = true) throws -> PlatformConfigMigrationResult {
        if let config = try loadJSON(PlatformIntegrationConfig.self, from: environment.platformConfigFile) {
            return PlatformConfigMigrationResult(config: config, migrated: false, warnings: [])
        }
        if let migrated = LegacyConfigMigration.extractPlatformConfig(from: environment.configFile) {
            guard saveMigrated else {
                return PlatformConfigMigrationResult(config: migrated, migrated: true, warnings: [])
            }
            do {
                try save(migrated, in: environment)
                return PlatformConfigMigrationResult(config: migrated, migrated: true, warnings: [])
            } catch {
                return PlatformConfigMigrationResult(
                    config: migrated,
                    migrated: true,
                    warnings: ["Platform config migrated in memory but could not be written to \(environment.platformConfigFile.path): \(error.localizedDescription)"]
                )
            }
        }
        return PlatformConfigMigrationResult(config: PlatformIntegrationConfig(), migrated: false, warnings: [])
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
    package static func load(in environment: RuntimeEnvironment) throws -> AppPreferences {
        try loadMigrating(in: environment).preferences
    }

    package static func loadMigrating(in environment: RuntimeEnvironment, saveMigrated: Bool = true) throws -> AppPreferencesMigrationResult {
        if let prefs = try loadJSON(AppPreferences.self, from: environment.preferencesFile) {
            return AppPreferencesMigrationResult(preferences: prefs, migrated: false, warnings: [])
        }
        if let migrated = LegacyConfigMigration.extractAppPreferences(from: environment.configFile) {
            guard saveMigrated else {
                return AppPreferencesMigrationResult(preferences: migrated, migrated: true, warnings: [])
            }
            do {
                try save(migrated, in: environment)
                return AppPreferencesMigrationResult(preferences: migrated, migrated: true, warnings: [])
            } catch {
                return AppPreferencesMigrationResult(
                    preferences: migrated,
                    migrated: true,
                    warnings: ["App preferences migrated in memory but could not be written to \(environment.preferencesFile.path): \(error.localizedDescription)"]
                )
            }
        }
        return AppPreferencesMigrationResult(preferences: AppPreferences(), migrated: false, warnings: [])
    }

    package static func save(_ prefs: AppPreferences, in environment: RuntimeEnvironment) throws {
        try writeJSON(prefs, to: environment.preferencesFile)
    }
}
