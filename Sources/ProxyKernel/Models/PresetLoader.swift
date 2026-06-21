// SPDX-License-Identifier: Apache-2.0
import Foundation

package struct PresetDescriptor: Codable, Equatable, Identifiable, Sendable {
    package let id: String
    package let displayName: String
    package let description: String
    package let version: Int
}

package struct ProxyPreset: Codable, Equatable, Identifiable, Sendable {
    package let descriptor: PresetDescriptor
    package let config: ProxyConfig
    package let platform: PlatformIntegrationConfig
    package let preferences: AppPreferences

    package var id: String { descriptor.id }
}

package enum PresetLoader {
    private static let presetsSubdirectory = "Presets"
    private static let indexResourceName = "index"

    package static func availablePresets(bundle: Bundle = .module) -> [PresetDescriptor] {
        loadJSON([PresetDescriptor].self, resource: indexResourceName, bundle: bundle) ?? []
    }

    package static func load(_ id: String, bundle: Bundle = .module) -> ProxyPreset? {
        guard let record = loadJSON(PresetRecord.self, resource: id, bundle: bundle) else {
            return nil
        }
        let descriptor = PresetDescriptor(
            id: record.id,
            displayName: record.displayName,
            description: record.description,
            version: record.version
        )
        let preset = ProxyPreset(
            descriptor: descriptor,
            config: record.config,
            platform: record.platform ?? PlatformIntegrationConfig(),
            preferences: record.preferences ?? AppPreferences()
        )
        guard preset.config.validate().isEmpty else {
            return nil
        }
        return preset
    }

    package static func loadConfig(_ id: String, bundle: Bundle = .module) -> ProxyConfig? {
        load(id, bundle: bundle)?.config
    }

    private static func loadJSON<T: Decodable>(_ type: T.Type, resource: String, bundle: Bundle) -> T? {
        let url = bundle.url(
            forResource: resource,
            withExtension: "json",
            subdirectory: presetsSubdirectory
        ) ?? bundle.url(forResource: resource, withExtension: "json")
        guard let url,
              let data = try? Data(contentsOf: url)
        else {
            return nil
        }
        return try? JSONDecoder().decode(type, from: data)
    }
}

private struct PresetRecord: Codable {
    let id: String
    let displayName: String
    let description: String
    let version: Int
    let config: ProxyConfig
    let platform: PlatformIntegrationConfig?
    let preferences: AppPreferences?
}
