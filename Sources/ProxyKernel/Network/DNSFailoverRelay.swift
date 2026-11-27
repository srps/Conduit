// SPDX-License-Identifier: Apache-2.0
import Foundation

/// Where the fail-safe relay sends a new query (decision 0049).
package enum DNSFailoverMode: String, Equatable, Sendable {
    case conduit
    case vpn
}

/// What one probe through one half of the relay found.
package enum DNSFailoverProbeOutcome: Equatable, Sendable {
    case notRunning
    case answered
    case refused
    case silent
    /// The prober's own socket failed; it says nothing about the forwarder.
    case failed(String)
}

/// One probe through each half of the relay.
package struct DNSFailoverProbe: Equatable, Sendable {
    package var udp: DNSFailoverProbeOutcome
    package var tcp: DNSFailoverProbeOutcome

    package init(udp: DNSFailoverProbeOutcome, tcp: DNSFailoverProbeOutcome) {
        self.udp = udp
        self.tcp = tcp
    }

    package init(_ both: DNSFailoverProbeOutcome) {
        self.init(udp: both, tcp: both)
    }

    /// Answered only when both halves answered; otherwise the more telling of the two: not running, refused, silent, failed.
    package var verdict: DNSFailoverProbeOutcome {
        if udp == .answered, tcp == .answered { return .answered }
        for wanted: (DNSFailoverProbeOutcome) -> Bool in [
            { $0 == .notRunning }, { $0 == .refused }, { $0 == .silent }, { if case .failed = $0 { true } else { false } },
        ] {
            if let found = [udp, tcp].first(where: wanted) { return found }
        }
        return .refused
    }
}

/// The servers the relay may fail over to: address literals that are neither loopback nor unspecified, in order, without repeats.
package enum DNSFailoverServers {
    package static func usable(_ servers: [String]) -> [String] {
        var kept: [String] = []
        for server in servers where isUsable(server) && !kept.contains(server) {
            kept.append(server)
        }
        return kept
    }

    package static func isUsable(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let host = UInt32(bigEndian: v4.s_addr)
            return host >> 24 != 127 && host != 0
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        return withUnsafeBytes(of: &v6) { bytes in
            let unspecified = bytes.allSatisfy { $0 == 0 }
            let loopback = bytes.dropLast().allSatisfy { $0 == 0 } && bytes.last == 1
            let mapped = bytes.prefix(10).allSatisfy { $0 == 0 } && bytes[10] == 0xff && bytes[11] == 0xff
            let mappedUnusable = mapped && (bytes[12] == 127 || bytes[12...].allSatisfy { $0 == 0 })
            return !unspecified && !loopback && !mappedUnusable
        }
    }
}

/// Counters of real queries the UDP half sent to Conduit.
package struct DNSFailoverProgress: Equatable, Sendable {
    package var answered: Int
    package var unanswered: Int

    package init(answered: Int, unanswered: Int) {
        self.answered = answered
        self.unanswered = unanswered
    }
}

/// The mode and the VPN's servers that both halves of the fail-safe relay follow (decision 0049).
package final class DNSFailoverRoute: @unchecked Sendable {
    private let lock = NSLock()
    private var _mode: DNSFailoverMode = .conduit
    private var _servers: [String] = []
    private var observers: [@Sendable () -> Void] = []

    package init() {}

    package var mode: DNSFailoverMode { lock.withLock { _mode } }
    package var servers: [String] { lock.withLock { _servers } }

    package func setMode(_ mode: DNSFailoverMode) {
        let notify = lock.withLock { () -> [@Sendable () -> Void] in
            let switched = _mode == .conduit && mode == .vpn
            _mode = mode
            return switched ? observers : []
        }
        for observer in notify { observer() }
    }

    /// Loopback and unspecified addresses never become a failover target.
    package func setServers(_ servers: [String]) {
        let usable = DNSFailoverServers.usable(servers)
        lock.withLock { _servers = usable }
    }

    /// Called, outside the lock, each time the mode turns from Conduit to the VPN's servers.
    package func onSwitchToVPN(_ observer: @escaping @Sendable () -> Void) {
        lock.withLock { observers.append(observer) }
    }
}

package struct DNSFailoverEndpoint: Sendable, Equatable {
    package var host: String
    package var port: Int

    package init(host: String, port: Int) {
        self.host = host
        self.port = port
    }
}

package struct DNSFailoverTiming: Sendable {
    /// How long a query to Conduit waits, with no reply from Conduit since it was sent, before the probe.
    package var silenceBeforeProbe: Duration = .seconds(1)
    package var probeBound: Duration = .milliseconds(500)
    package var serverSpacing: Duration = .seconds(1)
    package var entryLifetime: Duration = .seconds(UDPRelay.staleTimeoutSeconds)
    package var connectTimeout: Duration = .seconds(1)
    /// How long a TCP session may take to send its first query, which picks the session's target.
    package var firstQueryTimeout: Duration = .seconds(2)
    /// The loop's wake interval while anything is pending.
    package var granularity: Duration = .milliseconds(50)

    package init() {}

    package static let standard = DNSFailoverTiming()
}

