// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// Locks in the contract of the connection audit log (`audit.ndjson`).
/// Two layers:
///
///   * `ConnectionAuditRecord` — the value type written one-per-line. Field
///     names are wire-stable; renames break log pipelines.
///   * `FileConnectionAuditSink` — bounded NDJSON writer with rotation.
///     The bound discipline mirrors `RuntimeEventLog`: when the file
///     reaches `maxBytes`, the existing file is renamed to `.1`
///     (overwriting the previous `.1` if any) and a fresh file is opened.
///     This guarantees disk usage stays within `2 × maxBytes` and the
///     most recent records are always present.
///
/// The sink is the compliance / forensics surface for enterprise users:
/// "what sites went through which upstream with which auth, when?"
/// is answerable from the file alone, even when the daemon isn't running.
/// Because the file may live on a shared disk and may be shipped to
/// enterprise observability systems, credentials MUST be masked at
/// record-emit time — there is no second chance to scrub them.
final class ConnectionAuditRecordTests: XCTestCase {

    // MARK: - Wire stability

    func testRecordCodableRoundTrip() throws {
        let record = ConnectionAuditRecord(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000),
            clientAddress: "127.0.0.1",
            scheme: .https,
            target: "github.com:443",
            pacDecision: "PROXY proxy.corp:8080",
            chosenUpstream: "Corp@proxy.corp:8080",
            authMethod: "Negotiate",
            bytesSent: 1234,
            bytesReceived: 56789,
            durationMS: 42,
            outcome: .success
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)

        let json = String(data: data, encoding: .utf8) ?? ""
        // Pin the wire field names; any rename here is a breaking change to
        // log-consuming pipelines (Splunk dashboards, pmctl, etc.).
        XCTAssertTrue(json.contains("\"id\""))
        XCTAssertTrue(json.contains("\"timestamp\""))
        XCTAssertTrue(json.contains("\"clientAddress\""))
        XCTAssertTrue(json.contains("\"scheme\""))
        XCTAssertTrue(json.contains("\"target\""))
        XCTAssertTrue(json.contains("\"pacDecision\""))
        XCTAssertTrue(json.contains("\"chosenUpstream\""))
        XCTAssertTrue(json.contains("\"authMethod\""))
        XCTAssertTrue(json.contains("\"bytesSent\""))
        XCTAssertTrue(json.contains("\"bytesReceived\""))
        XCTAssertTrue(json.contains("\"durationMS\""))
        XCTAssertTrue(json.contains("\"outcome\""))

        let decoded = try JSONDecoder().decode(ConnectionAuditRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }

    func testFailureOutcomeCarriesReason() throws {
        let record = ConnectionAuditRecord(
            id: UUID(),
            timestamp: Date(),
            clientAddress: "10.0.0.5",
            scheme: .http,
            target: "internal.example.com:80",
            pacDecision: nil,
            chosenUpstream: nil,
            authMethod: nil,
            bytesSent: 0,
            bytesReceived: 0,
            durationMS: 1500,
            outcome: .failure(reason: "connect refused")
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let data = try encoder.encode(record)
        let decoded = try JSONDecoder().decode(ConnectionAuditRecord.self, from: data)
        XCTAssertEqual(decoded.outcome, .failure(reason: "connect refused"))
    }

    // MARK: - Optional fields and minimal records

    func testRecordWithOnlyMandatoryFieldsRoundTrips() throws {
        let record = ConnectionAuditRecord(
            id: UUID(),
            timestamp: Date(),
            clientAddress: nil,
            scheme: .connect,
            target: "tls.example:443",
            pacDecision: nil,
            chosenUpstream: nil,
            authMethod: nil,
            bytesSent: 0,
            bytesReceived: 0,
            durationMS: 0,
            outcome: .success
        )

        let data = try JSONEncoder().encode(record)
        let decoded = try JSONDecoder().decode(ConnectionAuditRecord.self, from: data)
        XCTAssertEqual(decoded, record)
    }
}

final class FileConnectionAuditSinkTests: XCTestCase {

