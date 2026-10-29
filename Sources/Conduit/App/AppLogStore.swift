// SPDX-License-Identifier: Apache-2.0
// SwiftUI ring-buffered log store. Moved from `Sources/ProxyKernel/Support/`
// because it imports `Combine` (`ObservableObject`/`@Published`) and
// runs on `@MainActor` — both forbidden in `ProxyKernel` per the import
// fence in `AGENTS.md`. The kernel now talks to logging through the
// `LogSink` protocol (`Sources/ProxyKernel/Abstractions/LogSink.swift`);
// `AppLogStore` is one of three conformers (alongside `ConsoleLogSink` for
// headless daemons and `DiscardingLogSink` for tests).
//
// LogSink conformance design: the protocol requirement `logImpl` is the
// raw sink primitive — it assumes the caller has already filtered by
// `minLevel` (the `LogSink.log` extension does this before calling
// `logImpl`). `AppLogStore.logImpl` builds one `LogEntry` and one
// formatted line, and writes the physical outputs (the file writer's
// bounded admission, the shared bounded stderr writer, the unified log)
// in the caller's own turn, on whatever thread it is. Only the UI history
// crosses to MainActor: off main through one bounded locked hand-off and
// at most one scheduled drain, and on main inline, after the hand-off's
// earlier entries, which preserves the "read `entries` right after `log`"
// semantics that AppState callers and LoggingTests rely on. A history
// entry evicted from that bounded hand-off is not a lost record: the
// physical outputs already have it.
//
// Per-output filter logic (stderr vs buffer vs file) is per output because
// each has its own threshold: a line may pass the outer `minLevel` filter
// (so `logImpl` runs) yet only land in the buffer, not stderr — or vice
// versa. The file and the unified log take every line that reaches the store.
//
// Filter levels (`minStderrLevel`, `minBufferedLevel`) are stored in
// `NIOLockedValueBox` so the LogSink-required `minLevel` accessor can
// read them from any thread without crossing actor isolation. Settings-
// driven writes from MainActor go through the same boxes — uniform,
// concurrency-safe, and the lock cost is negligible compared to the
// write the call usually triggers anyway.

import Combine
import Foundation
import NIOConcurrencyHelpers
import os
import ProxyKernel
import ConduitShared

