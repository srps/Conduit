// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// The shared phase owner: one absolute deadline for audit, events and snapshot, each writer capped at its own
/// 2 s and cut to what the phase has left. At most one events wait beyond the first. A drain is only a queue fact;
/// a confirmation also needs no recorded drop or failure.
final class DiagnosticDrainPhaseTests: XCTestCase {
    /// Audit that cannot drain asynchronously. The phase must call it unavailable, not drained.
    private struct UndrainableAuditSink: ConnectionAuditSink {
        func record(_ record: ConnectionAuditRecord) {}
        @discardableResult func flush(timeout: TimeInterval) -> Bool { false }
    }

    private func eventsFile(in directory: URL, log: RuntimeEventLog, limits: RecordWriterLimits = .init(),
                            guardForEvents: any RecordFileDestinationGuarding = UncheckedRecordFileDestination()) -> RuntimeEventFileWriter {
        let writer = RuntimeEventFileWriter(fileURL: directory.appendingPathComponent("events.ndjson"),
                                            logger: DiscardingLogSink(), limits: limits,
                                            destinationGuard: guardForEvents, eventLog: log)
        log.setSink { writer.record($0) }
        return writer
    }

    private func persistedEvents(in directory: URL) throws -> String {
        String(decoding: try Data(contentsOf: directory.appendingPathComponent("events.ndjson")), as: UTF8.self)
    }

    func testEachWriterGetsTheCapOrTheRemainderNeverMore() {
        let phase = DiagnosticFlushPhase(budget: .seconds(6))
        let capped = phase.nextDeadline()
        XCTAssertNotNil(capped)
        XCTAssertLessThanOrEqual(capped ?? ContinuousClock.now, ContinuousClock.now.advanced(by: .seconds(2)))

        let short = DiagnosticFlushPhase(budget: .seconds(1))
        let cut = short.nextDeadline()
        XCTAssertNotNil(cut)
        XCTAssertLessThanOrEqual(cut ?? ContinuousClock.now, ContinuousClock.now.advanced(by: .seconds(1)))
    }

    /// The logger's drain is reported beside the artifacts and never changes their confirmation: unset, it is `unavailable`, not a
    /// claimed drain, and no outcome of it makes a confirmed phase unconfirmed or the reverse.
    func testTheLoggerOutcomeStaysApartFromTheArtifactConfirmation() {
        var confirmed = DiagnosticFlushReport(audit: .drained, events: .drained, eventsRetry: nil, snapshot: .current,
                                              snapshotEvent: .notNeeded, auditStatistics: RecordWriterStatistics(),
                                              eventsStatistics: RecordWriterStatistics())
        XCTAssertEqual(confirmed.logger, .unavailable)
        var unconfirmed = confirmed
        unconfirmed.events = .timedOut
        for outcome in [RecordDrainOutcome.drained, .timedOut, .busy, .skippedBudget, .cancelled, .unavailable] {
            confirmed.logger = outcome
            unconfirmed.logger = outcome
            XCTAssertTrue(confirmed.allConfirmed, "\(outcome)")
            XCTAssertFalse(unconfirmed.allConfirmed, "\(outcome)")
        }
    }

    func testExhaustedPhaseSkipsEveryWriterAndSaysSo() async {
        let events = RuntimeEventLog(capacity: 16)
        let logger = RecordingLogSink()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer = RuntimeEventFileWriter(fileURL: directory.appendingPathComponent("events.ndjson"),
                                            logger: DiscardingLogSink(),
                                            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(budget: .zero), audit: DiscardingConnectionAuditSink(), events: writer,
            snapshot: snapshots, eventLog: events, logger: logger)
        XCTAssertEqual(report.audit, .skippedBudget)
        XCTAssertEqual(report.events, .skippedBudget)
        XCTAssertNil(report.eventsRetry)
        XCTAssertEqual(report.snapshot, .skippedBudget)
        XCTAssertEqual(report.snapshotEvent, .unconfirmed)
        XCTAssertFalse(report.allConfirmed)
        XCTAssertTrue(logger.containsMessage("observability.flush_timeout", at: .warning),
                      "a lost file marker still has its bounded derived log attempt")
        let marker = events.events.first { $0.event == "observability.flush_timeout" }
        XCTAssertEqual(marker?.detail, "auditFlushed=false eventsFlushed=false audit=skipped_budget events=skipped_budget")
        XCTAssertEqual(events.events.first { $0.event == "observability.snapshot_flush_unconfirmed" }?.detail,
                       "outcome=skipped_budget")
    }

