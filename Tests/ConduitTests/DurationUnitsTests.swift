// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import XCTest
@testable import ProxyKernel

/// Conversions from canonical seconds to whole units (decision 0023). The
/// expectations come from decimal text and from the decoder's own arithmetic,
/// not from re-running the conversion under test.
final class DurationUnitsTests: XCTestCase {

    // MARK: - Exact milliseconds

    func testOneThousandOneMillisecondsIsRepresentable() {
        // The old truncation read 1.001 * 1000 as 1000.999..., and stored 1000.
        XCTAssertEqual(DurationUnits.exactMilliseconds(1.001), 1001)
        XCTAssertEqual(DurationUnits.exactMilliseconds(1.0), 1000)
        XCTAssertEqual(DurationUnits.exactMilliseconds(0.001), 1)
        XCTAssertEqual(DurationUnits.exactMilliseconds(0), 0)
    }

    func testNegativeZeroIsZeroMilliseconds() {
        // -0.0 == 0.0, and the file decodes 0 to +0.0; the value is unchanged under ==.
        XCTAssertEqual(DurationUnits.exactMilliseconds(-0.0), 0)
        XCTAssertEqual(DurationUnits.exactMinutes(-0.0), 0)
    }

    func testSubMillisecondAndNeighbourValuesAreRefused() {
        XCTAssertNil(DurationUnits.exactMilliseconds(0.0005), "a half millisecond is not a whole millisecond")
        XCTAssertNil(DurationUnits.exactMilliseconds(0.0015))
        XCTAssertNil(DurationUnits.exactMilliseconds(1.0005))
        // One ulp either side of 1.001 is not 1001 ms: the file would decode 1.001, not the input.
        let oneMillisecond: TimeInterval = 1.001
        XCTAssertNil(DurationUnits.exactMilliseconds(oneMillisecond.nextUp))
        XCTAssertNil(DurationUnits.exactMilliseconds(oneMillisecond.nextDown))
    }

    func testNonFiniteAndOutOfRangeMillisecondsAreRefusedWithoutTrapping() {
        XCTAssertNil(DurationUnits.exactMilliseconds(.nan))
        XCTAssertNil(DurationUnits.exactMilliseconds(.infinity))
        XCTAssertNil(DurationUnits.exactMilliseconds(-.infinity))
        XCTAssertNil(DurationUnits.exactMilliseconds(1e300), "finite but past Int: must refuse before narrowing")
        XCTAssertNil(DurationUnits.exactMilliseconds(.greatestFiniteMagnitude))
        XCTAssertNil(DurationUnits.exactMilliseconds(-1e300))
    }

    // MARK: - Exact minutes

    func testWholeMinutesAreRepresentable() {
        XCTAssertEqual(DurationUnits.exactMinutes(300), 5)
        XCTAssertEqual(DurationUnits.exactMinutes(60), 1)
        XCTAssertEqual(DurationUnits.exactMinutes(0), 0)
        XCTAssertEqual(DurationUnits.exactMinutes(36_000), 600)
    }

    func testFractionalMinutesAndNeighboursAreRefused() {
        XCTAssertNil(DurationUnits.exactMinutes(90.5), "the 90.5-second TTL is not whole minutes")
        XCTAssertNil(DurationUnits.exactMinutes(90))
        XCTAssertNil(DurationUnits.exactMinutes(300.5))
        XCTAssertNil(DurationUnits.exactMinutes(TimeInterval(300).nextUp))
        XCTAssertNil(DurationUnits.exactMinutes(TimeInterval(300).nextDown))
    }

    func testNonFiniteAndOutOfRangeMinutesAreRefusedWithoutTrapping() {
        XCTAssertNil(DurationUnits.exactMinutes(.nan))
        XCTAssertNil(DurationUnits.exactMinutes(.infinity))
        XCTAssertNil(DurationUnits.exactMinutes(-.infinity))
        XCTAssertNil(DurationUnits.exactMinutes(1e300))
        XCTAssertNil(DurationUnits.exactMinutes(.greatestFiniteMagnitude))
    }

    // MARK: - Nanoseconds

    func testNanosecondRangeBoundaryIsEnforcedBeforeNarrowing() {
        XCTAssertEqual(DurationUnits.nanoseconds(9_000_000_000), 9_000_000_000_000_000_000)
        XCTAssertEqual(DurationUnits.nanoseconds(1.5), 1_500_000_000)
        // 2^63 nanoseconds is 9_223_372_036.854775808 seconds: 9_223_372_037 is past it.
        XCTAssertNil(DurationUnits.nanoseconds(9_223_372_037))
        XCTAssertNil(DurationUnits.nanoseconds(1e10))
        XCTAssertNil(DurationUnits.nanoseconds(.nan))
        XCTAssertNil(DurationUnits.nanoseconds(.infinity))
        XCTAssertNil(DurationUnits.nanoseconds(-.infinity))
    }

