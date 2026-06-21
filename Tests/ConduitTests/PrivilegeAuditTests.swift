// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class PrivilegeAuditTests: XCTestCase {
    func testAuditingPrivilegeClientEmitsRequestAndSuccessWithoutValues() throws {
        let base = FakePrivilegeClient()
        let recorder = EventRecorder()
        let client = AuditingPrivilegeClient(base: base) { recorder.append($0) }

        try client.execute(.setDNSServers, values: ["Wi-Fi", "10.0.0.1"])

        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.allSatisfy { $0.event == "auth.privilege_request" })
        XCTAssertTrue(events.contains { $0.detail?.contains("outcome=requested") == true })
        XCTAssertTrue(events.contains { $0.detail?.contains("outcome=succeeded") == true })
        XCTAssertFalse(events.contains { $0.detail?.contains("10.0.0.1") == true })
    }

    func testAuditingPrivilegeClientEmitsFailureAndRethrows() {
        let base = FakePrivilegeClient(error: PrivilegeClientError.executionFailed("boom"))
        let recorder = EventRecorder()
        let client = AuditingPrivilegeClient(base: base) { recorder.append($0) }

        XCTAssertThrowsError(try client.execute(.applyDNS, values: ["corp.example", "10.0.0.1"]))
        let events = recorder.events
        XCTAssertEqual(events.count, 2)
        XCTAssertTrue(events.contains { $0.detail?.contains("outcome=failed") == true })
        XCTAssertFalse(events.contains { $0.detail?.contains("10.0.0.1") == true })
    }
}

private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RuntimeEvent] = []

    func append(_ event: RuntimeEvent) {
        lock.withLock { storage.append(event) }
    }

    var events: [RuntimeEvent] {
        lock.withLock { storage }
    }
}

private final class FakePrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        if let error {
            throw error
        }
    }
}