private enum FailoverSocket {
    static func address(_ endpoint: DNSFailoverEndpoint) -> (sockaddr_storage, socklen_t)? {
        guard (1...65535).contains(endpoint.port) else { return nil }
        var storage = sockaddr_storage()
        var v4 = in_addr()
        if inet_pton(AF_INET, endpoint.host, &v4) == 1 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(endpoint.port).bigEndian
            address.sin_addr = v4
            withUnsafeBytes(of: &address) { source in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, endpoint.host, &v6) == 1 {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = UInt16(endpoint.port).bigEndian
            address.sin6_addr = v6
            withUnsafeBytes(of: &address) { source in
                withUnsafeMutableBytes(of: &storage) { $0.copyMemory(from: source) }
            }
            return (storage, socklen_t(MemoryLayout<sockaddr_in6>.size))
        }
        return nil
    }

    /// A non-blocking socket connected to `endpoint`, or nil.
    static func connected(_ endpoint: DNSFailoverEndpoint, type: Int32) -> Int32? {
        guard let (resolved, length) = address(endpoint) else { return nil }
        var storage = resolved
        let fd = socket(Int32(storage.ss_family), type, 0)
        guard fd >= 0 else { return nil }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            close(fd)
            return nil
        }
        let result = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 || (type == SOCK_STREAM && errno == EINPROGRESS) else {
            close(fd)
            return nil
        }
        return fd
    }

    /// A blocking TCP socket connected within `timeoutMilliseconds`, or nil.
    static func stream(_ endpoint: DNSFailoverEndpoint, timeoutMilliseconds: Int32) -> Int32? {
        guard let fd = connected(endpoint, type: SOCK_STREAM) else { return nil }
        var readiness = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&readiness, 1, timeoutMilliseconds) == 1,
              getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0,
              fcntl(fd, F_SETFL, 0) == 0 else {
            close(fd)
            return nil
        }
        return fd
    }

    static func milliseconds(_ duration: Duration) -> Int32 {
        Int32(clamping: duration.components.seconds * 1_000 + duration.components.attoseconds / 1_000_000_000_000_000)
    }

    static func nanoseconds(_ duration: Duration) -> UInt64 {
        UInt64(clamping: duration.components.seconds) * 1_000_000_000
            + UInt64(clamping: duration.components.attoseconds / 1_000_000_000)
    }

    static func listening(port: Int, type: Int32) throws -> Int32 {
        let fd = socket(AF_INET, type, 0)
        guard fd >= 0 else { throw UDPRelayError.socketCreationFailed(String(cString: strerror(errno))) }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, type != SOCK_STREAM || listen(fd, 128) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw UDPRelayError.bindFailed(port, message)
        }
        return fd
    }

    static func port(of fd: Int32) -> Int? {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return rc == 0 ? Int(UInt16(bigEndian: address.sin_port)) : nil
    }

    static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    /// Reads one length-prefixed DNS message from a blocking stream within `timeoutMilliseconds`, or nil.
    static func readFramed(_ fd: Int32, timeoutMilliseconds: Int32) -> [UInt8]? {
        let deadline = now + UInt64(max(0, timeoutMilliseconds)) * 1_000_000
        func read(_ count: Int) -> [UInt8]? {
            var bytes = [UInt8](repeating: 0, count: count)
            var filled = 0
            while filled < count {
                let current = now
                guard current < deadline else { return nil }
                var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let ready = poll(&readiness, 1, Int32(clamping: max(1, (deadline - current) / 1_000_000)))
                if ready < 0, errno == EINTR { continue }
                guard ready > 0 else { return nil }
                let got = bytes.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + filled, count - filled, 0) }
                if got < 0, errno == EINTR { continue }
                guard got > 0 else { return nil }
                filled += got
            }
            return bytes
        }
        guard let prefix = read(2) else { return nil }
        let length = Int(prefix[0]) << 8 | Int(prefix[1])
        guard length >= 12, let message = read(length) else { return nil }
        return message
    }

    static func writeFramed(_ fd: Int32, _ message: [UInt8]) -> Bool {
        let framed = [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message
        var sent = 0
        while sent < framed.count {
            let wrote = framed.withUnsafeBytes { Darwin.send(fd, $0.baseAddress! + sent, framed.count - sent, 0) }
            if wrote < 0, errno == EINTR { continue }
            guard wrote > 0 else { return false }
            sent += wrote
        }
        return true
    }
}

