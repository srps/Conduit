// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import ConduitRuntime
import ConduitShared
@testable import ProxyKernel
import ProxyControlBridge

/// One process-memory sample, written to the log as evidence. Its scope is the XCTest test process in Debug, not the installed app, and it
/// is never an assertion.
struct RuntimeServiceProfileResourceSample {
    let stage: String
    let peakRSSBytes: Int
    let mallocInUseBytes: Int
}

enum RuntimeServiceProfileResource {
    /// Peak RSS from `getrusage(RUSAGE_SELF)`, and in-use bytes from `malloc_zone_statistics` with a nil zone. The SDK header (`malloc/malloc.h`)
    /// says a nil zone sums the statistics of every malloc zone, so the in-use figure is the process total, not one zone's. A failed
    /// `getrusage` throws, so no sample reports a silent zero. Task-info residency is not sampled: the test target is Swift 6, and the imported
    /// `mach_task_self_` global is a concurrency diagnostic.
    static func sample(_ stage: String) throws -> RuntimeServiceProfileResourceSample {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            throw RuntimeServiceProfileError.resourceSampleFailed
        }
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        return RuntimeServiceProfileResourceSample(
            stage: stage,
            peakRSSBytes: usage.ru_maxrss,
            mallocInUseBytes: Int(stats.size_in_use)
        )
    }
}

/// Phase B: the actual projection, row encoding, capture bounds and page framing, measured at the candidate's collection bounds. Every bound
/// comes from `RuntimeServiceProfileCandidate.limits()`, the one candidate builder. Times and resource samples are probe observations written to
/// the log. No test asserts a deadline or a memory figure.
@MainActor
final class RuntimeServiceProfileProjectionTests: XCTestCase {
    /// Log-only gate: whether the retained-kernel probe extends from eleven to 101 captures. It is an observation, not a memory assertion.
    private let flatGrowthObservationBytes = 1_048_576

    private func candidate() throws -> RuntimeServiceLimits {
        try RuntimeServiceProfileCandidate.limits()
    }

    private func frame(_ limits: RuntimeServiceLimits) throws -> ControlFrameLimits {
        try RuntimeServiceProfileCandidate.frameLimits(limits.maxReplyBytes)
    }

    /// Typical connections at 1, 64, 256, 1,000 and the candidate's row bound. The projection's total is checked against the sum of the rows'
    /// own encodings, and every row is packed into a reply-sized page. The projection elapsed time is printed as an observation only.
    func testTypicalConnectionsAtTheDefaultScaleAreMeasuredThroughTheActualProjection() throws {
        let limits = try candidate()
        let frame = try frame(limits)
        for count in [1, 64, 256, 1_000, limits.collectionRowCapacity] {
            let kernel = RuntimeServiceProfileKernels.typical(connections: count)
            let start = ContinuousClock.now
            let captured = try RuntimeServiceProfileKernels.connectionRows(
                kernel,
                maxRows: limits.collectionRowCapacity,
                maxBytes: limits.collectionByteCapacity
            )
            let elapsed = start.duration(to: ContinuousClock.now)
            let stats = try RuntimeServiceProfileKernels.rowStats(captured.rows)
            let pages = try RuntimeServiceProfileKernels.pack(captured.rows, limits: frame)
            XCTAssertEqual(captured.rows.count, count)
            XCTAssertEqual(stats.total, captured.encodedBytes, "the projection's total is the exact sum of its rows' encoded sizes")
            XCTAssertEqual(pages.packedRows, count, "every typical row lands in exactly one reply-sized page")
            print(
                "RUNTIME-SERVICE-PROFILE projection typical connections=\(count) encodedRowBytesTotal=\(captured.encodedBytes)"
                    + " rowBytesMean=\(stats.mean) rowBytesP95=\(stats.p95) rowBytesMax=\(stats.max)"
                    + " pages=\(pages.pages) firstPageRows=\(pages.firstPageRows) maxFrameBytes=\(pages.maxFrameBytes)"
                    + " replyCap=\(limits.maxReplyBytes) projectionElapsed=\(elapsed) (observation, not a deadline)"
            )
        }
    }

