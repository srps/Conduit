// SPDX-License-Identifier: Apache-2.0
import Foundation

private let prettyEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try prettyEncoder.encode(value).write(to: url, options: .atomic)
}

private func loadJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
    guard let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(type, from: data)
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
        try load(from: environment.configFile, allowMissing: allowMissing)
    }

    package static func loadAllMigrating(in environment: RuntimeEnvironment, allowMissing: Bool = true) throws -> RuntimeConfigurationLoadResult {
        // Reject a broken runtime config before migration can write any files.
        let runtime = try loadMigrating(from: environment.configFile, saveMigrated: false, allowMissing: allowMissing)
        let platform = PlatformConfigPersistence.loadMigrating(in: environment)
        let preferences = AppPreferencesPersistence.loadMigrating(in: environment)
        let sidecarMigrationFailed = !platform.warnings.isEmpty || !preferences.warnings.isEmpty
        var warnings = platform.warnings + preferences.warnings + runtime.warnings
        if runtime.migrated && !sidecarMigrationFailed {
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

        let previousVersion = (try? JSONDecoder().decode(SchemaVersionEnvelope.self, from: data).schemaVersion) ?? 0
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
            decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
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

    package static func save(_ config: ProxyConfig, to url: URL) throws {
        try writeJSON(config, to: url)
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

// MARK: - Platform Config Persistence

package struct PlatformConfigMigrationResult {
    package let config: PlatformIntegrationConfig
    package let migrated: Bool
    package let warnings: [String]
}

package enum PlatformConfigPersistence {
    package static func load(in environment: RuntimeEnvironment) -> PlatformIntegrationConfig {
        loadMigrating(in: environment).config
    }

    package static func loadMigrating(in environment: RuntimeEnvironment) -> PlatformConfigMigrationResult {
        if let config = loadJSON(PlatformIntegrationConfig.self, from: environment.platformConfigFile) {
            return PlatformConfigMigrationResult(config: config, migrated: false, warnings: [])
        }
        if let migrated = LegacyConfigMigration.extractPlatformConfig(from: environment.configFile) {
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
    package static func load(in environment: RuntimeEnvironment) -> AppPreferences {
        loadMigrating(in: environment).preferences
    }

    package static func loadMigrating(in environment: RuntimeEnvironment) -> AppPreferencesMigrationResult {
        if let prefs = loadJSON(AppPreferences.self, from: environment.preferencesFile) {
            return AppPreferencesMigrationResult(preferences: prefs, migrated: false, warnings: [])
        }
        if let migrated = LegacyConfigMigration.extractAppPreferences(from: environment.configFile) {
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
