// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

/// Test DNS over the actual host: the app shows what the host's probe of the running forwarder found.
@MainActor
final class AppStateDNSTestTests: XCTestCase {
    private var harness: AppStateHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func ready(configure: (inout ProxyConfig) -> Void = { _ in }) async throws -> AppState {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        configure(&config)
        harness = try AppStateHarness(config: config, platformConfig: PlatformIntegrationConfig())
        return await harness.ready()
    }

    /// The app ready with its DNS forwarder running, and the port it bound.
    private func runningDNS() async throws -> (AppState, ControlPort) {
        let state = try await ready()
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        return (state, try ControlPort(XCTUnwrap(state.runtime.bindings.dnsPort)))
    }

    private func finished(_ state: AppState) async -> DNSTestResult? {
        await harness.settle("the test finished") { if case .finished = state.dnsTest { true } else { false } }
        guard case .finished(let result, _) = state.dnsTest else { return nil }
        return result
    }

    /// A snapshot of the forwarder running on `port`, changed by `change`, applied in this turn as the observer applies one.
    private func show(_ state: AppState, port: ControlPort, _ change: (inout ProxyOrchestratorSnapshot) -> Void = { _ in }) throws {
        var kernel = ProxyOrchestratorSnapshot()
        kernel.dnsRunState = .running
        kernel.bindings.dnsHost = ProxyConfig.dnsForwarderHost
        kernel.bindings.dnsPort = port.rawValue
        change(&kernel)
        let incarnation = try XCTUnwrap(state.runtime.stamp?.incarnation)
        state.runtime.apply(snapshot: try WireSnapshotFixture.snapshot(kernel, incarnation: incarnation))
    }

    func testAnAnsweringForwarderIsReportedWithItsPort() async throws {
        let (state, port) = try await runningDNS()
        harness.dnsProbe.setAnswering([port.rawValue])
        XCTAssertTrue(state.canTestDNS)

        state.testDNS()
        XCTAssertTrue(state.dnsTest.isTesting)
        XCTAssertFalse(state.canTestDNS, "a test in flight disables Test DNS")

        let result = await finished(state)
        XCTAssertEqual(result, .answered(port))
        XCTAssertTrue(state.canTestDNS, "a finished test enables Test DNS again")
    }

    func testASilentForwarderIsReportedAsNoAnswer() async throws {
        let (state, port) = try await runningDNS()
        state.testDNS()
        let result = await finished(state)
        XCTAssertEqual(result, .noAnswer(port))
    }

    func testAReadingIsClearedWhenTheForwarderStops() async throws {
        let (state, port) = try await runningDNS()
        harness.dnsProbe.setAnswering([port.rawValue])
        state.testDNS()
        _ = await finished(state)

        state.toggleDNS()
        await harness.settle("DNS stops") { state.runtime.dnsRunState == .stopped }
        XCTAssertEqual(state.dnsTest, .idle, "a reading from the run that stopped is not shown")
    }

    func testAProbeOutWhenTheForwarderStopsShowsNothingWhenItSettles() async throws {
        let (state, port) = try await runningDNS()
        harness.dnsProbe.setAnswering([port.rawValue])
        harness.hold.arm { name, values in name == "dns-probe" && values == [String(port.rawValue)] }
        state.testDNS()
        let held = await harness.hold.waitUntilReached(within: .seconds(5))
        guard held else { return XCTFail("the host never probed the forwarder") }

        state.toggleDNS()
        await harness.settle("DNS stops") { state.runtime.dnsRunState == .stopped }
        XCTAssertEqual(state.dnsTest, .idle, "the probe out describes the run that stopped")
        XCTAssertFalse(state.canTestDNS)

        harness.hold.release()
        await harness.settle("the late answer was set aside") {
            state.logStore.exportDiagnosticLog().contains("DNS test: the answer is not shown")
        }
        XCTAssertEqual(state.dnsTest, .idle, "the probe's answer is about the run that stopped")
    }

    func testANewerDNSFactClearsAReadingAndUnrelatedTelemetryKeepsIt() async throws {
        let (state, port) = try await runningDNS()
        let newer: [(String, (inout ProxyOrchestratorSnapshot) -> Void)] = [
            ("the relay stopped answering", { $0.dnsError = "DNS pipeline unresponsive" }),
            ("the forwarder rebound", { $0.bindings.dnsPort = port.rawValue == 65_535 ? 1 : port.rawValue + 1 }),
            ("the forwarder failed", { $0.dnsRunState = .failed; $0.dnsError = "bind failed" }),
        ]
        for (fact, change) in newer {
            try show(state, port: port)
            state.testDNS()
            _ = await finished(state)

            try show(state, port: port) {
                $0.dnsQueryCount = 7
                $0.runtimeStatus.metrics.requestsHandled = 3
                $0.bindings.proxyPort = 3128
            }
            guard case .finished = state.dnsTest else { return XCTFail("telemetry of the same run cleared the reading before: \(fact)") }

            try show(state, port: port, change)
            XCTAssertEqual(state.dnsTest, .idle, "a reading is not shown beside a newer fact: \(fact)")
        }
    }

    func testATestDroppedAtTheCommandCapEndsAtOnce() async throws {
        let (state, _) = try await runningDNS()
        for _ in 0..<AppState.maximumCommandsInFlight { state.toggleTunnels() }
        state.testDNS()
        guard case .finished(let result, _) = state.dnsTest else { return XCTFail("a dropped test stays testing: \(state.dnsTest)") }
        XCTAssertEqual(result, .noResult)
        XCTAssertTrue(state.canTestDNS, "Test DNS is enabled again")
        XCTAssertTrue(state.logStore.exportDiagnosticLog().contains("test-dns dropped"))
    }

    func testAFailedOrWarningDNSCanBeTested() async throws {
        let (state, port) = try await runningDNS()
        let degraded: [(String, (inout ProxyOrchestratorSnapshot) -> Void)] = [
            ("failed", { $0.dnsRunState = .failed; $0.dnsError = "bind failed"; $0.bindings.dnsPort = nil }),
            ("warning", { $0.dnsError = "DNS pipeline unresponsive" }),
        ]
        for (presented, change) in degraded {
            try show(state, port: port, change)
            XCTAssertTrue(state.canTestDNS, "a \(presented) DNS is when the owner most needs the check")
            state.testDNS()
            XCTAssertTrue(state.dnsTest.isTesting, "Test DNS ran while DNS was \(presented)")
            try show(state, port: port)
        }
    }

    func testASettlementWithoutAProbeSaysWhyNothingWasTested() {
        XCTAssertEqual(DNSTestResult(.failed(.effectFailed)), .noPort, "the host had no port to probe")
        XCTAssertEqual(DNSTestResult(nil), .noResult, "not sent, refused, or its answer lost")
    }
}
