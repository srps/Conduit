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
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    /// The old writer called `createFile(atPath:contents: nil)` on open,
    /// which truncated — flipping the Settings toggle erased the last
    /// session's log. Opening twice must keep what the first open wrote.
    func testReopeningAppendsInsteadOfTruncating() throws {
        let url = try tempDir().appendingPathComponent("proxy.log")
        let first = RotatingLogFile(url: url)
        first.write(Data("one\n".utf8))
        first.close()

        let second = RotatingLogFile(url: url)
        second.write(Data("two\n".utf8))
        second.close()

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\n")
    }

    func testRollsOverAtMaxBytesAndKeepsTheConfiguredArchives() throws {
        let dir = try tempDir()
        let url = dir.appendingPathComponent("proxy.log")
        let file = RotatingLogFile(url: url, maxBytes: 12, archives: 2)
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
        let file = RotatingLogFile(url: url, maxBytes: 4, archives: 1)
        file.write(Data("short\n".utf8))
        file.write(Data("much longer line\n".utf8))
        file.close()
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "much longer line\n")
    }

    @MainActor func testTheStoreWritesFormattedLinesThroughTheRotatingFile() throws {
        let url = try tempDir().appendingPathComponent("proxy.log")
        let store = AppLogStore()
        store.minStderrLevel = .error
        store.logFileURL = url
        store.log(.notice, "hello file")
        store.flushFileLog()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("[NOTICE] [General] hello file\n"), text)
    }

    func testFileLoggingIsOnByDefaultAndSurvivesAnOlderPreferencesFile() throws {
        XCTAssertTrue(AppPreferences().fileLoggingEnabled)
        let old = Data(#"{"showMenuBarIcon":true}"#.utf8)
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: old)
        XCTAssertTrue(decoded.fileLoggingEnabled, "a preferences file from before the key existed means default, not off")
    }
}
