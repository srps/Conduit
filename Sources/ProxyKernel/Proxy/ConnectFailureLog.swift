// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Why a connect failed, coarse enough to key log coalescing on: the same
/// target failing the same way is one story, told once per interval.
package enum ConnectFailureKind: String, Sendable {
    case dns
    case refused
    case timeout
    case unreachable
    case linkLocalRecent = "link_local_recent"
    case blocked
    case other

    package init(_ error: Error) {
        switch error {
        case is LinkLocalFailureMemo.RecentFailure:
            self = .linkLocalRecent
        case is MetadataBlocklist.BlockedAddressError:
            self = .blocked
        case is AddressFamilyAwareResolver.ResolutionError, is DirectIPv4FallbackError:
            self = .dns
        case let io as IOError:
            self = Self(errno: io.errnoCode)
        case let connection as NIOConnectionError:
            if connection.connectionErrors.isEmpty {
                self = connection.dnsAError != nil || connection.dnsAAAAError != nil ? .dns : .other
            } else {
                // Every address failed; the first says how.
                self = Self(connection.connectionErrors[0].error)
            }
        default:
            self = LinkLocalConnectPolicy.isConnectTimeout(error) ? .timeout : .other
        }
    }

    private init(errno code: Int32) {
        switch code {
        case ECONNREFUSED: self = .refused
        case ETIMEDOUT: self = .timeout
        case ENETUNREACH, EHOSTUNREACH, EADDRNOTAVAIL, ENETDOWN, EHOSTDOWN: self = .unreachable
        default: self = .other
        }
    }
}

