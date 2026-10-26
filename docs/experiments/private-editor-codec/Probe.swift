// Release sizing and lifetime probe for the private editor reply codec (decision 0034). Not product code, not a selected
// budget and not a test hook. `run.py` compiles this file together with the pure maximum fixture
// (`Tests/ConduitTests/Fixtures/PrivateEditorMaximumFixture.swift`, unmodified) against the Release `ConduitShared`
// object alone, with `-package-name conduit`. It calls the production reply encoder, frame reader and decoder. It reads
// no app, helper, network, store or configuration state, and it prints labels, counts and metrics only: never a fixture
// string.
//
// Modes, one fresh process each:
//
//   wide-shared      the fixture with `distinct: false`: every text at its ceiling, equal texts. One transfer, sampled at
//                    every stage, then the sizing analysis.
//   wide-distinct    the same with `distinct: true`: every text unique, the same widths.
//   repeat-distinct  `distinct: true`. One owner and one draft are built once and held across 20 transfers. Each transfer
//                    is sampled after its release, and those samples hold the owner and the draft.
//
// A transfer is what an in-process host and client do with one observation reply. The host's retained owner value and the
// client's draft stay alive (`withExtendedLifetime`) through measure, encode, read and decode. The draft is built by a
// second fixture call, so its storage is its own and counts. The wire frame is dropped once read, the body once decoded,
// and the decoded reply once compared with the original.
//
// Measurements are process samples, not installed-app RAM and not a whole-host peak: `getrusage` peak RSS, live malloc
// (`size_in_use` summed over every zone), and the task's physical footprint and its ledger peak. Live values are sampled
// between stages. A copy that lives and dies inside one stage (the encoder's buffer and its `SecretBytes` copy, the
// reader's buffer and its completion copy, the decoder's `Data` and Foundation's values) shows only in the two monotonic
// peaks. Samples go into storage reserved before the baseline, with static labels, and nothing is printed until the
// lifetime phase is over. Each printed record is built inside its own autorelease pool: an unscoped bridged dictionary on
// a command-line main thread is never drained, and an earlier probe misread that as codec growth. Each transfer runs in
// its own pool too, because Foundation's decoder may autorelease. The sizing analysis runs after all of that, so it cannot
// raise a quoted peak.

import ConduitShared
import Darwin
import Foundation

// MARK: - Modes and constants

enum Mode: String {
    case wideShared = "wide-shared"
    case wideDistinct = "wide-distinct"
    case repeatDistinct = "repeat-distinct"

    var distinct: Bool { self != .wideShared }
    var iterations: Int { self == .repeatDistinct ? Probe.repeatIterations : 1 }
    var samplesStages: Bool { self != .repeatDistinct }
}

/// Fixed failures of the probe itself. None carries input.
enum ProbeFailure: Error {
    case readerStalled
    case trailingBytes
    case incompleteFrame
    case malformedFrame
    case notAnObservation
}

/// `String(Int.min)` is 20 bytes and `String(UInt64.max)` is 20 bytes; both are checked at run time. Every integer the
/// reply writer emits is an `Int` or a `UInt64`.
let integerLexemeMaximumBytes = 20

/// Any finite IEEE 754 binary64 value is m·2^k with integer |m| < 2^53 and k ≥ −1074. For k ≥ 0 it is an integer below
/// 2^1024 < 10^309: at most 309 digits, plus a sign and a `.0` suffix, 312 bytes. For k < 0 it is m·5^−k / 10^−k: at most
/// 1,074 fractional digits, and |x| < 2^53 gives at most 16 integer digits, so sign + 16 + `.` + 1,074 = 1,092 bytes for the
/// exact positional expansion. Any scientific spelling of that expansion has at most as many significant digits plus a
/// five-byte exponent. 1,100 therefore bounds the exact expansion without assuming Swift's shortest round-trip format, and
/// without assuming the fixture's 24-byte spelling is the widest. It does not bound a writer that pads or repeats digits;
/// the production writer is `String(value)`.
let doubleLexemeMaximumBytes = 1_100

@inline(__always)
func monotonicNanoseconds() -> UInt64 {
    clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
}

// MARK: - Samples

struct MemorySample {
    let uptimeNanoseconds: UInt64
    let peakRSSBytes: Int
    let mallocInUseBytes: Int
    let physicalFootprintBytes: Int
    let physicalFootprintPeakBytes: Int

