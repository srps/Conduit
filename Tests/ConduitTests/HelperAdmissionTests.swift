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

    func testTeardownClassification() {
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.applyDNS))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.applySystemProxy))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.startDNSRelay))
        XCTAssertFalse(HelperAdmission.isTeardownOnly(.startTCPRelay))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.removeDNS))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.clearSystemProxy))
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.setWebProxyEndpoint), "restores the recorded prior endpoint")
        XCTAssertTrue(HelperAdmission.isTeardownOnly(.stopTCPRelay))
    }
}
