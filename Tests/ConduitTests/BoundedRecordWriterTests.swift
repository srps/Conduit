// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class BoundedRecordWriterTests: XCTestCase {
    func testBlockedStorageBoundsInflightRecordsBytesAndFlush() {
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let output = NIOLockedValueBox<[Data]>([])
        var limits = RecordWriterLimits()
        limits.maxPendingRecords = 3
        limits.maxPendingBytes = 12
        limits.maxBatchRecords = 2
        limits.maxBatchBytes = 8
        let writer = BoundedRecordWriter(limits: limits, write: { batch in
            started.signal()
            release.wait()
            output.withLockedValue { $0.append(contentsOf: batch) }
        }, reportFailure: { _ in XCTFail("Unexpected storage failure") })
        writer.append(Data("0000".utf8))
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        defer { for _ in 0..<4 { release.signal() }; writer.flush() }
        writer.append(Data("1111".utf8))
        writer.append(Data("2222".utf8))
        // A blocked write still counts against capacity; sustained production
        // cannot accumulate an unbounded Dispatch queue or captured payloads.
        for _ in 0..<10_000 { writer.append(Data("3333".utf8)) }
        XCTAssertEqual(writer.statistics.pendingRecords, 3)
        XCTAssertEqual(writer.statistics.pendingBytes, 12)
        XCTAssertEqual(writer.statistics.droppedRecords, 10_000)
        let before = DispatchTime.now().uptimeNanoseconds
        XCTAssertFalse(writer.flush(timeout: 0.01))
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - before, 500_000_000)
        XCTAssertEqual(writer.statistics.flushTimeouts, 1)
        release.signal()
        release.signal()
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(writer.statistics.pendingRecords, 0)
        XCTAssertEqual(writer.statistics.pendingBytes, 0)
        XCTAssertEqual(writer.statistics.writtenRecords, 3)
        XCTAssertEqual(output.withLockedValue { $0.map { String(decoding: $0, as: UTF8.self) } },
                       ["0000", "1111", "2222"])
    }

    func testByteLimitAndOversizedBatchRecordAreIndependentOfRecordLimit() {
        var limits = RecordWriterLimits()
        limits.maxPendingRecords = 100
        limits.maxPendingBytes = 4
        limits.maxBatchBytes = 8
        let writer = BoundedRecordWriter(limits: limits, write: { _ in XCTFail("Oversized record written") },
                                         reportFailure: { _ in })
        writer.append(Data(repeating: 1, count: 5))
        writer.append(Data(repeating: 1, count: 9))
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(writer.statistics.droppedRecords, 2)
        XCTAssertEqual(writer.statistics.pendingBytes, 0)
    }

    func testFailureIsCountedReportedAndCapacityRecovers() {
        let errors = NIOLockedValueBox<[String]>([])
        let writer = BoundedRecordWriter(write: { _ in throw CocoaError(.fileWriteNoPermission) },
                                         reportFailure: { error in errors.withLockedValue { $0.append(error) } })
        writer.append(Data("record\n".utf8))
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(writer.statistics.failedRecords, 1)
        XCTAssertEqual(writer.statistics.pendingBytes, 0)
        XCTAssertEqual(errors.withLockedValue { $0.count }, 1)
        writer.append(Data("retry\n".utf8))
        XCTAssertTrue(writer.flush())
        XCTAssertEqual(writer.statistics.failedRecords, 2)
    }

    func testFileAppendPreservesExistingRecordsAndRotatesWholeGenerations() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.ndjson")
        let file = RotatingRecordFile(fileURL: url, maxBytes: 12)
        try file.append([Data("one\n".utf8), Data("two\n".utf8)])
        try file.append([Data("tri\n".utf8)])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "one\ntwo\ntri\n")
        try file.append([Data("four\n".utf8), Data("five\n".utf8)])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "four\nfive\n")
        XCTAssertLessThanOrEqual(try Data(contentsOf: url).count, 12)
    }

    func testFileRetiresTornTailBeforeAppending() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("events.ndjson")
        try Data("{\"ok\":true}\n{\"torn\":".utf8).write(to: url)
        let file = RotatingRecordFile(fileURL: url, maxBytes: 128)
        try file.append([Data("{\"new\":true}\n".utf8)])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "{\"new\":true}\n")
        XCTAssertEqual(file.rotationCount, 1)
    }

    @MainActor
    func testTerminationDrainsAlreadyAcceptedAuditRecords() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, logger: DiscardingLogSink())
        let record = ConnectionAuditRecord(id: UUID(), timestamp: Date(), clientAddress: "127.0.0.1",
            scheme: .https, target: "fixture.test:443", pacDecision: nil, chosenUpstream: "DIRECT",
            authMethod: nil, bytesSent: 1, bytesReceived: 1, durationMS: 1, outcome: .success)
        let orchestrator = ProxyOrchestrator(config: GenericDefaults.shared.makeConfig(), auditSink: sink)
        sink.record(record)
        orchestrator.performTerminationCleanup()
        XCTAssertEqual(sink.statistics.pendingRecords, 0)
        let line = try Data(contentsOf: url).split(separator: 0x0A).first!
        let decoded = try CanonicalJSON.decoder().decode(ConnectionAuditRecord.self, from: Data(line))
        XCTAssertEqual(decoded.id, record.id)
        XCTAssertEqual(decoded.target, record.target)
        XCTAssertEqual(decoded.outcome, record.outcome)
        XCTAssertEqual(decoded.timestamp.timeIntervalSince1970, record.timestamp.timeIntervalSince1970, accuracy: 0.000_001)
    }

    func testRecordingAuditSinkBoundsAndRecoversAfterClear() {
        let sink = RecordingConnectionAuditSink(capacity: 1)
        let record = ConnectionAuditRecord(id: UUID(), timestamp: Date(), clientAddress: nil,
            scheme: .https, target: "fixture.test:443", pacDecision: nil, chosenUpstream: "DIRECT",
            authMethod: nil, bytesSent: 0, bytesReceived: 0, durationMS: 0, outcome: .success)
        sink.record(record)
        sink.record(record)
        XCTAssertEqual(sink.records().count, 1)
        XCTAssertEqual(sink.statistics.droppedRecords, 1)
        sink.clear()
        XCTAssertEqual(sink.statistics.pendingBytes, 0)
        sink.record(record)
        XCTAssertEqual(sink.records().count, 1)
    }

    func testRecordingLogSinkDropsAtCapacityAndReportsLoss() {
        let sink = RecordingLogSink(capacity: 2)
        for i in 0..<3 { sink.log(.warning, "entry-\(i)", category: .general) }
        XCTAssertEqual(sink.entries().count, 2)
        XCTAssertEqual(sink.droppedRecords, 1)
        sink.clear()
        sink.log(.warning, "after-clear", category: .general)
        XCTAssertEqual(sink.entries().count, 1)
    }
}
