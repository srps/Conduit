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
    package static func load(from url: URL) -> ProxyConfig {
        loadMigrating(from: url, saveMigrated: false).config
    }

    package static func load(in environment: RuntimeEnvironment) -> ProxyConfig {
        load(from: environment.configFile)
    }

    package static func loadAllMigrating(in environment: RuntimeEnvironment) -> RuntimeConfigurationLoadResult {
        let platform = PlatformConfigPersistence.loadMigrating(in: environment)
        let preferences = AppPreferencesPersistence.loadMigrating(in: environment)
        let sidecarMigrationFailed = !platform.warnings.isEmpty || !preferences.warnings.isEmpty
        let runtime = loadMigrating(from: environment.configFile, saveMigrated: !sidecarMigrationFailed)
        return RuntimeConfigurationLoadResult(
            config: runtime.config,
            platformConfig: platform.config,
            appPreferences: preferences.preferences,
            migrated: runtime.migrated || platform.migrated || preferences.migrated,
            warnings: platform.warnings + preferences.warnings + runtime.warnings
        )
    }

    package static func loadMigrating(from url: URL, saveMigrated: Bool = true) -> ProxyConfigMigrationResult {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(ProxyConfig.self, from: data) else {
            return ProxyConfigMigrationResult(
                config: GenericDefaults.shared.makeConfig(),
                migrated: false,
                warnings: []
            )
        }

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
