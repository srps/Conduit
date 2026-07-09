// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

/// The transparent proxy's direct path dials whatever `DoHOriginResolver`
/// hands it. If a resolver answer ever points back at this machine, the proxy
/// relays into its own listener — the intercept resolver file for a hostname
/// maps that hostname to exactly that listener, so this is one bad DNS answer
/// away, not a theoretical concern.
final class OriginResolverTests: XCTestCase {

    // MARK: - Loop prevention

    func testRejectsTheTransparentProxyListenerItself() {
        assertSelfReferential(ip: "127.44.3.0", host: "api2.cursor.sh")
    }

    func testRejectsLoopbackAnswers() {
        for ip in ["127.0.0.1", "127.1.2.3", "::1"] {
            assertSelfReferential(ip: ip, host: "api2.cursor.sh")
        }
    }

    func testRejectsLinkLocalAndUnspecifiedAnswers() {
        for ip in ["169.254.169.254", "0.0.0.0", "fe80::1"] {
            assertSelfReferential(ip: ip, host: "example.com")
        }
    }

    func testAcceptsPublicAddress() throws {
        let address = try DoHOriginResolver.address(ip: "3.227.72.43", port: 443, host: "api2.cursor.sh")
        XCTAssertEqual(address.ipAddress, "3.227.72.43")
        XCTAssertEqual(address.port, 443)
    }

    /// RFC-1918 stays reachable on the direct path. The guard exists to stop a
    /// relay loop, not to enforce the SSRF policy `gatewayMode` governs — and a
    /// split-horizon origin on a corporate subnet is a legitimate target.
    func testAcceptsPrivateRFC1918Address() throws {
        let address = try DoHOriginResolver.address(ip: "10.0.53.53", port: 443, host: "internal.example.com")
        XCTAssertEqual(address.ipAddress, "10.0.53.53")
    }

    func testRejectsNonAddressData() {
        // A CNAME's `data` is a hostname. `fetchA` filters on record type so
        // this should never arrive, but the address builder must not turn it
        // into a connectable address if it does.
        XCTAssertThrowsError(try DoHOriginResolver.address(ip: "api2geo.cursor.sh.", port: 443, host: "api2.cursor.sh"))
    }

    private func assertSelfReferential(ip: String, host: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try DoHOriginResolver.address(ip: ip, port: 443, host: host), file: file, line: line) { error in
            XCTAssertEqual(
                error as? OriginResolverError,
                .selfReferential(host: host, ip: ip),
                "\(ip) must be refused as a relay target",
                file: file, line: line
            )
        }
    }
}

/// `firstIPv4Answer` backs the RFC 8484 half of `DoHOriginResolver`, which
/// exists because two of the three default DoH providers reject `dns-json`.
final class DNSWireFormatAnswerTests: XCTestCase {

    /// Cloudflare answers `api2.cursor.sh` with two CNAMEs *ahead of* the A
    /// records. Taking the first answer record yields `api2geo.cursor.sh.`,
    /// which is not an address.
    func testSkipsLeadingCNAMEsAndReturnsFirstARecord() throws {
        let response = wireResponse(
            question: "api2.cursor.sh",
            answers: [
                .cname(name: "api2geo.cursor.sh", ttl: 271),
                .cname(name: "api2direct.cursor.sh", ttl: 271),
                .a(ip: [35, 175, 4, 2], ttl: 31),
                .a(ip: [3, 208, 182, 13], ttl: 31),
            ]
        )
        let answer = try XCTUnwrap(DNSWireFormat.firstIPv4Answer(in: response))
        XCTAssertEqual(answer.ip, "35.175.4.2")
        XCTAssertEqual(answer.ttl, 31)
    }

    func testReturnsNilWhenOnlyCNAMEsPresent() {
        let response = wireResponse(question: "api2.cursor.sh", answers: [.cname(name: "elsewhere.example", ttl: 60)])
        XCTAssertNil(DNSWireFormat.firstIPv4Answer(in: response))
    }

    func testReturnsNilForEmptyAnswerSection() {
        XCTAssertNil(DNSWireFormat.firstIPv4Answer(in: wireResponse(question: "nx.example", answers: [])))
    }

