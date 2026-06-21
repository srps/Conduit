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
    private let captured = NIOLockedValueBox<[ConnectionAuditRecord]>([])

    package init() {}

    package func record(_ record: ConnectionAuditRecord) {
        captured.withLockedValue { $0.append(record) }
    }

    /// Snapshot of the records captured so far, in insertion order. The
    /// underlying buffer is unbounded — tests that emit a lot of records
    /// should read and discard periodically.
    package func records() -> [ConnectionAuditRecord] {
        captured.withLockedValue { $0 }
    }

    package func clear() {
        captured.withLockedValue { $0.removeAll(keepingCapacity: false) }
    }
}

// MARK: - FileConnectionAuditSink

/// Bounded NDJSON file `ConnectionAuditSink`. One JSON object per line.
/// Disk usage is capped at `maxBytes` via in-place trim: when the
/// post-append file exceeds the cap, the oldest bytes are dropped from
/// the front (NDJSON-aware — trim is aligned to a newline boundary so
/// no partial record is left behind). This mirrors the existing
/// `RuntimeEventFileWriter` discipline rather than introducing a
/// second on-disk-rotation pattern.
///
/// Concurrency: writes are serialized through a single `DispatchQueue`
/// (the same shape `RuntimeEventFileWriter` uses) so each NDJSON line
/// is intact even when multiple event loops emit records concurrently.
/// `record(_:)` returns immediately; `flush()` blocks until the queue
/// has drained for tests / shutdown.
///
/// Errors during write or directory creation are SURFACED via the
/// injected `LogSink` (matches `RuntimeEventFileWriter`'s error
/// handling). The audit sink is best-effort observability — a disk-full
/// or permission error must not crash the proxy or block client
/// requests, but the operator deserves to know about it.
package final class FileConnectionAuditSink: ConnectionAuditSink, @unchecked Sendable {
    package static let defaultMaxBytes = 10 * 1_048_576

    private let fileURL: URL
    private let maxBytes: Int
    private let logger: any LogSink
    private let queue = DispatchQueue(label: "pm-proxy.audit-file")

    package init(
        fileURL: URL,
        maxBytes: Int = FileConnectionAuditSink.defaultMaxBytes,
        logger: any LogSink
    ) {
        precondition(maxBytes > 0, "FileConnectionAuditSink.maxBytes must be positive (got \(maxBytes))")
        self.fileURL = fileURL
        self.maxBytes = maxBytes
        self.logger = logger
    }

    package func record(_ record: ConnectionAuditRecord) {
        queue.async { [self] in
            do {
                try append(record)
            } catch {
                logger.log(
                    .warning,
                    "Failed to write audit.ndjson: \(error.localizedDescription)",
                    category: .general
                )
            }
        }
    }

    /// Block until the queue has drained. Tests call this before
    /// reading the file back; the daemon calls it on shutdown to
    /// guarantee in-flight records are durable.
    package func flush() {
        queue.sync {}
    }

    // MARK: - Private

    private func append(_ record: ConnectionAuditRecord) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        var line = try ConnectionAuditRecord.canonicalEncoder.encode(record)
        line.append(0x0A)
        guard line.count <= maxBytes else {
            // Single record larger than the entire cap is suspicious
            // (`maxBytes` typically defaults to 10 MiB). Drop with a
            // warning so the operator notices, rather than truncating
            // the cap to one record.
            logger.log(.warning, "Skipping oversized audit record (>= maxBytes).", category: .general)
            return
        }

        var data = (try? Data(contentsOf: fileURL)) ?? Data()
        data.append(line)
        data = trim(data)
        try data.write(to: fileURL, options: .atomic)
    }

    /// Drop bytes from the front of `data` until the result fits in
    /// `maxBytes`. NDJSON-aware: after dropping the suffix-aligned
    /// prefix, advance to the next newline so the remaining file
    /// starts at a record boundary (no half-decoded leading line).
    private func trim(_ data: Data) -> Data {
        guard data.count > maxBytes else { return data }
        var suffix = data.suffix(maxBytes)
        if let newline = suffix.firstIndex(of: 0x0A) {
            suffix = suffix[suffix.index(after: newline)...]
        }
        return Data(suffix)
    }
}
