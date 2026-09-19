// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import ProxyKernel

/// Twin of `UDPRelayTests.testRelayStartTwiceStopsFirst` for the TCP relay,
/// which had the same descriptor-identified `markDead` (#37).
final class TCPRelayRestartTests: XCTestCase {
    /// stop used to close descriptors between registration and thread.start.
    /// The late-started worker could then read sockets assigned to somebody
    /// else. Hold exactly that interleaving, without probabilistic FD churn.
    func testStopRetainsDescriptorsUntilLateStartingWorkerExits() throws {
        let registered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let descriptors = NIOLockedValueBox<(Int32, Int32)?>(nil)
        let relay = TCPRelay(sessionWillStart: { client, target in
            descriptors.withLockedValue { $0 = (client, target) }
            registered.signal()
            _ = release.wait(timeout: .now() + 5)
        }, sessionDidStop: { finished.signal() })
        defer { release.signal(); relay.stop() }
        let target = listen(on: 0)
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { if target >= 0 { close(target) } }
        try relay.start(listenPort: 0, targetPort: try boundPort(target), host: "127.0.0.1")
        let client = connect(to: try XCTUnwrap(relay.listeningPort))
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { if client >= 0 { close(client) } }
        XCTAssertEqual(registered.wait(timeout: .now() + 2), .success)
        let (ownedClient, ownedTarget) = try XCTUnwrap(descriptors.withLockedValue { $0 })

        relay.stop()
        XCTAssertFalse(relay.isRunning)
        XCTAssertNotEqual(fcntl(ownedClient, F_GETFD), -1, "stop must not recycle a worker's client FD")
        XCTAssertNotEqual(fcntl(ownedTarget, F_GETFD), -1, "stop must not recycle a worker's target FD")
        release.signal()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "late-started worker must release both descriptors")
        // Completion is emitted after both closes. Do not inspect their old
        // numbers now: another thread is allowed to reuse them at this point.
    }

    func testStopWakesAnIdleSessionAndItsOwnerClosesIt() throws {
        let finished = DispatchSemaphore(value: 0)
        let relay = TCPRelay(sessionDidStop: { finished.signal() })
        defer { relay.stop() }
        let target = listen(on: 0)
        XCTAssertGreaterThanOrEqual(target, 0)
        defer { if target >= 0 { close(target) } }
        try relay.start(listenPort: 0, targetPort: try boundPort(target), host: "127.0.0.1")
        let client = connect(to: try XCTUnwrap(relay.listeningPort))
        XCTAssertGreaterThanOrEqual(client, 0)
        defer { if client >= 0 { close(client) } }
        var readiness = pollfd(fd: target, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&readiness, 1, 2000), 1)
        let accepted = accept(target, nil, nil)
        XCTAssertGreaterThanOrEqual(accepted, 0)
        defer { if accepted >= 0 { close(accepted) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(accepted, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let payload: [UInt8] = [1, 2, 3, 4, 5]
        XCTAssertEqual(payload.withUnsafeBytes { send(client, $0.baseAddress, $0.count, 0) }, payload.count)
        // Prove the worker actually forwarded before stopping it; a signal
        // before thread.start would only retest the late-start case above.
        for expected in payload {
            var byte: UInt8 = 0
            XCTAssertEqual(recv(accepted, &byte, 1, 0), 1)
            XCTAssertEqual(byte, expected)
        }
        relay.stop()
        XCTAssertEqual(finished.wait(timeout: .now() + 2), .success, "stop must wake idle I/O, not wait for the client")
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

    func testASecondStartSurvivesTheEvictedAcceptLoop() throws {
        let relay = TCPRelay()
        let portA = Int.random(in: 19000..<20000)
        let portB = portA + 10
        try relay.start(listenPort: portA, targetPort: portA + 1, host: "127.0.0.1")
        XCTAssertTrue(relay.isRunning)

        // Leave a session open on the first relay so the restart evicts a
        // live session thread, whose descriptors the second relay's
        // sessions are then handed. Its tracker is its own; it must not
        // close what the second relay registered under the same numbers.
        let firstTarget = listen(on: portA + 1)
        XCTAssertTrue(firstTarget >= 0)
        defer { close(firstTarget) }
        let firstClient = connect(to: portA)
        XCTAssertTrue(firstClient >= 0)
        defer { close(firstClient) }
        var firstProbe = pollfd(fd: firstTarget, events: Int16(POLLIN), revents: 0)
        XCTAssertEqual(poll(&firstProbe, 1, 2000), 1, "the first relay must relay before the restart")
        let firstAccepted = accept(firstTarget, nil, nil)
        XCTAssertTrue(firstAccepted >= 0)
        defer { if firstAccepted >= 0 { close(firstAccepted) } }

        try relay.start(listenPort: portB, targetPort: portB + 1, host: "127.0.0.1")
        XCTAssertTrue(relay.isRunning)
        defer { relay.stop() }

        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(relay.isRunning, "the evicted accept loop must not take its successor down with it")

        // Every connection to the second listener must reach the second
        // target. An evicted accept loop still blocked on the reissued
        // descriptor number would win some of these accepts and relay them
        // to the first target, where nothing listens.
        let targetFD = listen(on: portB + 1)
        XCTAssertTrue(targetFD >= 0, "target listener: \(String(cString: strerror(errno)))")
        defer { close(targetFD) }
        for attempt in 1...5 {
            let fd = connect(to: portB)
            XCTAssertTrue(fd >= 0, "connect \(attempt): \(String(cString: strerror(errno)))")
            defer { close(fd) }
            var probe = pollfd(fd: targetFD, events: Int16(POLLIN), revents: 0)
            XCTAssertEqual(poll(&probe, 1, 2000), 1, "connection \(attempt) never reached the second target")
            let accepted = accept(targetFD, nil, nil)
            XCTAssertTrue(accepted >= 0)
            if accepted >= 0 { close(accepted) }
        }
    }

    private func listen(on port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var addr = loopback(port: port)
        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 8) == 0 else { close(fd); return -1 }
        return fd
    }

    private func connect(to port: Int) -> Int32 {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return -1 }
        var addr = loopback(port: port)
        let rc = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.connect(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard rc == 0 else { close(fd); return -1 }
        return fd
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
