// SPDX-License-Identifier: Apache-2.0
// Property-style tests for `ActiveConnectionStore`. Pins the contracts the
// orchestrator's per-connection / per-activity callbacks rely on:
//
//   - `insert` is O(1) and exposes the value via `ordered` immediately.
//   - `remove(id:)` is O(1) (swap-with-last) and keeps `indexByID`
//     consistent: every remaining element's id maps to its current index.
//   - `update(id:_:)` mutates in place and no-ops on absent ids.
//   - `count` / `isEmpty` mirror `ordered`.
//   - `Equatable` compares only the visible ordered array.
//   - `Codable` round-trips through the bare-array wire format
//     (back-compat with NDJSON consumers that decoded the old
//     `[ActiveConnectionInfo]` shape).
//
// The "kept index map consistent" property is the one that's easy to
// silently break — the swap-with-last needs to update the index of the
// element that moved INTO the removed slot, not just remove the entry
// for the id we explicitly dropped. The `randomInsertRemoveSequence`
// test below burns that property in.

import XCTest
@testable import ProxyKernel

final class ActiveConnectionStoreTests: XCTestCase {

    // MARK: - Defaults

    func testEmptyStoreIsEmpty() {
        let store = ActiveConnectionStore()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.ordered.isEmpty)
    }

    func testInitFromArrayPreservesOrder() {
        let entries = (0..<5).map { Self.makeInfo(label: "host\($0)") }
        let store = ActiveConnectionStore(entries)

        XCTAssertEqual(store.count, 5)
        XCTAssertEqual(store.ordered.map(\.id), entries.map(\.id))
    }

    // MARK: - Insert

    func testInsertAppendsAndIsRetrievable() {
        var store = ActiveConnectionStore()
        let info = Self.makeInfo(label: "host")
        store.insert(info)

        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.ordered.first?.id, info.id)
    }

    func testMultipleInsertsPreserveInsertionOrder() {
        var store = ActiveConnectionStore()
        let entries = (0..<10).map { Self.makeInfo(label: "host\($0)") }
        for info in entries { store.insert(info) }

        XCTAssertEqual(store.ordered.map(\.id), entries.map(\.id),
                       "insert is plain-append until the first remove — order must match insertion order.")
    }

    // MARK: - Remove

    func testRemoveReturnsTrueAndDropsCount() {
        var store = ActiveConnectionStore()
        let info = Self.makeInfo(label: "host")
        store.insert(info)

        XCTAssertTrue(store.remove(id: info.id))
        XCTAssertEqual(store.count, 0)
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveOfAbsentIdReturnsFalseAndIsNoOp() {
        var store = ActiveConnectionStore()
        store.insert(Self.makeInfo(label: "host"))

        XCTAssertFalse(store.remove(id: UUID()),
                       "Removing an id that's not in the store must return false.")
        XCTAssertEqual(store.count, 1, "No-op remove must not affect count.")
    }

    func testRemoveMiddleElementSwapsLastIntoSlot() {
        // The swap-with-last contract: removing element at idx k moves the
        // last element into slot k. Verify the survivor lookup still works
        // (proves indexByID was updated).
        var store = ActiveConnectionStore()
        let a = Self.makeInfo(label: "a")
        let b = Self.makeInfo(label: "b")
        let c = Self.makeInfo(label: "c")
        store.insert(a)
        store.insert(b)
        store.insert(c)

        XCTAssertTrue(store.remove(id: b.id))
        XCTAssertEqual(store.count, 2)

        // After swap-remove of `b` (at idx 1), `c` (last) moved into idx 1.
        // Order is now: [a, c]. Both lookups must still work.
        XCTAssertEqual(Set(store.ordered.map(\.id)), [a.id, c.id])

        // `c`'s index updated correctly — removing it now must succeed.
        XCTAssertTrue(store.remove(id: c.id))
        XCTAssertTrue(store.remove(id: a.id))
        XCTAssertTrue(store.isEmpty)
    }

    func testRemoveLastElementDoesNotSwap() {
        // Edge case: removing the last element should not swap with itself.
        var store = ActiveConnectionStore()
        let a = Self.makeInfo(label: "a")
        let b = Self.makeInfo(label: "b")
        store.insert(a)
        store.insert(b)

        XCTAssertTrue(store.remove(id: b.id))
        XCTAssertEqual(store.ordered.map(\.id), [a.id])
        XCTAssertTrue(store.remove(id: a.id))
        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - Update

    func testUpdateMutatesInPlace() {
        var store = ActiveConnectionStore()
        let info = Self.makeInfo(label: "host")
        store.insert(info)

        store.update(id: info.id) { entry in
            entry.applyActivity(ConnectionActivity(connectionID: info.id, bytesSent: 100, bytesReceived: 50))
        }

        XCTAssertEqual(store.ordered.first?.bytesSent, 100)
        XCTAssertEqual(store.ordered.first?.bytesReceived, 50)
    }

    func testUpdateOfAbsentIdIsNoOp() {
        var store = ActiveConnectionStore()
        let info = Self.makeInfo(label: "host")
        store.insert(info)

        store.update(id: UUID()) { entry in
            entry.applyActivity(ConnectionActivity(connectionID: entry.id, bytesSent: 999))
        }

        XCTAssertEqual(store.ordered.first?.bytesSent, 0,
                       "update(id:) must short-circuit on absent id; the closure must not run.")
    }

    func testUpdatePreservesIndexConsistency() {
        // Mutating an element via update must NOT disturb the index map.
        // Verify by removing a different id afterwards.
        var store = ActiveConnectionStore()
        let a = Self.makeInfo(label: "a")
        let b = Self.makeInfo(label: "b")
        store.insert(a)
        store.insert(b)

        store.update(id: a.id) { $0.applyActivity(ConnectionActivity(connectionID: a.id, bytesSent: 1)) }
        XCTAssertTrue(store.remove(id: b.id))
        XCTAssertEqual(store.count, 1)
        XCTAssertEqual(store.ordered.first?.id, a.id)
        XCTAssertEqual(store.ordered.first?.bytesSent, 1)
    }

    // MARK: - removeAll

    func testRemoveAllClearsBothViews() {
        var store = ActiveConnectionStore()
        for i in 0..<5 { store.insert(Self.makeInfo(label: "h\(i)")) }
        XCTAssertEqual(store.count, 5)

        store.removeAll()
        XCTAssertTrue(store.isEmpty)
        XCTAssertEqual(store.count, 0)

        // After removeAll the index map is also empty — proven by reinserting
        // an entry and being able to remove it cleanly.
        let fresh = Self.makeInfo(label: "fresh")
        store.insert(fresh)
        XCTAssertTrue(store.remove(id: fresh.id))
    }

    // MARK: - Equatable

    func testEqualityIgnoresIndexMapInternals() {
        // Two stores built differently (one direct from array, one via
        // sequential inserts) must compare equal as long as `ordered`
        // matches.
        let entries = (0..<3).map { Self.makeInfo(label: "h\($0)") }
        let viaInit = ActiveConnectionStore(entries)
        var viaInsert = ActiveConnectionStore()
        for e in entries { viaInsert.insert(e) }

        XCTAssertEqual(viaInit, viaInsert,
                       "Equality compares only `ordered` — the index map is derived state.")
    }

    // MARK: - Codable round-trip

    func testCodableRoundTripPreservesOrderAndContents() throws {
        let entries = (0..<5).map { Self.makeInfo(label: "h\($0)") }
        let store = ActiveConnectionStore(entries)

        let data = try JSONEncoder().encode(store)
        let decoded = try JSONDecoder().decode(ActiveConnectionStore.self, from: data)

        XCTAssertEqual(decoded, store)
        XCTAssertEqual(decoded.ordered.map(\.id), entries.map(\.id))
    }

    func testCodableEncodesAsBareArrayForWireBackCompat() throws {
        // Wire shape MUST be a JSON array, not a wrapping object — that's
        // the back-compat contract for NDJSON consumers (pm-proxy
        // `--status-interval`, future pmctl) that decoded the previous
        // `activeConnections: [ActiveConnectionInfo]` shape.
        let store = ActiveConnectionStore([Self.makeInfo(label: "h0")])
        let data = try JSONEncoder().encode(store)
        let topLevel = try JSONSerialization.jsonObject(with: data)
        XCTAssertTrue(topLevel is [Any], "Encoded form must be a JSON array (wire back-compat).")
    }

    // MARK: - Property: random insert/remove keeps index consistent

    func testRandomInsertRemoveSequenceKeepsLookupConsistent() {
        // Insert N random entries, then remove them in random order. After
        // each remove, every survivor's id must still resolve to the slot
        // holding that id. Catches index-update bugs in the swap-with-last
        // path that wouldn't show up in the explicit unit tests above.
        var rng = SystemRandomNumberGenerator()
        let count = 200
        var inserted = (0..<count).map { Self.makeInfo(label: "h\($0)") }
        var store = ActiveConnectionStore()
        for e in inserted { store.insert(e) }
        XCTAssertEqual(store.count, count)

        inserted.shuffle(using: &rng)
        for victim in inserted {
            XCTAssertTrue(store.remove(id: victim.id), "id \(victim.id) must be present in the store before removal")

            // Every surviving id must still be findable. We probe via
            // `update(id:_:)` (which uses the index map under the hood)
            // and check that exactly one entry exists per id.
            var seenIDs: Set<UUID> = []
            for entry in store.ordered {
                XCTAssertFalse(seenIDs.contains(entry.id), "duplicate id in store after remove")
                seenIDs.insert(entry.id)

                var found = false
                store.update(id: entry.id) { mutable in
                    found = mutable.id == entry.id
                }
                XCTAssertTrue(found, "id \(entry.id) survived remove but is not findable via update")
            }
            XCTAssertEqual(seenIDs.count, store.count, "ordered count must match unique-id count")
        }

        XCTAssertTrue(store.isEmpty)
    }

    // MARK: - Test fixtures

    /// Distinct `ActiveConnectionInfo` per call (fresh UUID, distinct
    /// destination string for human-readable failures).
    private static func makeInfo(label: String) -> ActiveConnectionInfo {
        ActiveConnectionInfo(
            destination: "\(label).example.com:443",
            upstream: "DIRECT",
            method: "CONNECT",
            tunnel: false
        )
    }
}
