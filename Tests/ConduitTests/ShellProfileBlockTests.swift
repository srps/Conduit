// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PlatformMac

/// The strict reading of Conduit's region in a shell profile (#175).
private extension ShellProfileBlock.Contents {
    var blockCount: Int {
        guard case .managed(let text, _) = self else { return 0 }
        return text.components(separatedBy: ShellProfileBlock.startMarker).count - 1
    }
}

final class ShellProfileBlockTests: XCTestCase {
    private let start = ShellProfileBlock.startMarker
    private let end = ShellProfileBlock.endMarker
    private var block: String { "\(start)\nexport HTTP_PROXY='http://127.0.0.1:3128'\n\(end)" }

    func testAFileWithoutMarkersIsUnmanaged() {
        XCTAssertEqual(ShellProfileBlock.parse("export EDITOR=vim\n"), .unmanaged("export EDITOR=vim\n"))
        XCTAssertEqual(ShellProfileBlock.parse(""), .unmanaged(""))
    }

    func testOnePairInOrderIsManaged() {
        guard case .managed = ShellProfileBlock.parse("a\n\n\(block)\n") else { return XCTFail("one pair is ours") }
    }

    /// Swift reads CRLF as one `Character`; a block saved by a Windows
    /// editor must still be found, and removed without touching the rest.
    func testACRLFProfileIsReadAndEditedLineByLine() throws {
        let text = "export A=1\r\n\r\n\(start)\r\nexport HTTP_PROXY=x\r\n\(end)\r\nexport B=2\r\n"
        let contents = ShellProfileBlock.parse(text)
        guard case .managed = contents else { return XCTFail("a CRLF block is ours: \(contents)") }
        XCTAssertEqual(ShellProfileBlock.clearing(contents), "export A=1\r\nexport B=2\r\n")
        let applied = try XCTUnwrap(ShellProfileBlock.applying(block, to: contents))
        XCTAssertEqual(ShellProfileBlock.parse(applied).blockCount, 1, "replaced, not appended beside")
        XCTAssertTrue(applied.hasPrefix("export A=1\r\nexport B=2\r\n\n\(start)"))
    }

    func testMarkersThatDoNotPairAreAmbiguous() {
        let cases = [
            "a\n\(start)\nexport X=1\n",            // start without end
            "a\n\(end)\n",                           // end without start
            "\(end)\n\(start)\n",                    // reversed
            "\(block)\n\(block)\n",                  // repeated
        ]
        for text in cases {
            XCTAssertEqual(ShellProfileBlock.parse(text), .unsafe(.ambiguousMarkers), text)
        }
    }

    /// A marker is a whole line: a comment that mentions it is the user's.
    func testAMarkerInsideALineIsNotAMarker() {
        let text = "echo '\(start)'\n"
        XCTAssertEqual(ShellProfileBlock.parse(text), .unmanaged(text))
    }

    func testApplyingAppendsAfterOneBlankLineAndKeepsTheRest() {
        XCTAssertEqual(ShellProfileBlock.applying(block, to: .unmanaged("a\n")), "a\n\n\(block)\n")
        XCTAssertEqual(ShellProfileBlock.applying(block, to: .unmanaged("a")), "a\n\n\(block)\n")
        XCTAssertEqual(ShellProfileBlock.applying(block, to: .unmanaged("a\n\n\n")), "a\n\n\n\n\(block)\n",
                       "the user's own blank lines are kept, and one is added")
        XCTAssertEqual(ShellProfileBlock.applying(block, to: .missing), "\(block)\n")
        XCTAssertEqual(ShellProfileBlock.applying(block, to: .unmanaged("\n")), "\(block)\n",
                       "what a clear leaves in environment.d")
        XCTAssertNil(ShellProfileBlock.applying(block, to: .unsafe(.ambiguousMarkers)))
    }

    func testReapplyingMovesTheBlockToTheEndAndAddsNothing() {
        let applied = "a\n\n\(block)\nb\n"
        let next = ShellProfileBlock.applying(block, to: ShellProfileBlock.parse(applied))
        XCTAssertEqual(next, "a\nb\n\n\(block)\n")
        XCTAssertEqual(ShellProfileBlock.applying(block, to: ShellProfileBlock.parse(next!)), next, "idempotent")
    }

    func testClearingUndoesApplyingByteForByte() {
        for original in ["a\n", "export EDITOR=vim\n\n\nalias ll='ls -la'\n", "a\n\n"] {
            let applied = ShellProfileBlock.applying(block, to: .unmanaged(original))!
            XCTAssertEqual(ShellProfileBlock.clearing(ShellProfileBlock.parse(applied)), original, original)
        }
    }

    func testClearingWithoutABlockWritesNothing() {
        XCTAssertNil(ShellProfileBlock.clearing(.unmanaged("a\n")))
        XCTAssertNil(ShellProfileBlock.clearing(.missing))
        XCTAssertNil(ShellProfileBlock.clearing(.unsafe(.notUTF8)))
    }
}
