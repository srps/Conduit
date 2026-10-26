// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ConduitShared

/// Segmentation tests for the frame reader's batched body copy. Every case runs on both input paths: an `ArraySlice`,
/// which has contiguous storage and takes the bulk copy, and `NoncontiguousBytes`, which has none and is read one byte
/// at a time. Each kind's header letter is written out here, not taken from the codec. No case measures time.
final class PrivateConfigFrameBatchTests: XCTestCase {
    private struct Failure: Error {
        let message: String
    }

    private enum Path: CaseIterable {
        case contiguous
        case noncontiguous
    }

    private static let budget = PrivateConfigurationFrame.maxInputBytesPerConsume
    private static let kinds: [(kind: PrivateConfigurationFrame.Kind, letter: String)] = [
        (.update, "Q"), (.read, "G"), (.editorReply, "R"),
    ]

    // MARK: - Input paths

    /// The two paths are the ones the tests name: a slice offers contiguous storage, the wrapper and its prefix do not.
    func testTheTwoInputPathsAreTheOnesTheTestsName() {
        let bytes: [UInt8] = [1, 2, 3]
        XCTAssertEqual(bytes[1...].withContiguousStorageIfAvailable { $0.count }, 2)
        XCTAssertNil(NoncontiguousBytes(bytes[...]).withContiguousStorageIfAvailable { $0.count })
        XCTAssertNil(NoncontiguousBytes(bytes[...]).prefix(2).withContiguousStorageIfAvailable { $0.count })
    }

    // MARK: - Segmentation

    /// A frame inside a larger buffer, read through slices that start past index zero. The bytes before and after it
    /// would be refused as a header, so reading either one fails the case.
    func testNonzeroSliceOffsetsReadEveryKindOnBothPaths() throws {
        let lead = 37
        for (kind, letter) in Self.kinds {
            for count in [1, 2, 40_000] {
                let body = Self.body(count, seed: count)
                let frame = Self.frame(letter, body)
                let storage = Array(repeating: UInt8(0xFF), count: lead) + frame + Array(repeating: UInt8(0xFF), count: 11)
                for chunk in [1, 5, 4_096, Self.budget, 65_536] {
                    for path in Path.allCases {
                        let label = "\(letter) body \(count) chunk \(chunk) \(path)"
                        let read = try readOne(storage, from: lead, chunk: chunk, kind: kind, path: path, label: label)
                        XCTAssertEqual(read.body, body, label)
                        XCTAssertEqual(read.end, lead + frame.count, label)
                    }
                }
            }
        }
    }

    /// The header split at every byte, and a little into the body, then the rest in budget-sized pieces. Nothing is
    /// buffered until the header's line feed, and the body that follows is copied intact.
    func testHeaderSplitAtEveryByteThenBatchedBody() throws {
        for (kind, letter) in Self.kinds {
            let body = Self.body(20_000, seed: 3)
            let frame = Self.frame(letter, body)
            let headerCount = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
            for split in 0...(headerCount + 2) {
                for path in Path.allCases {
                    let label = "\(letter) split \(split) \(path)"
                    let reader = PrivateConfigurationFrameReader(expecting: kind)
                    let (step, used) = try consume(reader, frame[..<split], path)
                    guard case .needsInput = step else {
                        throw Failure(message: "\(label): a frame before its body")
                    }
                    XCTAssertEqual(used, split, label)
                    XCTAssertEqual(reader.retainedByteCount, max(0, split - headerCount), label)
                    let read = try readOne(frame, from: split, chunk: Self.budget, kind: kind, path: path, reader: reader,
                                           label: label)
                    XCTAssertEqual(read.body, body, label)
                    XCTAssertEqual(read.end, frame.count, label)
                }
            }
        }
    }

    /// The call budget counts header, body and terminator together. With the next frame's bytes behind each frame, the
    /// budget falls one byte before the frame's end, exactly at it, at the terminator, and inside the body.
    func testBudgetBoundaryInsideBodyAtTerminatorAndAfterFrame() throws {
        let budget = Self.budget
        for (kind, letter) in Self.kinds {
            for delta in [-1, 0, 1, 100] {
                let count = try Self.bodyCount(forFrameBytes: budget + delta)
                let body = Self.body(count, seed: delta + 7)
                let frame = Self.frame(letter, body)
                XCTAssertEqual(frame.count, budget + delta)
                let headerCount = frame.count - count - 1
                let next = Self.body(5)
                let input = frame + Self.frame(letter, next)
                for path in Path.allCases {
                    let label = "\(letter) frame budget\(delta >= 0 ? "+" : "")\(delta) \(path)"
                    let reader = PrivateConfigurationFrameReader(expecting: kind)
                    let (step, consumed) = try consume(reader, input[...], path)
                    if delta <= 0 {
                        guard case .frame(let read) = step else {
                            throw Failure(message: "\(label): expected the frame within one call")
                        }
                        XCTAssertEqual(consumed, frame.count, label)
                        XCTAssertEqual(read.bytes.bytes(), body, label)
                    } else {
                        guard case .needsInput = step else {
                            throw Failure(message: "\(label): expected the budget to stop the call")
                        }
                        XCTAssertEqual(consumed, budget, label)
                        XCTAssertEqual(reader.retainedByteCount, min(count, budget - headerCount), label)
                        let (second, used) = try consume(reader, input[budget...], path)
                        guard case .frame(let read) = second else {
                            throw Failure(message: "\(label): expected the frame in the second call")
                        }
                        XCTAssertEqual(used, delta, label)
                        XCTAssertEqual(read.bytes.bytes(), body, label)
                    }
                    // The next frame was left whole for a reset reader.
                    reader.reset()
                    let read = try readOne(input, from: frame.count, chunk: budget, kind: kind, path: path,
                                           reader: reader, label: label)
                    XCTAssertEqual(read.body, next, label)
                    XCTAssertEqual(read.end, input.count, label)
                }
            }
        }
    }

