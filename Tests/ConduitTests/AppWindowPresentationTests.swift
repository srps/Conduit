// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
@testable import Conduit

final class AppWindowPresentationTests: XCTestCase {
    func testReturnsToMenuBarOnlyWhenRegularWithNoVisibleAppWindow() {
        XCTAssertTrue(AppWindowPresentation.shouldReturnToMenuBarMode(isRegular: true, visibleAppWindows: 0))
        XCTAssertFalse(AppWindowPresentation.shouldReturnToMenuBarMode(isRegular: true, visibleAppWindows: 1))
        XCTAssertFalse(AppWindowPresentation.shouldReturnToMenuBarMode(isRegular: false, visibleAppWindows: 0))
    }
}
