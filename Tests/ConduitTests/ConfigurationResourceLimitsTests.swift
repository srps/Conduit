// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared
@testable import ProxyControlBridge
@testable import ProxyKernel

// Fixture builders at file scope, so the static place table and the instance tests both call them.

private func upstream(name: String = "u", host: String = "p.example.test") -> UpstreamProxy {
    UpstreamProxy(id: UUID(), name: name, host: host, port: 8_080, enabled: true, priority: 0)
}

private func tunnel(remoteHost: String = "db.example.test", label: String = "t") -> TunnelDefinition {
    TunnelDefinition(
        id: UUID(), localPort: 1_521, remoteHost: remoteHost, remotePort: 1_521,
        enabled: false, proxied: false, label: label, preset: nil
    )
}

private func entry(domain: String = "example.test", servers: [String] = []) -> DomainDNSEntry {
    DomainDNSEntry(id: UUID(), domain: domain, servers: servers, enabled: false)
}

private func rule(pattern: String = "", address: String = "") -> DNSInterceptRule {
    DNSInterceptRule(id: UUID(), pattern: pattern, interceptIP: address, enabled: false)
}

/// The approved configuration resource ceilings (decisions 0021 and 0022), checked field by field. Each place
/// is checked at its exact value and one byte over, in the kernel's typed check (over `ProxyConfig`) and in the
/// scanner's byte pass (over raw bodies). The reference is a literal table of the decision values, so a changed
/// production ceiling fails here rather than being read back from itself.
final class ConfigurationResourceLimitsTests: XCTestCase {
    private struct Failure: Error {
        let message: String
    }

    /// The decision values, written out by hand.
    private static let decisionValues: [DomainResourceField: Int] = [
        .upstreams: 32, .tunnelDefinitions: 128, .dnsEntries: 256, .dnsServers: 8, .interceptRules: 256,
        .allowedClients: 256, .forceProxyHosts: 256, .noProxyHosts: 256, .dohProviders: 8,
        .profileName: 1_024, .upstreamName: 1_024, .tunnelLabel: 1_024,
        .authUsername: 1_024, .authDomain: 1_024, .authWorkstation: 1_024,
        .auditLogPath: 1_023,
        .proxyHost: 253, .upstreamHost: 253, .tunnelRemoteHost: 253, .dnsDomain: 253, .dnsServer: 253,
        .interceptAddress: 253, .transparentProxyIP: 253, .allowedClient: 253, .forceProxyPattern: 253,
        .noProxyPattern: 253, .interceptPattern: 253,
        .pacURL: 16_384, .checkURL: 16_384, .dohProvider: 16_384, .browserTestURL: 16_384,
        .token: 64, .noProxyList: 8_192,
    ]

    // MARK: - Policy

    func testEveryFieldCarriesItsDecisionCeiling() {
        XCTAssertEqual(Set(Self.decisionValues.keys), Set(DomainResourceField.allCases))
        for field in DomainResourceField.allCases {
            XCTAssertEqual(field.limit, Self.decisionValues[field], "\(field)")
        }
    }

    /// Only the approved wildcard prefix earns the larger ceiling. The prefix's two bytes are part of the value.
    func testWildcardPrefixIsPartOfTheValueAndOnlyItEarnsTheLargerCeiling() throws {
        XCTAssertEqual(DomainResourceField.interceptPattern.utf8Limit(wildcardPrefix: true), 255)
        XCTAssertEqual(DomainResourceField.interceptPattern.utf8Limit(wildcardPrefix: false), 253)
        let wildcard = "*." + String(repeating: "a", count: 253)
        XCTAssertNil(kernelViolation { $0.dns.interceptRules = [rule(pattern: wildcard)] })
        let longer = "*." + String(repeating: "a", count: 254)
        XCTAssertEqual(
            kernelViolation { $0.dns.interceptRules = [rule(pattern: longer)] },
            DomainResourceViolation(.interceptPattern, 255)
        )
        // A star without a dot is an ordinary pattern, and it gets the ordinary ceiling.
        let star = "*a" + String(repeating: "a", count: 252)
        XCTAssertEqual(
            kernelViolation { $0.dns.interceptRules = [rule(pattern: star)] },
            DomainResourceViolation(.interceptPattern, 253)
        )
    }

