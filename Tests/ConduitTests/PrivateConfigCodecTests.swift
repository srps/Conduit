// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// Codec and frame tests for the private configuration request (decisions 0018 and 0019).
/// They use the real encoder, reader and decoder. Three checks do not depend on the production
/// reader: the header literal in `testFrameMatchesIndependentHeaderReference`, the known-request
/// semantic round trip, and a whole-buffer `ReferenceFrameParser` that the reader is compared with
/// across read schedules, fixed counterexamples and seeded mutations.
final class PrivateConfigCodecTests: XCTestCase {
    private struct Failure: Error {
        let message: String
    }

    // MARK: - Round trip and segmentation

    func testRoundTripSurvivesOneByteAtATime() throws {
        let request = try PrivateConfigSamples.request(profileName: "Café 🙂 \"q\" \\ \u{01}\t")
        let frame = try PrivateConfigurationEncoder.encode(request)
        let body = try readFrame(frame.bytes(), chunkSize: 1)
        XCTAssertEqual(try PrivateConfigurationDecoder.decode(body), request)
    }

    /// Read schedules do not change the decoded value. The reference here is the same reader read
    /// in one piece, so this proves schedule invariance only. The differential test below is the
    /// independent check of the reader.
    func testSeededSegmentationDecodesTheSameRequest() throws {
        let request = try PrivateConfigSamples.request(profileName: "seeded 🙂 segments")
        let bytes = try PrivateConfigurationEncoder.encode(request).bytes()
        let reference = try PrivateConfigurationDecoder.decode(readFrame(bytes, chunkSize: bytes.count))
        XCTAssertEqual(reference, request)

        var generator = PrivateConfigSplitMix(state: 0x5EED)
        for _ in 0..<64 {
            let chunk = Int.random(in: 1...4_096, using: &generator)
            let body = try readFrame(bytes, chunkSize: chunk)
            XCTAssertEqual(try PrivateConfigurationDecoder.decode(body), reference, "chunk \(chunk)")
        }
    }

    /// Checks the header literal only. The whole frame is checked by the differential tests.
    func testFrameMatchesIndependentHeaderReference() throws {
        let request = try PrivateConfigSamples.request()
        let bytes = try PrivateConfigurationEncoder.encode(request).bytes()
        let lineFeed = try XCTUnwrap(bytes.firstIndex(of: 0x0A))
        let header = String(decoding: bytes[..<lineFeed], as: UTF8.self)
        XCTAssertTrue(header.hasPrefix("PCV1 Q "), header)
        let declared = try XCTUnwrap(Int(header.dropFirst("PCV1 Q ".count)))
        XCTAssertEqual(bytes.count, lineFeed + 1 + declared + 1)
        XCTAssertEqual(bytes.last, 0x0A)
        XCTAssertEqual(bytes[(lineFeed + 1)], UInt8(ascii: "{"))
    }

    /// A body longer than the reader's first buffer capacity grows across several doublings. The
    /// result must match the bytes that went in, and the reader must not stop at a capacity edge.
    func testBodyLargerThanTheInitialCapacityGrowsIntact() throws {
        let name = String(repeating: "é🙂", count: 30_000)
        let request = try PrivateConfigSamples.request(profileName: name)
        let bytes = try PrivateConfigurationEncoder.encode(request).bytes()
        XCTAssertGreaterThan(bytes.count, PrivateConfigurationFrame.maxInputBytesPerConsume * 8)
        let decoded = try PrivateConfigurationDecoder.decode(readFrame(bytes, chunkSize: 16_384))
        XCTAssertEqual(decoded.runtime.profileName, name)
    }

    // MARK: - Cap

    func testExactCapAcceptedAndCapPlusOneRefused() throws {
        let cap = PrivateConfigurationFrame.maxFrameBytes
        // A seven-digit body length of `cap - 16` makes the whole frame exactly `cap`: the
        // header is `PCV1 Q ` plus seven digits plus a line feed (15 bytes), and the terminator
        // is one more. Each profile-name byte adds exactly one body byte, since 'a' needs no escape.
        let empty = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request(profileName: "")).bytes()
        let emptyBody = try Self.declaredBodyLength(empty)
        let name = String(repeating: "a", count: cap - 16 - emptyBody)

