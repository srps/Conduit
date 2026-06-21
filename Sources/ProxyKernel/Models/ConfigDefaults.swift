// SPDX-License-Identifier: Apache-2.0
import Foundation

package protocol ConfigDefaultsProvider: Sendable {
    var profileName: String { get }
    var proxy: ProxySection { get }
    var auth: AuthSection { get }
    var upstreams: [UpstreamProxy] { get }
    var routing: RoutingSection { get }
    var dns: DNSSection { get }
    var tunnels: TunnelSection { get }
    var health: HealthSection { get }
    var logging: LoggingSection { get }
}

extension ConfigDefaultsProvider {
    package func makeConfig() -> ProxyConfig {
        ProxyConfig(
            profileName: profileName,
            proxy: proxy,
            auth: auth,
            upstreams: upstreams,
            routing: routing,
            dns: dns,
            tunnels: tunnels,
            health: health,
            logging: logging
        )
    }
}

/// Vendor-neutral defaults suitable for headless/CLI use and open-source distribution.
package struct GenericDefaults: ConfigDefaultsProvider, Sendable {
    package static let shared = GenericDefaults()
    package let profileName = "Default"
    package let proxy = ProxySection()
    package let auth = AuthSection()
    package let upstreams: [UpstreamProxy] = []
    package let routing = RoutingSection()
    package let dns = DNSSection()
    package let tunnels = TunnelSection()
    package let health = HealthSection()
    package let logging = LoggingSection()
}

// MARK: - Legacy Config Migration

/// Reads platform and preferences fields from a legacy config.json that bundled them
/// with the runtime config. Used for one-time migration on upgrade.
///
/// Both target types use tolerant `init(from decoder:)` with `decodeIfPresent`,
/// so they safely ignore unrelated keys in the flat legacy JSON.
package enum LegacyConfigMigration {
    package static func extractPlatformConfig(from url: URL) -> PlatformIntegrationConfig? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PlatformIntegrationConfig.self, from: data)
    }

    package static func extractAppPreferences(from url: URL) -> AppPreferences? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(AppPreferences.self, from: data)
    }
}