    /// Reads process counters only and allocates nothing, so taking a sample does not move what it measures.
    static func take() -> MemorySample {
        var usage = rusage()
        precondition(getrusage(RUSAGE_SELF, &usage) == 0, "getrusage failed")
        var stats = malloc_statistics_t()
        malloc_zone_statistics(nil, &stats)
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        precondition(result == KERN_SUCCESS, "task_info failed")
        return MemorySample(
            uptimeNanoseconds: monotonicNanoseconds(),
            peakRSSBytes: Int(usage.ru_maxrss),
            mallocInUseBytes: Int(stats.size_in_use),
            physicalFootprintBytes: Int(clamping: info.phys_footprint),
            physicalFootprintPeakBytes: Int(clamping: info.ledger_phys_footprint_peak)
        )
    }
}

/// One sample with what was alive when it was taken. `stepNanoseconds` is the work that led to this stage, or zero.
struct StageRecord {
    let stage: StaticString
    let holding: StaticString
    let iteration: Int
    let stepNanoseconds: UInt64
    let sample: MemorySample
}

/// One transfer's exact byte counts, reader calls, step timings and round-trip result.
struct TransferOutcome {
    var iteration = 0
    var measuredBodyBytes = 0
    var frameBytes = 0
    var readBodyBytes = 0
    var consumeCalls = 0
    var measureNanoseconds: UInt64 = 0
    var encodeNanoseconds: UInt64 = 0
    var readNanoseconds: UInt64 = 0
    var decodeNanoseconds: UInt64 = 0
    var compareNanoseconds: UInt64 = 0
    var roundTripEqual = false

    var totalNanoseconds: UInt64 {
        measureNanoseconds + encodeNanoseconds + readNanoseconds + decodeNanoseconds + compareNanoseconds
    }
}

/// What the lifetime phase learned beyond its samples.
struct LifetimeFacts {
    var ownerBuildNanoseconds: UInt64 = 0
    var draftBuildNanoseconds: UInt64 = 0
    var draftEqualsOwnerObservation = false
}

/// Fixed storage for the lifetime phase. Its capacity is reserved before the baseline sample, and an append past it is a
/// probe bug, so recording never allocates between samples.
final class Ledger {
    static let stageCapacity = 128
    private(set) var stages = ContiguousArray<StageRecord>()
    private(set) var transfers = ContiguousArray<TransferOutcome>()

    init() {
        stages.reserveCapacity(Self.stageCapacity)
        transfers.reserveCapacity(Probe.repeatIterations)
    }

    func mark(_ stage: StaticString, holding: StaticString, iteration: Int = 0, step: UInt64 = 0) {
        precondition(stages.count < stages.capacity, "stage ledger full")
        stages.append(StageRecord(stage: stage, holding: holding, iteration: iteration, stepNanoseconds: step,
                                  sample: .take()))
    }

    func record(_ outcome: TransferOutcome) {
        precondition(transfers.count < transfers.capacity, "transfer ledger full")
        transfers.append(outcome)
    }
}

// MARK: - Lifetime phase

enum Probe {
    static let repeatIterations = 20

    /// Builds the owner and the draft, runs the mode's transfers with both alive, then releases the draft and the owner.
    static func lifetime(_ mode: Mode, _ ledger: Ledger) throws -> LifetimeFacts {
        var facts = LifetimeFacts()
        var start = monotonicNanoseconds()
        var owner: PrivateEditorReply? = try PrivateEditorMaximumFixture.reply(distinct: mode.distinct)
        facts.ownerBuildNanoseconds = monotonicNanoseconds() - start
        withExtendedLifetime(owner) {
            ledger.mark("owner-built", holding: "owner", step: facts.ownerBuildNanoseconds)
        }
        start = monotonicNanoseconds()
        var draft: PrivateEditorObservation? = try PrivateEditorMaximumFixture.observation(distinct: mode.distinct)
        facts.draftBuildNanoseconds = monotonicNanoseconds() - start
        withExtendedLifetime((owner, draft)) {
            ledger.mark("draft-built", holding: "owner+draft", step: facts.draftBuildNanoseconds)
        }

        for iteration in 1...mode.iterations {
            let outcome = try autoreleasepool {
                try transfer(owner: owner!, draft: draft!, iteration: iteration, ledger: ledger, stages: mode.samplesStages)
            }
            ledger.record(outcome)
            withExtendedLifetime((owner, draft)) {
                ledger.mark("transfer-released", holding: "owner+draft", iteration: iteration, step: outcome.totalNanoseconds)
            }
        }

        // Scoped, so the extracted observation does not keep the owner's storage alive past `owner = nil`.
        facts.draftEqualsOwnerObservation = try { () throws -> Bool in
            guard case .observation(let held) = owner!.answer else {
                throw ProbeFailure.notAnObservation
            }
            return held == draft!
        }()
        draft = nil
        withExtendedLifetime(owner) {
            ledger.mark("draft-released", holding: "owner")
        }
        owner = nil
        ledger.mark("owner-released", holding: "nothing")
        return facts
    }

