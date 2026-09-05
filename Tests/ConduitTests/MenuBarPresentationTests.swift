// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
@testable import Conduit

final class MenuBarPresentationTests: XCTestCase {

    // MARK: - Glyph

    func testMenuBarSymbolCoversEveryRuntimeState() {
        for cause in [DirectModeCause.none, .vpnDisconnected, .noUpstreamsConfigured, .transientNetworkChange, .upstreamsUnreachable] {
            XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .stopped, directModeCause: cause), "network.slash", "\(cause)")
            XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .failed, directModeCause: cause), "exclamationmark.triangle", "\(cause)")
            XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .degraded, directModeCause: cause), "exclamationmark.triangle", "\(cause)")
            XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .recovering, directModeCause: cause), "exclamationmark.triangle", "\(cause)")
        }
    }

    func testMenuBarSymbolDistinguishesProxiedFromDirect() {
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .running, directModeCause: .none), "network.badge.shield.half.filled")
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .running, directModeCause: .vpnDisconnected), "network")
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .running, directModeCause: .noUpstreamsConfigured), "network")
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .running, directModeCause: .transientNetworkChange), "network")
    }

    func testMenuBarSymbolTreatsUnreachableUpstreamsAsAttention() {
        // The one direct-mode cause that signals a real problem.
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .running, directModeCause: .upstreamsUnreachable), "exclamationmark.triangle")
    }

    func testMenuBarSymbolWhileStartingMatchesTheStateItIsHeadingFor() {
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .starting, directModeCause: .none), "network.badge.shield.half.filled")
        XCTAssertEqual(MenuBarPresentation.menuBarSymbol(state: .starting, directModeCause: .vpnDisconnected), "network")
    }

    // MARK: - State line

    func testStateLineForLifecycleStates() {
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .stopped, directModeCause: .none, activeUpstream: "x", proxyError: nil), "Stopped")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .starting, directModeCause: .none, activeUpstream: nil, proxyError: nil), "Starting…")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .failed, directModeCause: .none, activeUpstream: nil, proxyError: "port in use"), "Failed: port in use")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .failed, directModeCause: .none, activeUpstream: nil, proxyError: nil), "Failed")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .failed, directModeCause: .none, activeUpstream: nil, proxyError: ""), "Failed")
    }

    func testStateLineNamesTheUpstreamWhenProxied() {
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .running, directModeCause: .none, activeUpstream: "corp-eu-1", proxyError: nil), "Proxied via corp-eu-1")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .running, directModeCause: .none, activeUpstream: nil, proxyError: nil), "Proxied")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .degraded, directModeCause: .none, activeUpstream: "corp-eu-1", proxyError: nil), "Degraded via corp-eu-1")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .recovering, directModeCause: .none, activeUpstream: nil, proxyError: nil), "Recovering")
    }

    func testStateLineExplainsDirectMode() {
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .running, directModeCause: .vpnDisconnected, activeUpstream: "corp-eu-1", proxyError: nil), "Direct, VPN off")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .running, directModeCause: .noUpstreamsConfigured, activeUpstream: nil, proxyError: nil), "Direct, no upstreams configured")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .running, directModeCause: .transientNetworkChange, activeUpstream: nil, proxyError: nil), "Direct, network changing")
        XCTAssertEqual(MenuBarPresentation.stateLine(state: .degraded, directModeCause: .upstreamsUnreachable, activeUpstream: nil, proxyError: nil), "Direct, upstreams unreachable")
    }

    // MARK: - Detail line

    func testStateDetailPrefersTheAppErrorThenJoinsTheParts() {
        XCTAssertEqual(
            MenuBarPresentation.stateDetail(lastError: "app error", healthSummary: "Healthy", vpnLabel: "Connected", uptime: "2h 14m"),
            "app error"
        )
        XCTAssertEqual(
            MenuBarPresentation.stateDetail(lastError: nil, healthSummary: "Healthy", vpnLabel: "Connected", uptime: "2h 14m"),
            "Healthy · VPN connected · 2h 14m up"
        )
        XCTAssertEqual(
            MenuBarPresentation.stateDetail(lastError: "", healthSummary: "", vpnLabel: "Disconnected (user)", uptime: nil),
            "VPN disconnected (user)"
        )
        XCTAssertEqual(
            MenuBarPresentation.stateDetail(lastError: nil, healthSummary: "", vpnLabel: "", uptime: nil),
            ""
        )
    }

    func testUpstreamSummaryLineCountsTheFallbacks() {
        XCTAssertNil(MenuBarPresentation.upstreamSummaryLine(closed: 0, halfOpen: 0, open: 0, activeShown: true))
        XCTAssertEqual(MenuBarPresentation.upstreamSummaryLine(closed: 3, halfOpen: 0, open: 1, activeShown: true), "4 fallbacks · 3 healthy · 1 open")
        XCTAssertEqual(MenuBarPresentation.upstreamSummaryLine(closed: 1, halfOpen: 0, open: 0, activeShown: true), "1 fallback · 1 healthy")
        XCTAssertEqual(MenuBarPresentation.upstreamSummaryLine(closed: 2, halfOpen: 1, open: 0, activeShown: false), "3 upstreams · 2 healthy · 1 probing")
    }

    func testDisplayNameResolvesTheActiveEndpointToItsName() {
        let statuses = [
            UpstreamRuntimeStatus(id: UUID(), name: "Germany", endpoint: "proxy-de.example:8080", circuitState: .closed, ewmaLatencyMS: 42, consecutiveFailures: 0, openUntil: nil),
            UpstreamRuntimeStatus(id: UUID(), name: "", endpoint: "proxy-tr.example:8080", circuitState: .closed, ewmaLatencyMS: nil, consecutiveFailures: 0, openUntil: nil),
        ]
        XCTAssertEqual(MenuBarPresentation.displayName(forActiveUpstream: "proxy-de.example:8080", statuses: statuses), "Germany")
        XCTAssertEqual(MenuBarPresentation.displayName(forActiveUpstream: "proxy-tr.example:8080", statuses: statuses), "proxy-tr.example:8080", "unnamed upstreams fall back to the endpoint")
        XCTAssertEqual(MenuBarPresentation.displayName(forActiveUpstream: "unknown:1", statuses: statuses), "unknown:1")
        XCTAssertNil(MenuBarPresentation.displayName(forActiveUpstream: nil, statuses: statuses))
    }

    func testActivityLineUsesCompactCounts() {
        XCTAssertEqual(MenuBarPresentation.activityLine(requests: 1_234, errors: 3, active: 4), "1.2k requests · 3 errors · 4 active")
    }

    // MARK: - Switches

    func testProxySwitchCoversEveryRuntimeState() {
        XCTAssertFalse(MenuBarPresentation.proxySwitchIsOn(for: .stopped))
        XCTAssertTrue(MenuBarPresentation.proxySwitchIsOn(for: .starting))
        XCTAssertTrue(MenuBarPresentation.proxySwitchIsOn(for: .running))
        XCTAssertTrue(MenuBarPresentation.proxySwitchIsOn(for: .degraded))
        XCTAssertTrue(MenuBarPresentation.proxySwitchIsOn(for: .recovering))
        XCTAssertFalse(MenuBarPresentation.proxySwitchIsOn(for: .failed))

        for state in ProxyConnectionState.allCases {
            XCTAssertEqual(MenuBarPresentation.proxySwitchIsEnabled(for: state), state != .starting, "\(state)")
        }
    }

    func testModuleSwitchCoversEveryRunState() {
        XCTAssertFalse(MenuBarPresentation.moduleSwitchIsOn(for: .stopped))
        XCTAssertTrue(MenuBarPresentation.moduleSwitchIsOn(for: .starting))
        XCTAssertTrue(MenuBarPresentation.moduleSwitchIsOn(for: .running))
        XCTAssertTrue(MenuBarPresentation.moduleSwitchIsOn(for: .warning))
        XCTAssertFalse(MenuBarPresentation.moduleSwitchIsOn(for: .failed))

        for state in ModuleRunState.allCases {
            XCTAssertEqual(MenuBarPresentation.moduleSwitchIsEnabled(for: state), state != .starting, "\(state)")
        }
    }

    // MARK: - Restart

    func testRestartAvailabilityCoversEveryRuntimeState() {
        XCTAssertFalse(MenuBarPresentation.canRestartProxy(for: .stopped))
        XCTAssertFalse(MenuBarPresentation.canRestartProxy(for: .starting))
        XCTAssertTrue(MenuBarPresentation.canRestartProxy(for: .running))
        XCTAssertTrue(MenuBarPresentation.canRestartProxy(for: .degraded))
        XCTAssertTrue(MenuBarPresentation.canRestartProxy(for: .recovering))
        XCTAssertTrue(MenuBarPresentation.canRestartProxy(for: .failed))
    }

    func testRestartStopsExistingRuntimeBeforeStarting() {
        XCTAssertFalse(MenuBarPresentation.shouldStopBeforeRestart(for: .stopped))
        XCTAssertFalse(MenuBarPresentation.shouldStopBeforeRestart(for: .starting))
        XCTAssertTrue(MenuBarPresentation.shouldStopBeforeRestart(for: .running))
        XCTAssertTrue(MenuBarPresentation.shouldStopBeforeRestart(for: .degraded))
        XCTAssertTrue(MenuBarPresentation.shouldStopBeforeRestart(for: .recovering))
        XCTAssertTrue(MenuBarPresentation.shouldStopBeforeRestart(for: .failed))
    }

    // MARK: - Formatting

    func testEndpointFormatting() {
        XCTAssertEqual(MenuBarPresentation.endpoint(host: "127.0.0.1", port: 3128), "127.0.0.1:3128")
        XCTAssertEqual(MenuBarPresentation.endpoint(host: nil, port: 3128), "-")
        XCTAssertEqual(MenuBarPresentation.endpoint(host: "127.0.0.1", port: nil), "-")
    }

    func testUptimeIsNilWhenNotRunning() {
        XCTAssertNil(MenuBarPresentation.uptime(since: nil))
        let start = Date(timeIntervalSince1970: 0)
        let uptime = MenuBarPresentation.uptime(since: start, now: start.addingTimeInterval(2 * 3600 + 14 * 60))
        XCTAssertNotNil(uptime)
        XCTAssertTrue(uptime?.contains("2") == true && uptime?.contains("14") == true, "\(uptime ?? "nil")")
    }

    func testStatusSummaryIncludesOperationalFields() {
        let summary = MenuBarPresentation.statusSummary(
            state: .running,
            activeUpstream: "proxy.example:8080",
            healthSummary: "Healthy",
            proxyEndpoint: "127.0.0.1:3128",
            dnsEndpoint: "127.0.0.1:5353",
            socksEndpoint: "127.0.0.1:1080",
            requestsHandled: 42,
            failedRequests: 2,
            activeConnectionCount: 3,
            directModeCause: .none,
            vpnLabel: "Connected"
        )

        XCTAssertTrue(summary.contains("State: Running"))
        XCTAssertTrue(summary.contains("Active upstream: proxy.example:8080"))
        XCTAssertTrue(summary.contains("HTTP: 127.0.0.1:3128"))
        XCTAssertTrue(summary.contains("DNS: 127.0.0.1:5353"))
        XCTAssertTrue(summary.contains("SOCKS: 127.0.0.1:1080"))
        XCTAssertTrue(summary.contains("Requests: 42"))
        XCTAssertTrue(summary.contains("Errors: 2"))
        XCTAssertTrue(summary.contains("Active connections: 3"))
        XCTAssertTrue(summary.contains("VPN: Connected"))
    }

    // MARK: - compactCount

    func testCompactCountExactBelowOneThousand() {
        XCTAssertEqual(MenuBarPresentation.compactCount(0), "0")
        XCTAssertEqual(MenuBarPresentation.compactCount(7), "7")
        XCTAssertEqual(MenuBarPresentation.compactCount(999), "999")
    }

    func testCompactCountThousands() {
        XCTAssertEqual(MenuBarPresentation.compactCount(1_000), "1k")
        XCTAssertEqual(MenuBarPresentation.compactCount(1_234), "1.2k")
        XCTAssertEqual(MenuBarPresentation.compactCount(9_999), "9.9k")
        XCTAssertEqual(MenuBarPresentation.compactCount(12_345), "12k")
        XCTAssertEqual(MenuBarPresentation.compactCount(999_999), "999k", "truncation must never produce 1000k")
    }

    func testCompactCountMillionsAndBillions() {
        XCTAssertEqual(MenuBarPresentation.compactCount(1_000_000), "1M")
        XCTAssertEqual(MenuBarPresentation.compactCount(2_345_678), "2.3M")
        XCTAssertEqual(MenuBarPresentation.compactCount(999_999_999), "999M")
        XCTAssertEqual(MenuBarPresentation.compactCount(1_200_000_000), "1.2B")
    }

    func testCompactCountNegative() {
        XCTAssertEqual(MenuBarPresentation.compactCount(-5), "-5")
        XCTAssertEqual(MenuBarPresentation.compactCount(-1_234), "-1.2k")
    }
}
