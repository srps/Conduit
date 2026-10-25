// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// One legacy component (platform or preferences) read from a runtime file.
package enum LegacyComponent<Value: Sendable>: Sendable {
    /// The component's sidecar exists, so the file's values for it are not used.
    case notRequired
    case decoded(Value)
    /// The file holds a value this component refuses, or the filter refused it. The component falls back to its defaults,
    /// with a warning from the loader. The runtime keeps loading.
    case refused
}

/// A runtime file as one frozen read produced it: the typed config, the version the file was written at, and each legacy
/// component that the file's own values supplied.
package struct RuntimeFileDocument: Sendable {
    package let config: ProxyConfig
    /// The version the file says it was written at. A missing or null version is 0, so a legacy file migrates.
    /// `ProxyConfig` defaults a missing version to the current one, so it cannot stand in for this value.
    package let originalSchemaVersion: Int
    package let platform: LegacyComponent<PlatformIntegrationConfig>
    package let preferences: LegacyComponent<AppPreferences>
    /// The legacy components whose values a rewrite of this file would drop: a shadowed component with a non-null known key, or a read
    /// component that decoded with one. A refused component is not here, because its defaults and warning already stand. A null key is
    /// absent, so it is not here either.
    package let carriedLegacyComponents: Set<ConfigurationComponent>

    /// Decodes a runtime file's bytes through the format gate: the physical cap, the strict filter for the keys this read needs,
    /// one Foundation decode and the newer-schema refusal. The bytes are the caller's, and nothing is written here.
    package static func decode(_ bytes: Data, requirements: RuntimeFileRequirements, source: String) throws -> RuntimeFileDocument {
        let root = ConfigurationFileSchema.runtime(requirements)
        let filtered = try ConfigurationFileGate.filter(bytes, root: root, source: source)
        // The requirements travel with the decoder, so the envelope builds only the legacy components this read keeps.
        let decoder = CanonicalJSON.decoder()
        decoder.userInfo[RuntimeFileRequirements.userInfoKey] = requirements
        let envelope: RuntimeFileEnvelope
        do {
            envelope = try decoder.decode(RuntimeFileEnvelope.self, from: filtered.bytes)
        } catch {
            // Do not echo configuration content, which may hold secrets.
            throw ConfigurationLoadError(source: source, reason: "The configuration is not valid Conduit JSON.")
        }
        guard envelope.originalSchemaVersion <= ProxyConfig.currentSchemaVersion else {
            throw ConfigurationLoadError(source: source, reason: "The configuration requires a newer version of Conduit.")
        }
        let platform = legacy(requirements.platform, .platform, in: filtered, decoded: envelope.platform)
        let preferences = legacy(requirements.preferences, .preferences, in: filtered, decoded: envelope.preferences)
        var carried: Set<ConfigurationComponent> = []
        if carries(.platform, required: requirements.platform, platform, in: filtered) { carried.insert(.platform) }
        if carries(.preferences, required: requirements.preferences, preferences, in: filtered) { carried.insert(.preferences) }
        return RuntimeFileDocument(
            config: envelope.config,
            originalSchemaVersion: envelope.originalSchemaVersion,
            platform: platform,
            preferences: preferences,
            carriedLegacyComponents: carried
        )
    }

    /// Whether a legacy component's values are in the file and must survive a rewrite. A shadowed component (not required) carries them
    /// when a non-null value is present, because its sidecar is the authority and a rewrite must not replace it blindly. A required
    /// component carries them only when it decoded, so a refused component keeps its defaults and warning and needs no guard.
    private static func carries<Value: Sendable>(
        _ component: ConfigurationComponent,
        required: Bool,
        _ legacy: LegacyComponent<Value>,
        in filtered: ConfigurationFileFiltered
    ) -> Bool {
        guard filtered.legacyValuesPresent.contains(component) else { return false }
        guard required else { return true }
        if case .decoded = legacy { return true }
        return false
    }

    /// A component that was not required is `.notRequired`, and so is never used. A required one is refused when the
    /// filter refused its value, and otherwise carries what its decoder read.
    private static func legacy<Value: Sendable>(
        _ required: Bool,
        _ component: ConfigurationComponent,
        in filtered: ConfigurationFileFiltered,
        decoded: LegacyComponent<Value>
    ) -> LegacyComponent<Value> {
        guard required else {
            return .notRequired
        }
        guard !filtered.refusedComponents.contains(component) else {
            return .refused
        }
        return decoded
    }
}

/// The one Foundation decode of the filtered bytes. It reads the version and the typed config from the same decoder, so
/// the version is the one the config was read with.
private struct RuntimeFileEnvelope: Decodable {
    let originalSchemaVersion: Int
    let config: ProxyConfig
    let platform: LegacyComponent<PlatformIntegrationConfig>
    let preferences: LegacyComponent<AppPreferences>

    private enum VersionKey: String, CodingKey {
        case schemaVersion
    }

    init(from decoder: Decoder) throws {
        let versions = try decoder.container(keyedBy: VersionKey.self)
        originalSchemaVersion = try versions.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 0
        config = try ProxyConfig(from: decoder)
        let requirements = decoder.userInfo[RuntimeFileRequirements.userInfoKey] as? RuntimeFileRequirements ?? .runtimeOnly
        platform = requirements.platform ? Self.component(PlatformIntegrationConfig.self, from: decoder) : .notRequired
        preferences = requirements.preferences ? Self.component(AppPreferences.self, from: decoder) : .notRequired
    }

    /// A legacy component is read from the same filtered document. A value its decoder refuses is recorded as `.refused`,
    /// so only that component falls back. The runtime's own decode is not affected.
    private static func component<Value: Decodable & Sendable>(_ type: Value.Type, from decoder: Decoder) -> LegacyComponent<Value> {
        do {
            return .decoded(try type.init(from: decoder))
        } catch {
            return .refused
        }
    }
}
