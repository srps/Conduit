// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyAuth

final class GSSInitiatorGateTests: XCTestCase {
    private struct KDCUnreachable: Error {}
    private struct NoTicket: Error {}

    private final class Clock: @unchecked Sendable {
        var now = Date(timeIntervalSince1970: 1_000)
    }

    private func makeGate(cooldown: TimeInterval = 5) -> (GSSInitiatorGate, Clock) {
        let clock = Clock()
        return (GSSInitiatorGate(cooldown: cooldown, now: { clock.now }), clock)
    }

    func testFailureStartsCooldownThatRethrowsWithoutRunningBody() throws {
        let (gate, clock) = makeGate()
        var runs = 0

        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { runs += 1; throw KDCUnreachable() })
        XCTAssertEqual(runs, 1)

        clock.now += 4
        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { runs += 1; return 0 }) { error in
            XCTAssertTrue(error is KDCUnreachable, "cooldown must rethrow the original failure")
        }
        XCTAssertEqual(runs, 1, "body must not run during the cooldown")

        clock.now += 2
        XCTAssertEqual(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { runs += 1; return 42 }, 42)
        XCTAssertEqual(runs, 2)
    }

    func testCooldownIsScopedToTheFailingTarget() throws {
        let (gate, _) = makeGate()
        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { throw KDCUnreachable() })

        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { XCTFail("must not run"); return 0 })
        XCTAssertEqual(try gate.run(target: "proxy-b", shouldCoolDown: { _ in true }) { 7 }, 7,
                       "failover to the next upstream must not inherit the first one's failure")
    }

    func testCooldownStartsWhenTheCallFailsNotWhenItStarted() throws {
        let (gate, clock) = makeGate(cooldown: 5)
        // The KDC takes longer than the cooldown to give up.
        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) {
            clock.now += 8
            throw KDCUnreachable()
        })

        var ran = false
        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { ran = true })
        XCTAssertFalse(ran, "the cooldown is measured from the failure, so the next call is still inside it")
    }

    func testExemptFailuresDoNotStartCooldown() throws {
        let (gate, _) = makeGate()
        var runs = 0
        let exempt: (Error) -> Bool = { !($0 is NoTicket) }

        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: exempt) { runs += 1; throw NoTicket() })
        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: exempt) { runs += 1; throw NoTicket() })
        XCTAssertEqual(runs, 2, "a credential-absence error is repeated on every call")
    }

    func testSuccessAfterCooldownClearsIt() throws {
        let (gate, clock) = makeGate(cooldown: 1)
        XCTAssertThrowsError(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { throw KDCUnreachable() })
        clock.now += 1
        XCTAssertNoThrow(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { () })
        XCTAssertNoThrow(try gate.run(target: "proxy-a", shouldCoolDown: { _ in true }) { () })
    }

    private final class OverlapCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var concurrent = 0
        private(set) var maxConcurrent = 0
        func enter() { lock.lock(); concurrent += 1; maxConcurrent = max(maxConcurrent, concurrent); lock.unlock() }
        func leave() { lock.lock(); concurrent -= 1; lock.unlock() }
    }

    func testBodiesNeverOverlap() {
        let (gate, _) = makeGate()
        let counter = OverlapCounter()
        let group = DispatchGroup()

        for _ in 0..<16 {
            DispatchQueue.global().async(group: group) {
                try? gate.run(target: "proxy-a", shouldCoolDown: { _ in false }) {
                    counter.enter()
                    usleep(2_000)
                    counter.leave()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(counter.maxConcurrent, 1)
    }
}
