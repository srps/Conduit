// SPDX-License-Identifier: Apache-2.0
import Foundation

/// The one line format the privileged helper writes to its log.
///
/// Every helper message used to be a bare `fputs` — no timestamp, no level,
/// no pid — into a file that launchd appends to across every boot and never
/// rotates. A forensic read of that file could count 17 `daemon listening`
/// lines and 2 `Rejected connection` lines and date none of them, nor tell a
/// crash-loop from a reboot. This is the app side's `LogEntry.formatted()`
/// shape with the pid in place of the category, so the two logs read alike
/// and a line from either can be placed next to a line from the other.
///
/// Lives in `ConduitShared` rather than the helper so it can be tested:
/// the helper is an executable target with no test target of its own.
public enum HelperLogLine {
    public enum Level: String {
        case info = "INFO"
        case notice = "NOTICE"
        case warning = "WARNING"
        case error = "ERROR"
    }

    /// Trailing newline included — it is a log *line*.
    public static func format(
        _ level: Level, _ message: String, pid: pid_t, at timestamp: Date
    ) -> String {
        "[\(formatter.string(from: timestamp))] [\(level.rawValue)] [pid \(pid)] \(message)\n"
    }

    private nonisolated(unsafe) static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
}
