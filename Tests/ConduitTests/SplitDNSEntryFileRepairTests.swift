// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// #165: a failed entry-file write or removal is remembered and retried
/// against the state at the time of the retry, over a `FakeMachine` whose
/// resolver files are real files in a scratch directory.
final class SplitDNSEntryFileRepairTests: XCTestCase {
    private var directory: URL!
    private var machine: FakeMachine!
    private var journal: PlatformStateJournal!
    private var manager: DNSManager!
    private var events: [RuntimeEvent] = []

    override func setUpWithError() throws {
        try super.setUpWithError()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("split-dns-repair-\(UUID().uuidString)")
        machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json"))
        manager = DNSManager(privilegeClient: machine, resolverDirectory: machine.resolverDirectory.path, journal: journal)
        events = []
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
        try super.tearDownWithError()
    }

    private func makeConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        return config
    }

    private func report(_ event: RuntimeEvent, _ level: LogLevel) { events.append(event) }

    private func names() -> [String] { events.map(\.event) }

    private func gate(_ state: VPNObservedState) -> SplitDNSVPNGate {
        var gate = SplitDNSVPNGate()
        _ = gate.update(state)
        return gate
    }

    private func retry(_ repair: inout SplitDNSEntryFileRepair, gate: SplitDNSVPNGate, config: ProxyConfig,
                       managed: Bool = true, runtimeStarted: Bool = true) {
        repair.retry(trigger: "helper_check", gate: gate, config: config, resolversManaged: managed,
                     dnsManager: manager, logger: DiscardingLogSink(), runtimeStarted: runtimeStarted, report: report)
    }

    /// The reported case: the removal on a VPN drop is refused, and nothing
    /// tried again once the helper took callers.
    func testAFailedRemovalIsRetriedOnceTheHelperAnswers() throws {
        let config = makeConfig()
        try manager.applyEntryFiles(config: config, logger: nil)
        var repair = SplitDNSEntryFileRepair()
        let down = gate(.disconnected(reason: .networkLost))
        machine.privilege.failingDomains = ["corp.example"]
        let outcome = try XCTUnwrap(down.reconcileEntryFiles(config: config, dnsManager: manager, logger: DiscardingLogSink(), runtimeStarted: true))
        repair.record(outcome, source: .vpnTransition, report: report)
        XCTAssertEqual(repair.pending?.operation, .remove)
        XCTAssertNotNil(machine.resolverFile(for: "corp.example"))
        XCTAssertFalse(repair.shouldRetry(helperAvailable: false))
        XCTAssertTrue(repair.shouldRetry(helperAvailable: true))

        machine.privilege.failingDomains = []
        retry(&repair, gate: down, config: config)

        XCTAssertNil(machine.resolverFile(for: "corp.example"), "no entry file with the tunnel down")
        XCTAssertNil(repair.pending)
        XCTAssertEqual(names(), ["platform.split_dns_failed", "platform.split_dns_retry", "platform.split_dns_repaired"])
        XCTAssertEqual(events[0].detail?.hasPrefix("operation=remove source=vpn_transition attempt=1 reason="), true)
        XCTAssertEqual(events[2].detail, "operation=remove by=retry failed=remove attempts=1")
    }

    /// A retry acts on the gate now, never on the operation that failed: a
    /// write refused while the tunnel was up is not repeated after it went
    /// down.
    func testARetryAfterTheTunnelWentDownRemovesInsteadOfWriting() {
        let config = makeConfig()
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.apply, RecordingPrivilegeClient.Refused(operation: .applyDNS, subject: nil)), source: .vpnTransition, report: report)
        retry(&repair, gate: gate(.disconnected(reason: .userInitiated)), config: config)
        XCTAssertTrue(machine.privilege.commands(matching: .applyDNS).isEmpty)
        XCTAssertEqual(machine.privilege.commands(matching: .removeDNS), [["corp.example"]])
        XCTAssertEqual(events.last?.detail, "operation=remove by=retry failed=apply attempts=1")
    }

    func testARetryWithTheTunnelUpAndTheProxyRunningWritesTheFiles() {
        let config = makeConfig()
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.apply, RecordingPrivilegeClient.Refused(operation: .applyDNS, subject: nil)), source: .start, report: report)
        retry(&repair, gate: gate(.connected), config: config)
        XCTAssertEqual(machine.resolverFile(for: "corp.example"), "nameserver 10.0.0.53")
        XCTAssertNil(repair.pending)
    }

    /// With the proxy stopped the files are a stop's to remove, VPN up or not.
    func testARetryWithTheProxyStoppedRemovesTheFiles() throws {
        let config = makeConfig()
        try manager.applyEntryFiles(config: config, logger: nil)
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .stop, report: report)
        retry(&repair, gate: gate(.connected), config: config, runtimeStarted: false)
        XCTAssertNil(machine.resolverFile(for: "corp.example"))
        XCTAssertNil(repair.pending)
    }

    /// A failed retry stays pending, counts the attempt and backs off.
    func testAFailedRetryStaysPendingAndBacksOff() {
        let config = makeConfig()
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.apply, RecordingPrivilegeClient.Refused(operation: .applyDNS, subject: nil)), source: .vpnTransition, report: report)
        XCTAssertEqual(repair.helperCheckDelay(base: .seconds(60)), .seconds(60))
        machine.privilege.failingDomains = ["corp.example"]
        for _ in 0..<6 { retry(&repair, gate: gate(.connected), config: config) }
        XCTAssertEqual(repair.pending?.attempts, 7)
        XCTAssertEqual(repair.pending?.source, .retry)
        XCTAssertEqual(repair.helperCheckDelay(base: .seconds(60)), .seconds(60 * SplitDNSEntryFileRepair.helperCheckBackoffLimit))
        XCTAssertEqual(names().filter { $0 == "platform.split_dns_failed" }.count, 7)
        XCTAssertEqual(events.last?.detail?.hasPrefix("operation=apply source=retry attempt=7 reason="), true)
    }

    /// The entry is deleted from the config while its removal is pending:
    /// the retry still removes the file, which only the journal names now.
    func testARetryRemovesARecordedFileTheConfigNoLongerNames() throws {
        let config = makeConfig()
        try manager.applyEntryFiles(config: config, logger: nil)
        var repair = SplitDNSEntryFileRepair()
        machine.privilege.failingDomains = ["corp.example"]
        XCTAssertThrowsError(try manager.clearEntryFiles(config: config, logger: nil))
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .vpnTransition, report: report)
        machine.privilege.failingDomains = []
        var edited = config
        edited.dnsEntries = []
        retry(&repair, gate: gate(.disconnected(reason: .userInitiated)), config: edited)
        XCTAssertNil(machine.resolverFile(for: "corp.example"))
        XCTAssertFalse(journal.hasRecords(for: .resolverFile))
        XCTAssertNil(repair.pending)
    }

    /// The switch went off while a removal was pending. The switch-off
    /// teardown can fail for the same reason, so the retry runs it, and the
    /// repair stands until the journal names no file of ours.
    func testWithTheSwitchOffTheRetryIsTheSwitchOffTeardown() throws {
        let config = makeConfig()
        try manager.applyEntryFiles(config: config, logger: nil)
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .vpnTransition, report: report)
        machine.privilege.failingDomains = ["corp.example"]
        retry(&repair, gate: gate(.disconnected(reason: .userInitiated)), config: config, managed: false)
        XCTAssertNotNil(repair.pending, "the teardown failed too")
        XCTAssertEqual(events.last?.event, "platform.split_dns_failed")
        machine.privilege.failingDomains = []
        retry(&repair, gate: gate(.connected), config: config, managed: false)
        XCTAssertNil(machine.resolverFile(for: "corp.example"), "removed, VPN up or not: the switch is off")
        XCTAssertNil(repair.pending)
        XCTAssertTrue(events.contains { $0.event == "platform.split_dns_retry" && $0.detail?.contains("managed=false") == true })
    }

    func testASuccessWithNothingPendingReportsNothing() {
        var repair = SplitDNSEntryFileRepair()
        repair.record(.succeeded(.apply), source: .start, report: report)
        XCTAssertTrue(events.isEmpty)
        XCTAssertFalse(repair.shouldRetry(helperAvailable: true))
    }

    /// Codex review: a start removes with the tunnel down; meanwhile the
    /// tunnel comes up and drops again and that removal fails. The start's
    /// success arrives last and must not forget the newer failure.
    func testAnOlderStartResultDoesNotOverwriteANewerFailure() {
        var repair = SplitDNSEntryFileRepair()
        let queuedAt = repair.generation
        repair.record(.succeeded(.apply), source: .vpnTransition, report: report)
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .vpnTransition, report: report)
        repair.record(.succeeded(.remove), source: .start, startedAt: queuedAt, report: report)
        XCTAssertEqual(repair.pending?.operation, .remove, "the newer failure still stands")
        XCTAssertEqual(events.last?.event, "platform.split_dns_outcome_superseded")
        XCTAssertEqual(events.last?.detail, "operation=remove source=start failed=false newer=2")

        let current = repair.generation
        repair.record(.succeeded(.remove), source: .stop, startedAt: current, report: report)
        XCTAssertNil(repair.pending, "a result with nothing recorded since is applied")
    }

    /// Codex review: a deleted entry's file is swept only by a retry, so a
    /// success elsewhere must not settle the repair while it is on disk.
    func testASuccessThatLeavesAnUnconfiguredRecordedFileDoesNotSettle() throws {
        let config = makeConfig()
        try manager.applyEntryFiles(config: config, logger: nil)
        var edited = config
        edited.dnsEntries = []
        XCTAssertTrue(manager.unconfiguredRecordedFilesPresent(config: edited))
        XCTAssertFalse(manager.unconfiguredRecordedFilesPresent(config: config))
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .vpnTransition, report: report)
        repair.record(.succeeded(.remove), source: .vpnTransition, residue: true, report: report)
        XCTAssertNotNil(repair.pending)
        XCTAssertFalse(names().contains("platform.split_dns_repaired"))
        retry(&repair, gate: gate(.disconnected(reason: .userInitiated)), config: edited)
        XCTAssertNil(repair.pending)
        XCTAssertFalse(manager.unconfiguredRecordedFilesPresent(config: edited))
    }

    /// Codex review of the PR #211 fixes: an entry deleted while its removal
    /// was refused, then re-added with no servers, is never written, so its
    /// old file is as stale as a deleted entry's. It must count as residue,
    /// or the config edit's success would settle the repair over it.
    func testAFileLeftForAnEntryReAddedWithoutServersIsResidueAndSwept() throws {
        let config = makeConfig()
        try manager.applyEntryFiles(config: config, logger: nil)
        var edited = config
        edited.dnsEntries = config.dnsEntries.map { DomainDNSEntry(domain: $0.domain, servers: []) }
        XCTAssertTrue(manager.unconfiguredRecordedFilesPresent(config: edited))
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .configChange, report: report)
        retry(&repair, gate: gate(.connected), config: edited)
        XCTAssertNil(repair.pending)
        XCTAssertFalse(manager.unconfiguredRecordedFilesPresent(config: edited))
    }

    /// Codex review of PR #211: an edit that only recapitalizes an entry,
    /// with the old spelling's record left by a refused removal. On a
    /// case-insensitive volume both names are one file, so the retry's
    /// sweep must not unlink the file its apply just wrote.
    func testARecapitalizedEntryKeepsItsFileThroughTheRetrysSweep() throws {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [DomainDNSEntry(domain: "Corp.example", servers: ["10.0.0.53"])]
        try manager.applyEntryFiles(config: config, logger: nil)
        var edited = config
        edited.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.apply, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .configChange, report: report)
        retry(&repair, gate: gate(.connected), config: edited)
        XCTAssertNil(repair.pending)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: machine.resolverDirectory.appendingPathComponent("corp.example").path),
            "the entry's override is on disk after the repair"
        )
        XCTAssertFalse(manager.unconfiguredRecordedFilesPresent(config: edited))
    }

    /// Any later operation that lands settles the repair, not only a retry.
    func testALaterVPNTransitionThatLandsSettlesTheRepair() {
        var repair = SplitDNSEntryFileRepair()
        repair.record(.failed(.remove, RecordingPrivilegeClient.Refused(operation: .removeDNS, subject: nil)), source: .stop, report: report)
        repair.record(.succeeded(.apply), source: .vpnTransition, report: report)
        XCTAssertNil(repair.pending)
        XCTAssertEqual(events.last?.detail, "operation=apply by=vpn_transition failed=remove attempts=1")
    }
}
