// SPDX-License-Identifier: Apache-2.0
import Foundation

/// When a dynamic-store observer reads next, and which failed attempts it
/// reports (decision 0048). A pure value: the caller supplies the time and
/// arms the one wake-up it asks for.
///
/// After a failed create, subscribe or read the next attempt is due after
/// 1, 2, 4, 8 and 16 s, then every 30 s until one succeeds. The first good
/// reading resets the count. While readings succeed, an observer with an
/// audit reads again every `audit` seconds; one without has nothing due.
///
/// It holds the count of consecutive failures and the audit interval, and
/// nothing that grows: the count saturates.
package struct StoreReadSchedule: Equatable, Sendable {
    /// The interval values are the owner's judgement, not a measurement
    /// (0048); changing them needs the owner.
    package enum Constants {
        /// The delays before the first five retries. A single transient
        /// failure costs about a second; a store that stays broken is not
        /// polled faster than `retryCap`.
        package static let retryDelays: [TimeInterval] = [1, 2, 4, 8, 16]
        /// The delay before every later retry.
        package static let retryCap: TimeInterval = 30
        /// How often the VPN monitor reads a healthy store, which bounds how
        /// long a lost notification can leave its verdict stale.
        package static let vpnAudit: TimeInterval = 60
        /// How late a wake-up may run, as a fraction of its delay, so macOS
        /// can batch it with other wake-ups.
        package static let leewayFraction = 0.1
        /// Attempts 1, 2, 4 … `reportEvery` are reported, then every
        /// `reportEvery`th, so a store that stays broken costs a few events
        /// an hour.
        package static let reportEvery = 64
    }

    /// The next read after a failed attempt.
    package struct Retry: Equatable, Sendable {
        /// Consecutive failed attempts, this one included.
        package let attempt: Int
        /// Whether this attempt emits an event.
        package let reports: Bool
        /// When the next attempt is due.
        package let due: TimeInterval
    }

    /// The next read after a good one.
    package struct Healthy: Equatable, Sendable {
        /// The failed attempts this reading ended, or nil when the reading
        /// before it was good too. A recovery event carries it.
        package let recoveredAfter: Int?
        /// When the audit read is due, or nil for an observer with none.
        package let due: TimeInterval?
    }

    /// Seconds between audit reads while healthy, or nil for none.
    package let audit: TimeInterval?
    /// Consecutive failed attempts since the last good reading.
    package private(set) var failedAttempts = 0

    package init(audit: TimeInterval?) {
        precondition(audit.map { $0 > 0 } ?? true, "an audit interval is positive")
        self.audit = audit
    }

    /// An attempt at `now` failed.
    package mutating func failed(at now: TimeInterval) -> Retry {
        failedAttempts = failedAttempts == .max ? .max : failedAttempts + 1
        return Retry(attempt: failedAttempts, reports: Self.reports(attempt: failedAttempts), due: now + Self.delay(after: failedAttempts))
    }

    /// An attempt at `now` read the store.
    package mutating func succeeded(at now: TimeInterval) -> Healthy {
        defer { failedAttempts = 0 }
        return Healthy(recoveredAfter: failedAttempts == 0 ? nil : failedAttempts, due: audit.map { now + $0 })
    }

    /// The delay before the attempt after failed attempt `attempt`.
    package static func delay(after attempt: Int) -> TimeInterval {
        precondition(attempt >= 1)
        return attempt <= Constants.retryDelays.count ? Constants.retryDelays[attempt - 1] : Constants.retryCap
    }

    /// Whether failed attempt `attempt` emits an event: the powers of two up
    /// to `reportEvery`, then each multiple of it.
    package static func reports(attempt: Int) -> Bool {
        precondition(attempt >= 1)
        return attempt % Constants.reportEvery == 0 || (attempt < Constants.reportEvery && attempt.nonzeroBitCount == 1)
    }

    /// How late a wake-up `delay` seconds out may run.
    package static func leeway(for delay: TimeInterval) -> TimeInterval {
        max(0, delay) * Constants.leewayFraction
    }
}
