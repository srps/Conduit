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

    /// Decodes a file's bytes through the format gate: the physical cap, the strict filter for the keys this read needs,
    /// one Foundation decode and the newer-schema refusal. The bytes are the caller's, and nothing is written here.
    package static func decode(_ bytes: Data, requirements: RuntimeFileRequirements, source: String) throws -> RuntimeFileDocument {
        guard bytes.count <= RuntimeConfigurationFileReader.maximumBytes else {
            throw ConfigurationLoadError(source: source, reason: "The configuration exceeds the runtime file size limit.")
        }
        let filtered: RuntimeFileFiltered
        do {
            filtered = try bytes.withUnsafeBytes { raw in
                try RuntimeFileFilter.filter(
                    UnsafeBufferPointer(start: raw.baseAddress?.assumingMemoryBound(to: UInt8.self), count: raw.count),
                    root: RuntimeFileSchema.root(requirements)
                )
            }
        } catch let refusal as RuntimeFileRefusal {
            throw ConfigurationLoadError(source: source, reason: refusal.reason)
        }
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
        return RuntimeFileDocument(
            config: envelope.config,
            originalSchemaVersion: envelope.originalSchemaVersion,
            platform: legacy(requirements.platform, .platform, in: filtered, decoded: envelope.platform),
            preferences: legacy(requirements.preferences, .preferences, in: filtered, decoded: envelope.preferences)
        )
    }

    /// A component that was not required is `.notRequired`, and so is never used. A required one is refused when the
    /// filter refused its value, and otherwise carries what its decoder read.
    private static func legacy<Value: Sendable>(
        _ required: Bool,
        _ component: RuntimeFileComponent,
        in filtered: RuntimeFileFiltered,
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

extension RuntimeFileRefusal {
    /// The fixed reason a loader reports. It names the limit, never the value that crossed it.
    var reason: String {
        switch self {
        case .malformed:
            "The configuration is not valid Conduit JSON."
        case .resourceLimit(let violation):
            "The configuration exceeds a resource limit. \(violation.description)."
        }
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
