// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

// The widest editor reply the approved ceilings allow (decisions 0021, 0022 and 0034). It is pure: it imports only
// `ConduitShared`, through `package` access, with no XCTest and no `@testable`. The unit tests compile it in the test
// target, and a standalone Release probe can compile the same file with `-package-name conduit` against the release
// modules, so the maximum is defined once.
//
// Every count is at its ceiling and every bounded text is at its UTF-8 ceiling, taken from `DomainResourceField`, never
// restated. Each text byte is a control character the wire writes as a six-byte `\u00XX` escape, the widest spelling,
// except the `*.` prefix a wildcard intercept pattern needs. The bypass list lands exactly on its canonical aggregate.
// Numbers take their widest spelling (`Int.min`, a 24-byte double, `UInt64.max`), Booleans are `false`, every nullable
// value is present, and every enumeration takes its longest raw value. This is a wire-width maximum, not a claim that
// the store would accept these values.

enum PrivateEditorMaximumFixture {
    struct Failure: Error {}

    /// The longest Swift spelling of a finite `Double` observed: 24 bytes.
    static let widestDouble = -2.2250738585072014e-308
    static let widestInt = Int.min

    /// The reply that carries the maximum observation. `distinct` makes every text unique without changing its width.
    static func reply(distinct: Bool) throws -> PrivateEditorReply {
        PrivateEditorReply(
            requestID: ControlRequestID(rawValue: uuid(1)),
            hostIncarnation: ControlHostIncarnation(rawValue: uuid(2)),
            answer: .observation(try observation(distinct: distinct))
        )
    }

    static func observation(distinct: Bool) throws -> PrivateEditorObservation {
        var texts = TextSource(distinct: distinct)
        let namespace = PrivateBaselineNamespace(rawValue: uuid(3))
        guard let revision = ControlLifecycleRevision(rawValue: Int.max) else { throw Failure() }
        let module = PrivateModuleState(lifecycleRevision: revision, enabled: false, fenced: false)
        return try PrivateEditorObservation(
            terminal: false,
            runtime: runtime(&texts),
            platform: PrivatePlatformConfiguration(
                manageSystemProxy: false, manageEnvironmentVariables: false, manageDNSResolvers: false,
                manageSystemDNS: false, systemProxyMode: longest(PrivateSystemProxyMode.allCases)
            ),
            preferences: PrivatePreferences(
                showMenuBarIcon: false, floatingWindowEnabled: false, globalShortcutEnabled: false,
                preferredBrowserTestURL: PrivateURLValue(texts.next(.browserTestURL)),
                fileLoggingEnabled: false, automaticUpdateChecks: false
            ),
            launchAtLogin: false,
            components: PrivateComponentSlots(
                runtime: .verified(PrivateBaseline(namespace: namespace, component: .runtime, version: .max)),
                platform: .verified(PrivateBaseline(namespace: namespace, component: .platform, version: .max)),
                preferences: .verified(PrivateBaseline(namespace: namespace, component: .preferences, version: .max))
            ),
            modules: PrivateModuleSlots(proxy: module, dns: module, tunnels: module)
        )
    }

    /// The bypass list at its count, with its canonical JSON width exactly at the aggregate ceiling. Each item takes as
    /// many six-byte escapes as fit, and the remainder below six is spent on one-byte ASCII.
    static func noProxyHosts(_ texts: inout TextSource) -> [String] {
        let count = DomainResourceField.noProxyHosts.limit
        let itemLimit = DomainResourceField.noProxyPattern.limit
        let control = CanonicalJSONWidth.quotedWidth("\u{01}") - 2
        // Brackets, separators and each item's quotes, before any item content.
        var budget = DomainResourceField.noProxyList.limit - 2 - (count - 1) - CanonicalJSONWidth.quotedWidth("") * count
        var ascii = budget % control
        budget /= control
        return (0..<count).map { _ in
            let escapes = min(budget, itemLimit)
            budget -= escapes
            let plain = min(ascii, itemLimit - escapes)
            ascii -= plain
            return texts.next(length: escapes) + String(repeating: "a", count: plain)
        }
    }

    // MARK: - Runtime

