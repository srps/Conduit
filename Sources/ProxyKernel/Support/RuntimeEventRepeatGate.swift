// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Limits an event that would otherwise fire on every request to one per
/// host and reason per `repeatInterval`, and counts what it held back.
///
/// Each pair has its own cooldown, so a host that alternates between two
/// reasons still reports each at most once per interval. Time rather than
/// success re-arms it: a Kerberos continuation leg can fail on every
/// request right after an initial leg that succeeded, so a success says
/// nothing about whether the failure is over. Bounded at `maximumEntries`
/// pairs; past that the oldest goes, which at worst repeats an event and
/// loses its suppressed count.
///
/// Used for `auth.kerberos_failed` (#73) and `auth.kerberos_fallback_ntlm`
/// (#99).
package final class RuntimeEventRepeatGate: @unchecked Sendable {
    package static let maximumEntries = 64

    private struct Key: Hashable {
        let host: String
        let reason: String
    }

    private struct Entry {
        var lastReported: Date
        var suppressed: Int
    }

    private let repeatInterval: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var entries: [Key: Entry] = [:]

    package init(repeatInterval: TimeInterval = 60, now: @escaping @Sendable () -> Date = { Date() }) {
        self.repeatInterval = repeatInterval
        self.now = now
    }

    /// `nil` when this occurrence falls inside the pair's cooldown and must
    /// not be reported; otherwise the number of occurrences held back since
    /// the pair was last reported, for the event's `suppressed=`.
    package func admit(host: String, reason: String) -> Int? {
        let key = Key(host: host, reason: reason)
        let current = now()
        lock.lock()
        defer { lock.unlock() }
        if var entry = entries[key], current.timeIntervalSince(entry.lastReported) < repeatInterval {
            entry.suppressed += 1
            entries[key] = entry
            return nil
        }
        let held = entries[key]?.suppressed ?? 0
        if entries[key] == nil, entries.count >= Self.maximumEntries,
           let oldest = entries.min(by: { $0.value.lastReported < $1.value.lastReported })?.key {
            entries.removeValue(forKey: oldest)
        }
        entries[key] = Entry(lastReported: current, suppressed: 0)
        return held
    }

    package func shouldEmit(host: String, reason: String) -> Bool {
        admit(host: host, reason: reason) != nil
    }
}
