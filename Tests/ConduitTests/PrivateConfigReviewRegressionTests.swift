// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

/// Regression witnesses for the codec review. They pin the decoder's own cap check, which does
/// not depend on the reader having run first, and its boundary with the reader.
final class PrivateConfigReviewRegressionTests: XCTestCase {
    private let cap = PrivateConfigurationFrame.maxFrameBytes

    func testDirectDecoderRejectsABodyWhoseCompleteFrameCannotFitTheCap() throws {
        let request = try PrivateConfigSamples.request()
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        var body = Array(frame[start..<(frame.count - 1)])
        let oversizedBodyCount = PrivateConfigurationFrame.maxFrameBytes - 15
        body.append(contentsOf: repeatElement(UInt8(0x20), count: oversizedBodyCount - body.count))
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decode(
            PrivateConfigurationFrameBody(bytes: SecretBytes(body)))) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .frameTooLarge)
        }
    }

    /// The cap comes before the scan. The body is not JSON at all, so a scan-first decoder would
    /// answer `malformedBody`. The answer here must be `frameTooLarge`.
    func testDirectDecoderRefusesAnOversizeBodyBeforeScanningIt() {
        let body = PrivateConfigurationFrameBody(bytes: SecretBytes(Array(repeating: UInt8(ascii: "x"), count: cap)))
        XCTAssertThrowsError(try PrivateConfigurationDecoder.decode(body)) {
            XCTAssertEqual($0 as? PrivateConfigurationWireError, .frameTooLarge)
        }
    }

    /// The largest body that fits. A seven-digit length of `cap - 16` makes the whole frame exactly
    /// `cap`: the header is `PCV1 Q ` (7), seven digits, a line feed, the body and a terminator
    /// (16 bytes around the body). The decoder and the reader both accept it.
    func testDirectDecoderAcceptsABodyWhoseCompleteFrameIsExactlyTheCap() throws {
        let request = try PrivateConfigSamples.request()
        let body = try paddedBody(for: request, count: cap - 16)
        XCTAssertEqual(
            try PrivateConfigurationDecoder.decode(PrivateConfigurationFrameBody(bytes: SecretBytes(body))),
            request
        )

        let framed = Array("PCV1 Q \(body.count)\n".utf8) + body + [UInt8(ascii: "\n")]
        XCTAssertEqual(framed.count, cap)
        let frame = try XCTUnwrap(readOneFrame(framed))
        XCTAssertEqual(frame.bytes.count, body.count)
    }

    /// A zero-length body is not a frame. The decoder has no special case for it: the frame size
    /// is far under the cap, so the scanner refuses the empty input as malformed. The reader refuses
    /// `PCV1 Q 0\n` in its header (see `PrivateConfigCodecTests`).
    func testEmptyAndWhitespaceOnlyBodiesAreMalformedNotTooLarge() {
        let bodies: [[UInt8]] = [[], Array(repeating: UInt8(ascii: " "), count: 16)]
        for body in bodies {
            XCTAssertThrowsError(try PrivateConfigurationDecoder.decode(
                PrivateConfigurationFrameBody(bytes: SecretBytes(body)))) {
                XCTAssertEqual($0 as? PrivateConfigurationWireError, .malformedBody)
            }
        }
    }

    // MARK: - Helpers

    /// The request's JSON body, padded with trailing spaces (valid JSON whitespace) to `count` bytes.
    private func paddedBody(for request: PrivateConfigurationRequest, count: Int) throws -> [UInt8] {
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        let start = try XCTUnwrap(frame.firstIndex(of: 0x0A)) + 1
        var body = Array(frame[start..<(frame.count - 1)])
        XCTAssertLessThanOrEqual(body.count, count)
        body.append(contentsOf: repeatElement(UInt8(ascii: " "), count: count - body.count))
        return body
    }

    /// Feeds `bytes` to a fresh reader in its own call budget and returns the one frame it completes.
    private func readOneFrame(_ bytes: [UInt8]) throws -> PrivateConfigurationFrameBody? {
        let reader = PrivateConfigurationFrameReader()
        var offset = 0
        while offset < bytes.count {
            let (step, consumed) = try reader.consume(bytes[offset...])
            offset += consumed
            if case .frame(let body) = step {
                return body
            }
        }
        return nil
    }
}
