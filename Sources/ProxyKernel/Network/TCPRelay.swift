// SPDX-License-Identifier: Apache-2.0
import Foundation

private final class TCPRelaySessionFDTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeFDs: Set<Int32> = []

    func insert(_ fd1: Int32, _ fd2: Int32) {
        lock.withLock {
            activeFDs.insert(fd1)
            activeFDs.insert(fd2)
        }
    }

    func takeOwnership(of fd1: Int32, _ fd2: Int32) -> (ownsFD1: Bool, ownsFD2: Bool) {
        lock.withLock {
            let ownsFD1 = activeFDs.remove(fd1) != nil
            let ownsFD2 = activeFDs.remove(fd2) != nil
            return (ownsFD1, ownsFD2)
        }
    }

    func takeAll() -> Set<Int32> {
        lock.withLock {
            let sessionFDs = activeFDs
            activeFDs.removeAll()
            return sessionFDs
        }
    }
}

package final class TCPRelay: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    private let lock = NSLock()
    private let sessionFDTracker = TCPRelaySessionFDTracker()
    private var clientThreads: [Thread] = []

    package init() {}

    package var isRunning: Bool {
        lock.withLock { listenFD >= 0 }
    }

    package func start(listenPort: Int, targetPort: Int, host: String = "127.44.3.0") throws {
        guard (0...65535).contains(listenPort) else {
            throw TCPRelayError.bindFailed(listenPort, "Port out of valid range (0-65535)")
        }
        guard (1...65535).contains(targetPort) else {
            throw TCPRelayError.bindFailed(targetPort, "Port out of valid range (1-65535)")
        }
        guard Self.isAllowedBindHost(host) else {
            throw TCPRelayError.bindFailed(listenPort, "Bind host must be loopback-only")
        }
        stop()

        let lfd = socket(AF_INET, SOCK_STREAM, 0)
        guard lfd >= 0 else {
            throw TCPRelayError.socketCreationFailed(errnoMessage)
        }

        var reuse: Int32 = 1
        setsockopt(lfd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var bindAddr = sockaddr_in()
        bindAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        bindAddr.sin_family = sa_family_t(AF_INET)
        bindAddr.sin_port = UInt16(listenPort).bigEndian
        bindAddr.sin_addr.s_addr = inet_addr(host)

        let bindResult = withUnsafePointer(to: &bindAddr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(lfd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            close(lfd)
            throw TCPRelayError.bindFailed(listenPort, errnoMessage)
        }

        guard listen(lfd, 128) == 0 else {
            close(lfd)
            throw TCPRelayError.listenFailed(errnoMessage)
        }

        lock.withLock { listenFD = lfd }

        let thread = Thread { [weak self] in
            self?.acceptLoop(listenFD: lfd, targetPort: targetPort, targetHost: host)
        }
        thread.name = "tcp-relay-\(listenPort)->\(targetPort)"
        thread.qualityOfService = .userInteractive
        thread.start()
        lock.withLock { acceptThread = thread }
    }

    package func stop() {
        let (lfd, thread, threads) = lock.withLock {
            let lfd = listenFD
            let thread = acceptThread
            let threads = clientThreads
            listenFD = -1
            acceptThread = nil
            clientThreads.removeAll()
            return (lfd, thread, threads)
        }
        let sessionFDs = sessionFDTracker.takeAll()
        if lfd >= 0 { close(lfd) }
        thread?.cancel()
        for t in threads { t.cancel() }
        for fd in sessionFDs {
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
    }

    private func acceptLoop(listenFD: Int32, targetPort: Int, targetHost: String) {
        while !Thread.current.isCancelled {
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let clientFD = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    accept(listenFD, sockPtr, &clientLen)
                }
            }
            guard clientFD >= 0 else {
                if errno == EINTR { continue }
                break
            }

            let targetFD = socket(AF_INET, SOCK_STREAM, 0)
            guard targetFD >= 0 else {
                close(clientFD)
                continue
            }

            var targetAddr = sockaddr_in()
            targetAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            targetAddr.sin_family = sa_family_t(AF_INET)
            targetAddr.sin_port = UInt16(targetPort).bigEndian
            targetAddr.sin_addr.s_addr = inet_addr(targetHost)

            let connectResult = withUnsafePointer(to: &targetAddr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    Darwin.connect(targetFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard connectResult == 0 else {
                close(clientFD)
                close(targetFD)
                continue
            }

            // TCP_NODELAY on both legs. This relay is one hop of the
            // transparent-intercept chain (client → :443 relay → transparent
            // proxy → upstream); with Nagle enabled, the many small TLS
            // records of interactive HTTP/2 streams get held for the
            // delayed-ACK timer on every hop and streaming visibly stutters
            // (Cursor reported "responses are being buffered by a proxy").
            Self.setNoDelay(clientFD)
            Self.setNoDelay(targetFD)

            sessionFDTracker.insert(clientFD, targetFD)

            let sessionFDTracker = sessionFDTracker
            let thread = Thread { [sessionFDTracker] in
                Self.relayBidirectional(fd1: clientFD, fd2: targetFD)
                let (relayOwnsClient, relayOwnsTarget) = sessionFDTracker.takeOwnership(of: clientFD, targetFD)
                if relayOwnsClient { close(clientFD) }
                if relayOwnsTarget { close(targetFD) }
            }
            thread.name = "tcp-relay-session"
            thread.qualityOfService = .userInteractive
            thread.start()
            lock.withLock { clientThreads.append(thread) }
        }
    }

    private static func relayBidirectional(fd1: Int32, fd2: Int32) {
        var buf1 = [UInt8](repeating: 0, count: 32_768)
        var buf2 = [UInt8](repeating: 0, count: 32_768)

        var fds: [pollfd] = [
            pollfd(fd: fd1, events: Int16(POLLIN), revents: 0),
            pollfd(fd: fd2, events: Int16(POLLIN), revents: 0),
        ]

        while !Thread.current.isCancelled {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, nfds_t(2), 30_000)
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            if ready == 0 { continue }

            if fds[0].revents & Int16(POLLIN) != 0 {
                let n = recv(fd1, &buf1, buf1.count, 0)
                if n <= 0 { break }
                guard Self.sendAll(fd2, buf1, n) else { break }
            }
            if fds[0].revents & Int16(POLLHUP | POLLERR) != 0 { break }

            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = recv(fd2, &buf2, buf2.count, 0)
                if n <= 0 { break }
                guard Self.sendAll(fd1, buf2, n) else { break }
            }
            if fds[1].revents & Int16(POLLHUP | POLLERR) != 0 { break }
        }
    }

    /// Writes the full `count` bytes, looping on short writes and EINTR.
    /// A short `send` silently dropping the tail would corrupt the relayed
    /// TLS stream (the peer sees a MAC failure and resets).
    private static func sendAll(_ fd: Int32, _ buffer: [UInt8], _ count: Int) -> Bool {
        var offset = 0
        while offset < count {
            let sent = buffer.withUnsafeBytes { raw in
                send(fd, raw.baseAddress!.advanced(by: offset), count - offset, 0)
            }
            if sent > 0 {
                offset += sent
                continue
            }
            if sent < 0 && errno == EINTR { continue }
            return false
        }
        return true
    }

    private static func setNoDelay(_ fd: Int32) {
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        // Defense in depth alongside the daemon-wide SIG_IGN: a peer reset
        // between poll() and send() must never raise SIGPIPE.
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    private static func isAllowedBindHost(_ host: String) -> Bool {
        host == "127.0.0.1" || host == "127.44.3.0"
    }

    private var errnoMessage: String {
        String(cString: strerror(errno))
    }
}

package enum TCPRelayError: Error, LocalizedError {
    case socketCreationFailed(String)
    case bindFailed(Int, String)
    case listenFailed(String)

    package var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let msg):
            return "Failed to create TCP socket: \(msg)"
        case .bindFailed(let port, let msg):
            return "Failed to bind port \(port): \(msg)"
        case .listenFailed(let msg):
            return "Failed to listen: \(msg)"
        }
    }
}
