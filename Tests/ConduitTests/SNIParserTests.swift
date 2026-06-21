// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import XCTest
@testable import ProxyKernel

final class SNIParserTests: XCTestCase {

    // MARK: - Valid ClientHello

    func testExtractsSNIFromMinimalClientHello() {
        let bytes = buildClientHello(hostname: "api2.cursor.sh")
        let result = SNIParser.extractSNI(from: bytes)
        XCTAssertEqual(result, "api2.cursor.sh")
    }

    func testExtractsSNIFromByteBuffer() {
        let bytes = buildClientHello(hostname: "example.com")
        var buf = ByteBuffer()
        buf.writeBytes(bytes)
        let result = SNIParser.extractSNI(from: buf)
        XCTAssertEqual(result, "example.com")
    }

    func testNormalizesToLowercase() {
        let bytes = buildClientHello(hostname: "API2.Cursor.SH")
        let result = SNIParser.extractSNI(from: bytes)
        XCTAssertEqual(result, "api2.cursor.sh")
    }

    func testLongSubdomain() {
        let host = "very-long-subdomain.nested.deep.cursor.sh"
        let bytes = buildClientHello(hostname: host)
        XCTAssertEqual(SNIParser.extractSNI(from: bytes), host)
    }

    func testMultipleExtensionsBeforeSNI() {
        let host = "multi-ext.example.com"
        let bytes = buildClientHelloWithExtraExtensions(hostname: host)
        XCTAssertEqual(SNIParser.extractSNI(from: bytes), host)
    }

    // MARK: - Invalid / Missing SNI

    func testReturnsNilForEmptyBuffer() {
        XCTAssertNil(SNIParser.extractSNI(from: [UInt8]()))
    }

    func testReturnsNilForTooShortBuffer() {
        XCTAssertNil(SNIParser.extractSNI(from: [0x16, 0x03, 0x01]))
    }

