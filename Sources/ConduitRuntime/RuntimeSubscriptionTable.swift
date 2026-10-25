// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The one parked wait a subscriber may hold. Its token names the registration exactly, so a stale cleanup cannot remove a newer one.
struct RuntimeParkedWaiter {
    let token: RuntimeWaiterToken
    let wake: @Sendable () -> Void
}

/// One subscriber's state: its cursors, which are fixed-size positions and generations, and the parked wait it may hold. The
/// buffered first frame is not here. It stays in the transport's stream handle, so nothing is held twice.
struct RuntimeSubscriberRecord {
    var cursor: RuntimeSubscriberCursor
    var waiter: RuntimeParkedWaiter?
}

/// The answer to opening a subscriber. `full` is the subscriber limit, and `exhausted` is the identity counter at its maximum.
enum RuntimeSubscriptionOpen: Equatable {
    case opened(Int)
    case full
    case exhausted
}

/// The answer to removing a subscriber. A removal happens exactly once: a second removal finds nothing and changes nothing.
enum RuntimeSubscriptionRemoval {
    /// The subscriber left the table. `waiter` is the wait it held, which the caller wakes after its owner turn is complete.
    case removed(waiter: RuntimeParkedWaiter?)
    case absent
}

/// The subscription table: every open subscriber's record, the subscriber limit, and each record's one parked wait. It is a plain
/// value that only the service's owner turn touches, so it takes no lock. Nothing in it calls out. A caller that wakes a wait does it
/// after the table mutation that produced it, so no wake runs inside an owner mutation.
struct RuntimeSubscriptionTable {
    let limit: Int
    private(set) var records: [Int: RuntimeSubscriberRecord] = [:]
    private var nextID = 1

    init(limit: Int) {
        self.limit = limit
    }

    var count: Int {
        records.count
    }

    /// The subscribers that hold a parked wait.
    var parkedCount: Int {
        records.values.reduce(0) { $0 + ($1.waiter == nil ? 0 : 1) }
    }

    /// Opens one subscriber at a cursor. A refusal changes nothing, and the identity is never reused.
    mutating func open(_ cursor: RuntimeSubscriberCursor) -> RuntimeSubscriptionOpen {
        guard records.count < limit else { return .full }
        guard let following = RuntimeCounter.successor(nextID) else { return .exhausted }
        let id = nextID
        nextID = following
        records[id] = RuntimeSubscriberRecord(cursor: cursor, waiter: nil)
        return .opened(id)
    }

    func cursor(_ subscriber: Int) -> RuntimeSubscriberCursor? {
        records[subscriber]?.cursor
    }

    /// Commits a cursor that a peek produced, once its frame has been delivered. A subscriber that has left is not revived.
    mutating func commit(_ subscriber: Int, _ cursor: RuntimeSubscriberCursor) {
        guard records[subscriber] != nil else { return }
        records[subscriber]?.cursor = cursor
    }

    /// Parks the one wait of a subscriber.
    mutating func park(_ subscriber: Int, _ waiter: RuntimeParkedWaiter) -> RuntimeParkResult {
        guard let record = records[subscriber] else { return .subscriberGone }
        guard record.waiter == nil else { return .alreadyParked }
        records[subscriber]?.waiter = waiter
        return .parked
    }

    /// Removes a parked registration if it is still the one named by `token`. A stale token changes nothing.
    mutating func release(_ subscriber: Int, token: RuntimeWaiterToken) {
        guard records[subscriber]?.waiter?.token == token else { return }
        records[subscriber]?.waiter = nil
    }

    /// Removes a subscriber. Its record and its parked wait leave the table in this call, and the wait is returned to be woken.
    @discardableResult
    mutating func remove(_ subscriber: Int) -> RuntimeSubscriptionRemoval {
        guard let record = records.removeValue(forKey: subscriber) else { return .absent }
        return .removed(waiter: record.waiter)
    }

    /// Takes every parked wait out of its record, so the caller wakes each one after the mutation. The records stay subscribed.
    mutating func takeParkedWaiters() -> [RuntimeParkedWaiter] {
        var taken: [RuntimeParkedWaiter] = []
        for subscriber in Array(records.keys) {
            guard let waiter = records[subscriber]?.waiter else { continue }
            taken.append(waiter)
            records[subscriber]?.waiter = nil
        }
        return taken
    }
}
