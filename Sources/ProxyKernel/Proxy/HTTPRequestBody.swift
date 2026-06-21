// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix

package enum HTTPRequestBody: @unchecked Sendable {
    case memory(ByteBuffer)
    case spooled(SpooledHTTPRequestBody)

    package var readableBytes: Int {
        switch self {
        case .memory(let buffer):
            return buffer.readableBytes
        case .spooled(let body):
            return body.readableBytes
        }
    }

    package func writeClientBody(
        context: ChannelHandlerContext
    ) -> EventLoopFuture<Void> {
        writeClientBody(channel: context.channel)
    }

    package func writeClientBody(
        channel: Channel
    ) -> EventLoopFuture<Void> {
        switch self {
        case .memory(let buffer):
            channel.write(HTTPClientRequestPart.body(.byteBuffer(buffer)), promise: nil)
            return channel.eventLoop.makeSucceededVoidFuture()
        case .spooled(let body):
            return body.writeClientBody(channel: channel)
        }
    }

    package func cleanup() {
        if case .spooled(let body) = self {
            body.cleanup()
        }
    }
}

package final class SpooledHTTPRequestBody: @unchecked Sendable {
    private let path: String
    private let fileIO: NonBlockingFileIO
    private var writeHandle: NIOFileHandle?
    private(set) package var readableBytes: Int
    private var cleanedUp = false

    private init(path: String, fileIO: NonBlockingFileIO, writeHandle: NIOFileHandle, readableBytes: Int) {
        self.path = path
        self.fileIO = fileIO
        self.writeHandle = writeHandle
        self.readableBytes = readableBytes
    }

    deinit {
        cleanup()
    }

    package static func cleanupStaleTemporaryFiles() {
        HTTPRequestBodyFileIO.cleanupStaleTemporaryFiles()
    }

    package static func create(
        initialBody: ByteBuffer,
        eventLoop: EventLoop
    ) -> EventLoopFuture<SpooledHTTPRequestBody> {
        let path = HTTPRequestBodyFileIO.shared.makeTemporaryPath()
        let fileIO = HTTPRequestBodyFileIO.shared.fileIO
        return fileIO.openFile(
            _deprecatedPath: path,
            mode: .write,
            flags: .allowFileCreation(posixMode: 0o600),
            eventLoop: eventLoop
        ).flatMap { handle in
            let spooled = SpooledHTTPRequestBody(
                path: path,
                fileIO: fileIO,
                writeHandle: handle,
                readableBytes: initialBody.readableBytes
            )
            return fileIO.write(fileHandle: handle, buffer: initialBody, eventLoop: eventLoop)
                .map { spooled }
        }
    }

    package func append(
        _ buffer: ByteBuffer,
        eventLoop: EventLoop
    ) -> EventLoopFuture<Void> {
        guard let writeHandle else {
            return eventLoop.makeFailedFuture(ConnectionPoolError.invalidResponse)
        }
        readableBytes += buffer.readableBytes
        return fileIO.write(fileHandle: writeHandle, buffer: buffer, eventLoop: eventLoop)
    }

    package func finalize(eventLoop: EventLoop) -> EventLoopFuture<HTTPRequestBody> {
        if let handle = writeHandle {
            writeHandle = nil
            do {
                try handle.close()
            } catch {
                return eventLoop.makeFailedFuture(error)
            }
        }
        return eventLoop.makeSucceededFuture(.spooled(self))
    }

    package func writeClientBody(channel: Channel) -> EventLoopFuture<Void> {
        guard readableBytes > 0 else {
            return channel.eventLoop.makeSucceededVoidFuture()
        }
        let eventLoop = channel.eventLoop
        return fileIO.openFile(_deprecatedPath: path, mode: .read, eventLoop: eventLoop).flatMap { handle in
            self.fileIO.readChunked(
                fileHandle: handle,
                fromOffset: 0,
                byteCount: self.readableBytes,
                allocator: channel.allocator,
                eventLoop: eventLoop
            ) { chunk in
                channel.write(HTTPClientRequestPart.body(.byteBuffer(chunk)), promise: nil)
                return eventLoop.makeSucceededVoidFuture()
            }.always { _ in
                try? handle.close()
            }
        }
    }

    package func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        if let handle = writeHandle {
            try? handle.close()
            writeHandle = nil
        }
        try? FileManager.default.removeItem(atPath: path)
    }
}

private final class HTTPRequestBodyFileIO: @unchecked Sendable {
    static let shared = HTTPRequestBodyFileIO()

    let fileIO: NonBlockingFileIO
    private static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Conduit-RequestBodies", isDirectory: true)
    private let directory: URL

    private init() {
        let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
        threadPool.start()
        self.fileIO = NonBlockingFileIO(threadPool: threadPool)
        Self.cleanupStaleTemporaryFiles()
        self.directory = Self.rootDirectory
            .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func makeTemporaryPath() -> String {
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).path
    }

    static func cleanupStaleTemporaryFiles() {
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: rootDirectory, withIntermediateDirectories: true)
        guard let contents = try? fileManager.contentsOfDirectory(
            at: rootDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        for url in contents {
            if isLiveProcessDirectory(url, currentProcessID: currentProcessID) {
                continue
            }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func isLiveProcessDirectory(_ url: URL, currentProcessID: Int32) -> Bool {
        guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else {
            return false
        }
        guard let processID = Int32(url.lastPathComponent) else {
            return false
        }
        guard processID != currentProcessID else {
            return true
        }
        return kill(processID, 0) == 0
    }
}
