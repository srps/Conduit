// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

final class HelperAdmissionTests: XCTestCase {
    private let user: uid_t = 501
    private let other: uid_t = 502

    func testConsoleUserIsAdmittedForEverything() {
        for command in HelperCommand.allCases {
            XCTAssertNil(HelperAdmission.refusal(peerUID: user, consoleUID: user, lastConsoleUID: user, command: command), "\(command)")
        }
    }

    func testAnotherUserIsRefusedWhileSomeoneHoldsTheConsole() {
        XCTAssertEqual(HelperAdmission.refusal(peerUID: other, consoleUID: user, lastConsoleUID: user, command: .removeDNS), .unauthorized)
    }

    func testRootPeerIsAlwaysUnauthorized() {
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 0, consoleUID: user, lastConsoleUID: user, command: .ping), .unauthorized)
        XCTAssertEqual(HelperAdmission.refusal(peerUID: 0, consoleUID: 0, lastConsoleUID: 0, command: .ping), .unauthorized)
    }

    func testLastConsoleUserMayTearDownAtTheLoginwindow() {
        for command in HelperCommand.allCases where HelperAdmission.isTeardownOnly(command) {
            XCTAssertNil(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: command), "\(command)")
        }
    }

    func testLastConsoleUserMayNotApplyAtTheLoginwindow() {
        for command in HelperCommand.allCases where !HelperAdmission.isTeardownOnly(command) {
            XCTAssertEqual(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: command), .noConsoleUser, "\(command)")
        }
    }

    func testAnotherUserIsDeferredAtTheLoginwindow() {
        // Fast user switch: the console is uid 0 and a different user's
        // process must not reshape the system proxy in the gap.
        XCTAssertEqual(HelperAdmission.refusal(peerUID: other, consoleUID: 0, lastConsoleUID: user, command: .clearSystemProxy), .noConsoleUser)
    }

    func testNoRememberedConsoleUserDefersEveryone() {
        // A helper that started at boot and has not yet served anyone.
        XCTAssertEqual(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: nil, command: .clearSystemProxy), .noConsoleUser)
    }

    func testAnUnparsableRequestAtTheLoginwindowIsDeferred() {
        XCTAssertEqual(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: nil), .noConsoleUser)
    }

    /// System-DNS teardown stops the relay first, so a service must at least
    /// go back to DHCP at the loginwindow; the recorded servers wait.
    func testDNSResetToDHCPIsAdmittedAtTheLoginwindowButServersAreNot() {
        XCTAssertNil(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: .setDNSServers, values: ["Wi-Fi", "Empty"]))
        XCTAssertNil(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: .setDNSServers, values: ["Wi-Fi", "empty"]))
        XCTAssertEqual(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: .setDNSServers, values: ["Wi-Fi", "10.0.0.53"]), .noConsoleUser)
        XCTAssertEqual(HelperAdmission.refusal(peerUID: user, consoleUID: 0, lastConsoleUID: user, command: .setDNSServers, values: ["Wi-Fi", "Empty", "10.0.0.53"]), .noConsoleUser)
        XCTAssertEqual(HelperAdmission.refusal(peerUID: other, consoleUID: 0, lastConsoleUID: user, command: .setDNSServers, values: ["Wi-Fi", "Empty"]), .noConsoleUser)
    }

    func testTeardownClassification() {
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.applyDNS))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.applySystemProxy))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.startDNSRelay))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.startTCPRelay))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.removeDNS))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.clearSystemProxy))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.stopTCPRelay))
        for setter: HelperCommand in [.setWebProxyEndpoint, .setAutoproxyURL, .setAutoproxy, .setProxyBypass, .setDNSServers] {
            XCTAssertFalse(HelperAdmission.isTeardownOnly(setter), "\(setter) carries a value; a restore is not distinguishable from an apply")
        }
    }
}
