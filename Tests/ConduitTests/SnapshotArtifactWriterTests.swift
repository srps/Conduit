// SPDX-License-Identifier: Apache-2.0
import Dispatch
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation
import NIOConcurrencyHelpers
import ProxyControlBridge
import XCTest
@testable import ProxyKernel

/// Reads the descriptor flags the OS reports for the descriptor the writer opened. Admits every destination.
private final class DescriptorFlagRecorder: RecordFileDestinationGuarding, @unchecked Sendable {
    private let flags = NIOLockedValueBox<[Int32]>([])

    /// One entry per opened descriptor: whether `F_GETFD` succeeded and reported close-on-exec.
    var closeOnExec: [Bool] { flags.withLockedValue { $0.map { $0 >= 0 && ($0 & FD_CLOEXEC) != 0 } } }

    func admit(destination: URL) throws {}

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        let value = fcntl(descriptor, F_GETFD)
        flags.withLockedValue { $0.append(value) }
    }
}

final class SnapshotArtifactWriterTests: XCTestCase {
    func testSnapshotTempDescriptorIsCloseOnExec() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let recorder = DescriptorFlagRecorder()
        let writer = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: recorder, eventLog: RuntimeEventLog(capacity: 8))
        writer.submit(snapshotValue(1))
        let outcome = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(outcome, .current)
        XCTAssertEqual(recorder.closeOnExec, [true], "the writable temporary descriptor is close-on-exec")
    }

    func testBurstCoalescesToLatestWhileTheWriterIsHeld() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldDestinationGuard()
        let writer = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: held, eventLog: RuntimeEventLog(capacity: 32))
        writer.submit(snapshotValue(1))
        XCTAssertEqual(held.entered.wait(timeout: .now() + 10), .success)
        writer.submit(snapshotValue(2))
        writer.submit(snapshotValue(3))
        let queued = writer.statistics
        XCTAssertEqual(queued.submittedGeneration, 3)
        XCTAssertEqual(queued.coalesced, 1)
        XCTAssertEqual(queued.written, 0)
        XCTAssertEqual(queued.retainedValuePeak, 2)

        held.release()
        let outcome = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(outcome, .current)
        let final = writer.statistics
        XCTAssertEqual(final.written, 2, "generation 1 and the latest, generation 3; generation 2 was coalesced")
        XCTAssertEqual(final.lastSuccessfulGeneration, 3)
        XCTAssertEqual(try decodeSnapshot(at: directory.appendingPathComponent("snapshot.json")).dnsQueryCount, 3)
        XCTAssertEqual(held.admittedOnMainThread, false, "the guard and the encoder ran on the drain, not the caller")
    }

    @MainActor
    func testAwaitedDrainLeavesTheMainActorFree() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldDestinationGuard()
        let writer = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: held, eventLog: RuntimeEventLog(capacity: 8))
        writer.submit(snapshotValue(1))
        XCTAssertEqual(held.entered.wait(timeout: .now() + 10), .success)
        // The probe can run only while the awaited drain is suspended. It then releases the held attempt.
        let probeRan = NIOLockedValueBox(false)
        let probe = Task { @MainActor in
            probeRan.withLockedValue { $0 = true }
            held.release()
        }
        let outcome = await writer.drain(until: deadline(in: 10))
        await probe.value
        XCTAssertTrue(probeRan.withLockedValue { $0 }, "the main actor ran while the drain was awaited")
        XCTAssertEqual(outcome, .current)
    }

    func testRefusedDestinationLatchesOnceAndSubmissionsContinue() async throws {
        // Signalled once per physical reservation that ends. The second drain joins it, so it is never busy.
        let cleaned = DispatchSemaphore(value: 0)
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let witness = Data(#"{"schemaVersion":2,"witness":"original-intent"}"#.utf8)
        try witness.write(to: config)
        let events = RuntimeEventLog(capacity: 16)
        let writer = makeSnapshotArtifactWriter(
            fileURL: config, logger: DiscardingLogSink(),
            destinationGuard: systemRecordFileDestinationGuard(
                protected: [ProtectedRecordFile(resource: .config, url: config)]),
            eventLog: events, onDrainCleanup: { cleaned.signal() })
        writer.submit(snapshotValue(1))
        let first = await drainJoining(writer, cleaned: cleaned)
        writer.submit(snapshotValue(2))
        let second = await drainJoining(writer, cleaned: cleaned)
        XCTAssertEqual(first, .refused)
        XCTAssertEqual(second, .refused)
        XCTAssertEqual(try Data(contentsOf: config), witness)
        XCTAssertEqual(events.events.filter { $0.event == RecordFileDestinationGate.eventName }.count, 1)
        XCTAssertEqual(writer.statistics.refused, 2)
        XCTAssertEqual(writer.statistics.written, 0)
    }

    func testConfigAliasesAreRefusedByTheSharedDiagnosticGuard() async throws {
        let root = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let witness = Data(#"{"schemaVersion":2,"witness":"original-intent"}"#.utf8)
        for alias in ["direct", "symbolic-link", "hard-link"] {
            let directory = root.appendingPathComponent(alias, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let config = directory.appendingPathComponent("config.json")
            try witness.write(to: config)
            let snapshotURL: URL
            switch alias {
            case "symbolic-link":
                snapshotURL = directory.appendingPathComponent("snapshot.json")
                try FileManager.default.createSymbolicLink(at: snapshotURL, withDestinationURL: config)
            case "hard-link":
                snapshotURL = directory.appendingPathComponent("snapshot.json")
                try FileManager.default.linkItem(at: config, to: snapshotURL)
            default:
                snapshotURL = config
            }
            let environment = RuntimeEnvironment(configDirectory: directory, configFile: config,
                                                 snapshotFile: snapshotURL)
            let writer = makeSnapshotArtifactWriter(
                fileURL: environment.snapshotFile, logger: DiscardingLogSink(),
                destinationGuard: diagnosticDestinationGuard(for: .snapshot, in: environment),
                eventLog: RuntimeEventLog(capacity: 8))
            writer.submit(snapshotValue(1))
            let outcome = await writer.drain(until: deadline(in: 10))
            XCTAssertEqual(outcome, .refused, alias)
            XCTAssertEqual(try Data(contentsOf: config), witness, alias)
        }
    }

    func testWriteFailureIsUnconfirmedThenRecoversObservably() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // A regular file where the snapshot's directory must be: creating that directory fails.
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let events = RuntimeEventLog(capacity: 16)
        let writer = makeSnapshotArtifactWriter(
            fileURL: blocker.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        writer.submit(snapshotValue(1))
        let failed = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(failed, .writeFailed)
        XCTAssertEqual(writer.statistics.failed, 1)
        XCTAssertEqual(events.events.first { $0.event == "observability.snapshot_write_failed" }?.detail,
                       "stage=directory code=0 leftTemporary=false")

        try FileManager.default.removeItem(at: blocker)
        writer.submit(snapshotValue(2))
        let recovered = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(recovered, .current)
        XCTAssertEqual(events.events.filter { $0.event == "observability.snapshot_write_recovered" }.count, 1)
        XCTAssertEqual(try decodeSnapshot(at: blocker.appendingPathComponent("snapshot.json")).dnsQueryCount, 2)
    }

    func testEmptyQueueIsNotCurrent() async {
        let writer = makeSnapshotArtifactWriter(
            fileURL: URL(fileURLWithPath: "/nonexistent-conduit-scratch/snapshot.json"),
            logger: DiscardingLogSink(), destinationGuard: UncheckedRecordFileDestination(),
            eventLog: RuntimeEventLog(capacity: 4))
        let outcome = await writer.drain(until: deadline(in: 1))
        XCTAssertEqual(outcome, .noSubmission)
    }

    func testTimedOutWaitIsBusyUntilPhysicalCleanupFrees() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldDestinationGuard()
        let cleaned = DispatchSemaphore(value: 0)
        let writer = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: held, eventLog: RuntimeEventLog(capacity: 8),
            onDrainCleanup: { cleaned.signal() })
        writer.submit(snapshotValue(1))
        XCTAssertEqual(held.entered.wait(timeout: .now() + 10), .success)

        let timedOut = await writer.drain(until: deadline(in: 0.05))
        XCTAssertEqual(timedOut, .timedOut)
        // The caller returned while the write is held, and the reservation still stands: no second registration.
        let busy = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(busy, .busy)

        held.release()
        XCTAssertEqual(cleaned.wait(timeout: .now() + 10), .success)
        let current = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(current, .current)
        XCTAssertEqual(writer.statistics.written, 1)
    }

    func testExhaustedGenerationClosesWithoutWrapping() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = RuntimeEventLog(capacity: 8)
        let writer = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events,
            initialGeneration: UInt64.max - 1)
        writer.submit(snapshotValue(1))
        writer.submit(snapshotValue(2))
        writer.submit(snapshotValue(3))
        XCTAssertEqual(writer.statistics.submittedGeneration, UInt64.max, "the last identity is not reused")
        XCTAssertEqual(events.events.filter { $0.event == "observability.snapshot_generations_exhausted" }.count, 1)
        let outcome = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(outcome, .exhausted)
    }

    /// Once the gate has latched, later submissions are not encoded. The encode count is the witness: the first
    /// attempt encodes once, discovers the refusal, and every later attempt skips the encoder entirely.
    func testLatchedRefusalSkipsEncodingOfLaterSubmissions() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let config = directory.appendingPathComponent("config.json")
        let witness = Data(#"{"schemaVersion":2,"witness":"original-intent"}"#.utf8)
        try witness.write(to: config)
        let events = RuntimeEventLog(capacity: 16)
        let encodes = NIOLockedValueBox(0)
        let writer = SnapshotArtifactWriter(
            fileURL: config, logger: DiscardingLogSink(),
            destinationGuard: systemRecordFileDestinationGuard(
                protected: [ProtectedRecordFile(resource: .config, url: config)]),
            eventLog: events, onDrainCleanup: nil, initialGeneration: 0,
            encodeOverride: { value in
                encodes.withLockedValue { $0 += 1 }
                return try JSONEncoder().encode(value)
            })
        writer.submit(snapshotValue(1))
        let first = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(encodes.withLockedValue { $0 }, 1)
        writer.submit(snapshotValue(2))
        writer.submit(snapshotValue(3))
        let second = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(first, .refused)
        XCTAssertEqual(second, .refused)
        XCTAssertEqual(encodes.withLockedValue { $0 }, 1, "no encoding after the refusal latched")
        // Whether generation 2 coalesces into 3 depends on timing, so the count is at least two, never a write.
        XCTAssertGreaterThanOrEqual(writer.statistics.refused, 2)
        XCTAssertEqual(writer.statistics.written, 0)
        XCTAssertEqual(writer.statistics.failed, 0)
        XCTAssertEqual(events.events.filter { $0.event == RecordFileDestinationGate.eventName }.count, 1)
        XCTAssertEqual(try Data(contentsOf: config), witness)
    }

    /// A directory where the file must go: the rename fails. Removing the temporary also fails, so one orphan remains,
    /// and the writer latches. The later attempts touch no file, so exactly one temporary file exists.
    func testFailedCleanupLatchesTheWriterAndCreatesOneTemporaryOnly() async throws {
        let cleaned = DispatchSemaphore(value: 0)
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("snapshot.json")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var effects = SnapshotFileEffects.system
        effects.removeFile = { _ in -1 }
        let events = RuntimeEventLog(capacity: 32)
        let writer = SnapshotArtifactWriter(
            fileURL: destination, logger: DiscardingLogSink(), destinationGuard: UncheckedRecordFileDestination(),
            eventLog: events, onDrainCleanup: { cleaned.signal() }, initialGeneration: 0, encodeOverride: nil,
            fileEffects: effects)
        var outcomes: [SnapshotFlushOutcome] = []
        for value in 1...3 {
            writer.submit(snapshotValue(value))
            outcomes.append(await drainJoining(writer, cleaned: cleaned))
        }
        XCTAssertEqual(outcomes, [.writeFailed, .writeFailed, .writeFailed])
        let statistics = writer.statistics
        XCTAssertEqual(statistics.orphanedTemporaries, 1)
        XCTAssertTrue(statistics.cleanupLatched)
        XCTAssertEqual(statistics.failed, 3)
        XCTAssertEqual(statistics.written, 0)
        let temporaries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".snapshot.json.") && $0.hasSuffix(".tmp") }
        XCTAssertEqual(temporaries.count, 1, "the latched writer created no further temporary file")
        XCTAssertEqual(events.events.filter { $0.event == "observability.snapshot_cleanup_unconfirmed" }.count, 1)
    }

    /// The refusal is the reported cause, and the orphan it leaves is still counted and latches the writer.
    func testRefusalAfterTemporaryCreationKeepsTheCleanupStatus() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var effects = SnapshotFileEffects.system
        effects.removeFile = { _ in -1 }
        let writer = SnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: OpenedDescriptorRefusal(), eventLog: RuntimeEventLog(capacity: 8),
            onDrainCleanup: nil, initialGeneration: 0, encodeOverride: nil, fileEffects: effects)
        writer.submit(snapshotValue(1))
        let outcome = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(outcome, .refused)
        XCTAssertEqual(writer.statistics.orphanedTemporaries, 1)
        XCTAssertTrue(writer.statistics.cleanupLatched)
    }

    /// A close that reports failure is ambiguous, so it is recorded and never retried. The descriptor is really closed
    /// by the seam, so the test leaks nothing. The writer then latches, and no file is created.
    func testUncertainCloseLatchesWithoutRetryingTheClose() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("snapshot.json")
        let closes = NIOLockedValueBox(0)
        var effects = SnapshotFileEffects.system
        effects.closeDescriptor = { descriptor in
            closes.withLockedValue { $0 += 1 }
            _ = close(descriptor)
            return -1
        }
        let writer = SnapshotArtifactWriter(
            fileURL: destination, logger: DiscardingLogSink(), destinationGuard: UncheckedRecordFileDestination(),
            eventLog: RuntimeEventLog(capacity: 8), onDrainCleanup: nil, initialGeneration: 0,
            encodeOverride: nil, fileEffects: effects)
        writer.submit(snapshotValue(1))
        let first = await writer.drain(until: deadline(in: 10))
        writer.submit(snapshotValue(2))
        let second = await writer.drain(until: deadline(in: 10))
        XCTAssertEqual(first, .writeFailed)
        XCTAssertEqual(second, .writeFailed)
        XCTAssertEqual(closes.withLockedValue { $0 }, 1, "the ambiguous close was not retried")
        XCTAssertEqual(writer.statistics.uncertainCloses, 1)
        XCTAssertTrue(writer.statistics.cleanupLatched)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "a latched writer created no file")
        let temporaries = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".snapshot.json.") }
        XCTAssertEqual(temporaries.count, 0, "the temporary was removed after the ambiguous close")
    }
}

/// Refuses the opened temporary descriptor, after the writer created it.
private final class OpenedDescriptorRefusal: RecordFileDestinationGuarding, @unchecked Sendable {
    func admit(destination: URL) throws {}

    func admit(openedDescriptor descriptor: Int32, destination: URL) throws {
        throw RecordFileDestinationRefusal(reason: .protectedIdentity, resource: .config)
    }
}
