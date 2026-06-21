// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class TunnelHealthProbeTests: XCTestCase {

    func testTunnelBindingInfoDefaultsToHealthy() {
        let binding = TunnelBindingInfo(
            label: "Test",
            localHost: "127.0.0.1",
            localPort: 5432,
            remoteHost: "db.example.com",
            remotePort: 5432,
            proxied: true
        )
        XCTAssertTrue(binding.healthy)
    }

    func testTunnelBindingInfoCodableRoundTripWithHealth() throws {
        var binding = TunnelBindingInfo(
            label: "Test",
            localHost: "127.0.0.1",
            localPort: 5432,
            remoteHost: "db.example.com",
            remotePort: 5432,
            proxied: true
        )
        binding.healthy = false

        let data = try JSONEncoder().encode(binding)
        let decoded = try JSONDecoder().decode(TunnelBindingInfo.self, from: data)
        XCTAssertFalse(decoded.healthy)
        XCTAssertEqual(decoded.label, "Test")
    }

    func testHealthProberStartStop() {
        let prober = TunnelHealthProber()
        let expectation = XCTestExpectation(description: "probe callback")
        expectation.isInverted = true

        prober.start(interval: 100, tunnels: { [] }, onResult: { _ in
            expectation.fulfill()
        })

        prober.stop()
        wait(for: [expectation], timeout: 0.5)
    }

    func testHealthProberDetectsListeningPort() throws {
        let prober = TunnelHealthProber()
        let expectation = XCTestExpectation(description: "probe runs")

        let serverFD = socket(AF_INET, SOCK_STREAM, 0)
        guard serverFD >= 0 else { throw XCTSkip("Cannot create socket") }
        defer { close(serverFD) }

        var one: Int32 = 1
        setsockopt(serverFD, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(serverFD, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else { throw XCTSkip("Cannot bind") }
        listen(serverFD, 1)

        var bound = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        withUnsafeMutablePointer(to: &bound) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(serverFD, sockPtr, &len)
            }
        }
        let port = Int(UInt16(bigEndian: bound.sin_port))
        let probeID = UUID()

        prober.start(interval: 0.1, tunnels: {
            [(id: probeID, host: "127.0.0.1", port: port)]
        }, onResult: { results in
            if let healthy = results[probeID] {
                XCTAssertTrue(healthy, "Listening port should be healthy")
                expectation.fulfill()
            }
        })

        wait(for: [expectation], timeout: 3)
        prober.stop()
    }

    func testHealthProberDetectsClosedPort() {
        let prober = TunnelHealthProber()
        let expectation = XCTestExpectation(description: "probe detects closed")
        let probeID = UUID()

        prober.start(interval: 0.1, tunnels: {
            [(id: probeID, host: "127.0.0.1", port: 19999)]
        }, onResult: { results in
            if let healthy = results[probeID] {
                XCTAssertFalse(healthy, "Non-listening port should be unhealthy")
                expectation.fulfill()
            }
        })

        wait(for: [expectation], timeout: 5)
        prober.stop()
    }

    /// Regression guard for the data race between the timer handler running on
    /// the prober's internal queue and `stop()` being called from the main
    /// thread. Run with `--sanitize=thread` to catch concurrent read/write on
    /// `onResult` / `timer`.
    func testHealthProberStopRaceStress() {
        for _ in 0..<50 {
            let prober = TunnelHealthProber()
            let probeID = UUID()
            prober.start(interval: 0.001, tunnels: {
                // Port 1 reliably ECONNREFUSES quickly on loopback, so the
                // handler actually reaches the `onResult?` read on most ticks.
                [(id: probeID, host: "127.0.0.1", port: 1)]
            }, onResult: { _ in })
            Thread.sleep(forTimeInterval: 0.005)
            prober.stop()
        }
    }
}
