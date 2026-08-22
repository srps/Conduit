// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

final class HelperLogLineTests: XCTestCase {
    /// Timestamp, level, pid, newline — the four things the old bare
    /// `fputs` lines lacked, which left 235 lines of helper log undatable.
    func testALineCarriesTimestampLevelAndPid() {
        let line = HelperLogLine.format(
            .warning, "Rejected connection from unauthorized peer",
            pid: 996, at: Date(timeIntervalSince1970: 1_700_000_000)
        )
        XCTAssertEqual(line, "[2023-11-14T22:13:20.000Z] [WARNING] [pid 996] Rejected connection from unauthorized peer\n")
    }

    /// The newsyslog entry has to name the same file launchd writes to, or
    /// the rotation rotates nothing.
    func testTheNewsyslogEntryRotatesTheFileLaunchdWrites() {
        XCTAssertTrue(HelperConstants.newsyslogEntry.hasPrefix(HelperConstants.logPath + "\t"))
        XCTAssertEqual(HelperConstants.logPath, "/var/log/\(HelperConstants.serviceLabel).log")
    }
}
