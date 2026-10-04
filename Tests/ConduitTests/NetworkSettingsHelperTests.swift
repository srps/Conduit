// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
import NIOConcurrencyHelpers
@testable import ConduitShared
@testable import PlatformMac
@testable import ProxyKernel

final class NetworkSettingsHelperTests: XCTestCase {
    private func request() -> NetworkSettingsRequest {
        .init(locationID: NetworkLocationFixture.home, serviceID: "33333333-3333-3333-3333-333333333333",
              kind: .dns, expected: ["ServerAddresses": .list(["192.0.2.1"])],
              replacement: ["ServerAddresses": .list(["127.0.0.1"])], requireActive: true)
    }

    func testComparisonRejectsExternalEditAndMergePreservesOtherDNSFields() throws {
        let update = request()
        let merged = try NetworkSettingsFields.merging(update, into: ["ServerAddresses": ["192.0.2.1"], "SearchDomains": ["corp.example"], "SupplementalMatchDomains": ["vpn.example"]])
        XCTAssertEqual(merged["ServerAddresses"] as? [String], ["127.0.0.1"])
        XCTAssertEqual(merged["SearchDomains"] as? [String], ["corp.example"])
        XCTAssertEqual(merged["SupplementalMatchDomains"] as? [String], ["vpn.example"])
        XCTAssertThrowsError(try NetworkSettingsFields.merging(update, into: ["ServerAddresses": ["192.0.2.9"]]))
    }

    func testProxyMergeRemovesSelectedKeysAndPreservesAuthenticationAndUnmanagedProtocols() throws {
        var update = request()
        update.kind = .proxies
        update.expected = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
        update.replacement = [:]
        let merged = try NetworkSettingsFields.merging(update, into: [
            "HTTPProxy": "127.0.0.1", "HTTPPort": 3128, "HTTPEnable": 1,
            "SOCKSProxy": "other.example", "HTTPProxyAuthenticated": 1, "HTTPProxyUsername": "synthetic-user"
        ])
        XCTAssertNil(merged["HTTPProxy"])
        XCTAssertNil(merged["HTTPPort"])
        XCTAssertEqual(merged["SOCKSProxy"] as? String, "other.example")
        XCTAssertEqual(merged["HTTPProxyAuthenticated"] as? Int, 1)
        XCTAssertEqual(merged["HTTPProxyUsername"] as? String, "synthetic-user")
    }

