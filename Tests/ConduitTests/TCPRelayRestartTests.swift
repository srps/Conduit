// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

/// Twin of `UDPRelayTests.testRelayStartTwiceStopsFirst` for the TCP relay,
/// which had the same descriptor-identified `markDead` (#37).
final class TCPRelayRestartTests: XCTestCase {
    func testASecondStartSurvivesTheEvictedAcceptLoop() throws {
        let relay = TCPRelay()
        let portA = Int.random(in: 19000..<20000)
        let portB = portA + 10
        try relay.start(listenPort: portA, targetPort: portA + 1, host: "127.0.0.1")
        XCTAssertTrue(relay.isRunning)
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
