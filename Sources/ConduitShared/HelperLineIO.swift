// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Line I/O for the helper's one-request-per-connection socket, bounded by a
/// deadline on the whole transfer rather than on each read. Both ends use
/// it: the helper for a peer, the app for the helper.
///
/// The helper serves one connection at a time. A receive timeout alone let a
/// peer that sent one byte every few seconds hold it for as long as the size
/// ceiling allowed; progress must not extend the time a peer is given. The
/// deadline is monotonic, so a wall-clock change cannot stretch it either.
/// Nothing here blocks past it: readiness comes from `poll` with the time
/// that is left, and the descriptor is made nonblocking so the transfer
/// itself never waits. `MSG_DONTWAIT` is not enough: Darwin does not honour
/// it for a send on a Unix stream socket that exceeds the buffer.
public enum HelperLineIO {
    public enum ReadResult: Equatable, Sendable {
        /// Bytes up to the newline, or up to end-of-stream if the peer closed
        /// after sending some without one.
        case line(Data)
        /// The peer closed without sending anything.
        case empty
        case tooLarge
        case deadlineExceeded
        case failed(Int32)
    }

    /// Monotonic nanoseconds.
    public static func now() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

    public static func deadline(afterMilliseconds milliseconds: Int, from start: UInt64 = now()) -> UInt64 {
        start &+ UInt64(max(milliseconds, 0)) &* 1_000_000
    }

    /// One request per connection: bytes after the newline are not kept.
    public static func readLine(fd: Int32, deadline: UInt64, maxBytes: Int) -> ReadResult {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        guard makeNonblocking(fd) else { return .failed(errno) }
        while true {
            if let failure = waitUntilReady(fd, for: Int16(POLLIN), deadline: deadline) { return failure }
            let count = recv(fd, &chunk, chunk.count, 0)
            if count == 0 { return line.isEmpty ? .empty : .line(line) }
            if count < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                return .failed(errno)
            }
            if let newline = chunk[..<count].firstIndex(of: UInt8(ascii: "\n")) {
                line.append(contentsOf: chunk[..<newline])
                return line.count > maxBytes ? .tooLarge : .line(line)
            }
            line.append(contentsOf: chunk[..<count])
            if line.count > maxBytes { return .tooLarge }
        }
    }

    /// False if the deadline passed or the peer went away before every byte
    /// was accepted. Never raises SIGPIPE by itself; the helper ignores it.
    public static func writeAll(fd: Int32, _ data: Data, deadline: UInt64) -> Bool {
        var offset = 0
        guard makeNonblocking(fd) else { return false }
        while offset < data.count {
            if waitUntilReady(fd, for: Int16(POLLOUT), deadline: deadline) != nil { return false }
            let sent = data.withUnsafeBytes { raw in
                send(fd, raw.baseAddress!.advanced(by: offset), data.count - offset, 0)
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if sent < 0 && (errno == EINTR || errno == EAGAIN) { continue }
            return false
        }
        return true
    }

    /// Connects a Unix stream socket, giving up at the deadline. Nil on
    /// success, otherwise the `errno`, with `ETIMEDOUT` for the deadline. A
    /// blocking `connect` waits for room in the listener's backlog, which a
    /// helper held by another peer never makes.
    package static func connect(fd: Int32, path: String, deadline: UInt64) -> Int32? {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { return ENAMETOOLONG }
        path.withCString { source in
            withUnsafeMutableBytes(of: &address.sun_path) { buffer in
                _ = strlcpy(buffer.baseAddress!.assumingMemoryBound(to: CChar.self), source, capacity)
            }
        }
        guard makeNonblocking(fd) else { return errno }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        if result == 0 { return nil }
        guard errno == EINPROGRESS || errno == EINTR else { return errno }
        switch waitUntilReady(fd, for: Int16(POLLOUT), deadline: deadline) {
        case .deadlineExceeded: return ETIMEDOUT
        case .failed(let code): return code
        default: break
        }
        var pending: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &pending, &length) == 0 else { return errno }
        return pending == 0 ? nil : pending
    }

    private static func makeNonblocking(_ fd: Int32) -> Bool {
        let flags = fcntl(fd, F_GETFL)
        return flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
    }

    /// Nil once `fd` is ready. A hang-up still counts as ready: the transfer
    /// that follows reports end-of-stream or the error.
    private static func waitUntilReady(_ fd: Int32, for events: Int16, deadline: UInt64) -> ReadResult? {
        while true {
            let current = now()
            guard current < deadline else { return .deadlineExceeded }
            // Rounded up, so a sub-millisecond remainder cannot spin.
            let milliseconds = min((deadline - current + 999_999) / 1_000_000, UInt64(Int32.max))
            var readiness = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&readiness, 1, Int32(milliseconds))
            if ready > 0 { return nil }
            if ready < 0 && errno != EINTR { return .failed(errno) }
        }
    }
}
