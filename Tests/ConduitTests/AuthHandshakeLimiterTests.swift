// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class AuthHandshakeLimiterTests: XCTestCase {
    func testLimitsClampUserConfiguredNonPositiveValues() {
        let limits = AuthHandshakeLimiter.Limits(total: 0, perSource: -10)

        XCTAssertEqual(limits.total, 1)
        XCTAssertEqual(limits.perSource, 1)
    }

    func testPerSourceLimitRejectsOnlyThatSource() {
        let limiter = AuthHandshakeLimiter()
        let limits = AuthHandshakeLimiter.Limits(total: 10, perSource: 2)

        let first = tryAcquire(limiter, source: "127.0.0.1", limits: limits)
        let second = tryAcquire(limiter, source: "127.0.0.1", limits: limits)

        switch limiter.acquire(source: "127.0.0.1", limits: limits) {
        case .success:
            XCTFail("third acquire from same source should be rejected")
        case .failure(.perSourceLimit(let source, let total, let limit)):
            XCTAssertEqual(source, "127.0.0.1")
            XCTAssertEqual(total, 2)
            XCTAssertEqual(limit, 2)
        case .failure(.totalLimit):
            XCTFail("expected per-source rejection")
        }

        XCTAssertNotNil(tryAcquire(limiter, source: "127.0.0.2", limits: limits))
        first.release()
        second.release()
    }

    func testTotalLimitRejectsAcrossSources() {
        let limiter = AuthHandshakeLimiter()
        let limits = AuthHandshakeLimiter.Limits(total: 2, perSource: 2)

        let first = tryAcquire(limiter, source: "127.0.0.1", limits: limits)
        let second = tryAcquire(limiter, source: "127.0.0.2", limits: limits)

        switch limiter.acquire(source: "127.0.0.3", limits: limits) {
        case .success:
            XCTFail("third total acquire should be rejected")
        case .failure(.totalLimit(let total, let limit)):
            XCTAssertEqual(total, 2)
            XCTAssertEqual(limit, 2)
        case .failure(.perSourceLimit):
            XCTFail("expected total rejection")
        }
        first.release()
        second.release()
    }

    func testReleaseAllowsNextAcquire() {
        let limiter = AuthHandshakeLimiter()
        let limits = AuthHandshakeLimiter.Limits(total: 1, perSource: 1)

        let permit = tryAcquire(limiter, source: "client", limits: limits)
        XCTAssertEqual(limiter.pendingCount, 1)
        permit.release()

        XCTAssertEqual(limiter.pendingCount, 0)
        XCTAssertNotNil(tryAcquire(limiter, source: "client", limits: limits))
    }

    private func tryAcquire(
        _ limiter: AuthHandshakeLimiter,
        source: String,
        limits: AuthHandshakeLimiter.Limits
    ) -> AuthHandshakePermit {
        switch limiter.acquire(source: source, limits: limits) {
        case .success(let permit):
            return permit
        case .failure(let rejection):
            XCTFail("unexpected rejection: \(rejection)")
            fatalError("unreachable")
        }
    }
}
