// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
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

/// Why a request body could not be spooled to disk.
package enum RequestBodySpoolError: Error, LocalizedError, Equatable {
    case directoryUnavailable(path: String, reason: String)
    /// A chunk was queued for a spool that does not exist. A bug, reported
    /// rather than dropping the chunk.
    case spoolMissing

    package var errorDescription: String? {
        switch self {
        case .directoryUnavailable(let path, let reason):
            return "The request-body spool directory \(path) is unavailable: \(reason)"
        case .spoolMissing:
            return "A request-body chunk was queued for a spool that does not exist."
        }
    }
}

/// Spool housekeeping that failed outside any one request: removing a
/// finished body's file, or sweeping a dead process's leftovers at startup.
/// Reported so leaked disk use has a cause on record.
package struct RequestBodySpoolHousekeepingFailure: Error, Sendable, LocalizedError {
    package let message: String

    package var errorDescription: String? { message }
}

package final class SpooledHTTPRequestBody: @unchecked Sendable {
    private let path: String
    private let fileIO: NonBlockingFileIO
    private var writeHandle: NIOFileHandle?
    private(set) package var readableBytes: Int
    private var cleanedUp = false
    private let reportFailure: @Sendable (RequestBodySpoolHousekeepingFailure) -> Void

    private init(
        path: String,
        fileIO: NonBlockingFileIO,
        writeHandle: NIOFileHandle,
        readableBytes: Int,
        reportFailure: @escaping @Sendable (RequestBodySpoolHousekeepingFailure) -> Void
    ) {
        self.path = path
        self.fileIO = fileIO
        self.writeHandle = writeHandle
        self.readableBytes = readableBytes
        self.reportFailure = reportFailure
    }

    deinit {
        cleanup()
    }

    /// `root` defaults to the shared spool root; tests pass their own.
    @discardableResult
    package static func cleanupStaleTemporaryFiles(root: URL? = nil) -> RequestBodySpoolSweep {
        HTTPRequestBodyFileIO.sweep(root: root ?? HTTPRequestBodyFileIO.rootDirectory)
    }

    /// This process's spool directory. For tests and simulator scenarios
    /// that need to make it fail.
    package static var processSpoolDirectory: URL {
        HTTPRequestBodyFileIO.processDirectory
    }

    /// Creates the spool file. A directory that cannot be created fails the
    /// future with `RequestBodySpoolError.directoryUnavailable`. The
    /// directory work runs on the spool's thread pool, never the event loop.
    /// `reportFailure` hears of housekeeping that failed later: this body's
    /// file not being removed, and (once per process, for a spool in the
    /// process directory) the startup sweep. `directory` defaults to this
    /// process's spool directory; tests pass their own so fault injection
    /// never touches another spool's files.
    package static func create(
        initialBody: ByteBuffer,
        eventLoop: EventLoop,
        directory: URL? = nil,
        reportFailure: @escaping @Sendable (RequestBodySpoolHousekeepingFailure) -> Void = { _ in }
    ) -> EventLoopFuture<SpooledHTTPRequestBody> {
        let io = HTTPRequestBodyFileIO.shared
        let fileIO = io.fileIO
        return io.makeTemporaryPath(in: directory ?? HTTPRequestBodyFileIO.processDirectory, eventLoop: eventLoop).flatMap { path in
            if directory == nil, let sweepFailure = io.takeStartupSweepFailure() {
                reportFailure(sweepFailure)
            }
            return fileIO.openFile(
                _deprecatedPath: path,
                mode: .write,
                flags: .allowFileCreation(posixMode: 0o600),
                eventLoop: eventLoop
            ).map { (path, $0) }
        }.flatMap { path, handle in
            let spooled = SpooledHTTPRequestBody(
                path: path,
                fileIO: fileIO,
                writeHandle: handle,
                readableBytes: initialBody.readableBytes,
                reportFailure: reportFailure
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
                // A read handle; closing it loses nothing if it fails.
                try? handle.close()
            }
        }
    }

    package func cleanup() {
        guard !cleanedUp else { return }
        cleanedUp = true
        if let handle = writeHandle {
            // Closed only to remove the file next; that removal reports.
            try? handle.close()
            writeHandle = nil
        }
        do {
            try HTTPRequestBodyFileIO.removeSpoolFile(atPath: path)
        } catch {
            reportFailure(RequestBodySpoolHousekeepingFailure(
                message: "Could not remove a spooled request body (\(error.displayDescription)); it stays on disk until the next startup sweep."
            ))
        }
    }
}

/// What a startup sweep of dead processes' spool directories did.
package struct RequestBodySpoolSweep: Sendable, Equatable {
    package var removed = 0
    package var failed = 0
    package var firstFailure: String?
}

