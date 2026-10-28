// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOPosix
import ProxyKernel

enum BoundedWriterScenarios {
    private struct Failure: Error { let message: String }

    static func slowStorage() async throws -> ScenarioResult {
        let start = Date()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var limits = RecordWriterLimits()
        limits.maxPendingRecords = 16
        limits.maxPendingBytes = 1024
        limits.maxBatchRecords = 16
        limits.maxBatchBytes = 1024
        let writer = BoundedRecordWriter(limits: limits, write: { _ in
            started.signal()
            release.wait()
        }, reportFailure: { _ in })
        defer {
            release.signal()
            release.signal()
            writer.flush()
        }
        writer.append(Data(repeating: 65, count: 64))
        guard storageStarted(started) else {
            throw Failure(message: "Storage fixture did not start")
        }
        // A stalled storage callback must not stall the event loop generating logs.
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try await loop.submit {
            for _ in 0..<10_000 { writer.append(Data(repeating: 66, count: 64)) }
        }.get()
        let responsive = try await loop.submit { true }.get()
        let blocked = writer.statistics
        guard responsive, blocked.pendingRecords == 16, blocked.pendingBytes == 1024,
              blocked.droppedRecords == 9985, !writer.flush(timeout: 0.01) else {
            throw Failure(message: "Storage backlog was unbounded or loss/deadline was not observable")
        }
        release.signal()
        release.signal()
        guard writer.flush(), writer.statistics.pendingRecords == 0,
              writer.statistics.writtenRecords == 16 else {
            throw Failure(message: "Storage capacity failed to recover after unblocking")
        }
        try await shutdownTimeoutPersistence()
        let confirmationNote = try await lateSnapshotConfirmation()
        let appendNote = try appendAmplification()
        let logFileNote = try await heldLogFile()
        return ScenarioResult(
            name: "bounded-writers", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 1024, durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [.init("storage bounds, loss reporting, recovery, late confirmation, append amplification and the held app log file", true)],
            notes: ["PASS: stalled storage retains at most 16 records/1024 bytes including in-flight writes",
                    "PASS: 9985 drops and flush deadline reported; event loop responsive; capacity recovered",
                    confirmationNote, appendNote, logFileNote])
    }

    /// Holds the app log file's open in its destination guard, as a stalled volume would.
    private final class HeldOpen: RecordFileDestinationGuarding, @unchecked Sendable {
        let entered = DispatchSemaphore(value: 0)
        let released = DispatchSemaphore(value: 0)
        func admit(destination: URL) throws {
            entered.signal()
            _ = released.wait(timeout: .now() + 10)
        }
        func admit(openedDescriptor descriptor: Int32, destination: URL) throws {}
    }

