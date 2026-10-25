// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

// MARK: - DiscardingConnectionAuditSink

/// No-op `ConnectionAuditSink`. Default-injected when audit logging is
/// disabled in config; lets the kernel take `any ConnectionAuditSink`
/// unconditionally without nullable-sink ceremony at every call site.
package final class DiscardingConnectionAuditSink: ConnectionAuditSink, @unchecked Sendable {
    package init() {}
    package func record(_ record: ConnectionAuditRecord) {
        // Intentionally empty.
    }
    /// Nothing is ever queued, so nothing can be pending.
    package func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome { .drained }
}

// MARK: - RecordingConnectionAuditSink

/// In-memory `ConnectionAuditSink`. Tests / scenario harnesses inject
/// this and read `records()` after the action under test; the daemon
/// itself never uses it. Thread-safe (`NIOLockedValueBox`) so concurrent
/// records from multiple event loops are captured without interleaving.
package final class RecordingConnectionAuditSink: ConnectionAuditSink, @unchecked Sendable {
    private struct State {
        var records: [ConnectionAuditRecord] = []
        var statistics = RecordWriterStatistics()
    }
    private let captured = NIOLockedValueBox(State())
    private let capacity: Int
    private let maxBytes: Int

    package init(capacity: Int = 10_000, maxBytes: Int = 4 * 1_048_576) {
        precondition(capacity > 0 && maxBytes > 0)
        self.capacity = capacity
        self.maxBytes = maxBytes
    }

    package var statistics: RecordWriterStatistics { captured.withLockedValue { $0.statistics } }

    package func record(_ record: ConnectionAuditRecord) {
        do {
            let bytes = try CanonicalJSON.encoder().encode(record).count
            captured.withLockedValue {
                guard $0.records.count < capacity, bytes <= maxBytes - $0.statistics.pendingBytes else {
                    $0.statistics.droppedRecords &+= 1
                    return
                }
                $0.records.append(record)
                $0.statistics.pendingBytes += bytes
                $0.statistics.pendingRecords += 1
            }
        } catch {
            captured.withLockedValue { $0.statistics.failedRecords &+= 1 }
        }
    }

    /// Records are captured synchronously in `record(_:)`, so nothing is ever pending.
    package func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome { .drained }

    /// Insertion-ordered bounded capture; overflow drops incoming records.
    package func records() -> [ConnectionAuditRecord] {
        captured.withLockedValue { $0.records }
    }

    package func clear() {
        captured.withLockedValue {
            $0.records.removeAll(keepingCapacity: false)
            $0.statistics.pendingBytes = 0
            $0.statistics.pendingRecords = 0
        }
    }
}

// MARK: - FileConnectionAuditSink

/// Bounded asynchronous NDJSON writer using batched append and record-aligned rotation.
/// A destination the guard refuses is latched: the sink emits one refusal event and
/// counts later records as dropped. The runtime keeps running (#222).
package final class FileConnectionAuditSink: ConnectionAuditSink, @unchecked Sendable {
    package static let defaultMaxBytes = 10 * 1_048_576
    private let writer: BoundedRecordWriter
    private let maxBytes: Int
    private let logger: any LogSink
    private let gate: RecordFileDestinationGate

    package init(fileURL: URL, maxBytes: Int = FileConnectionAuditSink.defaultMaxBytes,
                 logger: any LogSink, limits: RecordWriterLimits = .init(),
                 destinationGuard: any RecordFileDestinationGuarding, eventLog: RuntimeEventLog) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
        self.logger = logger
        let gate = RecordFileDestinationGate(sink: .connectionAudit, eventLog: eventLog, logger: logger)
        self.gate = gate
        let file = RotatingRecordFile(fileURL: fileURL, maxBytes: maxBytes, destinationGuard: destinationGuard)
        writer = BoundedRecordWriter(limits: limits, write: { try gate.write($0, to: file) },
            reportFailure: { message in
                // A refused batch is already reported by its event; logging it again would repeat the loss.
                guard !gate.isRefused else { return }
                logger.log(.warning, "Failed to write audit.ndjson: \(message)", category: .general)
            })
    }

    package var statistics: RecordWriterStatistics { writer.statistics }

    package func record(_ record: ConnectionAuditRecord) {
        guard !gate.isRefused else {
            writer.recordDrop()
            return
        }
        do {
            var data = try CanonicalJSON.encoder().encode(record)
            data.append(0x0A)
            guard data.count <= maxBytes else {
                writer.recordDrop()
                logger.log(.warning, "Skipping oversized audit record (>= maxBytes).", category: .general)
                return
            }
            writer.append(data)
        } catch {
            writer.recordDrop()
            logger.log(.warning, "Failed to encode audit record: \(error.localizedDescription)", category: .general)
        }
    }

    @discardableResult
    package func flush(timeout: TimeInterval = 2) -> Bool { writer.flush(timeout: timeout) }

    package func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
        await writer.drain(until: deadline)
    }
}
