// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Pins the VPN-gating policy for split-DNS entry files in its single shared
/// home. `AppState` and `DaemonRuntimeHost` both act on this gate, so a policy
/// change here is a behavior change in *both* hosts — these tests document
/// exactly which states keep the files and which transitions flip them.
final class SplitDNSVPNGateTests: XCTestCase {

    func testEntriesWantedPerState() {
        var gate = SplitDNSVPNGate()
        XCTAssertTrue(gate.entriesWanted, "bootstrap .unknown keeps files: wrongly keeping is self-correcting")

        _ = gate.update(.connected)
        XCTAssertTrue(gate.entriesWanted)

        _ = gate.update(.reasserting)
        XCTAssertTrue(gate.entriesWanted, "flap grace window keeps files: removal would churn resolver state")

        for reason: VPNDisconnectReason in [.userInitiated, .networkLost, .unknown] {
            _ = gate.update(.disconnected(reason: reason))
            XCTAssertFalse(gate.entriesWanted, "definitively down withholds files regardless of reason")
        }
    }

    func testUpdateReportsOnlyWantedStateFlips() {
        var gate = SplitDNSVPNGate()

        XCTAssertFalse(gate.update(.connected), "unknown → connected: files already wanted, nothing to do")
        XCTAssertFalse(gate.update(.reasserting), "flap starts: files stay, no action")
        XCTAssertTrue(gate.update(.disconnected(reason: .networkLost)), "flap settles down: remove files")
        XCTAssertFalse(gate.update(.disconnected(reason: .userInitiated)), "still down: no repeat removal")
        XCTAssertTrue(gate.update(.connected), "reconnected: apply files")
        XCTAssertFalse(gate.update(.connected), "duplicate state report: no repeat apply")
    }
}
