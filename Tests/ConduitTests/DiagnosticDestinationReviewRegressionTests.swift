// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel
@testable import ProxyControlBridge

final class DiagnosticDestinationReviewRegressionTests: XCTestCase {
    func testMissingCaseAliasIsRefusedBeforeCreatingAProtectedFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-review-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("owned fixture cleanup failed: \(error)") }
        }
        let flags = try root.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey])
        guard flags.volumeSupportsCaseSensitiveNames == false else {
            throw XCTSkip("case-alias check requires a case-insensitive fixture volume")
        }
        let environment = RuntimeEnvironment.isolated(stateDirectory: root)
        let file = RotatingRecordFile(
            fileURL: root.appendingPathComponent("CONFIG.JSON"), maxBytes: 1_024,
            destinationGuard: diagnosticDestinationGuard(for: .connectionAudit, in: environment))
        XCTAssertThrowsError(try file.append([Data("{\"audit\":true}\n".utf8)])) {
            XCTAssertEqual(($0 as? RecordFileDestinationRefusal)?.resource, .config)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.configFile.path),
                       "refusing after open is too late: it created a blank config")
    }

    func testMissingUnicodeCaseAliasIsRefusedBeforeCreatingPreferences() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-unicode-review-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("owned fixture cleanup failed: \(error)") }
        }
        let probe = root.appendingPathComponent("probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: false)
        try Data().write(to: probe.appendingPathComponent("preferences.json"))
        guard FileManager.default.fileExists(atPath: probe.appendingPathComponent("preferenceſ.json").path) else {
            throw XCTSkip("fixture volume does not fold long s")
        }
        let environment = RuntimeEnvironment.isolated(stateDirectory: root)
        let file = RotatingRecordFile(
            fileURL: root.appendingPathComponent("preferenceſ.json"), maxBytes: 1_024,
            destinationGuard: diagnosticDestinationGuard(for: .connectionAudit, in: environment))
        XCTAssertThrowsError(try file.append([Data("{\"audit\":true}\n".utf8)])) {
            XCTAssertEqual(($0 as? RecordFileDestinationRefusal)?.resource, .preferences)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.preferencesFile.path),
                       "the refusal must happen before creating preferences")
    }

    func testDestinationBeneathMissingConfigIsRefusedBeforeCreatingConfigDirectory() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("diagnostic-parent-review-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: root) }
            catch { XCTFail("owned fixture cleanup failed: \(error)") }
        }
        let environment = RuntimeEnvironment.isolated(stateDirectory: root)
        let file = RotatingRecordFile(
            fileURL: environment.configFile.appendingPathComponent("audit.ndjson"), maxBytes: 1_024,
            destinationGuard: diagnosticDestinationGuard(for: .connectionAudit, in: environment))
        XCTAssertThrowsError(try file.append([Data("{\"audit\":true}\n".utf8)])) {
            XCTAssertEqual(($0 as? RecordFileDestinationRefusal)?.resource, .config)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: environment.configFile.path),
                       "diagnostics must not create a directory in place of the future config file")
    }

    func testEventLogAndWriterDoNotKeepEachOtherAlive() {
        weak var observedLog: RuntimeEventLog?
        weak var observedWriter: RuntimeEventFileWriter?
        installEphemeralWriter { log, writer in
            observedLog = log
            observedWriter = writer
        }
        XCTAssertNil(observedLog, "destination gate must not retain the log that retains its writer")
        XCTAssertNil(observedWriter, "a disposed owner must release its writer")
    }

    private func installEphemeralWriter(_ observe: (RuntimeEventLog, RuntimeEventFileWriter) -> Void) {
        let log = RuntimeEventLog()
        let writer = RuntimeEventFileWriter(
            fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("unused-" + UUID().uuidString),
            logger: DiscardingLogSink(), destinationGuard: UncheckedRecordFileDestination(), eventLog: log)
        log.setSink { writer.record($0) }
        observe(log, writer)
    }
}