    // MARK: - Kernel check, every string place

    /// Each place is set on a fixture config. The exact value is accepted, and one byte more is refused for that
    /// place and ceiling. Values are ASCII here; the multibyte and escaped cases follow.
    func testKernelCheckAcceptsExactAndRefusesOneOverForEveryStringPlace() throws {
        for place in Self.stringPlaces {
            let limit = place.field.utf8Limit(wildcardPrefix: place.prefix.hasPrefix("*."))
            let exact = place.prefix + String(repeating: "a", count: limit - place.prefix.utf8.count)
            XCTAssertNil(kernelViolation { place.set(&$0, exact) }, "\(place.field) exact")
            XCTAssertEqual(
                kernelViolation { place.set(&$0, exact + "a") },
                DomainResourceViolation(place.field, limit),
                "\(place.field) one over"
            )
        }
    }

    /// The list ceilings are on the count. Zero-byte items count, so 257 empty bypass entries are refused.
    func testKernelCheckCountsEveryListIncludingZeroByteItems() throws {
        XCTAssertNil(kernelViolation { $0.routing.noProxyHosts = Array(repeating: "", count: 256) })
        XCTAssertEqual(
            kernelViolation { $0.routing.noProxyHosts = Array(repeating: "", count: 257) },
            DomainResourceViolation(.noProxyHosts, 256)
        )
        XCTAssertEqual(
            kernelViolation { $0.proxy.allowedClients = Array(repeating: "", count: 257) },
            DomainResourceViolation(.allowedClients, 256)
        )
        XCTAssertEqual(
            kernelViolation { $0.routing.forceProxyHosts = Array(repeating: "", count: 257) },
            DomainResourceViolation(.forceProxyHosts, 256)
        )
        XCTAssertEqual(
            kernelViolation { $0.dns.dohProviders = Array(repeating: "", count: 9) },
            DomainResourceViolation(.dohProviders, 8)
        )
        XCTAssertEqual(
            kernelViolation { $0.upstreams = Array(repeating: upstream(), count: 33) },
            DomainResourceViolation(.upstreams, 32)
        )
        XCTAssertEqual(
            kernelViolation { $0.tunnels.definitions = Array(repeating: tunnel(), count: 129) },
            DomainResourceViolation(.tunnelDefinitions, 128)
        )
        XCTAssertEqual(
            kernelViolation { $0.dns.entries = Array(repeating: entry(servers: []), count: 257) },
            DomainResourceViolation(.dnsEntries, 256)
        )
        XCTAssertEqual(
            kernelViolation { $0.dns.entries = [entry(servers: Array(repeating: "", count: 9))] },
            DomainResourceViolation(.dnsServers, 8)
        )
        XCTAssertEqual(
            kernelViolation { $0.dns.interceptRules = Array(repeating: rule(pattern: ""), count: 257) },
            DomainResourceViolation(.interceptRules, 256)
        )
    }

    /// The bytes of a multibyte or escaped value are the bytes it decodes to: 512 two-byte letters are exactly 1,024.
    func testKernelCheckCountsMultibyteBytesNotCharacters() throws {
        let exact = String(repeating: "é", count: 512)
        XCTAssertNil(kernelViolation { $0.profileName = exact })
        XCTAssertEqual(
            kernelViolation { $0.profileName = exact + "a" },
            DomainResourceViolation(.profileName, 1_024)
        )
        let emoji = String(repeating: "🙂", count: 256)
        XCTAssertNil(kernelViolation { $0.profileName = emoji })
        XCTAssertEqual(
            kernelViolation { $0.profileName = emoji + "a" },
            DomainResourceViolation(.profileName, 1_024)
        )
    }

