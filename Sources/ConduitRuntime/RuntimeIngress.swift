// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation

/// One queued item between producers and the ring. A loss stands for events that were dropped, and it is a
/// position in the stream, so it counts against a drain turn like an event does.
enum RuntimeIngressItem: Sendable {
    case event(ControlRuntimeEventRecord, bytes: Int)
    case loss
}

/// The bounded leaf ingress. Any thread may enqueue, because it is a lock and nothing else. It holds at most
/// `capacity` events plus one loss marker, and at most `byteCapacity` encoded bytes. A full queue or an event too
/// large to retain becomes a loss marker, so a producer never waits and never allocates a task per event.
///
/// Exactly one drain hop is pending at a time. `enqueue` reports when the caller must schedule it, and `take`
/// reports whether another hop is needed, so one batch costs one hop and no turn exceeds its budget.
final class RuntimeIngress: @unchecked Sendable {
    private let lock = NSLock()
    private let capacity: Int
    private let byteCapacity: Int
    private let maxEventBytes: Int
    private var items: [RuntimeIngressItem] = []
    private var queuedBytes = 0
    private var drainScheduled = false

    init(limits: RuntimeServiceLimits) {
        capacity = limits.ingressCapacity
        byteCapacity = limits.ingressByteCapacity
        maxEventBytes = limits.maxEventBytes
    }

    /// Queues one event from any thread. It returns true when the caller must schedule the drain hop. A nil size
    /// means the event has no encoding, and it becomes a loss marker, like an event over the bound or a full queue.
    func enqueue(_ record: ControlRuntimeEventRecord, bytes: Int?) -> Bool {
        lock.withLock {
            if let bytes, bytes <= maxEventBytes, items.count < capacity, bytes <= byteCapacity - queuedBytes {
                items.append(.event(record, bytes: bytes))
                queuedBytes += bytes
            } else {
                markLossLocked()
            }
            guard !drainScheduled else { return false }
            drainScheduled = true
            return true
        }
    }

    /// Takes up to `maxItems` items and `maxBytes` event bytes, in order. A loss marker counts as one item.
    /// It returns whether items remain, and then the caller schedules the next drain hop.
    func take(maxItems: Int, maxBytes: Int) -> (batch: [RuntimeIngressItem], more: Bool) {
        lock.withLock {
            var batch: [RuntimeIngressItem] = []
            var bytes = 0
            while let next = items.first, batch.count < maxItems {
                if case .event(_, let size) = next {
                    guard size <= maxBytes - bytes else { break }
                    bytes += size
                    queuedBytes -= size
                }
                batch.append(items.removeFirst())
            }
            let more = !items.isEmpty
            drainScheduled = more
            return (batch, more)
        }
    }

    /// Adds one loss marker at the tail. Consecutive losses collapse, so the queue holds at most one item more
    /// than its capacity.
    private func markLossLocked() {
        if case .loss? = items.last { return }
        items.append(.loss)
    }
}
