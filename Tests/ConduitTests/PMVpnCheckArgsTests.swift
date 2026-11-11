// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import pm_vpn_check

final class PMVpnCheckArgsTests: XCTestCase {
    func testMaxDurationTakesSecondsUpToOneWeek() {
        XCTAssertEqual(try PMVpnCheck.parseMaxDuration("0.5").get(), 0.5)
        XCTAssertEqual(try PMVpnCheck.parseMaxDuration("604800").get(), 604_800)
    }

    func testAMaxDurationPastOneWeekIsRefusedBeforeTheWatchStarts() {
        for text in ["604801", "1e300", "9223372036854775808"] {
            XCTAssertEqual(
                PMVpnCheck.parseMaxDuration(text),
                .failure(.init("--max-duration is at most 604800 seconds (one week); \(text) is more")),
                "\(text) would trap converting to Int"
            )
        }
    }

    func testAMaxDurationThatIsNotPositiveSecondsIsRefused() {
        for text in [nil, "", "ten", "0", "-1", "inf", "nan"] as [String?] {
            XCTAssertEqual(
                PMVpnCheck.parseMaxDuration(text), .failure(.init("--max-duration takes a number of seconds above zero")),
                "\(text ?? "nothing")"
            )
        }
    }
}
