// SPDX-License-Identifier: Apache-2.0
import Foundation
import ConduitShared
import PlatformMac
import ProxyKernel
import RuntimeEvents
import XCTest
@testable import ConduitRuntime

/// Interleavings of a workflow's physical steps with newer intent (decisions 0015, 0025, 0027 and 0032). The store's file access is
/// wrapped so one step parks its worker thread until the test releases it. The test admits Stop or Start while that step is parked,
/// then checks the typed outcome. The files are the fake's in-memory bytes, and the scratch state root is held for the lease only.
///
/// The exploration is bounded to the four cases below: {Stop, Start} admitted during {the pre-claim read, the replacement}. A claim
/// revoked before a replacement starts writes nothing, and a replacement that started finishes its read-back and reports it.
final class ConfigurationWorkflowPhaseTests: XCTestCase {
    /// The physical step a test parks. `read` is any configuration read, including the pre-read a replacement makes before its claim is
    /// checked. `replace` is the write itself, which is reached only after its claim check passed.
    private enum Step: Equatable {
        case read
        case replace
    }

    /// Delegates to the fake, and parks the worker at the armed step until the test releases it. Counts replacements that were made.
    private final class ParkingFiles: StateFileAccessing, @unchecked Sendable {
        private let inner = FakeStateFileAccess()
        private let condition = NSCondition()
        private var armed: Step?
        private var parked = false
        private var released = false
        private(set) var replacements = 0

        func arm(_ step: Step) {
            condition.withLock {
                armed = step
                parked = false
                released = false
            }
        }

        /// Waits, bounded, until the worker is parked at its step. Returns false if it never reached one.
        func waitUntilParked() async -> Bool {
            for _ in 0..<400 {
                if condition.withLock({ parked }) { return true }
                try? await Task.sleep(for: .milliseconds(5))
            }
            return false
        }

        func release() {
            condition.withLock {
                released = true
                condition.broadcast()
            }
        }

        private func park(_ step: Step) {
            condition.withLock {
                guard armed == step else { return }
                armed = nil
                parked = true
                condition.broadcast()
                while !released { condition.wait() }
                parked = false
            }
        }

        func readConfigurationFile(_ file: StateRootFile, limit: Int) -> Result<Data, ConfigurationFileError> {
            park(.read)
            return inner.readConfigurationFile(file, limit: limit)
        }

        func replaceConfigurationFile(_ file: StateRootFile, bytes: Data) -> Result<Void, ConfigurationFileWriteError> {
            park(.replace)
            condition.withLock { replacements += 1 }
            return inner.replaceConfigurationFile(file, bytes: bytes)
        }

        func entryPresence(_ file: StateRootFile) -> Result<Bool, ConfigurationPresenceError> {
            inner.entryPresence(file)
        }
    }

    @RuntimeActor private func scratchSession() throws -> (StateRootSession, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-workflow-phase-\(UUID().uuidString)", isDirectory: true)
        return (try acquireScratchStateRoot(.isolated(stateDirectory: directory)), directory)
    }

    @RuntimeActor private func workflow(_ session: StateRootSession, files: ParkingFiles, work: PlatformWork) -> RuntimeConfigurationWorkflow {
        let store = ConfigurationStore(session: session, access: files, work: work)
        return RuntimeConfigurationWorkflow(store: store, incarnation: ControlHostIncarnation(rawValue: UUID()), startupAllowsMissing: true)
    }

    /// Stop admitted while the commit is still queued behind a blocked physical job, so before its claim is checked. A queued commit has
    /// no I/O yet, so the revocation is observed at the claim, not at a file read. The claim is revoked before the write, so nothing is
    /// written, the runtime write is held behind the platform write, and the Start stops without applying anything.
    @RuntimeActor func testAStopAdmittedBeforeTheClaimRevokesTheWriteAndNothingApplies() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let files = ParkingFiles()
        let queue = PlatformWork(label: "test.workflow-phase.queue")
        let workflow = workflow(session, files: files, work: queue)
        _ = try await workflow.open()
        let ticket = try workflow.admitStart().get()

