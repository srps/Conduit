// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import XCTest

final class IPAddressSyntaxTests: XCTestCase {
    /// `inet_pton` stops at a NUL, so what follows it was never checked.
    func testAnAddressFollowedByANULAndMoreIsNotAnAddress() {
        for (address, rest) in [("192.0.2.1", "\r\nX-Forged: 1"), ("2001:db8::1", "\r\nX-Forged: 1"), ("::1", "")] {
            XCTAssertTrue(IPAddressSyntax.isLiteral(address), address)
            XCTAssertFalse(IPAddressSyntax.isLiteral(address + "\0" + rest), (address + "\0" + rest).debugDescription)
        }
        XCTAssertFalse(IPAddressSyntax.isIPv4("192.0.2.1\0"))
        XCTAssertFalse(IPAddressSyntax.isIPv6("2001:db8::1\0"))
    }

    /// A combining mark after the `%` joins it into one Character, which a Character search misses; `inet_pton` reads the
    /// bytes and accepts the address before the zone.
    func testAZoneIndexIsRefusedWhateverFollowsThePercentSign() {
        for address in ["fe80::1%en0", "fd00::5%\u{301}en0", "fd00::5%\u{301}"] {
            XCTAssertFalse(IPAddressSyntax.isIPv6(address), address.debugDescription)
            XCTAssertFalse(IPAddressSyntax.isLiteral(address), address.debugDescription)
        }
    }
}
