// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
@testable import Conduit

final class MenuBarPresentationTests: XCTestCase {

    func testProxyButtonTitleCoversEveryRuntimeState() {
        XCTAssertEqual(MenuBarPresentation.proxyButtonTitle(for: .stopped), "Start Proxy")
        XCTAssertEqual(MenuBarPresentation.proxyButtonTitle(for: .starting), "Starting...")
        XCTAssertEqual(MenuBarPresentation.proxyButtonTitle(for: .running), "Stop Proxy")
        XCTAssertEqual(MenuBarPresentation.proxyButtonTitle(for: .degraded), "Stop Proxy")
        XCTAssertEqual(MenuBarPresentation.proxyButtonTitle(for: .recovering), "Stop Proxy")
        XCTAssertEqual(MenuBarPresentation.proxyButtonTitle(for: .failed), "Start Proxy")
    }

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

    func testEndpointFormatting() {
        XCTAssertEqual(MenuBarPresentation.endpoint(host: "127.0.0.1", port: 3128), "127.0.0.1:3128")
        XCTAssertEqual(MenuBarPresentation.endpoint(host: nil, port: 3128), "-")
        XCTAssertEqual(MenuBarPresentation.endpoint(host: "127.0.0.1", port: nil), "-")
    }

    func testStatusSubtitlePrefersErrorsThenDirectModeThenHealthThenFallback() {
        XCTAssertEqual(
            MenuBarPresentation.statusSubtitle(
                state: .running,
                proxyError: "proxy failed",
                lastError: "older app error",
                directMode: true,
                directModeCause: .vpnDisconnected,
                healthSummary: "Healthy"
            ),
            "proxy failed"
        )

        XCTAssertEqual(
            MenuBarPresentation.statusSubtitle(
                state: .running,
                proxyError: nil,
                lastError: "app error",
                directMode: true,
                directModeCause: .vpnDisconnected,
                healthSummary: "Healthy"
            ),
            "app error"
        )

        XCTAssertEqual(
            MenuBarPresentation.statusSubtitle(
                state: .running,
                proxyError: nil,
                lastError: nil,
                directMode: true,
                directModeCause: .vpnDisconnected,
                healthSummary: "Healthy"
            ),
            DirectModeCause.vpnDisconnected.healthSummary
        )

        XCTAssertEqual(
            MenuBarPresentation.statusSubtitle(
                state: .running,
                proxyError: nil,
                lastError: nil,
                directMode: false,
                directModeCause: .none,
                healthSummary: "Healthy via proxy"
            ),
            "Healthy via proxy"
        )

        XCTAssertEqual(
            MenuBarPresentation.statusSubtitle(
                state: .stopped,
                proxyError: nil,
                lastError: nil,
                directMode: false,
                directModeCause: .none,
                healthSummary: ""
            ),
            "Menu-bar controller active"
        )
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