    /// One host-to-client transfer of the owner's reply. The owner and the draft stay alive for the whole call; each
    /// transient form is dropped as soon as the next one exists.
    @inline(never)
    static func transfer(
        owner: PrivateEditorReply, draft: PrivateEditorObservation, iteration: Int, ledger: Ledger, stages: Bool
    ) throws -> TransferOutcome {
        try withExtendedLifetime(draft) {
            try withExtendedLifetime(owner) {
                var outcome = TransferOutcome()
                outcome.iteration = iteration

                var start = monotonicNanoseconds()
                outcome.measuredBodyBytes = try PrivateConfigurationEncoder.measureBody(owner)
                outcome.measureNanoseconds = monotonicNanoseconds() - start
                if stages {
                    ledger.mark("measured", holding: "owner+draft", iteration: iteration, step: outcome.measureNanoseconds)
                }

                start = monotonicNanoseconds()
                var wire: SecretBytes? = try PrivateConfigurationEncoder.encode(owner)
                outcome.encodeNanoseconds = monotonicNanoseconds() - start
                outcome.frameBytes = wire!.count
                if stages {
                    withExtendedLifetime(wire) {
                        ledger.mark("encoded", holding: "owner+draft+wire", iteration: iteration,
                                    step: outcome.encodeNanoseconds)
                    }
                }

                start = monotonicNanoseconds()
                var body: PrivateConfigurationFrameBody? = try readReply(wire!, calls: &outcome.consumeCalls)
                outcome.readNanoseconds = monotonicNanoseconds() - start
                outcome.readBodyBytes = body!.bytes.count
                if stages {
                    withExtendedLifetime((wire, body)) {
                        ledger.mark("read", holding: "owner+draft+wire+body", iteration: iteration,
                                    step: outcome.readNanoseconds)
                    }
                }
                wire = nil
                if stages {
                    withExtendedLifetime(body) {
                        ledger.mark("wire-dropped", holding: "owner+draft+body", iteration: iteration)
                    }
                }

                start = monotonicNanoseconds()
                var decoded: PrivateEditorReply? = try PrivateConfigurationDecoder.decodeReply(body!)
                outcome.decodeNanoseconds = monotonicNanoseconds() - start
                if stages {
                    withExtendedLifetime((body, decoded)) {
                        ledger.mark("decoded", holding: "owner+draft+body+decoded", iteration: iteration,
                                    step: outcome.decodeNanoseconds)
                    }
                }
                body = nil
                if stages {
                    withExtendedLifetime(decoded) {
                        ledger.mark("body-dropped", holding: "owner+draft+decoded", iteration: iteration)
                    }
                }

                start = monotonicNanoseconds()
                outcome.roundTripEqual = decoded! == owner
                outcome.compareNanoseconds = monotonicNanoseconds() - start
                decoded = nil
                if stages {
                    ledger.mark("decoded-dropped", holding: "owner+draft", iteration: iteration,
                                step: outcome.compareNanoseconds)
                }
                return outcome
            }
        }
    }

    /// Feeds the whole remaining frame to the production reader, which takes what its per-call budget allows. Counts
    /// the calls, and requires the frame to end exactly at the reply's terminator.
    @inline(never)
    static func readReply(_ frame: SecretBytes, calls: inout Int) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader(expecting: .editorReply)
        return try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let (step, consumed) = try reader.consume(bytes[offset...])
                calls += 1
                guard consumed > 0 else {
                    throw ProbeFailure.readerStalled
                }
                offset += consumed
                if case .frame(let body) = step {
                    guard offset == bytes.count else {
                        throw ProbeFailure.trailingBytes
                    }
                    try reader.finish()
                    return body
                }
            }
            throw ProbeFailure.incompleteFrame
        }
    }
}

