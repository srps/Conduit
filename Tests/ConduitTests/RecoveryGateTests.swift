// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class RecoveryGateTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 10_000)

    func testOnlyOneLadderRunsAtATime() {
        var gate = RecoveryGate(cooldown: 60)
        XCTAssertEqual(gate.begin(now: t0), .run)
        XCTAssertEqual(gate.begin(now: t0 + 1), .alreadyRunning)
        gate.end(recovered: true, now: t0 + 2)
        XCTAssertEqual(gate.begin(now: t0 + 3), .run)
    }

    func testExhaustionStartsCooldownThatExpires() {
        var gate = RecoveryGate(cooldown: 60)
        XCTAssertEqual(gate.begin(now: t0), .run)
        gate.end(recovered: false, now: t0 + 2)

        XCTAssertEqual(gate.begin(now: t0 + 10), .coolingDown(remaining: 52))
        XCTAssertFalse(gate.inFlight)
        XCTAssertEqual(gate.begin(now: t0 + 62), .run)
    }

    func testSuccessfulRecoveryDoesNotCoolDown() {
        var gate = RecoveryGate(cooldown: 60)
        _ = gate.begin(now: t0)
        gate.end(recovered: true, now: t0 + 1)
        XCTAssertEqual(gate.begin(now: t0 + 1), .run)
    }

    func testHealthyResultClearsCooldown() {
        var gate = RecoveryGate(cooldown: 60)
        _ = gate.begin(now: t0)
        gate.end(recovered: false, now: t0 + 1)
        gate.reset()
        XCTAssertEqual(gate.begin(now: t0 + 2), .run)
    }
}
