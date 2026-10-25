// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import Conduit

final class RotatingLogFileTests: XCTestCase {

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RotatingLogFileTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { removeScratch([dir]) }
        return dir
    }

    /// The writer as the app composes it, with the unchecked fixture guard named at the call site.
    private func openFile(
        _ url: URL, maxBytes: Int = 5 << 20, archives: Int = 3, events: RuntimeEventLog
    ) -> any RotatingByteWriter {
        rotatingLogFile(
            url: url, maxBytes: maxBytes, archives: archives,
            destinationGuard: UncheckedRecordFileDestination(),
            gate: RecordFileDestinationGate(sink: .appLog, eventLog: events, logger: DiscardingLogSink()),
            eventLog: events, logger: DiscardingLogSink()
        )
    }

    /// The old writer called `createFile(atPath:contents: nil)` on open,
    /// which truncated — flipping the Settings toggle erased the last
    /// session's log. Opening twice must keep what the first open wrote.
    func testReopeningAppendsInsteadOfTruncating() throws {
        let url = try tempDir().appendingPathComponent("proxy.log")
        let events = RuntimeEventLog()
        let first = openFile(url, events: events)
        first.write(Data("one\n".utf8))
        first.close()

        let second = openFile(url, events: events)
        second.write(Data("two\n".utf8))
        second.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
    }

    func testRollsOverAtMaxBytesAndKeepsTheConfiguredArchives() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("proxy.log")
        let events = RuntimeEventLog()
        let file = openFile(url, maxBytes: 12, archives: 2, events: events)
        // Each line is 6 bytes; two fit exactly, the third rolls. Five lines → the
        // live file holds line 5, .1 holds 3+4, .2 holds 1+2, and nothing
        // older survives.
        for i in 1...5 {
            file.write(Data("line\(i)\n".utf8))
        }
        file.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "line5\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("proxy.log.1"), encoding: .utf8), "line3\nline4\n")
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("proxy.log.2"), encoding: .utf8), "line1\nline2\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("proxy.log.3").path))
    }

    /// A single line larger than the ceiling is still written, into a fresh
    /// file, rather than rotating forever or being dropped.
    func testAnOversizedLineIsWrittenNotDropped() throws {
        let url = try tempDir().appendingPathComponent("proxy.log")
        let file = openFile(url, maxBytes: 4, archives: 1, events: RuntimeEventLog())
        file.write(Data("short\n".utf8))
        file.write(Data("much longer line\n".utf8))
        file.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "much longer line\n")
    }

    @MainActor func testTheStoreWritesFormattedLinesThroughTheRotatingFile() throws {
        let url = try tempDir().appendingPathComponent("proxy.log")
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minStderrLevel = .error
        store.logFileURL = url
        store.log(.notice, "hello file")
        store.flushFileLog()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[NOTICE] [General] hello file\n"), text)
    }

    /// A file that cannot be written must say so — once — and the report must not carry the path. Here the parent
    /// "directory" is a regular file, so creating the directory fails and the failure is `mkdir`.
    func testAnUnwritableFileReportsOnceNotPerLine() throws {
        let parent = try tempDir().appendingPathComponent("not-a-directory")
        try Data().write(to: parent)
        let url = parent.appendingPathComponent("proxy.log")
        let events = RuntimeEventLog()
        let file = openFile(url, events: events)
        for i in 1...3 { file.write(Data("line\(i)\n".utf8)) }
        file.flush()
        let failures = events.events.filter { $0.event == "observability.log_file_failed" }
        XCTAssertEqual(failures.count, 1, "\(events.events.map(\.event))")
        XCTAssertTrue(failures.first?.detail?.hasPrefix("stage=mkdir ") ?? false, failures.first?.detail ?? "none")
        XCTAssertFalse(failures.first?.detail?.contains(url.path) ?? true, failures.first?.detail ?? "none")
    }

    /// The store routes the report into its own ring buffer. That report is
    /// itself offered to the failing file, which must not turn into a second
    /// report — or a third.
    @MainActor func testTheStoreSurfacesAFileFailureInTheRingBufferWithoutLooping() async throws {
        let parent = try tempDir().appendingPathComponent("not-a-directory")
        try Data().write(to: parent)
        let store = AppLogStore(destinationGuard: UncheckedRecordFileDestination(), eventLog: RuntimeEventLog())
        store.minStderrLevel = .error
        store.logFileURL = parent.appendingPathComponent("proxy.log")
        for i in 1...3 { store.log(.notice, "line \(i)") }
        store.flushFileLog()
        // The report hops to MainActor; give it a few turns to land.
        for _ in 0..<50 where !store.entries.contains(where: { $0.level == .warning }) {
            try await Task.sleep(for: .milliseconds(10))
        }
        store.flushFileLog()
        try await Task.sleep(for: .milliseconds(20))
        let warnings = store.entries.filter { $0.level == .warning }
        XCTAssertEqual(warnings.count, 1, warnings.map(\.message).joined(separator: "\n"))
        XCTAssertTrue(warnings[0].message.contains("File logging is not recording"), warnings[0].message)
    }

    func testFileLoggingIsOnByDefaultAndSurvivesAnOlderPreferencesFile() throws {
        XCTAssertTrue(AppPreferences().fileLoggingEnabled)
        let old = Data(#"{"showMenuBarIcon":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertTrue(decoded.fileLoggingEnabled, "a preferences file from before the key existed means default, not off")
    }
}
