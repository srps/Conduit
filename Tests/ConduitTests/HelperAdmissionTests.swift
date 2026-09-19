// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import ConduitShared

final class HelperAdmissionTests: XCTestCase {
    private let user: uid_t = 501
    private let other: uid_t = 502

    /// The early verdict shortens what a peer is given to send its request,
    /// and its request is then never decoded. It must therefore never differ
    /// from what the full policy would say for any request at all, and must
    /// stay undecided for every peer some request could admit.
    func testRefusalBeforeReadingNeverDisagreesWithTheFullPolicy() {
        let uids: [uid_t] = [0, user, other]
        let requests: [(HelperCommand?, [String])] = [(nil, [])]
            + HelperCommand.allCases.map { ($0, []) }
            + [(.setDNSServers, ["Wi-Fi", "Empty"]), (.setDNSServers, ["Wi-Fi", "127.0.0.1"])]
        for peer in uids {
            for console in uids {
                for last in [nil] + uids.map(Optional.some) {
                    let early = HelperAdmission.refusalBeforeReading(peerUID: peer, consoleUID: console, lastConsoleUID: last)
                    let verdicts = requests.map {
                        HelperAdmission.refusal(peerUID: peer, consoleUID: console, lastConsoleUID: last, command: $0.0, values: $0.1)
                    }
                    let state = "peer=\(peer) console=\(console) last=\(String(describing: last))"
                    if let early {
                        XCTAssertTrue(verdicts.allSatisfy { $0 == early }, state)
                    } else {
                        XCTAssertTrue(verdicts.contains(nil), "undecided, yet nothing this peer sends is admitted: \(state)")
                    }
                }
            }
        }
    }

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
