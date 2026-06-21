// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

final class CrashReportCollectorTests: XCTestCase {

    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("crash-collector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDir)
    }

    private func writeReport(name: String, modified: Date) throws -> URL {
        let url = tempDir.appendingPathComponent(name)
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    func testSelectsOnlyMatchingPrefixAndExtension() throws {
        let now = Date()
        _ = try writeReport(name: "Conduit-2026-06-10-060007.ips", modified: now)
        _ = try writeReport(name: "ConduitDaemon-2026-06-09-120000.ips", modified: now)
        _ = try writeReport(name: "OtherApp-2026-06-10-060007.ips", modified: now)
        _ = try writeReport(name: "Conduit-notes.txt", modified: now)

        let reports = CrashReportCollector.recentReports(in: tempDir, now: now)
        let names = reports.map { $0.url.lastPathComponent }.sorted()
        XCTAssertEqual(names, [
            "Conduit-2026-06-10-060007.ips",
            "ConduitDaemon-2026-06-09-120000.ips",
        ])
    }

    func testHonorsAgeCutoffLimitAndNewestFirstOrder() throws {
        let now = Date()
        _ = try writeReport(name: "Conduit-old.ips", modified: now.addingTimeInterval(-40 * 24 * 3600))
        for i in 1...7 {
            _ = try writeReport(
                name: "Conduit-recent-\(i).ips",
                modified: now.addingTimeInterval(TimeInterval(-i * 60))
            )
        }

        let reports = CrashReportCollector.recentReports(in: tempDir, limit: 5, now: now)
        XCTAssertEqual(reports.count, 5)
        XCTAssertEqual(reports.first?.url.lastPathComponent, "Conduit-recent-1.ips", "newest first")
        XCTAssertFalse(reports.contains { $0.url.lastPathComponent == "Conduit-old.ips" })
        XCTAssertEqual(reports, reports.sorted { $0.modifiedAt > $1.modifiedAt })
    }

    func testMissingDirectoryYieldsEmptyList() {
        let missing = tempDir.appendingPathComponent("nope", isDirectory: true)
        XCTAssertEqual(CrashReportCollector.recentReports(in: missing), [])
    }

    func testSanitizeRedactsHomePathPlainAndJSONEscaped() {
        let raw = """
        "procPath":"\\/Users\\/jdoe\\/Library\\/Foo","other":"/Users/jdoe/projects/x"
        """
        let out = CrashReportCollector.sanitize(raw, homeDirectory: "/Users/jdoe", userName: "jdoe")
        XCTAssertFalse(out.contains("jdoe"), "login name must not survive: \(out)")
        XCTAssertTrue(out.contains("/Users/[redacted]/projects/x"))
        XCTAssertTrue(out.contains("\\/Users\\/[redacted]\\/Library\\/Foo"))
    }

    func testSanitizeRedactsDeviceIdentifiers() {
        let raw = """
        {"crashReporterKey":"A60A93C6-3C8A","storeInfo":{"deviceIdentifierForVendor" : "1EC6F472-B99C"},"sleepWakeUUID":"F8C2290C","bootSessionUUID":"97993E37","incident_id":"69362EE2"}
        """
        let out = CrashReportCollector.sanitize(raw, homeDirectory: "/Users/jdoe", userName: "jdoe")
        for leaked in ["A60A93C6", "1EC6F472", "F8C2290C", "97993E37", "69362EE2"] {
            XCTAssertFalse(out.contains(leaked), "identifier must be redacted: \(leaked)")
        }
        XCTAssertTrue(out.contains("\"deviceIdentifierForVendor\":\"[redacted]\""))
    }

    func testSanitizePreservesDiagnosticContent() {
        let raw = """
        {"exception":{"type":"EXC_BAD_ACCESS","signal":"SIGSEGV"},"frames":[{"symbol":"spnego_reply","symbolLocation":216,"imageOffset":64332}]}
        """
        let out = CrashReportCollector.sanitize(raw, homeDirectory: "/Users/jdoe", userName: "jdoe")
        XCTAssertEqual(out, raw, "symbols, offsets, and exception data must be untouched")
    }

    func testSanitizeShortUserNameDoesNotOverRedact() {
        let raw = "value abc 0xabc \"/Users/abc/x\""
        let out = CrashReportCollector.sanitize(raw, homeDirectory: "/Users/abc", userName: "abc")
        XCTAssertTrue(out.contains("value abc 0xabc"), "bare short tokens must survive")
        XCTAssertTrue(out.contains("/Users/[redacted]/x"))
    }
}
