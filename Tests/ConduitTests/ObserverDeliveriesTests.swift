// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import PlatformMac

/// `ObserverDeliveries` exists so a test can wait for a host's observer hops
/// instead of polling for their effect (#19). What matters is that `drain()`
/// returns after the work, including work that work started, and never
/// before.
final class ObserverDeliveriesTests: XCTestCase {

    func testDrainReturnsAtOnceWhenNothingIsInFlight() async {
        let deliveries = ObserverDeliveries()
        await deliveries.drain()
        XCTAssertEqual(deliveries.inFlightCount, 0)
    }

    /// The delivery is counted when `deliver` returns, before its task has
    /// run, so a `drain()` that follows straight away cannot slip past it.
    func testDrainWaitsForADeliveryThatHasNotStartedYet() async {
        let deliveries = ObserverDeliveries()
        let ran = NIOLockedValueBox(false)

        deliveries.deliver { ran.withLockedValue { $0 = true } }
        XCTAssertEqual(deliveries.inFlightCount, 1)
        await deliveries.drain()

        XCTAssertTrue(ran.withLockedValue { $0 })
        XCTAssertEqual(deliveries.inFlightCount, 0)
    }

    /// The shape of a VPN change: the handler starts the orchestrator's async
    /// handling, which calls the snapshot callback, which hops again. Each is
    /// started before its cause finishes, so the count never touches zero in
    /// between.
    func testDrainWaitsForTheWholeCascadeADeliveryStarts() async {
        let deliveries = ObserverDeliveries()
        let order = NIOLockedValueBox<[String]>([])

        deliveries.deliver {
            order.withLockedValue { $0.append("handler") }
            deliveries.deliver {
                // Suspends, as the orchestrator does, with the count held.
                try? await Task.sleep(nanoseconds: 20_000_000)
                order.withLockedValue { $0.append("orchestrator") }
                deliveries.deliver { order.withLockedValue { $0.append("snapshot") } }
            }
        }
        await deliveries.drain()

        XCTAssertEqual(order.withLockedValue { $0 }, ["handler", "orchestrator", "snapshot"])
        XCTAssertEqual(deliveries.inFlightCount, 0)
    }

    /// The observers call from their own threads and queues. The work traps
    /// if it runs anywhere but the main actor.
    func testDeliveriesFromOtherThreadsRunOnTheMainActorAndAreWaitedFor() async {
        let deliveries = ObserverDeliveries()
        let count = NIOLockedValueBox(0)
        let started = DispatchGroup()

        for _ in 0..<50 {
            started.enter()
            DispatchQueue.global().async {
                deliveries.deliver {
                    MainActor.preconditionIsolated()
                    count.withLockedValue { $0 += 1 }
                }
                started.leave()
            }
        }
        await withCheckedContinuation { continuation in
            started.notify(queue: .global()) { continuation.resume() }
        }
        await deliveries.drain()

        XCTAssertEqual(count.withLockedValue { $0 }, 50)
    }

    func testEveryWaiterIsReleased() async {
        let deliveries = ObserverDeliveries()
        let gate = NIOLockedValueBox<CheckedContinuation<Void, Never>?>(nil)
        let held = expectation(description: "the delivery is holding the count")

        deliveries.deliver {
            await withCheckedContinuation { continuation in
                gate.withLockedValue { $0 = continuation }
                held.fulfill()
            }
        }
        await fulfillment(of: [held], timeout: 5)

        let released = NIOLockedValueBox(0)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<3 {
                group.addTask {
                    await deliveries.drain()
                    released.withLockedValue { $0 += 1 }
                }
            }
            // Let the three reach `drain()` while the count is still held.
            try? await Task.sleep(nanoseconds: 50_000_000)
            XCTAssertEqual(released.withLockedValue { $0 }, 0, "drain returned while a delivery was in flight")
            gate.withLockedValue { $0 }?.resume()
        }

        XCTAssertEqual(released.withLockedValue { $0 }, 3)
    }
}