/// The UDP half: forwards to Conduit's forwarder and fails each query over to the VPN's servers.
package final class DNSFailoverUDPRelay: @unchecked Sendable {
    package static let maximumPendingQueries = 1_024
    package static let maximumServersPerQuery = 3

    private let route: DNSFailoverRoute
    private let timing: DNSFailoverTiming
    private let serverEndpoint: @Sendable (String) -> DNSFailoverEndpoint
    private let droppedAtCapacity: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var conduitFD: Int32 = -1
    private var targetPort: Int?
    private var thread: Thread?
    private var generation: UInt64 = 0
    private var conduitAnswered = 0
    private var conduitUnanswered = 0

    package init(
        route: DNSFailoverRoute,
        timing: DNSFailoverTiming = .standard,
        serverEndpoint: @escaping @Sendable (String) -> DNSFailoverEndpoint = { DNSFailoverEndpoint(host: $0, port: 53) },
        droppedAtCapacity: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        self.route = route
        self.timing = timing
        self.serverEndpoint = serverEndpoint
        self.droppedAtCapacity = droppedAtCapacity
    }

    package var isRunning: Bool { lock.withLock { listenFD >= 0 } }
    package var target: Int? { lock.withLock { listenFD >= 0 ? targetPort : nil } }

    package var listeningPort: Int? {
        lock.withLock { listenFD >= 0 ? FailoverSocket.port(of: listenFD) : nil }
    }

    /// Real queries Conduit answered, and real queries sent to Conduit that it never answered (expired, or failed over
    /// on its silence), since the relay was made. Both only grow; the probe name is in neither.
    package var conduitProgress: DNSFailoverProgress {
        lock.withLock { DNSFailoverProgress(answered: conduitAnswered, unanswered: conduitUnanswered) }
    }

    package func start(listenPort: Int, targetPort: Int) throws {
        guard (0...65535).contains(listenPort) else { throw UDPRelayError.bindFailed(listenPort, "Port out of valid range (0-65535)") }
        guard (1...65535).contains(targetPort) else { throw UDPRelayError.bindFailed(targetPort, "Port out of valid range (1-65535)") }
        stop()
        let lfd = try FailoverSocket.listening(port: listenPort, type: SOCK_DGRAM)
        guard let cfd = FailoverSocket.connected(DNSFailoverEndpoint(host: "127.0.0.1", port: targetPort), type: SOCK_DGRAM) else {
            close(lfd)
            throw UDPRelayError.connectFailed(targetPort, String(cString: strerror(errno)))
        }
        let generation = lock.withLock { () -> UInt64 in
            self.generation &+= 1
            listenFD = lfd
            conduitFD = cfd
            self.targetPort = targetPort
            return self.generation
        }
        let thread = Thread { [weak self] in self?.run(generation: generation, listenFD: lfd, conduitFD: cfd) }
        thread.name = "dns-failover-udp-\(listenPort)->\(targetPort)"
        thread.qualityOfService = .userInteractive
        lock.withLock {
            if self.generation == generation { self.thread = thread }
            thread.start()
        }
    }

    package func stop() {
        let thread = lock.withLock { () -> Thread? in
            if listenFD >= 0 { close(listenFD) }
            if conduitFD >= 0 { close(conduitFD) }
            listenFD = -1
            conduitFD = -1
            targetPort = nil
            defer { self.thread = nil }
            return self.thread
        }
        thread?.cancel()
    }

    private enum Target: Hashable {
        case conduit
        case server(String)
    }

    private struct Entry {
        var originalTXID: UInt16
        var question: [UInt8]
        var datagram: [UInt8]
        var client: sockaddr_in
        var clientLength: socklen_t
        var arrived: UInt64
        /// Set while the query waits on Conduit.
        var conduitSentAt: UInt64?
        var tried: [String] = []
        var lastSentAt: UInt64 = 0
        var sentTo: Set<Target> = []
        /// The reserved probe name: asked of Conduit only, never of the VPN's servers.
        var isProbe = false
    }

    private struct Probe {
        var txID: UInt16
        var sentAt: UInt64
    }

    /// Everything here belongs to the loop's thread.
    private struct Loop {
        var pending: [UInt16: Entry] = [:]
        var probe: Probe?
        var lastConduitReply: UInt64 = 0
        var servers: [String] = []
        var sockets: [String: Int32] = [:]
        var dropped = 0
    }

    private func whileOwning<T>(_ generation: UInt64, _ lfd: Int32, _ body: () -> T) -> T? {
        lock.withLock {
            guard self.generation == generation, listenFD == lfd else { return nil }
            return body()
        }
    }

    private func run(generation: UInt64, listenFD lfd: Int32, conduitFD cfd: Int32) {
        var loop = Loop()
        var buffer = [UInt8](repeating: 0, count: 12_288)
        let idle = Int32(1_000)
        let busy = max(1, FailoverSocket.milliseconds(timing.granularity))
        while !Thread.current.isCancelled {
            refreshSockets(&loop)
            var fds = [pollfd(fd: lfd, events: Int16(POLLIN), revents: 0), pollfd(fd: cfd, events: Int16(POLLIN), revents: 0)]
            let order = loop.servers.filter { loop.sockets[$0] != nil }
            fds += order.map { pollfd(fd: loop.sockets[$0]!, events: Int16(POLLIN), revents: 0) }
            let ready = poll(&fds, nfds_t(fds.count), loop.pending.isEmpty && loop.probe == nil ? idle : busy)
            if ready < 0 {
                if errno == EINTR || errno == EAGAIN { continue }
                break
            }
            let owned: Void? = whileOwning(generation, lfd) {
                let now = FailoverSocket.now
                let mode = route.mode
                if fds[0].revents & Int16(POLLIN) != 0 { receiveQueries(&loop, &buffer, lfd: lfd, cfd: cfd, mode: mode, now: now) }
                if fds[1].revents & Int16(POLLIN | POLLERR) != 0 { receiveFromConduit(&loop, &buffer, lfd: lfd, cfd: cfd, now: now) }
                for (index, server) in order.enumerated() where fds[2 + index].revents & Int16(POLLIN | POLLERR) != 0 {
                    receiveFromServer(server, &loop, &buffer, lfd: lfd)
                }
                expire(&loop, lfd: lfd, cfd: cfd, mode: route.mode, now: now)
            }
            if owned == nil { break }
        }
        for fd in loop.sockets.values { close(fd) }
        lock.withLock {
            guard self.generation == generation, listenFD == lfd else { return }
            close(lfd)
            close(cfd)
            listenFD = -1
            conduitFD = -1
            targetPort = nil
        }
    }

    private func refreshSockets(_ loop: inout Loop) {
        let servers = Array(route.servers.prefix(Self.maximumServersPerQuery))
        guard servers != loop.servers else { return }
        for (server, fd) in loop.sockets where !servers.contains(server) {
            close(fd)
            loop.sockets[server] = nil
        }
        for server in servers where loop.sockets[server] == nil {
            loop.sockets[server] = FailoverSocket.connected(serverEndpoint(server), type: SOCK_DGRAM)
        }
        loop.servers = servers
    }

    private func receiveQueries(_ loop: inout Loop, _ buffer: inout [UInt8], lfd: Int32, cfd: Int32, mode: DNSFailoverMode, now: UInt64) {
        for _ in 0..<64 {
            var client = sockaddr_in()
            var clientLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = withUnsafeMutablePointer(to: &client) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(lfd, &buffer, buffer.count, 0, $0, &clientLength) }
            }
            guard count >= 0 else { return }
            guard count >= 12, var question = DNSWireFormat.headerAndQuestion(of: Array(buffer[0..<count])) else { continue }
            guard loop.pending.count < Self.maximumPendingQueries else {
                loop.dropped += 1
                droppedAtCapacity(loop.dropped)
                continue
            }
            let originalTXID = UInt16(buffer[0]) << 8 | UInt16(buffer[1])
            let relayTXID = freeTXID(loop)
            buffer[0] = UInt8(relayTXID >> 8)
            buffer[1] = UInt8(relayTXID & 0xFF)
            question[0] = buffer[0]
            question[1] = buffer[1]
            var entry = Entry(
                originalTXID: originalTXID, question: question, datagram: Array(buffer[0..<count]),
                client: client, clientLength: clientLength, arrived: now
            )
            entry.isProbe = DNSWireFormat.isForwarderProbe(entry.datagram)
            if entry.isProbe {
                guard sendToConduit(entry.datagram, cfd: cfd) else {
                    answerProbeRefused(entry, lfd: lfd)
                    continue
                }
                entry.conduitSentAt = now
                entry.sentTo.insert(.conduit)
            } else if mode == .conduit, sendToConduit(entry.datagram, cfd: cfd) {
                entry.conduitSentAt = now
                entry.sentTo.insert(.conduit)
            } else {
                sendToNextServer(&entry, loop: loop, now: now)
            }
            loop.pending[relayTXID] = entry
        }
    }

    private func sendToConduit(_ datagram: [UInt8], cfd: Int32) -> Bool {
        var sent = Darwin.send(cfd, datagram, datagram.count, 0)
        // A refusal left from an earlier datagram is reported on this call; it says nothing about this one.
        if sent < 0, errno == ECONNREFUSED { sent = Darwin.send(cfd, datagram, datagram.count, 0) }
        return sent == datagram.count
    }

    @discardableResult
    private func sendToNextServer(_ entry: inout Entry, loop: Loop, now: UInt64) -> Bool {
        guard entry.tried.count < Self.maximumServersPerQuery,
              let server = loop.servers.first(where: { !entry.tried.contains($0) }),
              let fd = loop.sockets[server] else { return false }
        entry.tried.append(server)
        entry.lastSentAt = now
        entry.sentTo.insert(.server(server))
        _ = Darwin.send(fd, entry.datagram, entry.datagram.count, 0)
        return true
    }

    /// A probe entry is never failed over: Conduit refused it, and its asker hears REFUSED, or Conduit was silent, and it
    /// hears nothing. A real query Conduit left unanswered on its silence counts against Conduit's progress.
    private func failOverConduitEntries(_ loop: inout Loop, now: UInt64, refused: Bool, lfd: Int32) {
        for key in Array(loop.pending.keys) where loop.pending[key]?.conduitSentAt != nil {
            guard var entry = loop.pending[key] else { continue }
            if entry.isProbe {
                loop.pending[key] = nil
                if refused { answerProbeRefused(entry, lfd: lfd) }
                continue
            }
            if !refused { conduitUnanswered += 1 }
            entry.conduitSentAt = nil
            sendToNextServer(&entry, loop: loop, now: now)
            loop.pending[key] = entry
        }
    }

    /// The prober reads REFUSED as Conduit's forward socket refusing; the forwarder itself answers the probe NXDOMAIN.
    private func answerProbeRefused(_ entry: Entry, lfd: Int32) {
        guard var answer = DNSWireFormat.emptyRefusedResponse(originalQuery: entry.datagram) else { return }
        answer[0] = UInt8(entry.originalTXID >> 8)
        answer[1] = UInt8(entry.originalTXID & 0xFF)
        var client = entry.client
        withUnsafePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(lfd, answer, answer.count, 0, $0, entry.clientLength) }
        }
    }

    private func receiveFromConduit(_ loop: inout Loop, _ buffer: inout [UInt8], lfd: Int32, cfd: Int32, now: UInt64) {
        for _ in 0..<64 {
            let count = recv(cfd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == ECONNREFUSED {
                    loop.probe = nil
                    failOverConduitEntries(&loop, now: now, refused: true, lfd: lfd)
                    continue
                }
                return
            }
            loop.lastConduitReply = now
            loop.probe = nil
            relay(Array(buffer[0..<count]), from: .conduit, &loop, lfd: lfd)
        }
    }

    private func receiveFromServer(_ server: String, _ loop: inout Loop, _ buffer: inout [UInt8], lfd: Int32) {
        guard let fd = loop.sockets[server] else { return }
        for _ in 0..<64 {
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == ECONNREFUSED {
                    for key in loop.pending.keys where loop.pending[key]?.tried.last == server {
                        loop.pending[key]?.lastSentAt = 0
                    }
                    continue
                }
                return
            }
            relay(Array(buffer[0..<count]), from: .server(server), &loop, lfd: lfd)
        }
    }

    /// The first matching reply from a target the entry was sent to ends it; any later one finds nothing.
    private func relay(_ reply: [UInt8], from target: Target, _ loop: inout Loop, lfd: Int32) {
        guard reply.count >= 12 else { return }
        let relayTXID = UInt16(reply[0]) << 8 | UInt16(reply[1])
        guard let entry = loop.pending[relayTXID], entry.sentTo.contains(target),
              DNSWireFormat.responseQuestionMatches(query: entry.question, response: reply) else { return }
        loop.pending[relayTXID] = nil
        if target == .conduit, !entry.isProbe { conduitAnswered += 1 }
        var answer = reply
        answer[0] = UInt8(entry.originalTXID >> 8)
        answer[1] = UInt8(entry.originalTXID & 0xFF)
        var client = entry.client
        withUnsafePointer(to: &client) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(lfd, answer, answer.count, 0, $0, entry.clientLength) }
        }
    }

    private func expire(_ loop: inout Loop, lfd: Int32, cfd: Int32, mode: DNSFailoverMode, now: UInt64) {
        let lifetime = FailoverSocket.nanoseconds(timing.entryLifetime)
        loop.pending = loop.pending.filter { _, entry in
            let live = now - entry.arrived < lifetime
            if !live, entry.conduitSentAt != nil, !entry.isProbe { conduitUnanswered += 1 }
            return live
        }
        if mode == .vpn {
            loop.probe = nil
            for key in Array(loop.pending.keys) where loop.pending[key].map({ $0.conduitSentAt != nil && !$0.isProbe }) == true {
                loop.pending[key]?.conduitSentAt = nil
                if var entry = loop.pending[key] {
                    sendToNextServer(&entry, loop: loop, now: now)
                    loop.pending[key] = entry
                }
            }
        }
        if let probe = loop.probe, now - probe.sentAt >= FailoverSocket.nanoseconds(timing.probeBound) {
            loop.probe = nil
            route.setMode(.vpn)
            failOverConduitEntries(&loop, now: now, refused: false, lfd: lfd)
        }
        let silence = FailoverSocket.nanoseconds(timing.silenceBeforeProbe)
        if loop.probe == nil, loop.pending.values.contains(where: { entry in
            guard let sent = entry.conduitSentAt, !entry.isProbe else { return false }
            return now - sent >= silence && loop.lastConduitReply < sent
        }) {
            let txID = freeTXID(loop)
            let query = DNSWireFormat.buildQuery(domain: DNSWireFormat.forwarderProbeDomain, txID: txID)
            if sendToConduit(query, cfd: cfd) {
                loop.probe = Probe(txID: txID, sentAt: now)
            } else {
                failOverConduitEntries(&loop, now: now, refused: true, lfd: lfd)
            }
        }
        let spacing = FailoverSocket.nanoseconds(timing.serverSpacing)
        for key in loop.pending.keys {
            guard var entry = loop.pending[key], entry.conduitSentAt == nil, !entry.isProbe,
                  entry.tried.isEmpty || now - entry.lastSentAt >= spacing else { continue }
            if sendToNextServer(&entry, loop: loop, now: now) { loop.pending[key] = entry }
        }
    }

    /// Random, so a reply cannot be forged by counting queries.
    private func freeTXID(_ loop: Loop) -> UInt16 {
        var candidate = UInt16.random(in: .min ... .max)
        for _ in 0...UInt16.max {
            if loop.pending[candidate] == nil, loop.probe?.txID != candidate { return candidate }
            candidate &+= 1
        }
        return candidate
    }
}