@MainActor
package final class AppLogStore: ObservableObject, LogSink {
    @Published package private(set) var entries: [LogEntry] = []

    /// Steady-state ring-buffer capacity. After a trim we keep exactly this
    /// many entries. The off-main hand-off is bounded the same way.
    nonisolated private static let maxEntries = 2000

    /// Overflow slack: we let `entries` grow up to `maxEntries + trimSlack`
    /// before trimming back to `maxEntries`. Trimming is `removeFirst(N)`,
    /// which is O(N) in the buffer size — doing it on every append once we
    /// hit the cap meant a 1999-element memmove per log line under burst
    /// load. Spreading the trim across `trimSlack` appends amortises the
    /// cost to O(1) per append at the cost of `trimSlack` extra entries
    /// briefly held in memory (≈ a few KB of `LogEntry`s). The hand-off
    /// trims the same way.
    nonisolated private static let trimSlack = 256

    private let stderrLevelBox = NIOLockedValueBox<LogLevel>(.notice)
    private let bufferedLevelBox = NIOLockedValueBox<LogLevel>(.notice)

    /// Stderr threshold. Read from any thread (LogSink path); written from
    /// MainActor (Settings sliders). The box collapses both into a single
    /// concurrency-safe storage.
    package nonisolated var minStderrLevel: LogLevel {
        get { stderrLevelBox.withLockedValue { $0 } }
        set { stderrLevelBox.withLockedValue { $0 = newValue } }
    }

    /// Ring-buffer threshold. Same nonisolated pattern as `minStderrLevel`
    /// for the same reason.
    package nonisolated var minBufferedLevel: LogLevel {
        get { bufferedLevelBox.withLockedValue { $0 } }
        set { bufferedLevelBox.withLockedValue { $0 = newValue } }
    }

    /// `LogSink.minLevel`: the looser of the two output thresholds. If
    /// either output is enabled at level X, the call is worth building the
    /// message for. Slightly racy across the lock acquires but the read is a
    /// hint, not a contract — at most a stale level is observed for one
    /// call.
    package nonisolated var minLevel: LogLevel {
        let stderr = stderrLevelBox.withLockedValue { $0 }
        let buf = bufferedLevelBox.withLockedValue { $0 }
        return min(stderr, buf)
    }

    /// The current file writer and the counters of the writers it replaced. A line is only admitted under this lock,
    /// and the swap happens under it, so no line reaches a writer after its counters were folded. Never held across a
    /// close, a wait or a publication.
    private struct Writers {
        var file: (any RotatingByteWriter)?
        /// The written, dropped and failed counts of every writer closed by a toggle.
        var folded = Folded()
        /// The waits this store saw time out. Owned here, not summed from the writers, so a wait that ends after its
        /// writer was replaced is counted once.
        var waitTimeouts: UInt64 = 0
    }
    /// A closed writer's monotonic counters. Its queue is empty once its close returned, so nothing pending is folded.
    private struct Folded {
        var written: UInt64 = 0
        var dropped: UInt64 = 0
        var failed: UInt64 = 0
    }
    private let writers = NIOLockedValueBox(Writers())
    /// The shared bounded stderr writer.
    private let console = ConsoleLogSink(minLevel: .debug)

    /// Entries emitted off main and not yet in `entries`, bounded like `entries`, and whether a drain is scheduled.
    private struct History {
        var pending: [LogEntry] = []
        var scheduled = false
        /// Drains scheduled over the store's life. Test observation.
        var drainsScheduled = 0
        /// Entries evicted from the hand-off before they reached `entries`. UI history only, never a lost record.
        var evicted = 0
    }
    private let history = NIOLockedValueBox(History())

    private let fileLogMaxBytes: Int
    private let fileLogArchives: Int
    /// The guard every file open and archive rotation is judged by. Required: no unchecked default is built into production.
    private let destinationGuard: any RecordFileDestinationGuarding
    /// The composition's one canonical event log, shared with the orchestrator, so a refusal or IO transition is
    /// reported in the same stream as every other event. The gate and the writer hold it weakly.
    private let diagnosticEventLog: RuntimeEventLog
    /// One refusal gate for the store's lifetime, so its latch survives Settings toggles and reopens.
    private let destinationGate: RecordFileDestinationGate
    /// The logger the gate and writer report through. It holds the store weakly, so the store-owned gate
    /// and writer do not keep the store alive.
    private let fileLogSink: WeakStoreLogSink

    /// Where the app writes its log by default. On by default — see
    /// `AppPreferences.fileLoggingEnabled` — because a log that has to be
    /// switched on before the failure is only useful for failures that can
    /// be predicted. The one real investigation this product has had found
    /// a `proxy.log` seven weeks stale for exactly that reason.
    /// Setting this opens the file for **append**; it never truncates. The
    /// previous implementation did, on every toggle flip. The file opens on
    /// its first write, never here.
    ///
    /// A change closes the current writer first, with no lock held: the close writes what that writer had admitted and
    /// blocks this turn until it has, as before. A line logged meanwhile reaches the closed writer and is counted
    /// dropped. Then, under the lock, the closed writer's counters are folded in and the new writer takes its place.
    package var logFileURL: URL? {
        didSet {
            let closing = writers.withLockedValue { $0.file }
            closing?.close()
            let next = logFileURL.map { url in
                rotatingLogFile(
                    url: url, maxBytes: fileLogMaxBytes, archives: fileLogArchives,
                    destinationGuard: destinationGuard, gate: destinationGate,
                    eventLog: diagnosticEventLog, logger: fileLogSink
                )
            }
            writers.withLockedValue { value in
                if let closing {
                    let statistics = closing.statistics
                    value.folded.written &+= statistics.writtenRecords
                    value.folded.dropped &+= statistics.droppedRecords
                    value.folded.failed &+= statistics.failedRecords
                }
                value.file = next
            }
        }
    }

    /// Every line that reaches the store is also mirrored to the unified log
    /// under the subsystem the privileged helper logs to, so a single
    /// `log show --predicate 'subsystem == "…"'` reads both processes in
    /// order — the interleaving that two files could only approximate.
    /// Public on purpose: the lines are already sanitised by `LogSink` and
    /// already land in a user-readable file. `info`/`debug` are not
    /// persisted by the system, which matches what is worth reading later.
    nonisolated private static let unifiedLog = Logger(subsystem: HelperConstants.logSubsystem, category: "app")

    /// Waits up to `timeout` for the file writer's admitted lines. False, and a counted timeout, when they had not
    /// left its queue. For tests and Settings; the runtime owner drains asynchronously instead.
    @discardableResult
    package nonisolated func flushFileLog(timeout: TimeInterval = 2) -> Bool {
        guard let file = writers.withLockedValue({ $0.file }) else { return true }
        let completed = file.flush(timeout: timeout)
        if !completed { writers.withLockedValue { $0.waitTimeouts &+= 1 } }
        return completed
    }

    package init(
        fileLogMaxBytes: Int = 5 << 20, fileLogArchives: Int = 3,
        destinationGuard: any RecordFileDestinationGuarding, eventLog: RuntimeEventLog
    ) {
        self.fileLogMaxBytes = fileLogMaxBytes
        self.fileLogArchives = fileLogArchives
        self.destinationGuard = destinationGuard
        self.diagnosticEventLog = eventLog
        let sink = WeakStoreLogSink()
        self.fileLogSink = sink
        self.destinationGate = RecordFileDestinationGate(sink: .appLog, eventLog: eventLog, logger: sink)
        sink.bind(self)
    }

    // MARK: - LogSink

    /// `LogSink` protocol primitive. Not called directly — the
    /// `LogSink.log` extension filters by `minLevel` and autoclosures the
    /// message, then routes here. Callers use `logger.log(.level, "msg",
    /// category: .cat)` which resolves to the extension and defaults
    /// `category` to `.general`; the extension then invokes this method
    /// with the fully-built message.
    ///
    /// Threading: the physical outputs are written here, on any thread, and only admit to bounded writers. The UI
    /// history entry is appended inline when called on the main thread (typical for AppState callbacks and
    /// LoggingTests), after any entries still in the hand-off, so those callers can read `entries` immediately after.
    /// Off main it goes to the bounded hand-off, which one scheduled drain appends.
    package nonisolated func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        let entry = LogEntry(level: level, category: category, message: message)
        let line = Data((entry.formatted() + "\n").utf8)
        writers.withLockedValue { $0.file?.write(line) }
        if level >= minStderrLevel { console.write(line: line) }
        Self.unifiedLog.log(level: level.osLogType, "[\(category.rawValue, privacy: .public)] \(message, privacy: .public)")
        let buffered = level >= minBufferedLevel
        if Thread.isMainThread {
            // MainActor IS the main thread on Apple platforms; `assumeIsolated` is the documented way to opt into the
            // synchronous path.
            MainActor.assumeIsolated { appendOnMain(buffered ? entry : nil) }
        } else if buffered {
            handOff(entry)
        }
    }

    /// The physical outputs' counters: the folded writers, the current file writer and the shared stderr writer.
    /// `flushTimeouts` is this store's own count of waits that timed out, not the writers' sum.
    package nonisolated var statistics: RecordWriterStatistics {
        let (folded, file, waitTimeouts) = writers.withLockedValue { ($0.folded, $0.file?.statistics, $0.waitTimeouts) }
        var total = console.statistics
        if let file {
            total.pendingRecords += file.pendingRecords
            total.pendingBytes += file.pendingBytes
            total.writtenRecords &+= file.writtenRecords
            total.droppedRecords &+= file.droppedRecords
            total.failedRecords &+= file.failedRecords
        }
        total.writtenRecords &+= folded.written
        total.droppedRecords &+= folded.dropped
        total.failedRecords &+= folded.failed
        // The writers' own timeout counts are left out: a wait is counted once, by this store.
        total.flushTimeouts = waitTimeouts
        return total
    }

    /// Waits for the file writer's and stderr's admitted lines, both under one absolute deadline. Honest and bounded,
    /// for callers outside the runtime owner. False when either had not drained.
    @discardableResult
    package nonisolated func flush(timeout: TimeInterval) -> Bool {
        let deadline = DispatchTime.now() + timeout
        let remaining = { max(0, Double(Int64(deadline.uptimeNanoseconds) - Int64(DispatchTime.now().uptimeNanoseconds)) / 1e9) }
        var timeouts: UInt64 = 0
        let file = writers.withLockedValue { $0.file }
        if let file, !file.flush(timeout: remaining()) { timeouts += 1 }
        if !console.flush(timeout: remaining()) { timeouts += 1 }
        if timeouts > 0 { writers.withLockedValue { $0.waitTimeouts &+= timeouts } }
        return timeouts == 0
    }

    /// Awaits the file writer's and stderr's admitted lines without blocking, both under the same absolute `deadline`.
    /// Each eligible output is tried whatever the other answered, and the first outcome that is not `drained` is the
    /// result. Each wait that times out is counted once, here.
    package nonisolated func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
        let file = writers.withLockedValue { $0.file }
        var result = RecordDrainOutcome.drained
        if let file { result = await record(file.drain(until: deadline), after: result) }
        return await record(console.drain(until: deadline), after: result)
    }

    private nonisolated func record(_ outcome: RecordDrainOutcome, after result: RecordDrainOutcome) -> RecordDrainOutcome {
        if outcome == .timedOut { writers.withLockedValue { $0.waitTimeouts &+= 1 } }
        return result == .drained ? outcome : result
    }

    // MARK: - UI history

    /// Drains scheduled over the store's life, and entries evicted from the hand-off. Test observation.
    nonisolated var historyDrainsScheduled: Int { history.withLockedValue { $0.drainsScheduled } }
    nonisolated var historyEvicted: Int { history.withLockedValue { $0.evicted } }

    /// Adds an off-main entry to the bounded hand-off, trimmed like `entries`, and schedules one drain if none is.
    private nonisolated func handOff(_ entry: LogEntry) {
        let schedule = history.withLockedValue { value -> Bool in
            value.pending.append(entry)
            if value.pending.count > Self.maxEntries + Self.trimSlack {
                let excess = value.pending.count - Self.maxEntries
                value.pending.removeFirst(excess)
                value.evicted += excess
            }
            guard !value.scheduled else { return false }
            value.scheduled = true
            value.drainsScheduled += 1
            return true
        }
        if schedule {
            Task { @MainActor [weak self] in self?.drainHandOff() }
        }
    }

    /// The scheduled drain: everything handed off so far, in one mutation of `entries`.
    private func drainHandOff() {
        let batch = history.withLockedValue { value -> [LogEntry] in
            value.scheduled = false
            return Self.take(&value.pending)
        }
        guard !batch.isEmpty else { return }
        Self.appendHistory(batch, to: &entries)
    }

    /// The main thread's own entry, after whatever the hand-off still holds, in one mutation of `entries`. A scheduled
    /// drain stays scheduled and finds less to do.
    private func appendOnMain(_ entry: LogEntry?) {
        var batch = history.withLockedValue { Self.take(&$0.pending) }
        if batch.isEmpty {
            guard let entry else { return }
            Self.appendHistory(CollectionOfOne(entry), to: &entries)
            return
        }
        if let entry { batch.append(entry) }
        Self.appendHistory(batch, to: &entries)
    }

    private nonisolated static func take(_ pending: inout [LogEntry]) -> [LogEntry] {
        guard !pending.isEmpty else { return [] }
        var taken: [LogEntry] = []
        swap(&taken, &pending)
        return taken
    }

    /// Appends, then applies the amortised trim: only act once we cross `maxEntries + trimSlack`, then drop back to
    /// `maxEntries`. A burst of N appends after the buffer is full triggers exactly ⌈N / trimSlack⌉ memmoves instead of
    /// N — ~1/256× the work in the worst case. One `inout` access, so one published change per batch.
    private static func appendHistory<S: Sequence>(_ batch: S, to entries: inout [LogEntry]) where S.Element == LogEntry {
        entries.append(contentsOf: batch)
        if entries.count > maxEntries + trimSlack {
            entries.removeFirst(entries.count - maxEntries)
        }
    }

    package func exportDiagnosticLog() -> String {
        entries.map { $0.formatted() }.joined(separator: "\n")
    }

    package func clearEntries() {
        history.withLockedValue { $0.pending.removeAll() }
        entries.removeAll()
    }
}

