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
        let subscription = try store.subscribe(
            queue: queue, onChange: { count.withLockedValue { $0 += 1 } },
            onUncancelledRelease: Self.cancelledFirst(file: file, line: line)
        ).get()
        return (subscription, { [queue] in
            queue.sync {}
            return count.withLockedValue { $0 }
        })
    }

    /// The `onUncancelledRelease` of a subscription the test cancels.
    private static func cancelledFirst(
        file: StaticString = #filePath, line: UInt = #line
    ) -> @Sendable (Result<Void, TunnelReading.Failure>) -> Void {
        { XCTFail("a cancelled subscription reported an uncancelled release: \($0)", file: file, line: line) }
    }

    /// Subscribes, lets the subscription go without a cancel, and returns
    /// the signal count and what each uncancelled release reported.
    private func subscribeAndRelease(
        on store: any TunnelStoreReading
    ) throws -> (signals: () -> Int, reports: () -> [Result<Void, TunnelReading.Failure>]) {
        let count = NIOLockedValueBox(0)
        let reported = NIOLockedValueBox<[Result<Void, TunnelReading.Failure>]>([])
        _ = try store.subscribe(
            queue: queue, onChange: { count.withLockedValue { $0 += 1 } },
            onUncancelledRelease: { outcome in reported.withLockedValue { $0.append(outcome) } }
        ).get()
        return ({ [queue] in
            queue.sync {}
            return count.withLockedValue { $0 }
        }, { reported.withLockedValue { $0 } })
    }

    private func assertReports(
        _ reports: [Result<Void, TunnelReading.Failure>], _ expected: [TunnelReading.Failure?],
        _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        let failures = reports.map { report -> TunnelReading.Failure? in
            if case .failure(let failure) = report { return failure }
            return nil
        }
        XCTAssertEqual(failures, expected, message, file: file, line: line)
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
        XCTAssertEqual(signals(), 1)

        try subscription.cancel().get()
        try subscription.cancel().get()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        XCTAssertEqual(signals(), 1)
        XCTAssertEqual(store.subscriptionCount, 0)
    }

    func testAWriteThatChangesNothingSignalsNothing() throws {
        let store = FakeTunnelStore()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        let (subscription, signals) = try subscribe(to: store)

        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        store.set("State:/Network/Interface/utun6/IPv4", ["Addresses": ["192.0.2.10"]])
        store.remove("State:/Network/Interface/utun7/IPv4")

        XCTAssertEqual(signals(), 0)
        try subscription.cancel().get()
    }

    func testAKeyOutsideTheSubscribedPatternsSignalsNothing() throws {
        let store = FakeTunnelStore()
        let (subscription, signals) = try subscribe(to: store)

        store.set("State:/Network/Interface/en0/IPv4", ["Addresses": ["192.0.2.20"]])
        store.set("State:/Network/Global/IPv4", ["PrimaryInterface": "en0"])
        store.set("State:/Network/Interface/utun6/Link", ["Active": true])
        store.remove("State:/Network/Interface/en0/IPv4")
        XCTAssertEqual(signals(), 0)

        store.set("State:/Network/Service/com.cisco.anyconnect/IPv6", ["InterfaceName": "utun6"])
        XCTAssertEqual(signals(), 1, "a service key is subscribed whatever its ID looks like")
        try subscription.cancel().get()
    }

    func testChangesBeforeTheSignalRunsArriveAsOneSignal() throws {
        let store = FakeTunnelStore()
        let (subscription, signals) = try subscribe(to: store)

        queue.suspend()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        store.setInterface("utun6", ipv4: [], ipv6: nil)
        store.setInterface("utun7", ipv4: ["192.0.2.11"], ipv6: nil)
        queue.resume()
        XCTAssertEqual(signals(), 1, "one signal is queued per subscription, however many changes it stands for")

        store.setInterface("utun7", ipv4: nil, ipv6: nil)
        XCTAssertEqual(signals(), 2, "a change after the signal ran is a new signal")
        try subscription.cancel().get()
    }

    func testSeveralKeysChangedTogetherAreOneSignalAndOneReading() throws {
        let store = FakeTunnelStore()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        let (subscription, signals) = try subscribe(to: store)

        store.setAll([
            "State:/Network/Interface/utun6/IPv4": nil,
            "State:/Network/Interface/utun7/IPv4": ["Addresses": ["192.0.2.11"]],
        ])

        XCTAssertEqual(signals(), 1)
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun7", ipv4Addresses: ["192.0.2.11"]),
        ])))
        try subscription.cancel().get()
    }

    func testEachSubscriptionIsSignalledAndCancelledOnItsOwn() throws {
        let store = FakeTunnelStore()
        let (first, firstSignals) = try subscribe(to: store)
        let (second, secondSignals) = try subscribe(to: store)
        XCTAssertEqual(store.subscriptionCount, 2)

        try first.cancel().get()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)

        XCTAssertEqual(firstSignals(), 0)
        XCTAssertEqual(secondSignals(), 1)
        try second.cancel().get()
    }

    func testACancelTakesBackASignalThatHasNotRun() throws {
        let store = FakeTunnelStore()
        let (subscription, signals) = try subscribe(to: store)

        queue.suspend()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        try subscription.cancel().get()
        queue.resume()

        XCTAssertEqual(signals(), 0)
    }

    func testASignalQueuedBeforeACancelRunsWhenTheStoreIsToldToLetIt() throws {
        let store = FakeTunnelStore()
        store.signalsQueuedBeforeCancelStillRun = true
        let (subscription, signals) = try subscribe(to: store)

        queue.suspend()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        try subscription.cancel().get()
        store.setInterface("utun6", ipv4: nil, ipv6: nil)
        queue.resume()

        XCTAssertEqual(signals(), 1, "the one already queued, and none for the change after the cancel")
    }

    func testHeldChangesReachOnlyTheSubscriptionsThatWereThere() throws {
        let store = FakeTunnelStore()
        let (early, earlySignals) = try subscribe(to: store)

        store.notifications = .held
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        store.setInterface("utun7", ipv4: ["192.0.2.11"], ipv6: nil)
        let (late, lateSignals) = try subscribe(to: store)
        XCTAssertEqual(earlySignals(), 0)

        store.deliverHeld()
        XCTAssertEqual(earlySignals(), 1, "two changes, one signal")
        XCTAssertEqual(lateSignals(), 0, "a change from before a subscription is never delivered to it")
        store.deliverHeld()
        XCTAssertEqual(earlySignals(), 1, "nothing was held the second time")
        try early.cancel().get()
        try late.cancel().get()
    }

    func testAHeldChangeIsNotDeliveredToTheNextSession() throws {
        let store = FakeTunnelStore()
        let (stopped, stoppedSignals) = try subscribe(to: store)
        store.notifications = .held
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)
        try stopped.cancel().get()

        let (restarted, restartedSignals) = try subscribe(to: store)
        store.deliverHeld()

        XCTAssertEqual(stoppedSignals(), 0)
        XCTAssertEqual(restartedSignals(), 0)
        try restarted.cancel().get()
    }

    func testDroppedChangesAreNeverSignalledAndStillRead() throws {
        let store = FakeTunnelStore()
        let (subscription, signals) = try subscribe(to: store)

        store.notifications = .dropped
        store.setInterface("utun7", ipv4: ["192.0.2.11"], ipv6: nil)
        store.notifications = .delivered
        store.deliverHeld()

        XCTAssertEqual(signals(), 0, "the change is lost")
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun7", ipv4Addresses: ["192.0.2.11"]),
        ])), "and a read still sees it")
        try subscription.cancel().get()
    }

    func testReadSubscribeAndCancelFailOnDemandAndRecover() throws {
        let store = FakeTunnelStore()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)

        store.readFailure = .init(.storeRead, code: 1001)
        XCTAssertEqual(store.read(), .failed(.init(.storeRead, code: 1001)))
        store.readFailure = nil
        XCTAssertEqual(store.read(), .snapshot(TunnelSnapshot(tunnels: [
            .init(interface: "utun6", ipv4Addresses: ["192.0.2.10"]),
        ])))

        store.subscribeFailure = .init(.storeSubscribe, code: 1001)
        XCTAssertThrowsError(
            try store.subscribe(queue: queue, onChange: {}, onUncancelledRelease: Self.cancelledFirst()).get()
        ) {
            XCTAssertEqual($0 as? TunnelReading.Failure, .init(.storeSubscribe, code: 1001))
        }
        XCTAssertEqual(store.subscriptionCount, 0)
        store.subscribeFailure = nil

        let (subscription, signals) = try subscribe(to: store)
        store.cancelFailure = .init(.storeUnsubscribe, code: 1002)
        XCTAssertThrowsError(try subscription.cancel().get()) {
            XCTAssertEqual($0 as? TunnelReading.Failure, .init(.storeUnsubscribe, code: 1002))
        }
        XCTAssertEqual(store.subscriptionCount, 0, "a cancel that reports a failure still ends the subscription")
        try subscription.cancel().get()
        store.setInterface("utun6", ipv4: nil, ipv6: nil)
        XCTAssertEqual(signals(), 0)
    }

    func testASubscriptionReleasedUncancelledStopsDeliveringAndReportsIt() throws {
        let store = FakeTunnelStore()
        store.trapsOnUncancelledRelease = false

        let (signals, reports) = try subscribeAndRelease(on: store)
        XCTAssertEqual(store.subscriptionCount, 0, "the release ended the subscription")
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: nil)

        XCTAssertEqual(signals(), 0)
        assertReports(reports(), [nil], "one report, of a detach that succeeded")
    }

    func testASubscriptionReleasedUncancelledReportsADetachTheStoreRefuses() throws {
        let store = FakeTunnelStore()
        store.trapsOnUncancelledRelease = false
        store.cancelFailure = .init(.storeUnsubscribe, code: 1002)

        let (_, reports) = try subscribeAndRelease(on: store)

        assertReports(reports(), [.init(.storeUnsubscribe, code: 1002)])
        XCTAssertEqual(store.subscriptionCount, 0)
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

        try subscription.cancel().get()
        try subscription.cancel().get()
    }

    func testACancelledSubscriptionReleasesItsHandler() throws {
        final class Captured: Sendable {}
        weak var cancelled: Captured?
        try autoreleasepool {
            let captured = Captured()
            cancelled = captured
            try SystemTunnelStore().subscribe(
                queue: queue, onChange: { _ = captured }, onUncancelledRelease: Self.cancelledFirst()
            ).get().cancel().get()
        }

        XCTAssertTrue(isReleased { cancelled }, "the store session was the handler's only owner")
    }

    func testALiveSubscriptionReleasedUncancelledDetachesReportsAndReleasesItsHandler() throws {
        final class Captured: Sendable {}
        let detaches = NIOLockedValueBox(0)
        let reported = NIOLockedValueBox<[Result<Void, TunnelReading.Failure>]>([])
        var calls = SystemTunnelStore.Calls()
        calls.setDispatchQueue = { session, queue in
            if queue == nil { detaches.withLockedValue { $0 += 1 } }
            return SCDynamicStoreSetDispatchQueue(session, queue)
        }
        calls.releasedUncancelled = {}
        weak var released: Captured?
        try autoreleasepool {
            let captured = Captured()
            released = captured
            _ = try SystemTunnelStore(calls: calls).subscribe(
                queue: queue, onChange: { _ = captured },
                onUncancelledRelease: { outcome in reported.withLockedValue { $0.append(outcome) } }
            ).get()
        }

        XCTAssertEqual(detaches.withLockedValue { $0 }, 1, "the release detached the queue")
        assertReports(reported.withLockedValue { $0 }, [nil], "one report, of a detach that succeeded")
        XCTAssertTrue(isReleased { released }, "the store session was the handler's only owner")
    }

    func testALiveSubscriptionReleasedUncancelledReportsADetachTheStoreRefuses() throws {
        // The queue is never attached, so the store itself refuses the detach.
        let reported = NIOLockedValueBox<[Result<Void, TunnelReading.Failure>]>([])
        var calls = SystemTunnelStore.Calls()
        calls.setDispatchQueue = { session, queue in queue != nil || SCDynamicStoreSetDispatchQueue(session, nil) }
        calls.releasedUncancelled = {}

        _ = try SystemTunnelStore(calls: calls).subscribe(
            queue: queue, onChange: {},
            onUncancelledRelease: { outcome in reported.withLockedValue { $0.append(outcome) } }
        ).get()

        assertReports(reported.withLockedValue { $0 }, [.init(.storeUnsubscribe, code: Int32(kSCStatusInvalidArgument))])
    }

    /// The session lets go of its context a moment after it is detached, so
    /// this waits up to two seconds for the object to go.
    private func isReleased(_ object: () -> AnyObject?) -> Bool {
        var waits = 0
        while object() != nil, waits < 200 {
            Thread.sleep(forTimeInterval: 0.01)
            waits += 1
        }
        return object() == nil
    }

    func testAFailedNotificationKeySubscriptionIsReportedWithTheStoresCodeAndTheNextSucceeds() throws {
        let failsOnce = FailsOnce()
        var calls = SystemTunnelStore.Calls()
        calls.setNotificationKeys = { session, keys in
            failsOnce.attempt() && SCDynamicStoreSetNotificationKeys(session, nil, keys)
        }
        calls.lastError = { 1001 }

        try assertFailsToSubscribeOnce(SystemTunnelStore(calls: calls))
    }

    func testAFailedDispatchQueueSubscriptionIsReportedWithTheStoresCodeAndTheNextSucceeds() throws {
        let failsOnce = FailsOnce()
        var calls = SystemTunnelStore.Calls()
        calls.setDispatchQueue = { session, queue in
            (queue == nil || failsOnce.attempt()) && SCDynamicStoreSetDispatchQueue(session, queue)
        }
        calls.lastError = { 1001 }

        try assertFailsToSubscribeOnce(SystemTunnelStore(calls: calls))
    }

    private func assertFailsToSubscribeOnce(
        _ store: SystemTunnelStore, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        XCTAssertThrowsError(
            try store.subscribe(queue: queue, onChange: {}, onUncancelledRelease: Self.cancelledFirst()).get(),
            file: file, line: line
        ) {
            XCTAssertEqual($0 as? TunnelReading.Failure, .init(.storeSubscribe, code: 1001), file: file, line: line)
        }
        try store.subscribe(queue: queue, onChange: {}, onUncancelledRelease: Self.cancelledFirst()).get().cancel().get()
    }

    func testACancelTheStoreRefusesIsReturnedWithTheStoresOwnCode() throws {
        // The queue is never attached, so the real detach has nothing to
        // detach and the store itself refuses it.
        var calls = SystemTunnelStore.Calls()
        calls.setDispatchQueue = { session, queue in queue != nil || SCDynamicStoreSetDispatchQueue(session, nil) }
        let subscription = try SystemTunnelStore(calls: calls).subscribe(
            queue: queue, onChange: {}, onUncancelledRelease: Self.cancelledFirst()
        ).get()

        XCTAssertThrowsError(try subscription.cancel().get()) {
            XCTAssertEqual(
                $0 as? TunnelReading.Failure, .init(.storeUnsubscribe, code: Int32(kSCStatusInvalidArgument))
            )
        }
        try subscription.cancel().get()
    }

    func testAFailedReadCarriesTheStoresCodeAndTheNextReadOpensANewSession() throws {
        let sessions = UsedSessions()
        var calls = SystemTunnelStore.Calls()
        calls.copyMultiple = { session, patterns in
            sessions.record(session) == 2 ? nil : SCDynamicStoreCopyMultiple(session, nil, patterns)
        }
        calls.lastError = { Int32(kSCStatusNoStoreServer) }
        let store = SystemTunnelStore(calls: calls)

        guard case .snapshot = store.read() else { return XCTFail("the first read succeeds") }
        XCTAssertEqual(store.read(), .failed(.init(.storeRead, code: Int32(kSCStatusNoStoreServer))))
        guard case .snapshot = store.read() else { return XCTFail("the read after a failure succeeds") }
        guard case .snapshot = store.read() else { return XCTFail("and so does the next") }

        let used = sessions.all
        XCTAssertTrue(used[0] === used[1], "a session is kept while it reads")
        XCTAssertFalse(used[1] === used[2], "the session that failed is not used again")
        XCTAssertTrue(used[2] === used[3])
    }

    /// Keeps every session a read used, so two of them are never one address
    /// reused.
    private final class UsedSessions: @unchecked Sendable {
        private let lock = NSLock()
        private var sessions: [SCDynamicStore] = []

        var all: [SCDynamicStore] { lock.withLock { sessions } }

        /// Returns how many reads there have been, this one included.
        func record(_ session: SCDynamicStore) -> Int {
            lock.withLock {
                sessions.append(session)
                return sessions.count
            }
        }
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
