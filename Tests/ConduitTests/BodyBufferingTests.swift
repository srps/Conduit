// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOEmbedded
import NIOHTTP1
import NIOPosix
import XCTest
@testable import ProxyKernel

final class BodyBufferingTests: XCTestCase {

    @MainActor func testBodyTruncatedErrorDescription() {
        let error = ConnectionPoolError.bodyTooLargeForReplay
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.lowercased().contains("too large"))
    }

    @MainActor func testMaxBufferedBodyBytesDefault() {
        let config = ProxyConfig.testFixture()
        XCTAssertEqual(config.maxBufferedBodyBytes, 16_777_216)
        XCTAssertEqual(config.maxSpooledBodyBytes, 268_435_456)
    }

    @MainActor func testMaxBufferedBodyBytesDecodesFromJSON() throws {
        let json = #"{"maxBufferedBodyBytes": 2097152, "maxSpooledBodyBytes": 33554432}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.maxBufferedBodyBytes, 2_097_152)
        XCTAssertEqual(config.maxSpooledBodyBytes, 33_554_432)
    }

    @MainActor func testMaxBufferedBodyBytesDefaultsWhenMissing() throws {
        let json = #"{}"#.data(using: .utf8)!
        let config = try JSONDecoder().decode(ProxyConfig.self, from: json)
        XCTAssertEqual(config.maxBufferedBodyBytes, 16_777_216)
        XCTAssertEqual(config.maxSpooledBodyBytes, 268_435_456)
    }

    @MainActor func testMaxSpooledBodyBytesMustCoverMemoryThreshold() {
        var config = ProxyConfig.testFixture()
        config.maxBufferedBodyBytes = 1024
        config.maxSpooledBodyBytes = 512

        XCTAssertFalse(config.validate().isEmpty)
    }

    func testStaleSpooledBodyFilesAreRemoved() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("Conduit-RequestBodies", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        let staleFile = root.appendingPathComponent(UUID().uuidString)
        try Data("stale".utf8).write(to: staleFile)

        SpooledHTTPRequestBody.cleanupStaleTemporaryFiles()

        XCTAssertFalse(fileManager.fileExists(atPath: staleFile.path))
    }

    func testSpooledBodyReplaysAcrossProxyAuthenticationChallenge() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let capturedBody = group.next().makePromise(of: String.self)
        let upstream = try await ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(ReplayBodyCaptureProxyHandler(promise: capturedBody))
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        defer { upstream.close(promise: nil) }

        var config = ProxyConfig.testFixture()
        config.upstreams = [
            UpstreamProxy(
                name: "auth-proxy",
                host: "127.0.0.1",
                port: try XCTUnwrap(upstream.localAddress?.port),
                priority: 0
            )
        ]
        let pool = ConnectionPool(
            group: group,
            logger: DiscardingLogSink(),
            configProvider: { config },
            authenticatorProvider: { _ in ReplayStaticAuthenticator() }
        )
        defer { pool.closeAll() }

        var headers = HTTPHeaders()
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "Content-Length", value: "2")
        let head = HTTPRequestHead(version: .http1_1, method: .POST, uri: "http://example.com/upload", headers: headers)
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeString("ab")
        let body = try await SpooledHTTPRequestBody.create(initialBody: buffer, eventLoop: group.next()).get()
        defer { body.cleanup() }

        let response = try await pool.exchange(head: head, requestBody: .spooled(body)).get()
        XCTAssertEqual(response.head.status, .ok)
        let captured = try await capturedBody.futureResult.get()
        XCTAssertEqual(captured, "ab")
    }
}

private final class ReplayStaticAuthenticator: ProxyAuthenticator, @unchecked Sendable {
    let scheme = "Negotiate"

    func initialToken(for host: String) throws -> String {
        "Negotiate initial"
    }

    func processChallenge(headerValues: [String], host: String) throws -> String? {
        "Negotiate response"
    }

    func canHandle(scheme: String) -> Bool {
        true
    }

    func reset() {}
}

private final class ReplayBodyCaptureProxyHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let promise: EventLoopPromise<String>
    private var accumulated = ByteBufferAllocator().buffer(capacity: 4096)
    private var challenged = false

    init(promise: EventLoopPromise<String>) {
        self.promise = promise
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var buffer = unwrapInboundIn(data)
        accumulated.writeBuffer(&buffer)
        guard let parsed = parseRequest() else { return }
        accumulated.clear()

        if !challenged {
            challenged = true
            writeRaw("HTTP/1.1 407 Proxy Authentication Required\r\nProxy-Authenticate: Negotiate\r\nContent-Length: 0\r\n\r\n", context: context)
            return
        }

        promise.succeed(parsed)
        writeRaw("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n", context: context)
    }

    private func parseRequest() -> String? {
        guard let bytes = accumulated.getBytes(at: accumulated.readerIndex, length: accumulated.readableBytes),
              let headerEnd = Self.headerEndOffset(in: bytes) else {
            return nil
        }
        let headers = String(bytes: bytes.prefix(headerEnd), encoding: .utf8) ?? ""
        let contentLength = headers
            .split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? "") } ?? 0
        let bodyStart = headerEnd + 4
        guard bytes.count >= bodyStart + contentLength else {
            return nil
        }
        return (String(bytes: bytes[bodyStart..<(bodyStart + contentLength)], encoding: .utf8) ?? "")
    }

    private static func headerEndOffset(in bytes: [UInt8]) -> Int? {
        guard bytes.count >= 4 else { return nil }
        for index in 0...(bytes.count - 4) where bytes[index..<index + 4].elementsEqual([13, 10, 13, 10]) {
            return index
        }
        return nil
    }

    private func writeRaw(_ value: String, context: ChannelHandlerContext) {
        var out = context.channel.allocator.buffer(capacity: value.utf8.count)
        out.writeString(value)
        context.writeAndFlush(wrapOutboundOut(out), promise: nil)
    }
}
