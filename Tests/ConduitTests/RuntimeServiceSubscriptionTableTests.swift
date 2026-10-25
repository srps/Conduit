// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitRuntime
import ConduitShared

/// The subscription table and the snapshot slot as values, without the core. Each test states one rule of the table or of the slot.
@MainActor
final class RuntimeServiceSubscriptionTableTests: XCTestCase {
    private let cursor = RuntimeSubscriberCursor(
        nextEvent: 1,
        replayThrough: nil,
        nextControl: 1,
        seenSnapshotGeneration: 0,
        lastWasSnapshot: false
    )

    private func waiter(_ counter: WakeCounter) -> RuntimeParkedWaiter {
        RuntimeParkedWaiter(token: RuntimeWaiterToken(), wake: { counter.bump() })
    }

    /// Opens take identities in order, the limit refuses without changing the table, and a removed slot frees its place.
    func testTheTableOpensToItsLimitAndRefusesWithoutChangingIt() {
        var table = RuntimeSubscriptionTable(limit: 2)
        XCTAssertEqual(table.open(cursor), .opened(1))
        XCTAssertEqual(table.open(cursor), .opened(2))
        XCTAssertEqual(table.open(cursor), .full)
        XCTAssertEqual(table.count, 2)
        _ = table.remove(1)
        XCTAssertEqual(table.open(cursor), .opened(3), "identities are never reused")
    }

    /// A removal happens exactly once: the record and its wait leave together, and a second removal finds nothing.
    func testARemovalReturnsTheHeldWaitOnceAndTheSecondFindsNothing() {
        var table = RuntimeSubscriptionTable(limit: 1)
        guard case .opened(let id) = table.open(cursor) else { return XCTFail("the table must open") }
        let counter = WakeCounter()
        XCTAssertEqual(table.park(id, waiter(counter)), .parked)
        guard case .removed(let held?) = table.remove(id) else { return XCTFail("the first removal returns the wait") }
        held.wake()
        XCTAssertEqual(counter.count, 1)
        guard case .absent = table.remove(id) else { return XCTFail("the second removal changes nothing") }
        XCTAssertEqual(table.count, 0)
    }

    /// One parked wait per subscriber, and only the token that parked it may release it.
    func testOneWaitPerSubscriberAndOnlyItsOwnTokenReleasesIt() {
        var table = RuntimeSubscriptionTable(limit: 1)
        guard case .opened(let id) = table.open(cursor) else { return XCTFail("the table must open") }
        let parked = waiter(WakeCounter())
        XCTAssertEqual(table.park(id, parked), .parked)
        XCTAssertEqual(table.park(id, waiter(WakeCounter())), .alreadyParked)
        table.release(id, token: RuntimeWaiterToken())
        XCTAssertEqual(table.parkedCount, 1, "a stale token changes nothing")
        table.release(id, token: parked.token)
        XCTAssertEqual(table.parkedCount, 0)
    }

    /// Taking the waits clears them and keeps every subscriber subscribed, so each wake runs after the table is complete.
    func testTakingTheWaitsKeepsEverySubscriberSubscribed() {
        var table = RuntimeSubscriptionTable(limit: 2)
        guard case .opened(let first) = table.open(cursor), case .opened(let second) = table.open(cursor) else {
            return XCTFail("the table must open")
        }
        _ = table.park(first, waiter(WakeCounter()))
        _ = table.park(second, waiter(WakeCounter()))
        XCTAssertEqual(table.takeParkedWaiters().count, 2)
        XCTAssertEqual(table.parkedCount, 0)
        XCTAssertEqual(table.count, 2)
    }

    /// A commit for a subscriber that has left changes nothing, so a late winning gate cannot revive it.
    func testACommitForAnAbsentSubscriberChangesNothing() {
        var table = RuntimeSubscriptionTable(limit: 1)
        guard case .opened(let id) = table.open(cursor) else { return XCTFail("the table must open") }
        _ = table.remove(id)
        var moved = cursor
        moved.nextEvent = 9
        table.commit(id, moved)
        XCTAssertNil(table.cursor(id))
        XCTAssertEqual(table.count, 0)
    }

    // MARK: - Snapshot slot

    private func snapshot(_ revision: Int, profile: String = "Corp", incarnation: Int = 1) throws -> ControlRuntimeSnapshot {
        try observationSnapshot(presentation: revision, profile: profile, incarnation: incarnation)
    }

    /// Each refusal leaves the held snapshot and its generation as they were, and names the broken invariant in its order.
    func testEveryRefusalLeavesTheHeldSnapshotAndItsGenerationAsTheyWere() throws {
        var slot = RuntimeSnapshotSlot(incarnation: RuntimeServiceFixtures.incarnation(1), byteCapacity: 100)
        XCTAssertEqual(slot.offer(try snapshot(10), encodedBytes: 50), .replaced)
        XCTAssertEqual(slot.generation, 1)
        XCTAssertEqual(slot.offer(try snapshot(11, incarnation: 2), encodedBytes: 50), .refused(.incarnation))
        XCTAssertEqual(slot.offer(try snapshot(11), encodedBytes: nil), .refused(.notEncodable))
        XCTAssertEqual(slot.offer(try snapshot(11), encodedBytes: 101), .refused(.overBound))
        XCTAssertEqual(slot.offer(try snapshot(10), encodedBytes: 50), .unchanged)
        XCTAssertEqual(slot.offer(try snapshot(10, profile: "Other"), encodedBytes: 50), .refused(.conflict))
        XCTAssertEqual(slot.offer(try snapshot(9), encodedBytes: 50), .refused(.regressed))
        XCTAssertEqual(slot.generation, 1)
        XCTAssertEqual(slot.latest, try snapshot(10))
        XCTAssertEqual(slot.latestBytes, 50)
    }

    /// Each replacement advances the generation by one, and the owner's stamp is kept as the owner sent it.
    func testEachReplacementAdvancesOnceAndKeepsTheOwnersStampVerbatim() throws {
        var slot = RuntimeSnapshotSlot(incarnation: RuntimeServiceFixtures.incarnation(1), byteCapacity: 100)
        let next = try snapshot(12)
        XCTAssertEqual(slot.offer(try snapshot(10), encodedBytes: 1), .replaced)
        XCTAssertEqual(slot.offer(try snapshot(11), encodedBytes: 1), .replaced)
        XCTAssertEqual(slot.offer(next, encodedBytes: 1), .replaced)
        XCTAssertEqual(slot.generation, 3)
        XCTAssertEqual(slot.latest?.stamp, next.stamp)
    }

    /// An exhausted generation is sticky: no further snapshot is retained, and the slot reports the exhaustion once it is reached.
    func testAnExhaustedGenerationIsStickyAndRetainsNothingMore() throws {
        var slot = RuntimeSnapshotSlot(incarnation: RuntimeServiceFixtures.incarnation(1), byteCapacity: 100, generationSeed: Int.max - 1)
        XCTAssertEqual(slot.offer(try snapshot(10), encodedBytes: 1), .replaced)
        XCTAssertEqual(slot.generation, Int.max)
        XCTAssertEqual(slot.offer(try snapshot(11), encodedBytes: 1), .refused(.exhausted))
        XCTAssertTrue(slot.exhausted)
        XCTAssertEqual(slot.offer(try snapshot(12), encodedBytes: 1), .refused(.exhausted))
        // Exhaustion is independent of the owner's value: even the held state is not recovered once the slot is sticky.
        XCTAssertEqual(slot.offer(try snapshot(10), encodedBytes: 1), .refused(.exhausted))
        XCTAssertEqual(slot.generation, Int.max)
    }
}
