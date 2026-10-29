// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

/// A sidecar the startup load refuses refuses the whole open: no draft is seeded, nothing is saved, every file keeps its bytes, and the
/// controls stay disabled. The loader's refusal itself is pinned by `ConfigSidecarBoundaryTests`.
@MainActor
final class AppStateHarnessSidecarRefusalTests: XCTestCase {
    private var harness: AppStateHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    func testAMalformedPlatformSidecarRefusesTheOpenAndKeepsEveryFile() async throws {
        try await assertRefusesTheOpen(malformed: "platform.json")
    }

    func testAMalformedPreferencesSidecarRefusesTheOpenAndKeepsEveryFile() async throws {
        try await assertRefusesTheOpen(malformed: "preferences.json")
    }

    private func assertRefusesTheOpen(malformed filename: String, line: UInt = #line) async throws {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        let harness = try AppStateHarness(config: config, platformConfig: PlatformIntegrationConfig())
        self.harness = harness
        let path = harness.stateDirectory.appendingPathComponent(filename)
        // Malformed, and carrying a value the banner must not repeat.
        let corrupt = Data(#"{"preferredBrowserTestURL": "https://private-witness.test/"#.utf8)
        let runtimeBytes = try Data(contentsOf: harness.environment.configFile)
        try corrupt.write(to: path)
        let state = harness.launch()
        await state.opening?.value
        XCTAssertEqual(state.phase, .refused, line: line)
        let banner = try XCTUnwrap(state.lastErrorMessage, "the refusal is shown", line: line)
        XCTAssertTrue(banner.contains(filename), "the banner names the refused file: \(banner)", line: line)
        XCTAssertFalse(banner.contains("private-witness"), "and none of its content", line: line)
        XCTAssertNil(state.editor, "no editor exists without an observation", line: line)
        state.appPreferences.fileLoggingEnabled.toggle()
        state.platformConfig.manageSystemProxy.toggle()
        state.saveConfig()
        state.toggleProxy()
        XCTAssertEqual(try Data(contentsOf: path), corrupt, line: line)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), runtimeBytes, line: line)
        XCTAssertFalse(state.controlsEnabled, line: line)
    }
}
