// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// `VPNStatusMonitor` over `FakeTunnelStore` and a held clock: what it reads,
/// when it wakes, and what it reports. Time moves only when the test fires the
/// one wake-up the monitor holds, so nothing here is timed.
final class VPNStatusMonitorTests: XCTestCase {
    private let store = FakeTunnelStore()
    private let clock = FakeStoreObserverClock()
    private var monitor: VPNStatusMonitor!
    private var seen: Seen!

    override func setUp() {
        super.setUp()
        monitor = VPNStatusMonitor(store: store, clock: clock.clock)
        seen = Seen(monitor)
    }

    override func tearDown() {
        monitor.stop()
        monitor = nil
        super.tearDown()
    }

    private func connect(_ interface: String = "utun6") {
        store.setInterface(interface, ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
    }

    // MARK: - Readings

    func testAStartReadsTheStoreAndArmsTheAudit() {
        connect()
        monitor.start()

        XCTAssertEqual(seen.states(1), [.connected])
        XCTAssertEqual(seen.names.last?.connected, "utun6")
        XCTAssertEqual(seen.names.last?.live, ["utun6"])
        XCTAssertEqual(clock.awaitSleep(), .init(seconds: 60, tolerance: 6), "a healthy session audits every 60 s")
        XCTAssertEqual(store.subscriptionCount, 1)
    }

    func testAStartOnAStoreWithNoAddressedTunnelIsDisconnected() {
        store.setInterface("utun0", ipv4: nil, ipv6: ["fe80::2"])
        monitor.start()

        XCTAssertEqual(seen.states(1), [.disconnected(reason: .unknown)])
    }

    func testANotificationIsReconciledAgainstTheWholeStore() {
        connect()
        monitor.start()
        XCTAssertEqual(seen.states(1), [.connected])

        store.setInterface("utun6", ipv4: nil, ipv6: nil)

        XCTAssertEqual(seen.states(2), [.connected, .disconnected(reason: .userInitiated)])
        XCTAssertEqual(seen.names.last?.live, [])
    }

    func testADroppedNotificationIsCorrectedByTheAudit() {
        connect()
        monitor.start()
        XCTAssertEqual(seen.states(1), [.connected])
        XCTAssertNotNil(clock.awaitSleep())

        store.notifications = .dropped
        store.setInterface("utun6", ipv4: nil, ipv6: nil)
        XCTAssertEqual(seen.states(1), [.connected], "the store said nothing")

        XCTAssertEqual(clock.fire()?.seconds, 60)
        XCTAssertEqual(seen.states(2), [.connected, .disconnected(reason: .userInitiated)])
        XCTAssertEqual(clock.awaitSleep()?.seconds, 60, "the next audit")
    }

    // MARK: - Flaps

    func testAFlapWakesAtEachDeadlineOfTheTimer() {
        connect()
        monitor.start()
        XCTAssertEqual(seen.states(1), [.connected])
        XCTAssertNotNil(clock.awaitSleep())

        store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
        XCTAssertEqual(clock.awaitSleep(matching: { $0.seconds == 1 })?.tolerance ?? -1, 0.1, accuracy: 1e-9,
                       "the debounce comes before the audit")
        clock.fire()
        XCTAssertEqual(seen.states(2), [.connected, .reasserting])
        XCTAssertEqual(clock.awaitSleep(matching: { $0.seconds == 5 })?.seconds, 5, "then the grace end")
        clock.fire()

        XCTAssertEqual(seen.states(3), [.connected, .reasserting, .disconnected(reason: .networkLost)])
        XCTAssertEqual(seen.names.last?.live, ["utun6"], "a tunnel that lost its address is not gone")
        XCTAssertEqual(clock.awaitSleep(matching: { $0.seconds == 60 })?.seconds, 60)
        XCTAssertEqual(clock.overlappingSleeps, 0)
    }

    func testAStopDuringAFlapCancelsTheWakeUpAndTheNextStartReadsAFreshSession() {
        connect()
        monitor.start()
        XCTAssertEqual(seen.states(1), [.connected])
        store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
        XCTAssertNotNil(clock.awaitSleep(matching: { $0.seconds == 1 }))

        monitor.stop()
        XCTAssertTrue(clock.awaitNoSleep(), "the stop cancelled the deadline")
        XCTAssertEqual(store.subscriptionCount, 0)

        monitor.start()
        XCTAssertEqual(seen.states(2), [.connected, .disconnected(reason: .unknown)],
                       "decision 1: flap memory does not survive a stop, so the store reads as off VPN")
        XCTAssertEqual(store.subscriptionCount, 1)
    }

    func testACallFromAnEarlierSessionIsIgnored() {
        let queue = DispatchQueue(label: "VPNStatusMonitorTests.late")
        let monitor = VPNStatusMonitor(store: store, clock: clock.clock, queue: queue)
        let seen = Seen(monitor)
        defer { monitor.stop() }
        store.signalsQueuedBeforeCancelStillRun = true
        connect()
        monitor.start()
        XCTAssertEqual(seen.states(1), [.connected])
        XCTAssertNotNil(clock.awaitSleep())
        let reads = store.readCount

        queue.suspend()
        store.setInterface("utun6", ipv4: nil, ipv6: nil)
        monitor.stop()
        monitor.start()
        queue.resume()

        XCTAssertEqual(seen.states(2), [.connected, .disconnected(reason: .unknown)],
                       "the new session's first reading, with no memory of the tunnel")
        queue.sync {}
        XCTAssertEqual(store.readCount, reads + 1, "the signal queued for the stopped session read nothing")
    }

    // MARK: - A store that cannot be read (decision 0048)

    func testAFailedReadIsUnknownRetriedOnTheScheduleAndReportedUntilItRecovers() {
        connect()
        store.readFailure = .init(.storeRead, code: 1001)
        monitor.start()

        XCTAssertEqual(seen.states(1), [.unknown])
        XCTAssertEqual(clock.awaitSleep(), .init(seconds: 1, tolerance: 0.1))
        clock.fire()
        XCTAssertEqual(clock.awaitSleep(matching: { $0.seconds == 2 })?.seconds, 2)
        clock.fire()
        XCTAssertEqual(clock.awaitSleep(matching: { $0.seconds == 4 })?.seconds, 4)

        store.readFailure = nil
        clock.fire()
        XCTAssertEqual(seen.states(2), [.unknown, .connected])
        XCTAssertEqual(clock.awaitSleep(matching: { $0.seconds == 60 })?.seconds, 60)
        XCTAssertEqual(seen.events(3), [
            "vpn.store_failed reason=store_read code=1001 attempt=1",
            "vpn.store_failed reason=store_read code=1001 attempt=2",
            "vpn.store_recovered attempts=3",
        ], "attempt 3 is not reported")
        XCTAssertEqual(store.subscriptionCount, 1, "a read retry keeps the subscription")
    }

    func testAFailedSubscribeIsRetriedOnANewSubscription() {
        connect()
        store.subscribeFailure = .init(.storeSubscribe, code: 1002)
        monitor.start()
        XCTAssertEqual(seen.states(1), [.unknown])
        XCTAssertEqual(store.subscriptionCount, 0)

        store.subscribeFailure = nil
        XCTAssertNotNil(clock.awaitSleep())
        clock.fire()

        XCTAssertEqual(seen.states(2), [.unknown, .connected])
        XCTAssertEqual(store.subscriptionCount, 1)
        XCTAssertEqual(seen.events(2), ["vpn.store_failed reason=store_subscribe code=1002 attempt=1", "vpn.store_recovered attempts=1"])
    }

    func testAStopDuringARetryCancelsIt() {
        store.readFailure = .init(.storeRead, code: 1001)
        monitor.start()
        XCTAssertEqual(seen.states(1), [.unknown])
        XCTAssertNotNil(clock.awaitSleep())

        monitor.stop()

        XCTAssertTrue(clock.awaitNoSleep())
        XCTAssertNil(clock.fire())
    }

    // MARK: - Stop is a barrier for deliveries

    /// The review's ordering on #317: a reconcile passed its entry check and was reading the window when the host
    /// stopped the monitor. Released after the stop, it publishes nothing: an obsolete `.connected` would turn the
    /// host's retained gate to wanted after its teardown.
    func testAReconcileOvertakenByAStopPublishesNothing() {
        let queue = DispatchQueue(label: "VPNStatusMonitorTests.held")
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let windowReads = Counter()
        let monitor = VPNStatusMonitor(
            graceSecondsProvider: {
                if windowReads.next() == 1 {
                    entered.signal()
                    _ = release.wait(timeout: .now() + 5)
                }
                return 5
            },
            store: store, clock: clock.clock, queue: queue
        )
        let seen = Seen(monitor)
        connect()
        monitor.start()
        XCTAssertEqual(entered.wait(timeout: .now() + 5), .success, "the first reconcile is reading the window")

        monitor.stop()
        release.signal()
        queue.sync {}

        XCTAssertEqual(seen.states(0), [], "no state of the stopped session after stop returned")
        XCTAssertEqual(seen.events(0), [])
        XCTAssertNil(monitor.connectedInterfaceName)
        XCTAssertEqual(monitor.liveInterfaceNames, [])
        XCTAssertNil(clock.pendingSleep, "no wake-up armed for the stopped session")
    }

    /// A consumer may stop the monitor from a callback on the monitor's queue. The stop returns at once, and the
    /// delivery that called it publishes nothing after it: here the event comes first and the state is dropped.
    func testAStopFromInsideACallbackReturnsAndPublishesNothingAfterIt() {
        let queue = DispatchQueue(label: "VPNStatusMonitorTests.reentrant")
        let monitor = VPNStatusMonitor(store: store, clock: clock.clock, queue: queue)
        let seen = Seen(monitor)
        let events = Counter()
        monitor.setOnEvent { [weak monitor] _, _ in
            _ = events.next()
            monitor?.stop()
        }
        store.readFailure = .init(.storeRead, code: 1001)
        monitor.start()
        queue.sync {}

        XCTAssertEqual(events.value, 1, "vpn.store_failed was emitted")
        XCTAssertEqual(seen.states(0), [], "the .unknown after it belonged to the stopped session")
        XCTAssertEqual(store.subscriptionCount, 0)

        store.readFailure = nil
        connect()
        monitor.setOnChange { [weak monitor] _ in monitor?.stop() }
        monitor.start()
        queue.sync {}
        XCTAssertEqual(store.subscriptionCount, 0, "a stop from onChange returned and ended the session")
        XCTAssertEqual(monitor.connectedInterfaceName, "utun6", "the names were published before the callback")
    }

    // MARK: - Reports

    func testAMalformedTunnelKeyIsReportedOnceWhileItStays() {
        store.set("State:/Network/Interface/utun6/IPv4", ["Addresses": 7])
        monitor.start()
        XCTAssertEqual(seen.states(1), [.disconnected(reason: .unknown)])
        store.setInterface("utun7", ipv4: ["192.0.2.11"], ipv6: nil)
        XCTAssertEqual(seen.states(2).last, .connected)

        XCTAssertEqual(seen.events(1), ["vpn.store_key_malformed key=State:/Network/Interface/utun6/IPv4"])
    }

    func testACancelThatFailsIsReported() {
        connect()
        monitor.start()
        XCTAssertEqual(seen.states(1), [.connected])
        store.cancelFailure = .init(.storeUnsubscribe, code: 1003)

        monitor.stop()

        XCTAssertEqual(seen.events(1), ["vpn.store_unsubscribe_failed code=1003"])
    }

    func testAnUncancelledReleaseIsAnEvent() {
        let detached = VPNStatusMonitor.uncancelledReleaseEvent(.success(()))
        let refused = VPNStatusMonitor.uncancelledReleaseEvent(.failure(.init(.storeUnsubscribe, code: 1003)))

        XCTAssertEqual("\(detached.event) \(detached.detail ?? "")", "vpn.store_released_uncancelled outcome=detached")
        XCTAssertEqual("\(refused.event) \(refused.detail ?? "")", "vpn.store_released_uncancelled outcome=store_unsubscribe code=1003")
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func next() -> Int { lock.withLock { count += 1; return count } }
}

/// What a monitor delivered and emitted, waited for with a bound.
private final class Seen: @unchecked Sendable {
    private let condition = NSCondition()
    private var delivered: [VPNObservedState] = []
    private var reported: [String] = []
    private var named: [(connected: String?, live: [String])] = []

    init(_ monitor: VPNStatusMonitor) {
        monitor.setOnChange { [self, weak monitor] state in
            let connected = monitor?.connectedInterfaceName
            let live = monitor?.liveInterfaceNames ?? []
            condition.withLock {
                delivered.append(state)
                named.append((connected, live))
                condition.broadcast()
            }
        }
        monitor.setOnEvent { [self] event, _ in
            condition.withLock {
                reported.append("\(event.event) \(event.detail ?? "")")
                condition.broadcast()
            }
        }
    }

    /// The names each delivery could read.
    var names: [(connected: String?, live: [String])] { condition.withLock { named } }

    /// The states once there are at least `count`, or after five seconds.
    func states(_ count: Int) -> [VPNObservedState] {
        wait { $0.delivered.count >= count }
        return condition.withLock { delivered }
    }

    /// The events once there are at least `count`, or after five seconds.
    func events(_ count: Int) -> [String] {
        wait { $0.reported.count >= count }
        return condition.withLock { reported }
    }

    private func wait(_ done: (Seen) -> Bool) {
        let limit = Date(timeIntervalSinceNow: 5)
        condition.lock()
        defer { condition.unlock() }
        while !done(self), condition.wait(until: limit) {}
    }
}