    /// One connection over the row bound is refused whole by its count, before any row is mapped. No partial rows are returned.
    func testOneMoreConnectionThanTheRowBoundIsRefusedWholeBeforeAnyRowIsMapped() throws {
        let limits = try candidate()
        let answer = RuntimeServiceProfileKernels.projection(
            RuntimeServiceProfileKernels.typical(connections: limits.collectionRowCapacity + 1),
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        guard case .overBudget = answer else {
            return XCTFail("a capture past the row bound is refused whole, got \(answer)")
        }
    }

    /// Doubling, then bisection, on the byte bound for a kernel builder. Rows are monotone in count: each row's size depends only on its index,
    /// and the byte check refuses exactly when the sum of all rows exceeds the cap. Returns the largest count that fits, the smallest that is
    /// refused, and the number of projections run. Either value is 0 when that side was never reached.
    private func fitBoundary(
        _ limits: RuntimeServiceLimits,
        _ build: (Int) -> ProxyOrchestratorSnapshot
    ) throws -> (fits: Int, refused: Int, probes: Int) {
        var probes = 0
        var fits = 0
        var refused = 0
        var count = 1
        while count <= limits.collectionRowCapacity {
            probes += 1
            switch RuntimeServiceProfileKernels.projection(
                build(count),
                maxRows: limits.collectionRowCapacity,
                maxBytes: limits.collectionByteCapacity
            ) {
            case .rows:
                fits = count
            case .overBudget:
                refused = count
            case .internalFailure:
                throw RuntimeServiceProfileError.internalFailure
            }
            if refused > 0 { break }
            count *= 2
        }
        var low = fits
        var high = refused
        while refused > 0, high - low > 1 {
            let middle = (low + high) / 2
            probes += 1
            switch RuntimeServiceProfileKernels.projection(
                build(middle),
                maxRows: limits.collectionRowCapacity,
                maxBytes: limits.collectionByteCapacity
            ) {
            case .rows:
                low = middle
            case .overBudget:
                high = middle
            case .internalFailure:
                throw RuntimeServiceProfileError.internalFailure
            }
        }
        return (low, high, probes)
    }

    /// The boundary of one kernel shape, through the actual kernel, Bridge projection, byte-bounded capture and page packer. The fitting capture
    /// and the refused count are both checked whole, and the rows are packed. Returns the largest fitting count and its rows.
    private func measureBoundary(
        _ label: String,
        _ limits: RuntimeServiceLimits,
        _ build: (Int) -> ProxyOrchestratorSnapshot
    ) throws -> (fits: Int, rows: [ControlConnectionRow]) {
        let frame = try frame(limits)
        let boundary = try fitBoundary(limits, build)
        XCTAssertGreaterThan(boundary.refused, 0, "\(label): the byte bound refuses before the row bound")
        XCTAssertGreaterThan(boundary.fits, 0, "\(label): at least one row fits")
        guard boundary.refused > 0, boundary.fits > 0 else { return (0, []) }

        let fitting = try RuntimeServiceProfileKernels.connectionRows(
            build(boundary.fits),
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        XCTAssertEqual(fitting.rows.count, boundary.fits)
        XCTAssertLessThanOrEqual(fitting.encodedBytes, limits.collectionByteCapacity)
        let stats = try RuntimeServiceProfileKernels.rowStats(fitting.rows)
        XCTAssertEqual(stats.total, fitting.encodedBytes, "the capture's total is the exact sum of its rows' encoded sizes")
        let next = RuntimeServiceProfileKernels.projection(
            build(boundary.refused),
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        guard case .overBudget = next else {
            XCTFail("\(label): one more row is refused whole, got \(next)")
            return (boundary.fits, fitting.rows)
        }
        let pages = try RuntimeServiceProfileKernels.pack(fitting.rows, limits: frame)
        XCTAssertEqual(pages.packedRows, boundary.fits)
        print(
            "RUNTIME-SERVICE-PROFILE projection \(label) maxFitRows=\(boundary.fits) firstRefusedRows=\(boundary.refused)"
                + " probes=\(boundary.probes) encodedBytesAtMaxFit=\(fitting.encodedBytes) byteCap=\(limits.collectionByteCapacity)"
                + " rowBytesMean=\(stats.mean) rowBytesP95=\(stats.p95) rowBytesMax=\(stats.max)"
                + " pages=\(pages.pages) maxFrameBytes=\(pages.maxFrameBytes)"
        )
        return (boundary.fits, fitting.rows)
    }

    /// MIXED ESCAPE, not a maximum: one different escape-heavy body per field, rotated. The earlier fixture, kept and labelled.
    func testMixedEscapeTextFitCountIsMeasuredAndLabelledNotAMaximum() throws {
        let limits = try candidate()
        let measured = try measureBoundary("mixed-escape (not a maximum)", limits) {
            RuntimeServiceProfileKernels.mixedEscape(connections: $0)
        }
        XCTAssertGreaterThan(measured.fits, 0)
    }

    /// The strongest string-field candidate measured here, not a universal maximum: every displayed text field is an all-NUL run of 1,025 bytes,
    /// over its 512-byte cap, with `Int.max` counts. The fit count is derived, not assumed. Every row encodes to the same size, so the largest
    /// count that fits is exactly the byte cap divided by that size. The escape shape is checked in the encoded row.
    func testAllNULStrongestStringFitCountIsDerivedThroughKernelBridgeAndCapture() throws {
        let limits = try candidate()
        let measured = try measureBoundary("all-nul strongest-string", limits) {
            RuntimeServiceProfileKernels.allNUL(connections: $0)
        }
        guard measured.fits > 0, let first = measured.rows.first else { return }
        let rowSize = try RuntimeWireSize.bytes(of: first)
        var sizes = Set<Int>()
        for row in measured.rows {
            sizes.insert(try RuntimeWireSize.bytes(of: row))
        }
        XCTAssertEqual(sizes, [rowSize], "every all-NUL row encodes to one size")
        XCTAssertEqual(measured.fits, limits.collectionByteCapacity / rowSize, "the derived fit is the byte cap divided by the one row size")
        let encodedRow = try String(decoding: ControlRuntimeCodec.makeEncoder().encode(first), as: UTF8.self)
        XCTAssertTrue(encodedRow.contains("\\u0000"), "the NUL shape survives the projection, so the row is the escape shape measured")
        print(
            "RUNTIME-SERVICE-PROFILE projection all-nul-derived rowBytes=\(rowSize)"
                + " byteCapQuotient=\(limits.collectionByteCapacity / rowSize) measuredFit=\(measured.fits)"
                + " nulEscapeSeen=\(encodedRow.contains("\\u0000"))"
        )
    }

    /// One projection and page pass over a kernel the caller already holds. The kernel is not rebuilt, so the sample isolates the projection.
    private func projectAndPack(_ kernel: ProxyOrchestratorSnapshot, _ limits: RuntimeServiceLimits) throws -> Int {
        let captured = try RuntimeServiceProfileKernels.connectionRows(
            kernel,
            maxRows: limits.collectionRowCapacity,
            maxBytes: limits.collectionByteCapacity
        )
        return try RuntimeServiceProfileKernels.pack(captured.rows, limits: try frame(limits)).pages
    }

    /// The two resource probes below assert nothing and only print samples, so they run on demand, not in every suite run.
    private func requireResourceProbesOptIn() throws {
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CONDUIT_RUNTIME_RESOURCE_PROBES"] == "1",
            "log-only resource probe; set CONDUIT_RUNTIME_RESOURCE_PROBES=1 to run it"
        )
    }

    private func printSample(_ sample: RuntimeServiceProfileResourceSample, pages: Int, scope: String) {
        print(
            "RUNTIME-SERVICE-PROFILE resource scope=\(scope) stage=\(sample.stage) peakRSSBytes=\(sample.peakRSSBytes)"
                + " mallocInUseBytes=\(sample.mallocInUseBytes) pagesPerCapture=\(pages)"
                + " process=XCTest-test-process-Debug typical-1000-rows no-caller-autoreleasepool"
        )
    }

    /// The retained-kernel probe. The 1,000-connection kernel is built once and held immutable, and each iteration runs only the projection and
    /// packing over it. Eleven iterations are sampled. The run extends to 101 only if the first eleven stay under the log-only gate above. The
    /// samples are written to the log, and no assertion depends on them.
    func testProjectionOnARetainedKernelIsSampledWithoutACallerPool() throws {
        try requireResourceProbesOptIn()
        let limits = try candidate()
        let retained = RuntimeServiceProfileKernels.typical(connections: 1_000)
        var samples = [try RuntimeServiceProfileResource.sample("projection-before-first")]
        var pages = 0
        for iteration in 1...11 {
            pages = try projectAndPack(retained, limits)
            samples.append(try RuntimeServiceProfileResource.sample("projection-iteration-\(iteration)"))
        }
        let growth = samples[11].mallocInUseBytes - samples[1].mallocInUseBytes
        let extend = growth < flatGrowthObservationBytes
        for sample in samples {
            printSample(sample, pages: pages, scope: "projection-only")
        }
        print(
            "RUNTIME-SERVICE-PROFILE resource scope=projection-only firstToEleventhMallocGrowthBytes=\(growth)"
                + " observationGateBytes=\(flatGrowthObservationBytes) extendTo101=\(extend)"
        )
        guard extend else {
            print("RUNTIME-SERVICE-PROFILE resource scope=projection-only expansion withheld: report before repeating")
            return
        }
        for iteration in 12...101 {
            pages = try projectAndPack(retained, limits)
            printSample(try RuntimeServiceProfileResource.sample("projection-iteration-\(iteration)"), pages: pages, scope: "projection-only")
        }
        print("RUNTIME-SERVICE-PROFILE resource scope=projection-only completed=101 finalPagesPerCapture=\(pages)")
    }

    /// The comparison probe: the same 1,000-connection kernel is built and released on each iteration, and nothing is projected. Its growth
    /// separates construction from projection. Eleven iterations only, and the samples are written to the log.
    func testFreshKernelConstructionAloneIsSampledForComparison() throws {
        try requireResourceProbesOptIn()
        var samples = [try RuntimeServiceProfileResource.sample("construction-before-first")]
        for iteration in 1...11 {
            withExtendedLifetime(RuntimeServiceProfileKernels.typical(connections: 1_000)) {}
            samples.append(try RuntimeServiceProfileResource.sample("construction-iteration-\(iteration)"))
        }
        for sample in samples {
            print(
                "RUNTIME-SERVICE-PROFILE resource scope=construction-only stage=\(sample.stage) peakRSSBytes=\(sample.peakRSSBytes)"
                    + " mallocInUseBytes=\(sample.mallocInUseBytes) process=XCTest-test-process-Debug typical-1000-rows no-caller-autoreleasepool"
            )
        }
        let growth = samples[11].mallocInUseBytes - samples[1].mallocInUseBytes
        print("RUNTIME-SERVICE-PROFILE resource scope=construction-only firstToEleventhMallocGrowthBytes=\(growth)")
    }
}
