// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// The strict byte cursor under the private scanner and the runtime file reader (decision 0024). Its verdicts on valid
/// JSON are checked against `JSONSerialization`, and each refusal is pinned to the fault the cursor names. The cursor
/// carries no key or ceiling, so these tests use no schema.
final class BoundedJSONByteCursorTests: XCTestCase {
    private func withCursor<Output>(_ bytes: [UInt8], _ body: (inout JSONByteCursor) throws -> Output) rethrows -> Output {
        try bytes.withUnsafeBufferPointer { buffer in
            var cursor = JSONByteCursor(buffer)
            return try body(&cursor)
        }
    }

    /// The fault `scan` raises over `bytes`, or nil when it completes. A throw that is not a fault is a test failure.
    private func fault(_ bytes: [UInt8], _ scan: (inout JSONByteCursor) throws -> Void) -> JSONByteCursor.Fault? {
        do {
            try withCursor(bytes, scan)
            return nil
        } catch let error as JSONByteCursor.Fault {
            return error
        } catch {
            XCTFail("the cursor threw a non-fault error: \(error)")
            return nil
        }
    }

    private func decodedString(_ bytes: [UInt8]) throws -> String {
        try withCursor(bytes) { cursor in
            var scalars: [Unicode.Scalar] = []
            try cursor.scanString { scalars.append($0) }
            try cursor.expectEnd()
            return String(String.UnicodeScalarView(scalars))
        }
    }

    // MARK: - Whitespace and literals

    func testWhitespaceIsOnlyTheFourJSONCharacters() {
        XCTAssertNil(fault([0x20, 0x09, 0x0A, 0x0D]) { cursor in
            cursor.skipWhitespace()
            try cursor.expectEnd()
        })
        XCTAssertEqual(fault([0x0B]) { cursor in
            cursor.skipWhitespace()
            try cursor.expectEnd()
        }, .trailingContent, "a vertical tab is not JSON whitespace")
    }

    func testLiteralsAreSpelledExactly() {
        XCTAssertNil(fault(Array("true".utf8)) { try $0.scanLiteral("true") })
        XCTAssertEqual(fault(Array("tru".utf8)) { try $0.scanLiteral("true") }, .truncated)
        XCTAssertEqual(fault(Array("trUe".utf8)) { try $0.scanLiteral("true") }, .invalidLiteral)
    }

    // MARK: - Numbers

