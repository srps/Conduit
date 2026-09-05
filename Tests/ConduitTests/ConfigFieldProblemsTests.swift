// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import ProxyKernel
@testable import Conduit

final class ConfigFieldProblemsTests: XCTestCase {
    func testIndexesBoundaryErrorsByField() {
        var config = ProxyConfig()
        config.localPort = 70_000
        config.maxConnections = 0
        config.noProxyHosts = ["ok.example", "bad host with spaces"]

        let problems = ConfigFieldProblems(config: config)

        XCTAssertNotNil(problems.message(for: "proxy.port"))
        XCTAssertTrue(problems.isInvalid("proxy.maxConnections"))
        XCTAssertNil(problems.message(for: "routing.noProxyHosts[0]"))
        XCTAssertNotNil(problems.message(for: "routing.noProxyHosts[1]"))
        XCTAssertNil(problems.message(for: "proxy.socksPort"))
    }

    func testConflictsAreListedSeparatelyAndFilterable() {
        var config = ProxyConfig()
        config.socksEnabled = true
        config.socksPort = config.localPort

        let problems = ConfigFieldProblems(config: config)

        XCTAssertFalse(problems.conflicts.isEmpty)
        XCTAssertFalse(problems.conflicts(mentioning: ["SOCKS port"]).isEmpty)
        XCTAssertTrue(problems.conflicts(mentioning: ["tunnel"]).isEmpty)
        XCTAssertNil(problems.message(for: "proxy.socksPort"), "a conflict is not a per-field problem")
    }

    func testCleanConfigHasNoProblems() {
        XCTAssertTrue(ConfigFieldProblems(config: ProxyConfig()).isEmpty)
    }
}
