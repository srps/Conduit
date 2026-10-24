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

// The legacy platform and preferences values of a runtime file are read by `ConfigurationFileSchema` and `RuntimeFileDocument`,
// from the same frozen read as the runtime config (decision 0024). No other path reads the file for them.
