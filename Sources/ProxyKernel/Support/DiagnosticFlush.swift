// SPDX-License-Identifier: Apache-2.0
import Foundation
import RuntimeEvents

/// One absolute monotonic deadline for an exit's diagnostic flushes, computed once when the phase starts.
/// Each wait is capped at `writerWait` and cut to the time the phase has left, so no writer gets a fresh budget.
package struct DiagnosticFlushPhase: Sendable {
    /// The audit, events and snapshot envelope: the existing 2 + 2 + 2 s, unchanged in total.
    package static let defaultBudget: Duration = .seconds(6)
    /// The per-wait cap the existing flushes used.
    package static let writerWait: Duration = .seconds(2)

    private let deadline: ContinuousClock.Instant

    /// `cap` is an absolute deadline the phase may not outlast, such as a quit's one total (decision 0039). It only cuts the envelope:
    /// a cap already passed leaves no wait, and none extends it. Writes already started are not cancelled.
    package init(budget: Duration = DiagnosticFlushPhase.defaultBudget, cappedAt cap: ContinuousClock.Instant? = nil) {
        let envelope = ContinuousClock.now.advanced(by: budget)
        deadline = cap.map { min($0, envelope) } ?? envelope
    }

    /// The absolute deadline for the next writer: the existing per-writer cap measured from now, or the phase
    /// deadline when that is sooner. Nil once the phase deadline has passed. The writer checks it again at its own
    /// registration, so a late start is not given a fresh window.
    package func nextDeadline() -> ContinuousClock.Instant? {
        let now = ContinuousClock.now
        guard now < deadline else { return nil }
        return min(deadline, now.advanced(by: Self.writerWait))
    }
}

/// Whether the snapshot's own unconfirmed-result event was confirmed. It is emitted after the events wait, so only a
/// later events wait can cover it, and the phase spends at most one such wait.
package enum SnapshotEventConfirmation: String, Sendable, Equatable {
    /// No snapshot event was emitted, because the snapshot is current.
    case notNeeded = "not_needed"
    /// The one events wait spent after the snapshot event drained, and the events writer recorded no drop or failure
    /// at any time up to the end of that wait.
    case confirmed
    /// No events wait can cover the event, or the wait did not drain it without recorded loss. The console line is still
    /// emitted. Nothing claims the event reached the file.
    case unconfirmed
}

/// What one exit's diagnostic phase established, per writer.
package struct DiagnosticFlushReport: Sendable, Equatable {
    /// Queue drain outcomes. These are facts about queued records only, not about writes.
    package var audit: RecordDrainOutcome
    package var events: RecordDrainOutcome
    /// The phase's single events wait beyond the first events wait. It is the early retry after an audit or events
    /// shortfall, or the late confirmation for the snapshot event, never both.
    package var eventsRetry: RecordDrainOutcome?
    package var snapshot: SnapshotFlushOutcome
    package var snapshotEvent: SnapshotEventConfirmation
    /// The writers' counters when the phase ended. They include history from before this phase, so a drop or failure
    /// earlier in the process keeps a later confirmation conservative.
    package var auditStatistics: RecordWriterStatistics
    package var eventsStatistics: RecordWriterStatistics
    /// The logger's own drain, which the host runs before the artifacts, a fact about its queues only. It is separate from the
    /// artifacts and never part of `allConfirmed`. `unavailable` until the owner that drains the logger sets it.
    package var logger: RecordDrainOutcome = .unavailable

    /// The events queue confirmed its records: drained by this phase's wait, with no recorded drop or failure.
    package var eventsConfirmed: Bool {
        (events == .drained || eventsRetry == .drained) && DiagnosticFlush.lossless(eventsStatistics)
    }

    /// Every artifact writer confirmed: both queues drained with no recorded drop or failure, and the snapshot is current.
    /// Queue drain alone is not a confirmation, since a failed batch empties the queue too. The logger is not an artifact.
    package var allConfirmed: Bool {
        audit == .drained && DiagnosticFlush.lossless(auditStatistics) && eventsConfirmed && snapshot == .current
    }
}

