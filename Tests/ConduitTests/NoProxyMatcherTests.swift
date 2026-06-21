// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class NoProxyMatcherTests: XCTestCase {
    let patterns = ["localhost", "127.0.0.1", "127.0.0.*", "::1", "[::1]", "*.local", "10.*", "192.168.*", "172.16.*"]

    func testExactMatch() {
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "localhost", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "127.0.0.1", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "::1", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "[::1]", patterns: patterns))
    }

    func testWildcardSuffix() {
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "myhost.local", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "printer.local", patterns: patterns))
    }

    func testWildcardPrefix() {
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "10.0.0.1", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "10.255.255.255", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "127.0.0.42", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "192.168.1.100", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "172.16.0.1", patterns: patterns))
    }

    func testDefaultConfigLoopbackPatterns() {
        let patterns = ProxyConfig().noProxyHosts
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "localhost", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "127.0.0.1", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "127.0.0.42", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "::1", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "[::1]", patterns: patterns))
    }

    func testNoMatchForExternalHosts() {
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "example.com", patterns: patterns))
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "github.com", patterns: patterns))
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "8.8.8.8", patterns: patterns))
    }

    func testCaseInsensitive() {
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "LOCALHOST", patterns: patterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "MyHost.LOCAL", patterns: patterns))
    }

    func testDotPrefixPattern() {
        let dotPatterns = [".example.com"]
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "sub.example.com", patterns: dotPatterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "example.com", patterns: dotPatterns))
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "notexample.com", patterns: dotPatterns))
    }

    func testStarDotPattern() {
        let starPatterns = ["*.example.test"]
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "github.example.test", patterns: starPatterns))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "example.test", patterns: starPatterns))
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "notexample.test", patterns: starPatterns))
    }

    func testEmptyPatternsNeverBypass() {
        XCTAssertFalse(NoProxyMatcher.shouldBypass(host: "anything.com", patterns: []))
    }

    func testExtractHostFromConnectURI() {
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "example.com:443"), "example.com")
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "10.0.0.1:8080"), "10.0.0.1")
    }

    func testExtractHostFromHTTPURL() {
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "http://example.com/path"), "example.com")
    }

    func testExtractHostFromBareHost() {
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "example.com"), "example.com")
    }

    // MARK: - parseHostPort

    func testParseHostPortIPv4() {
        let result = NoProxyMatcher.parseHostPort(from: "10.0.0.1:8080")
        XCTAssertEqual(result?.host, "10.0.0.1")
        XCTAssertEqual(result?.port, 8080)
    }

    func testParseHostPortHostname() {
        let result = NoProxyMatcher.parseHostPort(from: "example.com:443")
        XCTAssertEqual(result?.host, "example.com")
        XCTAssertEqual(result?.port, 443)
    }

    func testParseHostPortIPv6Bracketed() {
        let result = NoProxyMatcher.parseHostPort(from: "[::1]:443")
        XCTAssertEqual(result?.host, "::1")
        XCTAssertEqual(result?.port, 443)
    }

    func testParseHostPortIPv6Full() {
        let result = NoProxyMatcher.parseHostPort(from: "[2001:db8::1]:8080")
        XCTAssertEqual(result?.host, "2001:db8::1")
        XCTAssertEqual(result?.port, 8080)
    }

    func testParseHostPortNoPort() {
        let result = NoProxyMatcher.parseHostPort(from: "example.com")
        XCTAssertEqual(result?.host, "example.com")
        XCTAssertNil(result?.port)
    }

    func testExtractHostFromIPv6ConnectTarget() {
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "[::1]:443"), "::1")
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "[2001:db8::1]:8080"), "2001:db8::1")
    }

    func testExtractHostFromHTTPSURL() {
        XCTAssertEqual(NoProxyMatcher.extractHost(from: "https://secure.example.com:8443/api"), "secure.example.com")
    }
}
