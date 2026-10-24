// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import Conduit
@testable import ProxyKernel

/// The sidecar refusal as the app presents it (decision 0026), on a real `AppState` over the harness's scratch directories and
/// fake machine. A refused preferences save does not veto the runtime save or its apply, and the banner, the events and the log
/// name the file and the field, never the private URL. A refused startup sidecar blocks every save and keeps its bytes.
@MainActor
final class AppStateHarnessSidecarRefusalTests: XCTestCase {
    private var harness: AppStateHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// A browser URL past its raw limit. The marker must never reach a banner, an event or the log.
    private let privateMarker = "PREF-SIDECAR-SECRET"

    private var oversizedURL: String {
        "https://user:\(privateMarker)@preferences.example.test/" + String(repeating: "p", count: DomainResourceLimits.urlText)
    }

    func testARefusedPreferencesSaveKeepsTheRuntimeSaveAndApplyAndNamesOnlyTheFile() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        let preferencesBefore = try Data(contentsOf: harness.environment.preferencesFile)

        state.appPreferences.preferredBrowserTestURL = oversizedURL
        state.config.health.checkInterval = 47
        state.scheduleSave()
        state.saveConfig()

        // The runtime file is written and applied, so the refused preferences do not veto it.
        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).health.checkInterval, 47)
        XCTAssertEqual(state.reconciler.requestedConfig, state.config)
        // The preferences file keeps its previous bytes, and the edit stays unsaved so a later save or quit retries it.
        XCTAssertEqual(try Data(contentsOf: harness.environment.preferencesFile), preferencesBefore)
        XCTAssertTrue(state.hasUnsavedEdit)

        let banner = try XCTUnwrap(state.lastErrorMessage, "the refused save shows a banner")
        XCTAssertTrue(banner.contains("the app preferences"), banner)
        XCTAssertTrue(banner.contains("browserTestURL"), banner)
        XCTAssertFalse(banner.contains(privateMarker), banner)
        let rejected = state.eventLog.events.filter { $0.event == "config.save_rejected" }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected.first?.detail?.contains("browserTestURL") ?? false)
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains(privateMarker) })
        XCTAssertFalse(state.logStore.exportDiagnosticLog().contains(privateMarker))
    }

    func testARefusedStartupPreferencesSidecarBlocksEverySaveAndKeepsItsBytes() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let sidecar = Data(#"{"preferredBrowserTestURL":""#.utf8) + Data(oversizedURL.utf8) + Data(#""}"#.utf8)
        try sidecar.write(to: harness.environment.preferencesFile)
        let runtimeBefore = try Data(contentsOf: harness.environment.configFile)

        let state = harness.launch()

        let banner = try XCTUnwrap(state.lastErrorMessage, "the refused load shows a banner")
        XCTAssertTrue(banner.contains("preferences.json"), banner)
        XCTAssertTrue(banner.contains("resource limit"), banner)
        XCTAssertFalse(banner.contains(privateMarker), banner)

        state.config.health.checkInterval = 47
        state.saveConfig()
        XCTAssertEqual(try Data(contentsOf: harness.environment.preferencesFile), sidecar, "the rejected sidecar keeps its bytes")
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), runtimeBefore, "no save reaches the runtime file")
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains(privateMarker) })
    }
}
