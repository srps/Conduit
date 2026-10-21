// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

private final class CallbackCounter: @unchecked Sendable {
    private var _value = 0
    private let lock = NSLock()
    var value: Int { lock.withLock { _value } }
    func increment() { lock.withLock { _value += 1 } }
}

final class HealthCheckerTests: XCTestCase {
    func testHealthCheckerInvokesOperation() async throws {
        let checker = HealthChecker()
        let expectation = XCTestExpectation(description: "health result delivered")

        checker.start(interval: 0.05) {
            HealthCheckResult(healthy: true, summary: "OK", activeUpstream: "proxy-a.example.test:8080", responseTimeMS: 12)
        } onResult: { result in
            if result.healthy {
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        checker.stop()
    }

    func testIsRunningTracksStartAndStop() {
        let checker = HealthChecker()
        XCTAssertFalse(checker.isRunning)
        checker.start(interval: 10) {
            HealthCheckResult(healthy: true, summary: "OK", activeUpstream: nil, responseTimeMS: 0)
        } onResult: { _ in }
        XCTAssertTrue(checker.isRunning)
        checker.stop()
        XCTAssertFalse(checker.isRunning)
    }

    func testHealthCheckerStopPreventsCallbacks() async throws {
        let checker = HealthChecker()
        let counter = CallbackCounter()

        checker.start(interval: 0.05) {
            HealthCheckResult(healthy: true, summary: "OK", activeUpstream: nil, responseTimeMS: 1)
        } onResult: { _ in
            counter.increment()
        }

        try await Task.sleep(for: .milliseconds(200))
        checker.stop()
        let countAtStop = counter.value
        try await Task.sleep(for: .milliseconds(200))
        let drift = counter.value - countAtStop
        XCTAssertLessThanOrEqual(drift, 1, "At most one in-flight callback after stop()")
    }

    func testHealthCheckerRestartReplacesTimer() async throws {
        let checker = HealthChecker()
        let expectation = XCTestExpectation(description: "second timer fires")

        checker.start(interval: 100) {
            HealthCheckResult(healthy: false, summary: "slow", activeUpstream: nil, responseTimeMS: 999)
        } onResult: { _ in }

        checker.start(interval: 0.02) {
            HealthCheckResult(healthy: true, summary: "fast", activeUpstream: nil, responseTimeMS: 1)
        } onResult: { result in
            if result.healthy {
                expectation.fulfill()
            }
        }

        await fulfillment(of: [expectation], timeout: 1.0)
        checker.stop()
    }
}

/// Parks each check until the test releases it, and calls `onParked` once
/// the continuation is stored, so a test counts checks instead of timing them.
private final class ParkedChecks: @unchecked Sendable {
    private let lock = NSLock()
    private var parked: [String: CheckedContinuation<HealthCheckResult, Never>] = [:]
    private var runs: [String: HealthCheckRun] = [:]

    func park(_ id: String, run: HealthCheckRun, onParked: @escaping @Sendable () -> Void) async -> HealthCheckResult {
        await withCheckedContinuation { continuation in
            lock.withLock {
                parked[id] = continuation
                runs[id] = run
            }
            onParked()
        }
    }

    func run(_ id: String) -> HealthCheckRun? { lock.withLock { runs[id] } }

    func release(_ id: String, with result: HealthCheckResult) {
        let continuation = lock.withLock { parked.removeValue(forKey: id) }
        continuation?.resume(returning: result)
    }
}

final class HealthCheckerRestartTests: XCTestCase {
    /// #181: a check still running when its loop is stopped and restarted
    /// must not free the new run's in-flight slot (which let the next tick
    /// start a second check beside the new run's) and must not be delivered.
    func testStaleCheckAfterRestartNeitherFreesNewRunNorIsDelivered() async {
        let checker = HealthChecker()
        let checks = ParkedChecks()
        let aParked = expectation(description: "run A's check parked")
        let bParked = expectation(description: "run B's check parked")
        let aFinished = expectation(description: "run A's check finished")
        let bDelivered = expectation(description: "run B's check delivered")
        let aDelivered = CallbackCounter(), aSuperseded = CallbackCounter(), bDeliveredCount = CallbackCounter()

        checker.start(interval: 3600, operation: { run in
            await checks.park("A", run: run) { aParked.fulfill() }
        }, onResult: { _ in
            aDelivered.increment(); aFinished.fulfill()
        }, onSuperseded: { _ in
            aSuperseded.increment(); aFinished.fulfill()
        })
        await fulfillment(of: [aParked], timeout: 5)
        XCTAssertTrue(checker.isCheckInFlight)

        checker.stop()
        XCTAssertFalse(checker.isCheckInFlight, "a stopped run's check does not hold the next run's slot")
        checker.start(interval: 3600, operation: { run in
            await checks.park("B", run: run) { bParked.fulfill() }
        }, onResult: { _ in
            bDeliveredCount.increment(); bDelivered.fulfill()
        })
        await fulfillment(of: [bParked], timeout: 5)

        checks.release("A", with: .unhealthy(.unreachable(detail: "stale"), responseTimeMS: 1))
        await fulfillment(of: [aFinished], timeout: 5)
        XCTAssertEqual(aDelivered.value, 0, "the stopped run's result is not delivered")
        XCTAssertEqual(aSuperseded.value, 1, "the stopped run's result is reported as superseded")
        XCTAssertTrue(checker.isCheckInFlight, "the stale check must not free run B's slot under its running check")
        XCTAssertEqual(checks.run("A")?.isCurrent, false)
        XCTAssertEqual(checks.run("B")?.isCurrent, true)

        checks.release("B", with: .healthy(summary: "OK", activeUpstream: nil, responseTimeMS: 1))
        await fulfillment(of: [bDelivered], timeout: 5)
        XCTAssertEqual(bDeliveredCount.value, 1)
        XCTAssertFalse(checker.isCheckInFlight, "run B's own completion frees its slot")
        checker.stop()
        XCTAssertEqual(checks.run("B")?.isCurrent, false)
    }
}
