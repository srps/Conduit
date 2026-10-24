// SPDX-License-Identifier: Apache-2.0
import NIOPosix
import XCTest
@testable import ProxyKernel

/// A duration the runtime cannot hold is refused at every entry that would convert it:
/// the explicit health check, tunnel start, the direct-connect detector, and system wake
/// (which builds the detector). Each test drives the real entry point with a config that
/// is out of range, and expects a refusal by field with its structured event, not a trap.
@MainActor
final class ConfigRuntimeRangeRefusalTests: XCTestCase {
    private var group: MultiThreadedEventLoopGroup!

    override func setUp() {
        super.setUp()
        group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    }

    override func tearDown() async throws {
        try await group.shutdownGracefully()
        group = nil
        try await super.tearDown()
    }

    // MARK: - Explicit health check

    /// The check did not run, so it is a configuration refusal, not an upstream failure.
    /// That keeps it out of the recovery ladder, and it emits the structured event first.
    func testHealthCheckRefusesAConnectionCheckTimeoutPastTheRuntimeRange() async {
        var config = ProxyConfig.testFixture()
        config.health.connectionCheckTimeout = 1e10
        let events = EventCollector()
        let pool = makePool(config, events: events)

        let result = await pool.healthCheck(urlString: "http://proxy-a.example.test/")

        XCTAssertFalse(result.healthy)
        guard case .configurationRefused = result.failure else {
            return XCTFail("a refused check must not be classified as an upstream failure: \(String(describing: result.failure))")
        }
        XCTAssertTrue(result.summary.contains("health.connectionCheckTimeout"))
        XCTAssertFalse(result.summary.contains("10000000000"))
        XCTAssertTrue(events.events.contains {
            $0.event == "config.duration_refused" && $0.detail == "scope=health_check field=health.connectionCheckTimeout"
        })
    }

    func testHealthCheckRefusesAnUpstreamResponseTimeoutPastTheRuntimeRange() async {
        var config = ProxyConfig.testFixture()
        config.health.upstreamResponseTimeout = 1e10
        let events = EventCollector()
        let pool = makePool(config, events: events)

        let result = await pool.healthCheck(urlString: "http://proxy-a.example.test/")

        XCTAssertFalse(result.healthy)
        XCTAssertTrue(result.summary.contains("health.upstreamResponseTimeout"))
        XCTAssertTrue(events.events.contains {
            $0.event == "config.duration_refused" && $0.detail == "scope=health_check field=health.upstreamResponseTimeout"
        })
    }

    /// The inventory query: an admitted config names no field, and the exchange set is the
    /// one the pool converts. A field outside that set is not the exchange's concern.
    func testExchangeQueryNamesOnlyAnUnholdableExchangeDuration() {
        XCTAssertNil(ConnectionPool.firstUnrepresentableExchangeDuration(in: ProxyConfig.testFixture()))

        var config = ProxyConfig.testFixture()
        config.health.vpnFlapGraceSeconds = 1e10
        XCTAssertNil(ConnectionPool.firstUnrepresentableExchangeDuration(in: config), "not an exchange duration")

        config.health.upstreamConnectTimeout = 1e10
        XCTAssertEqual(ConnectionPool.firstUnrepresentableExchangeDuration(in: config), .upstreamConnectTimeout)
    }

    // MARK: - Direct-connect detector, built by the orchestrator's real paths

    /// System wake calls `directConnectDetector.clearCache()`, which builds the detector's
    /// lazy initializer from the loaded config. Before the fix this trapped, while the proxy
    /// was stopped, for a persisted connect timeout past the range.
    func testSystemWakeWithAnUnholdableConnectTimeoutDoesNotTrap() async {
        var config = ProxyConfig.testFixture()
        config.health.connectionCheckTimeout = 1e10
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        await orchestrator.handleSystemWake()

        // Reaching this line is the assertion: a trap would end the test run.
    }