    /// The runtime conversions are exact for an admitted value. They have no
    /// total form: an unrepresentable value traps (`preconditionFailure`), which
    /// XCTest cannot catch, so the refusal itself is pinned by the nil cases above.
    func testRuntimeConversionsAreExactForAdmittedValues() {
        XCTAssertEqual(DurationUnits.runtimeNanoseconds(1.5), 1_500_000_000)
        XCTAssertEqual(DurationUnits.runtimeNanoseconds(1.001), 1_001_000_000)
        XCTAssertEqual(DurationUnits.checkedMilliseconds(1.001), 1001)
        XCTAssertEqual(DurationUnits.checkedMilliseconds(0.3), 300)
        XCTAssertNil(DurationUnits.checkedMilliseconds(1e10), "past the nanosecond range: no budget, not a trap")
        XCTAssertNil(DurationUnits.checkedMilliseconds(.nan))
    }

    // MARK: - Nearest readings for display

    func testNearestReadingsKeepTheWholeUnitOfAnInexactValue() {
        XCTAssertEqual(DurationUnits.nearestMilliseconds(1.001), 1001)
        XCTAssertEqual(DurationUnits.nearestMilliseconds(.nan), 0)
        XCTAssertEqual(DurationUnits.nearestMinutes(300), 5)
        XCTAssertEqual(DurationUnits.nearestMinutes(.infinity), Int(Int64.max))
    }

    // MARK: - Connect budget and its adaptive ceiling

    /// The literal arithmetic, worked by hand: 2^63 - 1 nanoseconds is 9_223_372_036_854_775_807.
    /// Divided by 10^6 that is 9_223_372_036_854 ms; divided by 8 it is 1_152_921_504_606.75,
    /// so the largest budget is 1_152_921_504_606 ms. Its ceiling is 9_223_372_036_848 ms,
    /// which is 9_223_372_036_848_000_000 ns.
    func testDerivedBudgetLimitAndFactorAreTheLiteralArithmetic() {
        XCTAssertEqual(DurationUnits.adaptiveCeilingFactor, 8)
        XCTAssertEqual(DurationUnits.maxConnectBudgetMilliseconds, 1_152_921_504_606)
        XCTAssertEqual(DurationUnits.adaptiveCeilingMilliseconds(1_152_921_504_606), 9_223_372_036_848)
        XCTAssertLessThanOrEqual(9_223_372_036_848_000_000, Int64.max)
        // One millisecond more would put the ceiling past Int64.max nanoseconds. Double, so the test itself cannot trap.
        XCTAssertGreaterThan(Double(1_152_921_504_607) * 8 * 1_000_000, Double(Int64.max))
    }

    /// Largest accepted and first rejected budget, for both the integer and the seconds input.
    /// The seconds literals are the nearest Double to the decimal text, so the conversion's rounding
    /// is the thing under test, not the expectation.
    func testLargestAcceptedAndFirstRejectedBudgetForNonNilInput() {
        XCTAssertEqual(DurationUnits.connectBudgetMilliseconds(1_152_921_504_606), 1_152_921_504_606)
        XCTAssertNil(DurationUnits.connectBudgetMilliseconds(1_152_921_504_607))
        XCTAssertEqual(DurationUnits.checkedMilliseconds(1_152_921_504.606), 1_152_921_504_606)
        XCTAssertNil(DurationUnits.checkedMilliseconds(1_152_921_504.607))
    }

    /// Zero and sub-millisecond values take the one-millisecond floor `ConnectionPool` already applies,
    /// so a setting that rounds to zero never becomes a budget that expires before a connect can answer.
    func testZeroAndSubMillisecondBudgetsFloorToOneMillisecond() {
        XCTAssertEqual(DurationUnits.connectBudgetMilliseconds(0), 1)
        XCTAssertEqual(DurationUnits.connectBudgetMilliseconds(1), 1)
        XCTAssertEqual(DurationUnits.checkedMilliseconds(0), 1)
        XCTAssertEqual(DurationUnits.checkedMilliseconds(-0.0), 1)
        XCTAssertEqual(DurationUnits.checkedMilliseconds(0.0004), 1, "0.4 ms rounds to zero, so it takes the floor")
        XCTAssertEqual(DurationUnits.checkedMilliseconds(0.0016), 2, "1.6 ms rounds to the nearest whole millisecond")
    }

