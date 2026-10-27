// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import XCTest
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// The private editor's memory observation over the actual workflow and store (decisions 0032 and 0034): one owner turn, no disk I/O,
/// the store's values with each component's exact baseline or its closed retained reason, and the module intents. The reasons are the
/// store's own latches, recorded where each baseline was cleared.
@MainActor
final class ConfigurationEditorCaptureTests: XCTestCase {
    private typealias Fixture = ConfigurationStoreTests.Fixture

    private func preferences(showMenuBarIcon: Bool) throws -> Data {
        var preferences = AppPreferences()
        preferences.showMenuBarIcon = showMenuBarIcon
        return try AppPreferencesPersistence.stagedData(for: preferences)
    }

    private func opened(
        _ fixture: Fixture,
        incarnation: ControlHostIncarnation = ControlHostIncarnation(rawValue: UUID())
    ) async throws -> RuntimeConfigurationWorkflow {
        let workflow = RuntimeConfigurationWorkflow(store: fixture.store, incarnation: incarnation, startupAllowsMissing: true)
        _ = try await workflow.open()
        return workflow
    }

    private func reads(_ fixture: Fixture) -> Int {
        fixture.access.observations.filter { if case .read = $0 { true } else { false } }.count
    }

    private static let context = ConfigurationOperationContext(
        requestID: ControlRequestID(rawValue: UUID()),
        hostIncarnation: ControlHostIncarnation(rawValue: UUID()),
        expectedOwnerGeneration: PrivateConfigExpectedGeneration(rawValue: 1)!
    )

    /// An opened store's capture names each present file's exact token as a verified baseline and a missing sidecar's as an absence, with
    /// the module intents at their first revision. It reads no file, and it maps through the one bridge.
    func testACaptureNamesEachExactBaselineAndReadsNoFile() async throws {
        let fixture = try Fixture(preferences: try preferences(showMenuBarIcon: false))
        defer { fixture.close() }
        let workflow = try await opened(fixture)
        let before = reads(fixture)

        let capture = workflow.editorCapture()
        XCTAssertEqual(reads(fixture), before, "a capture reads no file")
        for (component, file) in [(ConfigurationComponent.runtime, ControlConfigWorkflowFile.runtime), (.platform, .platform),
                                  (.preferences, .preferences)] {
            let token = try XCTUnwrap(fixture.store.baselineToken(for: component))
            let baseline = PrivateBaseline(namespace: PrivateBaselineNamespace(rawValue: token.storeIncarnation), component: file,
                                           version: token.version)
            let expected: PrivateComponentState = fixture.store.isPresent(component) ? .verified(baseline) : .absent(baseline)
            XCTAssertEqual(capture.components[file], expected)
        }
        guard case .absent = capture.components.platform else {
            return XCTFail("the platform sidecar was not seeded, so its baseline is an observed absence")
        }
        XCTAssertEqual(capture.modules.dns, PrivateModuleState(
            lifecycleRevision: ControlLifecycleRevision(rawValue: 0)!, enabled: capture.values.runtime.dnsForwarderEnabled, fenced: false
        ))
        XCTAssertFalse(capture.terminal)
        XCTAssertEqual(capture.values.preferences.showMenuBarIcon, false)

        let observation = try capture.observation()
        XCTAssertEqual(observation.components, capture.components)
        XCTAssertEqual(observation.launchAtLogin, capture.values.platform.launchAtLogin)
    }

    /// A conflicting write retains only its own component, with the closed `changedSinceBaseline`, and a reload gives it a newer baseline.
    func testAConflictRetainsOnlyItsComponentUntilAReload() async throws {
        let fixture = try Fixture(preferences: try preferences(showMenuBarIcon: true))
        defer { fixture.close() }
        let workflow = try await opened(fixture)
        let old = try XCTUnwrap(workflow.editorCapture().components.preferences.baseline)

        fixture.access.externalEdit(.replace(try preferences(showMenuBarIcon: false)), at: fixture.plan.preferences.path)
        let token = fixture.store.baselineToken(for: .preferences)
        guard case .admitted(let result) = await fixture.store.commitPreferences(AppPreferences(), expecting: token, context: Self.context)
        else { return XCTFail("the commit was not admitted") }
        XCTAssertEqual(result.preferences, .conflict)
        let latched = workflow.editorCapture()
        XCTAssertEqual(latched.components.preferences, .retained(.changedSinceBaseline))
        XCTAssertNotNil(latched.components.runtime.baseline, "the other components keep their baselines")
        XCTAssertEqual(latched.values.preferences.showMenuBarIcon, true, "the retained values are the last the store verified")

        _ = await workflow.reload(capturedAt: workflow.generation)
        let reloaded = try XCTUnwrap(workflow.editorCapture().components.preferences.baseline)
        XCTAssertGreaterThan(reloaded.version, old.version, "a reload after a latch takes a newer version")
    }

