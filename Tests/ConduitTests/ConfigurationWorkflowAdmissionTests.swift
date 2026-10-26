// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import PlatformMac
import RuntimeEvents
import XCTest
@testable import ConduitRuntime
@testable import ProxyKernel

/// The workflow's admission rules (decisions 0015, 0031 and 0032) over the real workflow, store and scratch state root.
///
/// The bounded model enumerates every trace of up to `maximumLength` admissions over four operations. Its oracle is two integers
/// and a flag, written here without the workflow's code, so a defect in the workflow's arithmetic or fence cannot agree with itself.
@MainActor
final class ConfigurationWorkflowAdmissionTests: XCTestCase {
    private enum Operation: CaseIterable {
        case start
        case stop
        case capture
        case claim
    }

    /// Every trace of length 0 through `maximumLength`: 1 + 4 + 16 + 64 + 256 = 341 traces.
    private static let maximumLength = 4

    private func scratchSession() throws -> (StateRootSession, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-workflow-admission-\(UUID().uuidString)", isDirectory: true)
        return (try acquireScratchStateRoot(.isolated(stateDirectory: directory)), directory)
    }

    private func workflow(
        _ session: StateRootSession,
        startupAllowsMissing: Bool = true,
        generation: Int = 0
    ) -> RuntimeConfigurationWorkflow {
        let store = ConfigurationStore(
            session: session,
            access: StateFileAccess.operatingSystem(),
            work: PlatformWork(label: "test.workflow-admission")
        )
        return RuntimeConfigurationWorkflow(store: store, startupAllowsMissing: startupAllowsMissing, generation: generation)
    }

    // MARK: - Bounded model

    /// The reference: a generation that advances on each Start and each Stop, a fence that a Stop sets and only an authorized Start
    /// clears (decision 0035), so no admission alone clears it, and a ticket that is current only while its generation is the latest.
    private struct Oracle {
        var generation = 0
        var fenced = false

        mutating func start() {
            generation += 1
        }

        mutating func stop() {
            generation += 1
            fenced = true
        }

        func isCurrent(_ ticketGeneration: Int) -> Bool {
            ticketGeneration == generation
        }
    }