    /// The bridge refuses a one-over value before validation and mapping, with the same field and ceiling.
    func testBridgeRefusesOneOverBeforeValidationWithTheSameViolation() throws {
        var config = ProxyConfig.testFixture()
        config.profileName = String(repeating: "a", count: 1_025)
        XCTAssertThrowsError(try makeRequest(config)) {
            XCTAssertEqual($0 as? PrivateConfigurationBridgeError, .resourceLimit(DomainResourceViolation(.profileName, 1_024)))
        }
    }

    // MARK: - Scanner, every string place, raw bodies

    /// Each scanner place is a placeholder in one sample request. Its exact value replaces the placeholder in
    /// the body text, which is then decoded with no encoder involved. One byte over must be refused as that
    /// place's ceiling, which only the scanner can do before Foundation runs.
    func testScannerAcceptsExactAndRefusesOneOverForEveryStringPlace() throws {
        let base = try bodyText(placeholderRequest())
        for place in Self.stringPlaces {
            let limit = place.field.utf8Limit(wildcardPrefix: place.prefix.hasPrefix("*."))
            let exact = place.prefix + String(repeating: "a", count: limit - place.prefix.utf8.count)
            let exactText = base.replacingOccurrences(of: "\"\(place.placeholder)\"", with: "\"\(exact)\"")
            XCTAssertNoThrow(try decodeText(exactText), "\(place.field) exact")

            let overText = base.replacingOccurrences(of: "\"\(place.placeholder)\"", with: "\"\(exact)a\"")
            XCTAssertEqual(refusal(overText), .resourceLimitExceeded(DomainResourceViolation(place.field, limit)), "\(place.field)")
        }
    }

    /// The scanner counts decoded bytes: `\u00e9` is two bytes, so 512 escapes are exactly 1,024 and one more is not.
    func testScannerCountsEscapesByTheBytesTheyDecodeTo() throws {
        let base = try bodyText(placeholderRequest())
        let escaped = String(repeating: "\\u00e9", count: 512)
        XCTAssertNoThrow(try decodeText(base.replacingOccurrences(of: "\"x-profileName\"", with: "\"\(escaped)\"")))
        XCTAssertEqual(
            refusal(base.replacingOccurrences(of: "\"x-profileName\"", with: "\"\(escaped)a\"")),
            .resourceLimitExceeded(DomainResourceViolation(.profileName, 1_024))
        )
    }

    /// A list at its count decodes. One item more is refused by count, even when every item is empty.
    func testScannerRefusesOneMoreListItemByCount() throws {
        let base = try bodyText(placeholderRequest())
        let cases: [(key: String, element: String, field: DomainResourceField, limit: Int)] = [
            ("noProxyHosts", "\"a\"", .noProxyHosts, 256),
            ("forceProxyHosts", "\"a\"", .forceProxyHosts, 256),
            ("allowedClients", "\"\"", .allowedClients, 256),
            ("dohProviders", "\"\"", .dohProviders, 8),
            ("servers", "\"\"", .dnsServers, 8),
        ]
        for item in cases {
            let atCount = try replacingArray(base, key: item.key, elements: Array(repeating: item.element, count: item.limit))
            XCTAssertNoThrow(try decodeText(atCount), item.key)
            let overCount = try replacingArray(base, key: item.key, elements: Array(repeating: item.element, count: item.limit + 1))
            XCTAssertEqual(refusal(overCount), .resourceLimitExceeded(DomainResourceViolation(item.field, item.limit)), item.key)
        }
    }

    /// An object list is counted the same way. Each list is repeated at its ceiling, which decodes, and one more
    /// item, which is refused by count before the extra object is read.
    func testScannerRefusesOneMoreObjectItemByCount() throws {
        let base = try bodyText(placeholderRequest())
        let cases: [(key: String, field: DomainResourceField, limit: Int)] = [
            ("upstreams", .upstreams, 32),
            ("definitions", .tunnelDefinitions, 128),
            ("entries", .dnsEntries, 256),
            ("interceptRules", .interceptRules, 256),
        ]
        for item in cases {
            let element = try arrayElements(base, key: item.key)
            let atCount = try replacingArray(base, key: item.key, elements: Array(repeating: element, count: item.limit))
            XCTAssertNoThrow(try decodeText(atCount), item.key)
            let overCount = try replacingArray(base, key: item.key, elements: Array(repeating: element, count: item.limit + 1))
            XCTAssertEqual(refusal(overCount), .resourceLimitExceeded(DomainResourceViolation(item.field, item.limit)), item.key)
        }
    }

