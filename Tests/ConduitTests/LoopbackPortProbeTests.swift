// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import XCTest
@testable import PlatformMac

/// The probe that decides whether proxy settings left on the machine are
/// orphaned or still being served. It replaced an `lsof` subprocess whose
/// hardcoded path stopped existing on macOS 26, so it is worth testing against
/// a real socket rather than a fake.
final class LoopbackPortProbeTests: XCTestCase {

    func testDetectsAListeningSocket() throws {
        let (fd, port) = try makeListener()
        defer { close(fd) }

        XCTAssertTrue(LoopbackPortProbe.isServed(port: port))
    }

    /// The case that matters: after a crash the recorded settings point at a
    /// port nothing serves, and only that makes them safe to restore.
    func testReportsAClosedPortAsUnserved() throws {
        let (fd, port) = try makeListener()
        close(fd)

        XCTAssertFalse(LoopbackPortProbe.isServed(port: port))
    }

    func testRejectsPortsOutsideTheValidRange() {
        XCTAssertFalse(LoopbackPortProbe.isServed(port: 0))
        XCTAssertFalse(LoopbackPortProbe.isServed(port: -1))
        XCTAssertFalse(LoopbackPortProbe.isServed(port: 65_536))
    }

    /// Binds `127.0.0.1:0` and returns the port the kernel assigned.
    private func makeListener() throws -> (Int32, Int) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        try XCTSkipIf(fd < 0, "could not open a socket in this environment")

        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian

        let bound = withUnsafePointer(to: &addr) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                Darwin.bind(fd, sockPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 1) == 0 else {
            close(fd)
            throw XCTSkip("could not bind a loopback listener in this environment")
        }

        var assigned = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &assigned) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPointer in
                getsockname(fd, sockPointer, &length)
            }
        }
        guard named == 0 else {
            close(fd)
            throw XCTSkip("could not read back the bound port")
        }
        return (fd, Int(assigned.sin_port.bigEndian))
    }
}