    /// Negative and out-of-range values have no budget. Each is refused rather than latched or saturated.
    func testNegativeAndOverflowingBudgetsAreRefused() {
        XCTAssertNil(DurationUnits.connectBudgetMilliseconds(-1))
        XCTAssertNil(DurationUnits.connectBudgetMilliseconds(Int64.min))
        XCTAssertNil(DurationUnits.connectBudgetMilliseconds(Int64.max))
        XCTAssertNil(DurationUnits.checkedMilliseconds(-0.001))
        XCTAssertNil(DurationUnits.checkedMilliseconds(-1))
        XCTAssertNil(DurationUnits.checkedMilliseconds(1e10))
        XCTAssertNil(DurationUnits.checkedMilliseconds(.infinity))
        XCTAssertNil(DurationUnits.checkedMilliseconds(.greatestFiniteMagnitude))
    }

    /// Every admitted budget and its adaptive ceiling reach `TimeAmount.milliseconds` as the
    /// nanosecond count the multiplication gives. NIO would saturate a value past `Int64.max`
    /// without trapping, so this is what keeps the configured ceiling the one that runs.
    func testEveryAdmittedBudgetAndItsCeilingConvertToNIOWithoutSaturation() {
        var generator = SeededGenerator(seed: 0x4004)
        var budgets: [Int64] = [1, 2, 1_000, 1_152_921_504_605, 1_152_921_504_606]
        budgets += (0..<5_000).map { _ in Int64.random(in: 1...1_152_921_504_606, using: &generator) }
        for budget in budgets {
            let ceiling = DurationUnits.adaptiveCeilingMilliseconds(budget)
            XCTAssertEqual(ceiling, budget * 8, "the ceiling is the base times eight")
            XCTAssertEqual(TimeAmount.milliseconds(budget).nanoseconds, budget * 1_000_000)
            XCTAssertEqual(TimeAmount.milliseconds(ceiling).nanoseconds, ceiling * 1_000_000)
        }
    }

    /// The first refused budget's ceiling is past `Int64.max` nanoseconds. NIO would saturate it
    /// to `Int64.max` without trapping, which is the silent substitution the derived limit prevents.
    func testFirstRefusedBudgetsCeilingWouldSaturateInNIO() {
        let firstRefused: Int64 = 1_152_921_504_607
        XCTAssertEqual(TimeAmount.milliseconds(firstRefused * 8).nanoseconds, Int64.max)
    }

    // MARK: - Seeded properties

    /// Every millisecond count below 50 000 and a seeded sample of larger ones.
    /// The input is built from decimal text, which the correctly rounded Double
    /// parser turns into the nearest Double. That is an oracle separate from the
    /// conversion. The property is that the conversion returns the intended
    /// count, and that any count it returns decodes back to the input.
    func testEveryWholeMillisecondCountRoundTripsExactly() {
        var generator = SeededGenerator(seed: 0x1001)
        var counts = Array(0..<50_000)
        counts += (0..<20_000).map { _ in Int.random(in: 50_000...1_000_000_000_000, using: &generator) }
        for count in counts {
            let text = "\(count / 1000).\(String(format: "%03ld", count % 1000))"
            guard let seconds = Double(text) else {
                return XCTFail("the decimal text \(text) did not parse")
            }
            XCTAssertEqual(DurationUnits.exactMilliseconds(seconds), count, "intent of \(text) s")
            XCTAssertEqual(TimeInterval(count) / 1000, seconds, "the file decodes the count back to the input")
        }
    }

    /// Neighbours of a representable value are refused, or else they decode back to
    /// themselves. A neighbour never comes back as the wrong count.
    func testNeighboursOfWholeMillisecondsNeverReturnAWrongCount() {
        var generator = SeededGenerator(seed: 0x2002)
        for _ in 0..<5_000 {
            let count = Int.random(in: 0...1_000_000_000_000, using: &generator)
            let seconds = TimeInterval(count) / 1000
            for neighbour in [seconds.nextUp, seconds.nextDown] {
                if let milliseconds = DurationUnits.exactMilliseconds(neighbour) {
                    XCTAssertEqual(TimeInterval(milliseconds) / 1000, neighbour, "count \(milliseconds) must decode to its input")
                }
                XCTAssertNotEqual(DurationUnits.exactMilliseconds(neighbour), count, "a neighbour is never the count it neighbours")
            }
        }
    }

    func testEveryWholeMinuteCountRoundTripsExactly() {
        var generator = SeededGenerator(seed: 0x3003)
        var counts = Array(0..<5_000)
        counts += (0..<5_000).map { _ in Int.random(in: 5_000...100_000_000, using: &generator) }
        for count in counts {
            let seconds = TimeInterval(count) * 60
            XCTAssertEqual(DurationUnits.exactMinutes(seconds), count)
            XCTAssertNil(DurationUnits.exactMinutes(seconds + 0.5), "a fractional minute above \(count) is refused")
            XCTAssertNil(DurationUnits.exactMinutes(seconds.nextUp), "one ulp above \(count) minutes is refused")
        }
    }
}

/// SplitMix64: a fixed seed gives the same sequence on every run and machine.
private struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
