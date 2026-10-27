// SPDX-License-Identifier: Apache-2.0
import ConduitShared
import Foundation
import PlatformMac
import XCTest
@testable import ConduitRuntime
@testable import ProxyKernel

/// Decision 0037 over the actual workflow and store. The reference tracks symbolic saved pairs and a latched invalidation; it knows no
/// store receipt, version or production transition. Exhausts 93 histories (three before-capture pairs, then every trace of up to two
/// reload/Stop/Start operations), including changed-then-restored bytes. Physical bind/surface ordering is outside this model.
@MainActor
final class ConfigurationCaptureModelTests: XCTestCase {
    private enum Pair: String, CaseIterable {
        case original, runtimeEdit, platformEdit
    }

    private enum Step: String, CaseIterable {
        case reloadOriginal, reloadRuntimeEdit, reloadPlatformEdit, stop, newerStart

        var observation: Pair? {
            switch self {
            case .reloadOriginal: .original
            case .reloadRuntimeEdit: .runtimeEdit
            case .reloadPlatformEdit: .platformEdit
            case .stop, .newerStart: nil
            }
        }
    }

    private struct Reference {
        let captured: Pair
        var observed: Pair
        var replaced = false
        var superseded = false

        mutating func take(_ step: Step) {
            if let next = step.observation {
                if next != observed { replaced = true }
                observed = next
            } else {
                superseded = true
            }
        }

        var mayAuthorize: Bool { !replaced && !superseded }
    }

    private struct Bytes {
        let runtime: Data
        let platform: Data
    }

    func testBoundedCaptureHistoriesAgreeWithAnIndependentReference() async throws {
        let fixtures = try Dictionary(uniqueKeysWithValues: Pair.allCases.map { pair in
            (pair, try bytes(for: pair))
        })
        let histories = Self.histories()
        XCTAssertEqual(histories.count, 31)
        var explored = 0
        var transitions = 0
        var restoredAfterReplacement = 0
        for beforeCapture in Pair.allCases {
            for history in histories {
                let rewound = try await exercise(beforeCapture, history, fixtures: fixtures)
                explored += 1
                transitions += history.count
                if rewound { restoredAfterReplacement += 1 }
            }
        }
        XCTAssertEqual(explored, 93)
        XCTAssertEqual(transitions, 165)
        XCTAssertEqual(restoredAfterReplacement, 6, "returning to the captured bytes never revives an invalidated command")
    }

    private func exercise(_ beforeCapture: Pair, _ history: [Step], fixtures: [Pair: Bytes]) async throws -> Bool {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-capture-model-\(UUID().uuidString)")
        let environment = RuntimeEnvironment.isolated(stateDirectory: directory)
        let session = try acquireScratchStateRoot(environment)
        defer {
            releaseScratchStateRoot(session)
            removeScratch([directory])
        }
        try install(fixtures[.original]!, in: environment)
        try AppPreferencesPersistence.save(AppPreferences(), in: environment)
        let store = ConfigurationStore(session: session, access: StateFileAccess.operatingSystem(), work: PlatformWork(label: "test.capture-model"))
        let workflow = RuntimeConfigurationWorkflow(store: store, incarnation: ControlHostIncarnation(rawValue: UUID()), startupAllowsMissing: true)
        _ = try await workflow.open()
        let queued = try workflow.admitStart().get()
        try install(fixtures[beforeCapture]!, in: environment)
        _ = await workflow.reload(capturedAt: workflow.generation)
        let trace = "before=\(beforeCapture.rawValue) after=\(history.map(\.rawValue))"
        guard case .ready(let prepared) = await workflow.prepareStart(queued).preparation else {
            XCTFail("\(trace): preparation should use the latest observed pair")
            return false
        }
        XCTAssertEqual(prepared.input.runtime.profileName, beforeCapture == .runtimeEdit ? "B" : "A", trace)
        XCTAssertEqual(prepared.input.platform.manageEnvironmentVariables, beforeCapture == .platformEdit, trace)
        var reference = Reference(captured: beforeCapture, observed: beforeCapture)
        for step in history {
            reference.take(step)
            if let observation = step.observation {
                try install(fixtures[observation]!, in: environment)
                _ = await workflow.reload(capturedAt: workflow.generation)
            } else if step == .stop {
                workflow.admitStop()
            } else {
                _ = try workflow.admitStart().get()
            }
            XCTAssertEqual(workflow.isCurrent(prepared), reference.mayAuthorize, "\(trace) at \(step)")
            let observed = fixtures[reference.observed]!
            XCTAssertEqual(try Data(contentsOf: environment.configFile), observed.runtime, "\(trace): preserve the runtime observation")
            XCTAssertEqual(try Data(contentsOf: environment.platformConfigFile), observed.platform, "\(trace): preserve the platform observation")
        }
        XCTAssertEqual(workflow.authorize(prepared), reference.mayAuthorize, trace)
        XCTAssertTrue(workflow.isIdle, "all physical store work completed before releasing the root")
        return reference.replaced && reference.observed == reference.captured && !reference.superseded
    }

    private func bytes(for pair: Pair) throws -> Bytes {
        var runtime = GenericDefaults.shared.makeConfig()
        runtime.profileName = pair == .runtimeEdit ? "B" : "A"
        runtime.dnsForwarderEnabled = false
        let platform = PlatformIntegrationConfig(manageEnvironmentVariables: pair == .platformEdit)
        return Bytes(runtime: try ProxyConfigPersistence.stagedFileData(for: runtime), platform: try PlatformConfigPersistence.stagedData(for: platform))
    }

    private func install(_ bytes: Bytes, in environment: RuntimeEnvironment) throws {
        try bytes.runtime.write(to: environment.configFile)
        try bytes.platform.write(to: environment.platformConfigFile)
    }

    private static func histories() -> [[Step]] {
        let one = Step.allCases.map { [$0] }
        let two = one.flatMap { prefix in Step.allCases.map { prefix + [$0] } }
        return [[]] + one + two
    }
}