    private var tempDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("audit-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - Basic write semantics

    func testRecordsAreAppendedAsNDJSON() throws {
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 1_000_000, logger: DiscardingLogSink())

        let r1 = sampleRecord(target: "a.example:443")
        let r2 = sampleRecord(target: "b.example:443")
        sink.record(r1)
        sink.record(r2)
        sink.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 2, "Each record is one line of NDJSON")

        let decoded = try lines.map { line in
            try ConnectionAuditRecord.canonicalDecoder.decode(ConnectionAuditRecord.self, from: Data(line.utf8))
        }
        XCTAssertEqual(decoded[0].target, "a.example:443")
        XCTAssertEqual(decoded[1].target, "b.example:443")
    }

    func testEachRecordIsExactlyOneLine() throws {
        // Defensive: even a record carrying a target with embedded newlines
        // must serialize to exactly one line. JSON encoders escape control
        // characters by default; this test pins the assumption so a future
        // encoder swap that drops escaping is caught.
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 1_000_000, logger: DiscardingLogSink())

        let weird = sampleRecord(target: "host\nwith\nnewlines:443")
        sink.record(weird)
        sink.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, 1, "Embedded newlines must not split the record across NDJSON lines")
    }

    // MARK: - Trim / size cap

    func testFileSizeStaysWithinMaxBytes() throws {
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        // Each sample record serializes to ~280 bytes after newline.
        // Cap at 600 — file should never exceed that even after many
        // writes.
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 600, logger: DiscardingLogSink())
        for i in 0..<20 {
            sink.record(sampleRecord(target: "host-\(i):443"))
        }
        sink.flush()
        let size = try fileSize(at: url.path)
        XCTAssertLessThanOrEqual(size, 600, "Post-trim file must respect maxBytes (got \(size))")
    }

    func testTrimPreservesMostRecentRecords() throws {
        // The trim drops the OLDEST records; the newest ones survive.
        // Compliance auditors care about the most recent activity, not
        // the first-ever record from process boot, so this is the right
        // direction.
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 600, logger: DiscardingLogSink())
        for i in 0..<20 {
            sink.record(sampleRecord(target: "host-\(i):443"))
        }
        sink.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("host-19:443"),
                      "Most recent record must survive trim")
        XCTAssertFalse(contents.contains("host-0:443"),
                       "Oldest records must be dropped to stay under maxBytes")
    }

    func testTrimAlignsToNewlineBoundary() throws {
        // After trim, the file must START with a complete record — no
        // partial leading line. Decoding all lines proves no JSON parse
        // errors from a half-truncated record.
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 800, logger: DiscardingLogSink())
        for i in 0..<20 {
            sink.record(sampleRecord(target: "host-\(i):443"))
        }
        sink.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertFalse(lines.isEmpty, "Trim must leave at least one record")
        for line in lines {
            XCTAssertNoThrow(
                try ConnectionAuditRecord.canonicalDecoder.decode(
                    ConnectionAuditRecord.self,
                    from: Data(line.utf8)
                ),
                "Trim left a partial record: \(line)"
            )
        }
    }

    func testRecordsAreFlushedSynchronouslyOnFlush() throws {
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 1_000_000, logger: DiscardingLogSink())
        sink.record(sampleRecord(target: "sync.example:443"))
        sink.flush()
        let contents = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(contents.contains("sync.example:443"),
                      "After flush() the record must be visible on disk")
    }

    // MARK: - Concurrency

    func testConcurrentWritesProduceIntactRecords() throws {
        // Multiple writers can fire from different NIO event loops at the
        // same time. The sink must serialize internally so each line of
        // NDJSON is intact (no interleaved bytes mid-record).
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 5_000_000, logger: DiscardingLogSink())

        let writeCount = 100
        let group = DispatchGroup()
        for i in 0..<writeCount {
            group.enter()
            DispatchQueue.global().async {
                sink.record(self.sampleRecord(target: "concurrent-\(i):443"))
                group.leave()
            }
        }
        group.wait()
        sink.flush()

        let contents = try String(contentsOf: url, encoding: .utf8)
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: true)
        XCTAssertEqual(lines.count, writeCount)
        for line in lines {
            XCTAssertNoThrow(
                try ConnectionAuditRecord.canonicalDecoder.decode(
                    ConnectionAuditRecord.self,
                    from: Data(line.utf8)
                ),
                "Concurrent write produced torn JSON: \(line)"
            )
        }
    }

    // MARK: - Lazy creation

    func testParentDirectoryIsCreatedOnFirstRecord() throws {
        // The sink is often pointed at `$state-dir/audit.ndjson` where
        // the state-dir exists but the audit subdirectory might not.
        // Mirrors `RuntimeEventFileWriter.append` discipline.
        let url = tempDirectory
            .appendingPathComponent("nested")
            .appendingPathComponent("subdir")
            .appendingPathComponent("audit.ndjson")
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 1_000_000, logger: DiscardingLogSink())
        sink.record(sampleRecord(target: "lazy.example:443"))
        sink.flush()
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "Parent directory + file must be created lazily on first record")
    }

    func testOversizedRecordIsDroppedWithWarning() throws {
        // A single record larger than the entire cap is suspicious; the
        // sink drops it with a warning rather than truncating the cap to
        // a single record.
        let url = tempDirectory.appendingPathComponent("audit.ndjson")
        let logger = RecordingLogSink(minLevel: .debug)
        let sink = FileConnectionAuditSink(fileURL: url, maxBytes: 100, logger: logger)
        sink.record(sampleRecord(target: "this.target.is.long.enough.to.exceed.the.tiny.cap:443"))
        sink.flush()
        let warnings = logger.entries().filter { $0.level == .warning }
        XCTAssertFalse(warnings.isEmpty, "Oversized record must surface a warning via the LogSink")
    }

    // MARK: - Helpers

    private func sampleRecord(target: String) -> ConnectionAuditRecord {
        ConnectionAuditRecord(
            id: UUID(),
            timestamp: Date(),
            clientAddress: "127.0.0.1",
            scheme: .https,
            target: target,
            pacDecision: nil,
            chosenUpstream: "TestUpstream@proxy:8080",
            authMethod: "Negotiate",
            bytesSent: 1024,
            bytesReceived: 4096,
            durationMS: 12,
            outcome: .success
        )
    }

    private func fileSize(at path: String) throws -> Int {
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        return (attrs[.size] as? Int) ?? 0
    }
}

