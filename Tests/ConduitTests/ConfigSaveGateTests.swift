// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import Conduit
@testable import ConduitShared
@testable import PlatformMac
@testable import ProxyControlBridge
@testable import ProxyKernel
import RuntimeEvents

/// The Settings editor's typed notices: the wire write maps back to the domain write case for case, and a notice's per-file detail is the
/// host's own `config.workflow.committed` spelling of that write.
final class ConfigSaveGateNoticeTests: XCTestCase {
    private var everyWrite: [ConfigurationWorkflowWrite] {
        [.persisted(reportedError: false), .persisted(reportedError: true), .unchanged, .notPersisted, .conflict]
            + ConfigurationWorkflowUnknownCause.allCases.flatMap { [.unknown($0, reportedError: false), .unknown($0, reportedError: true)] }
            + ConfigurationWorkflowNotAttemptedCause.allCases.map { .notAttempted($0) }
    }

    func testEveryWriteRoundTripsThroughTheWireCaseForCase() {
        for write in everyWrite {
            XCTAssertEqual(ConfigurationWorkflowWrite(ControlConfigWorkflowWrite(write)), write)
        }
        for file in ConfigurationWorkflowFile.allCases {
            XCTAssertEqual(ConfigurationWorkflowFile(ControlConfigWorkflowFile(file)), file)
        }
    }

    func testAPerFileNoticeSpellsTheWriteAsTheHostsCommittedEventDoes() {
        for write in everyWrite where !ControlConfigWorkflowWrite(write).isVerified {
            let host = ConfigurationWorkflowEvent.committed(ConfigurationWorkflowCommitted(file: .runtime, write: write)).detail
            let notice = SettingsSaveNotice.unverified(.save, .file(.runtime, write), reloadNeeded: false)
            XCTAssertEqual(notice.name, "config.save_unverified")
            XCTAssertEqual(notice.detail, "trigger=save \(host) reload_needed=false")
        }
        XCTAssertEqual(SettingsSaveNotice.rejected(.launchAtLogin, .editorBusy).detail, "file=platform reason=editor_busy")
        XCTAssertEqual(SettingsSaveNotice.rejected(.configuration, .notAdmitted(nil)).detail, "file=runtime,platform reason=not_admitted code=not_sent")
        XCTAssertEqual(
            SettingsSaveNotice.unverified(.quit, .whole(.launchAtLogin, .quitBegan), reloadNeeded: nil).detail,
            "trigger=quit file=platform outcome=not_attempted cause=quit_began"
        )
    }

    /// The login item's own platform write that did not verify is a per-file notice, on its own settle and as the quit's prior (review
    /// ARCH N3); a completion that wrote no file gives none.
    func testAnUnverifiedLoginItemWriteIsAPerFileNotice() throws {
        let revision = try XCTUnwrap(ControlPresentationRevision(rawValue: 1))
        let unverified = ControlOperationOutcome.completed(try ControlCompletion(
            command: .setLaunchAtLogin, presentationRevision: revision,
            result: .platformWrite(try ControlComponentWrite(write: .notPersisted, baseline: nil))
        ))
        let host = ConfigurationWorkflowEvent.committed(ConfigurationWorkflowCommitted(file: .platform, write: .notPersisted)).detail
        for (trigger, reload) in [(SettingsSaveTrigger.save, Bool?.some(false)), (.quitPrior, nil)] {
            let notices = SettingsSaveNotice.unverified(unverified, of: .launchAtLogin, trigger: trigger, reloadNeeded: reload)
            let head = "trigger=\(trigger.rawValue) \(host)"
            XCTAssertEqual(notices.map(\.detail), [reload.map { "\(head) reload_needed=\($0)" } ?? head])
        }
        let noFile = ControlOperationOutcome.completed(try ControlCompletion(command: .stop, presentationRevision: revision, result: .settled))
        XCTAssertTrue(SettingsSaveNotice.unverified(noFile, of: .launchAtLogin, trigger: .save, reloadNeeded: false).isEmpty)
    }
}

