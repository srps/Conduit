// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix

enum AuditScenarios {
    @MainActor
    static func proxiedResponseHopByHop(verbose: Bool) async throws -> ScenarioResult {
        let name = "audit-proxied-response-hop-by-hop"
        let start = Date()
        let response = "HTTP/1.1 200 OK\r\n" +
            "Connection: X-Hop\r\n" +
            "X-Hop: response-hop\r\n" +
            "Content-Length: 0\r\n" +
            "\r\n"
        let harness = SimHarness(verbose: verbose)
        try await harness.start(
            originBehavior: .silent,
            upstreamPlainHTTPResponse: response
        )
        defer { Task { @MainActor in await harness.stop() } }

        let raw = try await RawHTTPAuditClient.request(
            group: harness.group,
            host: harness.localProxyHost,
            port: harness.localProxyPort,
            request: "GET http://example.com/resource HTTP/1.1\r\n" +
                "Host: example.com\r\n" +
                "Connection: close\r\n" +
                "\r\n"
        )
        let leaked = raw.contains("\r\nX-Hop: response-hop\r\n")
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: 1,
            clientsWithFirstByte: raw.isEmpty ? 0 : 1,
            clientsClosedEarly: leaked ? 0 : 1,
            totalBytes: raw.utf8.count,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: raw.utf8.count,
            maxBytes: raw.utf8.count,
            medianBytes: raw.utf8.count,
            earliestClose: nil,
            latestClose: nil,
            notes: [
                leaked ? "BUG_REPRODUCED: proxied response leaked X-Hop" : "fixed: X-Hop stripped",
                "containsConnectionHeader=\(raw.contains("\r\nConnection: X-Hop\r\n"))"
            ]
        )
    }

    @MainActor
    /// `Expect: 100-continue` answered by the proxy + response-trailer
    /// pass-through on the proxied (pooled streaming) path, end to end.
    static func expectContinueAndTrailers(verbose: Bool) async throws -> ScenarioResult {
        let name = "audit-expect-trailers"
        let start = Date()
        let chunkedWithTrailer =
            "HTTP/1.1 200 OK\r\n" +
            "Transfer-Encoding: chunked\r\n" +
            "Trailer: X-Trailer-Test\r\n" +
            "Connection: keep-alive\r\n" +
            "\r\n" +
            "4\r\nbody\r\n" +
            "0\r\n" +
            "X-Trailer-Test: shipped\r\n" +
            "\r\n"
        let harness = SimHarness(verbose: verbose)
        try await harness.start(
            originBehavior: .silent,
            upstreamPlainHTTPResponse: chunkedWithTrailer
        )
        defer { Task { @MainActor in await harness.stop() } }

        let transcript = try await ExpectContinueAuditClient.run(
            group: harness.group,
            host: harness.localProxyHost,
            port: harness.localProxyPort,
            requestHead:
                "PUT http://example.com/upload HTTP/1.1\r\n" +
                "Host: example.com\r\n" +
                "Expect: 100-continue\r\n" +
                "Content-Length: 5\r\n" +
                "\r\n",
            body: "hello",
            completionMarker: "X-Trailer-Test: shipped"
        )

        let got100 = transcript.contains("HTTP/1.1 100 Continue")
        let gotFinal = transcript.contains("HTTP/1.1 200 OK")
        let gotTrailer = transcript.contains("X-Trailer-Test: shipped")
        let passed = got100 && gotFinal && gotTrailer
        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: 1,
            clientsWithFirstByte: transcript.isEmpty ? 0 : 1,
            clientsClosedEarly: passed ? 0 : 1,
            totalBytes: transcript.utf8.count,
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: transcript.utf8.count,
            maxBytes: transcript.utf8.count,
            medianBytes: transcript.utf8.count,
            earliestClose: nil,
            latestClose: nil,
            notes: [
                passed ? "ok: proxy answered 100-continue and trailers passed through"
                       : "BUG: expect/trailer hygiene incomplete (100=\(got100) final=\(gotFinal) trailer=\(gotTrailer))",
            ]
        )
    }

    @MainActor
    static func socks5NonZeroRSV(verbose: Bool) async throws -> ScenarioResult {
        let name = "audit-socks5-nonzero-rsv"
        let start = Date()
        let harness = SimHarness(verbose: verbose)
        try await harness.start(
            originBehavior: .silent,
            socksEnabled: true,
            socksPort: 0,
            directMode: true,
            directModeCause: .noUpstreamsConfigured
        )
        defer { Task { @MainActor in await harness.stop() } }

        guard let socksPort = harness.server?.socksListeningPort else {
            throw NSError(
                domain: "pm-sim.audit",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "SOCKS5 listener did not start"]
            )
        }

        let targetPort = harness.origin?.port ?? 0
        let request: [UInt8] = [
            0x05, 0x01, 0x01, 0x01,
            127, 0, 0, 1,
            UInt8((targetPort >> 8) & 0xFF), UInt8(targetPort & 0xFF),
        ]
        let responses = try await SOCKS5AuditClient.exchange(
            group: harness.group,
            port: socksPort,
            writes: [[0x05, 0x01, 0x00], request],
            expectedResponses: 2
        )
        let replyCode = responses.last?.dropFirst().first
        let accepted = replyCode == 0x00

        return ScenarioResult(
            name: name,
            clientCount: 1,
            clientsOpened: 1,
            clientsWithFirstByte: responses.isEmpty ? 0 : 1,
            clientsClosedEarly: accepted ? 0 : 1,
            totalBytes: responses.reduce(0) { $0 + $1.count },
            durationSeconds: Date().timeIntervalSince(start),
            aggregateMBps: 0,
            minBytes: responses.map(\.count).min() ?? 0,
            maxBytes: responses.map(\.count).max() ?? 0,
            medianBytes: responses.map(\.count).sorted().dropFirst(responses.count / 2).first ?? 0,
            earliestClose: nil,
            latestClose: nil,
            notes: [
                accepted ? "BUG_REPRODUCED: SOCKS5 accepted RSV=0x01" : "fixed: nonzero RSV rejected",
                "replyCode=\(replyCode.map { String(format: "0x%02X", $0) } ?? "<none>")"
            ]
        )
    }
}

