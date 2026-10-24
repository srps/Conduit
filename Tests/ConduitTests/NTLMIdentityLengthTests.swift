// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyAuth
@testable import ProxyKernel

/// The NTLM security buffers carry a 16-bit length. The identity comes from the
/// user's configuration, so a long domain or workstation used to trap in
/// `UInt16(_:)`. The message builders now refuse with a fixed error instead.
final class NTLMIdentityLengthTests: XCTestCase {

    private func credentials(domain: String = "D", workstation: String = "W") -> ProxyCredentials {
        ProxyCredentials(username: "user", domain: domain, workstation: workstation, ntHash: SecretBytes.repeating(0, count: 16))
    }

    func testNegotiateRefusesADomainPastTheLengthField() {
        let domain = String(repeating: "d", count: 65_536)

        XCTAssertThrowsError(try NTLMAuth.negotiateMessage(credentials: credentials(domain: domain))) { error in
            XCTAssertEqual(error as? NTLMAuthError, .messageFieldTooLong)
        }
    }

    func testNegotiateRefusesAWorkstationPastTheLengthField() {
        let workstation = String(repeating: "w", count: 65_536)

        XCTAssertThrowsError(try NTLMAuth.negotiateMessage(credentials: credentials(workstation: workstation))) { error in
            XCTAssertEqual(error as? NTLMAuthError, .messageFieldTooLong)
        }
    }

    /// The largest value the field holds is still accepted, so the refusal is
    /// exactly at the boundary and not one byte early.
    func testNegotiateAcceptsTheLargestLengthField() throws {
        let domain = String(repeating: "d", count: 65_535)

        XCTAssertFalse(try NTLMAuth.negotiateMessage(credentials: credentials(domain: domain)).isEmpty)
    }
}