/// The TCP half: a session takes the mode at connect, and a session to Conduit is closed when the mode switches.
package final class DNSFailoverTCPRelay: @unchecked Sendable {
    private final class Sessions: @unchecked Sendable {
        struct Session {
            var target: Int32 = -1
            var toConduit = false
        }

        private let lock = NSLock()
        private var sessions: [Int32: Session] = [:]
        private var retired = false

        func admit(_ client: Int32, maximum: Int) -> Bool {
            lock.withLock {
                guard !retired, sessions.count < maximum else { return false }
                sessions[client] = Session()
                return true
            }
        }

        func attach(_ client: Int32, target: Int32, toConduit: Bool) -> Bool {
            lock.withLock {
                guard !retired, sessions[client] != nil else { return false }
                sessions[client] = Session(target: target, toConduit: toConduit)
                return true
            }
        }

        /// The session's own thread closes its descriptors after this; others only shut them down while registered.
        func leave(_ client: Int32) {
            lock.withLock { sessions[client] = nil }
        }

        func retire() {
            lock.withLock {
                retired = true
                for (client, session) in sessions {
                    shutdown(client, SHUT_RDWR)
                    if session.target >= 0 { shutdown(session.target, SHUT_RDWR) }
                }
            }
        }

        func closeConduitSessions() {
            lock.withLock {
                for (client, session) in sessions where session.toConduit {
                    shutdown(client, SHUT_RDWR)
                    shutdown(session.target, SHUT_RDWR)
                }
            }
        }
    }

    private let route: DNSFailoverRoute
    private let timing: DNSFailoverTiming
    private let maximumSessions: Int
    private let serverEndpoint: @Sendable (String) -> DNSFailoverEndpoint
    private let refusedAtCapacity: @Sendable (Int) -> Void
    private let lock = NSLock()
    private var listenFD: Int32 = -1
    private var targetPort: Int?
    private var thread: Thread?
    private var generation: UInt64 = 0
    private var sessions = Sessions()
    private var refusedTotal = 0

    package init(
        route: DNSFailoverRoute,
        maximumSessions: Int,
        timing: DNSFailoverTiming = .standard,
        serverEndpoint: @escaping @Sendable (String) -> DNSFailoverEndpoint = { DNSFailoverEndpoint(host: $0, port: 53) },
        refusedAtCapacity: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        precondition(maximumSessions > 0, "a relay that admits no session is not a relay")
        self.route = route
        self.timing = timing
        self.maximumSessions = maximumSessions
        self.serverEndpoint = serverEndpoint
        self.refusedAtCapacity = refusedAtCapacity
        route.onSwitchToVPN { [weak self] in
            self?.lock.withLock { self?.sessions }?.closeConduitSessions()
        }
    }

    package var isRunning: Bool { lock.withLock { listenFD >= 0 } }
    package var target: Int? { lock.withLock { listenFD >= 0 ? targetPort : nil } }

    package var listeningPort: Int? {
        lock.withLock { listenFD >= 0 ? FailoverSocket.port(of: listenFD) : nil }
    }

    package func start(listenPort: Int, targetPort: Int) throws {
        guard (0...65535).contains(listenPort) else { throw TCPRelayError.bindFailed(listenPort, "Port out of valid range (0-65535)") }
        guard (1...65535).contains(targetPort) else { throw TCPRelayError.bindFailed(targetPort, "Port out of valid range (1-65535)") }
        stop()
        let lfd = try FailoverSocket.listening(port: listenPort, type: SOCK_STREAM)
        let tracker = Sessions()
        let generation = lock.withLock { () -> UInt64 in
            self.generation &+= 1
            listenFD = lfd
            self.targetPort = targetPort
            sessions = tracker
            return self.generation
        }
        let thread = Thread { [weak self] in
            self?.acceptLoop(generation: generation, listenFD: lfd, sessions: tracker, targetPort: targetPort)
        }
        thread.name = "dns-failover-tcp-\(listenPort)->\(targetPort)"
        thread.qualityOfService = .userInteractive
        lock.withLock {
            if self.generation == generation { self.thread = thread }
            thread.start()
        }
    }

    package func stop() {
        let (thread, tracker) = lock.withLock { () -> (Thread?, Sessions) in
            if listenFD >= 0 { close(listenFD) }
            listenFD = -1
            targetPort = nil
            defer { self.thread = nil }
            return (self.thread, sessions)
        }
        thread?.cancel()
        tracker.retire()
    }

    private func acceptLoop(generation: UInt64, listenFD lfd: Int32, sessions: Sessions, targetPort: Int) {
        while !Thread.current.isCancelled {
            guard lock.withLock({ self.generation == generation && listenFD == lfd }) else { break }
            var readiness = pollfd(fd: lfd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, 1_000)
            if ready == 0 { continue }
            if ready < 0 {
                if errno == EINTR { continue }
                break
            }
            let (client, failure) = lock.withLock { () -> (Int32, Int32) in
                guard self.generation == generation, listenFD == lfd else { return (-1, EBADF) }
                return (accept(lfd, nil, nil), errno)
            }
            guard client >= 0 else {
                if [EINTR, ECONNABORTED, EAGAIN].contains(failure) { continue }
                if [EMFILE, ENFILE, ENOBUFS, ENOMEM].contains(failure) {
                    usleep(100_000)
                    continue
                }
                break
            }
            guard fcntl(client, F_SETFL, 0) == 0 else {
                close(client)
                continue
            }
            guard sessions.admit(client, maximum: maximumSessions) else {
                close(client)
                let total = lock.withLock { () -> Int in
                    refusedTotal += 1
                    return refusedTotal
                }
                refusedAtCapacity(total)
                continue
            }
            let thread = Thread { [weak self] in
                self?.serve(client, sessions: sessions, targetPort: targetPort)
            }
            thread.name = "dns-failover-tcp-session"
            thread.qualityOfService = .userInteractive
            thread.start()
        }
        lock.withLock {
            guard self.generation == generation, listenFD == lfd else { return }
            close(lfd)
            listenFD = -1
            self.targetPort = nil
        }
    }

    /// The first query picks the target: the reserved probe name goes to Conduit only, and hears REFUSED when Conduit's
    /// connect fails, so a probe measures this half and never the VPN's servers.
    private func serve(_ client: Int32, sessions: Sessions, targetPort: Int) {
        let timeout = FailoverSocket.milliseconds(timing.connectTimeout)
        guard let first = FailoverSocket.readFramed(client, timeoutMilliseconds: FailoverSocket.milliseconds(timing.firstQueryTimeout)) else {
            sessions.leave(client)
            close(client)
            return
        }
        let isProbe = DNSWireFormat.isForwarderProbe(first)
        var target: Int32?
        var toConduit = false
        if route.mode == .conduit || isProbe,
           let fd = FailoverSocket.stream(DNSFailoverEndpoint(host: "127.0.0.1", port: targetPort), timeoutMilliseconds: timeout) {
            target = fd
            toConduit = true
        }
        if target == nil, isProbe {
            if let refused = DNSWireFormat.emptyRefusedResponse(originalQuery: first) { _ = FailoverSocket.writeFramed(client, refused) }
            sessions.leave(client)
            close(client)
            return
        }
        if target == nil {
            for server in route.servers.prefix(DNSFailoverUDPRelay.maximumServersPerQuery) {
                if let fd = FailoverSocket.stream(serverEndpoint(server), timeoutMilliseconds: timeout) {
                    target = fd
                    break
                }
            }
        }
        defer { close(client) }
        guard let target else {
            sessions.leave(client)
            return
        }
        defer { close(target) }
        guard sessions.attach(client, target: target, toConduit: toConduit), isProbe || !(toConduit && route.mode == .vpn) else {
            sessions.leave(client)
            return
        }
        TCPRelay.setNoDelay(client)
        TCPRelay.setNoDelay(target)
        guard FailoverSocket.writeFramed(target, first) else {
            sessions.leave(client)
            return
        }
        TCPRelay.relayBidirectional(fd1: client, fd2: target)
        sessions.leave(client)
    }
}

