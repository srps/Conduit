// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import Conduit
@testable import PlatformMac
@testable import ProxyKernel

@MainActor
final class PACPreviewTests: XCTestCase {
    private var harness: AppStateHarness?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    func testEmptyTargetIsRejectedBeforeFetching() throws {
        let state = try launch()
        // This file does not exist: a fetch-first implementation reports a
        // download failure instead of the actionable diagnostic setting.
        state.config.pacURL = harness!.stateDirectory.appendingPathComponent("missing.pac").absoluteString
        XCTAssertEqual(state.appPreferences.preferredBrowserTestURL, AppPreferences.defaultBrowserTestURL)
        state.appPreferences.preferredBrowserTestURL = ""
        state.refreshPACResolutionPreview()
        XCTAssertEqual(state.pacPreviewMessage, PACResolverError.invalidTargetURL.localizedDescription)
        XCTAssertFalse(state.isPACPreviewRunning)
        XCTAssertNil(state.pacPreviewTask)
        XCTAssertTrue(state.eventLog.events.contains {
            $0.event == "pac.preview_failed" && $0.detail == PACResolverError.invalidTargetURL.localizedDescription
        })
    }

    func testPreviewTargetDefaultsAndRepairsLegacyEmptyPreference() throws {
        XCTAssertEqual(AppPreferences().preferredBrowserTestURL, "https://example.com/")
        for json in ["{}", "{\"preferredBrowserTestURL\":\"\"}", "{\"preferredBrowserTestURL\":\"   \"}"] {
            let preferences = try JSONDecoder().decode(AppPreferences.self, from: Data(json.utf8))
            XCTAssertEqual(preferences.preferredBrowserTestURL, AppPreferences.defaultBrowserTestURL)
        }
        let customized = AppPreferences(preferredBrowserTestURL: "https://custom.test/path")
        let restored = try JSONDecoder().decode(AppPreferences.self, from: JSONEncoder().encode(customized))
        XCTAssertEqual(restored.preferredBrowserTestURL, customized.preferredBrowserTestURL)
    }

    func testInvalidTargetsAreRejectedWithoutCrashing() throws {
        let state = try launch()
        state.config.pacURL = "https://pac.example.test/proxy.pac"
        for target in ["   ", "example.com/path", "http://", "file:///tmp/test", "https://user:password@example.test/"] {
            state.appPreferences.preferredBrowserTestURL = target
            state.refreshPACResolutionPreview()
            XCTAssertEqual(state.pacPreviewMessage, PACResolverError.invalidTargetURL.localizedDescription, target)
            XCTAssertNil(state.pacPreviewTask)
        }
    }

    func testPreviewShowsChainAndCapturesTargetWithOneOperationInFlight() async throws {
        let state = try launch()
        try setScript("function FindProxyForURL(url, host) { return host == 'preview.test' ? 'PROXY proxy.test:8080; DIRECT' : 'DIRECT'; }", on: state)
        state.appPreferences.preferredBrowserTestURL = " https://preview.test/path "
        state.refreshPACResolutionPreview()
        XCTAssertTrue(state.isPACPreviewRunning)
        state.appPreferences.preferredBrowserTestURL = "https://changed.test/"
        state.refreshPACResolutionPreview()
        await state.pacPreviewTask?.value
        XCTAssertFalse(state.isPACPreviewRunning)
        XCTAssertNil(state.pacPreviewTask)
        XCTAssertEqual(state.pacPreviewMessage, "https://preview.test/path: PROXY proxy.test:8080; DIRECT")
        XCTAssertEqual(state.eventLog.events.filter { $0.event == "pac.preview_completed" }.count, 1)
    }

    func testInvalidScriptShowsFailureAndReleasesPreviewSlot() async throws {
        let state = try launch()
        try setScript("function FindProxyForURL( {", on: state)
        state.appPreferences.preferredBrowserTestURL = "https://preview.test/"
        state.refreshPACResolutionPreview()
        await state.pacPreviewTask?.value
        XCTAssertFalse(state.isPACPreviewRunning)
        XCTAssertEqual(state.pacPreviewMessage, state.lastErrorMessage)
        XCTAssertTrue(state.pacPreviewMessage?.contains("evaluation failed") == true)
        XCTAssertTrue(state.eventLog.events.contains {
            $0.event == "pac.preview_failed" && $0.detail == state.pacPreviewMessage
        })
        try setScript("function FindProxyForURL() { return 'DIRECT'; }", on: state)
        state.refreshPACResolutionPreview()
        await state.pacPreviewTask?.value
        XCTAssertEqual(state.pacPreviewMessage, "https://preview.test/: DIRECT")
    }

    private func launch() throws -> AppState {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderPort = 0
        let harness = try AppStateHarness(config: config, platformConfig: PlatformIntegrationConfig())
        self.harness = harness
        return harness.launch()
    }

    private func setScript(_ script: String, on state: AppState) throws {
        let file = harness!.stateDirectory.appendingPathComponent("preview.pac")
        try script.write(to: file, atomically: true, encoding: .utf8)
        state.config.pacURL = file.absoluteString
    }
}
