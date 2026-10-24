// SPDX-License-Identifier: Apache-2.0

// The typed resource walk (decision 0021). `ConfigurationResourceSource` is the resource-only surface a configuration
// exposes: its strings, arrays and URL byte counts, in whatever storage the source already has. The one traversal is
// `DomainResourceCheck.configuration(_:)` below. It owns the wire order, the count before any element, the per-item
// ceilings and the aggregate. A source contributes representation only: no field limit, no violation, no loop and no
// order. The kernel and the private request each conform through a small adapter, so neither repeats the walk.
//
// The private scanner does not use this traversal. It reads arbitrary input order and refuses before decode, and it
// shares only `DomainResourceField` and the counters in `DomainResourceCheck`.

/// The resource view of one configuration. Requirements return the stored values: `String` and `Array` are Swift value
/// types with shared copy-on-write backing, and a scalar or small struct may be copied. The contract is narrower than
/// "no copies": the traversal never builds a new array with `map`, never encodes a value just to measure it, and never
/// reveals URL text, only its UTF-8 byte count. Element accessors return one field each.
package protocol ConfigurationResourceSource {
    associatedtype Upstream
    associatedtype Provider
    associatedtype DNSEntry
    associatedtype InterceptRule
    associatedtype Tunnel

    var profileName: String { get }
    var proxyHost: String { get }
    var allowedClients: [String] { get }
    var authUsername: String { get }
    var authDomain: String { get }
    var authWorkstation: String { get }
    var upstreams: [Upstream] { get }
    /// The UTF-8 byte count of the PAC URL. A private URL reports its count and never its bytes.
    var pacURLByteCount: Int { get }
    var noProxyHosts: [String] { get }
    var forceProxyHosts: [String] { get }
    var dohProviders: [Provider] { get }
    var dnsEntries: [DNSEntry] { get }
    var interceptRules: [InterceptRule] { get }
    var transparentProxyIP: String { get }
    var tunnelDefinitions: [Tunnel] { get }
    /// The UTF-8 byte count of the health check URL.
    var checkURLByteCount: Int { get }
    var auditLogPath: String? { get }

    static func upstreamName(_ upstream: Upstream) -> String
    static func upstreamHost(_ upstream: Upstream) -> String
    static func providerByteCount(_ provider: Provider) -> Int
    static func entryDomain(_ entry: DNSEntry) -> String
    static func entryServers(_ entry: DNSEntry) -> [String]
    static func interceptPattern(_ rule: InterceptRule) -> String
    static func interceptAddress(_ rule: InterceptRule) -> String
    static func tunnelRemoteHost(_ tunnel: Tunnel) -> String
    static func tunnelLabel(_ tunnel: Tunnel) -> String
}

extension DomainResourceCheck {
    /// The first approved ceiling a configuration crosses, in wire order, or nil. This is the only traversal of the
    /// resource places. Each place is charged here with its own field, and every list is refused by its count before
    /// its first element is read.
    package static func configuration<Source: ConfigurationResourceSource>(_ source: Source) -> DomainResourceViolation? {
        if let violation = text(source.profileName, .profileName) {
            return violation
        }
        if let violation = text(source.proxyHost, .proxyHost) {
            return violation
        }
        if let violation = items(source.allowedClients, count: .allowedClients, each: { text($0, .allowedClient) }) {
            return violation
        }
        if let violation = text(source.authUsername, .authUsername) {
            return violation
        }
        if let violation = text(source.authDomain, .authDomain) {
            return violation
        }
        if let violation = text(source.authWorkstation, .authWorkstation) {
            return violation
        }
        if let violation = items(source.upstreams, count: .upstreams, each: { upstream in
            text(Source.upstreamName(upstream), .upstreamName) ?? text(Source.upstreamHost(upstream), .upstreamHost)
        }) {
            return violation
        }
        if let violation = utf8(source.pacURLByteCount, .pacURL) {
            return violation
        }
        if let violation = strings(
            source.noProxyHosts, count: .noProxyHosts, item: .noProxyPattern, encodedWithin: .noProxyList
        ) {
            return violation
        }
        if let violation = items(source.forceProxyHosts, count: .forceProxyHosts, each: { text($0, .forceProxyPattern) }) {
            return violation
        }
        if let violation = items(source.dohProviders, count: .dohProviders, each: {
            utf8(Source.providerByteCount($0), .dohProvider)
        }) {
            return violation
        }
        if let violation = items(source.dnsEntries, count: .dnsEntries, each: { entry in
            text(Source.entryDomain(entry), .dnsDomain)
                ?? items(Source.entryServers(entry), count: .dnsServers, each: { text($0, .dnsServer) })
        }) {
            return violation
        }
        if let violation = items(source.interceptRules, count: .interceptRules, each: { rule in
            text(Source.interceptPattern(rule), .interceptPattern) ?? text(Source.interceptAddress(rule), .interceptAddress)
        }) {
            return violation
        }
        if let violation = text(source.transparentProxyIP, .transparentProxyIP) {
            return violation
        }
        if let violation = items(source.tunnelDefinitions, count: .tunnelDefinitions, each: { tunnel in
            text(Source.tunnelRemoteHost(tunnel), .tunnelRemoteHost) ?? text(Source.tunnelLabel(tunnel), .tunnelLabel)
        }) {
            return violation
        }
        if let violation = utf8(source.checkURLByteCount, .checkURL) {
            return violation
        }
        return source.auditLogPath.flatMap { text($0, .auditLogPath) }
    }
}
