// SPDX-License-Identifier: Apache-2.0
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
import Foundation

/// The byte writer the app's file log and pm-sim hold. The concrete `RotatingLogFile` stays internal, so
/// callers depend on this protocol and on `rotatingLogFile(...)`, never on the backend.
package protocol RotatingByteWriter: Sendable {
    /// Queues one write. A line is never split: an oversized line is written whole.
    func write(_ data: Data)
    /// Drains queued writes. For tests and shutdown.
    func flush()
    /// Closes the descriptor once. A failed close is reported and never retried.
    func close()
}

/// The app's file log writer. Its physical policy is its own, and it is not the record-file backend:
/// it opens `O_APPEND | O_CREAT | O_CLOEXEC | O_NONBLOCK` (never truncating), counts the bytes it writes,
/// and at `maxBytes` shifts `log → log.1 → … → log.N` and starts a fresh file. An oversized line is written whole.
///
/// The guard decides every destination. `admit(destination:)` runs before the directory is created, before
/// the file is opened, and before each archive slot is renamed or unlinked, and `admit(openedDescriptor:)` runs
/// on the opened descriptor before its first write. Every slot is judged before any rename or unlink, so a
/// refusal changes nothing on disk. The archive is removed with `unlink` only, never recursively.
///
/// Unsupported files are refused by kind, not by the guard: an existing path that is not a regular file (directly
/// or through a symbolic link) is not opened, so a FIFO or device cannot block the open. Admitted symbolic links
/// to ordinary files keep working.
///
/// All file work happens on one serial queue; `write` returns immediately, and `flush()` drains the queue.
///
/// Failures publish through the record gate's event log and logger, event first, then one derived line. A
/// failure streak costs one event and one line, and the first successful write after it publishes recovery.
/// `failing` is set before publication, so the derived line's own write is not reported again. A failed close
/// is never retried and never followed by another open: the writer is retired for its lifetime. Detail carries
/// a stage and a code, never a path or a value.
///
/// The event log is held weakly, as the gate holds it. The gate's owner outlives the writer's drains.
package func rotatingLogFile(
    url: URL, maxBytes: Int = 5 << 20, archives: Int = 3,
    destinationGuard: any RecordFileDestinationGuarding,
    gate: RecordFileDestinationGate, eventLog: RuntimeEventLog, logger: any LogSink
) -> any RotatingByteWriter {
    RotatingLogFile(
        url: url, maxBytes: maxBytes, archives: archives, destinationGuard: destinationGuard,
        gate: gate, eventLog: eventLog, logger: logger, effects: .system
    )
}

/// Test seam for the descriptor calls that the single-close and no-reopen claims depend on. Production uses
/// `.system`. A test replaces `closeDescriptor` to count closes, and `openFile` to count opens.
struct RotatingLogFileEffects: Sendable {
    var openFile: @Sendable (String, Int32, mode_t) -> Int32
    var closeDescriptor: @Sendable (Int32) -> Int32

    static let system = RotatingLogFileEffects(
        openFile: { path, flags, mode in Darwin.open(path, flags, mode) },
        closeDescriptor: { Darwin.close($0) }
    )
}

/// One failed file effect. Only its stage and a platform code leave this type, never a path.
struct RotatingLogFileFailure: Error, Equatable, Sendable {
    enum Stage: String, Sendable {
        case mkdir, inspect, open, fstat, write, close, other
        /// An existing path that is not a regular file, judged before it is opened or renamed.
        case unsupportedKind = "unsupported_kind"
        case rotateRemove = "rotate_remove"
        case rotateRename = "rotate_rename"
    }

    let stage: Stage
    /// An errno, or 0 when the stage has none. For `mkdir` it is the Foundation error's code.
    let code: Int32
}

