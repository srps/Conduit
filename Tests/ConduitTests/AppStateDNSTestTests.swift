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

    /// The app ready with its DNS forwarder running, and the port it bound.
    private func runningDNS() async throws -> (AppState, ControlPort) {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        harness = try AppStateHarness(config: config, platformConfig: PlatformIntegrationConfig())
        let state = await harness.ready()
        state.toggleDNS()
        await harness.settle("DNS runs") { state.runtime.dnsRunState == .running }
        return (state, try ControlPort(XCTUnwrap(state.runtime.bindings.dnsPort)))
    }

    private func finished(_ state: AppState) async -> DNSTestResult? {
        await harness.settle("the test finished") { if case .finished = state.dnsTest { true } else { false } }
        guard case .finished(let result, _) = state.dnsTest else { return nil }
        return result
    }

    func testAnAnsweringForwarderIsReportedWithItsPort() async throws {
        let (state, port) = try await runningDNS()
        harness.dnsProbe.setAnswering([port.rawValue])
        XCTAssertTrue(state.canTestDNS)

        state.testDNS()
        XCTAssertEqual(state.dnsTest, .testing)
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

    func testDNSCanBeTestedWhileItWarnsOrHasFailed() {
        let testable = ModuleRunState.allCases.filter { DNSTest.probes(in: $0) }
        XCTAssertEqual(testable, [.running, .warning, .failed], "a degraded DNS is when the owner most needs the check")
    }

    func testASettlementWithoutAProbeSaysWhyNothingWasTested() {
        XCTAssertEqual(DNSTestResult(.failed(.effectFailed)), .noPort, "the host had no port to probe")
        XCTAssertEqual(DNSTestResult(nil), .noResult, "not sent, refused, or its answer lost")
    }
}