        // A blocked job holds the queue. The commit queues behind it and waits there until the blocker is released. Each step is observed
        // rather than timed: the blocker has started, and the workflow is in flight, which means it passed its admission and awaits the commit.
        let blocked = DispatchSemaphore(value: 0)
        let started = LockedCount()
        let blocker = Task {
            await queue.run {
                started.set(1)
                blocked.wait()
            }
        }
        for _ in 0..<2_000 where started.value != 1 {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertEqual(started.value, 1, "the blocked job holds the queue")
        let prepared = Task { await workflow.prepareStart(ticket) }
        for _ in 0..<2_000 where workflow.isIdle {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertFalse(workflow.isIdle, "the commit waits behind the blocked job")
        workflow.admitStop()
        blocked.signal()
        await blocker.value
        let outcome = await prepared.value

        XCTAssertEqual(files.replacements, 0, "a revoked claim writes nothing")
        XCTAssertEqual(outcome.preparation.isSuperseded, true)
        XCTAssertEqual(outcome.events, [
            .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.heldBehindPlatform))),
            .committed(ConfigurationWorkflowCommitted(file: .platform, write: .notAttempted(.superseded))),
            .superseded(ConfigurationWorkflowSuperseded(phase: .start, generation: 1, current: 2)),
        ])
    }

    /// Stop admitted while the platform replacement is in flight. The replacement finishes its read-back and reports it persisted. The
    /// runtime write's claim is then revoked, so the runtime file is not written, and nothing applies.
    @RuntimeActor func testAStopAdmittedDuringAStartedReplacementCompletesIt() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let files = ParkingFiles()
        let workflow = workflow(session, files: files, work: PlatformWork(label: "test.workflow-phase"))
        _ = try await workflow.open()
        let ticket = try workflow.admitStart().get()

        files.arm(.replace)
        let prepared = Task { await workflow.prepareStart(ticket) }
        let parked = await files.waitUntilParked()
        XCTAssertTrue(parked, "the platform replacement was reached after its claim passed")
        workflow.admitStop()
        files.release()
        let outcome = await prepared.value

        XCTAssertEqual(files.replacements, 1, "only the started platform replacement wrote; the revoked runtime write did not")
        XCTAssertEqual(outcome.preparation.isSuperseded, true)
        XCTAssertEqual(outcome.events, [
            .committed(ConfigurationWorkflowCommitted(file: .runtime, write: .notAttempted(.superseded))),
            .committed(ConfigurationWorkflowCommitted(file: .platform, write: .persisted(reportedError: false))),
            .superseded(ConfigurationWorkflowSuperseded(phase: .start, generation: 1, current: 2)),
        ])
    }

    /// Start admitted during a reload's read. The reload's observation is durable, but it names no applied input.
    @RuntimeActor func testAReloadStaleAtItsReadAppliesNothing() async throws {
        let (session, directory) = try scratchSession()
        defer {
            releaseScratchStateRoot(session)
            try? FileManager.default.removeItem(at: directory)
        }
        let files = ParkingFiles()
        let workflow = workflow(session, files: files, work: PlatformWork(label: "test.workflow-phase"))
        _ = try await workflow.open()

        let captured = workflow.generation
        files.arm(.read)
        let reload = Task { await workflow.reload(capturedAt: captured) }
        let parked = await files.waitUntilParked()
        XCTAssertTrue(parked, "the reload's read was reached")
        _ = try workflow.admitStart().get()
        files.release()
        let outcome = await reload.value

        XCTAssertNil(outcome.applied)
        XCTAssertFalse(outcome.adopted)
        XCTAssertEqual(outcome.events.last, .superseded(ConfigurationWorkflowSuperseded(phase: .reload, generation: 0, current: 1)))
        XCTAssertEqual(files.replacements, 0, "a reload writes nothing")
    }
}

private extension RuntimeConfigurationWorkflow.StartPreparation {
    var isSuperseded: Bool {
        if case .superseded = self { true } else { false }
    }
}