// MARK: - Numeric lexemes

/// Token classes of one body. A flat walk over valid encoder output with the production lexical primitives: strings
/// and literals are consumed whole and skipped, punctuation is stepped over, and each number's span is classified. It
/// builds no tree and checks no structure; the decoder's scanner does that. A number with `.`, `e` or `E` is a Double
/// lexeme; the reply writer spells every Double with one of them and no integer with any.
struct NumericLexemes {
    var integers = 0, integerBytes = 0, widestIntegerBytes = 0
    var doubles = 0, doubleBytes = 0, widestDoubleBytes = 0
    var strings = 0, stringBytes = 0
    var literals = 0, literalBytes = 0
    var punctuationBytes = 0, whitespaceBytes = 0

    var accountedBytes: Int {
        integerBytes + doubleBytes + stringBytes + literalBytes + punctuationBytes + whitespaceBytes
    }

    static func scan(_ body: UnsafeBufferPointer<UInt8>) throws -> NumericLexemes {
        var result = NumericLexemes()
        var cursor = JSONByteCursor(body)
        while true {
            let gap = cursor.position
            cursor.skipWhitespace()
            result.whitespaceBytes += cursor.position - gap
            guard let byte = cursor.current else {
                return result
            }
            let start = cursor.position
            switch byte {
            case UInt8(ascii: "\""):
                try cursor.scanString { _ in }
                result.strings += 1
                result.stringBytes += cursor.position - start
            case UInt8(ascii: "t"), UInt8(ascii: "f"), UInt8(ascii: "n"):
                try cursor.scanLiteral(byte == UInt8(ascii: "t") ? "true" : byte == UInt8(ascii: "f") ? "false" : "null")
                result.literals += 1
                result.literalBytes += cursor.position - start
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try cursor.scanNumber()
                let span = cursor.span(from: start)
                if span.contains(where: { $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "e") || $0 == UInt8(ascii: "E") }) {
                    result.doubles += 1
                    result.doubleBytes += span.count
                    result.widestDoubleBytes = max(result.widestDoubleBytes, span.count)
                } else {
                    result.integers += 1
                    result.integerBytes += span.count
                    result.widestIntegerBytes = max(result.widestIntegerBytes, span.count)
                }
            case UInt8(ascii: "{"), UInt8(ascii: "}"), UInt8(ascii: "["), UInt8(ascii: "]"),
                 UInt8(ascii: ","), UInt8(ascii: ":"):
                cursor.consumeIf(byte)
                result.punctuationBytes += 1
            default:
                throw JSONByteCursor.Fault.unexpectedByte
            }
        }
    }
}

// MARK: - Report (after the lifetime phase)

final class Report {
    let mode: Mode
    private(set) var failures: [String] = []

    init(mode: Mode) {
        self.mode = mode
    }

    /// One NDJSON record, built and printed inside its own autorelease pool.
    func emit(_ fields: [String: Any]) {
        autoreleasepool {
            var record = fields
            record["mode"] = mode.rawValue
            let data = try! JSONSerialization.data(withJSONObject: record, options: [.sortedKeys])
            print(String(decoding: data, as: UTF8.self))
            fflush(stdout)
        }
    }

    func check(_ passed: Bool, _ name: String) {
        emit(["record": "check", "name": name, "passed": passed])
        if !passed {
            failures.append(name)
        }
    }

    func fail(_ name: String, _ error: any Error) {
        emit(["record": "error", "name": name, "error": Self.label(error)])
        failures.append(name)
    }

    /// Fixed labels only. No error here carries fixture text.
    static func label(_ error: any Error) -> String {
        switch error {
        case let error as PrivateConfigurationWireError: "wire: \(error.description)"
        case let error as JSONByteCursor.Fault: "cursor: \(error)"
        case let error as ProbeFailure: "probe: \(error)"
        case is PrivateEditorMaximumFixture.Failure: "fixture: failure"
        default: "unexpected: \(type(of: error))"
        }
    }

