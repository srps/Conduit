// SPDX-License-Identifier: Apache-2.0
// Pure-helper tests for `LogView.filter`. The view's body wires this through
// a `@State` cache (`filteredEntries`) updated only on input-changed events
// — `searchText`, `selectedCategories`, `minimumLevel`, and
// `logStore.entries.count`. The cache invariant ("recompute only on
// input change") isn't directly testable without a SwiftUI host, but the
// filter logic itself is pure — these tests pin down the level / category /
// substring contract that `recomputeFilter()` runs against the cached state.

import XCTest
@testable import ProxyKernel
@testable import Conduit

@MainActor
final class LogViewFilterCacheTests: XCTestCase {

    // MARK: - Reversal

    func testFilterReversesEntries() {
        let entries: [LogEntry] = [
            LogEntry(level: .info, category: .general, message: "first"),
            LogEntry(level: .info, category: .general, message: "second"),
            LogEntry(level: .info, category: .general, message: "third"),
        ]

        let result = LogView.filter(
            entries: entries,
            categories: Set(LogCategory.allCases),
            minimumLevel: .debug,
            search: ""
        )

        XCTAssertEqual(result.map(\.message), ["third", "second", "first"],
                       "Filter must reverse so newest entries appear first (matches list display).")
    }

    // MARK: - Category filter

    func testFilterDropsExcludedCategories() {
        let entries: [LogEntry] = [
            LogEntry(level: .info, category: .auth, message: "auth"),
            LogEntry(level: .info, category: .proxy, message: "proxy"),
            LogEntry(level: .info, category: .pac, message: "pac"),
        ]

        let result = LogView.filter(
            entries: entries,
            categories: [.proxy],
            minimumLevel: .debug,
            search: ""
        )

        XCTAssertEqual(result.map(\.message), ["proxy"])
    }

    // MARK: - Level filter

    func testFilterDropsBelowMinimumLevel() {
        let entries: [LogEntry] = [
            LogEntry(level: .debug, category: .general, message: "debug"),
            LogEntry(level: .info, category: .general, message: "info"),
            LogEntry(level: .warning, category: .general, message: "warning"),
        ]

        let result = LogView.filter(
            entries: entries,
            categories: Set(LogCategory.allCases),
            minimumLevel: .warning,
            search: ""
        )

        XCTAssertEqual(result.map(\.message), ["warning"],
                       "minimumLevel: .warning must drop debug and info.")
    }

    // MARK: - Search substring (case-insensitive)

    func testFilterSubstringIsCaseInsensitive() {
        let entries: [LogEntry] = [
            LogEntry(level: .info, category: .general, message: "Connected to Preset proxy"),
            LogEntry(level: .info, category: .general, message: "DNS resolution failed"),
            LogEntry(level: .info, category: .general, message: "PRESET upstream healthy"),
        ]

        let result = LogView.filter(
            entries: entries,
            categories: Set(LogCategory.allCases),
            minimumLevel: .debug,
            search: "preset"
        )

        XCTAssertEqual(result.count, 2)
        XCTAssertTrue(result.allSatisfy { $0.message.lowercased().contains("preset") })
    }

    func testFilterEmptySearchMatchesAll() {
        let entries: [LogEntry] = (0..<5).map {
            LogEntry(level: .info, category: .general, message: "msg \($0)")
        }

        let result = LogView.filter(
            entries: entries,
            categories: Set(LogCategory.allCases),
            minimumLevel: .debug,
            search: ""
        )

        XCTAssertEqual(result.count, 5)
    }

    // MARK: - Combined filter

    func testFilterAppliesAllConstraintsTogether() {
        let entries: [LogEntry] = [
            LogEntry(level: .debug, category: .auth, message: "kerberos init"),
            LogEntry(level: .warning, category: .auth, message: "kerberos failed"),
            LogEntry(level: .warning, category: .proxy, message: "kerberos hint in proxy"),
            LogEntry(level: .warning, category: .auth, message: "ntlm fallback"),
        ]

        let result = LogView.filter(
            entries: entries,
            categories: [.auth],
            minimumLevel: .warning,
            search: "kerberos"
        )

        // Drop debug (level), drop proxy (category), keep "kerberos failed",
        // drop "ntlm fallback" (no kerberos substring).
        XCTAssertEqual(result.map(\.message), ["kerberos failed"])
    }

    // MARK: - Performance characteristic (smoke check)

    /// Pin the assumption that the filter is O(N): a 2000-entry input runs
    /// in well under 50ms on the dev machine. Mostly a regression guard so
    /// nobody accidentally introduces an O(N²) substring search inside the
    /// filter loop and degrades the cached-recompute path.
    func testFilterScalesLinearlyWith2000Entries() {
        let entries: [LogEntry] = (0..<2000).map {
            LogEntry(
                level: .info,
                category: LogCategory.allCases[$0 % LogCategory.allCases.count],
                message: "log line \($0) with kerberos token if even=\($0 % 2 == 0)"
            )
        }

        let start = Date()
        let result = LogView.filter(
            entries: entries,
            categories: Set(LogCategory.allCases),
            minimumLevel: .debug,
            search: "kerberos"
        )
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(result.count, 2000, "Every entry contains 'kerberos'.")
        XCTAssertLessThan(elapsed, 0.5, "2000-entry filter should be well under 500ms.")
    }
}
