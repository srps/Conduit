// SPDX-License-Identifier: Apache-2.0

// The typed check over one private request (decision 0021). This file only maps the private DTO storage to the
// resource view. The order, the ceilings and the refusals live once, in `DomainResourceCheck.configuration(_:)`. The
// encoder runs the check before it writes anything, so a raw DTO that bypasses the bridge is refused too. The decoder's
// scanner enforces the same ceilings on the bytes before Foundation decodes them, and it uses the shared primitives, not
// this traversal. A parity test pins that the three agree. Every list is refused by its count before any item is read.

extension PrivateConfigurationRequest {
    /// The first approved ceiling the request crosses, or nil.
    package func resourceViolation() -> DomainResourceViolation? {
        runtime.resourceViolation()
    }
}

extension PrivateRuntimeConfiguration {
    /// The first approved ceiling this runtime crosses, or nil. The order follows the wire order of the members.
    package func resourceViolation() -> DomainResourceViolation? {
        DomainResourceCheck.configuration(PrivateResourceView(runtime: self))
    }
}

/// The private runtime's resource view. URL values contribute only their byte counts, so no URL text is revealed.
private struct PrivateResourceView: ConfigurationResourceSource {
    let runtime: PrivateRuntimeConfiguration

    var profileName: String { runtime.profileName }
    var proxyHost: String { runtime.proxy.host }
    var allowedClients: [String] { runtime.proxy.allowedClients }
    var authUsername: String { runtime.auth.username }
    var authDomain: String { runtime.auth.domain }
    var authWorkstation: String { runtime.auth.workstation }
    var upstreams: [PrivateUpstreamSettings] { runtime.upstreams }
    var pacURLByteCount: Int { runtime.routing.pacURL.byteCount }
    var noProxyHosts: [String] { runtime.routing.noProxyHosts }
    var forceProxyHosts: [String] { runtime.routing.forceProxyHosts }
    var dohProviders: [PrivateURLValue] { runtime.dns.dohProviders }
    var dnsEntries: [PrivateDNSEntrySettings] { runtime.dns.entries }
    var interceptRules: [PrivateInterceptRuleSettings] { runtime.dns.interceptRules }
    var transparentProxyIP: String { runtime.dns.transparentProxyIP }
    var tunnelDefinitions: [PrivateTunnelDefinitionSettings] { runtime.tunnels.definitions }
    var checkURLByteCount: Int { runtime.health.checkURL.byteCount }
    var auditLogPath: String? { runtime.logging.auditLogPath }

    static func upstreamName(_ upstream: PrivateUpstreamSettings) -> String { upstream.name }
    static func upstreamHost(_ upstream: PrivateUpstreamSettings) -> String { upstream.host }
    static func providerByteCount(_ provider: PrivateURLValue) -> Int { provider.byteCount }
    static func entryDomain(_ entry: PrivateDNSEntrySettings) -> String { entry.domain }
    static func entryServers(_ entry: PrivateDNSEntrySettings) -> [String] { entry.servers }
    static func interceptPattern(_ rule: PrivateInterceptRuleSettings) -> String { rule.pattern }
    static func interceptAddress(_ rule: PrivateInterceptRuleSettings) -> String { rule.interceptIP }
    static func tunnelRemoteHost(_ tunnel: PrivateTunnelDefinitionSettings) -> String { tunnel.remoteHost }
    static func tunnelLabel(_ tunnel: PrivateTunnelDefinitionSettings) -> String { tunnel.label }
}
