// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class AutoRecoveryTests: XCTestCase {
    @MainActor func testRecoveryStopsAtFirstStepWhenHealthRecovers() async {
        let logger = DiscardingLogSink()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.healthResults = [
            .healthy(summary: "Healthy after close")
        ]
        let recovery = AutoRecovery(service: service, logger: logger)

        let result = await recovery.recover()
        XCTAssertTrue(result)
        XCTAssertEqual(service.closeStalledCallCount, 1)
        XCTAssertEqual(service.reauthenticateCallCount, 0, "Should not escalate past first success")
    }

    @MainActor func testRecoveryEscalatesWhenStepCompletesButHealthStillFails() async {
        let logger = DiscardingLogSink()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.reauthenticateShouldSucceed = true
        service.switchUpstreamShouldSucceed = true
        service.healthResults = [
            .unhealthy(summary: "still failing after close"),
            .unhealthy(summary: "still failing after auth reset"),
            .healthy(summary: "healthy after upstream switch"),
        ]
        let recovery = AutoRecovery(service: service, logger: logger)

        let result = await recovery.recover()
        XCTAssertTrue(result)
        XCTAssertEqual(service.closeStalledCallCount, 1)
        XCTAssertEqual(service.reauthenticateCallCount, 1)
        XCTAssertEqual(service.switchUpstreamCallCount, 1)
        XCTAssertEqual(service.recycleListenerCallCount, 0)
    }

    @MainActor func testRecoveryReturnsFalseWhenAllStepsFail() async {
        let logger = DiscardingLogSink()
        let service = MockRecoverableService()
        let recovery = AutoRecovery(service: service, logger: logger)

        let result = await recovery.recover()
        XCTAssertFalse(result)
        XCTAssertEqual(service.recycleListenerCallCount, 1, "Should try all steps including listener recycle")
    }

    @MainActor func testRecoveryReturnsFalseWhenServiceIsNil() async {
        let logger = DiscardingLogSink()
        let recovery = AutoRecovery(service: nil, logger: logger)

        let result = await recovery.recover()
        XCTAssertFalse(result)
    }
}

private final class MockRecoverableService: RecoverableProxyService {
    var closeStalledShouldSucceed = false
    var reauthenticateShouldSucceed = false
    var switchUpstreamShouldSucceed = false
    var recycleListenerShouldSucceed = false
    var closeStalledClosedCount = 0
    var healthResults: [HealthCheckResult] = []

    var closeStalledCallCount = 0
    var reauthenticateCallCount = 0
    var switchUpstreamCallCount = 0
    var recycleListenerCallCount = 0
    var healthCheckCallCount = 0

    func closeStalledConnections() async throws -> Int {
        closeStalledCallCount += 1
        if !closeStalledShouldSucceed { throw TestError.simulated }
        return closeStalledClosedCount
    }

    func reauthenticate() async throws {
        reauthenticateCallCount += 1
        if !reauthenticateShouldSucceed { throw TestError.simulated }
    }

    func switchToNextUpstream() async throws -> String? {
        switchUpstreamCallCount += 1
        if !switchUpstreamShouldSucceed { throw TestError.simulated }
        return "proxy-b.example.test:8080"
    }

    func recycleListener() async throws {
        recycleListenerCallCount += 1
        if !recycleListenerShouldSucceed { throw TestError.simulated }
    }

    func performHealthCheck() async -> HealthCheckResult {
        healthCheckCallCount += 1
        if healthResults.isEmpty {
            return .unhealthy(summary: "still unhealthy")
        }
        return healthResults.removeFirst()
    }
}

private enum TestError: Error { case simulated }

private extension HealthCheckResult {
    static func healthy(summary: String) -> HealthCheckResult {
        HealthCheckResult(healthy: true, summary: summary, activeUpstream: "proxy.example.test:8080", responseTimeMS: 1)
    }

    static func unhealthy(summary: String) -> HealthCheckResult {
        HealthCheckResult(healthy: false, summary: summary, activeUpstream: nil, responseTimeMS: 1)
    }
}
