// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// Grammar agreement between the private scanner and `JSONSerialization`, on full schema-shaped bodies.
///
/// Every body goes through `PrivateConfigurationDecoder.decode`, so the scanner's real code runs. The bodies are
/// the encoder's own output for the sample, changed by byte-level edits: one value replaced, whitespace inserted,
/// members reordered by a fixed seed. Agreement is asserted where both accept and the values match.
///
/// The scanner is stricter on purpose in the cases below, and those refusals are not weakened to match
/// Foundation: duplicate keys (Foundation keeps one), unknown keys (Foundation ignores them), raw control bytes,
/// lone or mismatched surrogate escapes, invalid UTF-8, non-JSON whitespace, and any value past its ceiling.
/// The depth bound is structural: the schema reaches at most depth five through known keys, and an unknown key is
/// refused by name before its value, so a deep unknown structure is never read. This is a bounded set of explicit
/// and seeded variants. It is not an exhaustive proof of the grammar.
final class PrivateConfigGrammarDifferentialTests: XCTestCase {
    private let quote = UInt8(ascii: "\"")
    private let backslash = UInt8(ascii: "\\")

    // MARK: - Numbers

    /// Finite Double lexemes in a Double field agree with Foundation's value and with the scanner's decoded value.
    /// The expected values come from Swift's own `Double(String)`, which is independent of both parsers.
    func testValidDoubleLexemesAgreeWithJSONSerializationAndTheScanner() throws {
        let canonical = try canonicalBody()
        XCTAssertTrue(foundationAccepts(canonical))
        let cases: [(lexeme: String, value: Double)] = [
            ("0", 0), ("-0", -0.0), ("0.0", 0), ("2", 2), ("2.5", 2.5), ("2.50", 2.5), ("2e1", 20), ("2E+1", 20),
            ("2e-1", 0.2), ("1.5e3", 1_500), ("-1.25E-2", -0.0125), ("0.1", 0.1), ("1e300", 1e300),
            ("4.9e-324", 4.9e-324), ("123456789.123456789", 123_456_789.123_456_789),
        ]
        for (lexeme, value) in cases {
            XCTAssertEqual(Double(lexeme), value, "the expected value must parse: \(lexeme)")
            let body = try replacing("vpnFlapGraceSeconds", with: lexeme, in: canonical)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
            let health = try XCTUnwrap((object["runtime"] as? [String: Any])?["health"] as? [String: Any])
            XCTAssertEqual(health["vpnFlapGraceSeconds"] as? Double, value, "Foundation: \(lexeme)")
            do {
                let decoded = try decode(body)
                XCTAssertEqual(decoded.runtime.health.vpnFlapGraceSeconds, value, "scanner: \(lexeme)")
            } catch {
                XCTFail("scanner refused \(lexeme): \(error)")
            }
        }
    }

    /// Malformed JSON numbers are refused by the scanner, and Foundation refuses them too.
    func testMalformedNumericLexemesAreRefusedByBothParsers() throws {
        let canonical = try canonicalBody()
        let lexemes = [
            "01", "00", "1.", ".5", "-.5", "+1", "1e", "1e+", "1e-", "-", "--1", "1.2.3", "NaN", "Infinity",
            "-Infinity", "0x1F", "1_000", "1 2", "1e5.5", "1,5", "\u{0661}",
        ]
        for lexeme in lexemes {
            let body = try replacing("vpnFlapGraceSeconds", with: lexeme, in: canonical)
            XCTAssertEqual(refusal(body), .malformedBody, "scanner: \(lexeme)")
            XCTAssertFalse(foundationAccepts(body), "Foundation: \(lexeme)")
        }
    }

    /// Lexemes that overflow Double are refused by the decoder's finite check as malformed. Foundation's verdict is
    /// not asserted here.
    func testOverflowingDoubleLexemesAreRefusedAsMalformed() throws {
        let canonical = try canonicalBody()
        for lexeme in ["1e400", "-1e400"] {
            let body = try replacing("vpnFlapGraceSeconds", with: lexeme, in: canonical)
            XCTAssertEqual(refusal(body), .malformedBody, lexeme)
        }
    }

