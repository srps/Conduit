// SPDX-License-Identifier: Apache-2.0
import Foundation

package final class UDPRelay: @unchecked Sendable {
    private var listenFD: Int32 = -1
    private var forwardFD: Int32 = -1
    private var relayThread: Thread?
    private let lock = NSLock()
    private let staleTimeoutSeconds: TimeInterval = 10

    package init() {}

    package var isRunning: Bool {
        lock.withLock { listenFD >= 0 }
    }

    package func start(listenPort: Int, targetPort: Int, host: String = "127.0.0.1") throws {
        guard (0...65535).contains(listenPort) else {
            throw UDPRelayError.bindFailed(listenPort, "Port out of valid range (0-65535)")
        }
        guard (1...65535).contains(targetPort) else {
            throw UDPRelayError.bindFailed(targetPort, "Port out of valid range (1-65535)")
        }
        stop()

        let lfd = socket(AF_INET, SOCK_DGRAM, 0)
        guard lfd >= 0 else {
            throw UDPRelayError.socketCreationFailed(errnoMessage)
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
            throw UDPRelayError.bindFailed(listenPort, errnoMessage)
        }

        let ffd = socket(AF_INET, SOCK_DGRAM, 0)
        guard ffd >= 0 else {
            close(lfd)
            throw UDPRelayError.socketCreationFailed(errnoMessage)
        }

        lock.withLock {
            listenFD = lfd
            forwardFD = ffd
        }

        let thread = Thread { [weak self] in
            self?.runLoop(listenFD: lfd, forwardFD: ffd, targetPort: targetPort, targetHost: host)
        }
        thread.name = "udp-relay-\(listenPort)->\(targetPort)"
        thread.qualityOfService = .userInteractive
        thread.start()
        lock.withLock { relayThread = thread }
    }

    package func stop() {
        let (lfd, ffd, thread) = lock.withLock {
            let lfd = listenFD
            let ffd = forwardFD
            let thread = relayThread
            listenFD = -1
            forwardFD = -1
            relayThread = nil
            return (lfd, ffd, thread)
        }
        if lfd >= 0 { close(lfd) }
        if ffd >= 0 { close(ffd) }
        thread?.cancel()
    }

    private struct PendingQuery {
        var originalTXID: UInt16
        var clientAddr: sockaddr_in
        var clientLen: socklen_t
        var sentAt: Date
    }

    private func runLoop(listenFD: Int32, forwardFD: Int32, targetPort: Int, targetHost: String) {
        var buf = [UInt8](repeating: 0, count: 12_288)
        var pending: [UInt16: PendingQuery] = [:]
        var nextRelayTXID: UInt16 = 0

        var targetAddr = sockaddr_in()
        targetAddr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        targetAddr.sin_family = sa_family_t(AF_INET)
        targetAddr.sin_port = UInt16(targetPort).bigEndian
        targetAddr.sin_addr.s_addr = inet_addr(targetHost)

        var fds: [pollfd] = [
            pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0),
            pollfd(fd: forwardFD, events: Int16(POLLIN), revents: 0),
        ]

        while !Thread.current.isCancelled {
            fds[0].revents = 0
            fds[1].revents = 0
            let ready = poll(&fds, nfds_t(fds.count), 1000)
            if ready < 0 { break }

            let now = Date()
            pending = pending.filter { now.timeIntervalSince($0.value.sentAt) < staleTimeoutSeconds }

            if fds[0].revents & Int16(POLLIN) != 0 {
                var clientAddr = sockaddr_in()
                var clientLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &clientAddr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(listenFD, &buf, buf.count, 0, sockPtr, &clientLen)
                    }
                }
                if n >= 2 {
                    let originalTXID = UInt16(buf[0]) << 8 | UInt16(buf[1])
                    let relayTXID = nextAvailableRelayTXID(startingAt: &nextRelayTXID, pending: pending)
                    buf[0] = UInt8(relayTXID >> 8)
                    buf[1] = UInt8(relayTXID & 0xFF)
                    pending[relayTXID] = PendingQuery(
                        originalTXID: originalTXID,
                        clientAddr: clientAddr,
                        clientLen: clientLen,
                        sentAt: now
                    )
                    withUnsafePointer(to: &targetAddr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            _ = sendto(forwardFD, buf, n, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
                        }
                    }
                }
            }

            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = recv(forwardFD, &buf, buf.count, 0)
                if n >= 2 {
                    let relayTXID = UInt16(buf[0]) << 8 | UInt16(buf[1])
                    if var query = pending.removeValue(forKey: relayTXID) {
                        buf[0] = UInt8(query.originalTXID >> 8)
                        buf[1] = UInt8(query.originalTXID & 0xFF)
                        withUnsafePointer(to: &query.clientAddr) { ptr in
                            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                                _ = sendto(listenFD, buf, n, 0, sockPtr, query.clientLen)
                            }
                        }
                    }
                }
            }
        }
    }

    private func nextAvailableRelayTXID(startingAt next: inout UInt16, pending: [UInt16: PendingQuery]) -> UInt16 {
        for _ in 0...UInt16.max {
            let candidate = next
            next &+= 1
            if pending[candidate] == nil {
                return candidate
            }
        }
        return next
    }

    private var errnoMessage: String {
        String(cString: strerror(errno))
    }
}

package enum UDPRelayError: Error, LocalizedError {
    case socketCreationFailed(String)
    case bindFailed(Int, String)

    package var errorDescription: String? {
        switch self {
        case .socketCreationFailed(let msg):
            return "Failed to create UDP socket: \(msg)"
        case .bindFailed(let port, let msg):
            return "Failed to bind port \(port): \(msg)"
        }
    }
}
