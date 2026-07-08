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

    // MARK: - Side effects

    private func makeConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [
            DomainDNSEntry(domain: "gate-test.example", servers: ["10.1.1.1"])
        ]
        return config
    }

    func testReconcileAppliesEntryFilesWhenWanted() {
        var gate = SplitDNSVPNGate()
        _ = gate.update(.connected)
        let recording = RecordingPrivilegeClient()

        gate.reconcileEntryFiles(
            config: makeConfig(),
            dnsManager: DNSManager(privilegeClient: recording),
            logger: DiscardingLogSink()
        )

        XCTAssertEqual(recording.commands(matching: .applyDNS).compactMap(\.first), ["gate-test.example"])
        XCTAssertTrue(recording.commands(matching: .removeDNS).isEmpty)
    }

    func testReconcileClearsEntryFilesWhenUnwanted() {
        var gate = SplitDNSVPNGate()
        _ = gate.update(.disconnected(reason: .networkLost))
        let recording = RecordingPrivilegeClient()

        gate.reconcileEntryFiles(
            config: makeConfig(),
            dnsManager: DNSManager(privilegeClient: recording),
            logger: DiscardingLogSink()
        )

        XCTAssertEqual(recording.commands(matching: .removeDNS).compactMap(\.first), ["gate-test.example"])
        XCTAssertTrue(recording.commands(matching: .applyDNS).isEmpty)
    }
}

private final class RecordingPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private let lock = NSLock()
    private var _commands: [(PrivilegedOperation, [String])] = []

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        lock.withLock { _commands.append((operation, values)) }
    }

    func commands(matching operation: PrivilegedOperation) -> [[String]] {
        lock.withLock { _commands }.filter { $0.0 == operation }.map(\.1)
    }
}