        let exact = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request(profileName: name))
        XCTAssertEqual(exact.count, cap)
        let decoded = try PrivateConfigurationDecoder.decode(readFrame(exact.bytes(), chunkSize: 16_384))
        XCTAssertEqual(decoded.runtime.profileName.utf8.count, name.utf8.count)

        let overflow = name + "a"
        XCTAssertThrowsError(try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request(profileName: overflow))) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .frameTooLarge)
        }
    }

    func testReaderRefusesOversizeLengthBeforeAnyBodyByte() throws {
        let reader = PrivateConfigurationFrameReader()
        // 8,388,593 bytes of body is one more than the cap allows with a seven-digit length.
        let header = Array("PCV1 Q 8388593\n".utf8)
        XCTAssertThrowsError(try reader.consume(header)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .frameTooLarge)
        }
        XCTAssertEqual(reader.retainedByteCount, 0)
    }

    func testLengthDigitsAreRefusedAsSoonAsTheyExceedTheCap() throws {
        let reader = PrivateConfigurationFrameReader()
        // 9,999,999 is above the cap, so the refusal comes at its last digit and needs no line feed.
        XCTAssertThrowsError(try reader.consume(Array("PCV1 Q 9999999".utf8))) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .frameTooLarge)
        }
    }

    // MARK: - Header refusals

    func testUnsupportedVersionAndKindAreRefusedInTheHeader() throws {
        try assertHeaderRefusal("PCV2 Q 5\n", .unsupportedVersion)
        try assertHeaderRefusal("PCV1 X 5\n", .unknownFrameKind)
        try assertHeaderRefusal("PCX1 Q 5\n", .malformedHeader)
        try assertHeaderRefusal("PCV1 Q 0\n", .malformedHeader)
        try assertHeaderRefusal("PCV1 Q 05\n", .malformedHeader)
        try assertHeaderRefusal("PCV1 Q \n", .malformedHeader)
        try assertHeaderRefusal("PCV1 Q 5x\n", .malformedHeader)
        // A line feed inside the prefix is classified by the first byte that differs, not as a header end.
        try assertHeaderRefusal("PCV\n", .unsupportedVersion)
        try assertHeaderRefusal("PCV1 \n", .unknownFrameKind)
        try assertHeaderRefusal("PC\n", .malformedHeader)
        try assertHeaderRefusal("\n", .malformedHeader)
    }

    func testFailureIsStickyAndReleasesBufferedBody() throws {
        let reader = PrivateConfigurationFrameReader()
        let partial = Array("PCV1 Q 40\n".utf8) + Array(repeating: UInt8(ascii: "a"), count: 10)
        _ = try reader.consume(partial)
        XCTAssertEqual(reader.retainedByteCount, 10)
        // Ending the stream inside the body fails the reader and releases its ten buffered bytes.
        XCTAssertThrowsError(try reader.finish())
        XCTAssertEqual(reader.retainedByteCount, 0)
        // Later input gets the same refusal, not a fresh frame.
        XCTAssertThrowsError(try reader.consume([0x0A])) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody)
        }
        XCTAssertEqual(reader.retainedByteCount, 0)
    }

    func testTruncatedFrameIsRefusedAtEndOfInput() throws {
        let reader = PrivateConfigurationFrameReader()
        _ = try reader.consume(Array("PCV1 Q 3\n{\"a".utf8))
        XCTAssertThrowsError(try reader.finish()) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody)
        }
    }

    func testReaderStopsAtTheFrameAndLeavesLaterBytes() throws {
        let frame = Array("PCV1 Q 2\n{}\n".utf8)
        let reader = PrivateConfigurationFrameReader()
        let input = frame + Array("LATER".utf8)
        let (step, consumed) = try reader.consume(input)
        XCTAssertEqual(consumed, frame.count)
        guard case .frame = step else {
            throw Failure(message: "expected a frame")
        }
        XCTAssertThrowsError(try reader.consume([0x41])) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidState)
        }
    }

    func testOneCallExaminesAtMostTheInputBudget() throws {
        let reader = PrivateConfigurationFrameReader()
        let input = Array("PCV1 Q 1000000\n".utf8) + Array(repeating: UInt8(ascii: " "), count: 100_000)
        let (step, consumed) = try reader.consume(input)
        guard case .needsInput = step else {
            throw Failure(message: "expected more input")
        }
        XCTAssertEqual(consumed, PrivateConfigurationFrame.maxInputBytesPerConsume)
    }

    /// A reset returns a reader to its first state, after a frame, after a failure and mid-body.
    func testResetReusesTheReaderAfterAFrameAndAfterAFailure() throws {
        let frame = Array("PCV1 Q 2\n{}\n".utf8)
        let reader = PrivateConfigurationFrameReader()
        _ = try reader.consume(frame)
        XCTAssertThrowsError(try reader.consume([0x41])) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidState)
        }
        reader.reset()
        let (step, consumed) = try reader.consume(frame)
        guard case .frame(let body) = step else {
            throw Failure(message: "expected a frame after reset")
        }
        XCTAssertEqual(body.bytes.bytes(), Array("{}".utf8))
        XCTAssertEqual(consumed, frame.count)

        reader.reset()
        _ = try reader.consume(Array("PCV1 Q 40\n".utf8) + Array(repeating: UInt8(ascii: "a"), count: 10))
        XCTAssertEqual(reader.retainedByteCount, 10)
        reader.reset()
        XCTAssertEqual(reader.retainedByteCount, 0)

        XCTAssertThrowsError(try reader.consume(Array("PCX".utf8))) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedHeader)
        }
        reader.reset()
        let (again, _) = try reader.consume(frame)
        guard case .frame = again else {
            throw Failure(message: "expected a frame after a failure and reset")
        }
    }

    // MARK: - Differential check against the reference parser

    /// Fixed counterexamples: each one names a refusal or a boundary the grammar fixes. A line feed
    /// inside the fixed prefix is a mismatch, classified by its position (`PCV\n` is a bad version,
    /// `PCV1 \n` is a bad kind), exactly as the reference does.
    func testReaderAgreesWithReferenceParserOnFixedCases() {
        let cases = [
            "PCV1 Q 2\n{}\n", "PCV1 Q 2\n{}\nLATER", "PCV1 Q 2\n{}X", "PCV1 Q 2\n{}", "PCV1 Q 2\n{}\n\n",
            "PCV1 Q 0\n", "PCV1 Q 05\n", "PCV1 Q \n", "PCV1 Q 5x\n", "PCV1 X 5\n", "PCV2 Q 5\n", "PCX1 Q 5\n",
            "PCV1 Q 8388593\n", "PCV1 Q 8388592\n", "PCV1 Q 9999999", "PCV1 Q 12345678\n", "PCV", "",
            "PCV1 Q 3\n{\"a", "PCV1 Q 3\n{\"a}\n",
            "PCV\n", "PCV1 \n", "PCV1 Q\n", "\n", "PC\n",
        ]
        for text in cases {
            assertReaderAgreesWithReference(Array(text.utf8), label: text)
        }
    }

    /// Seeded mutations of one valid frame: replaced, truncated, inserted and rewritten bytes, a
    /// rewritten length, and a second frame behind the first. The seed replays a failing case.
    func testReaderAgreesWithReferenceParserOnSeededMutations() throws {
        let base = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request(profileName: "seeded")).bytes()
        var generator = PrivateConfigSplitMix(state: 0xFA11)
        for caseNumber in 0..<200 {
            let input = mutate(base, &generator)
            let chunk = Int.random(in: 1...4_096, using: &generator)
            assertReaderAgreesWithReference(input, label: "case \(caseNumber)", chunks: [1, chunk, 16_384])
        }
    }

    // MARK: - Body refusals

    func testMalformedBodiesAreRefusedWithFixedErrors() throws {
        let valid = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request()).bytes()
        let body = Array(valid[(valid.firstIndex(of: 0x0A)! + 1)..<(valid.count - 1)])
        let text = String(decoding: body, as: UTF8.self)

        // Each mutation is a valid frame around an invalid body. A duplicate key, a key the schema
        // does not name, a missing key, a bad enum, an out-of-range port, a fraction where an
        // integer belongs, and null for a required integer are all refused.
        try assertBodyRefusal(text.replacingOccurrences(of: "\"strictMode\":true", with: "\"strictMode\":true,\"strictMode\":false"))
        try assertBodyRefusal(text.replacingOccurrences(of: "\"strictMode\":true", with: "\"strictMode\":true,\"extra\":1"))
        try assertBodyRefusal(text.replacingOccurrences(of: ",\"strictMode\":true", with: ""))
        try assertBodyRefusal(text.replacingOccurrences(of: "\"systemNegotiated\"", with: "\"kerberos\""))
        try assertBodyRefusal(text.replacingOccurrences(of: "\"port\":3128", with: "\"port\":70000"))
        try assertBodyRefusal(text.replacingOccurrences(of: "\"port\":3128", with: "\"port\":3128.5"))
        try assertBodyRefusal(text.replacingOccurrences(of: "\"maxConnections\":5000", with: "\"maxConnections\":null"))
        // A lone high or low surrogate in a URL is refused, never replaced with U+FFFD.
        try assertBodyRefusal(text.replacingOccurrences(of: "PAC-TOKEN-7", with: "\\uD800"))
        try assertBodyRefusal(text.replacingOccurrences(of: "PAC-TOKEN-7", with: "\\uDC00"))
        // Bytes that are not UTF-8 are refused. The mutation is done on bytes, because a Swift
        // String always encodes as valid UTF-8.
        try assertBodyRefusal(bytes: bytesReplacing(Array(text.utf8), "PAC-TOKEN-7", [0xFF, 0xFE]))
    }

    func testUnknownNestedKeyAndTrailingGarbageAreRefused() throws {
        let valid = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request()).bytes()
        let body = Array(valid[(valid.firstIndex(of: 0x0A)! + 1)..<(valid.count - 1)])
        let text = String(decoding: body, as: UTF8.self)
        // Trailing whitespace is valid JSON; a trailing token is not.
        try assertBodyRefusal(text + "x")
        try assertBodyRefusal(text.replacingOccurrences(of: "\"workstation\":\"w\"", with: "\"workstation\":\"w\",\"x\":{}"))
    }

    // MARK: - Escapes and representability

    func testEscapedBytesAreWrittenAndReadBack() throws {
        let name = "quote\" back\\ ctl\u{01} tab\t nl\n emoji🙂 ünï"
        let frame = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request(profileName: name))
        let text = String(decoding: frame.bytes(), as: UTF8.self)
        XCTAssertTrue(text.contains("\\\""))
        XCTAssertTrue(text.contains("\\\\"))
        XCTAssertTrue(text.contains("\\u0001"))
        XCTAssertTrue(text.contains("🙂"))
        let decoded = try PrivateConfigurationDecoder.decode(readFrame(frame.bytes(), chunkSize: 97))
        XCTAssertEqual(decoded.runtime.profileName, name)
    }

    func testNonFiniteNumbersAndOutOfRangePortsAreRefusedByTheWriter() throws {
        var request = try PrivateConfigSamples.request()
        request.runtime.health.checkIntervalSeconds = .infinity
        XCTAssertThrowsError(try PrivateConfigurationEncoder.encode(request)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidValue)
        }
        request = try PrivateConfigSamples.request()
        request.runtime.proxy.port = 70_000
        XCTAssertThrowsError(try PrivateConfigurationEncoder.encode(request)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .invalidValue)
        }
    }

    /// `measureBody` is the count pass alone. It must agree with the frame the encoder builds.
    func testMeasuredBodyCountMatchesTheEncodedFrame() throws {
        let request = try PrivateConfigSamples.request(profileName: "measured \"🙂\"\n")
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        let declared = try Self.declaredBodyLength(frame)
        XCTAssertEqual(try PrivateConfigurationEncoder.measureBody(request), declared)
    }

    func testPortZeroIsRepresentable() throws {
        var request = try PrivateConfigSamples.request()
        request.runtime.proxy.port = 0
        request.runtime.dns.forwarderPort = 0
        let frame = try PrivateConfigurationEncoder.encode(request)
        let decoded = try PrivateConfigurationDecoder.decode(readFrame(frame.bytes(), chunkSize: 4_096))
        XCTAssertEqual(decoded, request)
    }

    // MARK: - Redaction and no generic coding

    func testURLPlaintextAbsentFromEveryReflectionPath() throws {
        let token = "PAC-TOKEN-7"
        let request = try PrivateConfigSamples.request()
        let url = request.runtime.routing.pacURL
        XCTAssertFalse(String(describing: url).contains(token))
        XCTAssertFalse(String(reflecting: url).contains(token))
        XCTAssertFalse(String(describing: request).contains(token))
        XCTAssertFalse(String(reflecting: request).contains(token))
        XCTAssertFalse(String(describing: request.runtime).contains(token))
        XCTAssertFalse("\(request)".contains(token))
        XCTAssertFalse(String(describing: Mirror(reflecting: url).children.map { "\($0.value)" }).contains(token))
        XCTAssertFalse(String(describing: Mirror(reflecting: request).children.map { "\($0.value)" }).contains(token))
        XCTAssertTrue(String(describing: url).contains("redacted"))
        // The private values are not Encodable, so a dynamic cast cannot reach a generic encoder.
        XCTAssertNil(request as Any as? any Encodable)
        XCTAssertNil(request.runtime as Any as? any Decodable)
        XCTAssertNil(url as Any as? any Encodable)
        XCTAssertNil(request.platform as Any as? any Encodable)
    }

    func testFrameBodyDoesNotPrintItsBytes() throws {
        let frame = try PrivateConfigurationEncoder.encode(PrivateConfigSamples.request())
        let body = PrivateConfigurationFrameBody(bytes: frame)
        XCTAssertFalse(String(describing: body).contains("PCV1"))
        XCTAssertFalse(String(reflecting: body).contains("{"))
    }

    // MARK: - Helpers

    private func assertHeaderRefusal(_ header: String, _ expected: PrivateConfigurationWireError) throws {
        let reader = PrivateConfigurationFrameReader()
        XCTAssertThrowsError(try reader.consume(Array(header.utf8)), header) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, expected, header)
        }
        XCTAssertEqual(reader.retainedByteCount, 0, header)
    }

    /// Builds a frame around `body` with an independent header, then checks the decoder refuses it.
    private func assertBodyRefusal(_ text: String) throws {
        try assertBodyRefusal(bytes: Array(text.utf8))
    }

    private func assertBodyRefusal(bytes body: [UInt8]) throws {
        let framed = Array("PCV1 Q \(body.count)\n".utf8) + body + [0x0A]
        let reader = PrivateConfigurationFrameReader()
        let (step, _) = try reader.consume(framed)
        guard case .frame(let frameBody) = step else {
            throw Failure(message: "the reference frame did not complete")
        }
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decode(frameBody)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody)
        }
    }

    /// Runs the reader over `input` in pieces of each size in `chunks`, and requires the reader's
    /// outcome to equal the reference parser's outcome for the same bytes.
    private func assertReaderAgreesWithReference(
        _ input: [UInt8],
        label: String,
        chunks: [Int]? = nil,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let expected = endOfStreamOutcome(ReferenceFrameParser.parse(input))
        for chunk in chunks ?? [1, 3, 7, 16, 4_096, 16_384, max(input.count, 1)] {
            XCTAssertEqual(
                runReader(input, chunk: chunk), expected,
                "\(label), chunk \(chunk)", file: file, line: line
            )
        }
    }

    /// A stream that ends without a frame is an error for the reader: `finish` refuses it.
    private func endOfStreamOutcome(_ outcome: FrameOutcome) -> FrameOutcome {
        outcome == .open ? .refused(.malformedBody) : outcome
    }

    /// What the production reader says about `input` read in pieces of `chunk`, including `finish`.
    private func runReader(_ input: [UInt8], chunk: Int) -> FrameOutcome {
        let reader = PrivateConfigurationFrameReader()
        var offset = 0
        while offset < input.count {
            let end = min(offset + chunk, input.count)
            do {
                let (step, consumed) = try reader.consume(input[offset..<end])
                offset += consumed
                if case .frame(let body) = step {
                    return .frame(body: body.bytes.bytes(), consumed: offset)
                }
            } catch let error as PrivateConfigurationWireError {
                return .refused(error)
            } catch {
                return .refused(.malformedBody)
            }
        }
        do {
            try reader.finish()
        } catch let error as PrivateConfigurationWireError {
            return .refused(error)
        } catch {
            return .refused(.malformedBody)
        }
        return .open
    }

    /// One seeded mutation of `base`. Each kind keeps the input bounded, since `base` is one small frame.
    private func mutate(_ base: [UInt8], _ generator: inout PrivateConfigSplitMix) -> [UInt8] {
        var bytes = base
        switch Int.random(in: 0..<6, using: &generator) {
        case 0:
            bytes[Int.random(in: 0..<bytes.count, using: &generator)] = UInt8.random(in: 0...255, using: &generator)
        case 1:
            bytes = Array(bytes.prefix(Int.random(in: 0...bytes.count, using: &generator)))
        case 2:
            bytes.insert(
                UInt8.random(in: 0...255, using: &generator),
                at: Int.random(in: 0...bytes.count, using: &generator)
            )
        case 3:
            let digits = Array(String(Int.random(in: 0...9_999_999, using: &generator)).utf8)
            let lineFeed = bytes.firstIndex(of: 0x0A) ?? bytes.count
            bytes = Array("PCV1 Q ".utf8) + digits + Array(bytes[lineFeed...])
        case 4:
            bytes[Int.random(in: 0..<7, using: &generator)] = UInt8.random(in: 0x20...0x7E, using: &generator)
        default:
            bytes += base
        }
        return bytes
    }

    private func bytesReplacing(_ bytes: [UInt8], _ needle: String, _ replacement: [UInt8]) -> [UInt8] {
        let pattern = Array(needle.utf8)
        var out: [UInt8] = []
        var index = 0
        while index < bytes.count {
            if index + pattern.count <= bytes.count, Array(bytes[index..<(index + pattern.count)]) == pattern {
                out += replacement
                index += pattern.count
            } else {
                out.append(bytes[index])
                index += 1
            }
        }
        return out
    }

    /// The body length a frame's header declares.
    private static func declaredBodyLength(_ bytes: [UInt8]) throws -> Int {
        let lineFeed = try XCTUnwrap(bytes.firstIndex(of: 0x0A))
        let header = String(decoding: bytes[..<lineFeed], as: UTF8.self)
        return try XCTUnwrap(Int(header.dropFirst("PCV1 Q ".count)))
    }

    /// Reads one frame from `bytes` in pieces of `chunkSize`, and returns its body.
    private func readFrame(_ bytes: [UInt8], chunkSize: Int) throws -> PrivateConfigurationFrameBody {
        let reader = PrivateConfigurationFrameReader()
        var offset = 0
        while offset < bytes.count {
            let end = min(offset + chunkSize, bytes.count)
            let (step, consumed) = try reader.consume(bytes[offset..<end])
            offset += consumed
            if case .frame(let body) = step {
                guard offset == bytes.count else {
                    throw Failure(message: "bytes followed the frame")
                }
                return body
            }
        }
        throw Failure(message: "the input ended inside the frame")
    }
}

