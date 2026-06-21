// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation

public struct DaemonClient: Sendable {
    public let socketPath: String
    public let maxFrameBytes: Int

    public init(socketPath: String, maxFrameBytes: Int = ControlSocket.maxFrameBytes) {
        precondition(maxFrameBytes > 0, "DaemonClient maxFrameBytes must be positive")
        self.socketPath = socketPath
        self.maxFrameBytes = maxFrameBytes
    }

    public init(stateDirectory: URL, maxFrameBytes: Int = ControlSocket.maxFrameBytes) {
        self.init(socketPath: ControlSocket.path(in: stateDirectory), maxFrameBytes: maxFrameBytes)
    }

    public func start() throws {
        try expectOK(send(.start), fallbackMessage: "Daemon refused start request.")
    }

    public func stop() throws {
        try expectOK(send(.stop), fallbackMessage: "Daemon refused stop request.")
    }

    public func reload() throws {
        try expectOK(send(.reload), fallbackMessage: "Daemon refused reload request.")
    }

    public func setProfile(_ profileName: String) throws {
        try expectOK(
            send(.setProfile, arguments: [profileName]),
            fallbackMessage: "Daemon refused profile switch request."
        )
    }

    public func status() throws -> ControlDaemonStatus {
        let response = try send(.status)
        guard response.success, let status = response.status else {
            throw DaemonClientError.daemon(
                response.errorCode ?? .internalError,
                response.errorMessage ?? "Daemon returned an empty status response."
            )
        }
        return status
    }

    public func testUpstream(named upstreamName: String) throws -> ControlUpstreamTestResult {
        let response = try send(.testUpstream, arguments: [upstreamName])
        guard response.success, let result = response.upstreamTest else {
            throw DaemonClientError.daemon(
                response.errorCode ?? .internalError,
                response.errorMessage ?? "Daemon returned an empty upstream test response."
            )
        }
        return result
    }

    public func send(_ command: ControlCommand, arguments: [String] = []) throws -> ControlResponse {
        try send(ControlRequest(command: command, arguments: arguments))
    }

    public func send(_ request: ControlRequest) throws -> ControlResponse {
        let fd = try connect()
        defer { Darwin.close(fd) }

        let requestData = try Self.encodeRequestFrame(request, maxFrameBytes: maxFrameBytes)
        try writeAll(requestData, to: fd)
        Darwin.shutdown(fd, SHUT_WR)

        let responseData = try readResponseFrame(from: fd)
        return try JSONDecoder().decode(ControlResponse.self, from: responseData)
    }

    public static func encodeRequestFrame(
        _ request: ControlRequest,
        maxFrameBytes: Int = ControlSocket.maxFrameBytes
    ) throws -> Data {
        var data = try JSONEncoder().encode(request)
        data.append(0x0A)
        guard data.count <= maxFrameBytes else {
            throw DaemonClientError.requestTooLarge(maxFrameBytes)
        }
        return data
    }

    private func expectOK(_ response: ControlResponse, fallbackMessage: String) throws {
        guard response.success else {
            throw DaemonClientError.daemon(
                response.errorCode ?? .internalError,
                response.errorMessage ?? fallbackMessage
            )
        }
    }

    private func connect() throws -> Int32 {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw DaemonClientError.posix("socket", errno)
        }

        var noSigPipe: Int32 = 1
        let noSigPipeResult = Darwin.setsockopt(
            fd,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )
        guard noSigPipeResult == 0 else {
            Darwin.close(fd)
            throw DaemonClientError.posix("setsockopt(SO_NOSIGPIPE)", errno)
        }

        do {
            var address = sockaddr_un()
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            address.sun_family = sa_family_t(AF_UNIX)
            try Self.writePath(socketPath, into: &address)

            let result = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
                    Darwin.connect(fd, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard result == 0 else {
                throw DaemonClientError.posix("connect \(socketPath)", errno)
            }
            return fd
        } catch {
            Darwin.close(fd)
            throw error
        }
    }

    private func writeAll(_ data: Data, to fd: Int32) throws {
        try data.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var bytesWritten = 0
            while bytesWritten < data.count {
                let result = Darwin.write(fd, baseAddress.advanced(by: bytesWritten), data.count - bytesWritten)
                guard result > 0 else {
                    throw DaemonClientError.posix("write", errno)
                }
                bytesWritten += result
            }
        }
    }

    private func readResponseFrame(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: min(maxFrameBytes, 16 * 1024))
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                data.append(buffer, count: count)
                guard data.count <= maxFrameBytes else {
                    throw DaemonClientError.responseTooLarge(maxFrameBytes)
                }
                continue
            }
            if count == 0 {
                break
            }
            throw DaemonClientError.posix("read", errno)
        }
        guard !data.isEmpty else {
            throw DaemonClientError.emptyResponse
        }
        if data.last == 0x0A {
            data.removeLast()
        }
        return data
    }

    private static func writePath(_ path: String, into address: inout sockaddr_un) throws {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw DaemonClientError.pathTooLong(path)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { rawBuffer in
            for index in rawBuffer.indices {
                rawBuffer[index] = 0
            }
            rawBuffer.copyBytes(from: pathBytes)
        }
    }
}

public enum DaemonClientError: LocalizedError, Sendable, Equatable {
    case daemon(ControlErrorCode, String)
    case emptyResponse
    case pathTooLong(String)
    case posix(String, Int32)
    case requestTooLarge(Int)
    case responseTooLarge(Int)

    public var errorDescription: String? {
        switch self {
        case .daemon(let code, let message):
            return "\(code.rawValue): \(message)"
        case .emptyResponse:
            return "Daemon returned an empty response."
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
