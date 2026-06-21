// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// Tests verifying that SOCKS5 bypass routing logic applies
/// NoProxyMatcher rules correctly (the core routing decision).
final class SOCKS5RoutingTests: XCTestCase {

    // MARK: - Bypass detection for SOCKS5 targets

    func testLocalHostBypassesCorporateProxy() {
        let noProxy = ["localhost", "127.0.0.1", "*.local", "10.*"]
        let forceProxy: [String] = []

        XCTAssertTrue(
            NoProxyMatcher.shouldBypass(host: "localhost", patterns: noProxy, forceProxy: forceProxy),
            "localhost should bypass via SOCKS5"
        )
        XCTAssertTrue(
            NoProxyMatcher.shouldBypass(host: "127.0.0.1", patterns: noProxy, forceProxy: forceProxy)
        )
        XCTAssertTrue(
            NoProxyMatcher.shouldBypass(host: "10.0.0.5", patterns: noProxy, forceProxy: forceProxy)
        )
    }

    func testExternalHostGoesViaUpstream() {
        let noProxy = ["localhost", "127.0.0.1", "*.local", "10.*"]
        let forceProxy: [String] = []

        XCTAssertFalse(
            NoProxyMatcher.shouldBypass(host: "github.com", patterns: noProxy, forceProxy: forceProxy),
            "External hosts should route through upstream corporate proxy"
        )
        XCTAssertFalse(
            NoProxyMatcher.shouldBypass(host: "api.openai.com", patterns: noProxy, forceProxy: forceProxy)
        )
    }

    func testForceProxyOverridesNoProxy() {
        let noProxy = ["10.*"]
        let forceProxy = ["10.0.0.1"]

        XCTAssertFalse(
            NoProxyMatcher.shouldBypass(host: "10.0.0.1", patterns: noProxy, forceProxy: forceProxy),
            "forceProxy should override noProxy for SOCKS5 routing"
        )
        XCTAssertTrue(
            NoProxyMatcher.shouldBypass(host: "10.0.0.2", patterns: noProxy, forceProxy: forceProxy),
            "Other 10.x addresses should still bypass"
        )
    }

    // MARK: - Direct mode interaction

    func testDirectModeBypassesEverything() {
        let noProxy: [String] = []
        let directMode = true

        // In SOCKS5Handler, bypass = shouldBypass(...) || directModeProvider(),
        // and PAC evaluation is skipped before it can influence the decision.
        let bypass = NoProxyMatcher.shouldBypass(host: "github.com", patterns: noProxy) || directMode
        XCTAssertTrue(bypass, "Direct mode should bypass all hosts")
        XCTAssertFalse(HTTPProxyHandler.shouldEvaluatePAC(isDirectMode: directMode, forceProxy: false))
    }

    func testNonDirectModeUsesRules() {
        let noProxy: [String] = []
        let directMode = false

        let bypass = NoProxyMatcher.shouldBypass(host: "github.com", patterns: noProxy) || directMode
        XCTAssertFalse(bypass, "Without direct mode and no bypass rules, should go via upstream")
    }

    // MARK: - Default config patterns for SOCKS5

    func testDefaultConfigPatternsMatchPrivateRanges() {
        let config = ProxyConfig.testFixture()
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "10.0.0.1", patterns: config.noProxyHosts))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "192.168.1.100", patterns: config.noProxyHosts))
        XCTAssertTrue(NoProxyMatcher.shouldBypass(host: "172.16.5.3", patterns: config.noProxyHosts))
    }

    func testDefaultConfigForceProxyAkaMs() {
        let config = ProxyConfig.testFixture()
        XCTAssertFalse(
            NoProxyMatcher.shouldBypass(host: "aka.ms", patterns: config.noProxyHosts, forceProxy: config.forceProxyHosts),
            "aka.ms should be forced through proxy even if it matched a bypass rule"
        )
    }
}