final class RecordingConnectionAuditSinkTests: XCTestCase {

    func testRecordsAreCapturedInOrder() {
        let sink = RecordingConnectionAuditSink()
        let r1 = makeRecord(target: "a:443")
        let r2 = makeRecord(target: "b:443")
        sink.record(r1)
        sink.record(r2)

        let captured = sink.records()
        XCTAssertEqual(captured.count, 2)
        XCTAssertEqual(captured[0].target, "a:443")
        XCTAssertEqual(captured[1].target, "b:443")
    }

    func testRecordsAreThreadSafe() {
        let sink = RecordingConnectionAuditSink()
        let count = 200
        let group = DispatchGroup()
        for i in 0..<count {
            group.enter()
            DispatchQueue.global().async {
                // Build the record inline (don't capture `self` through a
                // helper) to keep the closure `@Sendable`-clean.
                sink.record(ConnectionAuditRecord(
                    id: UUID(),
                    timestamp: Date(),
                    clientAddress: nil,
                    scheme: .connect,
                    target: "host-\(i):443",
                    pacDecision: nil,
                    chosenUpstream: nil,
                    authMethod: nil,
                    bytesSent: 0,
                    bytesReceived: 0,
                    durationMS: 0,
                    outcome: .success
                ))
                group.leave()
            }
        }
        group.wait()
        XCTAssertEqual(sink.records().count, count, "All concurrent records must be captured")
    }

    private func makeRecord(target: String) -> ConnectionAuditRecord {
        ConnectionAuditRecord(
            id: UUID(),
            timestamp: Date(),
            clientAddress: nil,
            scheme: .connect,
            target: target,
            pacDecision: nil,
            chosenUpstream: nil,
            authMethod: nil,
            bytesSent: 0,
            bytesReceived: 0,
            durationMS: 0,
            outcome: .success
        )
    }
}

final class DiscardingConnectionAuditSinkTests: XCTestCase {

