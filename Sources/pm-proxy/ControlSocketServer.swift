// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyControlBridge
import ProxyKernel
import ConduitShared

final class ControlSocketServer: @unchecked Sendable {
    private let socketPath: String
    private let logger: any LogSink
    private let statusProvider: @MainActor @Sendable () -> ControlDaemonStatus
    private let reloadHandler: @MainActor @Sendable () async -> Void
    private let stopHandler: @MainActor @Sendable () async -> Void
    private let upstreamTestHandler: @MainActor @Sendable (String) async -> ProbeResult?
    private let queue = DispatchQueue(label: "pm-proxy.control-socket")

    private var listenFD: Int32 = -1
    private var source: DispatchSourceRead?

    init(
        socketPath: String,
        logger: any LogSink,
        statusProvider: @escaping @MainActor @Sendable () -> ControlDaemonStatus,
        reloadHandler: @escaping @MainActor @Sendable () async -> Void,
        stopHandler: @escaping @MainActor @Sendable () async -> Void,
        upstreamTestHandler: @escaping @MainActor @Sendable (String) async -> ProbeResult?
    ) {
        self.socketPath = socketPath
        self.logger = logger
        self.statusProvider = statusProvider
        self.reloadHandler = reloadHandler
        self.stopHandler = stopHandler
        self.upstreamTestHandler = upstreamTestHandler
    }

    func start() throws {
        let socketURL = URL(fileURLWithPath: socketPath)
        try FileManager.default.createDirectory(
            at: socketURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Self.removeSocketFileIfPresent(socketURL)

        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw ControlSocketError.posix("socket", errno)
        }
        listenFD = fd

        do {
            try bindAndListen(fd: fd)
            let readSource = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            readSource.setEventHandler { [weak self] in
                self?.acceptAvailableConnections()
            }
            readSource.setCancelHandler { [logger, socketPath] in
                Darwin.close(fd)
                do {
                    try Self.removeSocketFileIfPresent(URL(fileURLWithPath: socketPath))
                } catch {
                    logger.log(
                        .warning,
                        "Failed to remove control socket at \(socketPath): \(error.localizedDescription)",
                        category: .general
                    )
                }
            }
            source = readSource
            readSource.resume()
            logger.log(.notice, "Control socket listening at \(socketPath)", category: .general)
        } catch {
            Darwin.close(fd)
            listenFD = -1
            do {
                try Self.removeSocketFileIfPresent(socketURL)
            } catch {
                logger.log(
                    .warning,
                    "Failed to remove control socket after start failure: \(error.localizedDescription)",
                    category: .general
                )
            }
            throw error
        }
    }

    func stop() {
        queue.async { [self] in
            source?.cancel()
            source = nil
            listenFD = -1
        }
    }

    private func bindAndListen(fd: Int32) throws {
        try setNonBlocking(fd)

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        try writePath(socketPath, into: &address)

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                Darwin.bind(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw ControlSocketError.posix("bind", errno)
        }
        guard Darwin.chmod(socketPath, 0o600) == 0 else {
            throw ControlSocketError.posix("chmod", errno)
        }
        guard Darwin.listen(fd, 16) == 0 else {
            throw ControlSocketError.posix("listen", errno)
        }
    }

