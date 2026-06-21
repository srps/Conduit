// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class AuditRegressionTests: XCTestCase {
    func testGatewayMetadataBlocklistUsesEffectiveHostForOriginFormRequests() throws {
        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "169.254.169.254")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/latest/meta-data/", headers: headers)

        let target = try XCTUnwrap(HTTPRequestTarget.parse(head))
        XCTAssertTrue(MetadataBlocklist.isBlocked(host: target.host, gatewayMode: true))
    }

    func testLogSanitizerRedactsURIUserInfo() {
        let line = "DIRECT HTTP GET http://user:secret@example.com/private"

        XCTAssertFalse(SensitiveValueSanitizer.sanitize(line).contains("user:secret@"))
    }

    func testAuditTargetRedactsQueryStringSecrets() {
        let target = "http://api.example.com/v1/resource?access_token=s3cr3t&api_key=abc123"
        let sanitized = SensitiveValueSanitizer.auditTarget(target)

        XCTAssertFalse(sanitized.contains("s3cr3t"))
        XCTAssertFalse(sanitized.contains("abc123"))
        XCTAssertFalse(sanitized.contains("access_token"))
        // Host + path are preserved so the audit row is still useful.
        XCTAssertTrue(sanitized.contains("api.example.com/v1/resource"))
        XCTAssertTrue(sanitized.contains("<redacted>"))
    }

    func testAuditTargetLeavesHostPortTargetsUntouched() {
        // CONNECT / SOCKS5 targets are `host:port`, with no query to redact.
        XCTAssertEqual(SensitiveValueSanitizer.auditTarget("example.com:443"), "example.com:443")
        XCTAssertEqual(SensitiveValueSanitizer.auditTarget("10.0.0.5:8080"), "10.0.0.5:8080")
    }

    func testAuditTargetRedactsOriginFormQuerySecrets() {
        // Origin-form request target (host travels in the Host header, so the
        // target has no scheme): the query must still be redacted.
        let sanitized = SensitiveValueSanitizer.auditTarget("/v1/resource?token=s3cr3t")

        XCTAssertFalse(sanitized.contains("s3cr3t"))
        XCTAssertFalse(sanitized.contains("token="))
        XCTAssertTrue(sanitized.hasPrefix("/v1/resource?<redacted>"))
    }

    func testPACRouteCacheKeepsPathSensitiveDecisionsSeparate() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://pac.example/proxy.pac"
        config.pacRoutingEnabled = true
        let evaluator = PathSensitivePacScriptEvaluator()
        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: AuditPacEvaluator(scriptEvaluator: evaluator),
            refreshInterval: 300,
            pacLoader: { _ in "function FindProxyForURL() { return \"DIRECT\"; }" }
        )
        try await engine.refresh(force: true)

        _ = engine.route(for: "https://example.com/public", host: "example.com")

        XCTAssertEqual(engine.route(for: "https://example.com/admin", host: "example.com"), .proxy(host: "corp.example", port: 8080))
    }

    func testDirectDNSSynthesisRejectsZeroQuestionCount() {
        let validQuery = DNSWireFormat.buildQuery(domain: "managed.internal", txID: 0x1234, qtype: 1)
        var malformed = Array(validQuery[0..<12])
        malformed[4] = 0x00
        malformed[5] = 0x00
        malformed.append(contentsOf: validQuery.dropFirst(12))

        XCTAssertNil(DNSWireFormat.synthesizeDirectResponse(originalQuery: malformed, ip: "127.0.0.1"))
    }

    func testPACRefreshLogsRedactQuerySecrets() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://pac.example/proxy.pac?token=s3cr3t"
        config.pacRoutingEnabled = true
        let logger = RecordingLogSink(minLevel: .debug)
        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: AuditPacEvaluator(scriptEvaluator: DirectAuditPacScriptEvaluator()),
            logger: logger,
            refreshInterval: 300,
            pacLoader: { _ in "function FindProxyForURL() { return \"DIRECT\"; }" }
        )

        try await engine.refresh(force: true)
        let messages = logger.entries().map(\.message).joined(separator: "\n")

        XCTAssertFalse(messages.contains("token=s3cr3t"))
    }

    func testWildcardProxyBindRequiresGatewayFiltering() {
        var config = ProxyConfig.testFixture()
        config.localHost = "0.0.0.0"
        config.gatewayMode = false

        XCTAssertFalse(config.validate().isEmpty)
    }

    func testStalledConnectionCleanupIgnoresInUseConnections() throws {
        let channel = EmbeddedChannel()
        let connection = PooledUpstreamConnection.makeForTesting(
            proxy: UpstreamProxy(name: "proxy", host: "127.0.0.1", port: 8080, priority: 0),
            channel: channel,
            inUse: true,
            isDedicatedTunnel: false,
            authenticated: true
        )
        connection.lastUsedAt = Date().addingTimeInterval(-120)

        XCTAssertFalse(ConnectionPool.stalledConnectionIDs(from: [connection], olderThan: 45).contains(connection.id))
        try? channel.close().wait()
    }

    func testUpstreamRequestStripsConnectionNamedHopByHopHeaders() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let capturedRequest = group.next().makePromise(of: String.self)
        let proxy = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawHTTPRequestCaptureHandler(promise: capturedRequest))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { proxy.close(promise: nil) }

        var config = ProxyConfig.testFixture()
        config.upstreams = [UpstreamProxy(name: "capture", host: "127.0.0.1", port: proxy.localAddress!.port!, priority: 0)]
        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in AuditStaticAuthenticator() }
        )
        defer { pool.closeAll() }

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "Connection", value: "X-Hop")
        headers.add(name: "X-Hop", value: "should-not-forward")
        let head = HTTPRequestHead(version: .http1_1, method: .GET, uri: "/resource", headers: headers)

        _ = try await pool.exchange(head: head, body: nil).get()
        let rawRequest = try await capturedRequest.futureResult.get()

        XCTAssertFalse(rawRequest.contains("\r\nX-Hop: should-not-forward\r\n"))
    }

    func testDirectHTTPResponseForwarderStripsConnectionNamedHopByHopHeaders() throws {
        let loop = EmbeddedEventLoop()
        let clientChannel = EmbeddedChannel(loop: loop)
        try clientChannel.pipeline.syncOperations.addHandler(HTTPResponseEncoder())
        let forwarder = DirectHTTPResponseForwarder(clientChannel: clientChannel, onComplete: {}, onError: { _ in })
        let upstreamChannel = EmbeddedChannel(handlers: [forwarder], loop: loop)
        var headers = HTTPHeaders()
        headers.add(name: "Connection", value: "X-Hop")
        headers.add(name: "X-Hop", value: "direct-hop")

        try upstreamChannel.writeInbound(HTTPClientResponsePart.head(HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)))
        try upstreamChannel.writeInbound(HTTPClientResponsePart.end(nil))

        var raw = ""
        while var out: ByteBuffer = try clientChannel.readOutbound() {
            raw += out.readString(length: out.readableBytes) ?? ""
        }

        XCTAssertFalse(raw.contains("\r\nX-Hop: direct-hop\r\n"))

        try? clientChannel.close().wait()
        try? upstreamChannel.close().wait()
    }

    func testSOCKS5GreetingRejectsNoAuthWhenClientDidNotOfferIt() async throws {
        let server = try await startSOCKS5Server(directMode: false)
        defer { Task { await server.stop() } }

        let response = try await socksExchange(
            port: server.listeningPort!,
            writes: [[0x05, 0x01, 0x02]],
            expectedResponseCount: 1
        ).first ?? []

        XCTAssertEqual(Array(response.prefix(2)), [0x05, 0xFF])
    }

    func testSOCKS5RoutingRejectsPipelinedPayloadBeforeConnectReply() async throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://pac.example/proxy.pac"
        config.pacRoutingEnabled = true
        config.upstreams = []
        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: AuditPacEvaluator(scriptEvaluator: DirectAuditPacScriptEvaluator()),
            refreshInterval: 300,
            pacLoader: { _ in "function FindProxyForURL() { return \"DIRECT\"; }" }
        )
        try await engine.refresh(force: true)
        let server = try await startSOCKS5Server(directMode: false, config: config, pacRoutingEngine: engine)
        defer { Task { await server.stop() } }

        let host = Array("example.com".utf8)
        let pipelinedPayload = Array(repeating: UInt8(0x41), count: 1024)
        let bytes = [0x05, 0x01, 0x00] +
            [0x05, 0x01, 0x00, 0x03, UInt8(host.count)] +
            host +
            [0x01, 0xbb] +
            pipelinedPayload

        let responses = try await socksExchangeUntilClose(port: server.listeningPort!, writes: [bytes])
        let flattened = responses.flatMap { $0 }

        XCTAssertEqual(Array(flattened.prefix(2)), [0x05, 0x00])
        XCTAssertFalse(flattened.dropFirst(2).starts(with: [0x05, 0x00]), "SOCKS5 must not accept optimistic payload before routing/connect completes")
    }

    func testAsyncPACPathSpoolsBodyBeyondMemoryLimit() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let capturedBody = group.next().makePromise(of: String.self)
        let origin = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(RawHTTPBodyCaptureHandler(promise: capturedBody))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { origin.close(promise: nil) }
        let originPort = try XCTUnwrap(origin.localAddress?.port)

        var config = ProxyConfig.testFixture()
        config.localPort = 0
        config.socksEnabled = false
        config.pacURL = "https://pac.example/proxy.pac"
        config.pacRoutingEnabled = true
        config.upstreams = []
        config.noProxyHosts = []
        config.forceProxyHosts = []
        config.maxBufferedBodyBytes = 1
        config.maxSpooledBodyBytes = 16

        let engine = PACRoutingEngine(
            configProvider: { config },
            resolver: AuditPacEvaluator(scriptEvaluator: SlowDirectAuditPacScriptEvaluator(delay: 0.15)),
            refreshInterval: 300,
            pacLoader: { _ in "function FindProxyForURL() { return \"DIRECT\"; }" }
        )
        try await engine.refresh(force: true)

        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in AuditStaticAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: group, logger: DiscardingLogSink()),
            pacRoutingEngine: engine,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let port = try XCTUnwrap(server.listeningPort)
        let response = try await rawHTTPExchange(
            port: port,
            request:
                "POST http://127.0.0.1:\(originPort)/upload HTTP/1.1\r\n" +
                "Host: 127.0.0.1:\(originPort)\r\n" +
                "Content-Length: 2\r\n" +
                "\r\n" +
                "ab"
        )

        XCTAssertTrue(response.contains("200 OK"), "Spooled body should forward successfully after async PAC routing")
        let body = try await capturedBody.futureResult.get()
        XCTAssertEqual(body, "ab")
    }

    func testRequestBodyAboveSpoolLimitIsRejected() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        var config = ProxyConfig.testFixture()
        config.localPort = 0
        config.socksEnabled = false
        config.upstreams = []
        config.maxBufferedBodyBytes = 1
        config.maxSpooledBodyBytes = 1

        let server = LocalProxyServer(
            logger: DiscardingLogSink(),
            configProvider: { config },
            directModeProvider: { (false, .none) },
            authenticatorProvider: { _ in AuditStaticAuthenticator() },
            directConnectDetector: DirectConnectDetector(group: group, logger: DiscardingLogSink()),
            pacRoutingEngine: nil,
            onConnectionOpened: { _ in },
            onConnectionClosed: { _ in },
            onRequestCompleted: { _, _ in }
        )
        try await server.start()
        defer { Task { await server.stop() } }

        let port = try XCTUnwrap(server.listeningPort)
        let response = try await rawHTTPExchange(
            port: port,
            request:
                "POST http://example.com/upload HTTP/1.1\r\n" +
                "Host: example.com\r\n" +
                "Content-Length: 2\r\n" +
                "\r\n" +
                "ab"
        )

        XCTAssertTrue(response.contains("413 Payload Too Large"))
    }

    private func startSOCKS5Server(
        directMode: Bool,
        config providedConfig: ProxyConfig? = nil,
        pacRoutingEngine: PACRoutingEngine? = nil
    ) async throws -> SOCKS5Server {
        let group = MultiThreadedEventLoopGroup.singleton
        var config = providedConfig ?? ProxyConfig.testFixture()
        if providedConfig == nil {
            config.upstreams = []
        }
        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in AuditStaticAuthenticator() }
        )
        let coordinator = CONNECTCoordinator(
            pool: pool,
            authenticatorProvider: { _ in AuditStaticAuthenticator() },
            logger: DiscardingLogSink()
        )
        let server = SOCKS5Server(
            group: group,
            connectCoordinator: coordinator,
            logger: DiscardingLogSink(),
            directModeProvider: { (directMode, directMode ? .noUpstreamsConfigured : .none) },
            pacRoutingEngine: pacRoutingEngine,
            configProvider: { config },
            gatewayMode: false
        )
        try await server.start(host: "127.0.0.1", port: 0)
        return server
    }

    private func socksExchange(port: Int, writes: [[UInt8]], expectedResponseCount: Int) async throws -> [[UInt8]] {
        let group = MultiThreadedEventLoopGroup.singleton
        let capture = ByteSequenceCapture(expectedCount: expectedResponseCount, eventLoop: group.next())
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(capture)
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        defer { client.close(promise: nil) }

        for bytes in writes {
            var buffer = client.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await client.writeAndFlush(buffer).get()
        }

        return try await capture.future.get()
    }

    private func socksExchangeUntilClose(port: Int, writes: [[UInt8]]) async throws -> [[UInt8]] {
        let group = MultiThreadedEventLoopGroup.singleton
        let capture = ByteSequenceUntilClose(eventLoop: group.next())
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(capture)
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        defer { client.close(promise: nil) }

        for bytes in writes {
            var buffer = client.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            try await client.writeAndFlush(buffer).get()
        }

        return try await capture.future.get()
    }

    private func rawHTTPExchange(port: Int, request: String) async throws -> String {
        let group = MultiThreadedEventLoopGroup.singleton
        let capture = RawHTTPResponseCapture(eventLoop: group.next())
        let client = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(capture)
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        defer { client.close(promise: nil) }

        var buffer = client.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        try await client.writeAndFlush(buffer).get()

        return try await capture.future.get()
    }
}