    private static func runtime(_ texts: inout TextSource) -> PrivateRuntimeConfiguration {
        let entryCount = DomainResourceField.dnsEntries.limit
        let serverCount = DomainResourceField.dnsServers.limit
        let wildcard = DomainResourceField.interceptPattern.utf8Limit(wildcardPrefix: true) - 2
        return PrivateRuntimeConfiguration(
            profileName: texts.next(.profileName),
            proxy: PrivateProxySettings(
                host: texts.next(.proxyHost), port: widestInt, socksEnabled: false, socksPort: widestInt,
                gatewayMode: false, allowedClients: texts.list(.allowedClients, .allowedClient),
                maxConnections: widestInt, stalledConnectionTimeoutSeconds: widestDouble,
                maxBufferedBodyBytes: widestInt, maxSpooledBodyBytes: widestInt,
                inboundConnectionWarnThreshold: widestInt, inboundConnectionMaxLimit: widestInt, strictMode: false
            ),
            auth: PrivateAuthSettings(
                mode: longest(PrivateAuthenticationMode.allCases), username: texts.next(.authUsername),
                domain: texts.next(.authDomain), workstation: texts.next(.authWorkstation),
                pendingHandshakeGlobalLimit: widestInt, pendingHandshakesPerSource: widestInt
            ),
            upstreams: (0..<DomainResourceField.upstreams.limit).map { index in
                PrivateUpstreamSettings(
                    id: ControlUpstreamID(rawValue: uuid(1_000 + index)), name: texts.next(.upstreamName),
                    host: texts.next(.upstreamHost), port: widestInt, enabled: false, priority: widestInt
                )
            },
            routing: PrivateRoutingSettings(
                pacURL: PrivateURLValue(texts.next(.pacURL)), localPACEnabled: false, localPACPort: widestInt,
                pacRoutingEnabled: false, pacUsableRouteLimit: widestInt,
                noProxyHosts: noProxyHosts(&texts), forceProxyHosts: texts.list(.forceProxyHosts, .forceProxyPattern)
            ),
            dns: PrivateDNSSettings(
                forwarderEnabled: false, forwarderPort: widestInt,
                dohProviders: texts.list(.dohProviders, .dohProvider).map { PrivateURLValue($0) },
                entries: (0..<entryCount).map { index in
                    PrivateDNSEntrySettings(
                        id: PrivateDNSEntryID(rawValue: uuid(2_000 + index)), domain: texts.next(.dnsDomain),
                        servers: (0..<serverCount).map { _ in texts.next(.dnsServer) }, enabled: false
                    )
                },
                interceptRules: (0..<DomainResourceField.interceptRules.limit).map { index in
                    PrivateInterceptRuleSettings(
                        id: PrivateInterceptRuleID(rawValue: uuid(3_000 + index)),
                        pattern: "*." + texts.next(length: wildcard), interceptIP: texts.next(.interceptAddress),
                        enabled: false
                    )
                },
                transparentProxyEnabled: false, transparentProxyIP: texts.next(.transparentProxyIP),
                transparentProxyPort: widestInt
            ),
            tunnels: PrivateTunnelSettings(
                definitions: (0..<DomainResourceField.tunnelDefinitions.limit).map { index in
                    PrivateTunnelDefinitionSettings(
                        id: ControlTunnelID(rawValue: uuid(4_000 + index)), localPort: widestInt,
                        remoteHost: texts.next(.tunnelRemoteHost), remotePort: widestInt, enabled: false,
                        proxied: false, label: texts.next(.tunnelLabel), preset: longest(PrivateTunnelPreset.allCases)
                    )
                },
                maxSessions: widestInt, maxSessionsPerTunnel: widestInt
            ),
            health: PrivateHealthSettings(
                checkURL: PrivateURLValue(texts.next(.checkURL)), checkIntervalSeconds: widestDouble,
                connectionCheckTimeoutSeconds: widestDouble, upstreamResponseTimeoutSeconds: widestDouble,
                upstreamConnectTimeoutSeconds: widestDouble, directConnectTTLSeconds: widestDouble,
                circuitBreakerWindowSeconds: widestDouble, circuitFailureThreshold: widestInt,
                circuitBaseOpenIntervalSeconds: widestDouble, circuitMaxOpenIntervalSeconds: widestDouble,
                vpnFlapGraceSeconds: widestDouble, vpnFlapMinVisibleSeconds: widestDouble
            ),
            logging: PrivateLoggingSettings(
                verbose: false, auditLogEnabled: false, auditLogMaxBytes: widestInt,
                auditLogPath: texts.next(.auditLogPath)
            )
        )
    }

    // MARK: - Texts

    /// Texts of six-byte escapes only. A distinct source starts each text with a tag of up to four characters drawn from
    /// the 26 controls U+0001 to U+001F that have no short escape, so texts of four or more bytes differ and no wire
    /// width changes.
    struct TextSource {
        private static let escapeOnly: [Unicode.Scalar] = (0x01...0x1F).compactMap { value in
            [0x08, 0x09, 0x0A, 0x0C, 0x0D].contains(value) ? nil : Unicode.Scalar(UInt8(value))
        }

        let distinct: Bool
        private var counter = 0

        init(distinct: Bool) {
            self.distinct = distinct
        }

        mutating func next(_ field: DomainResourceField) -> String {
            next(length: field.limit)
        }

        mutating func next(length: Int) -> String {
            var scalars = String.UnicodeScalarView()
            if distinct {
                var rest = counter
                counter += 1
                for _ in 0..<min(4, length) {
                    scalars.append(Self.escapeOnly[rest % Self.escapeOnly.count])
                    rest /= Self.escapeOnly.count
                }
            }
            while scalars.count < length {
                scalars.append(Self.escapeOnly[0])
            }
            return String(scalars)
        }

        mutating func list(_ count: DomainResourceField, _ item: DomainResourceField) -> [String] {
            (0..<count.limit).map { _ in next(item) }
        }
    }

    private static func longest<Value: RawRepresentable>(_ cases: [Value]) -> Value where Value.RawValue == String {
        cases.max { $0.rawValue.utf8.count < $1.rawValue.utf8.count }!
    }

    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }
}