    func testReturnsNilForTruncatedResponse() {
        let response = wireResponse(question: "api2.cursor.sh", answers: [.a(ip: [1, 2, 3, 4], ttl: 60)])
        XCTAssertNil(DNSWireFormat.firstIPv4Answer(in: Array(response.dropLast(3))))
        XCTAssertNil(DNSWireFormat.firstIPv4Answer(in: [0x00, 0x01]))
    }

    // MARK: - Wire builder

    private enum Answer {
        case a(ip: [UInt8], ttl: UInt32)
        case cname(name: String, ttl: UInt32)
    }

    private func wireResponse(question: String, answers: [Answer]) -> [UInt8] {
        var bytes: [UInt8] = []
        bytes += [0xAB, 0xCD]                                   // transaction ID
        bytes += [0x81, 0x80]                                   // response, recursion available
        bytes += be16(1)                                        // QDCOUNT
        bytes += be16(UInt16(answers.count))                    // ANCOUNT
        bytes += be16(0) + be16(0)                              // NSCOUNT, ARCOUNT
        bytes += encodeName(question)
        bytes += be16(1) + be16(1)                              // QTYPE A, QCLASS IN

        for answer in answers {
            bytes += [0xC0, 0x0C]                               // name: pointer to question
            switch answer {
            case .a(let ip, let ttl):
                bytes += be16(1) + be16(1) + be32(ttl) + be16(4) + ip
            case .cname(let name, let ttl):
                let rdata = encodeName(name)
                bytes += be16(5) + be16(1) + be32(ttl) + be16(UInt16(rdata.count)) + rdata
            }
        }
        return bytes
    }

    private func encodeName(_ name: String) -> [UInt8] {
        var bytes: [UInt8] = []
        for label in name.split(separator: ".") {
            bytes.append(UInt8(label.utf8.count))
            bytes += Array(label.utf8)
        }
        bytes.append(0x00)
        return bytes
    }

    private func be16(_ value: UInt16) -> [UInt8] { [UInt8(value >> 8), UInt8(value & 0xFF)] }
    private func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }
}

/// The two listeners must agree on when a strict profile may bypass the
/// corporate proxy. `TransparentTCPProxy` calls the same predicate
/// `HTTPProxyHandler` does; these pin the contract both rely on.
final class TransparentProxyRoutingPolicyTests: XCTestCase {

    func testVPNDisconnectedRoutesClientTrafficDirectly() {
        XCTAssertTrue(DirectModeCause.vpnDisconnected.routesClientTrafficDirectly)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.routesClientTrafficDirectly)
    }

    /// Upstreams down *while the VPN is up* is a real fault, not a sanctioned
    /// bypass: routing around it would leak corporate traffic past the proxy.
    ///
    /// `.transientNetworkChange` is the VPN-flap grace window. It reads as
    /// "direct" to the logging and health machinery (`isDirect`) but must keep
    /// routing upstream, because the VPN is expected back within the window —
    /// so the transparent proxy holds the upstream path here too.
    func testUpstreamsUnreachableAndFlapGraceWindowDoNotRouteDirectly() {
        XCTAssertFalse(DirectModeCause.upstreamsUnreachable.routesClientTrafficDirectly)
        XCTAssertFalse(DirectModeCause.transientNetworkChange.routesClientTrafficDirectly)
        XCTAssertFalse(DirectModeCause.none.routesClientTrafficDirectly)
    }

    func testStrictModeBlocksFallbackExceptOnSanctionedCauses() {
        XCTAssertFalse(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .none))
        XCTAssertFalse(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .upstreamsUnreachable))
        XCTAssertTrue(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .vpnDisconnected))
    }

    func testNonStrictModeAlwaysAllowsFallback() {
        XCTAssertTrue(HTTPProxyHandler.directFallbackAllowed(strictMode: false, cause: .none))
        XCTAssertTrue(HTTPProxyHandler.directFallbackAllowed(strictMode: false, cause: .upstreamsUnreachable))
    }
}
