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
// `logImpl`). `AppLogStore.logImpl` Tasks back to MainActor for the
// `entries` ring-buffer + file-write side effects, with a synchronous
// `MainActor.assumeIsolated` fast path when the caller is already on
// main. The fast path preserves the "read `entries` right after
// `log`" semantics that AppState callers and LoggingTests rely on; the
// Task-hop branch keeps the nonisolated entry valid for NIO callers.
//
// Per-output filter logic (stderr vs buffer vs file) stays inside
// `appendOnMain` because each output has its own threshold: a line may
// pass the outer `minLevel` filter (so `logImpl` runs) yet only land in
// the buffer, not stderr — or vice versa.
//
// Filter levels (`minStderrLevel`, `minBufferedLevel`) are stored in
// `NIOLockedValueBox` so the LogSink-required `minLevel` accessor can
// read them from any thread without crossing actor isolation. Settings-
// driven writes from MainActor go through the same boxes — uniform,
// concurrency-safe, and the lock cost is negligible compared to the file-
// write or Task-hop the call usually triggers anyway.

import Combine
import Foundation
import NIOConcurrencyHelpers
import ProxyKernel

@MainActor
package final class AppLogStore: ObservableObject, LogSink {
    @Published package private(set) var entries: [LogEntry] = []

    /// Steady-state ring-buffer capacity. After a trim we keep exactly this
    /// many entries.
    private let maxEntries = 2000

    /// Overflow slack: we let `entries` grow up to `maxEntries + trimSlack`
    /// before trimming back to `maxEntries`. Trimming is `removeFirst(N)`,
    /// which is O(N) in the buffer size — doing it on every append once we
    /// hit the cap meant a 1999-element memmove per log line under burst
    /// load. Spreading the trim across `trimSlack` appends amortises the
    /// cost to O(1) per append at the cost of `trimSlack` extra entries
    /// briefly held in memory (≈ a few KB of `LogEntry`s).
    private let trimSlack = 256

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

    private var fileHandle: FileHandle?
    private let fileQueue = DispatchQueue(label: "com.proxymanager.filelog", qos: .utility)

    package var logFileURL: URL? {
        didSet {
            fileHandle?.closeFile()
            fileHandle = nil
            guard let url = logFileURL else { return }
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            fileHandle = FileHandle(forWritingAtPath: url.path)
            fileHandle?.seekToEndOfFile()
        }
    }

    package init() {}

    /// `LogSink` protocol primitive. Not called directly — the
    /// `LogSink.log` extension filters by `minLevel` and autoclosures the
    /// message, then routes here. Callers use `logger.log(.level, "msg",
    /// category: .cat)` which resolves to the extension and defaults
    /// `category` to `.general`; the extension then invokes this method
    /// with the fully-built message.
    ///
    /// Threading: when called from the main thread (typical for AppState
    /// callbacks + LoggingTests), appends synchronously via
    /// `MainActor.assumeIsolated`. When called off the main thread
    /// (kernel files via NIO event loops), Tasks back to MainActor for the
    /// append. The split preserves synchronous semantics for direct
    /// AppState / test calls — those callers can read `entries` immediately
    /// after — while keeping the nonisolated entry valid for kernel
    /// callers that can't statically prove they're on MainActor.
    ///
    /// The per-output filter (stderr vs buffer vs file) stays inside
    /// `appendOnMain`: a line that passes the outer `minLevel` gate may
    /// still only satisfy one of the two thresholds, and `appendOnMain`
    /// decides where each line lands based on per-output comparison.
    package nonisolated func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        if Thread.isMainThread {
            // Already on main; append inline. Preserves the
            // synchronous semantics that AppState's @MainActor callers and
            // the LoggingTests rely on (read `entries` right after calling
            // `log`). MainActor IS the main thread on Apple platforms;
            // `assumeIsolated` is the documented way to opt into the
            // synchronous fast path.
            MainActor.assumeIsolated {
                appendOnMain(level: level, message: message, category: category)
            }
        } else {
            // Off main (NIO event loops via `any LogSink` from kernel
            // files). Dispatch through MainActor for the ring-buffer +
            // file-write side effects.
            Task { @MainActor in
                self.appendOnMain(level: level, message: message, category: category)
            }
        }
    }

    /// MainActor-isolated body. Performs the ring-buffer append + the
    /// stderr/file writes. Private; the only entry point is the nonisolated
    /// `logImpl` above.
    private func appendOnMain(level: LogLevel, message: String, category: LogCategory) {
        let entry = LogEntry(level: level, category: category, message: message)
        if level >= minBufferedLevel {
            entries.append(entry)
            // Amortised trim: only act once we cross `maxEntries + trimSlack`,
            // then drop back to `maxEntries`. A burst of N appends after the
            // buffer is full triggers exactly ⌈N / trimSlack⌉ memmoves
            // instead of N — ~1/256× the work in the worst case.
            if entries.count > maxEntries + trimSlack {
                entries.removeFirst(entries.count - maxEntries)
            }
        }
        let line = entry.formatted() + "\n"
        let lineData = Data(line.utf8)
        if level >= minStderrLevel {
            FileHandle.standardError.write(lineData)
        }
        if let fh = fileHandle {
            let data = lineData
            fileQueue.async { fh.write(data) }
        }
    }

    package func exportDiagnosticLog() -> String {
        entries.map { $0.formatted() }.joined(separator: "\n")
    }

    package func clearEntries() {
        entries.removeAll()
    }
}
