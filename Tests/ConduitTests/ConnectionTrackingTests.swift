// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ProxyKernel

final class ConnectionTrackingTests: XCTestCase {

    // MARK: - ConnectionActivity

    func testConnectionActivityDefaultsToZeroBytes() {
        let activity = ConnectionActivity(connectionID: UUID())
        XCTAssertEqual(activity.bytesSent, 0)
        XCTAssertEqual(activity.bytesReceived, 0)
    }

    func testConnectionActivityPreservesDirection() {
        let id = UUID()
        let sent = ConnectionActivity(connectionID: id, bytesSent: 1024)
        XCTAssertEqual(sent.bytesSent, 1024)
        XCTAssertEqual(sent.bytesReceived, 0)

        let received = ConnectionActivity(connectionID: id, bytesReceived: 2048)
        XCTAssertEqual(received.bytesSent, 0)
        XCTAssertEqual(received.bytesReceived, 2048)
    }

    // MARK: - ActiveConnectionInfo.applyActivity

    func testApplyActivityAccumulatesBytes() {
        var info = ActiveConnectionInfo(
            destination: "example.com:443",
            upstream: "SOCKS5",
            method: "SOCKS5",
            tunnel: true
        )
        let originalTime = info.lastActivityAt

        let activity1 = ConnectionActivity(
            connectionID: info.id,
            bytesSent: 100,
            bytesReceived: 200,
            timestamp: Date(timeIntervalSinceNow: 1)
        )
        info.applyActivity(activity1)

        XCTAssertEqual(info.bytesSent, 100)
        XCTAssertEqual(info.bytesReceived, 200)
        XCTAssertGreaterThan(info.lastActivityAt, originalTime)

        let activity2 = ConnectionActivity(
            connectionID: info.id,
            bytesSent: 50,
            bytesReceived: 75,
            timestamp: Date(timeIntervalSinceNow: 2)
        )
        info.applyActivity(activity2)

        XCTAssertEqual(info.bytesSent, 150)
        XCTAssertEqual(info.bytesReceived, 275)
    }

    func testApplyActivityUpdatesTimestamp() {
        var info = ActiveConnectionInfo(
            destination: "test.com:80",
            upstream: "DIRECT",
            method: "GET"
        )
        let future = Date(timeIntervalSinceNow: 60)
        let activity = ConnectionActivity(
            connectionID: info.id,
            bytesSent: 1,
            timestamp: future
        )
        info.applyActivity(activity)
        XCTAssertEqual(info.lastActivityAt, future)
    }

    // MARK: - SOCKS5 Connection Info

    func testSOCKS5ConnectionInfoFields() {
        let info = ActiveConnectionInfo(
            destination: "db.example.com:5432",
            upstream: "SOCKS5",
            method: "SOCKS5",
            tunnel: true
        )
        XCTAssertEqual(info.method, "SOCKS5")
        XCTAssertTrue(info.tunnel)
        XCTAssertEqual(info.bytesSent, 0)
        XCTAssertEqual(info.bytesReceived, 0)
    }

    // MARK: - Snapshot Integration (model-level)

    func testSnapshotActivityUpdatesMutateConnectionsInPlace() {
        var snapshot = ProxyOrchestratorSnapshot()
        let testInfo = ActiveConnectionInfo(
            destination: "test.com:443",
            upstream: "DIRECT",
            method: "CONNECT",
            tunnel: true
        )
        snapshot.activeConnections.insert(testInfo)

        let activity = ConnectionActivity(
            connectionID: testInfo.id,
            bytesSent: 512,
            bytesReceived: 1024
        )

        snapshot.activeConnections.update(id: activity.connectionID) { info in
            info.applyActivity(activity)
        }

        let updated = snapshot.activeConnections.ordered.first { $0.id == testInfo.id }
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.bytesSent, 512)
        XCTAssertEqual(updated?.bytesReceived, 1024)
    }

    func testSnapshotActivityIgnoresMismatchedID() {
        var snapshot = ProxyOrchestratorSnapshot()
        let testInfo = ActiveConnectionInfo(
            destination: "test.com:443",
            upstream: "DIRECT",
            method: "GET"
        )
        snapshot.activeConnections.insert(testInfo)

        let wrongID = ConnectionActivity(connectionID: UUID(), bytesSent: 999)
        snapshot.activeConnections.update(id: wrongID.connectionID) { info in
            info.applyActivity(wrongID)
        }

        XCTAssertEqual(snapshot.activeConnections.ordered[0].bytesSent, 0,
                       "Mismatched ID must no-op — `update(id:)` short-circuits when the id is absent.")
    }

    // MARK: - Codable Round-Trip

    func testConnectionActivityInfoCodableWithBytes() throws {
        let info = ActiveConnectionInfo(
            destination: "api.example.com:443",
            upstream: "proxy.corp.com:8080",
            method: "CONNECT",
            bytesSent: 4096,
            bytesReceived: 8192,
            tunnel: true
        )

        let data = try JSONEncoder().encode(info)
        let decoded = try JSONDecoder().decode(ActiveConnectionInfo.self, from: data)
        XCTAssertEqual(decoded.bytesSent, 4096)
        XCTAssertEqual(decoded.bytesReceived, 8192)
        XCTAssertEqual(decoded.destination, "api.example.com:443")
    }
}