private final class AuditStaticAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"

    func initialToken(for host: String) throws -> String {
        "Negotiate audit-token"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        "Negotiate audit-response"
    }

    func canHandle(scheme: String) -> Bool {
        true
    }

    func reset() {}
}

private final class AuditPacEvaluator: PacEvaluator, @unchecked Sendable {
    private let scriptEvaluator: any PacScriptEvaluating

    init(scriptEvaluator: any PacScriptEvaluating) {
        self.scriptEvaluator = scriptEvaluator
    }

    func fetchPAC(from _: String) async throws -> String {
        "function FindProxyForURL() { return \"DIRECT\"; }"
    }

    func makeEvaluator(pacScript _: String) throws -> any PacScriptEvaluating {
        scriptEvaluator
    }

    func routeChain(for entries: [String]) -> [PACRoute] {
        entries.compactMap { entry in
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.caseInsensitiveCompare("DIRECT") == .orderedSame {
                return .direct
            }
            let parts = trimmed.split(separator: " ", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0].caseInsensitiveCompare("PROXY") == .orderedSame else { return nil }
            let endpoint = parts[1].split(separator: ":", maxSplits: 1).map(String.init)
            guard endpoint.count == 2, let port = Int(endpoint[1]) else { return nil }
            return .proxy(host: endpoint[0], port: port)
        }
    }
}