    func emitScope() {
        emit([
            "record": "scope",
            "measures": "process samples of one in-process host owner value and one client draft around the production reply encoder, frame reader and decoder (Release ConduitShared); not installed-app RAM, not a whole-host peak, not Stop/status latency",
            "fixtureDistinct": mode.distinct,
            "iterations": mode.iterations,
            "readerInputBudgetBytes": PrivateConfigurationFrame.maxInputBytesPerConsume,
            "replyFrameCap": PrivateConfigurationFrame.maxEditorReplyFrameBytes,
        ])
    }

    static func sampleFields(_ sample: MemorySample) -> [String: Any] {
        ["peakRSSBytes": sample.peakRSSBytes, "mallocInUseBytes": sample.mallocInUseBytes,
         "physicalFootprintBytes": sample.physicalFootprintBytes,
         "physicalFootprintPeakBytes": sample.physicalFootprintPeakBytes]
    }

    func emitLifetime(_ ledger: Ledger, _ lifetime: Result<LifetimeFacts, any Error>) {
        let stages = ledger.stages
        let baseline = stages.first!.sample
        for stage in stages {
            var fields = Self.sampleFields(stage.sample)
            fields["record"] = "stage"
            fields["stage"] = "\(stage.stage)"
            fields["holding"] = "\(stage.holding)"
            fields["iteration"] = stage.iteration
            fields["stepNanoseconds"] = stage.stepNanoseconds
            fields["sinceBaselineNanoseconds"] = stage.sample.uptimeNanoseconds - baseline.uptimeNanoseconds
            emit(fields)
        }
        let cap = PrivateConfigurationFrame.maxEditorReplyFrameBytes
        let budget = PrivateConfigurationFrame.maxInputBytesPerConsume
        for transfer in ledger.transfers {
            emit(["record": "transfer", "iteration": transfer.iteration, "measuredBodyBytes": transfer.measuredBodyBytes,
                  "frameBytes": transfer.frameBytes, "readBodyBytes": transfer.readBodyBytes,
                  "consumeCalls": transfer.consumeCalls, "measureNanoseconds": transfer.measureNanoseconds,
                  "encodeNanoseconds": transfer.encodeNanoseconds, "readNanoseconds": transfer.readNanoseconds,
                  "decodeNanoseconds": transfer.decodeNanoseconds, "compareNanoseconds": transfer.compareNanoseconds,
                  "roundTripEqual": transfer.roundTripEqual])
        }
        switch lifetime {
        case .success(let facts):
            emit(["record": "lifetime", "ownerBuildNanoseconds": facts.ownerBuildNanoseconds,
                  "draftBuildNanoseconds": facts.draftBuildNanoseconds,
                  "draftEqualsOwnerObservation": facts.draftEqualsOwnerObservation])
            check(facts.draftEqualsOwnerObservation, "lifetime.draftEqualsOwnerObservation")
        case .failure(let error):
            fail("lifetime", error)
        }
        let transfers = ledger.transfers
        check(transfers.count == mode.iterations, "lifetime.everyTransferRan")
        check(transfers.allSatisfy(\.roundTripEqual), "lifetime.decodedReplyEqualsOriginal")
        check(transfers.allSatisfy { $0.readBodyBytes == $0.measuredBodyBytes }, "lifetime.readBodyEqualsMeasureBody")
        check(transfers.allSatisfy {
            $0.frameBytes == PrivateConfigurationFrame.frameByteCount(bodyCount: $0.measuredBodyBytes)
        }, "lifetime.frameMatchesHeaderFormula")
        check(transfers.allSatisfy { $0.frameBytes <= cap }, "lifetime.frameWithinReplyCap")
        // Each call examines at most the budget, header included, so a frame needs at least this many calls.
        check(transfers.allSatisfy { $0.consumeCalls >= ($0.frameBytes + budget - 1) / budget },
              "lifetime.readerCallsRespectInputBudget")
        check(Set(transfers.map(\.frameBytes)).count <= 1, "lifetime.everyTransferSameFrameBytes")

        guard let final = stages.last?.sample else { return }
        func live(_ name: String) -> Int? {
            stages.first { "\($0.stage)" == name }?.sample.mallocInUseBytes
        }
        if let ownerBuilt = live("owner-built"), let draftBuilt = live("draft-built"),
           let draftReleased = live("draft-released"), let ownerReleased = live("owner-released")
        {
            let ownerBytes = ownerBuilt - baseline.mallocInUseBytes
            let draftBytes = draftBuilt - ownerBuilt
            emit(["record": "retained-values", "ownerLiveMallocBytes": ownerBytes, "draftLiveMallocBytes": draftBytes,
                  "draftReleaseReturnedBytes": draftBuilt - draftReleased,
                  "ownerReleaseReturnedBytes": draftReleased - ownerReleased,
                  "residualAfterReleaseBytes": ownerReleased - baseline.mallocInUseBytes])
            // A release sample is labelled by what the probe dropped; this confirms the allocator saw most of it return.
            check(draftBuilt - draftReleased > draftBytes / 2, "lifetime.draftReleaseReturnsDraftBytes")
            check(draftReleased - ownerReleased > ownerBytes / 2, "lifetime.ownerReleaseReturnsOwnerBytes")
        } else {
            check(false, "lifetime.releaseStagesRecorded")
        }
        let widest = stages.max { $0.sample.mallocInUseBytes < $1.sample.mallocInUseBytes }!
        var summary = Self.sampleFields(final)
        summary["record"] = "lifetime-summary"
        summary["baselineMallocInUseBytes"] = baseline.mallocInUseBytes
        summary["baselinePeakRSSBytes"] = baseline.peakRSSBytes
        summary["widestLiveMallocInUseBytes"] = widest.sample.mallocInUseBytes
        summary["widestLiveMallocStage"] = "\(widest.stage)"
        summary["widestLiveMallocHolding"] = "\(widest.holding)"
        summary["finalHolding"] = "\(stages.last!.holding)"
        summary["note"] = "peaks are monotonic process high-water marks at the end of the lifetime phase, before the sizing analysis"
        emit(summary)

        guard mode == .repeatDistinct else { return }
        let released = stages.filter { "\($0.stage)" == "transfer-released" }
        guard let first = released.first, let last = released.last else { return }
        let malloc = released.map(\.sample.mallocInUseBytes)
        func median(_ values: [UInt64]) -> UInt64 { values.sorted()[values.count / 2] }
        var repeatSummary: [String: Any] = [
            "record": "repeat-summary",
            "releasedSamplesHold": "owner+draft (both remain across every iteration)",
            "iterations": released.count,
            "firstReleasedMallocInUseBytes": first.sample.mallocInUseBytes,
            "lastReleasedMallocInUseBytes": last.sample.mallocInUseBytes,
            "releasedMallocGrowthBytes": last.sample.mallocInUseBytes - first.sample.mallocInUseBytes,
            "widestReleasedMallocInUseBytes": malloc.max()!,
            "firstReleasedPhysicalFootprintBytes": first.sample.physicalFootprintBytes,
            "lastReleasedPhysicalFootprintBytes": last.sample.physicalFootprintBytes,
            "lastReleasedPeakRSSBytes": last.sample.peakRSSBytes,
            "lastReleasedPhysicalFootprintPeakBytes": last.sample.physicalFootprintPeakBytes,
        ]
        if released.count >= 10 {
            repeatSummary["releasedMallocGrowthFromIteration10Bytes"] =
                last.sample.mallocInUseBytes - released[9].sample.mallocInUseBytes
        }
        for (name, values) in [("measure", transfers.map(\.measureNanoseconds)),
                               ("encode", transfers.map(\.encodeNanoseconds)),
                               ("read", transfers.map(\.readNanoseconds)),
                               ("decode", transfers.map(\.decodeNanoseconds)),
                               ("compare", transfers.map(\.compareNanoseconds)),
                               ("total", transfers.map(\.totalNanoseconds))] {
            repeatSummary[name + "MinNanoseconds"] = values.min()!
            repeatSummary[name + "MedianNanoseconds"] = median(values)
            repeatSummary[name + "MaxNanoseconds"] = values.max()!
        }
        emit(repeatSummary)
    }

