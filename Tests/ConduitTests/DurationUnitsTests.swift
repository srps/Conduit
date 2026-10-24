// SPDX-License-Identifier: Apache-2.0
import Foundation
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
