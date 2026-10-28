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
final class ConfigurationWorkflowAdmissionTests: XCTestCase {
    private enum Operation: CaseIterable {
        case start
        case stop
        case capture
        case claim
    }

    /// Every trace of length 0 through `maximumLength`: 1 + 4 + 16 + 64 + 256 = 341 traces.
    private static let maximumLength = 4

    @RuntimeActor private func scratchSession() throws -> (StateRootSession, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-workflow-admission-\(UUID().uuidString)", isDirectory: true)
        return (try acquireScratchStateRoot(.isolated(stateDirectory: directory)), directory)
    }

    @RuntimeActor private func workflow(
        _ session: StateRootSession,
        startupAllowsMissing: Bool = true,
        generation: Int = 0
    ) -> RuntimeConfigurationWorkflow {
        let store = ConfigurationStore(
            session: session,
            access: StateFileAccess.operatingSystem(),
            work: PlatformWork(label: "test.workflow-admission")
        )
        return RuntimeConfigurationWorkflow(
            store: store, incarnation: ControlHostIncarnation(rawValue: UUID()),
            startupAllowsMissing: startupAllowsMissing, generation: generation
        )
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

    @RuntimeActor func testEveryBoundedTraceOfAdmissionsAgreesWithTheReferenceOracle() async throws {
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
                    guard case .success(let ticket) = workflow.admitStart() else {
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
                    // The store's write claim is built from this same admission check at the capture (`prepareStart`).
                    XCTAssertEqual(workflow.isCurrent(ticket), oracle.isCurrent(ticket.generation), "\(trace)")
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
    @RuntimeActor func testAStartCommitsRequiredDefaultsBeforeItAdmitsAnApply() async throws {
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
        XCTAssertEqual(reload.decision, .adopted(.held(.unit, .uncommitted)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.environment.configFile.path), "a reload writes nothing")

        let ticket = try workflow.admitStart().get()
        let started = await workflow.prepareStart(ticket)
        guard case .ready(let prepared) = started.preparation else {
            return XCTFail("a Start with missing defaults verifies after committing them, got \(started.preparation)")
        }
        let verified = prepared.input
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
    @RuntimeActor func testAReloadCapturedBeforeAnyStartIsSupersededByOneAdmittedDuringItsWait() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()

        let captured = workflow.generation
        XCTAssertEqual(captured, 0)
        _ = try workflow.admitStart().get()
        let reload = await workflow.reload(capturedAt: captured)

        XCTAssertNil(reload.applied)
        XCTAssertFalse(reload.adopted)
        XCTAssertEqual(reload.events.last, .superseded(ConfigurationWorkflowSuperseded(phase: .reload, generation: 0, current: 1)))
        XCTAssertEqual(reload.decision, .adopted(.superseded), "the stale observation is the store's, and nothing applies")
    }

    /// A reload under a Stop fence adopts nothing that applies, and the fence stays in force.
    @RuntimeActor func testAReloadUnderAStopFenceHoldsApplyAndLeavesTheFenceInForce() async throws {
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
        XCTAssertEqual(reload.decision, .adopted(.held(.unit, .stopFenced)))
        XCTAssertTrue(workflow.stopFenced, "a reload never clears the fence")
    }

    /// The maximum generation, reached through the internal seed. A Start there is the last one admitted: a further Start is refused as
    /// exhausted and leaves the admission standing. Ending the failed Start cannot advance, so it fences, and every stop then reports the
    /// closed fence hold, since no newer generation exists to name. A Stop at the maximum fences without advancing.
    @RuntimeActor func testTheMaximumGenerationRefusesFurtherStartsAndFencesInPlaceOfAdvancing() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let fenceHold: ConfigurationWorkflowEvent = .held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .stopFenced))

        let failed = workflow(session, generation: Int.max - 1)
        _ = try await failed.open()
        let last = try failed.admitStart().get()
        XCTAssertEqual(last.generation, Int.max)
        XCTAssertEqual(failed.admitStart(), .failure(.intentExhausted), "no generation is left for another Start")
        XCTAssertEqual(failed.admissionEvents(.intentExhausted), [
            .held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .intentExhausted)),
        ])
        XCTAssertTrue(failed.isCurrent(last), "a refused Start changes neither the generation nor the fence")
        guard case .ready(let ready) = await failed.prepareStart(last).preparation else {
            return XCTFail("the last Start prepares its defaults")
        }
        let committed = try Data(contentsOf: session.environment.configFile)
        XCTAssertTrue(failed.authorize(ready), "the host fails a Start only after authorizing it")
        failed.endFailedStart(last)
        XCTAssertEqual(failed.generation, Int.max)
        XCTAssertTrue(failed.stopFenced, "ending a failed Start at the maximum fences in place of advancing")
        XCTAssertFalse(failed.isCurrent(last))
        XCTAssertEqual(failed.supersession(of: last), [fenceHold])
        let prepared = await failed.prepareStart(last)
        XCTAssertEqual(prepared.preparation.isSuperseded, true)
        XCTAssertEqual(prepared.events, [fenceHold])
        XCTAssertEqual(try Data(contentsOf: session.environment.configFile), committed, "a fenced Start commits nothing")

        let stopped = workflow(session, generation: Int.max)
        _ = try await stopped.open()
        XCTAssertEqual(stopped.admitStart(), .failure(.intentExhausted))
        XCTAssertFalse(stopped.stopFenced, "an exhausted Start leaves the fence where it was")
        XCTAssertEqual(stopped.admitStop(), Int.max, "a Stop at the maximum fences without advancing")
        XCTAssertTrue(stopped.stopFenced)
        let reload = await stopped.reload(capturedAt: stopped.generation)
        XCTAssertNil(reload.applied)
        XCTAssertEqual(reload.events.last, .held(ConfigurationWorkflowHeld(phase: .reload, input: .unit, reason: .stopFenced)))
        XCTAssertEqual(reload.decision, .adopted(.held(.unit, .stopFenced)))
    }

    /// A client's reload names its request in the store context it reads under; the host's own facade names a fresh one. A refused
    /// observation is answered refused at the return of its one event, adopts nothing, and still names its request.
    @RuntimeActor func testAReloadNamesItsRequestInTheStoreContextAndAnswersBesideItsEvents() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()
        let request = ControlRequestID(rawValue: UUID())

        let named = await workflow.reload(capturedAt: workflow.generation, requestID: request)
        XCTAssertEqual(named.context?.requestID, request)
        XCTAssertEqual(named.context?.expectedOwnerGeneration.rawValue, workflow.generation)
        let facade = await workflow.reload(capturedAt: workflow.generation)
        XCTAssertNotNil(facade.context)
        XCTAssertNotEqual(facade.context?.requestID, request)

        try Data("{".utf8).write(to: session.environment.configFile)
        let refused = await workflow.reload(capturedAt: workflow.generation, requestID: request)
        XCTAssertEqual(refused.events, [.observed(ConfigurationWorkflowObserved(phase: .reload, observation: .refused(.invalidContent)))])
        XCTAssertEqual(refused.decision, .refused(.invalidContent))
        XCTAssertFalse(refused.adopted)
        XCTAssertNil(refused.applied)
        XCTAssertEqual(refused.context?.requestID, request)
    }

    /// Decision 0037: a saved-input Start captures the store's pair at preparation, not admission. A reload of valid B while the Start is
    /// queued supplies B, and B's observed bytes are verified, never written over. A reload of B after the capture holds the prepared Start:
    /// it is neither authorized nor rebound, and its cause is the replaced input.
    @RuntimeActor func testAFacadeStartNeverWritesOverAReloadObservedDNSValue() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()
        let first = try workflow.admitStart().get()
        guard case .ready(let committed) = await workflow.prepareStart(first).preparation else {
            return XCTFail("the defaults commit verifies")
        }
        XCTAssertTrue(workflow.authorize(committed))
        workflow.finishStart(first, succeeded: true)

        // B arrives before preparation: the queued facade uses it.
        let facade = try workflow.admitStart().get()
        XCTAssertNil(facade.lifecycle.dnsStaged, "a queued facade carries no configuration value")
        let external = try externalEdit(session, dnsForwarderEnabled: true, profileName: "Edited B")
        let reload = await workflow.reload(capturedAt: workflow.generation)
        XCTAssertEqual(reload.applied?.runtime.dnsForwarderEnabled, true, "the reload adopted the verified DNS on")

        let prepared = await workflow.prepareStart(facade)
        guard case .ready(let ready) = prepared.preparation else {
            return XCTFail("a reload before the capture supplies the saved input, got \(prepared.preparation)")
        }
        XCTAssertEqual(ready.input.runtime.dnsForwarderEnabled, true, "the capture used B's DNS on")
        XCTAssertEqual(ready.input.runtime.profileName, "Edited B", "and the rest of B")
        XCTAssertEqual(ready.ticket.lifecycle.dnsStaged, true)
        XCTAssertEqual(try Data(contentsOf: session.environment.configFile), external, "the observed file is not written over")
        XCTAssertTrue(workflow.isCurrent(ready))

        // C replaces the captured pair before the effects: the prepared Start holds and is not rebound.
        _ = try externalEdit(session, dnsForwarderEnabled: true, profileName: "Edited C")
        let later = await workflow.reload(capturedAt: workflow.generation)
        XCTAssertEqual(later.applied?.runtime.profileName, "Edited C", "the newer observation is adopted as the store's fact")
        XCTAssertFalse(workflow.isCurrent(ready), "it replaced the pair the Start captured")
        XCTAssertTrue(workflow.isCurrent(ready.ticket), "no newer admission came, so only the input moved")
        XCTAssertEqual(workflow.supersession(of: ready.ticket), [
            .held(ConfigurationWorkflowHeld(phase: .start, input: .unit, reason: .inputReplaced)),
        ])
        XCTAssertFalse(workflow.authorize(ready), "the replaced input authorizes nothing")
        workflow.retire(ready.ticket)
        XCTAssertFalse(workflow.isCurrent(ready.ticket))
    }

    /// A reload that observes the captured pair's unchanged bytes keeps the store's versions, so it replaces nothing.
    @RuntimeActor func testAnUnchangedReloadAfterTheCaptureKeepsThePreparedStart() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()
        let ticket = try workflow.admitStart().get()
        guard case .ready(let ready) = await workflow.prepareStart(ticket).preparation else {
            return XCTFail("the defaults commit verifies")
        }
        _ = await workflow.reload(capturedAt: workflow.generation)
        XCTAssertTrue(workflow.isCurrent(ready), "an unchanged observation keeps the captured pair")
        XCTAssertTrue(workflow.authorize(ready))
    }

    /// A session DNS Stop fences at once and owes its disable. A facade Start is refused whole while it is owed. The save goes through the
    /// runtime-only lifecycle commit and ends the obligation only once verified; the next facade Start then captures the saved false.
    @RuntimeActor func testASessionDNSStopOwesItsDisableUntilTheRuntimeOnlySaveVerifies() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()
        _ = try externalEdit(session, dnsForwarderEnabled: true, profileName: "DNS on")
        _ = await workflow.reload(capturedAt: workflow.generation)
        let none = await workflow.saveOwedDNSStop()
        XCTAssertEqual(none.save, .notOwed)

        let stop = workflow.admitStop([.dns], reason: .session)
        XCTAssertEqual(workflow.generation, stop)
        XCTAssertEqual(workflow.admitStart(), .failure(.stopSaveOwed), "the facade may not displace the owed save")
        XCTAssertEqual(workflow.generation, stop, "and its refusal changes nothing")

        let saved = await workflow.saveOwedDNSStop()
        XCTAssertEqual(saved.save, .saved)
        XCTAssertEqual(saved.events, [.committed(ConfigurationWorkflowCommitted(file: .runtime, write: .persisted(reportedError: false)))])
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.environment.platformConfigFile.path), "no sidecar is written")
        let after = await workflow.saveOwedDNSStop()
        XCTAssertEqual(after.save, .notOwed, "the verified save ended the obligation")

        let ticket = try workflow.admitStart().get()
        guard case .ready(let ready) = await workflow.prepareStart(ticket).preparation else {
            return XCTFail("the facade Start prepares once the save verified")
        }
        XCTAssertFalse(ready.input.runtime.dnsForwarderEnabled, "it captures the saved disable")
        XCTAssertEqual(ready.input.runtime.profileName, "DNS on", "and keeps the rest of the runtime file")
    }

    /// A runtime file changed outside the store since its baseline conflicts: the disable is not written over it and stays owed.
    @RuntimeActor func testAnOwedDNSDisableIsNotWrittenOverAChangedFile() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()
        _ = try externalEdit(session, dnsForwarderEnabled: true, profileName: "DNS on")
        _ = await workflow.reload(capturedAt: workflow.generation)
        workflow.admitStop([.dns], reason: .session)
        let external = try externalEdit(session, dnsForwarderEnabled: true, profileName: "Edited elsewhere")

        let attempt = await workflow.saveOwedDNSStop()
        XCTAssertEqual(attempt.save, .owed)
        XCTAssertEqual(attempt.events, [.committed(ConfigurationWorkflowCommitted(file: .runtime, write: .conflict))])
        XCTAssertEqual(try Data(contentsOf: session.environment.configFile), external, "the changed file is kept")
        XCTAssertEqual(workflow.admitStart(), .failure(.stopSaveOwed), "the disable is still owed")
    }

    @RuntimeActor private func externalEdit(_ session: StateRootSession, dnsForwarderEnabled: Bool, profileName: String) throws -> Data {
        var edited = GenericDefaults.shared.makeConfig()
        edited.dnsForwarderEnabled = dnsForwarderEnabled
        edited.profileName = profileName
        let external = try ProxyConfigPersistence.stagedFileData(for: edited)
        try external.write(to: session.environment.configFile)
        return external
    }

    /// A Start whose preparation resumes after a newer Stop stops without preparing anything, and says why.
    @RuntimeActor func testAStartSupersededByAStopStopsWithoutCommitting() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let workflow = workflow(session)
        _ = try await workflow.open()

        let ticket = try workflow.admitStart().get()
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

private extension RuntimeConfigurationWorkflow.ReloadOutcome {
    /// The answer decided at the workflow's return, nil when the observation is eligible and the host's pass decides it.
    var decision: RuntimeReloadDecision? {
        if case .decided(let decision) = answer { decision } else { nil }
    }
}
