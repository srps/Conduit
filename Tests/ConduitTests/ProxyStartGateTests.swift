// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import XCTest
@testable import ProxyKernel

/// `LocalProxyServer.start` used to refuse any config `validate()` had an
/// opinion about. Once intercept rules joined that set (#68), one unusable rule
/// stopped withholding intercept files and started withholding the listener —
/// and because those rules are validated whether or not they are enabled, it
/// did so even with DNS interception switched off. A user upgrading with one
/// leftover bad rule would lose all proxying, which is worse than the bug #68
/// fixed.
///
/// The start gate now filters on `ConfigValidationError.blocksProxyStart`. The
/// errors themselves are unchanged and still reach the Settings banner.
final class ProxyStartGateTests: XCTestCase {

    private func makeServer(_ config: ProxyConfig) -> LocalProxyServer {
        LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in StartGateNoOpAuthenticator() },
            directConnectDetector: DirectConnectDetector(
                group: MultiThreadedEventLoopGroup.singleton,
                logger: DiscardingLogSink()
            ),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in }
        )
    }

    private func makeConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 0
        return config
    }

    /// The listener does not read `/etc/resolver`, does not bind anything on
    /// behalf of an intercept rule, and does not need one to serve a request.
    func testAnUnusableInterceptRuleStillLetsTheProxyStart() async throws {
        var config = makeConfig()
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.foo bar.example")]
        XCTAssertFalse(
            config.validate().isEmpty,
            "the rule has to be one the boundary rejects, or this test proves nothing"
        )

        let server = makeServer(config)
        try await server.start()
        addTeardownBlock { await server.stop() }

        XCTAssertNotNil(server.listeningPort, "proxying must survive a bad intercept rule")
    }

    /// The rules are validated enabled-or-not on purpose (the cleanup path
    /// derives its set from all of them), so this is the shape an upgrading
    /// user actually hits: interception long since switched off, one stale
    /// rule still in the file.
    func testADisabledUnusableRuleWithInterceptionOffStillLetsTheProxyStart() async throws {
        var config = makeConfig()
        config.transparentProxyEnabled = false
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.foo bar.example", enabled: false)
        ]

        let server = makeServer(config)
        try await server.start()
        addTeardownBlock { await server.stop() }

        XCTAssertNotNil(server.listeningPort)
    }

    /// An intercept IP that is not an address is the same category: it is only
    /// ever written into a resolver file's synthesized answer.
    func testAnUnusableInterceptIPStillLetsTheProxyStart() async throws {
        var config = makeConfig()
        config.dnsInterceptRules = [
            DNSInterceptRule(pattern: "*.a.example", interceptIP: "not-an-ip")
        ]
        XCTAssertFalse(config.validate().isEmpty)

        let server = makeServer(config)
        try await server.start()
        addTeardownBlock { await server.stop() }

        XCTAssertNotNil(server.listeningPort)
    }

    /// The other half of the classification: a value the listener really does
    /// consume still stops it. Without this, "don't block on validation errors"
    /// would have been the fix, and a config that cannot bind would fail
    /// somewhere less legible than the gate.
    func testAnOutOfRangePortStillRefusesToStart() async throws {
        var config = makeConfig()
        config.localPort = 70000

        let server = makeServer(config)
        do {
            try await server.start()
            await server.stop()
            XCTFail("a port outside 0-65535 must not reach the bind")
        } catch let error as ConfigValidationError {
            XCTAssertTrue(error.localizedDescription.contains("70000"))
        }
    }

    /// The gate must not swallow a fatal error that arrives alongside a
    /// non-fatal one — the filter keeps the blocking members, it does not
    /// abandon the list when any member is non-blocking.
    func testAFatalErrorStillBlocksWhenAnInterceptErrorIsAlsoPresent() async throws {
        var config = makeConfig()
        config.localPort = 70000
        config.dnsInterceptRules = [DNSInterceptRule(pattern: "*.foo bar.example")]

        let server = makeServer(config)
        do {
            try await server.start()
            await server.stop()
            XCTFail("the port is still out of range")
        } catch let error as ConfigValidationError {
            XCTAssertTrue(error.localizedDescription.contains("70000"))
            XCTAssertFalse(
                error.localizedDescription.contains("foo bar"),
                "the message names what stopped the start, not everything that is wrong"
            )
        }
    }

    // MARK: - The classification itself

    /// Every case answers deliberately. A new case added without a decision is
    /// a compile error in `blocksProxyStart`, which is the point of putting it
    /// on the enum rather than in a filter at the call site.
    func testOnlyTheInterceptCasesAreNonBlocking() {
        XCTAssertFalse(
            ConfigValidationError.invalidInterceptPattern(
                index: 0, pattern: "*", reason: .empty
            ).blocksProxyStart
        )
        XCTAssertFalse(
            ConfigValidationError.invalidInterceptIP(index: 0, value: "x").blocksProxyStart
        )
        XCTAssertFalse(
            ConfigValidationError.invalidTransparentProxyIP(value: "x").blocksProxyStart
        )
        XCTAssertTrue(ConfigValidationError.invalidPort(field: "p", value: -1).blocksProxyStart)
        XCTAssertTrue(
            ConfigValidationError.invalidLimit(field: "l", value: 0, min: 1).blocksProxyStart
        )
        XCTAssertTrue(ConfigValidationError.invalidDuration(field: "d", value: -1).blocksProxyStart)
        XCTAssertTrue(ConfigValidationError.invalidHost(field: "h", value: "!").blocksProxyStart)
        XCTAssertTrue(ConfigValidationError.conflict(description: "c").blocksProxyStart)
    }
}

// MARK: - Test Double

private final class StartGateNoOpAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    var scheme: String { "NoOp" }
    func initialToken(for host: String) throws -> String { "NoOp none" }
    func processChallenge(headerValues: [String], host: String) throws -> String? { nil }
    func canHandle(scheme: String) -> Bool { true }
    func reset() {}
}
