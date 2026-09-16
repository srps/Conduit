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

    func testBurstCollapsesToOneDeliveryOfTheLastValue() async throws {
        let deliveries = Deliveries()
        let queue = DispatchQueue(label: "debouncer.test")
        let debouncer = TrailingDebouncer<Int>(interval: 0.1, queue: queue) { deliveries.append($0) }

        for value in 1...5 {
            debouncer.signal(value)
            try await Task.sleep(for: .milliseconds(10))
        }
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(deliveries.all, [5])
    }

    func testSignalsSpacedBeyondTheIntervalEachDeliver() async throws {
        let deliveries = Deliveries()
        let queue = DispatchQueue(label: "debouncer.test")
        let debouncer = TrailingDebouncer<Int>(interval: 0.05, queue: queue) { deliveries.append($0) }

        debouncer.signal(1)
        try await Task.sleep(for: .milliseconds(150))
        debouncer.signal(2)
        try await Task.sleep(for: .milliseconds(150))

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