/// What a frame reader must say about a byte stream: a frame and the count of bytes it used, a
/// refusal, or that the stream is still open.
enum FrameOutcome: Equatable {
    case frame(body: [UInt8], consumed: Int)
    case refused(PrivateConfigurationWireError)
    case open
}

/// An independent reference for the frame grammar of decision 0019. It reads the whole byte string
/// at once, from the header description, and uses none of the codec's constants or helpers. The cap
/// is written out here as a literal. The reader's 16 KiB read budget is not modelled, because it
/// changes when bytes are read and never what they mean.
enum ReferenceFrameParser {
    static func parse(_ input: [UInt8]) -> FrameOutcome {
        let cap = 8_388_608
        let prefix = Array("PCV1 Q ".utf8)
        var index = 0
        for expected in prefix {
            guard index < input.count else { return .open }
            guard input[index] == expected else {
                switch index {
                case 3: return .refused(.unsupportedVersion)
                case 5: return .refused(.unknownFrameKind)
                default: return .refused(.malformedHeader)
                }
            }
            index += 1
        }
        var length = 0
        var digits = 0
        while true {
            guard index < input.count else { return .open }
            let byte = input[index]
            if byte == 0x0A { break }
            guard byte >= 0x30, byte <= 0x39 else { return .refused(.malformedHeader) }
            guard digits > 0 || byte != 0x30 else { return .refused(.malformedHeader) }
            guard digits < 7 else { return .refused(.frameTooLarge) }
            length = length * 10 + Int(byte - 0x30)
            digits += 1
            guard length <= cap else { return .refused(.frameTooLarge) }
            index += 1
        }
        guard digits > 0, length > 0 else { return .refused(.malformedHeader) }
        // The header is the prefix, the digits and its line feed. The frame adds the body and a terminator.
        guard prefix.count + digits + 1 + length + 1 <= cap else { return .refused(.frameTooLarge) }
        let bodyStart = index + 1
        let terminator = bodyStart + length
        guard terminator < input.count else { return .open }
        guard input[terminator] == 0x0A else { return .refused(.malformedBody) }
        return .frame(body: Array(input[bodyStart..<terminator]), consumed: terminator + 1)
    }
}