    /// The app's file log writer, through its factory, with its open held. Writes from an event loop stay non-blocking and bounded by
    /// the default limits, counting the held write; the excess is dropped exactly. Its waits report the queue (timed out at the deadline,
    /// busy while that wait's notify is held, drained after release), the admitted lines all reach the file, and once closed a write is
    /// counted dropped and the file is never reopened.
    private static func heldLogFile() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-applog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("proxy.log")
        let events = RuntimeEventLog(capacity: 16)
        let held = HeldOpen()
        let file = rotatingLogFile(url: url, destinationGuard: held,
                                   gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: DiscardingLogSink()),
                                   eventLog: events, logger: DiscardingLogSink())
        let bound = RecordWriterLimits().maxPendingRecords
        file.write(Data("line 0\n".utf8))
        guard storageStarted(held.entered) else { throw Failure(message: "The app log open was not held") }
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try await loop.submit {
            for index in 1..<(bound + 10) { file.write(Data("line \(index)\n".utf8)) }
        }.get()
        let blocked = file.statistics
        let timedOut = await file.drain(until: ContinuousClock.now.advanced(by: .milliseconds(200)))
        let busy = await file.drain(until: ContinuousClock.now.advanced(by: .seconds(5)))
        held.released.signal()
        guard blocked.pendingRecords == bound, blocked.droppedRecords == 10, timedOut == .timedOut, busy == .busy,
              file.flush(timeout: 5) else {
            throw Failure(message: "The held app log was unbounded or its waits misreported: pending=\(blocked.pendingRecords) "
                + "dropped=\(blocked.droppedRecords) first=\(timedOut.rawValue) second=\(busy.rawValue)")
        }
        let drained = await file.drain(until: ContinuousClock.now.advanced(by: .seconds(5)))
        file.close()
        file.write(Data("after close\n".utf8))
        let final = file.statistics
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count
        guard drained == .drained, final.writtenRecords == UInt64(bound), final.droppedRecords == 11, final.pendingRecords == 0,
              lines == bound, events.events.isEmpty else {
            throw Failure(message: "The held app log lost admitted lines or reopened after close: written=\(final.writtenRecords) "
                + "dropped=\(final.droppedRecords) lines=\(lines)")
        }
        return "PASS: held app log admitted \(bound) of \(bound + 10) lines, dropped 10 exactly, waits timed_out then busy, "
            + "all \(bound) written after release; a write after close was dropped and nothing reopened"
    }

    /// The production writers on the real clock: a fresh events writer with a queued event, and a snapshot whose write
    /// fails. The phase's first events wait drains, and its one further wait must confirm the snapshot's marker inside the
    /// phase's own deadline, with no recorded loss. This guards the composition; the held-timer ordering that once left
    /// that wait busy is reproduced deterministically only by the unit tests.
    private static func lateSnapshotConfirmation() async throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-confirm-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let url = directory.appendingPathComponent("events.ndjson")
        let events = RuntimeEventLog(capacity: 32)
        let writer = RuntimeEventFileWriter(fileURL: url, logger: DiscardingLogSink(),
                                            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        events.setSink { writer.record($0) }
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: blocker.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        snapshots.submit(ProxyOrchestratorSnapshot())
        events.append(RuntimeEvent(kind: .health, event: "fixture.before-phase"))
        let started = ContinuousClock.now
        let report = await DiagnosticFlush.run(phase: DiagnosticFlushPhase(), audit: DiscardingConnectionAuditSink(),
                                               events: writer, snapshot: snapshots, eventLog: events,
                                               logger: DiscardingLogSink())
        let elapsed = started.duration(to: .now)
        let statistics = report.eventsStatistics
        guard report.events == .drained, report.snapshot == .writeFailed, report.eventsRetry == .drained,
              report.snapshotEvent == .confirmed, elapsed < DiagnosticFlushPhase.defaultBudget,
              statistics.pendingRecords == 0, statistics.droppedRecords == 0, statistics.failedRecords == 0,
              statistics.flushTimeouts == 0 else {
            throw Failure(message: "The late snapshot confirmation was not confirmed inside the phase: events=\(report.events.rawValue) "
                + "snapshot=\(report.snapshot.rawValue) eventsRetry=\(report.eventsRetry?.rawValue ?? "none") "
                + "snapshotEvent=\(report.snapshotEvent.rawValue) pending=\(statistics.pendingRecords) "
                + "dropped=\(statistics.droppedRecords) failed=\(statistics.failedRecords) flushTimeouts=\(statistics.flushTimeouts)")
        }
        let rows = try Data(contentsOf: url).split(separator: 0x0A).map {
            try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0))
        }
        guard rows.contains(where: { $0.event == "observability.snapshot_flush_unconfirmed" && $0.detail == "outcome=write_failed" }) else {
            throw Failure(message: "The confirmed snapshot marker is not in events.ndjson")
        }
        return "PASS: late snapshot marker confirmed by the one further events wait in \(elapsed) with zero loss; marker persisted"
    }

    private static func storageStarted(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 2) == .success
    }

    /// An audit sink that cannot drain asynchronously reports `.unavailable`, so the shared phase
    /// must mark it as unflushed rather than claim success.
    private struct UnavailableAuditSink: ConnectionAuditSink {
        func record(_ record: ConnectionAuditRecord) {}
        @discardableResult func flush(timeout: TimeInterval) -> Bool { false }
    }

    private static func shutdownTimeoutPersistence() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-flush-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.ndjson")
        let events = RuntimeEventLog(capacity: 8)
        let writer = RuntimeEventFileWriter(fileURL: url, logger: DiscardingLogSink(),
                                            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        events.setSink { writer.record($0) }
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        let report = await DiagnosticFlush.run(phase: DiagnosticFlushPhase(), audit: UnavailableAuditSink(),
                                               events: writer, snapshot: snapshots, eventLog: events,
                                               logger: DiscardingLogSink())
        guard report.audit == .unavailable, report.events == .drained, !report.allConfirmed else {
            throw Failure(message: "Shutdown concealed the audit flush failure")
        }
        // The snapshot outcome event was appended after the events wait. Drain it so the file can be read.
        guard writer.flush(timeout: 2), writer.statistics.pendingRecords == 0 else {
            throw Failure(message: "Shutdown events did not persist")
        }
        let rows = try Data(contentsOf: url).split(separator: 0x0A).map {
            try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0))
        }
        guard rows.first?.event == "observability.flush_timeout",
              rows.first?.detail == "auditFlushed=false eventsFlushed=true audit=unavailable events=drained" else {
            throw Failure(message: "Shutdown returned before persisting its timeout event")
        }
    }

    private static func appendAmplification() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.ndjson")
        let file = RotatingRecordFile(fileURL: url, maxBytes: 32_768, destinationGuard: UncheckedRecordFileDestination())
        let writer = BoundedRecordWriter(write: { try file.append($0) }, reportFailure: { _ in })
        var submittedBytes = 0
        let started = Date()
        for batch in 0..<80 {
            for index in 0..<128 {
                let event = RuntimeEvent(kind: .health, event: "fixture.\(batch * 128 + index)")
                var line = try CanonicalJSON.encoder().encode(event)
                line.append(0x0A)
                submittedBytes += line.count
                writer.append(line)
            }
            guard writer.flush() else { throw Failure(message: "Append fixture did not flush") }
        }
        let data = try Data(contentsOf: url)
        guard writer.statistics.droppedRecords == 0, writer.statistics.failedRecords == 0,
              writer.statistics.writtenRecords == 10_240, file.rotationCount > 0,
              file.bytesWritten <= UInt64(submittedBytes), data.count <= 32_768 else {
            throw Failure(message: "Append amplification, rotation, or bounded file check failed")
        }
        for line in data.split(separator: 0x0A) {
            _ = try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line))
        }
        return "PASS: 10240 events encoded/drained in \(Date().timeIntervalSince(started))s; submitted=\(submittedBytes) actualWritten=\(file.bytesWritten) rotations=\(file.rotationCount)"
    }
}
