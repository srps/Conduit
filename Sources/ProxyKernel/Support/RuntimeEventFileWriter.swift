// SPDX-License-Identifier: Apache-2.0
import Foundation

package final class RuntimeEventFileWriter: @unchecked Sendable {
    package static let defaultMaxBytes = 1_048_576

    private let writer: BoundedRecordWriter
    private let maxBytes: Int
    private let logger: any LogSink

    package init(fileURL: URL, maxBytes: Int = RuntimeEventFileWriter.defaultMaxBytes,
                 logger: any LogSink, limits: RecordWriterLimits = .init()) {
        precondition(maxBytes > 0)
        self.maxBytes = maxBytes
        self.logger = logger
        let file = RotatingRecordFile(fileURL: fileURL, maxBytes: maxBytes)
        writer = BoundedRecordWriter(limits: limits, write: { try file.append($0) },
            reportFailure: { logger.log(.warning, "Failed to write events.ndjson: \($0)", category: .general) })
    }

    package var statistics: RecordWriterStatistics { writer.statistics }

    package func record(_ event: RuntimeEvent) {
        do {
            var data = try CanonicalJSON.encoder().encode(event)
            data.append(0x0A)
            guard data.count <= maxBytes else {
                writer.recordDrop()
                logger.log(.warning, "Skipping oversized runtime event for events.ndjson.", category: .general)
                return
            }
            writer.append(data)
        } catch {
            writer.recordDrop()
            logger.log(.warning, "Failed to encode runtime event: \(error.localizedDescription)", category: .general)
        }
    }

    @discardableResult
    package func flush(timeout: TimeInterval = 2) -> Bool { writer.flush(timeout: timeout) }

    /// Shutdown gets one bounded retry to persist the timeout observation.
    /// The retry never generates another event, even if storage stays blocked.
    @discardableResult
    package func flushReportingTimeout(
        auditFlushed: Bool, eventLog: RuntimeEventLog, timeout: TimeInterval = 2
    ) -> Bool {
        let eventsFlushed = flush(timeout: timeout)
        guard !auditFlushed || !eventsFlushed else { return true }
        eventLog.append(RuntimeEvent(kind: .health, event: "observability.flush_timeout",
            detail: "auditFlushed=\(auditFlushed) eventsFlushed=\(eventsFlushed)"))
        flush(timeout: timeout)
        return false
    }
}
