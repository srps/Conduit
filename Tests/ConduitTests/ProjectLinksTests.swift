// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit

final class ProjectLinksTests: XCTestCase {
    func testLinksPointAtThePublicRepository() {
        XCTAssertEqual(ProjectLinks.repository.absoluteString, "https://github.com/srps/Conduit")
        XCTAssertEqual(ProjectLinks.newIssue.absoluteString, "https://github.com/srps/Conduit/issues/new")
    }
}