/// The one owner of an exit's diagnostic flush order: audit, then events, then the snapshot, all inside one
/// `DiagnosticFlushPhase`. The phase spends at most one events wait beyond its first events wait. Nothing here gates
/// control, admission or shutdown. The caller decides what to do with the report.
///
/// A drain is confirmed only conservatively. The writer's drop and failure counters must be zero when the wait ends,
/// including the counts recorded before this phase. A loss earlier in the process therefore keeps later confirmations
/// unconfirmed. That is the stated, accepted cost.
package enum DiagnosticFlush {
    /// No drop or failure has been recorded.
    package static func lossless(_ statistics: RecordWriterStatistics) -> Bool {
        statistics.droppedRecords == 0 && statistics.failedRecords == 0
    }

    package static func run(
        phase: DiagnosticFlushPhase,
        audit: any ConnectionAuditSink,
        events: RuntimeEventFileWriter,
        snapshot: any SnapshotArtifactWriting,
        eventLog: RuntimeEventLog,
        logger: any LogSink
    ) async -> DiagnosticFlushReport {
        var auditOutcome = RecordDrainOutcome.skippedBudget
        if let deadline = phase.nextDeadline() { auditOutcome = await audit.drain(until: deadline) }
        var eventsOutcome = RecordDrainOutcome.skippedBudget
        if let deadline = phase.nextDeadline() { eventsOutcome = await events.drain(until: deadline) }

        let auditFlushed = auditOutcome == .drained && lossless(audit.statistics)
        let eventsFlushed = eventsOutcome == .drained && lossless(events.statistics)
        // The one events wait beyond the first. Whichever point spends it, it is spent once.
        var retry: RecordDrainOutcome?
        if !auditFlushed || !eventsFlushed {
            // The marker is appended in memory. It is persisted only if the retry below drains without loss. Its flags
            // are conservative, and its outcome codes name what each writer reported.
            let event = RuntimeEvent(kind: .health, event: "observability.flush_timeout",
                                     detail: "auditFlushed=\(auditFlushed) eventsFlushed=\(eventsFlushed) "
                                         + "audit=\(auditOutcome.rawValue) events=\(eventsOutcome.rawValue)")
            eventLog.append(event)
            logger.log(.warning, "\(event.event) \(event.detail ?? "")", category: .general)
            if let deadline = phase.nextDeadline() { retry = await events.drain(until: deadline) }
        }

        var snapshotOutcome = SnapshotFlushOutcome.skippedBudget
        if let deadline = phase.nextDeadline() { snapshotOutcome = await snapshot.drain(until: deadline) }
        var snapshotEvent = SnapshotEventConfirmation.notNeeded
        if snapshotOutcome != .current {
            snapshotOutcome.reportIfUnconfirmed(eventLog: eventLog, logger: logger)
            // The snapshot event was appended in memory; the sink may have dropped it. Only a lossless remaining wait can confirm it.
            if retry == nil, let deadline = phase.nextDeadline() {
                retry = await events.drain(until: deadline)
                snapshotEvent = retry == .drained && lossless(events.statistics) ? .confirmed : .unconfirmed
            } else {
                snapshotEvent = .unconfirmed
            }
        }

        return DiagnosticFlushReport(audit: auditOutcome, events: eventsOutcome, eventsRetry: retry,
                                     snapshot: snapshotOutcome, snapshotEvent: snapshotEvent,
                                     auditStatistics: audit.statistics, eventsStatistics: events.statistics)
    }
}

extension LifecycleLogFlushOutcome {
    /// The typed outcome of a logger drain that did not confirm its lines; nil for `drained`, which records nothing.
    package init?(_ outcome: RecordDrainOutcome) {
        switch outcome {
        case .drained: return nil
        case .timedOut: self = .timedOut
        case .busy: self = .busy
        case .skippedBudget: self = .skippedBudget
        case .cancelled: self = .cancelled
        case .unavailable: self = .unavailable
        }
    }
}