    func testDiscardingSinkSilentlyAcceptsRecords() {
        let sink = DiscardingConnectionAuditSink()
        // No assertions — the test passes if no crash, no error.
        // The sink exists so the kernel can take `any ConnectionAuditSink`
        // unconditionally and headless / disabled paths inject this no-op.
        sink.record(ConnectionAuditRecord(
            id: UUID(),
            timestamp: Date(),
            clientAddress: nil,
            scheme: .http,
            target: "discarded:80",
            pacDecision: nil,
            chosenUpstream: nil,
            authMethod: nil,
            bytesSent: 0,
            bytesReceived: 0,
            durationMS: 0,
            outcome: .success
        ))
    }
}

/// Integration-shaped test: confirms `ProxyOrchestrator` emits one
/// `ConnectionAuditRecord` per `onConnectionClosed` callback. We don't
/// stand up the full proxy pipeline here — the wire-level part is
/// covered by the `OrchestratorScenarios` / `pm-sim` family. Instead we
/// drive the snapshot's `activeConnections` store directly to
/// reproduce the "open then close" lifecycle the wire-level paths
/// produce, and assert the orchestrator's audit funnel found the
/// closing connection's metadata and produced a faithful record.
@MainActor
final class ProxyOrchestratorAuditEmissionTests: XCTestCase {

    func testConnectionCloseEmitsAuditRecord() async throws {
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )

        let id = UUID()
        let info = ActiveConnectionInfo(
            id: id,
            destination: "github.com:443",
            upstream: "Corp@proxy.corp:8080",
            method: "CONNECT",
            startedAt: Date().addingTimeInterval(-5),
            lastActivityAt: Date(),
            bytesSent: 4096,
            bytesReceived: 16384,
            tunnel: true,
            authMethod: "Negotiate"
        )
        // Pass info: directly so the emission path doesn't need to look
        // up the snapshot (the snapshot setter is private).
        orchestrator.recordConnectionCloseForAudit(id: id, info: info)

