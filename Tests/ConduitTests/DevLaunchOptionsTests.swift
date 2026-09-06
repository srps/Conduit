// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import Conduit
@testable import ProxyKernel

/// The `--dev` flag parser. The composition it feeds is the harness's and is
/// covered in `AppStateHarnessTests`; this pins the flags an agent types and
/// the refusals, since a flag silently ignored is a screenshot of the wrong
/// state.
final class DevLaunchOptionsTests: XCTestCase {
    private let scratch = URL(fileURLWithPath: "/tmp/conduit-dev-test", isDirectory: true)

    private func parse(_ args: [String]) throws -> DevLaunchOptions? {
        try DevLaunchOptions.parse(["Conduit"] + args, defaultStateDirectory: scratch)
    }

    func testWithoutTheFlagTheLaunchIsProduction() throws {
        XCTAssertNil(try parse([]))
        XCTAssertNil(try parse(["--port", "3129", "--no-system-proxy", "--no-env"]),
                     "the production flags are AppState's and pass through")
    }

    func testTheFlagAloneTakesTheDefaults() throws {
        let options = try XCTUnwrap(try parse(["--dev"]))
        XCTAssertEqual(options, DevLaunchOptions(stateDirectory: scratch))
    }

    func testEveryFlagLands() throws {
        let options = try XCTUnwrap(try parse([
            "--dev", "--dev-state-dir", "/tmp/elsewhere", "--section", "dns",
            "--vpn", "utun4", "--upstream", "127.0.0.1:3129", "--port", "0",
        ]))
        XCTAssertEqual(options.stateDirectory.path, "/tmp/elsewhere")
        XCTAssertEqual(options.section, .dns)
        XCTAssertEqual(options.vpn, .connected)
        XCTAssertEqual(options.vpnInterfaceName, "utun4")
        XCTAssertEqual(options.upstream, DevLaunchOptions.Endpoint(host: "127.0.0.1", port: 3129))
    }

    func testVPNOffReportsDisconnectedWithNoInterface() throws {
        let options = try XCTUnwrap(try parse(["--dev", "--vpn", "off"]))
        XCTAssertEqual(options.vpn, .disconnected(reason: .userInitiated))
        XCTAssertNil(options.vpnInterfaceName)
    }

    func testADevFlagWithoutDevIsRefused() {
        XCTAssertThrowsError(try parse(["--section", "dns"])) { error in
            XCTAssertEqual(error.localizedDescription, "--section needs --dev")
        }
    }

    func testBadValuesAreRefusedByName() {
        XCTAssertThrowsError(try parse(["--dev", "--section", "settings"])) { error in
            XCTAssertTrue(error.localizedDescription.hasPrefix("--section: unknown section settings"))
        }
        XCTAssertThrowsError(try parse(["--dev", "--section"])) { error in
            XCTAssertEqual(error.localizedDescription, "--section needs a value")
        }
        XCTAssertThrowsError(try parse(["--dev", "--vpn", "--section", "dns"])) { error in
            XCTAssertEqual(error.localizedDescription, "--vpn needs a value", "the next flag is not a value")
        }
        XCTAssertThrowsError(try parse(["--dev", "--upstream", "proxy.example"])) { error in
            XCTAssertEqual(error.localizedDescription, "--upstream: expected host:port, got proxy.example")
        }
        XCTAssertThrowsError(try parse(["--dev", "--upstream", "proxy.example:70000"])) { error in
            XCTAssertEqual(error.localizedDescription, "--upstream: port must be 1-65535 in proxy.example:70000")
        }
    }
}