final class RotatingLogFile: @unchecked Sendable {
    private let url: URL
    private let maxBytes: Int
    private let archives: Int
    private let destinationGuard: any RecordFileDestinationGuarding
    private let gate: RecordFileDestinationGate
    /// Held weakly, as the gate holds it, so the writer never extends the event log's owner.
    private weak var eventLog: RuntimeEventLog?
    private let logger: any LogSink
    private let effects: RotatingLogFileEffects
    private let queue = DispatchQueue(label: "io.github.srps.Conduit.logfile", qos: .utility)
    private var fd: Int32 = -1
    private var size = 0
    /// Set on the first failed effect, cleared on the next success. Gates the report, so a failure streak
    /// costs one event and one line.
    private var failing = false
    /// Set when a close fails. The writer then opens no descriptor and closes none again.
    private var retired = false

    init(
        url: URL, maxBytes: Int, archives: Int,
        destinationGuard: any RecordFileDestinationGuarding,
        gate: RecordFileDestinationGate, eventLog: RuntimeEventLog, logger: any LogSink,
        effects: RotatingLogFileEffects
    ) {
        self.url = url
        self.maxBytes = maxBytes
        self.archives = archives
        self.destinationGuard = destinationGuard
        self.gate = gate
        self.eventLog = eventLog
        self.logger = logger
        self.effects = effects
    }

    deinit {
        // A writer released with its descriptor open closes it once. A failure is still reported while the event
        // log exists. Once the owner has released the log, the derived line is the only trace.
        guard fd >= 0, effects.closeDescriptor(fd) != 0 else { return }
        fail(RotatingLogFileFailure(stage: .close, code: errno))
    }

    // MARK: - Public entry points

    func write(_ data: Data) {
        queue.async { self.append(data) }
    }

    func flush() {
        queue.sync {}
    }

    func close() {
        queue.sync {
            if let failure = releaseDescriptor() { fail(failure) }
        }
    }

    // MARK: - Queue-confined

    private func append(_ data: Data) {
        guard !retired else { return }
        do {
            try gate.perform { try writeOne(data) }
            recover()
        } catch is RecordFileDestinationRefusal {
            // The gate has latched and published the refusal. Nothing more is touched.
        } catch let failure as RotatingLogFileFailure {
            fail(failure)
        } catch {
            fail(RotatingLogFileFailure(stage: .other, code: 0))
        }
    }

    /// Runs inside `gate.perform`. Opens if needed, rotates if the write would pass `maxBytes`, then writes.
    private func writeOne(_ data: Data) throws {
        try ensureOpen()
        if size + data.count > maxBytes, size > 0 {
            try rotate()
            try ensureOpen()
        }
        try writeAll(data)
    }

    /// Opens the active file only after the guard admits it and its existing kind is regular. Failure before the
    /// open creates nothing. A refused or non-regular opened descriptor is closed, and the open is not kept.
    private func ensureOpen() throws {
        guard fd < 0 else { return }
        try destinationGuard.admit(destination: url)
        try createDirectory()
        try requireRegularOrAbsent(url.path)
        let descriptor = effects.openFile(url.path, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC | O_NONBLOCK, 0o644)
        guard descriptor >= 0 else { throw RotatingLogFileFailure(stage: .open, code: errno) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw abandon(descriptor, RotatingLogFileFailure(stage: .fstat, code: errno))
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw abandon(descriptor, RotatingLogFileFailure(stage: .unsupportedKind, code: 0))
        }
        do {
            try destinationGuard.admit(openedDescriptor: descriptor, destination: url)
        } catch {
            throw abandon(descriptor, error)
        }
        fd = descriptor
        size = Int(info.st_size)
    }

    /// Closes a descriptor that failed validation, and returns the error that caused it. The validation error is the
    /// one reported. A failed close here retires the writer, and its report is not separate from that streak.
    private func abandon(_ descriptor: Int32, _ error: Error) -> Error {
        if effects.closeDescriptor(descriptor) != 0 { retired = true }
        return error
    }