/// A deterministic generator, so a failing segmentation can be replayed.
struct PrivateConfigSplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var mixed = state
        mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
        mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
        return mixed ^ (mixed >> 31)
    }
}

extension SecretBytes {
    /// Test-only copy of the bytes, so the test can inspect the frame.
    func bytes() -> [UInt8] {
        withUnsafeBytes { Array($0) }
    }
}

/// Canonical sample values shared by the private configuration tests.
enum PrivateConfigSamples {
    static func uuid(_ number: Int) -> UUID {
        UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", number))!
    }

    static func request(
        profileName: String = "sample",
        pacURL: String = "https://pac.example.test/p.pac?token=PAC-TOKEN-7"
    ) throws -> PrivateConfigurationRequest {
        PrivateConfigurationRequest(
            requestID: ControlRequestID(rawValue: uuid(1)),
            incarnation: ControlHostIncarnation(rawValue: uuid(2)),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 4)),
            expectedPlatformRevision: try XCTUnwrap(PrivatePlatformRevision(rawValue: 3)),
            expectedOwnerGeneration: try XCTUnwrap(PrivateConfigExpectedGeneration(rawValue: 9)),
            runtime: runtime(profileName: profileName, pacURL: pacURL),
            platform: PrivatePlatformConfiguration(
                manageSystemProxy: true, manageEnvironmentVariables: false, manageDNSResolvers: false,
                manageSystemDNS: true, systemProxyMode: .pac
            )
        )
    }

    static func runtime(profileName: String, pacURL: String) -> PrivateRuntimeConfiguration {
        PrivateRuntimeConfiguration(
            profileName: profileName,
            proxy: PrivateProxySettings(
                host: "127.0.0.1", port: 3128, socksEnabled: false, socksPort: 1080, gatewayMode: false,
                allowedClients: ["127.0.0.1", "::1"], maxConnections: 5_000,
                stalledConnectionTimeoutSeconds: 45, maxBufferedBodyBytes: 16_777_216,
                maxSpooledBodyBytes: 268_435_456, inboundConnectionWarnThreshold: 1_000,
                inboundConnectionMaxLimit: 10_000, strictMode: true
            ),
            auth: PrivateAuthSettings(
                mode: .systemNegotiated, username: "u", domain: "", workstation: "w",
                pendingHandshakeGlobalLimit: 512, pendingHandshakesPerSource: 128
            ),
            upstreams: [
                PrivateUpstreamSettings(
                    id: ControlUpstreamID(rawValue: uuid(10)), name: "a", host: "proxy-a.example.test",
                    port: 8_080, enabled: true, priority: 0
                ),
            ],
            routing: PrivateRoutingSettings(
                pacURL: PrivateURLValue(pacURL), localPACEnabled: false, localPACPort: 63_145,
                pacRoutingEnabled: true, pacUsableRouteLimit: 32, noProxyHosts: ["localhost"], forceProxyHosts: []
            ),
            dns: PrivateDNSSettings(
                forwarderEnabled: false, forwarderPort: 5_053,
                dohProviders: [PrivateURLValue("https://1.1.1.1/dns-query")], entries: [], interceptRules: [],
                transparentProxyEnabled: false, transparentProxyIP: "127.44.3.0", transparentProxyPort: 10_443
            ),
            tunnels: PrivateTunnelSettings(definitions: [], maxSessions: 128, maxSessionsPerTunnel: 32),
            health: PrivateHealthSettings(
                checkURL: PrivateURLValue("http://detectportal.firefox.com/success.txt"),
                checkIntervalSeconds: 30, connectionCheckTimeoutSeconds: 2, upstreamResponseTimeoutSeconds: 45,
                upstreamConnectTimeoutSeconds: 5, directConnectTTLSeconds: 300, circuitBreakerWindowSeconds: 10,
                circuitFailureThreshold: 5, circuitBaseOpenIntervalSeconds: 30, circuitMaxOpenIntervalSeconds: 300,
                vpnFlapGraceSeconds: 5, vpnFlapMinVisibleSeconds: 1
            ),
            logging: PrivateLoggingSettings(verbose: false, auditLogEnabled: false, auditLogMaxBytes: 10_485_760, auditLogPath: nil)
        )
    }
}
