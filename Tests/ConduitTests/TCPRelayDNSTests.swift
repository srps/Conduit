// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

final class TCPRelayDNSTests: XCTestCase {
    func testALengthPrefixedQueryReachesTheTargetAndALargeAnswerComesBack() throws {
        let target = listenLoopback()
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { if target >= 0 { close(target) } }
        let query = Self.query(id: 0x4C2A)
        let answer = Self.answer(id: 0x4C2A, bytes: 67 * 16 + 40)
        let received = NIOLockedValueBox<[UInt8]?>(nil)
        let served = DispatchSemaphore(value: 0)
        Thread {
            defer { served.signal() }
            let accepted = accept(target, nil, nil)
            guard accepted >= 0 else { return }
            defer { close(accepted) }
            Self.setTimeout(accepted)
            guard let message = Self.readMessage(accepted) else { return }
            received.withLockedValue { $0 = message }
            _ = Self.sendAll(accepted, Self.framed(answer))
        }.start()

        let relay = TCPRelay(maximumSessions: 64)
        defer { relay.stop() }
        try relay.start(listenPort: 0, targetPort: try boundPort(target), host: "127.0.0.1")
        let client = connectLoopback(try XCTUnwrap(relay.listeningPort))
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { if client >= 0 { close(client) } }
        Self.setTimeout(client)

        XCTAssertTrue(Self.sendAll(client, Self.framed(query)))
        XCTAssertEqual(Self.readMessage(client), answer, "the whole answer, in one length-prefixed message")
        XCTAssertEqual(served.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(received.withLockedValue { $0 }, query, "the target read the query as the client framed it")
    }

    func testAConnectionPastTheCapIsClosedUnansweredAndCounted() throws {
        let target = listenLoopback()
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { if target >= 0 { close(target) } }
        let started = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let refusals = NIOLockedValueBox<[Int]>([])
        let relay = TCPRelay(
            maximumSessions: 1,
            refusedAtCapacity: { total in refusals.withLockedValue { $0.append(total) } },
            sessionWillStart: { _, _ in started.signal() },
            sessionDidStop: { stopped.signal() }
        )
        defer { relay.stop() }
        try relay.start(listenPort: 0, targetPort: try boundPort(target), host: "127.0.0.1")
        let port = try XCTUnwrap(relay.listeningPort)

        let first = connectLoopback(port)
        XCTAssertGreaterThanOrEqual(first, 0)
        XCTAssertEqual(started.wait(timeout: .now() + 2), .success)
        let firstAccepted = accept(target, nil, nil)
        XCTAssertGreaterThanOrEqual(firstAccepted, 0)
        defer { if firstAccepted >= 0 { close(firstAccepted) } }

        let second = connectLoopback(port)
        XCTAssertGreaterThanOrEqual(second, 0)
        defer { if second >= 0 { close(second) } }
        Self.setTimeout(second)
        var byte: UInt8 = 0
        XCTAssertLessThanOrEqual(recv(second, &byte, 1, 0), 0, "the relay closes a connection past its cap")
        XCTAssertEqual(refusals.withLockedValue { $0 }, [1])
        var pending = pollfd(fd: target, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&pending, 1, 200), 0, "no target connection was spent on it")

        close(first)
        XCTAssertEqual(stopped.wait(timeout: .now() + 2), .success)
        let third = connectLoopback(port)
        XCTAssertGreaterThanOrEqual(third, 0)
        defer { if third >= 0 { close(third) } }
        XCTAssertEqual(poll(&pending, 1, 2000), 1, "a session's end frees its place")
        let thirdAccepted = accept(target, nil, nil)
        XCTAssertGreaterThanOrEqual(thirdAccepted, 0)
        if thirdAccepted >= 0 { close(thirdAccepted) }
        XCTAssertTrue(relay.isRunning, "refusing at the cap leaves the listener up")
    }

    private static func query(id: UInt16) -> [UInt8] {
        var bytes: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x01, 0x00, 0, 1, 0, 0, 0, 0, 0, 0]
        for label in ["example", "internal"] {
            bytes.append(UInt8(label.utf8.count))
            bytes.append(contentsOf: label.utf8)
        }
        bytes.append(contentsOf: [0, 0, 1, 0, 1])
        return bytes
    }

    private static func answer(id: UInt16, bytes: Int) -> [UInt8] {
        var answer: [UInt8] = [UInt8(id >> 8), UInt8(id & 0xFF), 0x81, 0x80, 0, 1, 0, 67, 0, 0, 0, 0]
        answer.append(contentsOf: (0..<(bytes - answer.count)).map { UInt8($0 % 251) })
        return answer
    }

    private static func framed(_ message: [UInt8]) -> [UInt8] {
        [UInt8(message.count >> 8), UInt8(message.count & 0xFF)] + message
    }

    private static func readMessage(_ fd: Int32) -> [UInt8]? {
        guard let prefix = readExactly(fd, 2) else { return nil }
        return readExactly(fd, Int(prefix[0]) << 8 | Int(prefix[1]))
    }

    private static func readExactly(_ fd: Int32, _ count: Int) -> [UInt8]? {
        var buffer = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let n = buffer.withUnsafeMutableBytes { recv(fd, $0.baseAddress!.advanced(by: offset), count - offset, 0) }
            guard n > 0 else { return nil }
            offset += n
        }
        return buffer
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeBytes { send(fd, $0.baseAddress!.advanced(by: offset), bytes.count - offset, 0) }
            guard n > 0 else { return false }
            offset += n
        }
        return true
    }

    private static func setTimeout(_ fd: Int32) {
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    private func listenLoopback() -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = loopback(port: 0)
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return -1 }
        return fd
    }

    private func connectLoopback(_ port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = loopback(port: port)
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard rc == 0 else { close(fd); return -1 }
        return fd
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

    private func loopback(port: Int) -> sockaddr_in {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        return addr
    }
}
