// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import Conduit
@testable import ConduitShared
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The save gate in `AppState.saveConfig` (decision 0023). A save the file
/// refuses, or a value that blocks a proxy start, is not reconciled: the
/// reconciler's requested config stays the one last applied, so the runtime
/// keeps it. Quit still writes the platform flags after a refused runtime save.
/// Runs on a real `AppState` over the harness's scratch directories and fake
/// machine; no real configuration is read or changed.
@MainActor
final class ConfigSaveGateTests: XCTestCase {
    private var harness: AppStateHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    /// 1e10 seconds is finite but past the runtime's nanosecond range. The save
    /// is refused by field, the file keeps its bytes, the runtime is not
    /// reconciled, and the event names the field and not the value.
    func testRefusedSaveIsNotReconciledAndEmitsSaveRejected() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        let applied = state.reconciler.requestedConfig
        let file = harness.environment.configFile
        let before = try XCTUnwrap(try? Data(contentsOf: file), "the harness writes the config file")

        state.config.upstreamResponseTimeoutSeconds = 1e10
        state.saveConfig()

        XCTAssertEqual(state.reconciler.requestedConfig, applied)
        XCTAssertEqual(try Data(contentsOf: file), before)
        let rejected = state.eventLog.events.filter { $0.event == "config.save_rejected" }
        XCTAssertEqual(rejected.count, 1)
        XCTAssertTrue(rejected.first?.detail?.contains("health.upstreamResponseTimeout") ?? false)
        XCTAssertFalse(rejected.first?.detail?.contains("10000000000") ?? true)
        XCTAssertNotNil(state.lastErrorMessage)
    }

    /// A value that blocks a start is written, as a commit always was, but the
    /// runtime is not reconciled to it, and `config.apply_held` says why.
    func testBlockingCommitIsWrittenButHeldOutOfTheRuntime() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        let applied = state.reconciler.requestedConfig

        state.config.proxy.port = 70_000
        state.saveConfig()

        XCTAssertEqual(state.reconciler.requestedConfig, applied)
        XCTAssertEqual(state.eventLog.events.filter { $0.event == "config.apply_held" }.count, 1)
        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).proxy.port, 70_000)
    }

    /// The gate does not hold a valid commit: it is reconciled, and no gate event
    /// is emitted.
    func testValidCommitIsReconciledWithoutAGateEvent() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()

        state.config.health.checkInterval = 47
        state.saveConfig()

        XCTAssertEqual(state.reconciler.requestedConfig, state.config)
        XCTAssertTrue(state.eventLog.events.allSatisfy { $0.event != "config.save_rejected" && $0.event != "config.apply_held" })
    }

    /// A persisted value the runtime cannot hold (written past the save's refusal, as an
    /// older build or a hand edit could) loads at launch. The app then refuses to start the
    /// proxy or the tunnels on it, by field, and applies no system proxy. Driven through the
    /// app's real launch and start entry points.
    func testLaunchWithAPersistedUnholdableDurationRefusesToStartTheRuntime() async throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        var persisted = ProxyConfig.testFixture()
        persisted.health.upstreamResponseTimeout = 1e10
        persisted.tunnelDefinitions = [
            TunnelDefinition(localPort: 0, remoteHost: "db.example.test", remotePort: 5432, enabled: true),
        ]
        try CanonicalJSON.encoder(prettyPrinted: true).encode(persisted).write(to: harness.environment.configFile)
        let state = harness.launch()

        _ = try? await state.startProxy()
        await state.startTunnels()

        XCTAssertTrue(state.runtimeSnapshot.tunnelsError?.contains("health.upstreamResponseTimeout") ?? false)
        XCTAssertTrue(state.eventLog.events.contains {
            $0.event == "config.duration_refused" && $0.detail == "scope=tunnels field=health.upstreamResponseTimeout"
        })
        XCTAssertTrue(harness.machine.privilege.commands(matching: .setWebProxyEndpoint).isEmpty)
    }

    /// A platform write that fails after the config was written leaves the edit unsaved. The
    /// config on disk is the new one, and a commit after the destination is repaired writes the
    /// missing platform file and clears the flag.
    func testPlatformWriteFailureKeepsTheEditUnsavedUntilACommitRetriesIt() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let state = harness.launch()
        let destination = harness.environment.platformConfigFile
        try blockWrites(to: destination)

        state.config.health.checkInterval = 47
        state.platformConfig.manageSystemProxy = false
        state.scheduleSave()
        state.saveConfig()

        XCTAssertTrue(state.hasUnsavedEdit, "the platform write failed, so the edit is not saved")
        XCTAssertNotNil(state.lastErrorMessage)
        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).health.checkInterval, 47)

        try repairWrites(to: destination)
        state.flushPendingSave()

        XCTAssertFalse(state.hasUnsavedEdit)
        XCTAssertFalse(try PlatformConfigPersistence.load(in: harness.environment).manageSystemProxy)
    }

    /// The same contract for the preferences file: the failed write keeps the edit unsaved, and
    /// quit retries it once the destination is repaired.
    func testPreferencesWriteFailureKeepsTheEditUnsavedUntilQuitRetriesIt() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        let destination = harness.environment.preferencesFile
        try blockWrites(to: destination)

        state.config.health.checkInterval = 47
        state.scheduleSave()
        state.saveConfig()

        XCTAssertTrue(state.hasUnsavedEdit, "the preferences write failed, so the edit is not saved")
        XCTAssertNotNil(state.lastErrorMessage)

        try repairWrites(to: destination)
        state.persistPendingEditForTermination()

        XCTAssertFalse(state.hasUnsavedEdit)
        _ = try AppPreferencesPersistence.load(in: harness.environment)
    }

    /// Quit writes what it can. A 90.5-second TTL passes validation and is refused
    /// by the save; the platform flag is still written, and the config file keeps
    /// its bytes.
    func testQuitWritesThePlatformFlagWhenTheRuntimeSaveIsRefused() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let state = harness.launch()
        let file = harness.environment.configFile
        let before = try XCTUnwrap(try? Data(contentsOf: file), "the harness writes the config file")

        state.config.health.directConnectTTL = 90.5
        state.platformConfig.manageSystemProxy = false
        state.scheduleSave()
        state.persistPendingEditForTermination()

        XCTAssertFalse(try PlatformConfigPersistence.load(in: harness.environment).manageSystemProxy)
        XCTAssertEqual(try Data(contentsOf: file), before)
    }

    /// Quit does not write a start-blocking draft, as before. The platform flag,
    /// which validation does not cover, is still written.
    func testQuitDoesNotWriteABlockingDraftButStillWritesThePlatformFlag() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig(manageSystemProxy: true))
        let state = harness.launch()
        let file = harness.environment.configFile
        let before = try XCTUnwrap(try? Data(contentsOf: file), "the harness writes the config file")

        state.config.proxy.port = 70_000
        state.platformConfig.manageSystemProxy = false
        state.scheduleSave()
        state.persistPendingEditForTermination()

        XCTAssertFalse(try PlatformConfigPersistence.load(in: harness.environment).manageSystemProxy)
        XCTAssertEqual(try Data(contentsOf: file), before)
        // The discarded config is not saved, so the edit stays unsaved even though the platform write succeeded.
        XCTAssertTrue(state.hasUnsavedEdit)
    }

    /// An out-of-range port that crossed the private transfer is saved to the file and held from the runtime.
    /// This is the Settings repair baseline through the real save gate: the draft is persisted, the apply is
    /// held, and no save is rejected.
    func testMappedOutOfRangePortIsSavedAndHeldOutOfTheRuntime() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        let applied = state.reconciler.requestedConfig
        var draft = state.config
        draft.proxy.port = 70_000
        state.config = try mappedDraft(draft)

        state.saveConfig()

        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).proxy.port, 70_000)
        XCTAssertEqual(state.reconciler.requestedConfig, applied)
        let held = state.eventLog.events.filter { $0.event == "config.apply_held" }
        XCTAssertEqual(held.count, 1)
        XCTAssertTrue(held.first?.detail?.contains("invalid_port field=proxy.port") ?? false)
        XCTAssertFalse(state.eventLog.events.contains { $0.event == "config.save_rejected" })
    }

    /// A non-blocking intercept problem does not hold the apply. The draft saves and reconciles together with an
    /// unrelated runtime edit from the same save. It stays inside every resource cap; a bypass problem cannot,
    /// since each one is a resource refusal (see the bridge test).
    func testMappedNonBlockingDraftSavesAndReconcilesUnrelatedProgress() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        var draft = state.config
        draft.dns.interceptRules = [
            DNSInterceptRule(id: UUID(), pattern: "not a domain!!", interceptIP: "not-an-ip", enabled: true),
        ]
        draft.health.checkInterval = 47
        state.config = try mappedDraft(draft)

        state.saveConfig()

        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).health.checkInterval, 47)
        XCTAssertEqual(state.reconciler.requestedConfig, state.config)
        XCTAssertTrue(state.eventLog.events.allSatisfy { $0.event != "config.apply_held" && $0.event != "config.save_rejected" })
    }

    /// A draft with a URL credential is held, and the credential appears in no surface the save writes:
    /// the banner, the validation log, or the events. The banner and the log must be populated, so the
    /// absence is not vacuous.
    func testMappedUserInfoDraftIsHeldAndItsCredentialIsAbsentFromEveryPresentation() throws {
        harness = try AppStateHarness(config: ProxyConfig.testFixture(), platformConfig: PlatformIntegrationConfig())
        let state = harness.launch()
        let applied = state.reconciler.requestedConfig
        var draft = state.config
        draft.routing.pacURL = "https://user:TOKEN-GATE-3@pac.example.test/p.pac"
        state.config = try mappedDraft(draft)

        state.saveConfig()

        XCTAssertEqual(state.reconciler.requestedConfig, applied)
        XCTAssertEqual(state.eventLog.events.filter { $0.event == "config.apply_held" }.count, 1)
        let banner = try XCTUnwrap(state.lastErrorMessage, "the save shows the problem")
        XCTAssertTrue(banner.contains("routing.pacURL"))
        XCTAssertFalse(banner.contains("TOKEN-GATE-3"))
        let log = state.logStore.exportDiagnosticLog()
        XCTAssertTrue(log.contains("Config validation: routing.pacURL"), "the validation line reached the log")
        XCTAssertFalse(log.contains("TOKEN-GATE-3"))
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains("TOKEN-GATE-3") })
    }

    /// The draft as the private bridge carries it: its request framed, read back through the real reader,
    /// decoded and mapped to values. The gate sees what a transfer would deliver.
    private func mappedDraft(_ draft: ProxyConfig) throws -> ProxyConfig {
        let request = try PrivateConfigurationBridge.makeRequest(
            config: draft,
            platform: PlatformIntegrationConfig(),
            requestID: ControlRequestID(rawValue: UUID()),
            incarnation: ControlHostIncarnation(rawValue: UUID()),
            budget: try ControlWireBudget(5_000),
            expectedConfigRevision: try XCTUnwrap(ControlConfigRevision(rawValue: 7)),
            expectedPlatformRevision: try XCTUnwrap(PrivatePlatformRevision(rawValue: 6)),
            expectedOwnerGeneration: try XCTUnwrap(PrivateConfigExpectedGeneration(rawValue: 5))
        )
        let frame = try PrivateConfigurationEncoder.encode(request).bytes()
        let reader = PrivateConfigurationFrameReader()
        guard case .frame(let body) = try reader.consume(frame).step else {
            throw PrivateConfigurationWireError.malformedBody
        }
        let decoded = try PrivateConfigurationDecoder.decode(body)
        return try PrivateConfigurationBridge.makeValues(from: decoded, localLaunchAtLogin: false).config
    }

    /// Makes a destination unwritable: a directory sits where the file goes. It is called after
    /// launch, so the launch's own reads are unaffected.
    private func blockWrites(to destination: URL) throws {
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    }

    /// Removes the blocking directory, so the next write can create the file.
    private func repairWrites(to destination: URL) throws {
        try FileManager.default.removeItem(at: destination)
    }
}
