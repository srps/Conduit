// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
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

    /// #155: a VPN transition during the ladder makes its trigger stale. The
    /// ladder stops before the next step and does not declare exhaustion.
    @MainActor func testALadderAVPNTransitionSupersedesStopsWithoutExhaustion() async {
        let events = EventRecorder()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.healthResults = [.unhealthy(summary: "still failing after close")]
        let current = NIOLockedValueBox(true)
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink(), eventSink: events.record)
        service.onCloseStalled = { current.withLockedValue { $0 = false } }

        let result = await recovery.recover(isCurrent: { current.withLockedValue { $0 } })

        XCTAssertFalse(result)
        XCTAssertEqual(service.closeStalledCallCount, 1)
        XCTAssertEqual(service.reauthenticateCallCount, 0)
        XCTAssertEqual(service.switchUpstreamCallCount, 0)
        XCTAssertEqual(events.names, ["recovery.abandoned"])
        XCTAssertEqual(events.details, ["reason=superseded after_step=closeStalledConnections"])
    }

    /// A transition during the last step: neither its success nor its
    /// failure is accepted, and exhaustion is not declared.
    @MainActor func testATransitionDuringTheLastStepAbandonsInsteadOfConcluding() async {
        for (healthy, recycleSucceeds) in [(true, true), (false, true), (false, false)] {
            let events = EventRecorder()
            let service = MockRecoverableService()
            service.recycleListenerShouldSucceed = recycleSucceeds
            service.healthResults = recycleSucceeds
                ? [healthy ? .healthy(summary: "ok") : .unhealthy(summary: "still failing")]
                : []
            let current = NIOLockedValueBox(true)
            service.onRecycleListener = { current.withLockedValue { $0 = false } }
            let recovery = AutoRecovery(service: service, logger: DiscardingLogSink(), eventSink: events.record)

            let result = await recovery.recover(isCurrent: { current.withLockedValue { $0 } })

            XCTAssertFalse(result, "healthy=\(healthy) recycleSucceeds=\(recycleSucceeds)")
            XCTAssertEqual(service.recycleListenerCallCount, 1)
            XCTAssertEqual(events.names, ["recovery.abandoned"])
            XCTAssertEqual(events.details, ["reason=superseded after_step=recycleListener"])
        }
    }

    @MainActor func testRecoveryReturnsFalseWhenAllStepsFail() async {
        let logger = DiscardingLogSink()
        let service = MockRecoverableService()
        let recovery = AutoRecovery(service: service, logger: logger)

        let result = await recovery.recover()
        XCTAssertFalse(result)
        XCTAssertEqual(service.recycleListenerCallCount, 1, "Should try all steps including listener recycle")
    }

    /// #147: a connect timeout cannot be fixed by credentials, and exhaustion
    /// must not blame the password.
    @MainActor func testUnreachableLadderSkipsReauthenticationAndDoesNotMentionPassword() async {
        let logger = RecordingLogSink()
        let events = EventRecorder()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.switchUpstreamShouldSucceed = true
        service.recycleListenerShouldSucceed = true
        service.healthResults = Array(repeating: .unhealthy(.unreachable(detail: "Connect timeout (500 ms)"), responseTimeMS: 500), count: 4)
        let recovery = AutoRecovery(service: service, logger: logger, eventSink: events.record)

        let result = await recovery.recover(trigger: .unreachable(detail: "Connect timeout (500 ms)"))

        XCTAssertFalse(result)
        XCTAssertEqual(service.reauthenticateCallCount, 0)
        XCTAssertEqual(service.closeStalledCallCount, 1)
        XCTAssertEqual(service.switchUpstreamCallCount, 1)
        XCTAssertEqual(service.recycleListenerCallCount, 1)
        XCTAssertEqual(events.names, ["recovery.step_skipped", "recovery.exhausted"])
        XCTAssertEqual(events.details.first, "step=reauthenticate reason=upstream_unreachable summary=Connect timeout (500 ms)")
        XCTAssertTrue(events.details.last?.hasPrefix("failure=unreachable ") == true)
        XCTAssertFalse(logger.entries().contains { $0.message.localizedCaseInsensitiveContains("password") })
        let exhausted = logger.entries().last { $0.level == .error }
        XCTAssertEqual(exhausted?.message.contains("no upstream proxy answered"), true)
    }

    @MainActor func testCredentialFailureRunsReauthenticationAndKeepsPasswordHint() async {
        let logger = RecordingLogSink()
        let events = EventRecorder()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.reauthenticateShouldSucceed = true
        service.healthResults = Array(repeating: .unhealthy(.credentialUnavailable(detail: "407 with no usable credential"), responseTimeMS: 5), count: 4)
        let recovery = AutoRecovery(service: service, logger: logger, eventSink: events.record)

        let result = await recovery.recover(trigger: .credentialUnavailable(detail: "407 with no usable credential"))

        XCTAssertFalse(result)
        XCTAssertEqual(service.reauthenticateCallCount, 1)
        XCTAssertEqual(events.names, ["recovery.exhausted"])
        XCTAssertTrue(events.details.last?.hasPrefix("failure=credential_unavailable ") == true)
        let exhausted = logger.entries().last { $0.level == .error }
        XCTAssertEqual(exhausted?.message.contains("Re-enter your password in Settings"), true)
    }

    /// A ladder that starts unreachable re-authenticates once a step's
    /// health check reports something else: the latest failure decides.
    @MainActor func testReauthenticationRunsWhenLatestFailureIsNoLongerUnreachable() async {
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.reauthenticateShouldSucceed = true
        service.healthResults = [
            .unhealthy(.upstreamStatus(code: 502, upstream: "proxy.example.test:8080"), responseTimeMS: 5),
            .healthy(summary: "healthy after auth reset"),
        ]
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink())

        let result = await recovery.recover(trigger: .unreachable(detail: "Connect timeout (500 ms)"))

        XCTAssertTrue(result)
        XCTAssertEqual(service.reauthenticateCallCount, 1)
    }

    /// An upstream that answered with a final 407 is reachable: the ladder
    /// re-authenticates and the exhaustion line keeps the password hint.
    @MainActor func testAuthenticationRejectionRunsReauthenticationAndKeepsPasswordHint() async {
        let logger = RecordingLogSink()
        let events = EventRecorder()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.reauthenticateShouldSucceed = true
        let rejected = HealthCheckFailure.authenticationRejected(detail: "The upstream proxy rejected authentication.")
        service.healthResults = Array(repeating: .unhealthy(rejected, responseTimeMS: 5), count: 4)
        let recovery = AutoRecovery(service: service, logger: logger, eventSink: events.record)

        let result = await recovery.recover(trigger: rejected)

        XCTAssertFalse(result)
        XCTAssertEqual(service.reauthenticateCallCount, 1)
        XCTAssertEqual(events.names, ["recovery.exhausted"])
        XCTAssertTrue(events.details.last?.hasPrefix("failure=authentication_rejected ") == true)
        let exhausted = logger.entries().last { $0.level == .error }
        XCTAssertEqual(exhausted?.message.contains("Your password may have changed"), true)
    }

    /// A refused trigger is decided before the first step: no side effect and no health
    /// check run, and the outcome is the skip, never exhaustion.
    @MainActor func testConfigurationRefusedTriggerRunsNoStepAndIsNotExhausted() async {
        let events = EventRecorder()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.reauthenticateShouldSucceed = true
        service.switchUpstreamShouldSucceed = true
        service.recycleListenerShouldSucceed = true
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink(), eventSink: events.record)

        let result = await recovery.recover(trigger: .configurationRefused(detail: "health.upstreamResponseTimeout"))

        XCTAssertFalse(result)
        XCTAssertEqual(service.closeStalledCallCount, 0)
        XCTAssertEqual(service.reauthenticateCallCount, 0)
        XCTAssertEqual(service.switchUpstreamCallCount, 0)
        XCTAssertEqual(service.recycleListenerCallCount, 0)
        XCTAssertEqual(service.healthCheckCallCount, 0)
        XCTAssertEqual(events.names, ["recovery.skipped"])
        XCTAssertEqual(events.details.first, "reason=configuration_refused summary=health.upstreamResponseTimeout")
    }

    /// A check that returns the refusal mid-ladder stops the ladder there: the step that
    /// ran is the last side effect, and no later step or check runs.
    @MainActor func testConfigurationRefusalFromAStepCheckStopsTheLadder() async {
        let events = EventRecorder()
        let service = MockRecoverableService()
        service.closeStalledShouldSucceed = true
        service.reauthenticateShouldSucceed = true
        service.switchUpstreamShouldSucceed = true
        service.recycleListenerShouldSucceed = true
        service.healthResults = [.unhealthy(.configurationRefused(detail: "health.connectionCheckTimeout"), responseTimeMS: 5)]
        let recovery = AutoRecovery(service: service, logger: DiscardingLogSink(), eventSink: events.record)

        let result = await recovery.recover(trigger: .upstreamStatus(code: 502, upstream: "proxy.example.test:8080"))

        XCTAssertFalse(result)
        XCTAssertEqual(service.closeStalledCallCount, 1)
        XCTAssertEqual(service.reauthenticateCallCount, 0)
        XCTAssertEqual(service.switchUpstreamCallCount, 0)
        XCTAssertEqual(service.recycleListenerCallCount, 0)
        XCTAssertEqual(service.healthCheckCallCount, 1)
        XCTAssertEqual(events.names, ["recovery.skipped"])
        XCTAssertEqual(events.details.first, "reason=configuration_refused summary=health.connectionCheckTimeout")
    }

    func testHealthCheckClassifiesAFinal407AsRejectionNotUnreachable() {
        XCTAssertEqual(
            ConnectionPool.healthFailure(for: ConnectionPoolError.authenticationRejected, detail: "rejected"),
            .authenticationRejected(detail: "rejected")
        )
        XCTAssertEqual(
            ConnectionPool.healthFailure(for: ConnectionPoolError.upstreamResponseTimedOut, detail: "timeout"),
            .unreachable(detail: "timeout")
        )
    }

    func testExhaustionMessageOnlySuggestsPasswordForCredentialOrUnknownFailures() {
        XCTAssertFalse(AutoRecovery.exhaustion(for: .unreachable(detail: "timeout")).message.contains("password"))
        XCTAssertFalse(AutoRecovery.exhaustion(for: .upstreamStatus(code: 503, upstream: "proxy.example.test:8080")).message.contains("password"))
        XCTAssertTrue(AutoRecovery.exhaustion(for: .credentialUnavailable(detail: "no ticket")).message.contains("password"))
        XCTAssertTrue(AutoRecovery.exhaustion(for: .authenticationRejected(detail: "407")).message.contains("password"))
        XCTAssertEqual(AutoRecovery.exhaustion(for: nil).failure, "unknown")
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
    var onCloseStalled: () -> Void = {}
    var onRecycleListener: () -> Void = {}

    func closeStalledConnections(expecting stamp: ListenerStamp) async throws -> Int {
        closeStalledCallCount += 1
        onCloseStalled()
        if !closeStalledShouldSucceed { throw TestError.simulated }
        return closeStalledClosedCount
    }

    func reauthenticate(expecting stamp: ListenerStamp) async throws {
        reauthenticateCallCount += 1
        if !reauthenticateShouldSucceed { throw TestError.simulated }
    }

    func switchToNextUpstream(expecting stamp: ListenerStamp) async throws -> String? {
        switchUpstreamCallCount += 1
        if !switchUpstreamShouldSucceed { throw TestError.simulated }
        return "proxy-b.example.test:8080"
    }

    /// A server that is never started, so its stamp never moves. The mock answers with it, and its ladder is always current.
    private static let idleServer = LocalProxyServer(
        logger: DiscardingLogSink(),
        configProvider: { ProxyConfig.testFixture() },
        directModeProvider: { (false, .none) },
        authenticatorProvider: { _ in throw TestError.simulated },
        directConnectDetector: DirectConnectDetector(group: MultiThreadedEventLoopGroup.singleton, logger: DiscardingLogSink()),
        pacRoutingEngine: nil,
        onConnectionOpened: { _ in },
        onConnectionClosed: { _ in },
        onRequestCompleted: { _, _ in }
    )

    let listenerStamp = MockRecoverableService.idleServer.listenerStamp

    func recycleListener(expecting stamp: ListenerStamp) async throws -> ListenerStamp {
        recycleListenerCallCount += 1
        onRecycleListener()
        if !recycleListenerShouldSucceed { throw TestError.simulated }
        return stamp
    }

    func performHealthCheck(expecting stamp: ListenerStamp) async throws -> HealthCheckResult {
        healthCheckCallCount += 1
        if healthResults.isEmpty {
            return .unhealthy(summary: "still unhealthy")
        }
        return healthResults.removeFirst()
    }
}

private enum TestError: Error { case simulated }

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []

    var record: @Sendable (RuntimeEvent) -> Void {
        { [self] event in lock.withLock { events.append(event) } }
    }

    var names: [String] { lock.withLock { events.map(\.event) } }
    var details: [String] { lock.withLock { events.compactMap(\.detail) } }
}

private extension HealthCheckResult {
    static func healthy(summary: String) -> HealthCheckResult {
        HealthCheckResult(healthy: true, summary: summary, activeUpstream: "proxy.example.test:8080", responseTimeMS: 1)
    }

    static func unhealthy(summary: String) -> HealthCheckResult {
        HealthCheckResult(healthy: false, summary: summary, activeUpstream: nil, responseTimeMS: 1)
    }
}
