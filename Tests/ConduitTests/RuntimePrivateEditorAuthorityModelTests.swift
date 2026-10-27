// SPDX-License-Identifier: Apache-2.0
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import ProxyControlBridge

/// A bounded two-client authority model over the actual private codec, transport, service and store.
/// Its oracle knows only a value, a version and each client's observed version; no production authority helper is reused.
@MainActor
final class RuntimePrivateEditorAuthorityModelTests: XCTestCase {
    private enum Action: String, CaseIterable {
        case readA, readB, saveA, saveB, reuseA, reuseB
        var client: Int { self == .readA || self == .saveA || self == .reuseA ? 0 : 1 }
        var reads: Bool { self == .readA || self == .readB }
        var saves: Bool { self == .saveA || self == .saveB }
    }

    private struct Reference {
        var name: String
        var version = 0
        var seen = [0, 0]
        var edits = [0, 0]

        mutating func read(_ client: Int) { seen[client] = version }

        mutating func save(_ client: Int) -> (name: String, accepted: Bool) {
            edits[client] += 1
            let candidate = "Model client \(client) edit \(edits[client])"
            guard seen[client] == version else { return (candidate, false) }
            name = candidate
            version += 1
            seen[client] = version
            return (candidate, true)
        }
    }

    private struct Draft {
        var config: ProxyConfig
        var platform: PlatformIntegrationConfig
        var runtime: PrivateBaseline
        var platformBaseline: PrivateBaseline

        init(_ observation: PrivateEditorObservation) throws {
            let values = try PrivateConfigurationBridge.makeValues(from: observation)
            config = values.config
            platform = values.platform
            runtime = try XCTUnwrap(observation.components.runtime.baseline)
            platformBaseline = try XCTUnwrap(observation.components.platform.baseline)
        }
    }

    private enum Mismatch: Error { case unexpectedAnswer }
    private func deadline() -> RuntimeDeadline { .after(.seconds(30), from: ContinuousClock.now) }

    func testAllThreeStepTwoClientAuthorityHistories() async throws {
        var transitions = 0
        // Reuse is eligible only after a submission: 88 legal depth-three histories, with no placeholder no-op steps.
        for first in Action.allCases {
            for second in Action.allCases {
                for third in Action.allCases {
                    let history = [first, second, third]
                    var submitted: Set<Int> = []
                    guard history.allSatisfy({ action in
                        if action.saves { submitted.insert(action.client); return true }
                        return action.reads || submitted.contains(action.client)
                    }) else { continue }
                    try await run(history)
                    transitions += 3
                }
            }
        }
        XCTAssertEqual(transitions, 264)
        print("PRIVATE-AUTHORITY-MODEL histories=88 transitions=\(transitions) depth=3 clients=2")
    }

    private func run(_ history: [Action]) async throws {
        let harness = try makeInteractiveHarness(platform: PlatformIntegrationConfig(), dnsForwarderEnabled: false)
        do {
            let host = try await harness.makeHost()
            let composition = RuntimeControlComposition(
                host: host, limits: try RuntimeServiceFixtures.limits(), timing: .system, scheduling: TaskOwnerScheduling()
            )
            let control = try makeFramedRuntimeClient(
                transport: composition.transport, limits: ControlFrameLimits(maxFrameBytes: 64 * 1024),
                wireBudgetCap: .seconds(30)
            )
            let editor = PrivateEditorClient(transport: composition.transport)
            let stream = try await control.subscribe(.live, deadline: deadline())
            defer { stream.cancel() }
            _ = try await stream.next(deadline())

            func read() async throws -> PrivateEditorObservation {
                let answer = try await editor.read(
                    requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: host.incarnation,
                    budget: try ControlWireBudget(30_000), deadline: deadline()
                )
                guard case .observation(let observed) = answer else { throw Mismatch.unexpectedAnswer }
                return observed
            }

            let initial = try await read()
            let firstDraft = try Draft(initial)
            var drafts = [firstDraft, firstDraft]
            var requests: [PrivateConfigurationRequest?] = [nil, nil]
            var reference = Reference(name: firstDraft.config.profileName)
            let initialVersion = firstDraft.runtime.version
            let trace = history.map(\.rawValue).joined(separator: " → ")

            for action in history {
                let client = action.client
                if action.reads {
                    drafts[client] = try Draft(try await read())
                    reference.read(client)
                } else if action.saves {
                    let expected = reference.save(client)
                    let draft = drafts[client]
                    let requestID = ControlRequestID(rawValue: UUID())
                    // Small fixture values; pre-mapping reservation ordering has separate deterministic witnesses.
                    var config = draft.config
                    config.profileName = expected.name
                    let request = try PrivateConfigurationBridge.makeRequest(
                        config: config, platform: draft.platform, requestID: requestID, incarnation: host.incarnation,
                        budget: try ControlWireBudget(30_000), runtimeBaseline: draft.runtime,
                        platformBaseline: draft.platformBaseline,
                        modules: PrivateModuleSlots(proxy: .saveOnly, dns: .saveOnly, tunnels: .saveOnly)
                    )
                    requests[client] = request
                    let admission = try await editor.submit(requestID: requestID, deadline: deadline()) { request }
                    guard case .accepted(let operation) = admission else {
                        XCTFail("\(trace): fresh request admission \(admission)")
                        throw Mismatch.unexpectedAnswer
                    }
                    var receipt: ControlConfigurationReceipt?
                    for _ in 0..<64 where receipt == nil {
                        if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation {
                            guard case .configurationSettled(let value) = finished.outcome else {
                                XCTFail("\(trace): save outcome \(finished.outcome)")
                                throw Mismatch.unexpectedAnswer
                            }
                            receipt = value
                        }
                    }
                    let settled = try XCTUnwrap(receipt, trace)
                    XCTAssertEqual(settled.requestID, requestID, trace)
                    XCTAssertEqual(settled.incarnation, host.incarnation, trace)
                    XCTAssertTrue(settled.modules.isEmpty, trace)
                    if expected.accepted {
                        XCTAssertEqual(settled.runtime.write, .persisted(reportedError: false), trace)
                        drafts[client].runtime = try XCTUnwrap(settled.runtime.baseline, trace)
                        drafts[client].platformBaseline = try XCTUnwrap(settled.platform.baseline, trace)
                    } else {
                        XCTAssertEqual(settled.runtime.write, .notAttempted(.baselineMismatch), trace)
                        XCTAssertNil(settled.runtime.baseline, trace)
                    }
                } else if let request = requests[client] {
                    let admission = try await editor.submit(requestID: request.requestID, deadline: deadline()) { request }
                    XCTAssertEqual(admission, .rejected(.requestReused), trace)
                } else {
                    XCTFail("\(trace): a generated reuse has no prior submission")
                    throw Mismatch.unexpectedAnswer
                }

                let observed = try await read()
                XCTAssertEqual(observed.runtime.profileName, reference.name, trace)
                XCTAssertEqual(observed.components.runtime.baseline?.version, initialVersion + UInt64(reference.version), trace)
                XCTAssertEqual(composition.privateCustody.held.transfer, false, trace)
                XCTAssertEqual(composition.privateCustody.held.input, false, trace)
                XCTAssertEqual(composition.service.liveOperationCount, 0, trace)
                XCTAssertEqual(host.pendingAdmissions, 0, trace)
                XCTAssertFalse(host.runtimeState().proxyIsUp, "save-only never starts: \(trace)")
            }
        } catch {
            await harness.tearDown()
            throw error
        }
        await harness.tearDown()
    }
}