/// The save gate on the app's private-update path (decisions 0018, 0023 and 0025). The host's store decides what may be stored, and its
/// own tests pin the refusal events; these pin what the app sends and keeps: a refused save leaves the file and the unsaved edit, a value
/// that blocks a start is saved only and held out of the running proxy, and a credential in a draft reaches no app presentation.
@MainActor
final class ConfigSaveGateTests: XCTestCase {
    private var harness: AppStateHarness!

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private func ready(running: Bool = false, stateFiles: (any StateFileAccessing)? = nil) async throws -> AppState {
        var config = ProxyConfig.testFixture()
        config.localPort = 0
        harness = try AppStateHarness(config: config, platformConfig: PlatformIntegrationConfig())
        if let stateFiles { harness.stateFiles = stateFiles }
        let state = await harness.ready()
        if running {
            state.toggleProxy()
            await harness.settle("the proxy runs") { state.runtime.runtimeStatus.state == .running }
        }
        return state
    }

    /// 1e10 seconds is finite but past the runtime's nanosecond range. The file keeps its bytes and the edit stays unsaved; the refusal is
    /// an event naming the field and the requirement, never the value (review N2).
    func testARefusedSaveKeepsTheFileAndTheEditUnsaved() async throws {
        let state = try await ready()
        let file = harness.environment.configFile
        let before = try Data(contentsOf: file)
        state.config.upstreamResponseTimeoutSeconds = 1e10
        state.saveConfig()
        await state.awaitPendingSave()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(state.hasUnsavedEdit)
        XCTAssertNotNil(state.lastErrorMessage)
        let refusal = try XCTUnwrap(state.eventLog.events.first { $0.event == "config.save_rejected" })
        XCTAssertEqual(refusal.detail, "file=runtime,platform reason=not_storable field=health.upstreamResponseTimeout requirement=runtime_range")
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains("10000000000") })
        XCTAssertFalse(state.lastErrorMessage?.contains("10000000000") ?? true)
    }

    /// A preferences value past its ceiling is refused before anything is sent, by field, like the configuration's (review N2).
    func testAnOverLimitPreferencesValueIsRefusedAsAnEventThatNamesTheField() async throws {
        let state = try await ready()
        let before = try Data(contentsOf: harness.environment.preferencesFile)
        state.appPreferences.preferredBrowserTestURL = "https://value-witness.test/" + String(repeating: "a", count: DomainResourceLimits.urlText)
        state.saveConfig()
        await state.awaitPendingSave()
        XCTAssertEqual(try Data(contentsOf: harness.environment.preferencesFile), before)
        XCTAssertTrue(state.hasUnsavedEdit)
        let refusal = try XCTUnwrap(state.eventLog.events.first { $0.event == "config.save_rejected" })
        XCTAssertEqual(refusal.detail, "file=preferences reason=resource_limit field=browserTestURL limit=\(DomainResourceLimits.urlText)")
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains("value-witness") })

        // At Quit the same ceiling keeps the value out of the final saves: it is discarded, not declared, so the Quit settles without
        // waiting out its deadline for a save that could never be sent.
        XCTAssertTrue(state.beginQuit())
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.completed) = result.quit else { return XCTFail("the Quit settled: \(result.quit)") }
        XCTAssertEqual(result.preferences, .notDeclared)
        let discard = try XCTUnwrap(state.eventLog.events.first { $0.event == "config.edit_discarded" })
        XCTAssertEqual(discard.detail, "trigger=quit reason=resource_limit field=browserTestURL limit=\(DomainResourceLimits.urlText)")
        XCTAssertEqual(try Data(contentsOf: harness.environment.preferencesFile), before)
    }

    /// A write the destination refuses keeps the edit unsaved and the file's authority, so no reload is asked for; once the destination is
    /// repaired, the next commit (leaving the section) writes the same draft, its own receipt cleans it, and the banner the failure showed
    /// is cleared. For each file the edit writes: the store writes the platform file first, so a refused platform write leaves the runtime
    /// file unwritten too.
    func testAFailedWriteKeepsTheEditUnsavedUntilACommitAfterTheRepairWritesIt() async throws {
        for role in [StateRootRole.config, .platformConfig] {
            // Scoped, so the app is gone before the teardown proves the root free.
            do {
                let refusing = RefusingWrites(of: role)
                let state = try await ready(stateFiles: refusing)
                let refused = role == .config ? harness.environment.configFile : harness.environment.platformConfigFile
                let before = try Data(contentsOf: refused)
                state.config.noProxyHosts.append("retry.example")
                state.platformConfig.manageEnvironmentVariables = true
                state.commitPendingEdit(trigger: .submit)
                await state.awaitPendingSave()
                XCTAssertEqual(try Data(contentsOf: refused), before, "\(role)")
                XCTAssertTrue(state.hasUnsavedEdit, "\(role): the write failed, so the edit is not saved")
                XCTAssertTrue(state.lastErrorMessage?.hasPrefix("Settings were not saved") == true, "\(role)")
                XCTAssertFalse(state.configurationNeedsReload, "\(role): a write proven not to have happened keeps the file's authority")

                refusing.refusing = false
                state.commitPendingEdit(trigger: .sectionClose)
                await state.awaitPendingSave()
                XCTAssertFalse(state.hasUnsavedEdit, "\(role)")
                XCTAssertTrue(try ProxyConfigPersistence.load(from: harness.environment.configFile).noProxyHosts.contains("retry.example"))
                XCTAssertTrue(try PlatformConfigPersistence.load(in: harness.environment).manageEnvironmentVariables)
                XCTAssertNil(state.lastErrorMessage, "\(role): the verified retry cleared the failure's banner")
            }
            await harness.tearDown()
            harness = nil
        }
    }

    /// At quit, a runtime draft the store's staging refuses (a 90.5-second TTL, which validates but is not whole minutes) gives way to the
    /// last saved runtime value, so the platform edit beside it is still written and the runtime file keeps its bytes (review N3).
    func testQuitWritesThePlatformEditBesideARuntimeDraftTheFileCannotHold() async throws {
        let state = try await ready()
        let runtimeBytes = try Data(contentsOf: harness.environment.configFile)
        state.config.health.directConnectTTL = 90.5
        XCTAssertTrue(state.config.startBlockingProblems.isEmpty, "it blocks no start")
        state.platformConfig.manageEnvironmentVariables = true
        XCTAssertTrue(state.beginQuit())
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.configurationSettled(let receipt)) = result.configuration else {
            return XCTFail("the final save settled: \(result.configuration)")
        }
        XCTAssertTrue(receipt.platform.write.isVerified)
        XCTAssertTrue(try PlatformConfigPersistence.load(in: harness.environment).manageEnvironmentVariables)
        XCTAssertEqual(try Data(contentsOf: harness.environment.configFile), runtimeBytes)
        XCTAssertTrue(state.eventLog.events.contains {
            $0.event == "config.edit_discarded" && $0.detail == "trigger=quit reason=not_storable field=health.directConnectTTL requirement=whole_minutes"
        })
        XCTAssertFalse(state.eventLog.events.contains { $0.event == "config.edit_committed" && ($0.detail ?? "").contains("trigger=quit") })
    }

    /// A bypass list past its approved ceiling (decision 0021) is refused before anything is sent: the refusal is an event naming the
    /// field and the ceiling, never a value; the file keeps its bytes and the edit stays unsaved.
    func testAnOverLimitBypassListIsRefusedAsAnEventThatNamesTheFieldNotTheValue() async throws {
        let state = try await ready()
        let file = harness.environment.configFile
        let before = try Data(contentsOf: file)
        state.config.noProxyHosts = (0...DomainResourceLimits.noProxyHosts).map { "bypass-\($0).value-witness.test" }
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertEqual(try Data(contentsOf: file), before)
        XCTAssertTrue(state.hasUnsavedEdit)
        let refusal = try XCTUnwrap(state.eventLog.events.first { $0.event == "config.save_rejected" })
        let detail = try XCTUnwrap(refusal.detail)
        XCTAssertTrue(detail.hasPrefix("file=runtime,platform reason=resource_limit field="), detail)
        XCTAssertTrue(detail.hasSuffix(" limit=\(DomainResourceLimits.noProxyHosts)"), detail)
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains("value-witness") })
        XCTAssertFalse(state.logStore.exportDiagnosticLog().contains("value-witness"))
    }

    /// At quit, a runtime draft past an approved ceiling gives way to the last saved runtime value, as a start-blocking one does, so the
    /// platform edit beside it is still written (review M6); the discard is an event, before the write.
    func testQuitWritesThePlatformEditBesideAnOverLimitRuntimeDraft() async throws {
        let state = try await ready()
        let saved = try ProxyConfigPersistence.load(from: harness.environment.configFile)
        state.config.noProxyHosts = (0...DomainResourceLimits.noProxyHosts).map { "bypass-\($0).value-witness.test" }
        state.platformConfig.manageEnvironmentVariables = true
        XCTAssertTrue(state.beginQuit())
        let finished = await state.finishQuit()
        let result = try XCTUnwrap(finished)
        guard case .settled(.configurationSettled(let receipt)) = result.configuration else {
            return XCTFail("the final save settled: \(result.configuration)")
        }
        XCTAssertTrue(receipt.platform.write.isVerified)
        XCTAssertTrue(try PlatformConfigPersistence.load(in: harness.environment).manageEnvironmentVariables)
        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).noProxyHosts, saved.noProxyHosts)
        XCTAssertTrue(state.eventLog.events.contains { $0.event == "config.edit_discarded" && ($0.detail ?? "").contains("trigger=quit reason=") })
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains("value-witness") })
    }

    /// A value that blocks a start is written, as a commit always was, but saved only: the running proxy keeps its listener, and
    /// `config.apply_held` says why.
    func testABlockingCommitIsSavedOnlyAndTheRunningProxyKeepsItsListener() async throws {
        let state = try await ready(running: true)
        let port = try XCTUnwrap(state.runtime.bindings.proxyPort)
        state.config.proxy.port = 70_000
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).proxy.port, 70_000)
        let held = state.eventLog.events.filter { $0.event == "config.apply_held" }
        XCTAssertEqual(held.count, 1)
        XCTAssertTrue(held.first?.detail?.contains("invalid_port field=proxy.port") ?? false)
        XCTAssertEqual(state.runtime.runtimeStatus.state, .running)
        XCTAssertEqual(state.runtime.bindings.proxyPort, port, "nothing applied the held value")
        XCTAssertFalse(state.hasUnsavedEdit, "its own receipt saved it")
    }

    /// A valid commit while the proxy runs carries no gate event.
    func testAValidCommitSavesWithoutAGateEvent() async throws {
        let state = try await ready(running: true)
        state.config.health.checkInterval = 47
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        XCTAssertEqual(try ProxyConfigPersistence.load(from: harness.environment.configFile).health.checkInterval, 47)
        XCTAssertTrue(state.eventLog.events.allSatisfy { $0.event != "config.apply_held" })
        XCTAssertFalse(state.hasUnsavedEdit)
    }

    /// A draft with a URL credential is held, and the credential appears in no app surface: the banner, the log or the app's events.
    /// The banner and the log are populated, so the absence is not vacuous.
    func testAUserInfoDraftsCredentialIsAbsentFromEveryAppPresentation() async throws {
        let state = try await ready()
        state.config.routing.pacURL = "https://user:TOKEN-GATE-3@pac.example.test/p.pac"
        state.commitPendingEdit(trigger: .submit)
        await state.awaitPendingSave()
        let banner = try XCTUnwrap(state.lastErrorMessage, "the save shows the problem")
        XCTAssertTrue(banner.contains("routing.pacURL"))
        XCTAssertFalse(banner.contains("TOKEN-GATE-3"))
        let log = state.logStore.exportDiagnosticLog()
        XCTAssertTrue(log.contains("Config validation: routing.pacURL"), "the validation line reached the log")
        XCTAssertFalse(log.contains("TOKEN-GATE-3"))
        XCTAssertFalse(state.eventLog.events.contains { ($0.detail ?? "").contains("TOKEN-GATE-3") })
    }
}
