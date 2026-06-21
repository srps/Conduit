// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel

final class TCPRelaySecurityTests: XCTestCase {
    func testRejectsWildcardBindHost() {
        let relay = TCPRelay()

        XCTAssertThrowsError(
            try relay.start(listenPort: 0, targetPort: 1, host: "0.0.0.0")
        )
    }
}
