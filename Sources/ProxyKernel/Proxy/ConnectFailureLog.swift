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

/// A direct connect that failed only because the destination is absent
/// (#149): the name does not exist, the host is under the reserved
/// `.invalid` TLD, or nothing listens on a loopback port. The path worked;
/// the client asked for something that is not there, so the failure is
/// worth a warning, not an error line. It still emits its event. DNS server
/// failures (`EAI_AGAIN`, `EAI_FAIL`), lookup timeouts and connect timeouts
/// are not absent: they can mean a broken route or resolver, and that
/// includes link-local peers, such as a Thunderbolt bridge whose SYNs a bad
/// route blackholes.
///
/// One timeout is treated as absent by policy rather than proof: a cloud
/// instance-metadata endpoint. Only a cloud instance serves one, and cloud
/// SDKs probe it on credential lookups wherever they run, so off a cloud
/// instance the probe times out as a matter of course, at an interval that
/// outlives `LinkLocalFailureMemo` (every 15 minutes in the log behind this).
/// A metadata endpoint behind a broken route would be logged the same way.
package enum AbsentDestination {
    package static func matches(_ error: Error, host: String) -> Bool {
        let name = normalized(host)
        if name == "invalid" || name.hasSuffix(".invalid") { return true }
        switch ConnectFailureKind(error) {
        case .dns: return isNoSuchName(error)
        case .refused: return isLoopback(name)
        case .timeout: return isMetadataEndpoint(name)
        default: return false
        }
    }

    private static func normalized(_ host: String) -> String {
        var name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        while name.hasSuffix(".") { name.removeLast() }
        return name
    }

    /// Every lookup that answered said the name has no address. A lookup
    /// that failed some other way keeps the failure unexplained.
    private static func isNoSuchName(_ error: Error) -> Bool {
        switch error {
        case let resolution as AddressFamilyAwareResolver.ResolutionError:
            return resolution.rc == EAI_NONAME
        case let fallback as DirectIPv4FallbackError:
            switch fallback {
            case .resolutionFailed(_, let rc): return rc == EAI_NONAME
            case .noIPv4Address: return true
            case .resolutionTimedOut: return false
            }
        case let connection as NIOConnectionError:
            let lookups = [connection.dnsAError, connection.dnsAAAAError].compactMap { $0 }
            return connection.connectionErrors.isEmpty && !lookups.isEmpty && lookups.allSatisfy(isNoSuchName)
        default:
            return false
        }
    }

    /// The literals cloud SDKs probe for instance credentials: the shared
    /// IPv4 endpoint (AWS, Azure, GCP, OCI), the ECS task endpoint, and
    /// EC2's IPv6 one. Compared as addresses, so `[fd00:ec2:0::254]` and the
    /// IPv4-mapped `::ffff:169.254.169.254` match.
    package static func isMetadataEndpoint(_ host: String) -> Bool {
        let name = normalized(host)
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 {
            return isMetadataIPv4(UInt32(bigEndian: v4.s_addr))
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, name, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: &v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }) && bytes[10] == 0xff && bytes[11] == 0xff {
            return isMetadataIPv4(bytes[12...].reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        let ec2: [UInt8] = [0xfd, 0, 0x0e, 0xc2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02, 0x54] // fd00:ec2::254
        return bytes == ec2
    }

    private static func isMetadataIPv4(_ value: UInt32) -> Bool {
        value == 0xa9fe_a9fe || value == 0xa9fe_aa02 // 169.254.169.254, 169.254.170.2
    }

    private static func isLoopback(_ name: String) -> Bool {
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        var v4 = in_addr()
        if inet_pton(AF_INET, name, &v4) == 1 { return UInt32(bigEndian: v4.s_addr) >> 24 == 127 }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, name, &v6) == 1 {
            return withUnsafeBytes(of: &v6) { bytes in bytes.prefix(15).allSatisfy { $0 == 0 } && bytes[15] == 1 }
        }
        return false
    }
}

/// How a failed direct connect is reported. Shared by the HTTP direct paths
/// and pm-sim, so the scenario checks the policy the proxy applies.
package enum DirectConnectFailure {
    /// A memo refusal repeats a failure already logged; log it at `.info`.
    package static func level(_ error: Error, default level: LogLevel) -> LogLevel {
        error is LinkLocalFailureMemo.RecentFailure ? .info : level
    }

    /// Always names `direct.connect_failed`; whether it is emitted follows
    /// the level (`.warning` and up) and `ConnectFailureLog`'s coalescing.
    /// An absent destination (see `AbsentDestination`) logs at `.warning` at
    /// most; everything else keeps `level`. Never raises a level the
    /// direct-mode cause or the link-local memo lowered.
    package static func report(
        _ error: Error, host: String, default level: LogLevel
    ) -> (event: String?, level: LogLevel) {
        let level = Self.level(error, default: level)
        guard AbsentDestination.matches(error, host: host) else { return ("direct.connect_failed", level) }
        return ("direct.connect_failed", min(level, .warning))
    }
}

/// Coalesces connect-failure reports per target and failure kind (#100).
///
/// The first failure is reported as it happens. Repeats inside `interval`
/// are counted, not reported; when the interval closes, one summary carries
/// the count as `suppressed=N` and the age of its window as `windowSeconds`:
/// wall-clock seconds since the window opened (at its first failure, or at
/// the previous summary), at least 1. That is about `interval` while awake,
/// less when an eviction reports a window early, and longer after a sleep:
/// the flush timer runs on uptime, which stops while the Mac sleeps. The
/// event follows the same bound and still precedes its log line (both come
/// from `HTTPProxyHandler.reportConnectFailure`).
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
        /// Emit `event` whatever the level; otherwise only at warning and up.
        let eventAtAnyLevel: Bool
        let target: String
        /// The upstream the failed attempt dialed, when the caller knows it:
        /// one target failing via two upstreams is two stories.
        let upstream: String?
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
        /// The window's age; reported only when `suppressed` is nonzero.
        var windowSeconds = 0
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

    /// `upstream` is the sanitized endpoint the attempt dialed; pass it only
    /// when the attempt went through one.
    package func report(
        _ event: String?, level: LogLevel, target: String, upstream: String? = nil, error: Error, message: String,
        eventAtAnyLevel: Bool = false
    ) {
        let key = Key(event: event, eventAtAnyLevel: eventAtAnyLevel, target: target, upstream: upstream,
                      kind: ConnectFailureKind(error))
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
                                      suppressed: entry.suppressed, windowSeconds: Self.seconds(from: entry.windowStart, to: at)))
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
                                      suppressed: entry.suppressed, windowSeconds: Self.seconds(from: entry.windowStart, to: at)))
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
                                  suppressed: entry.suppressed, windowSeconds: Self.seconds(from: entry.windowStart, to: at)))
        }
        return reports
    }

    private func emit(_ reports: [Report]) {
        for report in reports {
            HTTPProxyHandler.reportConnectFailure(
                report.key.event, level: report.level, target: report.key.target, upstream: report.key.upstream,
                error: report.error,
                message: report.message, logger: logger, eventSink: eventSink,
                eventAtAnyLevel: report.key.eventAtAnyLevel,
                kind: report.key.kind, suppressed: report.suppressed, windowSeconds: report.windowSeconds
            )
        }
    }

    /// At least 1: a summary always stands for a span, even an evicted
    /// window a burst of new keys pushed out within the same second.
    private static func seconds(from start: Date, to end: Date) -> Int {
        max(1, Int(end.timeIntervalSince(start).rounded()))
    }
}
