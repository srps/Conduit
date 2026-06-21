// SPDX-License-Identifier: Apache-2.0
// Stock `LogSink` conformers used by headless daemons + tests + sim
// scenarios. The SwiftUI app's ring-buffered `AppLogStore` lives in the app
// target (`Sources/Conduit/App/AppLogStore.swift`) and conforms via its
// own extension — the kernel doesn't ship a UI-flavoured sink.
//
// Which executable picks which sink:
//   - pm-proxy / pm-tunnel / pm-dns: `ConsoleLogSink` (synchronous stderr)
//   - pm-sim default scenarios: `ConsoleLogSink` (sim wants its own output)
//   - pm-sim assertion-on-content scenarios: `RecordingLogSink`
//   - Tests that exercise log content: `RecordingLogSink`
//   - Tests that just need a logger plumbed: `DiscardingLogSink`
//
// All three conformers implement the `LogSink.logImpl` primitive (not
// `log`) — filtering by `minLevel` and the `@autoclosure` short-circuit
// happen in the `log` extension method before `logImpl` is ever called.
// See `LogSink.swift` for the protocol shape.

import Foundation
import NIOConcurrencyHelpers

/// Writes formatted log lines synchronously to stderr. The default for
/// headless daemons (`pm-proxy`, `pm-tunnel`, `pm-dns`). Synchronous write
/// is intentional: NIO event loops calling `log(...)` pay one
/// `FileHandle.write` syscall and continue — no Task hop, no MainActor
/// scheduling pressure.
package struct ConsoleLogSink: LogSink {
    package let minLevel: LogLevel

    package init(minLevel: LogLevel = .notice) {
        self.minLevel = minLevel
    }

    package func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        let entry = LogEntry(level: level, category: category, message: message)
        FileHandle.standardError.write(Data((entry.formatted() + "\n").utf8))
    }
}

/// No-op `LogSink` for tests / sim scenarios that don't assert on log
/// output. `minLevel` is set to `.error` (the highest `LogLevel`) so the
/// `LogSink.log` extension short-circuits everything below `.error`,
/// eliminating message-interpolation cost on the common `.debug` /
/// `.info` / `.notice` / `.warning` paths. The rare `.error` path still
/// builds the message but `logImpl` discards it.
///
/// Useful when wiring a kernel type that requires `any LogSink` but the
/// test isn't checking what it logs.
package struct DiscardingLogSink: LogSink {
    package init() {}

    package var minLevel: LogLevel { .error }

    package func logImpl(_: LogLevel, _: String, category _: LogCategory) {
        // Intentionally empty.
    }
}

/// In-memory capturing `LogSink` for tests + pm-sim scenarios that assert
/// on log content. Thread-safe via `NIOLockedValueBox`; the captured
/// `[LogEntry]` slice is read via `entries()` (snapshot copy) or filtered
/// helpers like `entries(at:)` and `containsMessage(_:at:)`.
///
/// Designed to drop in wherever a kernel type takes `any LogSink`. Mirrors
/// the existing `RecordingPrivilegeClient` pattern: production code talks
/// to a protocol, tests substitute a recorder.
package final class RecordingLogSink: LogSink, @unchecked Sendable {
    private let entriesBox = NIOLockedValueBox<[LogEntry]>([])
    private let minLevelBox: NIOLockedValueBox<LogLevel>

    /// Filter threshold. Defaults to `.debug` so the recorder captures
    /// everything; tests that want to assert "this didn't log a warning"
    /// can construct with `RecordingLogSink(minLevel: .info)` to match
    /// production sinks more closely. The filtering happens in the
    /// `LogSink.log` extension before `logImpl` is called, so below-
    /// threshold levels never reach the captured buffer.
    package init(minLevel: LogLevel = .debug) {
        self.minLevelBox = NIOLockedValueBox<LogLevel>(minLevel)
    }

    package var minLevel: LogLevel {
        minLevelBox.withLockedValue { $0 }
    }

    package func logImpl(_ level: LogLevel, _ message: String, category: LogCategory) {
        let entry = LogEntry(level: level, category: category, message: message)
        entriesBox.withLockedValue { $0.append(entry) }
    }

    /// Snapshot copy of the captured entries. Safe to iterate from any
    /// thread; the returned array is a value-type copy.
    package func entries() -> [LogEntry] {
        entriesBox.withLockedValue { $0 }
    }

    /// Convenience: entries filtered to a specific level.
    package func entries(at level: LogLevel) -> [LogEntry] {
        entriesBox.withLockedValue { buf in buf.filter { $0.level == level } }
    }

    /// Convenience: did any captured entry at `level` contain `substring`?
    package func containsMessage(_ substring: String, at level: LogLevel? = nil) -> Bool {
        entriesBox.withLockedValue { buf in
            buf.contains { entry in
                (level == nil || entry.level == level) && entry.message.contains(substring)
            }
        }
    }

    /// Wipe the captured buffer. Useful for assertion windows.
    package func clear() {
        entriesBox.withLockedValue { $0.removeAll() }
    }
}
