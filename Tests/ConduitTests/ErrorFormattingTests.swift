// SPDX-License-Identifier: Apache-2.0
import Darwin
import NIOCore
import XCTest
@testable import ProxyKernel

final class ErrorFormattingTests: XCTestCase {
    func testDisplayDescriptionUsesDetailedNIOMessage() {
        let error = IOError(errnoCode: EADDRINUSE, reason: "bind")

        let description = error.displayDescription

        XCTAssertTrue(description.contains("bind"))
        XCTAssertTrue(description.contains("Address already in use"))
        XCTAssertTrue(description.contains("errno: \(EADDRINUSE)"))
    }

    func testDisplayDescriptionNamesTheChannelErrorCase() {
        let timeout: any Error = ChannelError.connectTimeout(.seconds(10))
        let closed: any Error = ChannelError.ioOnClosedChannel

        // Foundation's bridge renders both as "(NIOCore.ChannelError error N.)".
        XCTAssertTrue(timeout.displayDescription.contains("timeout"), timeout.displayDescription)
        XCTAssertTrue(timeout.displayDescription.contains("10"), timeout.displayDescription)
        XCTAssertTrue(closed.displayDescription.contains("closed channel"), closed.displayDescription)
        XCTAssertFalse(closed.displayDescription.contains("operation couldn"), closed.displayDescription)
    }
}