        let records = auditSink.records()
        XCTAssertEqual(records.count, 1, "Exactly one audit record must be emitted per closing connection")
        let r = try XCTUnwrap(records.first)
        XCTAssertEqual(r.id, id)
        XCTAssertEqual(r.target, "github.com:443")
        XCTAssertEqual(r.chosenUpstream, "Corp@proxy.corp:8080")
        XCTAssertEqual(r.scheme, .connect, "CONNECT method must surface as scheme=.connect")
        XCTAssertEqual(r.authMethod, "Negotiate")
        XCTAssertEqual(r.bytesSent, 4096)
        XCTAssertEqual(r.bytesReceived, 16384)
        XCTAssertGreaterThanOrEqual(r.durationMS, 5_000 - 1_000,
                                    "Duration should be ~5 s (lastActivityAt - startedAt)")
        XCTAssertEqual(r.outcome, .success)
    }

    func testCloseForUnknownConnectionEmitsNoRecord() {
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )
        // Close an ID that was never opened, no info supplied — the
        // production path is "look up in snapshot, missing → silent no-op".
        orchestrator.recordConnectionCloseForAudit(id: UUID())
        XCTAssertTrue(auditSink.records().isEmpty,
                      "Unknown-ID close must not synthesize a placeholder audit record")
    }

    func testAuditUsesPerConnectionAuthMethodNotGlobalLastOutcome() async throws {
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )
        let id = UUID()
        let info = ActiveConnectionInfo(
            id: id,
            destination: "kerberos.example:443",
            upstream: "Corp@proxy.corp:8080",
            method: "CONNECT",
            tunnel: true,
            authMethod: "Negotiate"
        )

        // Simulate a later, unrelated connection changing the global UI chip
        // to NTLM fallback before this Kerberos connection closes. The audit
        // record must still use the closing connection's own auth method.
        orchestrator.reportAuthOutcome(.ntlmFallback, host: "other-proxy.example:8080", reason: "test")
        try await Task.sleep(for: .milliseconds(50))
        orchestrator.recordConnectionCloseForAudit(id: id, info: info)

        XCTAssertEqual(auditSink.records().first?.authMethod, "Negotiate")
    }

    func testHTTPSPortSurfacesAsHTTPSScheme() {
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )
        let id = UUID()
        let info = ActiveConnectionInfo(
            id: id,
            destination: "api.example.com:443",
            upstream: "DIRECT",
            method: "GET",
            bytesSent: 256,
            bytesReceived: 1024,
            tunnel: false
        )
        orchestrator.recordConnectionCloseForAudit(id: id, info: info)
        XCTAssertEqual(auditSink.records().first?.scheme, .https,
                       "HTTPS-port destination on a non-tunnel connection should surface as scheme=.https")
    }

    func testSchemeDetectionUsesPortSuffixNotSubstring() {
        // `info.destination.contains(":443")`
        // misclassified `:4431` as HTTPS and missed `:8443` as HTTP.
        // The fix uses `hasSuffix(":443")`. Pin the corner cases here.
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )

        // Port 4431 must NOT be HTTPS (substring trap).
        let port4431 = ActiveConnectionInfo(
            id: UUID(),
            destination: "internal-api.example:4431",
            upstream: "DIRECT",
            method: "GET",
            tunnel: false
        )
        orchestrator.recordConnectionCloseForAudit(id: port4431.id, info: port4431)

        // Port 8443 (alternate HTTPS) — the heuristic only knows port 443
        // is the standard. 8443 falls through to .http, which is honest:
        // the audit record reports the wire-observable port, not the
        // application-layer protocol the operator hopes is running.
        let port8443 = ActiveConnectionInfo(
            id: UUID(),
            destination: "alt-https.example:8443",
            upstream: "DIRECT",
            method: "GET",
            tunnel: false
        )
        orchestrator.recordConnectionCloseForAudit(id: port8443.id, info: port8443)

        // Port 443 (standard HTTPS) — must be detected.
        let port443 = ActiveConnectionInfo(
            id: UUID(),
            destination: "api.example:443",
            upstream: "DIRECT",
            method: "GET",
            tunnel: false
        )
        orchestrator.recordConnectionCloseForAudit(id: port443.id, info: port443)

        let records = auditSink.records()
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        XCTAssertEqual(byID[port4431.id]?.scheme, .http,
                       ":4431 must NOT be misclassified as HTTPS (substring trap)")
        XCTAssertEqual(byID[port8443.id]?.scheme, .http,
                       ":8443 falls through to .http; the heuristic only knows the standard port")
        XCTAssertEqual(byID[port443.id]?.scheme, .https,
                       ":443 (standard) must surface as HTTPS")
    }

    func testPlainHTTPMethodSurfacesAsHTTPScheme() {
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )
        let id = UUID()
        let info = ActiveConnectionInfo(
            id: id,
            destination: "intranet.example:80",
            upstream: "Corp@proxy.corp:8080",
            method: "GET",
            bytesSent: 256,
            bytesReceived: 1024,
            tunnel: false
        )
        orchestrator.recordConnectionCloseForAudit(id: id, info: info)
        XCTAssertEqual(auditSink.records().first?.scheme, .http)
    }

    func testSOCKS5MethodClassifiedAsSOCKS5Scheme() {
        let auditSink = RecordingConnectionAuditSink()
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink(),
            auditSink: auditSink
        )
        let id = UUID()
        let info = ActiveConnectionInfo(
            id: id,
            destination: "remote.host:22",
            upstream: "SOCKS5",
            method: "SOCKS5",
            bytesSent: 512,
            bytesReceived: 2048,
            tunnel: true
        )
        orchestrator.recordConnectionCloseForAudit(id: id, info: info)
        XCTAssertEqual(auditSink.records().first?.scheme, .socks5,
                       "SOCKS5 method must surface as scheme=.socks5, not .connect")
    }

    func testDefaultAuditSinkIsDiscarding() {
        // No `auditSink:` in init → DiscardingConnectionAuditSink → no
        // crash, no records produced (proven by simply not blowing up).
        let orchestrator = ProxyOrchestrator(
            config: ProxyConfig.testFixture(),
            logger: DiscardingLogSink()
        )
        let id = UUID()
        let info = ActiveConnectionInfo(
            id: id,
            destination: "anywhere:443",
            upstream: "DIRECT",
            method: "GET"
        )
        orchestrator.recordConnectionCloseForAudit(id: id, info: info)
        // Pass = no fatal error. The discarding sink swallows the call.
    }
}

