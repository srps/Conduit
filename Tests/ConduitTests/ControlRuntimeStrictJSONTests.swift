// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared

/// The v2 codec's strict JSON boundary. A known frame is refused when any byte of it, including an unknown or
/// ignored value, breaks the JSON grammar, the UTF-8 rules or the escape rules. A valid unknown extension is kept
/// legal. Each fixture is written as exact bytes, so the escape text is never lost to a tool's Unicode handling.
final class ControlRuntimeStrictJSONTests: XCTestCase {
    private let limits = try! ControlFrameLimits(maxFrameBytes: 64 * 1024)
    private let correlation = ControlRequestID(rawValue: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)

    private var base: ControlRuntimeMessage {
        ControlRuntimeMessage(correlation: correlation, body: .request(.readSnapshot))
    }

    /// The valid payload of a read-snapshot request with one unknown top-level field. `value` is the field's
    /// raw JSON text, exactly as given.
    private func payload(extension value: [UInt8]) throws -> Data {
        var bytes = try ControlRuntimeCodec.encodeBoundedPayload(base, limits: limits)
        XCTAssertEqual(bytes.last, 0x7D, "the encoded payload ends in a closing brace")
        bytes.removeLast()
        bytes.append(contentsOf: Array(",\"x-extension\":".utf8))
        bytes.append(contentsOf: value)
        bytes.append(0x7D)
        return bytes
    }

    private func assertMalformed(_ payload: Data, _ label: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(payload, limits: limits), label, file: file, line: line) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .malformedMessage, label, file: file, line: line)
        }
    }

    /// Values an ignored field must not carry: bad escapes, lone surrogates, raw controls, bad UTF-8, bad numbers.
    private let malformedValues: [(label: String, value: [UInt8])] = [
        ("lone high surrogate", Array("\"\\ud800\"".utf8)),
        ("lone low surrogate", Array("\"\\udc00\"".utf8)),
        ("high surrogate before a non-surrogate escape", Array("\"\\ud800\\u0041\"".utf8)),
        ("high surrogate before a literal character", Array("\"\\ud800x\"".utf8)),
        ("unknown escape letter", Array("\"\\x41\"".utf8)),
        ("short unicode escape", Array("\"\\u12\"".utf8)),
        ("raw control character", [0x22, 0x09, 0x22]),
        ("invalid UTF-8 byte", [0x22, 0xFF, 0x22]),
        ("overlong UTF-8", [0x22, 0xC0, 0xAF, 0x22]),
        ("UTF-8 encoded surrogate", [0x22, 0xED, 0xA0, 0x80, 0x22]),
        ("truncated UTF-8 sequence", [0x22, 0xE2, 0x82, 0x22]),
        ("unterminated string", Array("\"abc".utf8)),
        ("leading zero number", Array("01".utf8)),
        ("number with no fraction digit", Array("1.".utf8)),
        ("misspelled literal", Array("tru".utf8)),
        ("trailing comma in array", Array("[1,]".utf8)),
        ("malformed string nested in an object", Array("{\"a\":\"\\ud800\"}".utf8)),
    ]

    /// Valid unknown values, including the large exponent that must be skipped without a Double conversion.
    private let validValues: [(label: String, value: [UInt8])] = [
        ("escaped ASCII and BMP", Array("\"\\u0041\\u00e9\"".utf8)),
        ("escaped surrogate pair", Array("\"\\ud83d\\ude00\"".utf8)),
        // "\/\b\f\n\r\t\\\"" as bytes: every simple escape, written out so no quoting layer can change it.
        ("every simple escape", [0x22, 0x5C, 0x2F, 0x5C, 0x62, 0x5C, 0x66, 0x5C, 0x6E, 0x5C, 0x72, 0x5C, 0x74,
                                 0x5C, 0x5C, 0x5C, 0x22, 0x22]),
        ("raw UTF-8 text", Array("\"\u{e9}\u{1F600}\"".utf8)),
        ("huge exponent", Array("1e400".utf8)),
        ("signed exponent", Array("-1E+2".utf8)),
        ("negative fraction", Array("-0.5e-3".utf8)),
        ("nested containers", Array("[1,true,false,null,{\"deep\":[[]]}]".utf8)),
        ("empty object", Array("{}".utf8)),
    ]

    // MARK: - Malformed ignored values refuse the whole frame

    func testAMalformedValueInAnUnknownFieldRefusesAKnownFrame() throws {
        for (label, value) in malformedValues {
            assertMalformed(try payload(extension: value), label)
        }
    }

    // MARK: - Valid unknown extensions stay legal

    func testAValidUnknownExtensionKeepsTheKnownFrameLegalAndDecodesToItsMessage() throws {
        for (label, value) in validValues {
            let decoded = try ControlRuntimeCodec.decodeFrame(try payload(extension: value), limits: limits)
            XCTAssertEqual(decoded, base, label)
        }
    }

    // MARK: - Actual bytes

    func testTheEscapeFixturesAreTheExactEscapeBytes() {
        XCTAssertEqual(Array("\"\\ud800\"".utf8), [0x22, 0x5C, 0x75, 0x64, 0x38, 0x30, 0x30, 0x22])
        XCTAssertEqual(Array("\"\\udc00\"".utf8), [0x22, 0x5C, 0x75, 0x64, 0x63, 0x30, 0x30, 0x22])
        XCTAssertEqual(Array("\"\\ud83d\\ude00\"".utf8).count, 14)
    }

    func testTheExtensionFixtureCarriesTheEscapeBytesThroughToTheFrame() throws {
        let frame = try payload(extension: Array("\"\\ud800\"".utf8))
        let escape: [UInt8] = [0x5C, 0x75, 0x64, 0x38, 0x30, 0x30]
        let found = frame.firstRange(of: escape)
        XCTAssertNotNil(found, "the escape text reaches the payload as written, not as a decoded scalar")
    }

    // MARK: - Priority is unchanged

    func testAnUnknownKindWithAMalformedExtensionIsStillAnUnknownCommand() {
        let text = "{\"body\":{\"type\":\"readSnapshot\"},\"correlation\":\"00000000-0000-0000-0000-000000000001\","
            + "\"kind\":\"bogus\",\"version\":2,\"x-extension\":\"\\ud800\"}"
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(Data(text.utf8), limits: limits)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .unknownCommand, "the kind is classified before any strict check")
        }
    }

    func testAnOversizeFrameWithAMalformedExtensionIsRefusedAsOversizeFirst() throws {
        let tiny = try ControlFrameLimits(maxFrameBytes: 64)
        let malformed = try payload(extension: Array("\"\\ud800\"".utf8))
        XCTAssertThrowsError(try ControlRuntimeCodec.decodeFrame(malformed, limits: tiny)) { error in
            XCTAssertEqual(error as? ControlRuntimeWireError, .frameTooLarge, "size is checked before anything parses")
        }
    }
}
