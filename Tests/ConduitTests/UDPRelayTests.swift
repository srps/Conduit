// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class UDPRelayTests: XCTestCase {

    // MARK: - Start / Stop

    func testRelayStartsAndReportsRunning() throws {
        let relay = UDPRelay()
        let port = randomHighPort()
        try relay.start(listenPort: port, targetPort: port + 1)
        XCTAssertTrue(relay.isRunning)
        relay.stop()
        XCTAssertFalse(relay.isRunning)
    }

    func testRelayStopIsIdempotent() {
        let relay = UDPRelay()
        relay.stop()
        relay.stop()
        XCTAssertFalse(relay.isRunning)
    }

    /// `stop()` closes the first loop's descriptors and the second start is
    /// handed the same numbers back. The evicted loop reports itself dead a
    /// moment later; identified by descriptor it would close its successor's
    /// sockets and flip `isRunning` (#37, seen on CI as a flake).
    func testRelayStartTwiceStopsFirst() throws {
        let relay = UDPRelay()
        let portA = randomHighPort()
        let portB = portA + 10
        try relay.start(listenPort: portA, targetPort: portA + 1)
        XCTAssertTrue(relay.isRunning)
        try relay.start(listenPort: portB, targetPort: portB + 1)
        XCTAssertTrue(relay.isRunning)
        defer { relay.stop() }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(relay.isRunning, "the evicted loop must not take its successor down with it")

        let echoFD = createUDPSocket(port: portB + 1)
        XCTAssertTrue(echoFD >= 0, "Failed to create echo socket")
        defer { close(echoFD) }
        let echoThread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(echoFD, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }
            if n > 0 {
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        _ = sendto(echoFD, buf, n, 0, sockPtr, addrLen)
                    }
                }
            }
        }
        echoThread.start()

        let payload = DNSWireFormat.buildQuery(domain: "second.example", txID: 0x0001)
        let response = sendAndReceiveUDP(host: "127.0.0.1", port: portB, payload: payload, timeoutSec: 3)
        XCTAssertEqual(response, payload, "the second relay must still forward after the first loop has left")
    }

    /// stop used to close both descriptors while the loop could sit between
    /// poll and recvfrom. The numbers go to the next socket opened, and the
    /// loop then read that socket's datagram and forwarded it to its target.
    /// Hold exactly that interleaving, without probabilistic FD churn.
    func testEvictedLoopDoesNotReadADescriptorReusedAfterStop() throws {
        let ready = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let exited = DispatchSemaphore(value: 0)
        let serviced = NIOLockedValueBox<(Int32, Int32)?>(nil)
        let relay = UDPRelay(willServiceDescriptors: { listen, forward in
            let first = serviced.withLockedValue { value -> Bool in
                defer { value = value ?? (listen, forward) }
                return value == nil
            }
            guard first else { return }
            ready.signal()
            _ = release.wait(timeout: .now() + 5)
        }, loopDidExit: { exited.signal() })
        defer { release.signal(); relay.stop() }

        let target = createUDPSocket(port: 0)
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { if target >= 0 { close(target) } }
        XCTAssertEqual(fcntl(target, F_SETFL, O_NONBLOCK), 0)
        try relay.start(listenPort: 0, targetPort: try boundPort(target))
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        XCTAssertGreaterThanOrEqual(sender, 0)
        defer { if sender >= 0 { close(sender) } }

        send(from: sender, to: try XCTUnwrap(relay.listeningPort), [0x12, 0x34, 0xAA])
        XCTAssertEqual(ready.wait(timeout: .now() + 2), .success, "loop must report readiness before any I/O")
        let (evictedListenFD, _) = try XCTUnwrap(serviced.withLockedValue { $0 })

        relay.stop()
        XCTAssertFalse(relay.isRunning)

        // The lowest free number is handed out first; keep anything else
        // aside until the evicted loop's listen descriptor comes back.
        var spares: [Int32] = []
        defer { for fd in spares { close(fd) } }
        var victim: Int32 = -1
        while victim < 0, spares.count < 64 {
            let fd = createUDPSocket(port: 0)
            XCTAssertGreaterThanOrEqual(fd, 0)
            if fd == evictedListenFD { victim = fd } else { spares.append(fd) }
        }
        XCTAssertEqual(victim, evictedListenFD, "stop must have released the listen descriptor's number")
        defer { if victim >= 0 { close(victim) } }
        XCTAssertEqual(fcntl(victim, F_SETFL, O_NONBLOCK), 0)

        let payload: [UInt8] = [0xCA, 0xFE, 0xF0, 0x0D]
        send(from: sender, to: try boundPort(victim), payload)
        var readiness = pollfd(fd: victim, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&readiness, 1, 2000), 1)

        release.signal()
        XCTAssertEqual(exited.wait(timeout: .now() + 3), .success, "an evicted loop must leave")

        var buf = [UInt8](repeating: 0, count: 64)
        let n = recv(victim, &buf, buf.count, 0)
        XCTAssertEqual(n > 0 ? Array(buf[0..<n]) : nil, payload, "the evicted loop must not consume another socket's datagram")
        XCTAssertEqual(recv(target, &buf, buf.count, 0), -1, "nothing may be forwarded after stop")
    }

    private func boundPort(_ fd: Int32) throws -> Int {
        var address = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let rc = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        XCTAssertEqual(rc, 0)
        return Int(UInt16(bigEndian: address.sin_port))
    }

    private func send(from fd: Int32, to port: Int, _ payload: [UInt8]) {
        XCTAssertEqual(Self.sendDatagram(from: fd, to: port, payload), payload.count)
    }

    /// Static so a `@Sendable` closure can send without capturing the test case.
    private static func sendDatagram(from fd: Int32, to port: Int, _ payload: [UInt8]) -> Int {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                sendto(fd, payload, payload.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }

    func testRelayFailsOnPortConflict() throws {
        let relay1 = UDPRelay()
        let relay2 = UDPRelay()
        let port = randomHighPort()
        try relay1.start(listenPort: port, targetPort: port + 1)
        XCTAssertThrowsError(try relay2.start(listenPort: port, targetPort: port + 1))
        relay1.stop()
        relay2.stop()
    }

    func testStopFreesPort() throws {
        let relay = UDPRelay()
        let port = randomHighPort()
        try relay.start(listenPort: port, targetPort: port + 1)
        relay.stop()

        let relay2 = UDPRelay()
        try relay2.start(listenPort: port, targetPort: port + 1)
        XCTAssertTrue(relay2.isRunning)
        relay2.stop()
    }

    func testRelayRejectsOverflowPort() {
        let relay = UDPRelay()
        defer { relay.stop() }
        XCTAssertThrowsError(try relay.start(listenPort: 70000, targetPort: 1234))
        XCTAssertThrowsError(try relay.start(listenPort: 1234, targetPort: 70000))
    }

    func testRelayRejectsNegativeAndZeroTargetPort() {
        let relay = UDPRelay()
        defer { relay.stop() }
        XCTAssertThrowsError(try relay.start(listenPort: -1, targetPort: 1234))
        XCTAssertThrowsError(try relay.start(listenPort: 1234, targetPort: 0))
        XCTAssertThrowsError(try relay.start(listenPort: 1234, targetPort: -5))
    }

    // MARK: - Forwarding

    func testRelayForwardsUDPPacket() throws {
        let listenPort = randomHighPort()
        let targetPort = listenPort + 1

        let echoFD = createUDPSocket(port: targetPort)
        XCTAssertTrue(echoFD >= 0, "Failed to create echo socket")

        let relay = UDPRelay()
        try relay.start(listenPort: listenPort, targetPort: targetPort)

        let echoThread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(echoFD, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }
            if n > 0 {
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        _ = sendto(echoFD, buf, n, 0, sockPtr, addrLen)
                    }
                }
            }
        }
        echoThread.start()

        let payload = DNSWireFormat.buildQuery(domain: "forward.example", txID: 0xDEAD)
        let response = sendAndReceiveUDP(host: "127.0.0.1", port: listenPort, payload: payload, timeoutSec: 3)

        relay.stop()
        close(echoFD)

        XCTAssertNotNil(response, "Should receive a response through the relay")
        XCTAssertEqual(response, payload, "Response should match sent payload")
    }

    func testRelayHandlesTargetTimeout() throws {
        let listenPort = randomHighPort()
        let targetPort = listenPort + 1

        let relay = UDPRelay()
        try relay.start(listenPort: listenPort, targetPort: targetPort)

        // Nothing listens on the target, so nothing comes back. Any reply the
        // relay made up would arrive in well under this wait on loopback.
        let payload = DNSWireFormat.buildQuery(domain: "unanswered.example", txID: 0x0102)
        let response = Self.sendAndReceiveUDPImpl(
            host: "127.0.0.1", port: listenPort, payload: payload, timeoutMS: 200
        )

        XCTAssertNil(response, "Should timeout when target is not listening")
        XCTAssertTrue(relay.isRunning, "Relay should still be running after timeout")

        // And it still relays: once the target listens, the next query is
        // answered through the same relay.
        let echoFD = createUDPSocket(port: targetPort)
        XCTAssertTrue(echoFD >= 0, "Failed to create echo socket")
        defer { close(echoFD) }
        let echoThread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                    recvfrom(echoFD, &buf, buf.count, 0, sockPtr, &addrLen)
                }
            }
            if n > 0 {
                withUnsafePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        _ = sendto(echoFD, buf, n, 0, sockPtr, addrLen)
                    }
                }
            }
        }
        echoThread.start()
        let later = DNSWireFormat.buildQuery(domain: "later.example", txID: 0x0304)
        XCTAssertEqual(
            sendAndReceiveUDP(host: "127.0.0.1", port: listenPort, payload: later, timeoutSec: 3), later,
            "The relay must keep forwarding after a query its target never answered"
        )
        relay.stop()
    }

    // MARK: - Concurrent queries (transaction ID correlation)

    func testRelayConcurrentQueriesCorrelateCorrectly() async throws {
        let listenPort = randomHighPort()
        let targetPort = listenPort + 1

        let echoFD = createUDPSocket(port: targetPort)
        XCTAssertTrue(echoFD >= 0, "Failed to create echo socket")

        let echoThread = Thread {
            var buf = [UInt8](repeating: 0, count: 4096)
            for _ in 0..<3 {
                var addr = sockaddr_in()
                var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
                let n = withUnsafeMutablePointer(to: &addr) { ptr in
                    ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                        recvfrom(echoFD, &buf, buf.count, 0, sockPtr, &addrLen)
                    }
                }
                if n > 0 {
                    withUnsafePointer(to: &addr) { ptr in
                        ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                            _ = sendto(echoFD, buf, n, 0, sockPtr, addrLen)
                        }
                    }
                }
            }
        }
        echoThread.start()

        let relay = UDPRelay()
        try relay.start(listenPort: listenPort, targetPort: targetPort)

        let responses = await withTaskGroup(of: (Int, [UInt8]?).self) { group in
            for i: UInt16 in 0..<3 {
                let port = listenPort
                group.addTask {
                    let payload = DNSWireFormat.buildQuery(domain: "q\(i).example", txID: i)
                    let response = Self.sendAndReceiveUDPStatic(host: "127.0.0.1", port: port, payload: payload, timeoutSec: 3)
                    return (Int(i), response)
                }
            }
            var results: [Int: [UInt8]?] = [:]
            for await (idx, response) in group {
                results[idx] = response
            }
            return results
        }

        relay.stop()
        close(echoFD)

        for i in 0..<3 {
            let response = responses[i] ?? nil
            XCTAssertNotNil(response, "Query \(i) should receive a response")
            if let response, response.count >= 2 {
                let rxTxid = UInt16(response[0]) << 8 | UInt16(response[1])
                XCTAssertEqual(rxTxid, UInt16(i), "Response transaction ID should match query \(i)")
            }
        }
    }

    // MARK: - Response binding

    /// Only the target may answer. Another local process that finds the
    /// forward socket's port and sends a reply with the pending relay ID first
    /// must not reach the client.
    func testReplyFromAnotherSenderIsDiscarded() throws {
        let target = createUDPSocket(port: 0)
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { close(target) }
        let relay = UDPRelay()
        try relay.start(listenPort: 0, targetPort: try boundPort(target))
        defer { relay.stop() }

        let forger = createUDPSocket(port: 0)
        XCTAssertGreaterThanOrEqual(forger, 0)
        defer { close(forger) }

        let query = DNSWireFormat.buildQuery(domain: "bank.example", txID: 0x4242)
        let answer = respondingTarget(target) { relayed, forwardPort in
            // NXDOMAIN with the right ID and question, from the wrong socket.
            var forged = relayed
            forged[2] |= 0x80
            forged[3] = (forged[3] & 0xF0) | 3
            XCTAssertEqual(Self.sendDatagram(from: forger, to: forwardPort, forged), forged.count)
            Thread.sleep(forTimeInterval: 0.1)
            var genuine = relayed
            genuine[2] |= 0x80
            return genuine
        }

        let response = try XCTUnwrap(
            sendAndReceiveUDP(host: "127.0.0.1", port: try XCTUnwrap(relay.listeningPort), payload: query, timeoutSec: 3)
        )
        answer.join()
        XCTAssertEqual(Array(response[0..<2]), [0x42, 0x42], "the client's own transaction ID must come back")
        XCTAssertEqual(DNSWireFormat.extractRCode(from: response), 0, "the forged NXDOMAIN must not be relayed")
    }

    /// A reply carrying the pending relay ID but another question is not the
    /// answer to this query, even from the target.
    func testReplyWithAnotherQuestionIsDiscarded() throws {
        let target = createUDPSocket(port: 0)
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { close(target) }
        let relay = UDPRelay()
        try relay.start(listenPort: 0, targetPort: try boundPort(target))
        defer { relay.stop() }

        let query = DNSWireFormat.buildQuery(domain: "asked.example", txID: 0x0707)
        let answer = respondingTarget(target) { relayed, _ in
            var wrong = DNSWireFormat.buildQuery(domain: "other.example", txID: 0)
            wrong[0] = relayed[0]
            wrong[1] = relayed[1]
            wrong[2] |= 0x80
            return wrong
        }

        let response = sendAndReceiveUDP(
            host: "127.0.0.1", port: try XCTUnwrap(relay.listeningPort), payload: query, timeoutSec: 1
        )
        answer.join()
        XCTAssertNil(response, "an answer to another question must not reach the client")
    }

    func testNonDNSDatagramIsNotRelayed() throws {
        let target = createUDPSocket(port: 0)
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { close(target) }
        XCTAssertEqual(fcntl(target, F_SETFL, O_NONBLOCK), 0)
        let relay = UDPRelay()
        try relay.start(listenPort: 0, targetPort: try boundPort(target))
        defer { relay.stop() }

        XCTAssertNil(sendAndReceiveUDP(
            host: "127.0.0.1", port: try XCTUnwrap(relay.listeningPort), payload: [0xDE, 0xAD, 0xBE, 0xEF], timeoutSec: 1
        ))
        var buf = [UInt8](repeating: 0, count: 64)
        XCTAssertEqual(recv(target, &buf, buf.count, 0), -1, "a datagram with no question must not be forwarded")
    }

    private final class Responder: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        func join() { _ = done.wait(timeout: .now() + 5) }
    }

    /// Reads one relayed query on `target` and sends back what `reply` makes
    /// of it, given the query and the relay's forward-socket port.
    private func respondingTarget(_ target: Int32, reply: @escaping @Sendable ([UInt8], Int) -> [UInt8]) -> Responder {
        let responder = Responder()
        let thread = Thread {
            defer { responder.done.signal() }
            var tv = timeval(tv_sec: 3, tv_usec: 0)
            setsockopt(target, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var buf = [UInt8](repeating: 0, count: 4096)
            var addr = sockaddr_in()
            var addrLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            let n = withUnsafeMutablePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { recvfrom(target, &buf, buf.count, 0, $0, &addrLen) }
            }
            guard n > 0 else { return }
            let response = reply(Array(buf[0..<n]), Int(UInt16(bigEndian: addr.sin_port)))
            withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(target, response, response.count, 0, $0, addrLen)
                }
            }
        }
        thread.start()
        return responder
    }

    // MARK: - Helpers

    private func randomHighPort() -> Int {
        Int.random(in: 17000..<18000)
    }

    private func createUDPSocket(port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return -1 }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard result == 0 else { close(fd); return -1 }
        return fd
    }

    private static func sendAndReceiveUDPStatic(host: String, port: Int, payload: [UInt8], timeoutSec: Int) -> [UInt8]? {
        sendAndReceiveUDPImpl(host: host, port: port, payload: payload, timeoutMS: timeoutSec * 1000)
    }

    private func sendAndReceiveUDP(host: String, port: Int, payload: [UInt8], timeoutSec: Int) -> [UInt8]? {
        Self.sendAndReceiveUDPImpl(host: host, port: port, payload: payload, timeoutMS: timeoutSec * 1000)
    }

    private static func sendAndReceiveUDPImpl(host: String, port: Int, payload: [UInt8], timeoutMS: Int) -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutMS / 1000, tv_usec: Int32(timeoutMS % 1000) * 1000)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)

        withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                _ = sendto(fd, payload, payload.count, 0, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        var buf = [UInt8](repeating: 0, count: 4096)
        let n = recv(fd, &buf, buf.count, 0)
        guard n > 0 else { return nil }
        return Array(buf[0..<n])
    }
}