    private func acceptAvailableConnections() {
        while true {
            let clientFD = Darwin.accept(listenFD, nil, nil)
            if clientFD >= 0 {
                guard Self.peerIsAllowed(clientFD) else {
                    logger.log(.warning, "Control socket rejected unauthorized peer.", category: .general)
                    Darwin.close(clientFD)
                    continue
                }
                handle(clientFD: clientFD)
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            logger.log(.warning, "Control socket accept failed: \(String(cString: strerror(errno)))", category: .general)
            return
        }
    }

    private func handle(clientFD: Int32) {
        do {
            try setNoSigPipe(clientFD)
            try setBlocking(clientFD)
            try setReadTimeout(clientFD, seconds: 2)
            let request = try readRequest(from: clientFD)
            guard request.protocolVersion == ControlProtocolVersion.current else {
                try writeResponse(
                    .error(.unsupportedVersion, "Unsupported control protocol version."),
                    to: clientFD
                )
                Darwin.close(clientFD)
                return
            }

            switch request.command {
            case .diag:
                try writeResponse(
                    .error(.notImplemented, "Use pmctl diag to create a diagnostics bundle."),
                    to: clientFD
                )
                Darwin.close(clientFD)
            case .events:
                try writeResponse(
                    .error(.notImplemented, "Use pmctl events to read events.ndjson."),
                    to: clientFD
                )
                Darwin.close(clientFD)
            case .reload:
                Task { @MainActor in
                    await reloadHandler()
                    queue.async {
                        do {
                            try self.writeResponse(.ok(), to: clientFD)
                        } catch {
                            self.logger.log(
                                .warning,
                                "Control socket reload response failed: \(error.localizedDescription)",
                                category: .general
                            )
                        }
                        Darwin.close(clientFD)
                    }
                }
            case .setProfile:
                try writeResponse(
                    .error(.notImplemented, "Profile switching is reserved for the production daemon."),
                    to: clientFD
                )
                Darwin.close(clientFD)
            case .start:
                try writeResponse(
                    .error(.notImplemented, "pm-proxy starts its isolated runtime at process launch; start is reserved for ConduitDaemon."),
                    to: clientFD
                )
                Darwin.close(clientFD)
            case .status:
                Task { @MainActor in
                    let response = ControlResponse.status(statusProvider())
                    queue.async {
                        do {
                            try self.writeResponse(response, to: clientFD)
                        } catch {
                            self.logger.log(
                                .warning,
                                "Control socket status response failed: \(error.localizedDescription)",
                                category: .general
                            )
                        }
                        Darwin.close(clientFD)
                    }
                }
            case .stop:
                let response = ControlResponse.ok()
                queue.async {
                    do {
                        try self.writeResponse(response, to: clientFD)
                    } catch {
                        self.logger.log(
                            .warning,
                            "Control socket stop response failed: \(error.localizedDescription)",
                            category: .general
                        )
                    }
                    Darwin.close(clientFD)
                    Task { @MainActor in
                        self.stop()
                        await self.stopHandler()
                    }
                }
            case .testUpstream:
                guard let upstreamName = request.arguments.first, !upstreamName.isEmpty else {
                    try writeResponse(.error(.missingArgument, "Missing upstream name."), to: clientFD)
                    Darwin.close(clientFD)
                    return
                }
                Task { @MainActor in
                    let result = await upstreamTestHandler(upstreamName)
                    queue.async {
                        do {
                            if let result {
                                try self.writeResponse(
                                    .upstreamTest(ControlUpstreamTestResult(result)),
                                    to: clientFD
                                )
                            } else {
                                try self.writeResponse(
                                    .error(.unknownUpstream, "Unknown upstream: \(upstreamName)"),
                                    to: clientFD
                                )
                            }
                        } catch {
                            self.logger.log(
                                .warning,
                                "Control socket upstream test response failed: \(error.localizedDescription)",
                                category: .general
                            )
                        }
                        Darwin.close(clientFD)
                    }
                }
            }
        } catch {
            do {
                try writeResponse(.error(.invalidRequest, error.localizedDescription), to: clientFD)
            } catch {
                logger.log(.warning, "Control socket error response failed: \(error.localizedDescription)", category: .general)
            }
            Darwin.close(clientFD)
        }
    }

    private static func peerIsAllowed(_ fd: Int32) -> Bool {
        var euid: uid_t = 0
        var egid: gid_t = 0
        guard getpeereid(fd, &euid, &egid) == 0 else { return false }
        return euid == geteuid()
    }

    private func readRequest(from fd: Int32) throws -> ControlRequest {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = Darwin.recv(fd, &buffer, buffer.count, 0)
            if count > 0 {
                data.append(buffer, count: count)
                if let newlineIndex = data.firstIndex(of: 0x0A) {
                    let requestData = data[..<newlineIndex]
                    guard !requestData.isEmpty else {
                        throw ControlSocketError.emptyRequest
                    }
                    guard requestData.count <= ControlSocket.maxFrameBytes else {
                        throw ControlSocketError.requestTooLarge(ControlSocket.maxFrameBytes)
                    }
                    return try JSONDecoder().decode(ControlRequest.self, from: Data(requestData))
                }
                guard data.count <= ControlSocket.maxFrameBytes else {
                    throw ControlSocketError.requestTooLarge(ControlSocket.maxFrameBytes)
                }
                continue
            }
            if count == 0 {
                guard !data.isEmpty else {
                    throw ControlSocketError.emptyRequest
                }
                return try JSONDecoder().decode(ControlRequest.self, from: data)
            }
            throw ControlSocketError.posix("recv", errno)
        }
    }

    private func writeResponse(_ response: ControlResponse, to fd: Int32) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        guard data.count <= ControlSocket.maxFrameBytes else {
            throw ControlSocketError.responseTooLarge(ControlSocket.maxFrameBytes)
        }
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                guard result > 0 else {
                    throw ControlSocketError.posix("write", errno)
                }
                bytesWritten += result
            }
        }
    }

    private func setNonBlocking(_ fd: Int32) throws {
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw ControlSocketError.posix("fcntl(F_GETFL)", errno)
        }
        guard Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw ControlSocketError.posix("fcntl(F_SETFL)", errno)
        }
    }

    private func setBlocking(_ fd: Int32) throws {
        let flags = Darwin.fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else {
            throw ControlSocketError.posix("fcntl(F_GETFL)", errno)
        }
        guard Darwin.fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) == 0 else {
            throw ControlSocketError.posix("fcntl(F_SETFL)", errno)
        }
    }

    private func setReadTimeout(_ fd: Int32, seconds: Int) throws {
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        let result = withUnsafePointer(to: &timeout) { pointer in
            Darwin.setsockopt(
                fd,
                SOL_SOCKET,
                SO_RCVTIMEO,
                pointer,
                socklen_t(MemoryLayout<timeval>.size)
            )
        }
        guard result == 0 else {
            throw ControlSocketError.posix("setsockopt(SO_RCVTIMEO)", errno)
        }
    }

    private func setNoSigPipe(_ fd: Int32) throws {
        var noSigPipe: Int32 = 1
        let result = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard result == 0 else {
            throw ControlSocketError.posix("setsockopt(SO_NOSIGPIPE)", errno)
        }
    }

    private func writePath(_ path: String, into address: inout sockaddr_un) throws {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ControlSocketError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            rawBuffer.copyBytes(from: pathBytes)
        }
    }

    private static func removeSocketFileIfPresent(_ url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        try FileManager.default.removeItem(at: url)
    }
}

private enum ControlSocketError: LocalizedError {
    case emptyRequest
    case pathTooLong(String)
    case posix(String, Int32)
    case requestTooLarge(Int)
    case responseTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .emptyRequest:
            return "Control request was empty."
        case .pathTooLong(let path):
            return "Control socket path is too long: \(path)"
        case .posix(let operation, let code):
            return "\(operation) failed: \(String(cString: strerror(code)))"
        case .requestTooLarge(let maxBytes):
            return "Control request exceeded \(maxBytes) bytes."
        case .responseTooLarge(let maxBytes):
            return "Control response exceeded \(maxBytes) bytes."
        }
    }
}
