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
