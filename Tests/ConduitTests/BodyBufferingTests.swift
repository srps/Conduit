// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
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

    // MARK: - #81: spool failures are reported, not swallowed

    /// A spool directory that cannot be created fails the spool with the
    /// cause, instead of surfacing later as an unexplained open failure.
    /// Only this process's directory is touched: the root is shared with
    /// any Conduit running as this user.
    func testSpoolFailsWithTheCauseWhenItsDirectoryCannotBeCreated() async throws {
        let directory = SpooledHTTPRequestBody.processSpoolDirectory
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: directory)
        try fileManager.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A file where the directory should be.
        XCTAssertTrue(fileManager.createFile(atPath: directory.path, contents: Data("blocker".utf8)))
        defer { try? fileManager.removeItem(at: directory) }

        let group = MultiThreadedEventLoopGroup.singleton
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeString("ab")
        do {
            let body = try await SpooledHTTPRequestBody.create(initialBody: buffer, eventLoop: group.next()).get()
            body.cleanup()
            XCTFail("spooled into a directory that could not be created")
        } catch let error as RequestBodySpoolError {
            guard case .directoryUnavailable(let path, _) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, directory.path)
        }
    }

    func testSpoolCleanupReportsAFileItCouldNotRemove() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let reports = NIOLockedValueBox<[String]>([])
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeString("ab")
        let body = try await SpooledHTTPRequestBody.create(initialBody: buffer, eventLoop: group.next()) { failure in
            reports.withLockedValue { $0.append(failure.message) }
        }.get()
        _ = try await body.finalize(eventLoop: group.next()).get()

        let directory = SpooledHTTPRequestBody.processSpoolDirectory
        let fileManager = FileManager.default
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        defer { try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        body.cleanup()
        body.cleanup()

        XCTAssertEqual(reports.withLockedValue { $0.count }, 1, "\(reports.withLockedValue { $0 })")
        XCTAssertTrue(reports.withLockedValue { $0.first ?? "" }.contains("Could not remove a spooled request body"))
    }

    func testSpoolCleanupOfAFileAlreadyGoneReportsNothing() async throws {
        let group = MultiThreadedEventLoopGroup.singleton
        let reports = NIOLockedValueBox(0)
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeString("ab")
        let body = try await SpooledHTTPRequestBody.create(initialBody: buffer, eventLoop: group.next()) { _ in
            reports.withLockedValue { $0 += 1 }
        }.get()
        _ = try await body.finalize(eventLoop: group.next()).get()
        let directory = SpooledHTTPRequestBody.processSpoolDirectory
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }

        body.cleanup()

        XCTAssertEqual(reports.withLockedValue { $0 }, 0)
    }

    /// A dead process's directory the sweep cannot remove is counted with
    /// its cause rather than skipped silently.
    func testStartupSweepCountsWhatItCouldNotRemove() throws {
        let fileManager = FileManager.default
        let root = SpooledHTTPRequestBody.processSpoolDirectory.deletingLastPathComponent()
        // No process has this ID, so the sweep treats it as dead.
        let stale = root.appendingPathComponent("2147483000", isDirectory: true)
        let locked = stale.appendingPathComponent("locked", isDirectory: true)
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: locked.appendingPathComponent("body"))
        try fileManager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path)
            try? fileManager.removeItem(at: stale)
        }

        let sweep = SpooledHTTPRequestBody.cleanupStaleTemporaryFiles()

        XCTAssertGreaterThanOrEqual(sweep.failed, 1)
        XCTAssertNotNil(sweep.firstFailure)
        XCTAssertTrue(fileManager.fileExists(atPath: stale.path))
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
