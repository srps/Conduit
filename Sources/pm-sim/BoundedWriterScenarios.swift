// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOPosix
import ProxyKernel

enum BoundedWriterScenarios {
    private struct Failure: Error { let message: String }

    static func slowStorage() async throws -> ScenarioResult {
        let start = Date()
        let started = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        var limits = RecordWriterLimits()
        limits.maxPendingRecords = 16
        limits.maxPendingBytes = 1024
        limits.maxBatchRecords = 16
        limits.maxBatchBytes = 1024
        let writer = BoundedRecordWriter(limits: limits, write: { _ in
            started.signal()
            release.wait()
        }, reportFailure: { _ in })
        defer {
            release.signal()
            release.signal()
            writer.flush()
        }
        writer.append(Data(repeating: 65, count: 64))
        guard storageStarted(started) else {
            throw Failure(message: "Storage fixture did not start")
        }
        // A stalled storage callback must not stall the event loop generating logs.
        let loop = MultiThreadedEventLoopGroup.singleton.next()
        try await loop.submit {
            for _ in 0..<10_000 { writer.append(Data(repeating: 66, count: 64)) }
        }.get()
        let responsive = try await loop.submit { true }.get()
        let blocked = writer.statistics
        guard responsive, blocked.pendingRecords == 16, blocked.pendingBytes == 1024,
              blocked.droppedRecords == 9985, !writer.flush(timeout: 0.01) else {
            throw Failure(message: "Storage backlog was unbounded or loss/deadline was not observable")
        }
        release.signal()
        release.signal()
        guard writer.flush(), writer.statistics.pendingRecords == 0,
              writer.statistics.writtenRecords == 16 else {
            throw Failure(message: "Storage capacity failed to recover after unblocking")
        }
        try shutdownTimeoutPersistence()
        let appendNote = try appendAmplification()
        return ScenarioResult(
            name: "bounded-writers", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 1024, durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            notes: ["PASS: stalled storage retains at most 16 records/1024 bytes including in-flight writes",
                    "PASS: 9985 drops and flush deadline reported; event loop responsive; capacity recovered", appendNote])
    }

    private static func storageStarted(_ signal: DispatchSemaphore) -> Bool {
        signal.wait(timeout: .now() + 2) == .success
    }

    private static func shutdownTimeoutPersistence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-flush-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.ndjson")
        let writer = RuntimeEventFileWriter(fileURL: url, logger: DiscardingLogSink())
        let events = RuntimeEventLog(capacity: 8)
        events.setSink { writer.record($0) }
        guard !writer.flushReportingTimeout(auditFlushed: false, eventLog: events) else {
            throw Failure(message: "Shutdown concealed the audit flush failure")
        }
        let rows = try Data(contentsOf: url).split(separator: 0x0A).map {
            try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0))
        }
        guard rows.count == 1, rows.first?.event == "observability.flush_timeout",
              writer.statistics.pendingRecords == 0 else {
            throw Failure(message: "Shutdown returned before persisting its timeout event")
        }
    }

    private static func appendAmplification() throws -> String {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("conduit-writer-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.ndjson")
        let file = RotatingRecordFile(fileURL: url, maxBytes: 32_768)
        let writer = BoundedRecordWriter(write: { try file.append($0) }, reportFailure: { _ in })
        var submittedBytes = 0
        let started = Date()
        for batch in 0..<80 {
            for index in 0..<128 {
                let event = RuntimeEvent(kind: .health, event: "fixture.\(batch * 128 + index)")
                var line = try CanonicalJSON.encoder().encode(event)
                line.append(0x0A)
                submittedBytes += line.count
                writer.append(line)
            }
            guard writer.flush() else { throw Failure(message: "Append fixture did not flush") }
        }
        let data = try Data(contentsOf: url)
        guard writer.statistics.droppedRecords == 0, writer.statistics.failedRecords == 0,
              writer.statistics.writtenRecords == 10_240, file.rotationCount > 0,
              file.bytesWritten <= UInt64(submittedBytes), data.count <= 32_768 else {
            throw Failure(message: "Append amplification, rotation, or bounded file check failed")
        }
        for line in data.split(separator: 0x0A) {
            _ = try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data(line))
        }
        return "PASS: 10240 events encoded/drained in \(Date().timeIntervalSince(started))s; submitted=\(submittedBytes) actualWritten=\(file.bytesWritten) rotations=\(file.rotationCount)"
    }
}
