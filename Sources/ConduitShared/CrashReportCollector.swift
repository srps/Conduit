// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Collects recent Conduit crash reports (`.ips`) for the `pmctl diag`
/// bundle.
///
/// Crash evidence otherwise sits unnoticed in `~/Library/Logs/
/// DiagnosticReports/` — the 2026-06-10 GSS SIGSEGV was found there days
/// after the fact. Folding the recent reports into the diag bundle makes
/// the 1.0 reliability bar ("zero restarts in a quarter") measurable from
/// a bug report alone.
///
/// Reports are sanitized before inclusion: the user's home path and login
/// name are redacted, as are the per-device identifiers Apple embeds
/// (`deviceIdentifierForVendor`, `crashReporterKey`, `sleepWakeUUID`,
/// `bootSessionUUID`). Symbol names, addresses, and image offsets — the
/// parts that make a report diagnosable — are untouched.
public enum CrashReportCollector {
    public struct Report: Sendable, Equatable {
        public let url: URL
        public let modifiedAt: Date

        public init(url: URL, modifiedAt: Date) {
            self.url = url
            self.modifiedAt = modifiedAt
        }
    }

    public static let defaultLimit = 5
    public static let defaultMaxAge: TimeInterval = 30 * 24 * 3600
    /// Process-name prefixes considered ours. Matches the app, the daemon,
    /// and the privileged helper.
    public static let defaultPrefixes = ["Conduit"]

    public static func defaultDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DiagnosticReports", isDirectory: true)
    }

    /// Newest-first list of matching `.ips` reports, bounded by `limit` and
    /// `maxAge`. Missing directory yields an empty list, never an error —
    /// a diag bundle must still build on a machine that has never crashed.
    public static func recentReports(
        in directory: URL,
        prefixes: [String] = defaultPrefixes,
        limit: Int = defaultLimit,
        maxAge: TimeInterval = defaultMaxAge,
        now: Date = Date()
    ) -> [Report] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        let cutoff = now.addingTimeInterval(-maxAge)
        let matching = entries.compactMap { url -> Report? in
            guard url.pathExtension == "ips" else { return nil }
            let name = url.lastPathComponent
            guard prefixes.contains(where: { name.hasPrefix($0) }) else { return nil }
            let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard modified >= cutoff else { return nil }
            return Report(url: url, modifiedAt: modified)
        }
        return Array(matching.sorted { $0.modifiedAt > $1.modifiedAt }.prefix(max(0, limit)))
    }

    /// Redact user- and device-identifying values from a report's text.
    public static func sanitize(
        _ contents: String,
        homeDirectory: String = FileManager.default.homeDirectoryForCurrentUser.path,
        userName: String = NSUserName()
    ) -> String {
        var sanitized = contents

        // Home path first (it usually embeds the user name).
        if !homeDirectory.isEmpty, homeDirectory != "/" {
            sanitized = sanitized.replacingOccurrences(of: homeDirectory, with: "/Users/[redacted]")
            // Crash reports JSON-escape "/" as "\/" in path strings.
            let escapedHome = homeDirectory.replacingOccurrences(of: "/", with: "\\/")
            sanitized = sanitized.replacingOccurrences(of: escapedHome, with: "\\/Users\\/[redacted]")
        }
        // Residual login-name occurrences outside the home path. Guard
        // against degenerate short names over-redacting hex/symbols.
        if userName.count >= 4 {
            sanitized = sanitized.replacingOccurrences(of: "/Users/\(userName)", with: "/Users/[redacted]")
            sanitized = sanitized.replacingOccurrences(of: "\\/Users\\/\(userName)", with: "\\/Users\\/[redacted]")
        }

        for key in ["deviceIdentifierForVendor", "crashReporterKey", "sleepWakeUUID", "bootSessionUUID", "incident_id", "incident"] {
            sanitized = redactJSONStringValue(key: key, in: sanitized)
        }
        return sanitized
    }

    /// Replaces `"key":"…"` / `"key" : "…"` string values with `[redacted]`.
    static func redactJSONStringValue(key: String, in text: String) -> String {
        let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*\"[^\"]*\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text,
            range: range,
            withTemplate: "\"\(key)\":\"[redacted]\""
        )
    }
}