private final class PathSensitivePacScriptEvaluator: PacScriptEvaluating, @unchecked Sendable {
    func resolveProxyChain(for url: URL) throws -> [String] {
        url.path.contains("admin") ? ["PROXY corp.example:8080"] : ["DIRECT"]
    }
}

private struct DirectAuditPacScriptEvaluator: PacScriptEvaluating {
    func resolveProxyChain(for _: URL) throws -> [String] {
        ["DIRECT"]
    }
}

private final class SlowDirectAuditPacScriptEvaluator: PacScriptEvaluating, @unchecked Sendable {
    private let delay: TimeInterval

    init(delay: TimeInterval) {
        self.delay = delay
    }

    func resolveProxyChain(for _: URL) throws -> [String] {
        Thread.sleep(forTimeInterval: delay)
        return ["DIRECT"]
    }
}

private final class RawHTTPRequestCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var completed = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard !completed,
              let raw = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              raw.contains("\r\n\r\n") else {
            return
        }
        completed = true
        promise.succeed(raw)
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }
}

private final class RawHTTPBodyCaptureHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var completed = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard !completed,
              let bytes = accumulated.getBytes(at: accumulated.readerIndex, length: accumulated.readableBytes),
              let headerEndOffset = Self.headerEndOffset(in: bytes) else {
            return
        }
        let headers = String(bytes: bytes.prefix(headerEndOffset), encoding: .utf8) ?? ""
        let contentLength = headers
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let bodyStart = headerEndOffset + 4
        guard accumulated.readableBytes >= bodyStart + contentLength else {
            return
        }
        completed = true
        let body = String(bytes: bytes[bodyStart..<(bodyStart + contentLength)], encoding: .utf8) ?? ""
        promise.succeed(body)
        let response = "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
        var out = context.channel.allocator.buffer(capacity: response.utf8.count)
        out.writeString(response)
        context.writeAndFlush(NIOAny(out), promise: nil)
    }

    private static func headerEndOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index..<index + 4].elementsEqual([13, 10, 13, 10]) {
            return index
        }
        return nil
    }
}

