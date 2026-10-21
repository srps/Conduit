// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// `ConfigDiff.replacesListeners` decides which Settings edits wait for a
/// commit instead of the autosave pause. Every config field is classified
/// here by name, and the field list is read from the types, so a field
/// added later fails this test until someone says whether editing it
/// replaces a bound endpoint.
final class ConfigDiffListenerTests: XCTestCase {

    private struct Row {
        let replacesListeners: Bool
        let mutate: (inout ProxyConfig) -> Void
    }

    private static let tunnel = TunnelDefinition(localPort: 15432, remoteHost: "db.example.test", remotePort: 5432, label: "DB")

    private func fixture() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.tunnels.definitions = [Self.tunnel]
        return config
    }

    /// Field path to whether editing it alone replaces a listener.
    private let table: [String: Row] = [
        "schemaVersion": Row(replacesListeners: false) { $0.schemaVersion += 1 },
        "profileName": Row(replacesListeners: false) { $0.profileName += " edited" },

        "proxy.host": Row(replacesListeners: true) { $0.proxy.host = "127.0.0.2" },
        "proxy.port": Row(replacesListeners: true) { $0.proxy.port += 1 },
        "proxy.socksEnabled": Row(replacesListeners: true) { $0.proxy.socksEnabled.toggle() },
        "proxy.socksPort": Row(replacesListeners: true) { $0.proxy.socksPort += 1 },
        "proxy.gatewayMode": Row(replacesListeners: true) { $0.proxy.gatewayMode.toggle() },
        "proxy.allowedClients": Row(replacesListeners: false) { $0.proxy.allowedClients.append("10.0.0.9") },
        "proxy.maxConnections": Row(replacesListeners: false) { $0.proxy.maxConnections += 1 },
        "proxy.stalledConnectionTimeout": Row(replacesListeners: false) { $0.proxy.stalledConnectionTimeout += 1 },
        "proxy.maxBufferedBodyBytes": Row(replacesListeners: false) { $0.proxy.maxBufferedBodyBytes += 1 },
        "proxy.maxSpooledBodyBytes": Row(replacesListeners: false) { $0.proxy.maxSpooledBodyBytes += 1 },
        "proxy.inboundConnectionWarnThreshold": Row(replacesListeners: false) { $0.proxy.inboundConnectionWarnThreshold += 1 },
        "proxy.inboundConnectionMaxLimit": Row(replacesListeners: false) { $0.proxy.inboundConnectionMaxLimit += 1 },
        "proxy.strictMode": Row(replacesListeners: false) { $0.proxy.strictMode.toggle() },

        "auth.mode": Row(replacesListeners: false) { $0.auth.mode = $0.auth.mode == .ntlmv2 ? .systemNegotiated : .ntlmv2 },
        "auth.username": Row(replacesListeners: false) { $0.auth.username += "x" },
        "auth.domain": Row(replacesListeners: false) { $0.auth.domain += "x" },
        "auth.workstation": Row(replacesListeners: false) { $0.auth.workstation += "x" },
        "auth.pendingHandshakeGlobalLimit": Row(replacesListeners: false) { $0.auth.pendingHandshakeGlobalLimit += 1 },
        "auth.pendingHandshakesPerSource": Row(replacesListeners: false) { $0.auth.pendingHandshakesPerSource += 1 },

        "upstreams": Row(replacesListeners: false) {
            $0.upstreams.append(UpstreamProxy(name: "extra", host: "proxy2.example.test", port: 8080, priority: 9))
        },

        "routing.pacURL": Row(replacesListeners: false) { $0.routing.pacURL = "https://pac.example.test/proxy.pac" },
        "routing.localPACEnabled": Row(replacesListeners: true) { $0.routing.localPACEnabled.toggle() },
        "routing.localPACPort": Row(replacesListeners: true) { $0.routing.localPACPort += 1 },
        "routing.pacRoutingEnabled": Row(replacesListeners: false) { $0.routing.pacRoutingEnabled.toggle() },
        "routing.pacUsableRouteLimit": Row(replacesListeners: false) { $0.routing.pacUsableRouteLimit += 1 },
        "routing.noProxyHosts": Row(replacesListeners: false) { $0.routing.noProxyHosts.append("bypass.example.test") },
        "routing.forceProxyHosts": Row(replacesListeners: false) { $0.routing.forceProxyHosts.append("force.example.test") },

        "dns.forwarderEnabled": Row(replacesListeners: true) { $0.dns.forwarderEnabled.toggle() },
        "dns.forwarderPort": Row(replacesListeners: true) { $0.dns.forwarderPort += 1 },
        "dns.dohProviders": Row(replacesListeners: true) { $0.dns.dohProviders.removeLast() },
        "dns.entries": Row(replacesListeners: true) {
            $0.dns.entries.append(DomainDNSEntry(domain: "corp.example.test", servers: ["10.0.0.53"]))
        },
        "dns.interceptRules": Row(replacesListeners: true) {
            $0.dns.interceptRules.append(DNSInterceptRule(pattern: "*.intercept.example.test"))
        },
        "dns.transparentProxyEnabled": Row(replacesListeners: true) { $0.dns.transparentProxyEnabled.toggle() },
        "dns.transparentProxyIP": Row(replacesListeners: true) { $0.dns.transparentProxyIP = "127.44.3.9" },
        "dns.transparentProxyPort": Row(replacesListeners: true) { $0.dns.transparentProxyPort += 1 },

        "tunnels.maxSessions": Row(replacesListeners: false) { $0.tunnels.maxSessions += 1 },
        "tunnels.maxSessionsPerTunnel": Row(replacesListeners: false) { $0.tunnels.maxSessionsPerTunnel += 1 },
        "tunnels.definitions.id": Row(replacesListeners: true) { $0.tunnels.definitions[0].id = UUID() },
        "tunnels.definitions.localPort": Row(replacesListeners: true) { $0.tunnels.definitions[0].localPort += 1 },
        "tunnels.definitions.remoteHost": Row(replacesListeners: true) { $0.tunnels.definitions[0].remoteHost = "db2.example.test" },
        "tunnels.definitions.remotePort": Row(replacesListeners: true) { $0.tunnels.definitions[0].remotePort += 1 },
        "tunnels.definitions.enabled": Row(replacesListeners: true) { $0.tunnels.definitions[0].enabled.toggle() },
        "tunnels.definitions.proxied": Row(replacesListeners: true) { $0.tunnels.definitions[0].proxied.toggle() },
        "tunnels.definitions.label": Row(replacesListeners: false) { $0.tunnels.definitions[0].label = "Renamed" },
        "tunnels.definitions.preset": Row(replacesListeners: false) {
            $0.tunnels.definitions[0].preset = $0.tunnels.definitions[0].preset == nil ? TunnelPreset.allCases.first : nil
        },

        "health.checkURL": Row(replacesListeners: false) { $0.health.checkURL += "?edited" },
        "health.checkInterval": Row(replacesListeners: false) { $0.health.checkInterval += 1 },
        "health.connectionCheckTimeout": Row(replacesListeners: false) { $0.health.connectionCheckTimeout += 1 },
        "health.upstreamResponseTimeout": Row(replacesListeners: false) { $0.health.upstreamResponseTimeout += 1 },
        "health.upstreamConnectTimeout": Row(replacesListeners: false) { $0.health.upstreamConnectTimeout += 1 },
        "health.directConnectTTL": Row(replacesListeners: false) { $0.health.directConnectTTL += 1 },
        "health.circuitBreakerWindowSeconds": Row(replacesListeners: false) { $0.health.circuitBreakerWindowSeconds += 1 },
        "health.circuitFailureThreshold": Row(replacesListeners: false) { $0.health.circuitFailureThreshold += 1 },
        "health.circuitBaseOpenIntervalSeconds": Row(replacesListeners: false) { $0.health.circuitBaseOpenIntervalSeconds += 1 },
        "health.circuitMaxOpenIntervalSeconds": Row(replacesListeners: false) { $0.health.circuitMaxOpenIntervalSeconds += 1 },
        "health.vpnFlapGraceSeconds": Row(replacesListeners: false) { $0.health.vpnFlapGraceSeconds += 1 },
        "health.vpnFlapMinVisibleSeconds": Row(replacesListeners: false) { $0.health.vpnFlapMinVisibleSeconds += 1 },

        "logging.verbose": Row(replacesListeners: false) { $0.logging.verbose.toggle() },
        "logging.auditLogEnabled": Row(replacesListeners: false) { $0.logging.auditLogEnabled.toggle() },
        "logging.auditLogMaxBytes": Row(replacesListeners: false) { $0.logging.auditLogMaxBytes += 1 },
        "logging.auditLogPath": Row(replacesListeners: false) { $0.logging.auditLogPath = "/tmp/audit-edited.ndjson" },
    ]

    /// Stored properties by path, read from the types: a section's
    /// properties under its name, a tunnel definition's under
    /// `tunnels.definitions`, and every other property as itself.
    private func fieldPaths(of config: ProxyConfig) -> Set<String> {
        var paths: Set<String> = []
        for child in Mirror(reflecting: config).children {
            guard let name = child.label else { continue }
            let sectionFields = Mirror(reflecting: child.value).children.compactMap(\.label)
            let isSection = Mirror(reflecting: child.value).displayStyle == .struct
            guard isSection, !sectionFields.isEmpty else {
                paths.insert(name)
                continue
            }
            for field in sectionFields {
                if name == "tunnels", field == "definitions" {
                    for tunnelField in Mirror(reflecting: Self.tunnel).children.compactMap(\.label) {
                        paths.insert("tunnels.definitions.\(tunnelField)")
                    }
                } else {
                    paths.insert("\(name).\(field)")
                }
            }
        }
        return paths
    }

    func testEveryConfigFieldIsClassified() {
        let fields = fieldPaths(of: fixture())
        XCTAssertEqual(fields.subtracting(table.keys).sorted(), [],
                       "classify the new field in this table: does editing it start, stop or replace a bound endpoint?")
        XCTAssertEqual(Set(table.keys).subtracting(fields).sorted(), [], "a classified field no longer exists")
    }

    func testEachFieldReplacesListenersAsClassified() {
        let old = fixture()
        for (path, row) in table.sorted(by: { $0.key < $1.key }) {
            var new = old
            row.mutate(&new)
            XCTAssertNotEqual(old, new, "\(path): the mutation must change the config")
            XCTAssertEqual(ConfigDiff(old: old, new: new).replacesListeners, row.replacesListeners, path)
        }
    }

    func testRevertingToTheBaselineReplacesNothing() {
        let old = fixture()
        var new = old
        new.proxy.port += 1
        new.proxy.port -= 1
        XCTAssertFalse(ConfigDiff(old: old, new: new).replacesListeners)
    }

    func testTunnelAdditionsReplaceListenersOnlyWhenEnabled() {
        let old = fixture()
        var enabled = old
        enabled.tunnels.definitions.append(TunnelDefinition(localPort: 16379, remoteHost: "cache.example.test", remotePort: 6379))
        XCTAssertTrue(ConfigDiff(old: old, new: enabled).replacesListeners)

        var disabled = old
        disabled.tunnels.definitions.append(
            TunnelDefinition(localPort: 16379, remoteHost: "cache.example.test", remotePort: 6379, enabled: false))
        XCTAssertFalse(ConfigDiff(old: old, new: disabled).replacesListeners, "nothing binds for a disabled tunnel")

        var removed = old
        removed.tunnels.definitions.removeAll()
        XCTAssertTrue(ConfigDiff(old: old, new: removed).replacesListeners)
    }

    /// The DNS forwarder does not follow the listen host, so a host edit
    /// replaces the HTTP listener only.
    func testAListenHostEditLeavesDNSAlone() {
        var old = fixture()
        old.proxy.host = "127.0.0.1"
        var moved = old
        moved.proxy.host = "127.0.0.2"
        let diff = ConfigDiff(old: old, new: moved)
        XCTAssertFalse(diff.dnsChanged)
        XCTAssertTrue(diff.proxyListenerChanged)
        XCTAssertTrue(diff.replacesListeners)
    }
}