    func testReturnsNilForNonTLSContent() {
        var bytes = buildClientHello(hostname: "example.com")
        bytes[0] = 0x15
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testReturnsNilForNonHandshakeRecord() {
        var bytes = buildClientHello(hostname: "example.com")
        bytes[5] = 0x02
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testReturnsNilForTruncatedClientHello() {
        let bytes = buildClientHello(hostname: "example.com")
        let truncated = Array(bytes[0..<40])
        XCTAssertNil(SNIParser.extractSNI(from: truncated))
    }

    func testReturnsNilWhenNoSNIExtension() {
        let bytes = buildClientHelloNoSNI()
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRandomGarbageNeverProducesFalsePositiveSNI() {
        var generator = SeededByteGenerator(seed: 0xC0FFEE)

        for sample in 0..<2_000 {
            let length = Int(generator.nextByte()) + Int(generator.nextByte() % 2) * 256
            var bytes = (0..<length).map { _ in generator.nextByte() }

            // Bias part of the corpus toward TLS-looking prefixes so the
            // parser exercises deeper length/extension validation paths.
            if bytes.count >= 6, sample.isMultiple(of: 4) {
                bytes[0] = 0x16
                bytes[1] = 0x03
                bytes[2] = 0x03
                bytes[5] = 0x01
            }

            XCTAssertNil(SNIParser.extractSNI(from: bytes), "sample \(sample) unexpectedly parsed as SNI")
        }
    }

    // MARK: - Security: Hostname Validation

    func testRejectsHostnameWithoutDot() {
        let bytes = buildClientHello(hostname: "localhost")
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRejectsHostnameWithSpaces() {
        let bytes = buildClientHello(hostname: "bad host.com")
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRejectsHostnameWithUnderscore() {
        let bytes = buildClientHello(hostname: "bad_host.com")
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRejectsHostnameStartingWithDash() {
        let bytes = buildClientHello(hostname: "-invalid.com")
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRejectsHostnameEndingWithDash() {
        let bytes = buildClientHello(hostname: "invalid-.com")
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testAcceptsIPAddressAsSNI() {
        let bytes = buildClientHello(hostname: "127.0.0.1")
        let result = SNIParser.extractSNI(from: bytes)
        XCTAssertEqual(result, "127.0.0.1")
    }

    func testRejectsEmptyHostname() {
        let bytes = buildClientHelloWithEmptyHostname()
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRejectsOversizedHostname() {
        let longLabel = String(repeating: "a", count: 63)
        let host = "\(longLabel).\(longLabel).\(longLabel).\(longLabel)"
        XCTAssertTrue(host.count > 253)
        let bytes = buildClientHello(hostname: host)
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    // MARK: - TLS Version Variants

    func testAcceptsTLS10Version() {
        var bytes = buildClientHello(hostname: "tls10.example.com")
        bytes[2] = 0x01
        XCTAssertEqual(SNIParser.extractSNI(from: bytes), "tls10.example.com")
    }

    func testAcceptsTLS12Version() {
        var bytes = buildClientHello(hostname: "tls12.example.com")
        bytes[2] = 0x03
        XCTAssertEqual(SNIParser.extractSNI(from: bytes), "tls12.example.com")
    }

    func testRejectsTLS09Version() {
        var bytes = buildClientHello(hostname: "old.example.com")
        bytes[2] = 0x00
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    func testRejectsTLS05Version() {
        var bytes = buildClientHello(hostname: "future.example.com")
        bytes[2] = 0x05
        XCTAssertNil(SNIParser.extractSNI(from: bytes))
    }

    // MARK: - Builders

    private func buildClientHello(hostname: String) -> [UInt8] {
        let hostnameBytes = Array(hostname.utf8)
        let sniExtension = buildSNIExtension(hostnameBytes)
        let extensionsPayload = sniExtension
        return wrapInClientHello(extensions: extensionsPayload)
    }

    private func buildClientHelloWithExtraExtensions(hostname: String) -> [UInt8] {
        let hostnameBytes = Array(hostname.utf8)
        var extensions = [UInt8]()

        // ec_point_formats (type 0x000B)
        extensions += [0x00, 0x0B, 0x00, 0x02, 0x01, 0x00]
        // supported_groups (type 0x000A)
        extensions += [0x00, 0x0A, 0x00, 0x04, 0x00, 0x02, 0x00, 0x17]
        // SNI
        extensions += buildSNIExtension(hostnameBytes)

        return wrapInClientHello(extensions: extensions)
    }

    private func buildClientHelloNoSNI() -> [UInt8] {
        var extensions = [UInt8]()
        // ec_point_formats only
        extensions += [0x00, 0x0B, 0x00, 0x02, 0x01, 0x00]
        return wrapInClientHello(extensions: extensions)
    }

    private func buildClientHelloWithEmptyHostname() -> [UInt8] {
        var sniPayload = [UInt8]()
        // ServerNameList length = 3 (type + name_length)
        sniPayload += [0x00, 0x03]
        // name_type = 0x00 (host_name), name_length = 0
        sniPayload += [0x00, 0x00, 0x00]
        let ext: [UInt8] = [0x00, 0x00] + UInt16(sniPayload.count).beBytes + sniPayload
        return wrapInClientHello(extensions: ext)
    }

    private func buildSNIExtension(_ hostnameBytes: [UInt8]) -> [UInt8] {
        var sniPayload = [UInt8]()
        let nameLength = UInt16(hostnameBytes.count)
        let listLength = nameLength + 3
        sniPayload += listLength.beBytes
        sniPayload += [0x00] // name_type: host_name
        sniPayload += nameLength.beBytes
        sniPayload += hostnameBytes

        var ext = [UInt8]()
        ext += [0x00, 0x00] // extension type: server_name
        ext += UInt16(sniPayload.count).beBytes
        ext += sniPayload
        return ext
    }

    private func wrapInClientHello(extensions: [UInt8]) -> [UInt8] {
        let sessionID: [UInt8] = [0x00] // empty session ID
        let cipherSuites: [UInt8] = [0x00, 0x02, 0x00, 0x2F] // TLS_RSA_WITH_AES_128_CBC_SHA
        let compression: [UInt8] = [0x01, 0x00] // null compression

        let extensionsLengthPrefix = UInt16(extensions.count).beBytes

        var handshakeBody = [UInt8]()
        handshakeBody += [0x03, 0x03] // client version TLS 1.2
        handshakeBody += [UInt8](repeating: 0xAA, count: 32) // random
        handshakeBody += sessionID
        handshakeBody += cipherSuites
        handshakeBody += compression
        handshakeBody += extensionsLengthPrefix
        handshakeBody += extensions

        let handshakeLength = UInt32(handshakeBody.count)
        var handshake = [UInt8]()
        handshake += [0x01] // ClientHello
        handshake += [
            UInt8((handshakeLength >> 16) & 0xFF),
            UInt8((handshakeLength >> 8) & 0xFF),
            UInt8(handshakeLength & 0xFF),
        ]
        handshake += handshakeBody

        let recordLength = UInt16(handshake.count)
        var record = [UInt8]()
        record += [0x16] // ContentType: Handshake
        record += [0x03, 0x01] // TLS 1.0 record layer (normal for ClientHello)
        record += recordLength.beBytes
        record += handshake

        return record
    }
}

private struct SeededByteGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        self.state = seed
    }

    mutating func nextByte() -> UInt8 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return UInt8(truncatingIfNeeded: state >> 32)
    }
}

// MARK: - DNS Intercept Rule Tests

final class DNSInterceptRuleTests: XCTestCase {

    func testExactMatch() {
        let rule = DNSInterceptRule(pattern: "api2.cursor.sh")
        XCTAssertTrue(rule.matches("api2.cursor.sh"))
        XCTAssertTrue(rule.matches("API2.Cursor.SH"))
        XCTAssertFalse(rule.matches("other.cursor.sh"))
    }

    func testWildcardMatch() {
        let rule = DNSInterceptRule(pattern: "*.cursor.sh")
        XCTAssertTrue(rule.matches("api2.cursor.sh"))
        XCTAssertTrue(rule.matches("deep.nested.cursor.sh"))
        XCTAssertTrue(rule.matches("cursor.sh"))
        XCTAssertFalse(rule.matches("not-cursor.sh"))
        XCTAssertFalse(rule.matches("evil-cursor.sh.attacker.com"))
    }

    func testWildcardCaseInsensitive() {
        let rule = DNSInterceptRule(pattern: "*.Cursor.SH")
        XCTAssertTrue(rule.matches("api2.cursor.sh"))
    }

    func testDisabledRuleNotInEnabledList() {
        var config = ProxyConfig.testFixture()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh", enabled: true),
            DNSInterceptRule(pattern: "*.disabled.com", enabled: false),
        ]
        XCTAssertEqual(config.enabledInterceptRules.count, 1)
        XCTAssertEqual(config.enabledInterceptRules[0].pattern, "*.cursor.sh")
    }

    func testDefaultInterceptIP() {
        let rule = DNSInterceptRule(pattern: "*.cursor.sh")
        XCTAssertEqual(rule.interceptIP, "127.44.3.0")
    }

    func testCustomInterceptIP() {
        let rule = DNSInterceptRule(pattern: "*.cursor.sh", interceptIP: "127.44.4.0")
        XCTAssertEqual(rule.interceptIP, "127.44.4.0")
    }

    func testNoPartialWildcardSuffix() {
        let rule = DNSInterceptRule(pattern: "*.cursor.sh")
        XCTAssertFalse(rule.matches("notcursor.sh"))
    }
}

// MARK: - TCP Relay Lifecycle Tests

final class TCPRelayTests: XCTestCase {

    func testRelayStartsAndStops() throws {
        let relay = TCPRelay()
        XCTAssertFalse(relay.isRunning)
        try relay.start(listenPort: 0, targetPort: 19999, host: "127.0.0.1")
        XCTAssertTrue(relay.isRunning)
        relay.stop()
        XCTAssertFalse(relay.isRunning)
    }

    func testRelayBindFailsOnPrivilegedPort() {
        let relay = TCPRelay()
        defer { relay.stop() }
        XCTAssertThrowsError(try relay.start(listenPort: 1, targetPort: 19999, host: "127.0.0.1"))
    }

    func testRelayRejectsOverflowPort() {
        let relay = TCPRelay()
        defer { relay.stop() }
        XCTAssertThrowsError(try relay.start(listenPort: 99999, targetPort: 1234, host: "127.0.0.1"))
        XCTAssertThrowsError(try relay.start(listenPort: 1234, targetPort: 99999, host: "127.0.0.1"))
    }

    func testRelayRejectsNegativeAndZeroTargetPort() {
        let relay = TCPRelay()
        defer { relay.stop() }
        XCTAssertThrowsError(try relay.start(listenPort: -1, targetPort: 1234, host: "127.0.0.1"))
        XCTAssertThrowsError(try relay.start(listenPort: 1234, targetPort: 0, host: "127.0.0.1"))
        XCTAssertThrowsError(try relay.start(listenPort: 1234, targetPort: -5, host: "127.0.0.1"))
    }

    func testDoubleStopIsSafe() throws {
        let relay = TCPRelay()
        try relay.start(listenPort: 0, targetPort: 19999, host: "127.0.0.1")
        relay.stop()
        relay.stop()
        XCTAssertFalse(relay.isRunning)
    }
}

// MARK: - DNS Intercept Integration

final class DNSInterceptIntegrationTests: XCTestCase {

    func testSynthesizeDirectResponseForInterceptedDomain() {
        let query = DNSWireFormat.buildQuery(domain: "api2.cursor.sh", txID: 0x4242)
        let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "127.44.3.0")
        XCTAssertNotNil(response)
        guard let response else { return }

        XCTAssertEqual(response[0], 0x42)
        XCTAssertEqual(response[1], 0x42)

        XCTAssertFalse(DNSWireFormat.isNXDOMAIN(response))

        let answerCount = (UInt16(response[6]) << 8) | UInt16(response[7])
        XCTAssertEqual(answerCount, 1)

        let lastFourBytes = Array(response[(response.count - 4)...])
        XCTAssertEqual(lastFourBytes, [127, 44, 3, 0])
    }

    func testSynthesizeDirectResponseForAAAAReturnsEmptyNoError() {
        let query = DNSWireFormat.buildQuery(domain: "api2.cursor.sh", txID: 0x1234, qtype: 28)
        let response = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: "127.44.3.0")
        XCTAssertNotNil(response)
        guard let response else { return }

        let answerCount = (UInt16(response[6]) << 8) | UInt16(response[7])
        XCTAssertEqual(answerCount, 0)

        let rcode = response[3] & 0x0F
        XCTAssertEqual(rcode, 0, "AAAA should get NOERROR, not NXDOMAIN")
    }

    func testInterceptRuleMatchesConfiguredDomain() {
        var config = ProxyConfig.testFixture()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh", interceptIP: "127.44.3.0"),
            DNSInterceptRule(pattern: "*.cursorapi.com", interceptIP: "127.44.3.0"),
        ]

        let rules = config.enabledInterceptRules
        let domain = "api2.cursor.sh"

        let matched = rules.first { $0.matches(domain) }
        XCTAssertNotNil(matched)
        XCTAssertEqual(matched?.interceptIP, "127.44.3.0")
    }

    func testInterceptRuleDoesNotMatchUnrelatedDomain() {
        var config = ProxyConfig.testFixture()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh"),
        ]

        let rules = config.enabledInterceptRules
        let matched = rules.first { $0.matches("www.google.com") }
        XCTAssertNil(matched)
    }

    func testInterceptRuleCodableRoundTrip() throws {
        let original = DNSInterceptRule(pattern: "*.cursor.sh", interceptIP: "127.44.3.0", enabled: true)
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(DNSInterceptRule.self, from: data)
        XCTAssertEqual(decoded, original)
    }
}

// MARK: - Transparent Proxy Config Tests

final class TransparentProxyConfigTests: XCTestCase {

    func testDefaultConfigValues() {
        let config = ProxyConfig.testFixture()
        XCTAssertFalse(config.transparentProxyEnabled)
        XCTAssertEqual(config.transparentProxyIP, "127.44.3.0")
        XCTAssertEqual(config.transparentProxyPort, 10443)
        XCTAssertTrue(config.dnsInterceptRules.isEmpty)
    }

    func testConfigCodableRoundTripWithInterceptRules() throws {
        var config = ProxyConfig.testFixture()
        config.transparentProxyEnabled = true
        config.transparentProxyIP = "127.44.5.0"
        config.transparentProxyPort = 20443
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.cursor.sh"),
            DNSInterceptRule(pattern: "*.cursorapi.com", enabled: false),
        ]

        let data = try JSONEncoder().encode(config)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)

        XCTAssertTrue(decoded.transparentProxyEnabled)
        XCTAssertEqual(decoded.transparentProxyIP, "127.44.5.0")
        XCTAssertEqual(decoded.transparentProxyPort, 20443)
        XCTAssertEqual(decoded.dnsInterceptRules.count, 2)
        XCTAssertEqual(decoded.enabledInterceptRules.count, 1)
    }

    func testConfigDecodesWithMissingInterceptFieldsUsingDefaults() throws {
        let json = """
        {"profileName":"Test","localHost":"127.0.0.1","localPort":3128}
        """
        let data = Data(json.utf8)
        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: data)
        XCTAssertFalse(decoded.transparentProxyEnabled)
        XCTAssertEqual(decoded.transparentProxyIP, "127.44.3.0")
        XCTAssertEqual(decoded.transparentProxyPort, 10443)
        XCTAssertTrue(decoded.dnsInterceptRules.isEmpty)
    }
}

private extension UInt16 {
    var beBytes: [UInt8] { [UInt8(self >> 8), UInt8(self & 0xFF)] }
}
