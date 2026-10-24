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

    /// The factor by which a host's adaptive connect timeout may grow past its
    /// base: the detector doubles on each failure and holds at `base * factor`.
    /// This is the only copy of the number; the ceiling and the budget limit below
    /// both derive from it.
    package static let adaptiveCeilingFactor: Int64 = 8

    /// The largest connect budget, in whole milliseconds, the runtime holds. The
    /// adaptive ceiling reaches NIO as a `TimeAmount`, and NIO saturates a
    /// nanosecond count past `Int64.max` instead of trapping, so a larger budget
    /// would run with a ceiling nobody configured. The limit is `Int64.max`
    /// nanoseconds, in milliseconds, divided by the factor and rounded down: the
    /// largest budget whose ceiling still converts exactly.
    package static let maxConnectBudgetMilliseconds: Int64 = Int64.max / 1_000_000 / adaptiveCeilingFactor

    /// Whole milliseconds for the connect budget, for a consumer that takes
    /// milliseconds (the direct-connect probe). Nil when the value is not finite,
    /// is negative, or is past `maxConnectBudgetMilliseconds`, so the consumer
    /// refuses rather than trapping or saturating. A positive value under half a
    /// millisecond rounds to zero and takes the one-millisecond floor; see
    /// `connectBudgetMilliseconds`.
    package static func checkedMilliseconds(_ seconds: TimeInterval) -> Int64? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let scaled = (seconds * 1_000).rounded()
        guard scaled < integerLimit else { return nil }
        return connectBudgetMilliseconds(Int64(scaled))
    }

    /// The connect budget an integer millisecond count denotes, or nil when the
    /// runtime cannot hold it: negative, or past `maxConnectBudgetMilliseconds`.
    /// Zero is raised to one millisecond. That is the floor `ConnectionPool`
    /// already applies to the same setting (`max(…, 1_000_000)` nanoseconds), so a
    /// zero or sub-millisecond setting is never a zero budget, which would expire
    /// before any connect could answer. The detector admits every reading through
    /// this before it can latch, so an injected value gets the same answer as a
    /// configured one.
    package static func connectBudgetMilliseconds(_ milliseconds: Int64) -> Int64? {
        guard (0...maxConnectBudgetMilliseconds).contains(milliseconds) else { return nil }
        return max(milliseconds, 1)
    }

    /// The adaptive ceiling of an admitted connect budget, in milliseconds. Its
    /// nanoseconds fit an `Int64` by the derivation of `maxConnectBudgetMilliseconds`,
    /// so NIO converts it exactly. A value that was not admitted is a bug in the
    /// gate, and it traps, as `runtimeNanoseconds` does.
    package static func adaptiveCeilingMilliseconds(_ budget: Int64) -> Int64 {
        guard (0...maxConnectBudgetMilliseconds).contains(budget) else {
            preconditionFailure("A connect budget the runtime did not admit reached its adaptive ceiling.")
        }
        return budget * adaptiveCeilingFactor
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