    /// A write whose read-back cannot say what landed retains its component as `writeUnknown`.
    func testAnUnknownWriteRetainsItsComponentAsWriteUnknown() async throws {
        let fixture = try Fixture(preferences: try preferences(showMenuBarIcon: true))
        defer { fixture.close() }
        let workflow = try await opened(fixture)
        fixture.access.scheduleWrites([.init(landing: .lands, editAfterWrite: .replace(Data("other".utf8)))])
        var changed = AppPreferences()
        changed.showMenuBarIcon = false
        guard case .admitted(let result) = await fixture.store.commitPreferences(
            changed, expecting: fixture.store.baselineToken(for: .preferences), context: Self.context
        ) else { return XCTFail("the commit was not admitted") }
        guard case .unknown = result.preferences else { return XCTFail("the write was not unknown: \(result.preferences)") }
        XCTAssertEqual(workflow.editorCapture().components.preferences, .retained(.writeUnknown))
    }

    /// A refused reload retains every component as `observationRefused` and keeps the last adopted values for display.
    func testARefusedReloadRetainsEveryComponentAndKeepsTheLastValues() async throws {
        let fixture = try Fixture(preferences: try preferences(showMenuBarIcon: false))
        defer { fixture.close() }
        let workflow = try await opened(fixture)
        let before = workflow.editorCapture()

        fixture.access.externalEdit(.replace(Data("not json".utf8)), at: fixture.plan.config.path)
        _ = await workflow.reload(capturedAt: workflow.generation)
        let refused = workflow.editorCapture()
        XCTAssertEqual(refused.components, PrivateComponentSlots(
            runtime: .retained(.observationRefused), platform: .retained(.observationRefused), preferences: .retained(.observationRefused)
        ))
        XCTAssertEqual(refused.values.preferences, before.values.preferences)
        XCTAssertEqual(refused.values.runtime, before.values.runtime)
    }

    /// A client's request ID follows its Start into the store, and the store context names the host's incarnation: both receipts of the
    /// prepared pair carry them. The host's own facade, which has no client request, names a fresh ID instead.
    func testAClientRequestAndTheHostIncarnationReachTheStartsCommitReceipts() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let incarnation = ControlHostIncarnation(rawValue: UUID())
        let workflow = try await opened(fixture, incarnation: incarnation)
        let request = ControlRequestID(rawValue: UUID())

        let ticket = try workflow.admitStart(PrivateModuleSlots(proxy: .start, dns: .none, tunnels: .none), requestID: request).get()
        guard case .ready(let prepared) = await workflow.prepareStart(ticket).preparation else {
            return XCTFail("the Start's required defaults verified")
        }
        for receipt in [prepared.input.runtimeReceipt, prepared.input.platformReceipt] {
            XCTAssertEqual(receipt.context.requestID, request)
            XCTAssertEqual(receipt.context.hostIncarnation, incarnation)
        }

        let facade = try workflow.admitStart().get()
        guard case .ready(let facadePrepared) = await workflow.prepareStart(facade).preparation else {
            return XCTFail("the facade Start verified")
        }
        XCTAssertNotEqual(facadePrepared.input.runtimeReceipt.context.requestID, request)
        XCTAssertEqual(facadePrepared.input.runtimeReceipt.context.hostIncarnation, incarnation)
    }

    /// A session DNS Stop's fence is in the next capture, at the revision its admission took, with no store work.
    func testAStopFenceIsInTheNextCapture() async throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let workflow = try await opened(fixture)
        let revision = workflow.admitStop([.dns], reason: .session)
        let capture = workflow.editorCapture()
        XCTAssertEqual(capture.modules.dns.lifecycleRevision.rawValue, revision)
        XCTAssertTrue(capture.modules.dns.fenced)
        XCTAssertFalse(capture.modules.dns.enabled)
        XCTAssertFalse(capture.modules.proxy.fenced, "a DNS Stop fences only DNS")
    }
}
