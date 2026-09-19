// SPDX-License-Identifier: Apache-2.0
import Foundation

private final class TCPRelaySessionFDTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var activeFDs: Set<Int32> = []
    private var retired = false

    var isRetired: Bool { lock.withLock { retired } }

    /// False once `retire()` has run: an accept that completed after the
    /// relay was stopped must not start a session nobody will stop.
    func insert(_ fd1: Int32, _ fd2: Int32) -> Bool {
        lock.withLock {
            guard !retired else { return false }
            activeFDs.insert(fd1)
            activeFDs.insert(fd2)
            return true
        }
    }

    func takeOwnership(of fd1: Int32, _ fd2: Int32) -> (ownsFD1: Bool, ownsFD2: Bool) {
        lock.withLock {
            let ownsFD1 = activeFDs.remove(fd1) != nil
            let ownsFD2 = activeFDs.remove(fd2) != nil
            return (ownsFD1, ownsFD2)
        }
    }

    func retire() {
        lock.withLock {
            retired = true
            // Wake blocked I/O, but leave close ownership with the worker.
            // Closing here permits descriptor reuse while a worker is between
            // poll and recv/send (or has not even started yet). Shutdown runs
            // under the same lock as removal, so it cannot hit a reused FD.
            for fd in activeFDs { shutdown(fd, SHUT_RDWR) }
        }
    }
}

package final class TCPRelay: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var acceptThread: Thread?
    /// See `UDPRelay.generation`.
    private var generation: UInt64 = 0
    private let lock = NSLock()
    /// One tracker per start. A session evicted by `stop()` still exits on
    /// its own and asks its tracker whether it owns its descriptors; with a
    /// tracker shared across starts it would find the next relay's sessions
    /// registered under the same numbers and close them.
    private var sessionFDTracker = TCPRelaySessionFDTracker()
    private let sessionWillStart: @Sendable (Int32, Int32) -> Void
    private let sessionDidStop: @Sendable () -> Void

    /// Hooks delimit worker ownership for deterministic lifecycle tests. They
    /// are called once per session, never from the per-byte forwarding loop.
    package init(
        sessionWillStart: @escaping @Sendable (Int32, Int32) -> Void = { _, _ in },
        sessionDidStop: @escaping @Sendable () -> Void = {}
    ) {
        self.sessionWillStart = sessionWillStart
        self.sessionDidStop = sessionDidStop
    }

    package var listeningPort: Int? {
        lock.withLock {
            guard listenFD >= 0 else { return nil }
            var address = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let rc = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listenFD, $0, &length) }
            }
            return rc == 0 ? Int(UInt16(bigEndian: address.sin_port)) : nil
        }
    }

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
        // accept is performed under the lifecycle lock, so it must never
        // block. poll may race close/reuse, but its result is validated under
        // that lock before the descriptor is used for any actual I/O.
        guard fcntl(lfd, F_SETFL, O_NONBLOCK) == 0 else {
            let message = errnoMessage
            close(lfd)
            throw TCPRelayError.listenFailed(message)
        }

        let tracker = TCPRelaySessionFDTracker()
        let generation = lock.withLock { () -> UInt64 in
            self.generation &+= 1
            listenFD = lfd
            sessionFDTracker = tracker
            return self.generation
        }

        let thread = Thread { [weak self] in
            self?.acceptLoop(generation: generation, listenFD: lfd, tracker: tracker, targetPort: targetPort, targetHost: host)
        }
        thread.name = "tcp-relay-\(listenPort)->\(targetPort)"
        thread.qualityOfService = .userInteractive
        lock.withLock {
            if self.generation == generation, listenFD == lfd { acceptThread = thread }
            thread.start()
        }
    }

    package func stop() {
        let (thread, tracker) = lock.withLock {
            let lfd = listenFD
            let thread = acceptThread
            let tracker = sessionFDTracker
            listenFD = -1
            acceptThread = nil
            // Serializes close with the generation check + nonblocking accept.
            if lfd >= 0 { close(lfd) }
            return (thread, tracker)
        }
        thread?.cancel()
        tracker.retire()
    }

    /// The accept loop has left on its own. Close the listener so
    /// `isRunning` says so — the helper consults it before answering a start
    /// with "already running", and a dead relay that still looked alive was
    /// invisible to every recovery path. The generation check keeps a loop
    /// that `stop()` evicted from closing the descriptor a later `start()`
    /// was handed with the same number.
    private func markDead(generation: UInt64, _ lfd: Int32) {
        let owned = lock.withLock { () -> Bool in
            guard self.generation == generation, listenFD == lfd else { return false }
            listenFD = -1
            return true
        }
        if owned { close(lfd) }
    }

    private func acceptLoop(
        generation: UInt64,
        listenFD: Int32,
        tracker: TCPRelaySessionFDTracker,
        targetPort: Int,
        targetHost: String
    ) {
        while !Thread.current.isCancelled {
            guard lock.withLock({ self.generation == generation && self.listenFD == listenFD }) else { break }
            var readiness = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
            // The timeout only bounds how long an evicted loop lingers after
            // stop. Nothing waits for it, and it revalidates under the lock
            // before accepting. One idle wakeup a second, as in `UDPRelay`.
            let ready = poll(&readiness, 1, 1000)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            var clientAddr = sockaddr_in()
            var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let (clientFD, acceptError) = lock.withLock { () -> (Int32, Int32) in
                guard self.generation == generation, self.listenFD == listenFD else { return (-1, EBADF) }
                let fd = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        accept(listenFD, sockPtr, &clientLen)
                    }
                }
                return (fd, errno)
            }
            guard clientFD >= 0 else {
                let err = acceptError
                if err == EINTR || err == ECONNABORTED || err == EAGAIN { continue }
                if err == EMFILE || err == ENFILE || err == ENOBUFS || err == ENOMEM {
                    // Exhaustion is a moment, not the end: sessions close
                    // and descriptors come back. Leaving on it left a bound
                    // listener nobody accepted on — SYNs completed into the
                    // backlog, so even a connect probe called it healthy.
                    usleep(100_000)
                    continue
                }
                break
            }
            // Darwin may inherit O_NONBLOCK from the listener. Session I/O
            // remains blocking and is interrupted with shutdown, not close.
            guard fcntl(clientFD, F_SETFL, 0) == 0 else {
                close(clientFD)
                continue
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

            guard tracker.insert(clientFD, targetFD) else {
                // stop() retired this tracker while the accept or the target
                // connect was in flight.
                close(clientFD)
                close(targetFD)
                break
            }

            startSession(clientFD: clientFD, targetFD: targetFD, tracker: tracker)
        }
        markDead(generation: generation, listenFD)
    }

    private func startSession(clientFD: Int32, targetFD: Int32, tracker: TCPRelaySessionFDTracker) {
        let onStop = sessionDidStop
        let thread = Thread {
            if !tracker.isRetired {
                Self.relayBidirectional(fd1: clientFD, fd2: targetFD)
            }
            let (relayOwnsClient, relayOwnsTarget) = tracker.takeOwnership(of: clientFD, targetFD)
            if relayOwnsClient { close(clientFD) }
            if relayOwnsTarget { close(targetFD) }
            onStop()
        }
        thread.name = "tcp-relay-session"
        thread.qualityOfService = .userInteractive
        sessionWillStart(clientFD, targetFD)
        // Always start the owner, even after stop: it must close its FDs.
        // Shutdown (not Thread.cancel) wakes live session I/O, and retired
        // trackers prevent late-started sessions from forwarding anything.
        thread.start()
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