/// Both halves on one port, and the probe of Conduit's forwarder (decision 0049).
package final class DNSFailoverRelay: @unchecked Sendable {
    package static let probeBoundMilliseconds = 500

    package let route: DNSFailoverRoute
    private let listenPort: Int
    private let udp: DNSFailoverUDPRelay
    private let tcp: DNSFailoverTCPRelay
    private let lock = NSLock()
    private var wantedTarget: Int?

    package init(
        listenPort: Int,
        maximumTCPSessions: Int,
        timing: DNSFailoverTiming = .standard,
        serverEndpoint: @escaping @Sendable (String) -> DNSFailoverEndpoint = { DNSFailoverEndpoint(host: $0, port: 53) },
        droppedAtCapacity: @escaping @Sendable (Int) -> Void = { _ in },
        refusedAtCapacity: @escaping @Sendable (Int) -> Void = { _ in }
    ) {
        let route = DNSFailoverRoute()
        self.route = route
        self.listenPort = listenPort
        udp = DNSFailoverUDPRelay(route: route, timing: timing, serverEndpoint: serverEndpoint, droppedAtCapacity: droppedAtCapacity)
        tcp = DNSFailoverTCPRelay(
            route: route, maximumSessions: maximumTCPSessions, timing: timing, serverEndpoint: serverEndpoint,
            refusedAtCapacity: refusedAtCapacity
        )
    }

    package var udpRunning: Bool { udp.isRunning }
    package var tcpRunning: Bool { tcp.isRunning }
    package var target: Int? { lock.withLock { wantedTarget } }

    package var listeningPort: Int? {
        guard let port = udp.listeningPort, tcp.listeningPort == port else { return nil }
        return port
    }

    package var mode: DNSFailoverMode { route.mode }
    package func setMode(_ mode: DNSFailoverMode) { route.setMode(mode) }
    package func setFailoverServers(_ servers: [String]) { route.setServers(servers) }

    /// Starts each half that is not already running for `targetPort`; returns what failed, one line per half.
    package func start(targetPort: Int) -> [String] {
        lock.withLock { wantedTarget = targetPort }
        var failures: [String] = []
        if !(udp.isRunning && udp.target == targetPort) {
            do {
                try udp.start(listenPort: listenPort, targetPort: targetPort)
            } catch {
                failures.append("udp: \(error.localizedDescription)")
            }
        }
        if !(tcp.isRunning && tcp.target == targetPort) {
            do {
                try tcp.start(listenPort: udp.listeningPort ?? listenPort, targetPort: targetPort)
            } catch {
                failures.append("tcp: \(error.localizedDescription)")
            }
        }
        return failures
    }

    /// Restarts a half that left on its own, for the target the other half still has.
    package func restartDeadHalves() -> (restarted: Bool, failures: [String]) {
        guard let target, !(udp.isRunning && tcp.isRunning) else { return (false, []) }
        return (true, start(targetPort: target))
    }

    package func stop() {
        lock.withLock { wantedTarget = nil }
        udp.stop()
        tcp.stop()
    }

    /// Asks the reserved probe name through the relay's own UDP and TCP listener, as the system resolver reaches it.
    /// The relay sends that name to Conduit only, so an answer is the forwarder's NXDOMAIN with the query's ID and
    /// question; REFUSED from the relay, or any other answer, is a refusal.
    package func probe() -> DNSFailoverProbe {
        guard let port = listeningPort else { return DNSFailoverProbe(udp: .notRunning, tcp: .notRunning) }
        return DNSFailoverProbe(
            udp: Self.probeUDP(port: port, boundMilliseconds: Self.probeBoundMilliseconds),
            tcp: Self.probeTCP(port: port, boundMilliseconds: Self.probeBoundMilliseconds)
        )
    }

    package var conduitProgress: DNSFailoverProgress { udp.conduitProgress }

    static func verdict(_ response: [UInt8], to query: [UInt8]) -> DNSFailoverProbeOutcome? {
        guard response.count >= 12, response[2] & 0x80 != 0, DNSWireFormat.isResponse(response, to: query) else { return nil }
        return DNSWireFormat.extractRCode(from: response) == 3 ? .answered : .refused
    }

    static func probeUDP(port: Int, boundMilliseconds: Int) -> DNSFailoverProbeOutcome {
        guard let fd = FailoverSocket.connected(DNSFailoverEndpoint(host: "127.0.0.1", port: port), type: SOCK_DGRAM) else {
            return .failed("udp: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        let query = DNSWireFormat.buildQuery(domain: DNSWireFormat.forwarderProbeDomain, txID: UInt16.random(in: .min ... .max))
        guard Darwin.send(fd, query, query.count, 0) == query.count else {
            return errno == ECONNREFUSED ? .refused : .failed("udp send: \(String(cString: strerror(errno)))")
        }
        let deadline = FailoverSocket.now + UInt64(boundMilliseconds) * 1_000_000
        var buffer = [UInt8](repeating: 0, count: 512)
        while true {
            let now = FailoverSocket.now
            guard now < deadline else { return .silent }
            var readiness = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&readiness, 1, Int32(clamping: max(1, (deadline - now) / 1_000_000)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return .silent }
            let count = recv(fd, &buffer, buffer.count, 0)
            if count < 0 {
                if errno == EAGAIN || errno == EINTR { continue }
                return errno == ECONNREFUSED ? .refused : .failed("udp recv: \(String(cString: strerror(errno)))")
            }
            if let verdict = verdict(Array(buffer[0..<count]), to: query) { return verdict }
        }
    }

    /// A session the relay closes without an answer, at its session cap say, is a refusal.
    static func probeTCP(port: Int, boundMilliseconds: Int) -> DNSFailoverProbeOutcome {
        let began = FailoverSocket.now
        guard let fd = FailoverSocket.connected(DNSFailoverEndpoint(host: "127.0.0.1", port: port), type: SOCK_STREAM) else {
            return errno == ECONNREFUSED ? .refused : .failed("tcp: \(String(cString: strerror(errno)))")
        }
        defer { close(fd) }
        var readiness = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard poll(&readiness, 1, Int32(boundMilliseconds)) == 1 else { return .silent }
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            return error == ECONNREFUSED ? .refused : .failed("tcp connect: \(String(cString: strerror(error)))")
        }
        guard fcntl(fd, F_SETFL, 0) == 0 else { return .failed("tcp: \(String(cString: strerror(errno)))") }
        let query = DNSWireFormat.buildQuery(domain: DNSWireFormat.forwarderProbeDomain, txID: UInt16.random(in: .min ... .max))
        guard FailoverSocket.writeFramed(fd, query) else { return .refused }
        let spent = Int((FailoverSocket.now - began) / 1_000_000)
        let left = Int32(max(1, boundMilliseconds - spent))
        var peek = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&peek, 1, left) == 1 else { return .silent }
        guard let response = FailoverSocket.readFramed(fd, timeoutMilliseconds: left) else { return .refused }
        return verdict(response, to: query) ?? .refused
    }
}
