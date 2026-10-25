// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac

/// Synthetic mapping witnesses for the write-error classifier. Each case builds an error shape that a failed atomic write can
/// take, then checks that only a closed code comes out. They pin the mapping rules, not the OS: some shapes, such as an
/// out-of-range POSIX code, are built here because they are the classifier's input contract, and they do not claim that every
/// such shape occurs on this OS. No case writes a file.
final class StateFileAccessWriteErrorTests: XCTestCase {
    private static let cocoaWriteOutOfSpace = 640
    private static let cocoaWriteNoPermission = 513

    private func classify(_ error: NSError) -> ConfigurationFileWriteError {
        OSStateFileAccess.writeError(for: error)
    }

    private func posix(_ code: Int) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: code)
    }

    /// A POSIX error is kept as its errno.
    func testAPOSIXErrorIsKeptAsItsErrno() {
        XCTAssertEqual(classify(posix(Int(ENOSPC))), .writeFailed(errno: ENOSPC))
    }

    /// A Cocoa error with no POSIX cause keeps its own Cocoa code. It is not reported as `EIO`.
    func testACocoaErrorWithoutAPOSIXCauseKeepsItsCocoaCode() {
        let error = NSError(domain: NSCocoaErrorDomain, code: Self.cocoaWriteNoPermission)
        XCTAssertEqual(classify(error), .cocoaFailed(code: Self.cocoaWriteNoPermission))
    }

    /// Foundation's Cocoa wrapper around a POSIX cause yields the cause's errno. The Cocoa code is not the answer then.
    func testACocoaErrorWithAPOSIXCauseIsKeptAsThatErrno() {
        let error = NSError(domain: NSCocoaErrorDomain, code: Self.cocoaWriteOutOfSpace, userInfo: [NSUnderlyingErrorKey: posix(Int(ENOSPC))])
        XCTAssertEqual(classify(error), .writeFailed(errno: ENOSPC))
    }

    /// A failure in an unknown domain is `unclassified`, whatever its domain string, description and user info hold. The outcome
    /// has no field for any of them, so none is retained.
    func testAnUnknownDomainIsUnclassifiedAndNothingFromItIsKept() {
        let error = NSError(
            domain: "io.example.synthetic-secret=/Users/alice/config.json",
            code: 9,
            userInfo: [
                NSLocalizedDescriptionKey: "synthetic secret description",
                NSUnderlyingErrorKey: NSError(domain: "io.example.synthetic-inner", code: 2),
            ]
        )
        XCTAssertEqual(classify(error), .unclassified)
    }

    /// A POSIX cause still counts under an unknown outer domain, because it is the real errno.
    func testAPOSIXCauseUnderAnUnknownDomainIsKept() {
        let error = NSError(domain: "io.example.synthetic-wrapper", code: 3, userInfo: [NSUnderlyingErrorKey: posix(Int(EACCES))])
        XCTAssertEqual(classify(error), .writeFailed(errno: EACCES))
    }

    /// Under a non-Cocoa error, a POSIX code that does not fit `Int32`, or is not positive, is `unclassified`. It is not truncated
    /// and it is not `EIO`.
    func testAPOSIXCodeOutsideInt32OrNotPositiveIsUnclassifiedNotEIO() {
        for code in [Int(Int32.max) + 1, Int(Int32.min) - 1, 0, -1] {
            XCTAssertEqual(classify(posix(code)), .unclassified, "POSIX code \(code)")
        }
    }

    /// A Cocoa error whose POSIX cause is unusable keeps the outer Cocoa code. No errno is invented from the unusable cause.
    func testAnUnusablePOSIXCauseUnderACocoaErrorKeepsItsCocoaCode() {
        let cause = posix(Int(Int32.max) + 1)
        let error = NSError(domain: NSCocoaErrorDomain, code: Self.cocoaWriteOutOfSpace, userInfo: [NSUnderlyingErrorKey: cause])
        XCTAssertEqual(classify(error), .cocoaFailed(code: Self.cocoaWriteOutOfSpace))
    }

    /// The walk follows `maximumUnderlyingDepth` links. A POSIX code at that depth is kept. One link further is not reached, so the
    /// outer Cocoa code is kept instead. The same cap bounds a cyclic chain, which therefore stops.
    func testTheUnderlyingWalkStopsAtItsDepthCap() {
        let cap = OSStateFileAccess.maximumUnderlyingDepth
        XCTAssertEqual(classify(chain(hops: cap)), .writeFailed(errno: ENOSPC))
        XCTAssertEqual(classify(chain(hops: cap + 1)), .cocoaFailed(code: Self.cocoaWriteOutOfSpace))
    }

    /// A Cocoa outer error with `hops` underlying links to a POSIX leaf with `ENOSPC`.
    private func chain(hops: Int) -> NSError {
        var error = posix(Int(ENOSPC))
        for _ in 0..<hops {
            error = NSError(domain: NSCocoaErrorDomain, code: Self.cocoaWriteOutOfSpace, userInfo: [NSUnderlyingErrorKey: error])
        }
        return error
    }
}
