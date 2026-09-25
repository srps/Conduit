// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Emits `pac.no_usable_route`, rate-limited per reason so a broken PAC
/// cannot flood the event log (#50).
///
/// At most one event per reason per `window`. Events held back in between are
/// counted and reported as `suppressed=` on the next one for that reason. The
/// table has one slot per `PACNoUsableReason` case, so it is bounded by
/// construction; the rejected-type list in an event is capped at
/// `maxRejectedTypes`.
package final class PACNoUsableRouteReporter: @unchecked Sendable {
    package static let window: TimeInterval = 60
    package static let maxRejectedTypes = 8

    private struct Slot {
        var lastEmitted: Date
        var suppressed: Int
    }

    private let lock = NSLock()
    private var slots: [PACNoUsableReason: Slot] = [:]
    private let eventSink: (@Sendable (RuntimeEvent) -> Void)?
    private let logger: (any LogSink)?
    private let now: @Sendable () -> Date

    package init(
        eventSink: (@Sendable (RuntimeEvent) -> Void)?,
        logger: (any LogSink)?,
        now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.eventSink = eventSink
        self.logger = logger
        self.now = now
    }

    /// Report one request that got no usable PAC answer. Returns whether an
    /// event was emitted (`false` when rate-limited).
    @discardableResult
    package func report(_ reason: PACNoUsableReason, rejected: PACRejections, host: String) -> Bool {
        let current = now()
        let suppressed: Int? = lock.withLock {
            if var slot = slots[reason], current.timeIntervalSince(slot.lastEmitted) < Self.window {
                slot.suppressed += 1
                slots[reason] = slot
                return nil
            }
            let held = slots[reason]?.suppressed ?? 0
            slots[reason] = Slot(lastEmitted: current, suppressed: 0)
            return held
        }
        guard let suppressed else { return false }

        var detail = "reason=\(reason.rawValue) host=\(host)"
        let types = Self.rejectedTypes(rejected)
        if !types.isEmpty {
            detail += " rejected=\(types.joined(separator: ","))"
        }
        if rejected.truncated {
            // Only the first entries are kept; say how many there were.
            detail += " rejectedTotal=\(rejected.total)"
        }
        detail += " suppressed=\(suppressed)"
        let event = RuntimeEvent(kind: .routing, event: "pac.no_usable_route", detail: detail)
        eventSink?(event)
        logger?.log(
            Self.logLevel(for: reason),
            "PAC gave no usable route (\(event.detail ?? detail)); routing through the configured upstreams.",
            category: .pac
        )
        return true
    }

    /// Distinct rejected types in script order, at most `maxRejectedTypes`.
    package static func rejectedTypes(_ rejected: PACRejections) -> [String] {
        var seen: [String] = []
        for entry in rejected where !seen.contains(entry.type) {
            guard seen.count < maxRejectedTypes else { break }
            seen.append(entry.type)
        }
        return seen
    }

    /// A PAC that has not loaded yet, or was replaced mid-evaluation, is a
    /// transient state of a configuration change; the rest is a broken or
    /// overloaded PAC.
    private static func logLevel(for reason: PACNoUsableReason) -> LogLevel {
        switch reason {
        case .notLoaded, .superseded:
            return .info
        case .empty, .unsupported, .invalid, .evaluationFailed, .timeout, .refused:
            return .warning
        }
    }
}
