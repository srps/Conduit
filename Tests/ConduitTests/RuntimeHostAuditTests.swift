// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import NIOCore
import NIOPosix
import XCTest
import ConduitShared
import ProxyControlBridge
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel
import RuntimeEvents

/// The connection audit through the actual host, as the app composes it (#222): off by default; on, a request the host serves is
/// recorded at the configured destination, or the root's `audit.ndjson`, with its query redacted and within the configured bound; and a
/// destination that aliases a protected resource is refused with one fixed event on the actual stream, its bytes kept, while the host
/// keeps serving and stops. Start and Stop go through the framed client. Each request is a loopback one sent to the host's listener;
/// the default no-proxy list routes it DIRECT to an origin this test owns, so no upstream or authentication is involved. The host's own
/// request counts are the witness that it was served.
@MainActor
final class RuntimeHostAuditTests: XCTestCase {
    private var harness: InteractiveHostHarness?
    private var origin: Channel?
    private var external: URL?

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await origin?.close().get()
        origin = nil
        if let external { removeScratch([external]) }
        external = nil
        try await super.tearDown()
    }

    /// The query value every request carries. No audit row may contain it.
    private static let secret = "audit-secret-6f2c"

    private func deadline() -> RuntimeDeadline {
        .after(.seconds(30), from: ContinuousClock.now)
    }

    private struct Composed {
        let host: RuntimeHost
        let environment: RuntimeEnvironment
        let control: any RuntimeClient
    }

    private struct NotStarted: Error {
        let outcome: String
    }

    /// One host over a saved configuration whose logging section `configure` sets, after the root is taken so it can name the root's
    /// files, and the framed client the production factory hands out. The upstream is the closed discard port; no request here uses it.
    private func compose(_ configure: (inout LoggingSection, StateRootSession) throws -> Void) async throws -> Composed {
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.dnsForwarderEnabled = false
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        let harness = try InteractiveHostHarness(config: config, platform: PlatformIntegrationConfig())
        self.harness = harness
        try configure(&config.logging, harness.session)
        try ProxyConfigPersistence.save(config, in: harness.environment)
        let host = try await harness.makeHost()
        let clients = try host.makeInMemoryControlClient(
            limits: try RuntimeServiceFixtures.hostLimits(subscribers: 3),
            clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        return Composed(host: host, environment: harness.environment, control: clients.control)
    }

    /// One command through the framed client and its settlement, nil when it was not admitted or never settled within the bound.
    private func settle(_ composed: Composed, _ command: ControlRuntimeCommand) async throws -> ControlOperationOutcome? {
        let incarnation = try await composed.control.readSnapshot(deadline: deadline()).stamp.incarnation
        let stream = try await composed.control.subscribe(.live, deadline: deadline())
        defer { stream.cancel() }
        _ = try await stream.next(deadline())
        let admission = try await composed.control.submit(
            command, requestID: ControlRequestID(rawValue: UUID()), expectedIncarnation: incarnation, deadline: deadline()
        )
        guard case .accepted(let operation) = admission else { return nil }
        for _ in 0..<64 {
            if case .operationFinished(let finished) = try await stream.next(deadline()), finished.operationID == operation {
                return finished.outcome
            }
        }
        return nil
    }

    /// A saved proxy Start through the framed client; returns the port it bound.
    private func startProxy(_ composed: Composed) async throws -> Int {
        let snapshot = try await composed.control.readSnapshot(deadline: deadline())
        let revision = try XCTUnwrap(snapshot.stamp.modules?.proxy)
        let outcome = try await settle(composed, .start(.proxy, ifModuleRevision: revision))
        guard case .configurationSettled(let receipt)? = outcome,
              receipt.modules == [ControlModuleReceipt(module: .proxy, result: .started)] else {
            throw NotStarted(outcome: String(describing: outcome))
        }
        return try XCTUnwrap(composed.host.status().bindings.proxyPort)
    }

    /// A proxy Stop through the framed client; it must complete and leave no listener.
    private func stopProxy(_ composed: Composed) async throws {
        let outcome = try await settle(composed, .stop(.proxy))
        guard case .completed(let completion)? = outcome else { return XCTFail("the Stop settles: \(String(describing: outcome))") }
        XCTAssertEqual(completion.command, .stop)
        XCTAssertNil(composed.host.status().bindings.proxyPort, "the Stop leaves no listener")
    }

    /// The loopback origin. The test target has no shared HTTP origin (each suite's is file-private), so this is the smallest one: a
    /// complete 200 on a connection's first read.
    private func startOrigin() async throws -> Int {
        let channel = try await ServerBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in channel.pipeline.addHandler(AuditOrigin()) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        origin = channel
        return try XCTUnwrap(channel.localAddress?.port)
    }

    /// Sends one absolute-form GET through the host's listener, its query carrying the secret, and waits until the host has handled and
    /// served `served` requests and closed every connection. The orchestrator hands a connection's row to its sink in the same
    /// main-actor step that closes it, queued after the request's completion, so these counts mean every row was handed over.
    private func request(through proxyPort: Int, origin originPort: Int, host: RuntimeHost, served: Int) async throws {
        let client = try await ClientBootstrap(group: MultiThreadedEventLoopGroup.singleton)
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()
        defer { client.close(promise: nil) }
        let request = "GET http://127.0.0.1:\(originPort)/v1/resource?token=\(Self.secret) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n"
        try await client.writeAndFlush(client.allocator.buffer(string: request)).get()
        var metrics = host.status().metrics
        for _ in 0..<5_000 where !(metrics.requestsHandled >= served && metrics.openConnections == 0) {
            try await Task.sleep(for: .milliseconds(1))
            metrics = host.status().metrics
        }
        XCTAssertEqual(metrics.requestsHandled, served, "the host handled each request")
        XCTAssertEqual(metrics.failedRequests, 0, "the host served each request")
        XCTAssertEqual(metrics.openConnections, 0, "the host closed each connection")
    }

    private func auditRows(at url: URL) throws -> (text: String, rows: [ConnectionAuditRecord]) {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = ConnectionAuditRecord.canonicalDecoder
        return (text, try text.split(separator: "\n").map { try decoder.decode(ConnectionAuditRecord.self, from: Data($0.utf8)) })
    }

    private func defaultAuditFile(_ composed: Composed) -> URL {
        composed.environment.configDirectory.appendingPathComponent("audit.ndjson")
    }

    /// Serves one request through a started host, stops through the client and flushes.
    private func serveOne(_ composed: Composed) async throws -> (originPort: Int, report: DiagnosticFlushReport) {
        let originPort = try await startOrigin()
        let proxyPort = try await startProxy(composed)
        try await request(through: proxyPort, origin: originPort, host: composed.host, served: 1)
        try await stopProxy(composed)
        return (originPort, await composed.host.flushEvents())
    }

    func testAnEnabledAuditRecordsTheServedRequestAtTheDefaultPathWithItsQueryRedacted() async throws {
        let composed = try await compose { logging, _ in logging.auditLogEnabled = true }
        let served = try await serveOne(composed)

        XCTAssertEqual(served.report.audit, .drained)
        XCTAssertEqual(served.report.auditStatistics.writtenRecords, 1)
        let audit = try auditRows(at: defaultAuditFile(composed))
        XCTAssertFalse(audit.text.contains(Self.secret), "no audit row carries the query value")
        XCTAssertEqual(audit.rows.count, 1)
        let row = try XCTUnwrap(audit.rows.first)
        XCTAssertEqual(row.target, "http://127.0.0.1:\(served.originPort)/v1/resource?<redacted>")
        XCTAssertEqual(row.scheme, .http)
        XCTAssertEqual(row.chosenUpstream, "DIRECT")
        XCTAssertEqual(row.outcome, .success)
    }

    /// The orchestrator's connection callbacks through the actual path, under mixed-priority owner load: concurrent connections from
    /// clients at every task priority, while owner jobs at every priority queue beside the callbacks' hops. A close whose hop ran before
    /// its open's would find no row to audit and leave a stale one, so the counts are the order witness: no open connection or row is
    /// left, and every connection has its one audit row. The hops themselves come from the event loop at that thread's priority; what
    /// varies is the priority of everything queued beside them.
    func testConnectionTrackingUnderMixedPriorityLoadKeepsEachOpenBeforeItsClose() async throws {
        let composed = try await compose { logging, _ in logging.auditLogEnabled = true }
        let originPort = try await startOrigin()
        let proxyPort = try await startProxy(composed)
        let connections = 32
        let priorities: [TaskPriority] = [.background, .utility, .medium, .userInitiated, .high]
        let host = composed.host
        let load = (0..<256).map { index in
            Task(priority: priorities[index % priorities.count]) { @MainActor in _ = host.status() }
        }
        let clients = (0..<connections).map { index in
            Task.detached(priority: priorities[index % priorities.count]) {
                try await Self.serveOnItsOwnConnection(proxyPort: proxyPort, originPort: originPort, index: index)
            }
        }
        for client in clients { try await client.value }
        for job in load { await job.value }
        var metrics = host.status().metrics
        for _ in 0..<5_000 where !(metrics.requestsHandled >= connections && metrics.openConnections == 0) {
            try await Task.sleep(for: .milliseconds(1))
            metrics = host.status().metrics
        }
        XCTAssertEqual(metrics.requestsHandled, connections, "the host handled each request")
        XCTAssertEqual(metrics.failedRequests, 0)
        XCTAssertEqual(metrics.openConnections, 0, "no connection is left open")
        XCTAssertEqual(host.orchestrator.snapshot.activeConnections.count, 0, "no stale connection row is left")

        try await stopProxy(composed)
        let report = await host.flushEvents()
        XCTAssertEqual(report.audit, .drained)
        XCTAssertEqual(report.auditStatistics.writtenRecords, UInt64(connections), "every close found its open's row")
        let rows = try auditRows(at: defaultAuditFile(composed)).rows
        XCTAssertEqual(Set(rows.map(\.id)).count, connections, "one row for each connection")
    }

    /// One request on a connection of its own, from whichever task calls it. The client closes the connection once the response's first
    /// bytes arrive, or after ten seconds, and the host's counts then say what was missing.
    private nonisolated static func serveOnItsOwnConnection(proxyPort: Int, originPort: Int, index: Int) async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let answered = group.next().makePromise(of: Void.self)
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in channel.pipeline.addHandler(FirstReadSignal(answered)) }
            .connect(host: "127.0.0.1", port: proxyPort)
            .get()
        let request = "GET http://127.0.0.1:\(originPort)/v1/item/\(index) HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(originPort)\r\nConnection: close\r\n\r\n"
        try await client.writeAndFlush(client.allocator.buffer(string: request)).get()
        let timeout = answered.futureResult.eventLoop.scheduleTask(in: .seconds(10)) { answered.succeed(()) }
        try await answered.futureResult.get()
        timeout.cancel()
        try? await client.close()
    }

    func testADisabledAuditWritesNothing() async throws {
        let composed = try await compose { logging, _ in logging.auditLogEnabled = false }
        let served = try await serveOne(composed)

        XCTAssertEqual(served.report.auditStatistics, RecordWriterStatistics())
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultAuditFile(composed).path))
    }

    func testAnExplicitPathOutsideTheRootIsWrittenInsteadOfTheDefault() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("pm-audit-external-\(UUID().uuidString)", isDirectory: true)
        external = directory
        let destination = directory.appendingPathComponent("compliance.ndjson")
        let composed = try await compose { logging, _ in
            logging.auditLogEnabled = true
            logging.auditLogPath = destination.path
        }
        let served = try await serveOne(composed)

        XCTAssertEqual(served.report.auditStatistics.writtenRecords, 1)
        let audit = try auditRows(at: destination)
        XCTAssertEqual(audit.rows.map(\.target), ["http://127.0.0.1:\(served.originPort)/v1/resource?<redacted>"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultAuditFile(composed).path), "the default path is not written")
    }

    /// A configured bound below one row's size skips the row rather than writing part of it, so the bound reached the writer.
    func testTheConfiguredBoundReachesTheWriter() async throws {
        let composed = try await compose { logging, _ in
            logging.auditLogEnabled = true
            logging.auditLogMaxBytes = 64
        }
        let served = try await serveOne(composed)

        XCTAssertEqual(served.report.auditStatistics.writtenRecords, 0)
        XCTAssertEqual(served.report.auditStatistics.droppedRecords, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: defaultAuditFile(composed).path))
    }

    func testAPathAliasingTheWriterLeaseIsRefusedAndTheHostKeepsServing() async throws {
        try await assertRefusedAlias(detail: "sink=audit reason=protected_identity resource=writer_lease") { session, alias in
            XCTAssertEqual(link(session.writerLeaseFile.path, alias.path), 0)
            return session.writerLeaseFile
        }
    }

    func testAPathAliasingTheConfigIsRefusedAndTheHostKeepsServing() async throws {
        try await assertRefusedAlias(detail: "sink=audit reason=protected_path resource=config") { session, alias in
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: session.environment.configFile)
            return session.environment.configFile
        }
    }

    func testAPathAliasingThePlatformSidecarIsRefusedAndTheHostKeepsServing() async throws {
        try await assertRefusedAlias(detail: "sink=audit reason=protected_path resource=platform_config") { session, alias in
            try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: session.environment.platformConfigFile)
            return session.environment.platformConfigFile
        }
    }

    /// The audit path is an alias `makeAlias` creates in the root, of the protected file it returns. The first row is refused, with one
    /// fixed event on the actual stream and in the events file; the protected file keeps its bytes and inode; the next request is still
    /// served, its row counted as a drop; and the Stop through the client completes.
    private func assertRefusedAlias(
        detail: String,
        _ makeAlias: (StateRootSession, URL) throws -> URL
    ) async throws {
        var protected: URL?
        let composed = try await compose { logging, session in
            let alias = session.environment.configDirectory.appendingPathComponent("audit-alias.ndjson")
            protected = try makeAlias(session, alias)
            logging.auditLogEnabled = true
            logging.auditLogPath = alias.path
        }
        let protectedFile = try XCTUnwrap(protected)
        let originPort = try await startOrigin()
        let proxyPort = try await startProxy(composed)
        // Taken after the Start's own commit, so only the audit writer could change it from here.
        let before = try writerLeaseFingerprint(protectedFile)
        let witness = try await composed.control.subscribe(.live, deadline: deadline())
        defer { witness.cancel() }
        guard case .baseline = try await witness.next(deadline()) else { return XCTFail("the witness stream opens with its baseline") }

        try await request(through: proxyPort, origin: originPort, host: composed.host, served: 1)
        var streamed: [String] = []
        for _ in 0..<256 where streamed.isEmpty {
            guard case .events(let batch) = try await witness.next(.after(.seconds(10), from: ContinuousClock.now)) else { continue }
            for case .known(let event) in batch.events where event.event == RecordFileDestinationGate.eventName {
                streamed.append(event.detail ?? "")
            }
        }
        XCTAssertEqual(streamed, [detail], "the refusal reaches the actual stream with fixed codes only")

        try await request(through: proxyPort, origin: originPort, host: composed.host, served: 2)
        let report = await composed.host.flushEvents()
        XCTAssertEqual(try writerLeaseFingerprint(protectedFile), before, "the refused writer left the protected file as it was")
        XCTAssertEqual(report.audit, .drained)
        XCTAssertEqual(report.auditStatistics.writtenRecords, 0)
        XCTAssertEqual(report.auditStatistics.failedRecords, 1, "the first row is the refused one")
        XCTAssertEqual(report.auditStatistics.droppedRecords, 1, "a row after the refusal is dropped, never written")
        let decoder = CanonicalJSON.decoder()
        let written = try String(contentsOf: composed.environment.eventsFile, encoding: .utf8).split(separator: "\n")
            .map { try decoder.decode(RuntimeEvent.self, from: Data($0.utf8)) }
            .filter { $0.event == RecordFileDestinationGate.eventName }
        XCTAssertEqual(written.map(\.detail), [detail], "the events file records the one refusal")

        try await stopProxy(composed)
    }
}

/// Completes its promise at a connection's first read: the response has begun to arrive.
private final class FirstReadSignal: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let read: EventLoopPromise<Void>

    init(_ read: EventLoopPromise<Void>) {
        self.read = read
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        read.succeed(())
    }

    func channelInactive(context: ChannelHandlerContext) {
        read.succeed(())
        context.fireChannelInactive()
    }
}

/// Answers a connection's first read with a complete 200. Each connection carries one bodiless request, and a response may precede the
/// rest of its request, so the first read is enough.
private final class AuditOrigin: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private var answered = false

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard !answered else { return }
        answered = true
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        context.writeAndFlush(NIOAny(context.channel.allocator.buffer(string: response)), promise: nil)
    }
}
