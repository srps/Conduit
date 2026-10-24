// SPDX-License-Identifier: Apache-2.0
import ConduitShared

// The kernel's typed resource check (decision 0021). This file only maps `ProxyConfig` storage to the resource view in
// `ConduitShared`. The order, the ceilings and the refusals live once, in `DomainResourceCheck.configuration(_:)`. The
// bridge runs the check before any value is mapped; runtime eligibility stays with the runtime gate. The private request
// reads the same traversal, and a parity test pins that the two agree. Raw stored bytes count, and so do disabled
// entries and whitespace.

extension ProxyConfig {
    /// The first approved ceiling a stored value crosses, or nil.
    package func resourceViolation() -> DomainResourceViolation? {
        DomainResourceCheck.configuration(KernelResourceView(config: self))
    }
}

/// The kernel's resource view. It holds the configuration value it was built from, and each accessor returns a stored
/// value. Nothing is mapped into a new array or encoded to be measured. A string is read for its UTF-8 length, and an
/// intercept pattern also for its two-byte wildcard prefix.
private struct KernelResourceView: ConfigurationResourceSource {
    let config: ProxyConfig

    var profileName: String { config.profileName }
    var proxyHost: String { config.proxy.host }
    var allowedClients: [String] { config.proxy.allowedClients }
    var authUsername: String { config.auth.username }
    var authDomain: String { config.auth.domain }
    var authWorkstation: String { config.auth.workstation }
    var upstreams: [UpstreamProxy] { config.upstreams }
    var pacURLByteCount: Int { config.routing.pacURL.utf8.count }
    var noProxyHosts: [String] { config.routing.noProxyHosts }
    var forceProxyHosts: [String] { config.routing.forceProxyHosts }
    var dohProviders: [String] { config.dns.dohProviders }
    var dnsEntries: [DomainDNSEntry] { config.dns.entries }
    var interceptRules: [DNSInterceptRule] { config.dns.interceptRules }
    var transparentProxyIP: String { config.dns.transparentProxyIP }
    var tunnelDefinitions: [TunnelDefinition] { config.tunnels.definitions }
    var checkURLByteCount: Int { config.health.checkURL.utf8.count }
    var auditLogPath: String? { config.logging.auditLogPath }

    static func upstreamName(_ upstream: UpstreamProxy) -> String { upstream.name }
    static func upstreamHost(_ upstream: UpstreamProxy) -> String { upstream.host }
    static func providerByteCount(_ provider: String) -> Int { provider.utf8.count }
    static func entryDomain(_ entry: DomainDNSEntry) -> String { entry.domain }
    static func entryServers(_ entry: DomainDNSEntry) -> [String] { entry.servers }
    static func interceptPattern(_ rule: DNSInterceptRule) -> String { rule.pattern }
    static func interceptAddress(_ rule: DNSInterceptRule) -> String { rule.interceptIP }
    static func tunnelRemoteHost(_ tunnel: TunnelDefinition) -> String { tunnel.remoteHost }
    static func tunnelLabel(_ tunnel: TunnelDefinition) -> String { tunnel.label }
}
