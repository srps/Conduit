// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import SystemConfiguration
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// `FakeTunnelStore`'s semantics, and `SystemTunnelStore` against the live
/// store, which it only reads.
final class TunnelStoreTests: XCTestCase {
    private let queue = DispatchQueue(label: "TunnelStoreTests")

    /// Subscribes and returns the subscription with a count of signals,
    /// read after everything queued so far has run.
    private func subscribe(
        to store: any TunnelStoreReading, file: StaticString = #filePath, line: UInt = #line
    ) throws -> (subscription: any TunnelStoreSubscription, signals: () -> Int) {
        let count = NIOLockedValueBox(0)
        let subscription = try store.subscribe(queue: queue) { count.withLockedValue { $0 += 1 } }.get()
        return (subscription, { [queue] in
            queue.sync {}
            return count.withLockedValue { $0 }
        })
    }

    // MARK: - Fake

    func testAReadIsTheWholeStoreEveryTime() {
        let store = FakeTunnelStore()
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot()))

        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
        store.setInterface("utun0", ipv4: nil, ipv6: ["fe80::2"])
        store.set("State:/Network/Service/com.cisco.anyconnect/IPv4", ["InterfaceName": "utun6", "OverridePrimary": 1])
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun0"),
            .init(
                interface: "utun6", ipv4Addresses: ["192.0.2.10"],
                serviceID: "com.cisco.anyconnect", overridesPrimary: true
            ),
        ])))

        store.setInterface("utun6", ipv4: nil, ipv6: nil)
        store.remove("State:/Network/Service/com.cisco.anyconnect/IPv4")
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [.init(interface: "utun0")])),
                       "nothing of the removed tunnel is remembered")
    }

    func testAChangeSignalsOnlyWhileSubscribed() throws {
        let store = FakeTunnelStore()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)

        let (subscription, signals) = try subscribe(to: store)
        XCTAssertEqual(signals(), 0, "a change before the subscription is not replayed")
        XCTAssertEqual(store.subscriptionCount, 1)

        store.setInterface("utun6", ipv4: [], ipv6: nil)
        store.remove("State:/Network/Interface/utun6/IPv4")
        XCTAssertEqual(signals(), 2)

        store.remove("State:/Network/Interface/utun6/IPv4")
        XCTAssertEqual(signals(), 2, "removing a key that is not there changes nothing")

        subscription.cancel()
        subscription.cancel()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        XCTAssertEqual(signals(), 2)
        XCTAssertEqual(store.subscriptionCount, 0)
    }

    func testEachSubscriptionIsSignalledAndCancelledOnItsOwn() throws {
        let store = FakeTunnelStore()
        let (first, firstSignals) = try subscribe(to: store)
        let (second, secondSignals) = try subscribe(to: store)
        XCTAssertEqual(store.subscriptionCount, 2)

        first.cancel()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)

        XCTAssertEqual(firstSignals(), 0)
        XCTAssertEqual(secondSignals(), 1)
        second.cancel()
    }

    func testADroppedSubscriptionIsCancelled() throws {
        let store = FakeTunnelStore()
        do { _ = try subscribe(to: store) }

        XCTAssertEqual(store.subscriptionCount, 0)
    }

    func testHeldChangesAreSignalledOnceAndDroppedOnesNever() throws {
        let store = FakeTunnelStore()
        let (subscription, signals) = try subscribe(to: store)
        defer { subscription.cancel() }

        store.notifications = .held
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        store.setInterface("utun7", ipv4: ["192.0.2.11"], ipv6: nil)
        XCTAssertEqual(signals(), 0)
        store.deliverHeld()
        XCTAssertEqual(signals(), 1, "two changes, one signal")
        store.deliverHeld()
        XCTAssertEqual(signals(), 1, "nothing was held the second time")

        store.notifications = .dropped
        store.setInterface("utun6", ipv4: nil, ipv6: nil)
        store.notifications = .delivered
        XCTAssertEqual(signals(), 1, "the change is lost")
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun7", ipv4Addresses: ["192.0.2.11"]),
        ])), "and a read still sees it")
    }

    func testReadAndSubscribeFailOnDemandAndRecover() throws {
        let store = FakeTunnelStore()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)

        store.readFailure = .storeRead
        XCTAssertEqual(store.read(), .failed(.storeRead))
        store.readFailure = nil
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun6", ipv4Addresses: ["192.0.2.10"]),
        ])))

        store.subscribeFailure = .storeSubscribe
        XCTAssertThrowsError(try store.subscribe(queue: queue) {}.get()) {
            XCTAssertEqual($0 as? TunnelReading.Failure, .storeSubscribe)
        }
        XCTAssertEqual(store.subscriptionCount, 0)
        store.subscribeFailure = nil
        let (subscription, _) = try subscribe(to: store)
        XCTAssertEqual(store.subscriptionCount, 1)
        subscription.cancel()
    }

    // MARK: - System store

    func testTheLiveStoreReadsAsASnapshotOfTunnelsOnly() throws {
        guard case .snapshot(let snapshot) = SystemTunnelStore().read() else {
            return XCTFail("the dynamic store is readable in a user session and on CI")
        }

        XCTAssertTrue(snapshot.tunnels.allSatisfy { PushedResolverReading.isTunnelInterface($0.interface) })
    }

    func testTheLiveStoreSubscribesAndCancels() throws {
        let (subscription, _) = try subscribe(to: SystemTunnelStore())

        subscription.cancel()
        subscription.cancel()
    }

    func testASubscriptionThatEndsReleasesItsHandler() throws {
        final class Captured: Sendable {}
        weak var cancelled: Captured?
        weak var dropped: Captured?
        try autoreleasepool {
            let first = Captured(), second = Captured()
            cancelled = first
            dropped = second
            let store = SystemTunnelStore()
            try store.subscribe(queue: queue) { _ = first }.get().cancel()
            _ = try store.subscribe(queue: queue) { _ = second }.get()
        }
        // The session lets go of its context a moment after it is detached.
        var waits = 0
        while cancelled != nil || dropped != nil, waits < 200 {
            Thread.sleep(forTimeInterval: 0.01)
            waits += 1
        }

        XCTAssertNil(cancelled, "the store session was the handler's only owner")
        XCTAssertNil(dropped, "a subscription let go without a cancel ends the same way")
    }

    func testAFailedNotificationKeySubscriptionIsReportedAndTheNextSucceeds() throws {
        let failsOnce = FailsOnce()
        let store = SystemTunnelStore(setNotificationKeys: { session, keys in
            failsOnce.attempt() && SCDynamicStoreSetNotificationKeys(session, nil, keys)
        })

        try assertFailsToSubscribeOnce(store)
    }

    func testAFailedDispatchQueueSubscriptionIsReportedAndTheNextSucceeds() throws {
        let failsOnce = FailsOnce()
        let store = SystemTunnelStore(setDispatchQueue: { session, queue in
            (queue == nil || failsOnce.attempt()) && SCDynamicStoreSetDispatchQueue(session, queue)
        })

        try assertFailsToSubscribeOnce(store)
    }

    private func assertFailsToSubscribeOnce(
        _ store: SystemTunnelStore, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertThrowsError(try store.subscribe(queue: queue) {}.get(), file: file, line: line) {
            XCTAssertEqual($0 as? TunnelReading.Failure, .storeSubscribe, file: file, line: line)
        }
        try store.subscribe(queue: queue) {}.get().cancel()
    }

    private final class FailsOnce: Sendable {
        private let attempts = NIOLockedValueBox(0)

        /// False on the first call, true after.
        func attempt() -> Bool {
            attempts.withLockedValue { count in
                defer { count += 1 }
                return count > 0
            }
        }
    }
}
