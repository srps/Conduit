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
package final class FileConnectionAuditSink: ConnectionAuditSink, @unchecked Sendable {
    package static let defaultMaxBytes = 10 * 1_048_576
    private let writer: BoundedRecordWriter
    private let maxBytes: Int
    private let logger: any LogSink

    package init(fileURL: URL, maxBytes: Int = FileConnectionAuditSink.defaultMaxBytes,
                 logger: any LogSink, limits: RecordWriterLimits = .init()) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
        self.logger = logger
        let file = RotatingRecordFile(fileURL: fileURL, maxBytes: maxBytes)
        writer = BoundedRecordWriter(limits: limits, write: { try file.append($0) },
            reportFailure: { logger.log(.warning, "Failed to write audit.ndjson: \($0)", category: .general) })
    }

    package var statistics: RecordWriterStatistics { writer.statistics }

    package func record(_ record: ConnectionAuditRecord) {
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
}
