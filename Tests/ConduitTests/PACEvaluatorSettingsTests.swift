// SPDX-License-Identifier: Apache-2.0
// Wiring tests for the post-graduation PAC evaluator path. Pins three
// contracts:
//
//   1. The factory `AppState.makePACEvaluator(fetcher:)` returns the
//      CFNetwork-backed concrete backend.
//   2. Legacy configs that still contain the removed
//      `experimentalCFPacEvaluator` key decode successfully.
//
// Not tested here: full `AppState` construction (touches Keychain,
// NSWorkspace, NotificationManager.requestAuthorization() — too heavy for
// a unit test). The factory extraction in `AppState.makePACEvaluator`
// exists specifically so this layer can be tested without that.

import XCTest
@testable import ProxyKernel
@testable import ProxyPAC
@testable import Conduit

final class PACEvaluatorSettingsTests: XCTestCase {

    // MARK: - Factory wiring

    func testFactoryReturnsCFPACEvaluator() {
        let evaluator = AppState.makePACEvaluator(
            insecureFetcher: { _ in throw FetcherError.shouldNotBeCalled }
        )
        XCTAssertTrue(evaluator is CFPACEvaluator,
                      "The app must wire CFPACEvaluator (CFNetwork-backed).")
    }

    // MARK: - Codable compatibility

    func testLegacyConfigWithRemovedExperimentalFlagDecodes() throws {
        // A config saved during the dual-impl ramp may still contain the
        // removed key. Decoding must ignore it and continue with CFNetwork.
        let legacyJSON = """
        {
            "profileName": "Legacy",
            "domain": "EXAMPLE",
            "username": "u",
            "workstation": "w",
            "authMode": "systemNegotiated",
            "experimentalCFPacEvaluator": false
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(ProxyConfig.self, from: legacyJSON)
        XCTAssertEqual(decoded.profileName, "Legacy")
    }

    // MARK: - Helpers

    private enum FetcherError: Error { case shouldNotBeCalled }
}