    func testLoginwindowAcceptsScopedRemovalButRefusesApplyingOrRestoringValues() throws {
        var update = request()
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501,
                                               command: .compareNetworkSettings, values: [try update.encoded()]), .noConsoleUser)
        update.requireActive = false
        update.replacement = [:]
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501,
                                               command: .compareNetworkSettings, values: [try update.encoded()]), .noConsoleUser)
        update.expected = ["ServerAddresses": .list(["127.0.0.1"])]
        XCTAssertNil(HelperAdmission.refusal(peerUID: 501, consoleUID: 0, lastConsoleUID: 501,
                                             command: .compareNetworkSettings, values: [try update.encoded()]))
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 502, consoleUID: 0, lastConsoleUID: 501,
                                               command: .compareNetworkSettings, values: [try update.encoded()]), .noConsoleUser)
        update.replacement = ["ServerAddresses": .list(["192.0.2.9"])]
        XCTAssertFalse(update.isCleanup)
    }

    func testLoginwindowCannotRemoveCorporateProxyOrBypassFields() throws {
        var update = request()
        update.kind = .proxies
        update.requireActive = false
        update.expected = ["HTTPProxy": .text("corporate.example"), "HTTPPort": .number(8080), "HTTPEnable": .number(1)]
        update.replacement = [:]
        XCTAssertFalse(update.isCleanup)
        update.expected["HTTPProxy"] = .text("127.0.0.1")
        XCTAssertTrue(update.isCleanup)
        update.expected["ExceptionsList"] = .list(["corporate.example"])
        XCTAssertFalse(update.isCleanup)
        update.replacement = ["ExceptionsList": .list(["corporate.example"])]
        XCTAssertTrue(update.isCleanup)
    }

    func testCleanupRecognizesSupportedLoopbackAddressesAndRejectsLookalikes() {
        var update = request()
        update.kind = .proxies
        update.requireActive = false
        update.replacement = [:]
        for host in ["127.0.0.2", "127.255.255.254", "LOCALHOST", "::1"] {
            update.expected = ["HTTPProxy": .text(host), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
            XCTAssertTrue(update.isCleanup, host)
        }
        update.expected["HTTPProxy"] = .text("127.attacker.example")
        XCTAssertFalse(update.isCleanup)
        update.expected = ["ProxyAutoConfigURLString": .text("http://127.0.0.2:8888/proxy.pac"), "ProxyAutoConfigEnable": .number(1)]
        XCTAssertTrue(update.isCleanup)
    }

    func testUnsupportedProxyProjectionDoesNotPoisonDNSOrExposeCredentials() {
        let proxy = SystemNetworkLocationStore.readFields(["ProxyAutoConfigURLString": "https://user:password@example.com/proxy.pac"], kind: .proxies)
        XCTAssertTrue(proxy.unreadable)
        XCTAssertTrue(proxy.fields.isEmpty)
        let dns = SystemNetworkLocationStore.readFields(["ServerAddresses": ["192.0.2.1"]], kind: .dns)
        XCTAssertFalse(dns.unreadable)
        XCTAssertEqual(dns.fields, ["ServerAddresses": .list(["192.0.2.1"])])
    }

    func testMissingHelperNeverInvokesAppleScriptForScopedWrites() throws {
        let ran = NIOLockedValueBox(false)
        let events = RuntimeEventLog()
        let fallback = AppleScriptPrivilegeClient { _ in
            ran.withLockedValue { $0 = true }
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        }
        let client = HelperToolPrivilegeClient(eventSink: { events.append($0) }, socketPath: "/tmp/no-helper-\(UUID().uuidString)",
                                               fallback: fallback, transactionMilliseconds: 100)
        XCTAssertThrowsError(try client.execute(.compareNetworkSettings, values: [request().encoded()]))
        XCTAssertFalse(ran.withLockedValue { $0 })
        XCTAssertEqual(events.events.last?.event, "auth.privilege_helper_required")
        XCTAssertFalse(events.events.contains { $0.event == "auth.privilege_helper_degraded" })
    }

    func testAppleScriptRendererRefusesScopedWritesInsteadOfRenderingAnUnsafeFallback() throws {
        let client = AppleScriptPrivilegeClient { _ in XCTFail("must not prompt"); return CommandResult(exitCode: 0, standardOutput: "", standardError: "") }
        XCTAssertThrowsError(try client.execute(.compareNetworkSettings, values: [request().encoded()]))
    }

    func testRequestBoundsAndFieldTypesRejectBeforeMutation() throws {
        XCTAssertThrowsError(try NetworkSettingsRequest.decode(String(repeating: " ", count: 65_537)))
        var update = request()
        update.replacement = ["ServerAddresses": .list(Array(repeating: "127.0.0.1", count: 257))]
        XCTAssertThrowsError(try update.validate())
        update.replacement = ["ServerAddresses": .number(53)]
        XCTAssertThrowsError(try update.validate())
        update.kind = .proxies
        update.expected = [:]
        update.replacement = ["ExceptionsList": .list(Array(repeating: String(repeating: "a", count: 253), count: 256))]
        XCTAssertThrowsError(try update.validate(), "Individually bounded fields must also fit the whole request budget")
        XCTAssertThrowsError(try NetworkSettingsFields.project(["HTTPPort": 8080.5], kind: .proxies))
        XCTAssertEqual(HelperProtocolVersion.current, 5)
        XCTAssertEqual(HelperProtocolVersion.replyVersion(forRequest: 3), 3)
        XCTAssertEqual(HelperProtocolVersion.replyVersion(forRequest: 4), 4)
    }
}