    // MARK: - Ordering and refusal kinds

    /// A malformed value after the ceiling is refused as the ceiling: the scanner stopped before reading it.
    func testMalformedValueAfterTheCeilingIsRefusedAsTheCeiling() throws {
        let base = try bodyText(placeholderRequest())
        let text = try replacingArray(
            base,
            key: "dohProviders",
            elements: ["\"\"", "\"\"", "\"\"", "\"\"", "\"\"", "\"\"", "\"\"", "\"\"", "@"]
        )
        XCTAssertEqual(refusal(text), .resourceLimitExceeded(DomainResourceViolation(.dohProviders, 8)))
    }

    /// An unknown key is refused at its name, so a huge or malformed value under it is never read.
    func testUnknownKeyIsRefusedAsMalformedBeforeItsValue() throws {
        let base = try bodyText(placeholderRequest())
        let unknown = base.replacingOccurrences(of: "\"strictMode\":false", with: "\"strictMode\":false,\"zz\":[@]")
        XCTAssertEqual(refusal(unknown), .malformedBody)
    }

    /// A repeated key is a duplicate even when one spelling uses an escape.
    func testEscapedDuplicateKeyIsRefused() throws {
        let base = try bodyText(placeholderRequest())
        let duplicate = base.replacingOccurrences(of: "\"strictMode\":false", with: "\"\\u0073trictMode\":true,\"strictMode\":false")
        XCTAssertEqual(refusal(duplicate), .malformedBody)
    }