    /// Nothing failed, so nothing is retried, and the report claims complete only because every writer confirmed.
    func testCurrentSnapshotWithDrainedWritersIsConfirmedWithNoRetry() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = RuntimeEventLog(capacity: 16)
        let eventsWriter = eventsFile(in: directory, log: events)
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        snapshots.submit(snapshotValue(1))
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: DiscardingConnectionAuditSink(), events: eventsWriter,
            snapshot: snapshots, eventLog: events, logger: DiscardingLogSink())
        XCTAssertEqual(report.snapshot, .current)
        XCTAssertEqual(report.snapshotEvent, .notNeeded)
        XCTAssertNil(report.eventsRetry)
        XCTAssertTrue(report.allConfirmed)
    }

    /// Early events drained, so no retry was spent. The snapshot then fails, and the phase's one confirmation covers
    /// its event: the late wait drains it into the file with no recorded loss. The report claims no complete flush.
    func testLateSnapshotFailureSpendsTheOneRemainingConfirmation() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let events = RuntimeEventLog(capacity: 32)
        let eventsWriter = eventsFile(in: directory, log: events)
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: blocker.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        snapshots.submit(snapshotValue(1))
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: DiscardingConnectionAuditSink(), events: eventsWriter,
            snapshot: snapshots, eventLog: events, logger: DiscardingLogSink())
        XCTAssertEqual(report.audit, .drained)
        XCTAssertEqual(report.events, .drained)
        XCTAssertEqual(report.snapshot, .writeFailed)
        XCTAssertEqual(report.eventsRetry, .drained)
        XCTAssertEqual(report.snapshotEvent, .confirmed)
        XCTAssertFalse(report.allConfirmed, "a failed write is never a complete flush, whatever the queue drained")
        XCTAssertNil(events.events.first { $0.event == "observability.flush_timeout" }, "no writer timed out")
        XCTAssertEqual(events.events.first { $0.event == "observability.snapshot_flush_unconfirmed" }?.detail,
                       "outcome=write_failed")
        XCTAssertTrue(try persistedEvents(in: directory).contains("observability.snapshot_flush_unconfirmed"),
                      "the confirmation drained the snapshot event into the file")
    }

    /// Audit could not drain, so the early retry is spent. A later snapshot failure gets no second confirmation: the
    /// report stays unconfirmed, and the retry is still the early one. Only one retry ever runs.
    func testEarlyRetryIsNotRepeatedAfterASnapshotFailure() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let events = RuntimeEventLog(capacity: 32)
        let eventsWriter = eventsFile(in: directory, log: events)
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: blocker.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        snapshots.submit(snapshotValue(1))
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: UndrainableAuditSink(), events: eventsWriter,
            snapshot: snapshots, eventLog: events, logger: DiscardingLogSink())
        XCTAssertEqual(report.audit, .unavailable)
        XCTAssertEqual(report.eventsRetry, .drained, "the single retry was the early one")
        XCTAssertEqual(report.snapshotEvent, .unconfirmed, "a second confirmation was not run")
        XCTAssertFalse(report.allConfirmed)
        XCTAssertEqual(events.events.filter { $0.event == "observability.flush_timeout" }.count, 1)
    }

    /// The snapshot consumes the phase's time while its write is held. The late confirmation finds no time left,
    /// so the event is unconfirmed, the console line is still derived, and no retry runs.
    func testLateSnapshotFailureWithoutTimeLeftIsUnconfirmedWithNoRetry() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let held = HeldDestinationGuard()
        let events = RuntimeEventLog(capacity: 32)
        let eventsWriter = eventsFile(in: directory, log: events)
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: held, eventLog: events)
        snapshots.submit(snapshotValue(1))
        XCTAssertEqual(held.entered.wait(timeout: .now() + 10), .success)
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(budget: .milliseconds(200)), audit: DiscardingConnectionAuditSink(),
            events: eventsWriter, snapshot: snapshots, eventLog: events, logger: DiscardingLogSink())
        held.release()
        XCTAssertNotEqual(report.snapshot, .current)
        XCTAssertNil(report.eventsRetry, "no time was left for a confirmation")
        XCTAssertEqual(report.snapshotEvent, .unconfirmed)
        XCTAssertFalse(report.allConfirmed)
        XCTAssertEqual(events.events.first { $0.event == "observability.snapshot_flush_unconfirmed" }?.detail,
                       "outcome=\(report.snapshot.rawValue)")
    }

    /// (1) The events gate latched before the marker. The marker is refused at the gate, counted as a drop, and the
    /// drained queue is not a confirmation.
    func testEventGateRefusedBeforeTheMarkerIsNotConfirmed() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let eventsPath = directory.appendingPathComponent("events.ndjson")
        let events = RuntimeEventLog(capacity: 64)
        let refusing = systemRecordFileDestinationGuard(protected: [ProtectedRecordFile(resource: .config, url: eventsPath)])
        let eventsWriter = eventsFile(in: directory, log: events, guardForEvents: refusing)
        events.append(RuntimeEvent(kind: .health, event: "fixture.before-marker"))
        let latched = await eventsWriter.drain(until: deadline(in: 10))
        XCTAssertEqual(latched, .drained)
        XCTAssertGreaterThanOrEqual(eventsWriter.statistics.failedRecords + eventsWriter.statistics.droppedRecords, 1)

        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: UndrainableAuditSink(), events: eventsWriter,
            snapshot: makeSnapshotArtifactWriter(fileURL: directory.appendingPathComponent("snapshot.json"),
                                                 logger: DiscardingLogSink(),
                                                 destinationGuard: UncheckedRecordFileDestination(), eventLog: events),
            eventLog: events, logger: DiscardingLogSink())
        XCTAssertEqual(report.events, .drained)
        XCTAssertFalse(report.eventsConfirmed, "drained with recorded loss is not a confirmation")
        XCTAssertGreaterThanOrEqual(report.eventsStatistics.droppedRecords, 1, "the marker was refused at the gate")
        XCTAssertEqual(events.events.first { $0.event == "observability.flush_timeout" }?.detail,
                       "auditFlushed=false eventsFlushed=false audit=unavailable events=drained")
        XCTAssertEqual(report.snapshotEvent, .unconfirmed)
        XCTAssertFalse(report.allConfirmed)
    }

    /// (2) A batch write fails, and the queue is then empty. Drained is true; the failed record is still not confirmed.
    func testBatchWriteFailureThenEmptyQueueIsDrainedButNotConfirmed() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let events = RuntimeEventLog(capacity: 32)
        let eventsWriter = RuntimeEventFileWriter(fileURL: blocker.appendingPathComponent("events.ndjson"),
                                                  logger: DiscardingLogSink(),
                                                  destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        events.setSink { eventsWriter.record($0) }
        events.append(RuntimeEvent(kind: .health, event: "fixture.failing-batch"))
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: DiscardingConnectionAuditSink(), events: eventsWriter,
            snapshot: makeSnapshotArtifactWriter(fileURL: directory.appendingPathComponent("snapshot.json"),
                                                 logger: DiscardingLogSink(),
                                                 destinationGuard: UncheckedRecordFileDestination(), eventLog: events),
            eventLog: events, logger: DiscardingLogSink())
        XCTAssertEqual(report.events, .drained)
        XCTAssertGreaterThanOrEqual(report.eventsStatistics.failedRecords, 1, "the batch failed; the marker failed too")
        XCTAssertFalse(report.eventsConfirmed)
        XCTAssertEqual(report.snapshotEvent, .unconfirmed)
        XCTAssertFalse(report.allConfirmed)
    }

    /// (3) The marker is dropped at capacity: the byte limit is one byte, so no record fits. The drop is counted, and
    /// the marker and the snapshot event are not reported as confirmed.
    func testCapacityDropOnTheMarkerIsNotConfirmed() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var limits = RecordWriterLimits()
        limits.maxPendingBytes = 1
        let events = RuntimeEventLog(capacity: 32)
        let eventsWriter = eventsFile(in: directory, log: events, limits: limits)
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: UndrainableAuditSink(), events: eventsWriter,
            snapshot: makeSnapshotArtifactWriter(fileURL: directory.appendingPathComponent("snapshot.json"),
                                                 logger: DiscardingLogSink(),
                                                 destinationGuard: UncheckedRecordFileDestination(), eventLog: events),
            eventLog: events, logger: DiscardingLogSink())
        XCTAssertGreaterThanOrEqual(report.eventsStatistics.droppedRecords, 1)
        // The marker's flags describe the writers before the marker was appended. The marker itself was dropped at
        // capacity, and that drop is in the statistics, so the flags alone are never the report's claim.
        XCTAssertEqual(events.events.first { $0.event == "observability.flush_timeout" }?.detail,
                       "auditFlushed=false eventsFlushed=true audit=unavailable events=drained")
        XCTAssertFalse(report.eventsConfirmed, "the recorded drop keeps the events unconfirmed")
        XCTAssertEqual(report.snapshotEvent, .unconfirmed, "a dropped event is never called confirmed")
        XCTAssertFalse(report.allConfirmed)
    }

    /// What one phase reported when its first events wait's timer body was held, and whether a later events timer started.
    private struct HeldTimerRun {
        let report: DiagnosticFlushReport
        let elapsed: Duration
        let laterTimer: DispatchTimeoutResult
    }

    /// The first events wait drains while its timer body is held, so the caller resolves and the cancelled body outlives
    /// it. The phase's one further events wait then meets the marker's held write. Writes from before the phase are
    /// settled first, so the two held writes are the fixture event's and the marker's. `audit` and `snapshotURL` decide
    /// whether that further wait is the early retry or the late confirmation.
    private func runWithTheFirstEventsTimerHeld(audit: any ConnectionAuditSink, snapshotURL: URL, directory: URL,
                                                settledSnapshot: SnapshotFlushOutcome) async -> HeldTimerRun {
        let events = RuntimeEventLog(capacity: 32)
        let writes = HeldDestinationGuard(holds: 0)
        let timer = HeldTimerBody()
        let eventsWriter = RuntimeEventFileWriter(fileURL: directory.appendingPathComponent("events.ndjson"),
                                                  logger: DiscardingLogSink(), destinationGuard: writes, eventLog: events,
                                                  drainSleep: { try await timer.sleep(until: $0) })
        events.setSink { eventsWriter.record($0) }
        let snapshots = makeSnapshotArtifactWriter(fileURL: snapshotURL, logger: DiscardingLogSink(),
                                                   destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        snapshots.submit(snapshotValue(1))
        let settled = await snapshots.drain(until: deadline(in: 10))
        XCTAssertEqual(settled, settledSnapshot)
        XCTAssertTrue(eventsWriter.flush(timeout: 10), "the writes from before the phase are settled")

        writes.arm(2)
        events.append(RuntimeEvent(kind: .health, event: "fixture.held-write"))
        XCTAssertEqual(writes.entered.wait(timeout: .now() + 10), .success, "the fixture event's write is held")
        // The phase's own duration, measured where it returns, not when the test collects it.
        let flush = Task {
            let started = ContinuousClock.now
            let report = await DiagnosticFlush.run(phase: DiagnosticFlushPhase(), audit: audit, events: eventsWriter,
                                                   snapshot: snapshots, eventLog: events, logger: DiscardingLogSink())
            return (report, started.duration(to: .now))
        }
        XCTAssertEqual(timer.entered.wait(timeout: .now() + 10), .success,
                       "the first events wait registered, and its timer body is held")
        writes.release()
        XCTAssertEqual(writes.entered.wait(timeout: .now() + 10), .success, "the marker's write is held")
        let laterTimer = timer.joinLaterStart()
        writes.release()
        let (report, elapsed) = await flush.value
        timer.release()
        return HeldTimerRun(report: report, elapsed: elapsed, laterTimer: laterTimer)
    }

    /// The late confirmation is spent while the first events wait's cancelled timer body is still held. It still
    /// registers, waits for the marker inside the phase's one deadline, and confirms it.
    func testDiagnosticFlushLateConfirmationIsNotRefusedByTheFirstEventsWaitsHeldTimerBody() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let blocker = directory.appendingPathComponent("blocker")
        try Data("not a directory".utf8).write(to: blocker)
        let run = await runWithTheFirstEventsTimerHeld(
            audit: DiscardingConnectionAuditSink(), snapshotURL: blocker.appendingPathComponent("snapshot.json"),
            directory: directory, settledSnapshot: .writeFailed)
        XCTAssertEqual(run.laterTimer, .success, "the late confirmation registered its own timer beside the held one")
        XCTAssertEqual(run.report.audit, .drained)
        XCTAssertEqual(run.report.events, .drained)
        XCTAssertEqual(run.report.snapshot, .writeFailed)
        XCTAssertEqual(run.report.eventsRetry, .drained, "the late confirmation waited for the marker")
        XCTAssertEqual(run.report.snapshotEvent, .confirmed)
        XCTAssertEqual(run.report.eventsStatistics.pendingRecords, 0)
        XCTAssertEqual(run.report.eventsStatistics.flushTimeouts, 0)
        XCTAssertTrue(DiagnosticFlush.lossless(run.report.eventsStatistics))
        XCTAssertLessThan(run.elapsed, DiagnosticFlushPhase.defaultBudget)
        // The file is read only once the wait claims the marker drained; otherwise the read races the released write.
        guard run.report.eventsRetry == .drained else { return }
        XCTAssertTrue(try persistedEvents(in: directory).contains("observability.snapshot_flush_unconfirmed"))
    }

    /// The early retry is spent while the first events wait's cancelled timer body is still held. It still registers,
    /// waits for the timeout marker, and is the phase's only further events wait.
    func testDiagnosticFlushEarlyRetryIsNotRefusedByTheFirstEventsWaitsHeldTimerBody() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let run = await runWithTheFirstEventsTimerHeld(
            audit: UndrainableAuditSink(), snapshotURL: directory.appendingPathComponent("snapshot.json"),
            directory: directory, settledSnapshot: .current)
        XCTAssertEqual(run.laterTimer, .success, "the early retry registered its own timer beside the held one")
        XCTAssertEqual(run.report.audit, .unavailable)
        XCTAssertEqual(run.report.events, .drained)
        XCTAssertEqual(run.report.eventsRetry, .drained, "the early retry waited for the marker")
        XCTAssertEqual(run.report.snapshot, .current)
        XCTAssertEqual(run.report.snapshotEvent, .notNeeded)
        XCTAssertFalse(run.report.allConfirmed)
        XCTAssertEqual(run.report.eventsStatistics.pendingRecords, 0)
        XCTAssertEqual(run.report.eventsStatistics.flushTimeouts, 0)
        XCTAssertTrue(DiagnosticFlush.lossless(run.report.eventsStatistics))
        XCTAssertLessThan(run.elapsed, DiagnosticFlushPhase.defaultBudget)
        guard run.report.eventsRetry == .drained else { return }
        let markers = try persistedEvents(in: directory).split(separator: "\n")
            .filter { $0.contains("observability.flush_timeout") }
        XCTAssertEqual(markers.count, 1, "one marker, persisted by the one retry")
    }

    /// The events writer's two timer slots count retired bodies across calls. Two drained calls whose bodies are held
    /// leave a third non-empty wait busy, and that refusal creates no timer.
    func testDiagnosticFlushEventsWriterHoldsAtMostTwoTimerBodiesAcrossCalls() async throws {
        let directory = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let events = RuntimeEventLog(capacity: 32)
        let writes = HeldDestinationGuard(holds: 0)
        let bodies = IndexedTimerBodies(held: [0, 1])
        let eventsWriter = RuntimeEventFileWriter(fileURL: directory.appendingPathComponent("events.ndjson"),
                                                  logger: DiscardingLogSink(), destinationGuard: writes, eventLog: events,
                                                  drainSleep: { try await bodies.sleep(until: $0) })
        events.setSink { eventsWriter.record($0) }

        for call in 0..<2 {
            writes.arm(1)
            events.append(RuntimeEvent(kind: .health, event: "fixture.call-\(call)"))
            XCTAssertEqual(writes.entered.wait(timeout: .now() + 10), .success)
            let wait = Task { await eventsWriter.drain(until: deadline(in: 10)) }
            XCTAssertEqual(bodies.entered.wait(timeout: .now() + 10), .success, "call \(call) registered; its body is held")
            writes.release()
            let outcome = await wait.value
            XCTAssertEqual(outcome, .drained)
        }

        writes.arm(1)
        events.append(RuntimeEvent(kind: .health, event: "fixture.call-2"))
        XCTAssertEqual(writes.entered.wait(timeout: .now() + 10), .success)
        let third = await eventsWriter.drain(until: deadline(in: 10))
        XCTAssertEqual(third, .busy, "both slots hold retired bodies from earlier calls")
        XCTAssertEqual(bodies.calls, 2, "the refused wait created no timer")

        writes.release()
        bodies.release(0)
        bodies.release(1)
        XCTAssertTrue(eventsWriter.flush(timeout: 10))
        XCTAssertTrue(DiagnosticFlush.lossless(eventsWriter.statistics))
        XCTAssertEqual(eventsWriter.statistics.flushTimeouts, 0)
    }

    func testUndrainableAuditIsReportedUnavailableNotDrained() async {
        let events = RuntimeEventLog(capacity: 16)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let writer = RuntimeEventFileWriter(fileURL: directory.appendingPathComponent("events.ndjson"),
                                            logger: DiscardingLogSink(),
                                            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        let snapshots = makeSnapshotArtifactWriter(
            fileURL: directory.appendingPathComponent("snapshot.json"), logger: DiscardingLogSink(),
            destinationGuard: UncheckedRecordFileDestination(), eventLog: events)
        let report = await DiagnosticFlush.run(
            phase: DiagnosticFlushPhase(), audit: UndrainableAuditSink(), events: writer,
            snapshot: snapshots, eventLog: events, logger: DiscardingLogSink())
        XCTAssertEqual(report.audit, .unavailable)
        XCTAssertFalse(report.allConfirmed)
        XCTAssertEqual(events.events.first { $0.event == "observability.flush_timeout" }?.detail,
                       "auditFlushed=false eventsFlushed=true audit=unavailable events=drained")
    }
}
