// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Conversions from canonical seconds to the whole units the runtime and the
/// schema-two file use (decision 0023). Each conversion checks that the value
/// is finite and inside the integer range before it narrows, so none traps.
/// The exact conversions also require that the integer decodes back to the
/// input, which is the test for "representable" rather than whether a scaled
/// Double happens to be integral.
package enum DurationUnits {
    /// 2^63, the first Double above `Int64.max`. Both bounds of an `Int64`
    /// are checked against it, because `Int64(_:)` traps past them.
    private static let integerLimit = 9_223_372_036_854_775_808.0

    /// Whole nanoseconds, nearest. Nil for a non-finite value or one outside
    /// `Int64`. Boundary validation uses this to refuse a duration the runtime
    /// cannot hold.
    package static func nanoseconds(_ seconds: TimeInterval) -> Int64? {
        guard seconds.isFinite else { return nil }
        let scaled = (seconds * 1_000_000_000).rounded()
        guard fitsInteger(scaled) else { return nil }
        return Int64(scaled)
    }

    /// Whole nanoseconds, nearest, for a runtime consumer that reads a value the
    /// boundary already admitted. The boundary refuses an unrepresentable
    /// duration at every entry that reaches a consumer: the save, the live
    /// apply (`AppState.saveConfig`), start, and reload. So reaching this with
    /// one is a bug in that gate, and it traps rather than substituting zero or
    /// saturating, which would run the proxy on a value nobody chose.
    package static func runtimeNanoseconds(_ seconds: TimeInterval) -> Int64 {
        guard let whole = nanoseconds(seconds) else {
            preconditionFailure("An unrepresentable duration reached a runtime consumer; the boundary should have refused it.")
        }
        return whole
    }

    /// Whole milliseconds, nearest, for a consumer that takes milliseconds (the
    /// direct-connect budget). Nil when the runtime cannot hold the duration, so
    /// the consumer refuses rather than trapping. Within the nanosecond range the
    /// millisecond value is in range too.
    package static func checkedMilliseconds(_ seconds: TimeInterval) -> Int64? {
        guard nanoseconds(seconds) != nil else { return nil }
        return Int64((seconds * 1_000).rounded())
    }

    /// Whole milliseconds that the schema-two file decodes back to exactly
    /// `seconds` (as `TimeInterval(ms) / 1000`), or nil. The candidate is the
    /// nearest whole millisecond, and it is accepted only when that decoding
    /// returns the input. A sub-millisecond value, a neighbour of a
    /// representable value, and a non-finite value are all refused.
    package static func exactMilliseconds(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite else { return nil }
        let candidate = (seconds * 1_000).rounded()
        guard fitsInteger(candidate) else { return nil }
        let milliseconds = Int(candidate)
        return TimeInterval(milliseconds) / 1_000 == seconds ? milliseconds : nil
    }

    /// Whole minutes that the schema-two file decodes back to exactly
    /// `seconds` (as `TimeInterval(minutes) * 60`), or nil. A fractional
    /// minute, such as 90.5 seconds, is refused.
    package static func exactMinutes(_ seconds: TimeInterval) -> Int? {
        guard seconds.isFinite else { return nil }
        let candidate = (seconds / 60).rounded()
        guard fitsInteger(candidate) else { return nil }
        let minutes = Int(candidate)
        return TimeInterval(minutes) * 60 == seconds ? minutes : nil
    }

    /// Nearest whole milliseconds for display and legacy readers. Total, and
    /// saturating for an out-of-range value; a non-finite value reads as zero. It
    /// never decides what is saved (the save refuses an inexact value instead),
    /// and no runtime consumer reads it: the runtime reads `runtimeNanoseconds` or `checkedMilliseconds`.
    package static func nearestMilliseconds(_ seconds: TimeInterval) -> Int {
        Int(clampedInteger((seconds * 1_000).rounded()))
    }

    /// Nearest whole minutes for display and legacy readers. Total, and never
    /// used to decide what is saved.
    package static func nearestMinutes(_ seconds: TimeInterval) -> Int {
        Int(clampedInteger((seconds / 60).rounded()))
    }

    private static func fitsInteger(_ whole: Double) -> Bool {
        whole >= -integerLimit && whole < integerLimit
    }

    private static func clampedInteger(_ whole: Double) -> Int64 {
        if whole.isNaN { return 0 }
        if whole >= integerLimit { return Int64.max }
        if whole < -integerLimit { return Int64.min }
        return Int64(whole)
    }
}