    /// A raw DTO past a ceiling is refused by the encoder before any frame is written.
    func testEncoderRefusesAnOverlimitDTOBeforeWritingAFrame() throws {
        var request = try PrivateConfigSamples.request()
        request.runtime.routing.noProxyHosts = Array(repeating: "", count: 257)
        XCTAssertThrowsError(try PrivateConfigurationEncoder.encode(request)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .resourceLimitExceeded(DomainResourceViolation(.noProxyHosts, 256)))
        }
    }

    // MARK: - The encoded bypass list

    /// The bypass list's canonical JSON width is its own ceiling. 31 items of 253 bytes and one of 252 encode to exactly
    /// 8,192 bytes, and one byte more is refused. This is the typed check's view. The scanner charges the same width
    /// while it reads the body, and `ConfigurationResourceCanonicalWidthTests` pins the wire side at the same boundary.
    func testEncodedBypassListAtExactlyItsCeilingIsAcceptedAndOneMoreRefused() throws {
        var request = try PrivateConfigSamples.request()
        let full = String(repeating: "a", count: 253)
        request.runtime.routing.noProxyHosts = Array(repeating: full, count: 31) + [String(repeating: "a", count: 252)]
        XCTAssertEqual(try JSONEncoder().encode(request.runtime.routing.noProxyHosts).count, 8_192)
        XCTAssertNil(request.resourceViolation())

        request.runtime.routing.noProxyHosts = Array(repeating: full, count: 31) + [full]
        XCTAssertEqual(request.resourceViolation(), DomainResourceViolation(.noProxyList, 8_192))
    }

    // MARK: - Fixtures

    private struct StringPlace: Sendable {
        let field: DomainResourceField
        /// The placeholder token in the sample request's body, which the exact value replaces.
        let placeholder: String
        /// What every value of this place starts with, so a wildcard pattern keeps its prefix.
        let prefix: String
        let set: @Sendable (inout ProxyConfig, String) -> Void
    }

    private static let stringPlaces: [StringPlace] = [
        StringPlace(field: .profileName, placeholder: "x-profileName", prefix: "", set: { $0.profileName = $1 }),
        StringPlace(field: .authUsername, placeholder: "x-authUsername", prefix: "", set: { $0.auth.username = $1 }),
        StringPlace(field: .authDomain, placeholder: "x-authDomain", prefix: "", set: { $0.auth.domain = $1 }),
        StringPlace(field: .authWorkstation, placeholder: "x-authWorkstation", prefix: "", set: { $0.auth.workstation = $1 }),
        StringPlace(field: .auditLogPath, placeholder: "x-auditLogPath", prefix: "/", set: { $0.logging.auditLogPath = $1 }),
        StringPlace(field: .proxyHost, placeholder: "x-proxyHost", prefix: "", set: { $0.proxy.host = $1 }),
        StringPlace(field: .upstreamName, placeholder: "x-upstreamName", prefix: "", set: { $0.upstreams = [upstream(name: $1)] }),
        StringPlace(field: .upstreamHost, placeholder: "x-upstreamHost", prefix: "", set: { $0.upstreams = [upstream(host: $1)] }),
        StringPlace(field: .tunnelRemoteHost, placeholder: "x-tunnelRemoteHost", prefix: "", set: { $0.tunnels.definitions = [tunnel(remoteHost: $1)] }),
        StringPlace(field: .tunnelLabel, placeholder: "x-tunnelLabel", prefix: "", set: { $0.tunnels.definitions = [tunnel(label: $1)] }),
        StringPlace(field: .dnsDomain, placeholder: "x-dnsDomain", prefix: "", set: { $0.dns.entries = [entry(domain: $1)] }),
        StringPlace(field: .dnsServer, placeholder: "x-dnsServer", prefix: "", set: { $0.dns.entries = [entry(servers: [$1])] }),
        StringPlace(field: .interceptPattern, placeholder: "x-interceptPattern", prefix: "*.", set: { $0.dns.interceptRules = [rule(pattern: $1)] }),
        StringPlace(field: .interceptAddress, placeholder: "x-interceptAddress", prefix: "", set: { $0.dns.interceptRules = [rule(address: $1)] }),
        StringPlace(field: .transparentProxyIP, placeholder: "x-transparentProxyIP", prefix: "", set: { $0.dns.transparentProxyIP = $1 }),
        StringPlace(field: .allowedClient, placeholder: "x-allowedClient", prefix: "", set: { $0.proxy.allowedClients = [$1] }),
        StringPlace(field: .forceProxyPattern, placeholder: "x-forceProxyPattern", prefix: "", set: { $0.routing.forceProxyHosts = [$1] }),
        StringPlace(field: .noProxyPattern, placeholder: "x-noProxyPattern", prefix: "", set: { $0.routing.noProxyHosts = [$1] }),
        StringPlace(field: .pacURL, placeholder: "x-pacURL", prefix: "https://", set: { $0.routing.pacURL = $1 }),
        StringPlace(field: .checkURL, placeholder: "x-checkURL", prefix: "https://", set: { $0.health.checkURL = $1 }),
        StringPlace(field: .dohProvider, placeholder: "x-dohProvider", prefix: "https://", set: { $0.dns.dohProviders = [$1] }),
    ]

    /// Runs the kernel's check on the fixture after `mutate`.
    private func kernelViolation(_ mutate: (inout ProxyConfig) -> Void) -> DomainResourceViolation? {
        var config = ProxyConfig.testFixture()
        mutate(&config)
        return config.resourceViolation()
    }

    private func makeRequest(_ config: ProxyConfig) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationBridge.makeRequest(
            config: config,
            platform: PlatformIntegrationConfig(manageSystemProxy: true, systemProxyMode: .pac, launchAtLogin: true),
            requestID: ControlRequestID(rawValue: PrivateConfigSamples.uuid(101)),
            incarnation: ControlHostIncarnation(rawValue: PrivateConfigSamples.uuid(102)),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 7)),
            expectedPlatformRevision: try XCTUnwrap(PrivatePlatformRevision(rawValue: 6)),
            expectedOwnerGeneration: try XCTUnwrap(PrivateConfigExpectedGeneration(rawValue: 5))
        )
    }

    /// A sample request whose every placeholder is a unique `x-` token, and whose every list has one item.
    private func placeholderRequest() throws -> PrivateConfigurationRequest {
        var request = try PrivateConfigSamples.request()
        request.runtime.profileName = "x-profileName"
        request.runtime.proxy.host = "x-proxyHost"
        request.runtime.proxy.allowedClients = ["x-allowedClient"]
        request.runtime.auth.username = "x-authUsername"
        request.runtime.auth.domain = "x-authDomain"
        request.runtime.auth.workstation = "x-authWorkstation"
        request.runtime.upstreams = [
            PrivateUpstreamSettings(
                id: ControlUpstreamID(rawValue: PrivateConfigSamples.uuid(301)), name: "x-upstreamName",
                host: "x-upstreamHost", port: 8_080, enabled: true, priority: 1
            ),
        ]
        request.runtime.routing.pacURL = PrivateURLValue("x-pacURL")
        request.runtime.routing.noProxyHosts = ["x-noProxyPattern"]
        request.runtime.routing.forceProxyHosts = ["x-forceProxyPattern"]
        request.runtime.dns.dohProviders = [PrivateURLValue("x-dohProvider")]
        request.runtime.dns.entries = [
            PrivateDNSEntrySettings(
                id: PrivateDNSEntryID(rawValue: PrivateConfigSamples.uuid(302)), domain: "x-dnsDomain",
                servers: ["x-dnsServer"], enabled: true
            ),
        ]
        request.runtime.dns.interceptRules = [
            PrivateInterceptRuleSettings(
                id: PrivateInterceptRuleID(rawValue: PrivateConfigSamples.uuid(303)), pattern: "x-interceptPattern",
                interceptIP: "x-interceptAddress", enabled: true
            ),
        ]
        request.runtime.dns.transparentProxyIP = "x-transparentProxyIP"
        request.runtime.tunnels.definitions = [
            PrivateTunnelDefinitionSettings(
                id: ControlTunnelID(rawValue: PrivateConfigSamples.uuid(304)), localPort: 1_521,
                remoteHost: "x-tunnelRemoteHost", remotePort: 1_521, enabled: true, proxied: false,
                label: "x-tunnelLabel", preset: nil
            ),
        ]
        request.runtime.health.checkURL = PrivateURLValue("x-checkURL")
        request.runtime.logging.auditLogPath = "x-auditLogPath"
        request.runtime.proxy.strictMode = false
        return request
    }

    /// The body text of a request: its JSON, without the header and terminator.
    private func bodyText(_ request: PrivateConfigurationRequest) throws -> String {
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        return String(decoding: frame[start..<(frame.count - 1)], as: UTF8.self)
    }

    private func decodeText(_ text: String) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(bytes: SecretBytes(Array(text.utf8))))
    }

    /// The wire error a body is refused with, or nil when it decodes.
    private func refusal(_ text: String) -> PrivateConfigurationWireError? {
        do {
            _ = try decodeText(text)
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }

    /// The text between `[` and `]` of the array under `key`, for one element.
    private func arrayElements(_ text: String, key: String) throws -> String {
        let (open, close) = try arrayBounds(text, key: key)
        return String(text[open..<close])
    }

    /// Replaces the elements of the array under `key`. Brackets inside values do not occur in these bodies.
    private func replacingArray(_ text: String, key: String, elements: [String]) throws -> String {
        let (open, close) = try arrayBounds(text, key: key)
        var copy = text
        copy.replaceSubrange(open..<close, with: elements.joined(separator: ","))
        return copy
    }

    /// The bounds of the array's contents: just after its `[` and just before its matching `]`.
    private func arrayBounds(_ text: String, key: String) throws -> (String.Index, String.Index) {
        let open = try XCTUnwrap(text.range(of: "\"\(key)\":[")).upperBound
        var depth = 1
        var index = open
        while depth > 0 {
            guard index < text.endIndex else {
                throw Failure(message: "the array under \(key) is not closed")
            }
            if text[index] == "[" {
                depth += 1
            } else if text[index] == "]" {
                depth -= 1
            }
            index = text.index(after: index)
        }
        return (open, text.index(before: index))
    }
}