private final class HTTPRequestBodyFileIO: @unchecked Sendable {
    static let shared = HTTPRequestBodyFileIO()

    let fileIO: NonBlockingFileIO
    private let threadPool: NIOThreadPool
    /// The startup sweep, run first on the thread pool. Every spool waits
    /// for it, so it never races a spool's directory and its result is in
    /// before the first spool could report it.
    private let sweepDone: EventLoopFuture<Void>
    static let rootDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("Conduit-RequestBodies", isDirectory: true)
    static let processDirectory = rootDirectory
        .appendingPathComponent("\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
    /// Held until the first spool reports it; at most one per process.
    private let startupSweepFailure: NIOLockedValueBox<RequestBodySpoolHousekeepingFailure?>

    private init() {
        let threadPool = NIOThreadPool(numberOfThreads: NonBlockingFileIO.defaultThreadPoolSize)
        threadPool.start()
        self.threadPool = threadPool
        self.fileIO = NonBlockingFileIO(threadPool: threadPool)
        let failure = NIOLockedValueBox<RequestBodySpoolHousekeepingFailure?>(nil)
        startupSweepFailure = failure
        let swept = MultiThreadedEventLoopGroup.singleton.next().makePromise(of: Void.self)
        sweepDone = swept.futureResult
        threadPool.submit { state in
            if case .active = state {
                let sweep = Self.sweep(root: Self.rootDirectory)
                if sweep.failed > 0 {
                    failure.withLockedValue {
                        $0 = RequestBodySpoolHousekeepingFailure(
                            message: "The startup sweep could not remove \(sweep.failed) stale request-body spool entr\(sweep.failed == 1 ? "y" : "ies") under \(Self.rootDirectory.path): \(sweep.firstFailure ?? "unknown")"
                        )
                    }
                }
            }
            swept.succeed(())
        }
    }

    func takeStartupSweepFailure() -> RequestBodySpoolHousekeepingFailure? {
        startupSweepFailure.withLockedValue { failure in
            defer { failure = nil }
            return failure
        }
    }

    /// Created on every call, so a directory removed under a running
    /// process comes back; a directory that cannot be created is the
    /// request's failure. On the thread pool, after the startup sweep.
    func makeTemporaryPath(in directory: URL, eventLoop: EventLoop) -> EventLoopFuture<String> {
        let threadPool = self.threadPool
        return sweepDone.hop(to: eventLoop).flatMap {
            threadPool.runIfActive(eventLoop: eventLoop) {
                try Self.prepareDirectory(directory)
                return directory.appendingPathComponent(UUID().uuidString).path
            }
        }
    }

    static func prepareDirectory(_ url: URL) throws {
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            throw RequestBodySpoolError.directoryUnavailable(path: url.path, reason: briefReason(error))
        }
    }

    /// The POSIX cause under a Foundation error ("File exists (errno 17)"),
    /// which an event can carry; the full `NSError` description repeats
    /// paths and user-info that the sanitizer then has to redact.
    private static func briefReason(_ error: Error) -> String {
        let nsError = error as NSError
        if let posix = nsError.userInfo[NSUnderlyingErrorKey] as? NSError, posix.domain == NSPOSIXErrorDomain {
            return "\(posix.localizedDescription) (errno \(posix.code))"
        }
        return error.displayDescription
    }

    /// A file that is already gone is not a failure.
    static func removeSpoolFile(atPath path: String) throws {
        do {
            try FileManager.default.removeItem(atPath: path)
        } catch CocoaError.fileNoSuchFile {
            return
        }
    }

    /// Removes the spool directories of processes that are no longer running.
    static func sweep(root: URL) -> RequestBodySpoolSweep {
        var result = RequestBodySpoolSweep()
        let fileManager = FileManager.default
        let contents: [URL]
        do {
            contents = try fileManager.contentsOfDirectory(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        } catch CocoaError.fileReadNoSuchFile {
            // Nothing spooled yet on this machine: nothing to sweep.
            return result
        } catch {
            result.failed += 1
            result.firstFailure = "listing \(root.path): \(error.displayDescription)"
            return result
        }

        let currentProcessID = ProcessInfo.processInfo.processIdentifier
        for url in contents {
            if isLiveProcessDirectory(url, currentProcessID: currentProcessID) {
                continue
            }
            do {
                try fileManager.removeItem(at: url)
                result.removed += 1
            } catch CocoaError.fileNoSuchFile {
                continue
            } catch {
                result.failed += 1
                if result.firstFailure == nil {
                    result.firstFailure = "\(url.lastPathComponent): \(error.displayDescription)"
                }
            }
        }
        return result
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
