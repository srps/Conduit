// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import ProxyKernel

/// `pm-sim dns-relay-witness` (#201). The helper's real `UDPRelay`, on an
/// ephemeral loopback port instead of :53 so no root is needed, reports
/// what a fresh query to its target finds. A forwarder that exited (the
/// crash case) is refused by the kernel at once; a port held by something
/// that never replies is silent at the bound; a target that replies is
/// answered; a stopped relay is not running. Nothing on the machine is
/// touched.
enum DNSRelayWitnessScenarios {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    static func run() throws -> ScenarioResult {
        let started = Date()
        let relay = UDPRelay()
        defer { relay.stop() }

        let closed = try boundSocket()
        let targetPort = try port(of: closed)
        close(closed)
        try relay.start(listenPort: 0, targetPort: targetPort)

        let refusedStarted = Date()
        let refused = try relay.status(boundMilliseconds: 30_000)
        let refusedSeconds = Date().timeIntervalSince(refusedStarted)

        // The same port, now held by a socket that never reads.
        let holder = try boundSocket(port: targetPort)
        defer { close(holder) }
        let silent = try relay.status()
        // The silent probe's query is still queued on the holder; the replier
        // must answer the next one.
        var drain = [UInt8](repeating: 0, count: 512)
        while recv(holder, &drain, drain.count, MSG_DONTWAIT) >= 0 {}
        // Bounds the replier's wait, so a status that never sends leaves no
        // thread blocked behind the scenario.
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        guard setsockopt(holder, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            throw Failure(description: "SO_RCVTIMEO: \(String(cString: strerror(errno)))")
        }

        let replier = Thread {
            var buffer = [UInt8](repeating: 0, count: 512)
            var peer = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let received = withUnsafeMutablePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(holder, &buffer, buffer.count, 0, $0, &length) }
            }
            guard received > 0 else { return }
            buffer[2] |= 0x80
            withUnsafePointer(to: &peer) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = sendto(holder, buffer, received, 0, $0, length) }
            }
        }
        replier.start()
        let answered = try relay.status(boundMilliseconds: 30_000)

        relay.stop()
        let stopped = try relay.status()

        return ScenarioResult(
            name: "dns-relay-witness", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(started),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a target nobody listens on is refused", refused == .relaying(targetPort: targetPort, target: .refused)),
                .init("the refusal is the kernel's answer, not the end of a 30 s bound", refusedSeconds < 10),
                .init("a port held by something that never replies is silent",
                      silent == .relaying(targetPort: targetPort, target: .silent)),
                .init("a target that replies is answered", answered == .relaying(targetPort: targetPort, target: .answered)),
                .init("a stopped relay is not running", stopped == .notRunning),
            ],
            notes: ["target=\(targetPort) refused_after_ms=\(Int(refusedSeconds * 1000)) silent_bound_ms=\(UDPRelay.statusBoundMilliseconds)"]
        )
    }

    private static func boundSocket(port: Int = 0) throws -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0 else {
            let message = String(cString: strerror(errno))
            close(fd)
            throw Failure(description: "bind 127.0.0.1:\(port): \(message)")
        }
        return fd
    }

    private static func port(of fd: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        guard rc == 0 else { throw Failure(description: "getsockname: \(String(cString: strerror(errno)))") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