    // MARK: Sizing analysis

    /// Exact sizes of the fixture's reply, then a conservative numeric allowance over its actual numeric lexemes.
    func analyze() {
        do {
            let cap = PrivateConfigurationFrame.maxEditorReplyFrameBytes
            let reply = try PrivateEditorMaximumFixture.reply(distinct: mode.distinct)
            let measured = try PrivateConfigurationEncoder.measureBody(reply)
            let frame = try PrivateConfigurationEncoder.encode(reply)
            let (headerBytes, lexemes) = try frame.withUnsafeBytes { bytes -> (Int, NumericLexemes) in
                guard let lineFeed = bytes.firstIndex(of: 0x0A), lineFeed < bytes.count - 1, bytes.last == 0x0A else {
                    throw ProbeFailure.malformedFrame
                }
                let body = UnsafeBufferPointer(rebasing: bytes[(lineFeed + 1)..<(bytes.count - 1)])
                return (lineFeed + 1, try NumericLexemes.scan(body))
            }
            let bodyBytes = frame.count - headerBytes - 1
            emit(["record": "size", "bodyBytes": bodyBytes, "frameBytes": frame.count, "headerBytes": headerBytes,
                  "replyFrameCap": cap, "measuredHeadroomBytes": cap - frame.count])
            check(bodyBytes == measured, "size.encodedBodyEqualsMeasureBody")
            check(frame.count == PrivateConfigurationFrame.frameByteCount(bodyCount: measured), "size.frameMatchesHeaderFormula")
            check(frame.count <= cap, "size.frameWithinReplyCap")

            emit(["record": "lexemes", "integers": lexemes.integers, "integerBytes": lexemes.integerBytes,
                  "widestIntegerBytes": lexemes.widestIntegerBytes, "doubles": lexemes.doubles,
                  "doubleBytes": lexemes.doubleBytes, "widestDoubleBytes": lexemes.widestDoubleBytes,
                  "strings": lexemes.strings, "stringBytes": lexemes.stringBytes, "literals": lexemes.literals,
                  "literalBytes": lexemes.literalBytes, "punctuationBytes": lexemes.punctuationBytes,
                  "whitespaceBytes": lexemes.whitespaceBytes])
            check(lexemes.accountedBytes == bodyBytes, "numeric.walkAccountsForEveryBodyByte")
            check(String(Int.min).utf8.count == integerLexemeMaximumBytes
                  && String(Int.max).utf8.count <= integerLexemeMaximumBytes
                  && String(UInt64.max).utf8.count <= integerLexemeMaximumBytes, "numeric.integerLexemeMaximumIsTwenty")
            check(lexemes.widestIntegerBytes <= integerLexemeMaximumBytes, "numeric.observedIntegersWithinTwenty")
            check(lexemes.widestDoubleBytes == String(PrivateEditorMaximumFixture.widestDouble).utf8.count,
                  "numeric.observedDoubleIsTheFixtureSpelling")

            let numericBytes = lexemes.integerBytes + lexemes.doubleBytes
            let allowance = lexemes.integers * integerLexemeMaximumBytes + lexemes.doubles * doubleLexemeMaximumBytes
                - numericBytes
            let boundBody = bodyBytes + allowance
            let boundFrame = PrivateConfigurationFrame.frameByteCount(bodyCount: boundBody)
            emit(["record": "numeric-bound",
                  "label": "CONSERVATIVE NUMERIC BOUND for this fixture: its widest texts and counts and observed scalar spellings, with every numeric lexeme charged at its widest; not a proved universal maximum",
                  "measuredFrameBytes": frame.count, "integerLexemeMaximumBytes": integerLexemeMaximumBytes,
                  "doubleLexemeMaximumBytes": doubleLexemeMaximumBytes, "actualNumericBytes": numericBytes,
                  "numericAllowanceBytes": allowance, "boundBodyBytes": boundBody, "boundFrameBytes": boundFrame,
                  "replyFrameCap": cap, "boundHeadroomBytes": cap - boundFrame, "boundWithinCap": boundFrame <= cap])
        } catch {
            fail("analysis", error)
        }
    }

    func finish() -> Never {
        emit(["record": "summary", "failedChecks": failures.count, "failures": failures])
        exit(failures.isEmpty ? 0 : 1)
    }
}

// MARK: - Entry

@main
enum ProbeMain {
    static func main() {
        guard CommandLine.arguments.count == 2, let mode = Mode(rawValue: CommandLine.arguments[1]) else {
            FileHandle.standardError.write(Data("usage: probe wide-shared|wide-distinct|repeat-distinct\n".utf8))
            exit(64)
        }
        let ledger = Ledger()
        ledger.mark("baseline", holding: "nothing")
        let lifetime = Result { try Probe.lifetime(mode, ledger) }

        // The lifetime phase is over: print it, then analyze.
        let report = Report(mode: mode)
        report.emitScope()
        report.emitLifetime(ledger, lifetime)
        if mode != .repeatDistinct {
            report.analyze()
        }
        report.finish()
    }
}
