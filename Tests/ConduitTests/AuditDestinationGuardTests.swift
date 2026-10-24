// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyControlBridge
@testable import ProxyKernel

/// The audit writer against real files: a destination that aliases a protected
/// resource is refused before anything is created or truncated (#222).
final class AuditDestinationGuardTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-audit-dest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeEnvironment() -> RuntimeEnvironment {
        RuntimeEnvironment(configDirectory: root)
    }

    /// Saved through the production persistence path: pretty JSON with no trailing newline,
    /// the shape that `RotatingRecordFile` used to truncate.
    private func saveConfig(_ environment: RuntimeEnvironment) throws -> Data {
        try ProxyConfigPersistence.save(GenericDefaults.shared.makeConfig(), in: environment)
        return try Data(contentsOf: environment.configFile)
    }

    private func auditSink(
        at url: URL,
        environment: RuntimeEnvironment,
        log: RuntimeEventLog
    ) -> FileConnectionAuditSink {
        FileConnectionAuditSink(
            fileURL: url, maxBytes: 1_000_000, logger: DiscardingLogSink(),
            destinationGuard: diagnosticDestinationGuard(for: .connectionAudit, in: environment),
            eventLog: log
        )
    }

    private func fixtureRecord() -> ConnectionAuditRecord {
        ConnectionAuditRecord(id: UUID(), timestamp: Date(), clientAddress: "127.0.0.1",
            scheme: .https, target: "fixture.test:443", pacDecision: nil, chosenUpstream: "DIRECT",
            authMethod: nil, bytesSent: 1, bytesReceived: 1, durationMS: 1, outcome: .success)
    }

    private func refusalDetails(_ log: RuntimeEventLog) -> [String] {
        log.events.filter { $0.event == RecordFileDestinationGate.eventName }.compactMap(\.detail)
    }

    func testDirectAliasOfConfigIsRefusedAndConfigBytesUnchanged() throws {
        let environment = makeEnvironment()
        let config = try saveConfig(environment)
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: environment.configFile, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
        XCTAssertEqual(sink.statistics.writtenRecords, 0)
        XCTAssertEqual(sink.statistics.failedRecords, 1)
        XCTAssertEqual(refusalDetails(log), ["sink=audit reason=protected_path resource=config"])
    }

    func testSymlinkAliasOfConfigIsRefused() throws {
        let environment = makeEnvironment()
        let config = try saveConfig(environment)
        let alias = root.appendingPathComponent("audit.ndjson")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: environment.configFile)
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: alias, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
        XCTAssertEqual(refusalDetails(log), ["sink=audit reason=protected_path resource=config"])
    }

    func testHardlinkAliasOfConfigIsRefusedByIdentity() throws {
        let environment = makeEnvironment()
        let config = try saveConfig(environment)
        let alias = root.appendingPathComponent("audit.ndjson")
        try FileManager.default.linkItem(at: environment.configFile, to: alias)
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: alias, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
        XCTAssertEqual(refusalDetails(log), ["sink=audit reason=protected_identity resource=config"])
    }

    func testDanglingSymlinkIsRefusedBeforeItsTargetIsCreated() throws {
        let environment = makeEnvironment()
        let target = root.appendingPathComponent("not-yet.json")
        let alias = root.appendingPathComponent("audit.ndjson")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: alias, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        XCTAssertEqual(refusalDetails(log), ["sink=audit reason=inspection_failed resource=none"])
    }

    func testValidDefaultAuditPathWritesAndLeavesConfigAlone() throws {
        let environment = makeEnvironment()
        let config = try saveConfig(environment)
        let log = RuntimeEventLog(capacity: 16)
        let url = environment.configDirectory.appendingPathComponent("audit.ndjson")
        let sink = auditSink(at: url, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(sink.statistics.writtenRecords, 1)
        XCTAssertEqual(sink.statistics.failedRecords, 0)
        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
        XCTAssertTrue(refusalDetails(log).isEmpty)
    }

    func testValidExternalAuditPathOutsideStateDirectoryWrites() throws {
        let environment = makeEnvironment()
        _ = try saveConfig(environment)
        let external = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-audit-external-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: external) }
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: external.appendingPathComponent("compliance.ndjson"),
                             environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(sink.statistics.writtenRecords, 1)
        XCTAssertTrue(refusalDetails(log).isEmpty)
    }

    func testTornOwnedAuditFileKeepsItsRotationSemantics() throws {
        let environment = makeEnvironment()
        let url = root.appendingPathComponent("audit.ndjson")
        try Data("{\"ok\":true}\n{\"torn\":".utf8).write(to: url)
        let file = RotatingRecordFile(
            fileURL: url, maxBytes: 128,
            destinationGuard: diagnosticDestinationGuard(for: .connectionAudit, in: environment)
        )

        try file.append([Data("{\"new\":true}\n".utf8)])

        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"new\":true}\n")
        XCTAssertEqual(file.rotationCount, 1)
    }

    /// The writer reopens its destination for every batch. A path that becomes a config alias
    /// after a healthy write is refused on the next write, and the atomically replaced config
    /// keeps its new bytes.
    func testAuditPathTurnedIntoConfigAliasIsRefusedAfterAtomicConfigReplacement() throws {
        let environment = makeEnvironment()
        _ = try saveConfig(environment)
        let url = root.appendingPathComponent("audit.ndjson")
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: url, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())
        XCTAssertEqual(sink.statistics.writtenRecords, 1)

        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(at: url, withDestinationURL: environment.configFile)
        var changed = GenericDefaults.shared.makeConfig()
        changed.localPort = 3128
        try ProxyConfigPersistence.save(changed, in: environment)
        let replaced = try Data(contentsOf: environment.configFile)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(try Data(contentsOf: environment.configFile), replaced)
        XCTAssertEqual(sink.statistics.writtenRecords, 1)
        XCTAssertEqual(refusalDetails(log), ["sink=audit reason=protected_path resource=config"])
    }

    /// A destination beneath a nested custom config whose directory is missing is refused before the directory
    /// is created. A sibling directory whose name only shares a prefix still writes through the real guard.
    func testMissingCustomConfigDirectoryIsNotCreatedByBeneathDestinationButSiblingWrites() throws {
        let custom = root.appendingPathComponent("custom", isDirectory: true)
        let environment = RuntimeEnvironment.explicit(configFile: custom.appendingPathComponent("config.json"))
        let beneathLog = RuntimeEventLog(capacity: 16)
        let beneath = auditSink(
            at: custom.appendingPathComponent("config.json").appendingPathComponent("audit.ndjson"),
            environment: environment, log: beneathLog)

        beneath.record(fixtureRecord())
        XCTAssertTrue(beneath.flush())

        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path), "a refused destination created the config directory")
        XCTAssertEqual(beneath.statistics.writtenRecords, 0)
        XCTAssertEqual(refusalDetails(beneathLog), ["sink=audit reason=protected_path resource=config"])

        let sibling = root.appendingPathComponent("custom-audit", isDirectory: true)
            .appendingPathComponent("audit.ndjson")
        let siblingLog = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: sibling, environment: environment, log: siblingLog)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(sink.statistics.writtenRecords, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
        XCTAssertTrue(refusalDetails(siblingLog).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: custom.path))
    }

    /// The first refusal emits one event. Records after it are counted as drops and never reach storage.
    func testRefusalEmitsOneEventAndLaterRecordsAreCountedAsDrops() throws {
        let environment = makeEnvironment()
        let config = try saveConfig(environment)
        let log = RuntimeEventLog(capacity: 16)
        let sink = auditSink(at: environment.configFile, environment: environment, log: log)

        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())
        sink.record(fixtureRecord())
        sink.record(fixtureRecord())
        XCTAssertTrue(sink.flush())

        XCTAssertEqual(try Data(contentsOf: environment.configFile), config)
        XCTAssertEqual(sink.statistics.writtenRecords, 0)
        XCTAssertEqual(sink.statistics.failedRecords, 1)
        XCTAssertEqual(sink.statistics.droppedRecords, 2)
        XCTAssertEqual(refusalDetails(log).count, 1)
    }
}