    func testEveryBoundedTraceOfAdmissionsAgreesWithTheReferenceOracle() throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let traces = Self.traces(upTo: Self.maximumLength)
        XCTAssertEqual(traces.count, 341)
        for trace in traces {
            let workflow = workflow(session)
            var oracle = Oracle()
            var starts: [RuntimeConfigurationWorkflow.StartTicket] = []
            var captures: [Int] = []
            for operation in trace {
                switch operation {
                case .start:
                    oracle.start()
                    guard let ticket = workflow.admitStart() else {
                        return XCTFail("\(trace): a start was refused below the maximum generation")
                    }
                    starts.append(ticket)
                    XCTAssertEqual(ticket.generation, oracle.generation, "\(trace)")
                case .stop:
                    oracle.stop()
                    XCTAssertEqual(workflow.admitStop(), oracle.generation, "\(trace)")
                case .capture:
                    captures.append(workflow.generation)
                case .claim:
                    guard let ticket = starts.last else { continue }
                    let claim = workflow.writeClaim(for: ticket)
                    XCTAssertEqual(workflow.isCurrent(ticket), oracle.isCurrent(ticket.generation), "\(trace)")
                    XCTAssertEqual(claim.isCurrent(), oracle.isCurrent(ticket.generation), "\(trace)")
                }
                XCTAssertEqual(workflow.generation, oracle.generation, "\(trace)")
                XCTAssertEqual(workflow.stopFenced, oracle.fenced, "\(trace)")
            }
            // A capture is stale exactly when a later admission moved the generation past it.
            for captured in captures {
                XCTAssertEqual(workflow.isLatest(captured), captured == oracle.generation, "\(trace)")
            }
        }
    }

    /// Every sequence of operations up to `length`, in lexicographic order of the operation cases.
    private static func traces(upTo length: Int) -> [[Operation]] {
        var result: [[Operation]] = [[]]
        var frontier: [[Operation]] = [[]]
        for _ in 0..<length {
            frontier = frontier.flatMap { prefix in Operation.allCases.map { prefix + [$0] } }
            result += frontier
        }
        return result
    }

    // MARK: - Real store and reload

    /// A Start prepares the required defaults through the store, persists them before the start, and returns the exact pair. The
    /// reload that observed the same missing files held apply and wrote nothing.
    func testAStartCommitsRequiredDefaultsBeforeItAdmitsAnApply() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        let opened = try await workflow.open()
        XCTAssertEqual(opened.events, [.observed(ConfigurationWorkflowObserved(phase: .startup, observation: .adopted))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.environment.configFile.path), "open writes nothing")

        let reload = await workflow.reload(capturedAt: workflow.generation)
        XCTAssertNil(reload.applied, "a missing runtime file is uncommitted, so a reload holds apply")
        XCTAssertEqual(reload.events, [
            .observed(ConfigurationWorkflowObserved(phase: .reload, observation: .adopted)),
            .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .uncommitted)),
        ])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.environment.configFile.path), "a reload writes nothing")

        let ticket = try XCTUnwrap(workflow.admitStart())
        let started = await workflow.prepareStart(ticket)
        guard case .ready(let verified) = started.preparation else {
            return XCTFail("a Start with missing defaults verifies after committing them, got \(started.preparation)")
        }
        XCTAssertEqual(verified.runtime, opened.values.runtime)
        XCTAssertEqual(verified.platform, opened.values.platform)
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.environment.configFile.path), "the default is persisted before the start")
        XCTAssertEqual(started.events, [
            .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .persisted(reportedError: false))),
            .committed(ConfigurationWorkflowCommitted(file: .platform, write: .persisted(reportedError: false))),
        ])
    }

    /// A reload captured at generation 0, before any Start, is superseded by a Start admitted during its wait. Its observation stays a
    /// durable observation, and it changes no applied view.
    func testAReloadCapturedBeforeAnyStartIsSupersededByOneAdmittedDuringItsWait() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()

        let captured = workflow.generation
        XCTAssertEqual(captured, 0)
        _ = try XCTUnwrap(workflow.admitStart())
        let reload = await workflow.reload(capturedAt: captured)

        XCTAssertNil(reload.applied)
        XCTAssertNil(reload.preferences)
        XCTAssertEqual(reload.events.last, .superseded(ConfigurationWorkflowSuperseded(phase: .reload, generation: 0, current: 1)))
    }

    /// A reload under a Stop fence adopts nothing that applies, and the fence stays in force.
    func testAReloadUnderAStopFenceHoldsApplyAndLeavesTheFenceInForce() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()

        workflow.admitStop()
        let reload = await workflow.reload(capturedAt: workflow.generation)

        XCTAssertNil(reload.applied)
        XCTAssertEqual(reload.events.last, .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .stopFenced)))
        XCTAssertTrue(workflow.stopFenced, "a reload never clears the fence")
    }

    /// The maximum generation, reached through the internal seed. A Start there is the last one admitted: a further Start is refused as
    /// exhausted and leaves the admission standing. Ending the failed Start cannot advance, so it fences, and every stop then reports the
    /// closed fence hold, since no newer generation exists to name. A Stop at the maximum fences without advancing.
    func testTheMaximumGenerationRefusesFurtherStartsAndFencesInPlaceOfAdvancing() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let fenceHold: ConfigurationWorkflowEvent = .held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .stopFenced))

        let failed = workflow(session, generation: Int.max - 1)
        _ = try await failed.open()
        let last = try XCTUnwrap(failed.admitStart())
        XCTAssertEqual(last.generation, Int.max)
        XCTAssertNil(failed.admitStart(), "no generation is left for another Start")
        XCTAssertTrue(failed.isCurrent(last), "a refused Start changes neither the generation nor the fence")
        XCTAssertTrue(failed.authorize(last), "the host fails a Start only after authorizing it")
        failed.endFailedStart(last)
        XCTAssertEqual(failed.generation, Int.max)
        XCTAssertTrue(failed.stopFenced, "ending a failed Start at the maximum fences in place of advancing")
        XCTAssertFalse(failed.isCurrent(last))
        XCTAssertEqual(failed.supersession(of: last), [fenceHold])
        let prepared = await failed.prepareStart(last)
        XCTAssertEqual(prepared.preparation.isSuperseded, true)
        XCTAssertEqual(prepared.events, [fenceHold])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.environment.configFile.path), "a fenced Start commits nothing")

        let stopped = workflow(session, generation: Int.max)
        _ = try await stopped.open()
        XCTAssertNil(stopped.admitStart())
        XCTAssertFalse(stopped.stopFenced, "an exhausted Start leaves the fence where it was")
        XCTAssertEqual(stopped.admitStop(), Int.max, "a Stop at the maximum fences without advancing")
        XCTAssertTrue(stopped.stopFenced)
        let reload = await stopped.reload(capturedAt: stopped.generation)
        XCTAssertNil(reload.applied)
        XCTAssertEqual(reload.events.last, .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .stopFenced)))
    }

    /// Review prototype B: pin a facade's input at admission and supersede when a later reload changes it. Saved-command binding is
    /// unselected; see docs/design-saved-runtime-input-binding.md. Every option must preserve the observed file bytes; the superseded
    /// expectation below belongs only to this prototype.
    func testAFacadeStartNeverWritesOverAReloadObservedDNSValue() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()
        let first = try XCTUnwrap(workflow.admitStart())
        guard case .ready = await workflow.prepareStart(first).preparation else { return XCTFail("the defaults commit verifies") }
        XCTAssertTrue(workflow.authorize(first))
        workflow.finishStart(first, succeeded: true)

        let facade = try XCTUnwrap(workflow.admitStart())
        XCTAssertFalse(facade.lifecycle.dnsStaged, "admitted on the committed DNS off")
        var edited = GenericDefaults.shared.makeConfig()
        edited.dnsForwarderEnabled = true
        let external = try ProxyConfigPersistence.stagedFileData(for: edited)
        try external.write(to: session.environment.configFile)
        let reload = await workflow.reload(capturedAt: workflow.generation)
        XCTAssertEqual(reload.applied?.runtime.dnsForwarderEnabled, true, "the reload adopted the verified DNS on")

        let prepared = await workflow.prepareStart(facade)
        XCTAssertEqual(prepared.preparation.isSuperseded, true, "the changed DNS fact ends the facade's admission")
        XCTAssertEqual(try Data(contentsOf: session.environment.configFile), external, "the observed file is not written over")
        XCTAssertFalse(workflow.isCurrent(facade))
        let next = try XCTUnwrap(workflow.admitStart())
        XCTAssertTrue(next.lifecycle.dnsStaged, "a fresh facade Start stages the observed DNS on")
    }

    /// A Start whose preparation resumes after a newer Stop stops without preparing anything, and says why.
    func testAStartSupersededByAStopStopsWithoutCommitting() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()

        let ticket = try XCTUnwrap(workflow.admitStart())
        workflow.admitStop()
        let started = await workflow.prepareStart(ticket)

        XCTAssertEqual(started.preparation.isSuperseded, true)
        XCTAssertEqual(started.events, [.superseded(ConfigurationWorkflowSuperseded(phase: .start, generation: 1, current: 2))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.environment.configFile.path), "a superseded Start commits nothing")
    }
}

private extension RuntimeConfigurationWorkflow.StartPreparation {
    var isSuperseded: Bool {
        if case .superseded = self { true } else { false }
    }
}