private final class RawHTTPAuditClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let request: String
    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)

    init(request: String, promise: EventLoopPromise<String>) {
        self.request = request
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: request.utf8.count)
        buffer.writeString(request)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let raw = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes),
              raw.contains("\r\n\r\n") else {
            return
        }
        promise.succeed(raw)
        context.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private enum RawHTTPAuditClient {
    static func request(group: EventLoopGroup, host: String, port: Int, request: String) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(AuditScenarioError.timeout("raw HTTP audit client timed out"))
        }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(RawHTTPAuditClientHandler(request: request, promise: promise))
            }
            .connect(host: host, port: port)
            .get()
        defer { channel.close(promise: nil) }
        return try await promise.futureResult.always { _ in timeout.cancel() }.get()
    }
}

private final class SOCKS5AuditClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let writes: [[UInt8]]
    private let expectedResponses: Int
    private let promise: EventLoopPromise<[[UInt8]]>
    private var responses: [[UInt8]] = []
    private var nextWriteIndex = 0

    init(writes: [[UInt8]], expectedResponses: Int, promise: EventLoopPromise<[[UInt8]]>) {
        self.writes = writes
        self.expectedResponses = expectedResponses
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        writeNext(context: context)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        responses.append(buffer.readBytes(length: buffer.readableBytes) ?? [])
        if responses.count >= expectedResponses {
            promise.succeed(responses)
            context.close(promise: nil)
        } else {
            writeNext(context: context)
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }

    private func writeNext(context: ChannelHandlerContext) {
        guard nextWriteIndex < writes.count else { return }
        let bytes = writes[nextWriteIndex]
        nextWriteIndex += 1
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}

private enum SOCKS5AuditClient {
    static func exchange(
        group: EventLoopGroup,
        port: Int,
        writes: [[UInt8]],
        expectedResponses: Int
    ) async throws -> [[UInt8]] {
        let promise = group.next().makePromise(of: [[UInt8]].self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(AuditScenarioError.timeout("SOCKS5 audit client timed out"))
        }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    SOCKS5AuditClientHandler(
                        writes: writes,
                        expectedResponses: expectedResponses,
                        promise: promise
                    )
                )
            }
            .connect(host: "127.0.0.1", port: port)
            .get()
        defer { channel.close(promise: nil) }
        return try await promise.futureResult.always { _ in timeout.cancel() }.get()
    }
}

/// Two-phase raw client: sends the request head, waits for the proxy's
/// `100 Continue`, then sends the body and accumulates until
/// `completionMarker` appears (or fails on timeout/close).
private final class ExpectContinueAuditClientHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let requestHead: String
    private let body: String
    private let completionMarker: String
    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var sentBody = false

    init(requestHead: String, body: String, completionMarker: String, promise: EventLoopPromise<String>) {
        self.requestHead = requestHead
        self.body = body
        self.completionMarker = completionMarker
        self.promise = promise
    }

    func channelActive(context: ChannelHandlerContext) {
        var buffer = context.channel.allocator.buffer(capacity: requestHead.utf8.count)
        buffer.writeString(requestHead)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let transcript = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes) else { return }

        if !sentBody, transcript.contains("100 Continue") {
            sentBody = true
            var out = context.channel.allocator.buffer(capacity: body.utf8.count)
            out.writeString(body)
            context.writeAndFlush(wrapOutboundOut(out), promise: nil)
        }
        if transcript.contains(completionMarker) {
            promise.succeed(transcript)
            context.close(promise: nil)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        let transcript = accumulated.getString(at: accumulated.readerIndex, length: accumulated.readableBytes) ?? ""
        promise.succeed(transcript)
        context.fireChannelInactive()
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        promise.fail(error)
        context.close(promise: nil)
    }
}

private enum ExpectContinueAuditClient {
    static func run(
        group: EventLoopGroup,
        host: String,
        port: Int,
        requestHead: String,
        body: String,
        completionMarker: String
    ) async throws -> String {
        let promise = group.next().makePromise(of: String.self)
        let timeout = promise.futureResult.eventLoop.scheduleTask(in: .seconds(5)) {
            promise.fail(AuditScenarioError.timeout("expect-continue audit client timed out"))
        }
        let channel = try await ClientBootstrap(group: group)
            .channelInitializer { channel in
                channel.pipeline.addHandler(
                    ExpectContinueAuditClientHandler(
                        requestHead: requestHead,
                        body: body,
                        completionMarker: completionMarker,
                        promise: promise
                    )
                )
            }
            .connect(host: host, port: port)
            .get()
        defer { channel.close(promise: nil) }
        return try await promise.futureResult.always { _ in timeout.cancel() }.get()
    }
}

private enum AuditScenarioError: Error, LocalizedError {
    case timeout(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let message): return message
        }
    }
}
