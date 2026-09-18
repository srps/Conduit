// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class TrailingDebouncerTests: XCTestCase {
    private final class Deliveries: @unchecked Sendable {
        private let lock = NIOLock()
        private var values: [Int] = []
        func append(_ value: Int) { lock.withLock { values.append(value) } }
        var all: [Int] { lock.withLock { values } }
    }

    private func waitUntil(timeout: Duration = .seconds(5), _ condition: @Sendable () -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while !condition(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    func testBurstCollapsesToOneDeliveryOfTheLastValue() async throws {
        let deliveries = Deliveries()
        let queue = DispatchQueue(label: "debouncer.test")
        let debouncer = TrailingDebouncer<Int>(interval: 0.1, queue: queue) { deliveries.append($0) }

        // Signal back to back: a sleep between signals could outlast the
        // interval on a loaded runner and legitimately deliver early.
        for value in 1...5 {
            debouncer.signal(value)
        }
        try await waitUntil { !deliveries.all.isEmpty }
        // Anything else would have to be a second trailing delivery.
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(deliveries.all, [5])
    }

    func testSignalsSpacedBeyondTheIntervalEachDeliver() async throws {
        let deliveries = Deliveries()
        let queue = DispatchQueue(label: "debouncer.test")
        let debouncer = TrailingDebouncer<Int>(interval: 0.05, queue: queue) { deliveries.append($0) }

        // Wait for each delivery rather than a fixed sleep: a late timer on a
        // loaded runner would otherwise let 2 arrive inside 1's interval.
        debouncer.signal(1)
        try await waitUntil { deliveries.all.count == 1 }
        debouncer.signal(2)
        try await waitUntil { deliveries.all.count == 2 }

        XCTAssertEqual(deliveries.all, [1, 2])
    }

    func testCancelDropsThePendingDelivery() async throws {
        let deliveries = Deliveries()
        let queue = DispatchQueue(label: "debouncer.test")
        let debouncer = TrailingDebouncer<Int>(interval: 0.05, queue: queue) { deliveries.append($0) }

        debouncer.signal(1)
        debouncer.cancel()
        try await Task.sleep(for: .milliseconds(150))

        XCTAssertEqual(deliveries.all, [])
    }

    func testZeroIntervalDeliversWithoutWaiting() async throws {
        let deliveries = Deliveries()
        let queue = DispatchQueue(label: "debouncer.test")
        let debouncer = TrailingDebouncer<Int>(interval: 0, queue: queue) { deliveries.append($0) }

        debouncer.signal(7)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(deliveries.all, [7])
    }
}