    /// An integral-valued fraction in an Int field (`5000.0`) keeps its value and is accepted, as it is today. A
    /// non-integral one (`5000.5`) is refused. This pins existing behavior and does not endorse the spelling.
    func testIntegralFractionalSpellingInAnIntFieldKeepsItsValue() throws {
        let canonical = try canonicalBody()
        let integral = try replacing("maxConnections", with: "5000.0", in: canonical)
        XCTAssertTrue(foundationAccepts(integral))
        XCTAssertEqual(try decode(integral).runtime.proxy.maxConnections, 5_000)
        let fractional = try replacing("maxConnections", with: "5000.5", in: canonical)
        XCTAssertEqual(refusal(fractional), .malformedBody)
    }

    // MARK: - Strings

    /// Raw and escaped valid strings, including surrogate pairs, the short escapes, controls, DEL, and U+2028/2029,
    /// agree with Foundation's string and with the scanner's decoded value.
    func testRawAndEscapedValidStringsAgreeWithJSONSerializationAndTheScanner() throws {
        let canonical = try canonicalBody()
        let cases: [(literal: String, value: String)] = [
            (#""sample""#, "sample"),
            (#""sample""#, "sample"),
            ("\"héllo €🙂\"", "héllo €🙂"),
            (#""héllo €🙂""#, "héllo €🙂"),
            (#""\"\\\/\b\f\n\r\t""#, "\"\\/\u{08}\u{0C}\n\r\t"),
            (#""\u0000\u0001\u001f\u007f""#, "\u{0}\u{1}\u{1F}\u{7F}"),
            ("\"\u{2028}\u{2029}\"", "\u{2028}\u{2029}"),
            (#""  ""#, "\u{2028}\u{2029}"),
            (#""a b""#, "a b"),
        ]
        for (literal, value) in cases {
            let body = try replacing("profileName", with: literal, in: canonical)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(body)) as? [String: Any])
            let runtime = try XCTUnwrap(object["runtime"] as? [String: Any])
            XCTAssertEqual(runtime["profileName"] as? String, value, "Foundation: \(literal)")
            do {
                let decoded = try decode(body)
                XCTAssertEqual(decoded.runtime.profileName, value, "scanner: \(literal)")
            } catch {
                XCTFail("scanner refused \(literal): \(error)")
            }
        }
    }

    /// Bytes a JSON string may not carry raw, lone or mismatched surrogates, and invalid UTF-8 are refused by the
    /// scanner. These are intentional refusals. Foundation's verdict is not asserted for them.
    func testRawControlsSurrogatesAndInvalidUTF8AreRefusedByTheScanner() throws {
        let canonical = try canonicalBody()
        let invalid: [(name: String, bytes: [UInt8])] = [
            ("raw NUL", [0x22, 0x00, 0x22]),
            ("raw unit separator", [0x22, 0x1F, 0x22]),
            ("raw tab", [0x22, 0x09, 0x22]),
            ("lone high surrogate", Array(#""\ud83d""#.utf8)),
            ("lone low surrogate", Array(#""\ude42""#.utf8)),
            ("high surrogate then non-low", Array(#""\ud83dA""#.utf8)),
            ("invalid UTF-8 byte", [0x22, 0xFF, 0x22]),
            ("overlong slash", [0x22, 0xC0, 0xAF, 0x22]),
            ("encoded surrogate", [0x22, 0xED, 0xA0, 0x80, 0x22]),
            ("truncated three-byte sequence", [0x22, 0xE2, 0x82, 0x22]),
        ]
        for (name, bytes) in invalid {
            let body = try replacing("profileName", withBytes: bytes, in: canonical)
            XCTAssertEqual(refusal(body), .malformedBody, name)
        }
    }

    // MARK: - Whitespace and member order

    /// JSON whitespace (space, tab, line feed, carriage return) between any tokens, and around the whole body,
    /// agrees with Foundation and re-encodes to the canonical body. Vertical tab and form feed are not JSON
    /// whitespace, and the scanner refuses them.
    func testWhitespaceVariantsAgreeAndNonJSONWhitespaceIsRefused() throws {
        let canonical = try canonicalBody()
        let separators: [[UInt8]] = [[0x20], [0x09], [0x0A], [0x0D, 0x0A], [0x20, 0x0D, 0x0A, 0x09, 0x20]]
        for separator in separators {
            let body = spaced(canonical, separator: separator)
            XCTAssertNotEqual(body, canonical)
            try assertAgreement(body, "separator \(separator)")
            try assertAgreement([0x20, 0x0A] + body + [0x0D, 0x0A, 0x09], "framed separator \(separator)")
        }
        for byte: UInt8 in [0x0B, 0x0C] {
            XCTAssertEqual(refusal(spaced(canonical, separator: [byte])), .malformedBody, "byte \(byte)")
        }
    }

    /// Member order is free in both parsers. Each seed reorders every object's members, and every other seed also
    /// changes the whitespace. The fixed seeds keep the set bounded and repeatable.
    func testSeededMemberOrderAgreesWithJSONSerializationAndTheScanner() throws {
        let canonical = try canonicalBody()
        var changed = 0
        for seed in UInt64(1)...24 {
            var generator = SplitMix64(state: seed)
            let reordered = shuffled(canonical[...], &generator)
            if reordered != canonical {
                changed += 1
            }
            try assertAgreement(reordered, "seed \(seed)")
            let separator: [UInt8] = seed.isMultiple(of: 2) ? [0x0A, 0x09] : [0x20]
            try assertAgreement(spaced(reordered, separator: separator), "seed \(seed) with whitespace")
        }
        XCTAssertGreaterThan(changed, 0, "the seeds must actually reorder the members")
    }

    // MARK: - Intentional refusals

    /// Duplicate keys, unknown keys, and a value past its ceiling are refused by the scanner, where Foundation
    /// accepts the same bytes. A within-ceiling value of the same field still agrees with Foundation.
    func testDuplicateUnknownAndOverResourceAreRefusedWhereFoundationAccepts() throws {
        let canonical = try canonicalBody()
        let duplicate = try replacing("profileName", with: #""sample","profileName":"sample""#, in: canonical)
        let escapedDuplicate = try replacing("profileName", with: #""sample","profileName":"sample""#, in: canonical)
        let unknown = try replacing("profileName", with: #""sample","zz":[1,{"a":null}]"#, in: canonical)
        let over = try replacing(
            "profileName", with: "\"" + String(repeating: "a", count: 1_025) + "\"", in: canonical
        )
        for body in [duplicate, escapedDuplicate, unknown, over] {
            XCTAssertTrue(foundationAccepts(body))
        }
        XCTAssertEqual(refusal(duplicate), .malformedBody, "duplicate")
        XCTAssertEqual(refusal(escapedDuplicate), .malformedBody, "escaped duplicate")
        XCTAssertEqual(refusal(unknown), .malformedBody, "unknown key")
        XCTAssertEqual(refusal(over), .resourceLimitExceeded(DomainResourceViolation(.profileName, 1_024)), "over ceiling")

        let within = try replacing(
            "profileName", with: "\"" + String(repeating: "a", count: 1_024) + "\"", in: canonical
        )
        XCTAssertTrue(foundationAccepts(within))
        XCTAssertEqual(try decode(within).runtime.profileName.utf8.count, 1_024)
    }

    // MARK: - Helpers

    /// The encoder's body for the sample: compact, fixed field order, and every schema key present.
    private func canonicalBody() throws -> [UInt8] {
        try body(of: PrivateConfigurationEncoder.encode(PrivateConfigSamples.request()).bytes())
    }

    private func encodedBody(_ request: PrivateConfigurationRequest) throws -> [UInt8] {
        try body(of: PrivateConfigurationEncoder.encode(request).bytes())
    }

    /// The bytes after the header's line feed, without the terminator.
    private func body(of frame: [UInt8]) throws -> [UInt8] {
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        return Array(frame[start..<(frame.count - 1)])
    }

    private func decode(_ body: [UInt8]) throws -> PrivateConfigurationRequest {
        try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(kind: .update, bytes: SecretBytes(body)))
    }

    /// The scanner's refusal, or nil when the body decodes.
    private func refusal(_ body: [UInt8]) -> PrivateConfigurationWireError? {
        do {
            _ = try decode(body)
            return nil
        } catch {
            return error as? PrivateConfigurationWireError
        }
    }

    private func foundationAccepts(_ body: [UInt8]) -> Bool {
        (try? JSONSerialization.jsonObject(with: Data(body))) != nil
    }

    /// Both parsers accept the body, the scanner's decode re-encodes to the canonical body, and so the decoded
    /// values equal the sample's values.
    private func assertAgreement(_ body: [UInt8], _ label: String) throws {
        XCTAssertTrue(foundationAccepts(body), "Foundation refuses \(label)")
        do {
            let decoded = try decode(body)
            XCTAssertEqual(try encodedBody(decoded), try canonicalBody(), label)
        } catch {
            XCTFail("scanner refused \(label): \(error)")
        }
    }

    /// The first occurrence of `needle`, or nil.
    private func find(_ needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard needle.count <= haystack.count else {
            return nil
        }
        for start in 0...(haystack.count - needle.count) where haystack[start..<(start + needle.count)].elementsEqual(needle) {
            return start
        }
        return nil
    }

    /// The byte range of the value under `key`. A string runs through its closing quote. A scalar runs up to the
    /// next `,`, `}` or `]`. The canonical body is compact, so this is exact for it.
    private func valueRange(_ key: String, in body: [UInt8]) throws -> Range<Int> {
        let marker = Array("\"\(key)\":".utf8)
        let start = try XCTUnwrap(find(marker, in: body)) + marker.count
        var end = start
        if body[start] == quote {
            end += 1
            while body[end] != quote {
                if body[end] == backslash {
                    end += 2
                } else {
                    end += 1
                }
            }
            end += 1
        } else {
            let structural: [UInt8] = [UInt8(ascii: ","), UInt8(ascii: "}"), UInt8(ascii: "]")]
            while !structural.contains(body[end]) {
                end += 1
            }
        }
        return start..<end
    }

    private func replacing(_ key: String, with literal: String, in body: [UInt8]) throws -> [UInt8] {
        try replacing(key, withBytes: Array(literal.utf8), in: body)
    }

    private func replacing(_ key: String, withBytes bytes: [UInt8], in body: [UInt8]) throws -> [UInt8] {
        var copy = body
        copy.replaceSubrange(try valueRange(key, in: body), with: bytes)
        return copy
    }

    /// Inserts `separator` around each structural byte outside a string. Only whitespace is added.
    private func spaced(_ body: [UInt8], separator: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        var inString = false
        var escaped = false
        for byte in body {
            if inString {
                out.append(byte)
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            switch byte {
            case UInt8(ascii: "{"), UInt8(ascii: "["):
                out += [byte] + separator
            case UInt8(ascii: ","), UInt8(ascii: ":"):
                out += separator + [byte] + separator
            case UInt8(ascii: "}"), UInt8(ascii: "]"):
                out += separator + [byte]
            default:
                if byte == quote {
                    inString = true
                }
                out.append(byte)
            }
        }
        return out
    }

    /// Reorders the members of every object, at every depth, with the generator. Arrays keep their order, and
    /// their objects are reordered.
    private func shuffled(_ value: ArraySlice<UInt8>, _ generator: inout SplitMix64) -> [UInt8] {
        guard let open = value.first else {
            return []
        }
        if open == UInt8(ascii: "{") {
            var members = splitTopLevel(value.dropFirst().dropLast()).map { member -> [UInt8] in
                let colon = member.firstIndex(of: UInt8(ascii: ":")) ?? member.startIndex
                return Array(member[member.startIndex...colon]) + shuffled(member[(colon + 1)...], &generator)
            }
            for index in stride(from: members.count - 1, to: 0, by: -1) {
                members.swapAt(index, Int(generator.next() % UInt64(index + 1)))
            }
            return [open] + Array(members.joined(separator: [UInt8(ascii: ",")])) + [UInt8(ascii: "}")]
        }
        if open == UInt8(ascii: "[") {
            let items = splitTopLevel(value.dropFirst().dropLast()).map { shuffled($0, &generator) }
            return [open] + Array(items.joined(separator: [UInt8(ascii: ",")])) + [UInt8(ascii: "]")]
        }
        return Array(value)
    }

    /// The comma-separated parts at depth zero, outside strings. An empty value has no parts.
    private func splitTopLevel(_ value: ArraySlice<UInt8>) -> [ArraySlice<UInt8>] {
        guard !value.isEmpty else {
            return []
        }
        var parts: [ArraySlice<UInt8>] = []
        var depth = 0
        var inString = false
        var escaped = false
        var start = value.startIndex
        for index in value.indices {
            let byte = value[index]
            if inString {
                if escaped {
                    escaped = false
                } else if byte == backslash {
                    escaped = true
                } else if byte == quote {
                    inString = false
                }
                continue
            }
            if byte == quote {
                inString = true
            } else if byte == UInt8(ascii: "{") || byte == UInt8(ascii: "[") {
                depth += 1
            } else if byte == UInt8(ascii: "}") || byte == UInt8(ascii: "]") {
                depth -= 1
            } else if byte == UInt8(ascii: ","), depth == 0 {
                parts.append(value[start..<index])
                start = value.index(after: index)
            }
        }
        parts.append(value[start..<value.endIndex])
        return parts
    }
}

/// A fixed, seeded generator, so the reordered bodies are the same on every run.
private struct SplitMix64 {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }
}
