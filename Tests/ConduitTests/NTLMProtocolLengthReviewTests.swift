// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// The wire length covers the transformed bytes, not the source character count.
/// These independent witnesses exercise Authenticate as well as Negotiate.
final class NTLMProtocolLengthReviewTests: XCTestCase {
    func testAuthenticateRefusesEachOversizedUTF16Identity() {
        let long = String(repeating: "x", count: 32_768)
        let identities = [(long, "D", "W"), ("u", long, "W"), ("u", "D", long)]
        for (username, domain, workstation) in identities {
            let credentials = ProxyCredentials(username: username, domain: domain,
                workstation: workstation, ntHash: SecretBytes.repeating(0, count: 16))
            XCTAssertThrowsError(try NTLMAuth.authenticateMessage(
                challengeBase64: challenge(), credentials: credentials)) {
                XCTAssertEqual($0 as? NTLMAuthError, .messageFieldTooLong)
            }
        }
    }

    func testAuthenticateAcceptsLargestEvenUTF16FieldLength() throws {
        let credentials = ProxyCredentials(username: String(repeating: "u", count: 32_767),
            domain: "D", workstation: "W", ntHash: SecretBytes.repeating(0, count: 16))
        let encoded = try NTLMAuth.authenticateMessage(challengeBase64: challenge(), credentials: credentials)
        let message = try XCTUnwrap(Data(base64Encoded: encoded))
        // UserName security-buffer length is the little-endian UInt16 at offset36.
        XCTAssertEqual(Int(message[36]) | Int(message[37]) << 8, 65_534)
    }

    func testNegotiateChecksUppercasedBytesRatherThanOriginalLength() {
        let domain = String(repeating: "ΐ", count: 12_000)
        XCTAssertLessThan(domain.utf8.count, 65_535)
        XCTAssertGreaterThan(domain.uppercased().utf8.count, 65_535)
        let credentials = ProxyCredentials(username: "u", domain: domain,
            workstation: "W", ntHash: SecretBytes.repeating(0, count: 16))
        XCTAssertThrowsError(try NTLMAuth.negotiateMessage(credentials: credentials)) {
            XCTAssertEqual($0 as? NTLMAuthError, .messageFieldTooLong)
        }
    }

    private func challenge() -> String {
        var bytes = Array("NTLMSSP\0".utf8)
        bytes += [2, 0, 0, 0] // MessageType
        bytes += Array(repeating: 0, count: 8) // TargetNameFields
        bytes += [5, 0x92, 0x88, 0xA2] // Flags
        bytes += [1, 2, 3, 4, 5, 6, 7, 8] // ServerChallenge
        bytes += Array(repeating: 0, count: 16) // Reserved and TargetInfoFields
        return Data(bytes).base64EncodedString()
    }
}
