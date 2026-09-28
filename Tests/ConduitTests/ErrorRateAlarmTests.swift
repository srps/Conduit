// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// #100: a direct route whose origin does not resolve is the destination's
/// problem, not the upstream pool's. Only upstream failures raise
/// `error_rate.alarm` (and its re-probe); every failure still counts.
@MainActor
final class ErrorRateAlarmTests: XCTestCase {
    private func makeRunningOrchestrator() -> ProxyOrchestrator {
        var config = ProxyConfig()
        config.proxy.host = "127.0.0.1"
        config.proxy.port = 0
        config.routing.pacRoutingEnabled = false
        // The alarm's re-probe dials this; port 9 on loopback refuses at once.
        config.upstreams = [UpstreamProxy(name: "alarm-test", host: "127.0.0.1", port: 9, priority: 0)]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        orchestrator.mutateSnapshotForTesting {
            $0.runtimeStatus.state = .running
            $0.directModeCause = .none
        }
        return orchestrator
    }

    private func alarms(_ orchestrator: ProxyOrchestrator) -> Int {
        orchestrator.eventLog.events.filter { $0.event == "error_rate.alarm" }.count
    }

    func testADirectNXDOMAINStormDoesNotRaiseTheAlarm() {
        let orchestrator = makeRunningOrchestrator()
        for _ in 0..<300 {
            orchestrator.recordRequestCompletion(.failed(.origin))
        }
        XCTAssertEqual(alarms(orchestrator), 0, "origin failures on a direct route say nothing about the upstreams")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.metrics.failedRequests, 300, "they still count")
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.metrics.requestsHandled, 300)
    }

    func testClientAndLocalFailuresDoNotRaiseTheAlarm() {
        let orchestrator = makeRunningOrchestrator()
        for _ in 0..<50 {
            orchestrator.recordRequestCompletion(.failed(.client))
            orchestrator.recordRequestCompletion(.failed(.local))
        }
        XCTAssertEqual(alarms(orchestrator), 0)
        XCTAssertEqual(orchestrator.snapshot.runtimeStatus.metrics.failedRequests, 100)
    }

    func testUpstreamFailuresStillRaiseTheAlarm() {
        let orchestrator = makeRunningOrchestrator()
        for _ in 0..<300 {
            orchestrator.recordRequestCompletion(.failed(.origin))
        }
        for _ in 0..<20 {
            orchestrator.recordRequestCompletion(.failed(.upstream))
        }
        XCTAssertEqual(alarms(orchestrator), 1)
        let detail = orchestrator.eventLog.events.first { $0.event == "error_rate.alarm" }?.detail
        XCTAssertEqual(detail, "failures=20 windowSeconds=5", "only the upstream failures filled the window")
    }

    func testRequestOutcomeClassification() {
        XCTAssertTrue(RequestOutcome.failed(.upstream).implicatesUpstream)
        XCTAssertFalse(RequestOutcome.failed(.origin).implicatesUpstream)
        XCTAssertFalse(RequestOutcome.failed(.client).implicatesUpstream)
        XCTAssertFalse(RequestOutcome.failed(.local).implicatesUpstream)
        XCTAssertFalse(RequestOutcome.succeeded.implicatesUpstream)

        XCTAssertEqual(HTTPProxyHandler.upstreamPathFailureClass(ConnectionPoolError.upstreamResponseTimedOut), .upstream)
        XCTAssertEqual(HTTPProxyHandler.upstreamPathFailureClass(ConnectionPoolError.poolExhausted), .local)
        XCTAssertEqual(HTTPProxyHandler.upstreamPathFailureClass(ConnectionPoolError.authHandshakeLimitExceeded), .local)
        XCTAssertEqual(
            HTTPProxyHandler.directPathFailureClass(AddressFamilyAwareResolver.ResolutionError(host: "x.invalid", rc: EAI_NONAME)),
            .origin
        )
        XCTAssertEqual(HTTPProxyHandler.directPathFailureClass(MetadataBlocklist.BlockedAddressError(host: "x", resolvedIP: "127.0.0.1")), .local)
    }
}
