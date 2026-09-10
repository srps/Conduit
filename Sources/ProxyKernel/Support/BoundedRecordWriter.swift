// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers

/// Limits include the batch currently blocked in storage, not just waiting records.
package struct RecordWriterLimits: Sendable {
    package var maxPendingRecords: Int = 4096
    package var maxPendingBytes: Int = 4 * 1_048_576
    package var maxBatchRecords: Int = 128
    package var maxBatchBytes: Int = 256 * 1024
    package init() {}
}

package struct RecordWriterStatistics: Sendable, Codable {
    package var pendingRecords = 0
    package var pendingBytes = 0
    package var writtenRecords: UInt64 = 0
    package var droppedRecords: UInt64 = 0
    package var failedRecords: UInt64 = 0
    package var flushTimeouts: UInt64 = 0
}

/// One scheduled drain owns all I/O. Producers never enqueue one closure per record.
/// Overflow drops the incoming record and increments a queryable loss counter.
package final class BoundedRecordWriter: @unchecked Sendable {
    private struct State {
        var pending: [Data] = []
        var draining = false
        var statistics = RecordWriterStatistics()
    }
    private let state = NIOLockedValueBox(State())
    private let queue = DispatchQueue(label: "conduit.observability-writer", qos: .utility)
    private let drained = DispatchGroup()
    private let limits: RecordWriterLimits
    private let write: @Sendable ([Data]) throws -> Void
    private let reportFailure: @Sendable (String) -> Void

    package init(limits: RecordWriterLimits = .init(),
                 write: @escaping @Sendable ([Data]) throws -> Void,
                 reportFailure: @escaping @Sendable (String) -> Void) {
        precondition(limits.maxPendingRecords > 0 && limits.maxPendingBytes > 0)
        precondition(limits.maxBatchRecords > 0 && limits.maxBatchBytes > 0)
        self.limits = limits
        self.write = write
        self.reportFailure = reportFailure
    }

    package var statistics: RecordWriterStatistics { state.withLockedValue { $0.statistics } }

    package func recordDrop() {
        state.withLockedValue { $0.statistics.droppedRecords &+= 1 }
    }

    package func append(_ data: Data) {
        let schedule = state.withLockedValue { value -> Bool in
            guard value.statistics.pendingRecords < limits.maxPendingRecords,
                  data.count <= limits.maxBatchBytes,
                  data.count <= limits.maxPendingBytes - value.statistics.pendingBytes else {
                value.statistics.droppedRecords &+= 1
                return false
            }
            value.pending.append(data)
            value.statistics.pendingRecords += 1
            value.statistics.pendingBytes += data.count
            guard !value.draining else { return false }
            value.draining = true
            drained.enter()
            return true
        }
        if schedule { queue.async { [self] in drain() } }
    }

    /// A timeout does not cancel an OS write already in progress. Memory stays bounded
    /// and the caller can finish shutdown without waiting for an unresponsive device.
    @discardableResult
    package func flush(timeout: TimeInterval = 2) -> Bool {
        precondition(timeout.isFinite && timeout >= 0)
        let completed = drained.wait(timeout: .now() + timeout) == .success
        if !completed { state.withLockedValue { $0.statistics.flushTimeouts &+= 1 } }
        return completed
    }

    private func drain() {
        while true {
            let batch = state.withLockedValue { value -> [Data] in
                guard !value.pending.isEmpty else {
                    value.draining = false
                    drained.leave()
                    return []
                }
                var count = 0
                var bytes = 0
                for record in value.pending.prefix(limits.maxBatchRecords) {
                    guard record.count <= limits.maxBatchBytes - bytes else { break }
                    count += 1
                    bytes += record.count
                }
                let result = Array(value.pending.prefix(count))
                value.pending.removeFirst(count)
                return result
            }
            guard !batch.isEmpty else { return }
            var failed = false
            do { try write(batch) }
            catch {
                failed = true
                reportFailure(error.localizedDescription)
            }
            state.withLockedValue { value in
                value.statistics.pendingRecords -= batch.count
                value.statistics.pendingBytes -= batch.reduce(0) { $0 + $1.count }
                if failed { value.statistics.failedRecords &+= UInt64(batch.count) }
                else { value.statistics.writtenRecords &+= UInt64(batch.count) }
            }
        }
    }
}

/// Keeps a single current generation. Rotation truncates at a record boundary;
/// it never loads the existing file into memory. The file never exceeds maxBytes.
package final class RotatingRecordFile: @unchecked Sendable {
    private let fileURL: URL
    private let maxBytes: Int
    private let counters = NIOLockedValueBox((bytes: UInt64(0), rotations: UInt64(0)))
    package var bytesWritten: UInt64 { counters.withLockedValue { $0.bytes } }
    package var rotationCount: UInt64 { counters.withLockedValue { $0.rotations } }
    package init(fileURL: URL, maxBytes: Int) {
        precondition(maxBytes > 0)
        self.fileURL = fileURL
        self.maxBytes = maxBytes
    }

    // Called only by the owning writer's serial drain.
    package func append(_ records: [Data]) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            guard FileManager.default.createFile(atPath: fileURL.path, contents: nil) else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let handle = try FileHandle(forUpdating: fileURL)
        do {
            var offset = try handle.seekToEnd()
            if offset > 0 {
                try handle.seek(toOffset: offset - 1)
                let tail = try handle.read(upToCount: 1)
                if offset > UInt64(maxBytes) || tail?.first != 0x0A {
                    // A prior crash may leave a partial record. Retire that
                    // generation rather than gluing new JSON onto its torn tail.
                    try handle.truncate(atOffset: 0)
                    counters.withLockedValue { $0.rotations &+= 1 }
                    offset = 0
                }
                try handle.seek(toOffset: offset)
            }
            var buffer = Data()
            for record in records {
                precondition(record.count <= maxBytes)
                if offset + UInt64(buffer.count) + UInt64(record.count) > UInt64(maxBytes) {
                    // This generation is being discarded; do not write bytes only to truncate them.
                    buffer.removeAll(keepingCapacity: true)
                    try handle.truncate(atOffset: 0)
                    counters.withLockedValue { $0.rotations &+= 1 }
                    try handle.seek(toOffset: 0)
                    offset = 0
                }
                buffer.append(record)
            }
            try handle.write(contentsOf: buffer)
            counters.withLockedValue { $0.bytes &+= UInt64(buffer.count) }
            try handle.close()
        } catch {
            // Preserve the original failure; closing a failed descriptor is best effort.
            do { try handle.close() } catch { /* Original I/O failure is reported by the writer. */ }
            throw error
        }
    }
}
