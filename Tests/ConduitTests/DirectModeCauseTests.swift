// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class DirectModeCauseTests: XCTestCase {

    // MARK: - Predicate semantics

    func testIsDirectIsFalseOnlyForNone() {
        XCTAssertFalse(DirectModeCause.none.isDirect)
        XCTAssertTrue(DirectModeCause.transientNetworkChange.isDirect)
        XCTAssertTrue(DirectModeCause.vpnDisconnected.isDirect)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.isDirect)
        XCTAssertTrue(DirectModeCause.upstreamsUnreachable.isDirect)
    }

    func testUnconditionalDirectRoutingOnlyForOffVPNOrNoUpstreams() {
        XCTAssertFalse(DirectModeCause.none.allowsUnconditionalDirectRouting)
        XCTAssertFalse(DirectModeCause.transientNetworkChange.allowsUnconditionalDirectRouting)
        XCTAssertTrue(DirectModeCause.vpnDisconnected.allowsUnconditionalDirectRouting)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.allowsUnconditionalDirectRouting)
        XCTAssertFalse(DirectModeCause.upstreamsUnreachable.allowsUnconditionalDirectRouting)
    }

    func testOnlyUnconditionalDirectStatesRouteClientTrafficDirectly() {
        XCTAssertFalse(DirectModeCause.none.routesClientTrafficDirectly)
        XCTAssertFalse(DirectModeCause.transientNetworkChange.routesClientTrafficDirectly)
        XCTAssertTrue(DirectModeCause.vpnDisconnected.routesClientTrafficDirectly)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.routesClientTrafficDirectly)
        XCTAssertFalse(DirectModeCause.upstreamsUnreachable.routesClientTrafficDirectly)
    }

    func testDirectOnlyPACOnlyForUnconditionalDirectStates() {
        XCTAssertFalse(DirectModeCause.none.advertisesDirectOnlyPAC)
        XCTAssertFalse(DirectModeCause.transientNetworkChange.advertisesDirectOnlyPAC)
        XCTAssertTrue(DirectModeCause.vpnDisconnected.advertisesDirectOnlyPAC)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.advertisesDirectOnlyPAC)
        XCTAssertFalse(DirectModeCause.upstreamsUnreachable.advertisesDirectOnlyPAC)
    }

    func testUpstreamHealthLoopRunsForUpstreamRoutedStates() {
        XCTAssertTrue(DirectModeCause.none.runsUpstreamHealthLoop)
        XCTAssertFalse(DirectModeCause.transientNetworkChange.runsUpstreamHealthLoop)
        XCTAssertFalse(DirectModeCause.vpnDisconnected.runsUpstreamHealthLoop)
        XCTAssertFalse(DirectModeCause.noUpstreamsConfigured.runsUpstreamHealthLoop)
        XCTAssertTrue(DirectModeCause.upstreamsUnreachable.runsUpstreamHealthLoop)
    }

    func testReprobeTimerRunsForRecoverableDirectOrDegradedStates() {
        XCTAssertFalse(DirectModeCause.none.usesDirectReprobeTimer)
        XCTAssertFalse(DirectModeCause.transientNetworkChange.usesDirectReprobeTimer)
        XCTAssertTrue(DirectModeCause.vpnDisconnected.usesDirectReprobeTimer)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.usesDirectReprobeTimer)
        XCTAssertTrue(DirectModeCause.upstreamsUnreachable.usesDirectReprobeTimer)
    }

    func testDirectModeSuppressesPACEvaluationEvenForForceProxyHosts() {
        XCTAssertFalse(HTTPProxyHandler.shouldEvaluatePAC(isDirectMode: true, forceProxy: false))
        XCTAssertFalse(HTTPProxyHandler.shouldEvaluatePAC(isDirectMode: true, forceProxy: true))
    }

    func testNormalModeStillSkipsPACForForceProxyHostsOnly() {
        XCTAssertTrue(HTTPProxyHandler.shouldEvaluatePAC(isDirectMode: false, forceProxy: false))
        XCTAssertFalse(HTTPProxyHandler.shouldEvaluatePAC(isDirectMode: false, forceProxy: true))
    }

    func testIsExpectedClassifiesCausesCorrectly() {
        // Expected: silent, fast, no error-rate alarm, no escalation.
        XCTAssertTrue(DirectModeCause.transientNetworkChange.isExpected)
        XCTAssertTrue(DirectModeCause.vpnDisconnected.isExpected)
        XCTAssertTrue(DirectModeCause.noUpstreamsConfigured.isExpected)

        // Unexpected: keep the loud current behavior. Real signal of a problem.
        XCTAssertFalse(DirectModeCause.upstreamsUnreachable.isExpected)

        // Not in direct mode: not "expected direct" either, by definition.
        XCTAssertFalse(DirectModeCause.none.isExpected)
    }

    // MARK: - Health summary strings (drives MainView + lastHealthSummary)

    func testHealthSummaryMappingMatchesDesignDoc() {
        // Mapping locked by docs/design-vpn-flap-resilience.md §
        // "lastHealthSummary strings derive from cause".
        XCTAssertEqual(DirectModeCause.transientNetworkChange.healthSummary, "Network changing…")
        XCTAssertEqual(DirectModeCause.vpnDisconnected.healthSummary, "Direct (VPN off)")
        XCTAssertEqual(DirectModeCause.noUpstreamsConfigured.healthSummary, "Direct (no upstreams configured)")
        XCTAssertEqual(DirectModeCause.upstreamsUnreachable.healthSummary, "⚠ Upstreams unreachable")
    }

    func testNoneHealthSummaryIsEmpty() {
        // .none is not in direct mode, so the cause's summary doesn't apply
        // (the snapshot uses the upstream-derived "Healthy via X (Y ms)" string instead).
        XCTAssertEqual(DirectModeCause.none.healthSummary, "")
    }

    func testWarningGlyphOnlyOnUnexpectedCause() {
        // The ⚠ glyph is the user-visible signal that something is genuinely
        // wrong. It must NOT appear on any expected cause; it MUST appear on
        // the only unexpected one.
        for cause in [DirectModeCause.transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured] {
            XCTAssertFalse(cause.healthSummary.contains("⚠"),
                           "Expected cause \(cause) must not display ⚠ — it would alarm the user when nothing is wrong")
        }
        XCTAssertTrue(DirectModeCause.upstreamsUnreachable.healthSummary.contains("⚠"),
                      "Unexpected cause must display ⚠ to signal the real problem")
    }

    // MARK: - Direct-failure log severity (HTTPProxyHandler integration)

    func testDirectFailureLogLevelDemotesExpectedCauses() {
        for cause in [DirectModeCause.transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured] {
            XCTAssertEqual(HTTPProxyHandler.directFailureLogLevel(for: cause), .info,
                           "Expected cause \(cause) should demote direct-failure logs to .info")
        }
    }

    func testDirectFailureLogLevelKeepsErrorForUnexpected() {
        XCTAssertEqual(HTTPProxyHandler.directFailureLogLevel(for: .upstreamsUnreachable), .error,
                       "Unexpected cause must keep .error severity — direct failures here are real signal")
        XCTAssertEqual(HTTPProxyHandler.directFailureLogLevel(for: .none), .error,
                       ".none shouldn't reach this code path, but if it does, .error is the safe default")
    }

    func testTransientUpstreamFailuresAreNotErrorLevel() {
        XCTAssertEqual(HTTPProxyHandler.upstreamFailureLogLevel(for: .transientNetworkChange), .info)
        XCTAssertEqual(HTTPProxyHandler.upstreamFailureLogLevel(for: .upstreamsUnreachable), .error)
        XCTAssertEqual(HTTPProxyHandler.upstreamFailureLogLevel(for: .none), .error)
    }

    func testStrictModeSuppressesPACDirectFallbackWhileOnVPN() {
        XCTAssertFalse(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .none))
        XCTAssertFalse(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .transientNetworkChange))
        XCTAssertFalse(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .upstreamsUnreachable))
    }

    func testExplicitOffVPNStatesAllowDirectFallbackEvenInStrictMode() {
        XCTAssertTrue(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .vpnDisconnected))
        XCTAssertTrue(HTTPProxyHandler.directFallbackAllowed(strictMode: true, cause: .noUpstreamsConfigured))
    }

    func testNonStrictModeAllowsPACDirectFallback() {
        for cause in DirectModeCause.allCasesForTest {
            XCTAssertTrue(HTTPProxyHandler.directFallbackAllowed(strictMode: false, cause: cause))
        }
    }

    func testStreamingInterruptionSuppressesDirectFallbackReplay() {
        XCTAssertFalse(HTTPProxyHandler.shouldFallbackToDirectAfterProxyExchangeFailure(
            hasDirectFallback: true,
            error: ConnectionPoolError.streamingResponseInterrupted
        ))
        XCTAssertTrue(HTTPProxyHandler.shouldFallbackToDirectAfterProxyExchangeFailure(
            hasDirectFallback: true,
            error: ConnectionPoolError.invalidResponse
        ))
        XCTAssertFalse(HTTPProxyHandler.shouldFallbackToDirectAfterProxyExchangeFailure(
            hasDirectFallback: false,
            error: ConnectionPoolError.invalidResponse
        ))
    }

    func testPACProxyChainReusesConfiguredUpstreamBeforeDynamicFallback() {
        let configured = UpstreamProxy(
            name: "Germany",
            host: "proxy-a.example.test",
            port: 8080,
            priority: 0
        )
        var config = ProxyConfig.testFixture()
        config.upstreams = [configured]

        let chain = HTTPProxyHandler.pacProxyChain(
            from: [
                .proxy(host: "proxy-a.example.test", port: 8080),
                .proxy(host: "proxy-special.example.test", port: 8080),
                .direct,
            ],
            config: config
        )

        XCTAssertEqual(chain.map(\.endpoint), [
            "proxy-a.example.test:8080",
            "proxy-special.example.test:8080",
        ])
        XCTAssertEqual(chain.first?.id, configured.id)
        XCTAssertEqual(chain.last?.name, "PAC proxy-special.example.test:8080")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesCause() throws {
        for cause in DirectModeCause.allCasesForTest {
            let encoded = try JSONEncoder().encode(cause)
            let decoded = try JSONDecoder().decode(DirectModeCause.self, from: encoded)
            XCTAssertEqual(cause, decoded)
        }
    }

    // MARK: - Snapshot Codable round-trip

    func testSnapshotCodableRoundTripPreservesCause() throws {
        // The snapshot's only direct-mode field is `directModeCause`. Verify
        // every cause survives a JSONEncoder -> JSONDecoder round-trip. The
        // historical `directMode: Bool` field was removed in Phase 2's cleanup
        // commit (see docs/design-vpn-flap-resilience.md "Phase 2 deviations").
        for cause in DirectModeCause.allCasesForTest {
            let original = ProxyOrchestratorSnapshot(directModeCause: cause)
            let encoded = try JSONEncoder().encode(original)
            let decoded = try JSONDecoder().decode(ProxyOrchestratorSnapshot.self, from: encoded)
            XCTAssertEqual(decoded.directModeCause, original.directModeCause,
                           "Cause \(cause) did not survive snapshot round-trip")
        }
    }
}

private extension DirectModeCause {
    /// Manual all-cases list (the enum doesn't conform to `CaseIterable` because
    /// only test code needs to iterate).
    static var allCasesForTest: [DirectModeCause] {
        [.none, .transientNetworkChange, .vpnDisconnected, .noUpstreamsConfigured, .upstreamsUnreachable]
    }
}