    /// Creates the parent directory. A failure is reported as `mkdir`, not swallowed.
    private func createDirectory() throws {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
        } catch {
            throw RotatingLogFileFailure(stage: .mkdir, code: Int32(truncatingIfNeeded: (error as NSError).code))
        }
    }

    /// A missing path, or an existing regular file, passes. A symbolic link passes when its target is regular, since
    /// `stat` follows it. Any other kind (directory, FIFO, socket, device) is refused before it is opened or renamed.
    private func requireRegularOrAbsent(_ path: String) throws {
        var info = stat()
        guard stat(path, &info) == 0 else {
            let code = errno
            guard code == ENOENT else { throw RotatingLogFileFailure(stage: .inspect, code: code) }
            return
        }
        guard info.st_mode & S_IFMT == S_IFREG else {
            throw RotatingLogFileFailure(stage: .unsupportedKind, code: 0)
        }
    }

    private func writeAll(_ data: Data) throws {
        var written = 0
        var failure: RotatingLogFileFailure?
        data.withUnsafeBytes { buf in
            while written < buf.count {
                let n = Darwin.write(fd, buf.baseAddress! + written, buf.count - written)
                if n < 0, errno == EINTR { continue }
                if n <= 0 {
                    failure = RotatingLogFileFailure(stage: .write, code: errno)
                    return
                }
                written += n
            }
        }
        size += written
        if let failure { throw failure }
    }

    /// Judges the active file and every archive slot, then closes and shifts. Nothing is renamed or removed until every
    /// slot has passed the guard and the kind check. Removal is `unlink`, so a directory is never removed.
    private func rotate() throws {
        let last = max(archives, 1)
        for index in 0...last {
            let path = slot(index)
            try destinationGuard.admit(destination: URL(fileURLWithPath: path))
            try requireRegularOrAbsent(path)
        }
        if let failure = releaseDescriptor() { throw failure }
        if unlink(slot(last)) != 0, errno != ENOENT {
            throw RotatingLogFileFailure(stage: .rotateRemove, code: errno)
        }
        // Oldest first, so each rename lands on a name that is free.
        for index in stride(from: last - 1, through: 0, by: -1) {
            guard rename(slot(index), slot(index + 1)) == 0 || errno == ENOENT else {
                throw RotatingLogFileFailure(stage: .rotateRename, code: errno)
            }
        }
    }

    /// Closes the active descriptor once and forgets it. A failed close is ambiguous, so the descriptor is never
    /// closed again, and the writer is retired for its lifetime.
    private func releaseDescriptor() -> RotatingLogFileFailure? {
        guard fd >= 0 else { return nil }
        let descriptor = fd
        fd = -1
        guard effects.closeDescriptor(descriptor) != 0 else { return nil }
        retired = true
        return RotatingLogFileFailure(stage: .close, code: errno)
    }

    /// Event first, then the derived line. `failing` is set before publication, so the line's own write, which comes
    /// back through this writer, is part of the same streak and is not reported again.
    private func fail(_ failure: RotatingLogFileFailure) {
        guard !failing else { return }
        failing = true
        let detail = "stage=\(failure.stage.rawValue) code=\(failure.code)"
        publish(
            event: "observability.log_file_failed", detail: detail, level: .warning,
            line: "File logging is not recording — \(detail). Entries are kept in the Logs window only until this clears."
        )
    }

    private func recover() {
        guard failing else { return }
        failing = false
        publish(event: "observability.log_file_recovered", detail: nil, level: .notice, line: "File logging resumed.")
    }

    private func publish(event name: String, detail: String?, level: LogLevel, line: String) {
        let event = RuntimeEvent(kind: .health, event: name, detail: detail)
        eventLog?.append(event)
        logger.log(level, line, category: .general)
    }

    /// The active path, or an archive slot. Archive slots are `base.1` through `base.N`.
    private func slot(_ index: Int) -> String {
        index == 0 ? url.path : "\(url.path).\(index)"
    }
}

extension RotatingLogFile: RotatingByteWriter {}
