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
}
