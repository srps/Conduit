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

    /// A directory of the test's own, so fault injection never touches the
    /// process's spool or any other Conduit's. Removed after the test, with
    /// write permission restored first.
    private func isolatedSpoolDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("conduit-spool-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            let fileManager = FileManager.default
            if let entries = fileManager.enumerator(atPath: directory.path) {
                for case let entry as String in entries {
                    try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.appendingPathComponent(entry).path)
                }
            }
            try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try fileManager.removeItem(at: directory)
        }
        return directory
    }

    private func smallBody() -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: 2)
        buffer.writeString("ab")
        return buffer
    }

    /// A spool directory that cannot be created fails the spool with the
    /// cause, instead of surfacing later as an unexplained open failure.
    func testSpoolFailsWithTheCauseWhenItsDirectoryCannotBeCreated() async throws {
        let parent = try isolatedSpoolDirectory()
        // A file where the directory should be.
        let blocked = parent.appendingPathComponent("spool")
        XCTAssertTrue(FileManager.default.createFile(atPath: blocked.path, contents: Data("blocker".utf8)))

        let group = MultiThreadedEventLoopGroup.singleton
        do {
            let body = try await SpooledHTTPRequestBody.create(initialBody: smallBody(), eventLoop: group.next(), directory: blocked).get()
            body.cleanup()
            XCTFail("spooled into a directory that could not be created")
        } catch let error as RequestBodySpoolError {
            guard case .directoryUnavailable(let path, let reason) = error else { return XCTFail("\(error)") }
            XCTAssertEqual(path, blocked.path)
            XCTAssertTrue(reason.contains("errno 17"), reason)
        }
    }

    func testSpoolCleanupReportsAFileItCouldNotRemove() async throws {
        let directory = try isolatedSpoolDirectory()
        let group = MultiThreadedEventLoopGroup.singleton
        let reports = NIOLockedValueBox<[String]>([])
        let body = try await SpooledHTTPRequestBody.create(initialBody: smallBody(), eventLoop: group.next(), directory: directory) { failure in
            reports.withLockedValue { $0.append(failure.message) }
        }.get()
        _ = try await body.finalize(eventLoop: group.next()).get()

        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        body.cleanup()
        body.cleanup()

        XCTAssertEqual(reports.withLockedValue { $0.count }, 1, "\(reports.withLockedValue { $0 })")
        XCTAssertTrue(reports.withLockedValue { $0.first ?? "" }.contains("Could not remove a spooled request body"))
    }

    func testSpoolCleanupOfAFileAlreadyGoneReportsNothing() async throws {
        let directory = try isolatedSpoolDirectory()
        let group = MultiThreadedEventLoopGroup.singleton
        let reports = NIOLockedValueBox(0)
        let body = try await SpooledHTTPRequestBody.create(initialBody: smallBody(), eventLoop: group.next(), directory: directory) { _ in
            reports.withLockedValue { $0 += 1 }
        }.get()
        _ = try await body.finalize(eventLoop: group.next()).get()
        for file in try FileManager.default.contentsOfDirectory(atPath: directory.path) {
            try FileManager.default.removeItem(at: directory.appendingPathComponent(file))
        }

        body.cleanup()

        XCTAssertEqual(reports.withLockedValue { $0 }, 0)
    }

    /// A dead process's directory the sweep cannot remove is counted with
    /// its cause rather than skipped silently.
    func testStartupSweepCountsWhatItCouldNotRemove() throws {
        let root = try isolatedSpoolDirectory()
        // No process has this ID, so the sweep treats it as dead.
        let stale = root.appendingPathComponent("2147483000", isDirectory: true)
        let locked = stale.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try Data("stale".utf8).write(to: locked.appendingPathComponent("body"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        let removable = root.appendingPathComponent("2147483001", isDirectory: true)
        try FileManager.default.createDirectory(at: removable, withIntermediateDirectories: true)

        let sweep = SpooledHTTPRequestBody.cleanupStaleTemporaryFiles(root: root)

        XCTAssertEqual(sweep.failed, 1)
        XCTAssertEqual(sweep.removed, 1)
        XCTAssertTrue(sweep.firstFailure?.hasPrefix("2147483000:") == true, sweep.firstFailure ?? "nil")
        XCTAssertTrue(FileManager.default.fileExists(atPath: stale.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: removable.path))
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
