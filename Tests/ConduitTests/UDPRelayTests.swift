// SPDX-License-Identifier: Apache-2.0
import Foundation
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

    func testRelayStartTwiceStopsFirst() throws {
        let relay = UDPRelay()
        let portA = randomHighPort()
        let portB = portA + 10
        try relay.start(listenPort: portA, targetPort: portA + 1)
        XCTAssertTrue(relay.isRunning)
        try relay.start(listenPort: portB, targetPort: portB + 1)
        XCTAssertTrue(relay.isRunning)
        relay.stop()
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

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
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

        let payload: [UInt8] = [0x01, 0x02]
        let response = sendAndReceiveUDP(host: "127.0.0.1", port: listenPort, payload: payload, timeoutSec: 2)

        XCTAssertNil(response, "Should timeout when target is not listening")
        XCTAssertTrue(relay.isRunning, "Relay should still be running after timeout")
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
                    let txidHi = UInt8(i >> 8)
                    let txidLo = UInt8(i & 0xFF)
                    let payload: [UInt8] = [txidHi, txidLo, 0xCA, 0xFE]
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
        sendAndReceiveUDPImpl(host: host, port: port, payload: payload, timeoutSec: timeoutSec)
    }

    private func sendAndReceiveUDP(host: String, port: Int, payload: [UInt8], timeoutSec: Int) -> [UInt8]? {
        Self.sendAndReceiveUDPImpl(host: host, port: port, payload: payload, timeoutSec: timeoutSec)
    }

    private static func sendAndReceiveUDPImpl(host: String, port: Int, payload: [UInt8], timeoutSec: Int) -> [UInt8]? {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        var tv = timeval(tv_sec: timeoutSec, tv_usec: 0)
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