    func testValidNumberLexemesAreAcceptedAsFoundationAcceptsThem() {
        let lexemes = ["0", "-0", "7", "-12", "0.5", "-12.5", "1e5", "1E+5", "2.5e-3", "-1.25e+10"]
        for lexeme in lexemes {
            XCTAssertNil(fault(Array(lexeme.utf8)) { cursor in
                try cursor.scanNumber()
                try cursor.expectEnd()
            }, lexeme)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(lexeme.utf8), options: [.fragmentsAllowed]), lexeme)
        }
    }

    func testMalformedNumberLexemesAreRefusedAsFoundationRefusesThem() {
        let lexemes = ["01", "-01", "-", "1.", ".5", "+1", "1e", "1e+", "--1", "1.e5"]
        for lexeme in lexemes {
            XCTAssertNotNil(fault(Array(lexeme.utf8)) { cursor in
                try cursor.scanNumber()
                try cursor.expectEnd()
            }, lexeme)
            XCTAssertThrowsError(try JSONSerialization.jsonObject(with: Data(lexeme.utf8), options: [.fragmentsAllowed]), lexeme)
        }
    }

    // MARK: - Strings

    func testEachDecodedScalarReachesTheVisitorInOrder() throws {
        let text = #""aé😀\n\"é""#
        XCTAssertEqual(try decodedString(Array(text.utf8)), "aé😀\n\"é")
    }

    func testValidStringsDecodeToTheTextFoundationDecodes() throws {
        let corpus = [
            #""""#,
            #""plain text""#,
            #""café""#,
            #""tab\tnew\nquote\"slash\/back\\""#,
            #""\b\f\r""#,
            "\"caf\u{e9}\"",
            "\"\u{1F600}\"",
            #""😀""#,
            #""\u007f\u0000""#,
        ]
        for text in corpus {
            let bytes = Array(text.utf8)
            let oracle = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(bytes), options: [.fragmentsAllowed]) as? String,
                text
            )
            XCTAssertEqual(try decodedString(bytes), oracle, text)
        }
    }

    func testRefusedStringsNameTheirFault() {
        let cases: [([UInt8], JSONByteCursor.Fault)] = [
            ([0x22, 0x01, 0x22], .controlCharacter),
            ([0x22, 0x0A, 0x22], .controlCharacter),
            (Array(#""\x""#.utf8), .invalidEscape),
            (Array(#""\u12G4""#.utf8), .invalidEscape),
            (Array(#""\ud800""#.utf8), .unpairedSurrogate),
            (Array(#""\ud800A""#.utf8), .unpairedSurrogate),
            (Array(#""\ud800\n""#.utf8), .unpairedSurrogate),
            (Array(#""\udc00""#.utf8), .unpairedSurrogate),
            ([0x22, 0xFF, 0x22], .invalidUTF8),
            ([0x22, 0xC0, 0x80, 0x22], .invalidUTF8),
            ([0x22, 0xE0, 0x80, 0x80, 0x22], .invalidUTF8),
            ([0x22, 0xED, 0xA0, 0x80, 0x22], .invalidUTF8),
            ([0x22, 0xF4, 0x90, 0x80, 0x80, 0x22], .invalidUTF8),
            ([0x22, 0xE2, 0x82, 0x22], .invalidUTF8),
            (Array(#""abc"#.utf8), .truncated),
        ]
        for (bytes, expected) in cases {
            XCTAssertEqual(fault(bytes) { _ = try $0.scanString { _ in } }, expected, "\(bytes)")
        }
    }

    func testAVisitorsErrorStopsTheScanAndPassesThroughUnchanged() {
        struct Sentinel: Error, Equatable {}
        var visited: [Unicode.Scalar] = []
        do {
            try withCursor(Array(#""abcdef""#.utf8)) { cursor in
                try cursor.scanString { scalar in
                    visited.append(scalar)
                    if scalar == "c" {
                        throw Sentinel()
                    }
                }
            }
            XCTFail("the visitor's refusal did not stop the scan")
        } catch {
            XCTAssertEqual(error as? Sentinel, Sentinel())
        }
        XCTAssertEqual(String(String.UnicodeScalarView(visited)), "abc")
    }

    // MARK: - Skipping

    func testSkippingAcceptsEveryValueShapeAndDuplicateNames() {
        let text = #"{"a":[1,-2.5e+3,true,false,null,"xA"],"a":{"b":{}},"c":[[],[{}]]}"#
        XCTAssertNil(fault(Array(text.utf8)) { cursor in
            try cursor.skipValue(maxDepth: 8)
            try cursor.expectEnd()
        })
        XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(text.utf8)))
    }

    func testMalformedSkippedValuesAreRefused() {
        let texts = [#"[1,]"#, #"{"a" 1}"#, #"{"a":1,}"#, #"[1 2]"#, #"{1:2}"#, #"{"a":"\x"}"#, #"["\ud800"]"#, #"[01]"#, #"[tru]"#, #"[1]]"#]
        for text in texts {
            XCTAssertNotNil(fault(Array(text.utf8)) { cursor in
                try cursor.skipValue(maxDepth: 8)
                try cursor.expectEnd()
            }, text)
        }
    }

    func testDepthIsTheCallersBoundNotTheSchemasEight() {
        let nine = Array(repeating: UInt8(ascii: "["), count: 9) + Array(repeating: UInt8(ascii: "]"), count: 9)
        XCTAssertEqual(fault(nine) { try $0.skipValue(maxDepth: 8) }, .nestingTooDeep)
        XCTAssertNil(fault(nine) { try $0.skipValue(maxDepth: 9) })

        // Deep input is walked without recursion, so a depth far past any call stack still completes.
        let depth = 100_000
        let deep = Array(repeating: UInt8(ascii: "["), count: depth) + Array(repeating: UInt8(ascii: "]"), count: depth)
        XCTAssertNil(fault(deep) { cursor in
            try cursor.skipValue(maxDepth: depth)
            try cursor.expectEnd()
        })
        XCTAssertEqual(fault(deep) { try $0.skipValue(maxDepth: depth - 1) }, .nestingTooDeep)
    }

    func testSkipLeavesTheCursorOnTheByteAfterTheValue() throws {
        let next = try withCursor(Array("[1,2] x".utf8)) { cursor -> UInt8? in
            try cursor.skipValue(maxDepth: 4)
            cursor.skipWhitespace()
            return cursor.current
        }
        XCTAssertEqual(next, UInt8(ascii: "x"))
    }
}