    /// The detector starts no probe of any kind with a nil budget. The refusal is reported
    /// through its event sink as `budget_refused`.
    func testDetectorWithoutABudgetStartsNoProbeAndReportsIt() {
        let events = EventCollector()
        let detector = DirectConnectDetector(
            group: group, logger: DiscardingLogSink(), baseTimeoutMS: nil,
            eventSink: { events.append($0) }
        )

        XCTAssertFalse(detector.shortcutReachable(host: "reachable.example.test", port: 443, gatewayMode: false))
        XCTAssertEqual(
            detector.probeForStrictModeHint(host: "strict.example.test", port: 443, gatewayMode: false) {},
            .budgetRefused
        )
        XCTAssertEqual(detector.probeCount, 0)
        XCTAssertNil(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false))
        XCTAssertTrue(events.events.contains { ($0.detail ?? "").contains("reason=budget_refused") })
    }

    /// Invalid construction, then a correction, with no relaunch: probes are refused while the
    /// budget is invalid, and the first valid budget admits a probe.
    func testDetectorAdmitsProbesOnceACorrectedBudgetIsRead() {
        let budget = BudgetBox(nil)
        let events = EventCollector()
        let detector = DirectConnectDetector(
            group: group, logger: DiscardingLogSink(), baseTimeoutProvider: { budget.value },
            resolver: { _, _, loop in loop.makeSucceededFuture([]) },
            eventSink: { events.append($0) }
        )

        XCTAssertFalse(detector.shortcutReachable(host: "reachable.example.test", port: 443, gatewayMode: false))
        XCTAssertEqual(detector.probeCount, 0)
        XCTAssertNil(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false))
        XCTAssertTrue(events.events.contains { ($0.detail ?? "").contains("reason=budget_refused") })

        budget.value = 1_000
        XCTAssertEqual(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false), 1_000)
        XCTAssertFalse(detector.shortcutReachable(host: "reachable.example.test", port: 443, gatewayMode: false))
        XCTAssertEqual(detector.probeCount, 1, "the corrected budget admits a probe")
    }

    /// A valid budget latches and stays fixed: a later change to any value, invalid included,
    /// does not move the budget that probes use.
    func testEstablishedBudgetStaysFixedWhenTheProviderChanges() {
        let budget = BudgetBox(1_000)
        let detector = DirectConnectDetector(
            group: group, logger: DiscardingLogSink(), baseTimeoutProvider: { budget.value },
            resolver: { _, _, loop in loop.makeSucceededFuture([]) }
        )

        XCTAssertEqual(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false), 1_000)
        budget.value = 2_000
        XCTAssertEqual(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false), 1_000)
        budget.value = nil
        XCTAssertEqual(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false), 1_000)
    }

    /// A caller whose budget reading is nil while another caller latches a valid budget returns
    /// that latch, not nil. The race is fixed by the test, not timed: the first caller's read
    /// is held inside the provider until the second caller has latched.
    func testNilReadingThatRacesAValidLatchReturnsTheLatch() {
        let reads = ReadSequence()
        let racingReadStarted = DispatchSemaphore(value: 0)
        let releaseRacingRead = DispatchSemaphore(value: 0)
        let detector = DirectConnectDetector(
            group: group, logger: DiscardingLogSink(),
            baseTimeoutProvider: {
                switch reads.next() {
                case 1: return nil // construction
                case 2: // the racing caller's read: nil, held until released
                    racingReadStarted.signal()
                    releaseRacingRead.wait()
                    return nil
                default: return 1_000 // the second caller: a valid budget
                }
            }
        )
        let racingResult = ResultBox()
        let racingDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            racingResult.value = detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false)
            racingDone.signal()
        }

        XCTAssertEqual(racingReadStarted.wait(timeout: .now() + 5), .success, "the racing read reached the provider")
        XCTAssertEqual(detector.probeTimeoutMS(host: "reachable.example.test", port: 443, gatewayMode: false), 1_000)
        releaseRacingRead.signal()

        XCTAssertEqual(racingDone.wait(timeout: .now() + 5), .success, "the racing call returned")
        XCTAssertEqual(racingResult.value, 1_000, "a nil reading does not hide the valid latch another caller published")
    }

    // MARK: - Tunnel start

    /// Tunnel start converts the same durations, so it refuses before it binds anything.
    /// The refusal is an event on the orchestrator's log, and the snapshot names the field.
    func testStartTunnelsRefusesAnUnholdableExchangeDurationBeforeBinding() async {
        var config = ProxyConfig.testFixture()
        config.health.upstreamResponseTimeout = 1e10
        config.tunnelDefinitions = [
            TunnelDefinition(localPort: 0, remoteHost: "db.example.test", remotePort: 5432, enabled: true),
        ]
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())

        await orchestrator.startTunnels()

        XCTAssertEqual(orchestrator.snapshot.tunnelsRunState, .failed)
        XCTAssertTrue(orchestrator.snapshot.tunnelsError?.contains("health.upstreamResponseTimeout") ?? false)
        XCTAssertFalse(orchestrator.snapshot.tunnelsError?.contains("10000000000") ?? true)
        XCTAssertTrue(orchestrator.eventLog.events.contains {
            $0.event == "config.duration_refused" && $0.detail == "scope=tunnels field=health.upstreamResponseTimeout"
        })
    }

    /// A refused check is its own outcome, not `.unreachable`, so the recovery code can tell
    /// it apart and does not describe it as "no upstream answered".
    func testRefusedCheckIsNotAnUpstreamOutcome() {
        XCTAssertNotEqual(HealthCheckFailure.configurationRefused(detail: "x"), .unreachable(detail: "x"))
        XCTAssertEqual(AutoRecovery.exhaustion(for: .configurationRefused(detail: "x")).failure, "configuration_refused")
    }

    // MARK: - Helpers

    private func makePool(_ config: ProxyConfig, events: EventCollector) -> ConnectionPool {
        ConnectionPool(
            group: group, logger: DiscardingLogSink(), configProvider: { config },
            authenticatorProvider: { _ in throw CancellationError() },
            eventSink: { events.append($0) }
        )
    }
}

/// A connect-budget value the test changes in place, like a correction made in Settings.
private final class BudgetBox: @unchecked Sendable {
    var value: Int64?

    init(_ value: Int64?) {
        self.value = value
    }
}

/// Numbers the provider's reads, from any thread, so the test can script each one.
private final class ReadSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func next() -> Int {
        lock.withLock {
            count += 1
            return count
        }
    }
}

/// Carries a background call's result back. The reader waits on a semaphore before reading it.
private final class ResultBox: @unchecked Sendable {
    var value: Int64?
}

/// Collects the events a refusal emits, for assertions. Each refusal emits before it
/// returns, on the caller's task, so reading after the call sees every event.
private final class EventCollector: @unchecked Sendable {
    private(set) var events: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) {
        events.append(event)
    }
}