private final class ByteSequenceCapture: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let expectedCount: Int
    private let promise: EventLoopPromise<[[UInt8]]>
    private var responses: [[UInt8]] = []

    init(expectedCount: Int, eventLoop: EventLoop) {
        self.expectedCount = expectedCount
        self.promise = eventLoop.makePromise(of: [[UInt8]].self)
    }

    var future: EventLoopFuture<[[UInt8]]> {
        promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        responses.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
        if responses.count >= expectedCount {
            promise.succeed(responses)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
    }
}

private final class ByteSequenceUntilClose: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<[[UInt8]]>
    private var responses: [[UInt8]] = []
    private var completed = false

    init(eventLoop: EventLoop) {
        self.promise = eventLoop.makePromise(of: [[UInt8]].self)
        eventLoop.scheduleTask(in: .seconds(2)) {
            if !self.completed {
                self.completed = true
                self.promise.fail(ChannelError.connectTimeout(.seconds(2)))
            }
        }
    }

    var future: EventLoopFuture<[[UInt8]]> {
        promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        responses.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        promise.succeed(responses)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }
}

private final class RawHTTPResponseCapture: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var completed = false

    init(eventLoop: EventLoop) {
        self.promise = eventLoop.makePromise(of: String.self)
        eventLoop.scheduleTask(in: .seconds(3)) {
            if !self.completed {
                self.completed = true
                self.promise.fail(ChannelError.connectTimeout(.seconds(3)))
            }
        }
    }

    var future: EventLoopFuture<String> {
        promise.futureResult
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard !completed,
              let raw = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              raw.contains("\r\n\r\n") else {
            return
        }
        completed = true
        promise.succeed(raw)
    }

    func channelInactive(context: ChannelHandlerContext) {
        guard !completed else { return }
        completed = true
        let raw = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes) ?? ""
        promise.succeed(raw)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !completed else { return }
        completed = true
        promise.fail(error)
    }
}