/// Coalesces connect-failure reports per target and failure kind (#100).
///
/// The first failure is reported as it happens. Repeats inside `interval`
/// are counted, not reported; when the interval closes, one summary carries
/// the count as `suppressed=N`. The event follows the same bound and still
/// precedes its log line (both come from `HTTPProxyHandler.reportConnectFailure`).
///
/// Bounded: at most `capacity` keys. A new key on a full map first drops
/// quiet expired entries, then evicts the oldest window, reporting any
/// count it held back so no suppressed failure goes unaccounted.
package final class ConnectFailureLog: @unchecked Sendable {
    package typealias Cancel = @Sendable () -> Void
    package typealias Scheduler = @Sendable (_ delay: TimeInterval, _ work: @escaping @Sendable () -> Void) -> Cancel

    package static let defaultInterval: TimeInterval = 60
    package static let defaultCapacity = 256

    private struct Key: Hashable {
        let event: String?
        let target: String
        let kind: ConnectFailureKind
    }

    private struct Entry {
        var windowStart: Date
        var suppressed: Int
        var level: LogLevel
        var error: Error
        var message: String
    }

    private struct Report {
        let key: Key
        let level: LogLevel
        let error: Error
        let message: String
        let suppressed: Int
    }

    package let interval: TimeInterval
    package let capacity: Int
    private let logger: any LogSink
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let now: @Sendable () -> Date
    private let scheduleFlush: Scheduler?
    private let lock = NIOLock()
    private var entries: [Key: Entry] = [:]
    /// The one pending flush: armed for the earliest window that holds a
    /// count, re-armed after each flush. Never more than one task, however
    /// many keys there are (Codex on #106).
    private var armed: (deadline: Date, cancel: Cancel)?

    package init(
        logger: any LogSink,
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        interval: TimeInterval = ConnectFailureLog.defaultInterval,
        capacity: Int = ConnectFailureLog.defaultCapacity,
        now: @escaping @Sendable () -> Date = { Date() },
        scheduleFlush: Scheduler? = nil
    ) {
        precondition(interval > 0 && capacity > 0)
        self.logger = logger
        self.eventSink = eventSink
        self.interval = interval
        self.capacity = capacity
        self.now = now
        self.scheduleFlush = scheduleFlush
    }

    deinit {
        armed?.cancel()
    }

    /// A flush scheduler on `group`: summaries come out when their interval
    /// closes even if the failures stopped.
    package static func eventLoopScheduler(_ group: EventLoopGroup) -> Scheduler {
        { delay, work in
            let nanoseconds = Int64(max(0, delay) * 1_000_000_000)
            let task = group.next().scheduleTask(in: .nanoseconds(nanoseconds)) { work() }
            return { task.cancel() }
        }
    }

    package func report(_ event: String?, level: LogLevel, target: String, error: Error, message: String) {
        let key = Key(event: event, target: target, kind: ConnectFailureKind(error))
        let at = now()
        var reports: [Report] = []
        lock.withLock {
            if var entry = entries[key] {
                let age = at.timeIntervalSince(entry.windowStart)
                if age < interval {
                    entry.suppressed += 1
                    entry.level = max(entry.level, level)
                    entry.error = error
                    entry.message = message
                    entries[key] = entry
                    if entry.suppressed == 1 { arm(for: entry.windowStart.addingTimeInterval(interval), at: at) }
                    return
                }
                // The window closed without a flush: this failure carries
                // the count the window held back.
                entries[key] = Entry(windowStart: at, suppressed: 0, level: level, error: error, message: message)
                reports.append(Report(key: key, level: entry.suppressed > 0 ? max(entry.level, level) : level, error: error, message: message,
                                      suppressed: entry.suppressed))
                return
            }
            if entries.count >= capacity {
                reports += makeRoom(at: at)
            }
            entries[key] = Entry(windowStart: at, suppressed: 0, level: level, error: error, message: message)
            reports.append(Report(key: key, level: level, error: error, message: message, suppressed: 0))
        }
        emit(reports)
    }

    /// Reports every window that has closed with a count held back and
    /// forgets the quiet ones.
    package func flushDue() {
        let at = now()
        let reports: [Report] = lock.withLock {
            var due: [Report] = []
            for (key, entry) in entries where at.timeIntervalSince(entry.windowStart) >= interval {
                if entry.suppressed > 0 {
                    due.append(Report(key: key, level: entry.level, error: entry.error, message: entry.message,
                                      suppressed: entry.suppressed))
                    // A new window starts: the next repeat is counted
                    // against it rather than reported at once.
                    entries[key] = Entry(windowStart: at, suppressed: 0, level: entry.level, error: entry.error, message: entry.message)
                } else {
                    entries.removeValue(forKey: key)
                }
            }
            armed?.cancel()
            armed = nil
            let next = entries.values.lazy.filter { $0.suppressed > 0 }.map(\.windowStart).min()
            if let next { arm(for: next.addingTimeInterval(interval), at: at) }
            return due
        }
        emit(reports)
    }

    package var count: Int { lock.withLock { entries.count } }

    /// Called with the lock held. Moves the one pending flush earlier if
    /// `deadline` comes first; a later deadline waits for the re-arm.
    private func arm(for deadline: Date, at: Date) {
        guard let scheduleFlush else { return }
        if let armed, armed.deadline <= deadline { return }
        armed?.cancel()
        // A small margin so the flush lands after the window has closed.
        let cancel = scheduleFlush(max(0, deadline.timeIntervalSince(at)) + 0.05) { [weak self] in self?.flushDue() }
        armed = (deadline, cancel)
    }

    /// Called with the lock held on a full map.
    private func makeRoom(at: Date) -> [Report] {
        var reports: [Report] = []
        for (key, entry) in entries where entry.suppressed == 0 && at.timeIntervalSince(entry.windowStart) >= interval {
            entries.removeValue(forKey: key)
        }
        guard entries.count >= capacity,
              let oldest = entries.min(by: { $0.value.windowStart < $1.value.windowStart }) else { return reports }
        entries.removeValue(forKey: oldest.key)
        if oldest.value.suppressed > 0 {
            let entry = oldest.value
            reports.append(Report(key: oldest.key, level: entry.level, error: entry.error, message: entry.message,
                                  suppressed: entry.suppressed))
        }
        return reports
    }

    private func emit(_ reports: [Report]) {
        for report in reports {
            HTTPProxyHandler.reportConnectFailure(
                report.key.event, level: report.level, target: report.key.target, error: report.error,
                message: report.message, logger: logger, eventSink: eventSink,
                kind: report.key.kind, suppressed: report.suppressed, windowSeconds: Int(interval)
            )
        }
    }
}