/// The logger the store's gate and file writer report through. It forwards to the store while the store lives, and
/// does nothing after. The store owns the gate, and the gate would otherwise hold the store alive.
private final class WeakStoreLogSink: LogSink, @unchecked Sendable {
    private let lock = NSLock()
    private weak var store: AppLogStore?

    func bind(_ store: AppLogStore) {
        lock.withLock { self.store = store }
    }

    private var current: AppLogStore? {
        lock.withLock { store }
    }

    var minLevel: LogLevel { current?.minLevel ?? .error }

    func drain(until deadline: ContinuousClock.Instant) async -> RecordDrainOutcome {
        guard let store = current else { return .unavailable }
        return await store.drain(until: deadline)
    }

    func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        current?.logImpl(level, message, category: category)
    }
}

extension LogLevel {
    /// Same mapping as the helper's `HelperLog`, so the two processes read
    /// alike in Console, on os_log's own semantics: warnings are handled
    /// anomalies (`.default`), errors are errors (`.error`), and `.fault`
    /// stays reserved for invariant violations — which keeps Console's
    /// Error and Fault columns meaningful instead of one level louder
    /// than the text. `info`/`debug` keep their own types and are not
    /// persisted.
    var osLogType: OSLogType {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .notice: return .default
        case .warning: return .default
        case .error: return .error
        }
    }
}