    /// Frames back to back in one stream, each piece reaching into the next frame: each call stops at its frame's end,
    /// the completed reader takes nothing more, and a reset reader continues from the next header.
    func testConsecutiveFramesAreReadOneAtATimeWithReset() throws {
        for (kind, letter) in Self.kinds {
            let bodies = [Self.body(3_000, seed: 1), Self.body(25_000, seed: 2), Self.body(1, seed: 3)]
            let stream = bodies.flatMap { Self.frame(letter, $0) }
            for chunk in [7, 4_096, Self.budget, stream.count] {
                for path in Path.allCases {
                    let reader = PrivateConfigurationFrameReader(expecting: kind)
                    var offset = 0
                    for (index, expected) in bodies.enumerated() {
                        let label = "\(letter) frame \(index) chunk \(chunk) \(path)"
                        let read = try readOne(stream, from: offset, chunk: chunk, kind: kind, path: path, reader: reader,
                                               label: label)
                        XCTAssertEqual(read.body, expected, label)
                        XCTAssertEqual(read.end, offset + Self.frame(letter, expected).count, label)
                        XCTAssertThrowsError(try consume(reader, stream[read.end...], path), label) {
                            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidState, label)
                        }
                        reader.reset()
                        offset = read.end
                    }
                }
            }
        }
    }

    // MARK: - Refusals

    /// A wrong terminator after a batched body, end of input inside one, the header refusals and empty input, on both
    /// paths. Failure releases the body and is sticky; reset reads again.
    func testRefusalsEndOfInputAndEmptyInputOnBothPaths() throws {
        for (kind, letter) in Self.kinds {
            let body = Self.body(30_000, seed: 9)
            let frame = Self.frame(letter, body)
            let headerCount = frame.count - body.count - 1
            for path in Path.allCases {
                let label = "\(letter) \(path)"

                var badTerminator = frame
                badTerminator[badTerminator.count - 1] = UInt8(ascii: "X")
                let reader = PrivateConfigurationFrameReader(expecting: kind)
                XCTAssertThrowsError(try readOne(badTerminator, chunk: Self.budget, kind: kind, path: path, reader: reader,
                                                 label: label)) {
                    XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody, label)
                }
                XCTAssertEqual(reader.retainedByteCount, 0, label)
                XCTAssertThrowsError(try consume(reader, Self.frame(letter, [0x7B, 0x7D])[...], path), label) {
                    XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody, label)
                }
                XCTAssertThrowsError(try reader.finish(), label) {
                    XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody, label)
                }

                let open = PrivateConfigurationFrameReader(expecting: kind)
                let (step, used) = try consume(open, frame[..<10_000], path)
                guard case .needsInput = step else {
                    throw Failure(message: "\(label): expected an open body")
                }
                XCTAssertEqual(used, 10_000, label)
                XCTAssertEqual(open.retainedByteCount, 10_000 - headerCount, label)
                let (emptyStep, emptyUsed) = try consume(open, frame[10_000..<10_000], path)
                guard case .needsInput = emptyStep else {
                    throw Failure(message: "\(label): empty input completed a frame")
                }
                XCTAssertEqual(emptyUsed, 0, label)
                XCTAssertEqual(open.retainedByteCount, 10_000 - headerCount, label)
                XCTAssertThrowsError(try open.finish(), label) {
                    XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody, label)
                }
                XCTAssertEqual(open.retainedByteCount, 0, label)
                open.reset()
                let read = try readOne(frame, chunk: Self.budget, kind: kind, path: path, reader: open, label: label)
                XCTAssertEqual(read.body, body, label)

                let refusals: [(String, PrivateConfigurationWireError)] = [
                    ("PCV1 \(letter) 8388593\n", .frameTooLarge),
                    ("PCV1 X 2\n{}\n", .unexpectedFrameKind),
                    ("PCV2 \(letter) 2\n{}\n", .unsupportedVersion),
                    ("PCV1 \(letter) 02\n{}\n", .malformedHeader),
                ]
                for (text, expected) in refusals {
                    let refusing = PrivateConfigurationFrameReader(expecting: kind)
                    XCTAssertThrowsError(try consume(refusing, Array(text.utf8)[...], path), "\(label) \(text)") {
                        XCTAssertEqual($0 as? PrivateConfigurationWireError, expected, "\(label) \(text)")
                    }
                    XCTAssertEqual(refusing.retainedByteCount, 0, "\(label) \(text)")
                }

                let fresh = PrivateConfigurationFrameReader(expecting: kind)
                let (freshStep, freshUsed) = try consume(fresh, frame[0..<0], path)
                guard case .needsInput = freshStep else {
                    throw Failure(message: "\(label): empty input completed a frame")
                }
                XCTAssertEqual(freshUsed, 0, label)
            }
        }
    }

    // MARK: - Buffer

    /// Bulk and single appends mixed across several growths, ending exactly at the ceiling: the bytes are the ones
    /// appended, and capacity never passes the ceiling.
    func testBulkAppendMatchesBytewiseAppendAcrossGrowth() {
        let runs = [0, 1, 9, 4_096, 1, 20_000, 3]
        let buffer = PrivateFrameBuffer(initialCapacity: 10, ceiling: runs.reduce(0, +) + runs.count)
        var expected: [UInt8] = []
        for (index, length) in runs.enumerated() {
            let run = Self.body(length, seed: index)
            run.withUnsafeBufferPointer { buffer.append(contentsOf: $0) }
            expected += run
            buffer.append(UInt8(index))
            expected.append(UInt8(index))
            XCTAssertLessThanOrEqual(buffer.capacity, buffer.ceiling, "run \(index)")
            XCTAssertGreaterThanOrEqual(buffer.capacity, buffer.count, "run \(index)")
        }
        XCTAssertEqual(buffer.count, buffer.ceiling)
        XCTAssertEqual(buffer.withBytes { Array($0) }, expected)
        buffer.release()
        XCTAssertEqual(buffer.count, 0)
        XCTAssertEqual(buffer.capacity, 0)
    }

    // MARK: - Helpers

    /// Body bytes that run through every byte value, line feeds included: the reader goes by the declared length.
    private static func body(_ count: Int, seed: Int = 0) -> [UInt8] {
        (0..<count).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ seed) }
    }

    private static func frame(_ letter: String, _ body: [UInt8]) -> [UInt8] {
        Array("PCV1 \(letter) \(body.count)\n".utf8) + body + [0x0A]
    }

    /// The body length whose whole frame is `total` bytes: the seven-byte prefix, the decimal digits, the header's line
    /// feed, the body and the terminator.
    private static func bodyCount(forFrameBytes total: Int) throws -> Int {
        for digits in 1...7 {
            let count = total - 7 - digits - 2
            if count > 0, String(count).count == digits {
                return count
            }
        }
        throw Failure(message: "no body length makes a frame of \(total) bytes")
    }

    private func consume(
        _ reader: PrivateConfigurationFrameReader, _ piece: ArraySlice<UInt8>, _ path: Path
    ) throws -> (step: PrivateConfigurationFrameStep, consumed: Int) {
        switch path {
        case .contiguous: try reader.consume(piece)
        case .noncontiguous: try reader.consume(NoncontiguousBytes(piece))
        }
    }

    /// Reads one frame of `input` from `start` in pieces of at most `chunk`, and returns its body and the offset after
    /// it. No call may use more than the budget, and a call that ends without a frame must use all it may.
    private func readOne(
        _ input: [UInt8],
        from start: Int = 0,
        chunk: Int,
        kind: PrivateConfigurationFrame.Kind,
        path: Path,
        reader: PrivateConfigurationFrameReader? = nil,
        label: String
    ) throws -> (body: [UInt8], end: Int) {
        let reader = reader ?? PrivateConfigurationFrameReader(expecting: kind)
        var offset = start
        while offset < input.count {
            let piece = input[offset..<min(offset + chunk, input.count)]
            let (step, consumed) = try consume(reader, piece, path)
            XCTAssertLessThanOrEqual(consumed, Self.budget, label)
            offset += consumed
            if case .frame(let body) = step {
                return (body.bytes.bytes(), offset)
            }
            XCTAssertEqual(consumed, min(piece.count, Self.budget), label)
        }
        throw Failure(message: "\(label): the input ended inside the frame")
    }
}

/// A byte collection without contiguous storage. It keeps the default `withContiguousStorageIfAvailable`, which
/// returns nil, so the reader reads it one byte at a time.
struct NoncontiguousBytes: Collection {
    private let storage: [UInt8]

    init(_ bytes: ArraySlice<UInt8>) {
        storage = Array(bytes)
    }

    var startIndex: Int { 0 }
    var endIndex: Int { storage.count }

    subscript(position: Int) -> UInt8 {
        storage[position]
    }

    func index(after index: Int) -> Int {
        index + 1
    }
}
