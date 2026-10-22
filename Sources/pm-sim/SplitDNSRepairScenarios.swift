// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// #165 over `FakeMachine`: the policy both hosts share, `SplitDNSVPNGate`
/// and `SplitDNSEntryFileRepair` over a `DNSManager` with a journal, driven
/// the way the hosts drive it. The hosts themselves are app and daemon
/// executables pm-sim cannot link; their wiring is pinned by
/// `AppStateHarnessTests` and `DaemonRuntimeHostTests`.
///
/// A helper refusing callers fails the entry-file removal on a VPN drop;
/// nothing is retried while it still refuses; the first observation of it
/// available removes the file. A write refused with the tunnel up is not
/// replayed after the tunnel went down. A failure the helper is not behind
/// stays pending and backs off.
enum SplitDNSRepairScenarios {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-split-dns-repair-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: directory) }
            catch { fputs("split-dns-repair cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json"))
        let dns = DNSManager(privilegeClient: machine, resolverDirectory: machine.resolverDirectory.path, journal: journal)
        var config = GenericDefaults.shared.makeConfig()
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["10.0.0.53"])]
        var events: [RuntimeEvent] = []
        let report: (RuntimeEvent, LogLevel) -> Void = { event, _ in events.append(event) }
        func count(_ name: String) -> Int { events.filter { $0.event == name }.count }
        let logger = DiscardingLogSink()
        var gate = SplitDNSVPNGate()
        var repair = SplitDNSEntryFileRepair()

        // Phase 1: applied with the tunnel up; the helper then refuses every
        // caller, and the removal on a VPN drop fails.
        _ = gate.update(.connected)
        if let outcome = gate.reconcileEntryFiles(config: config, dnsManager: dns, logger: logger, runtimeStarted: true) {
            repair.record(outcome, source: .vpnTransition, report: report)
        }
        machine.privilege.failingDomains = ["corp.example"]
        if gate.update(.disconnected(reason: .networkLost)),
           let outcome = gate.reconcileEntryFiles(config: config, dnsManager: dns, logger: logger, runtimeStarted: true) {
            repair.record(outcome, source: .vpnTransition, report: report)
        }
        let strandedAndReported = machine.resolverFile(for: "corp.example") != nil
            && repair.pending?.operation == .remove && count("platform.split_dns_failed") == 1

        // Phase 2: the helper is still refusing; an observation retries nothing.
        let quietWhileRefused = !repair.shouldRetry(helperAvailable: false)

        // Phase 3: the helper takes callers again; the first observation of
        // it available removes the file, with no VPN report.
        machine.privilege.failingDomains = []
        if repair.shouldRetry(helperAvailable: true) {
            repair.retry(trigger: "helper_available", gate: gate, config: config, resolversManaged: true,
                         dnsManager: dns, logger: logger, runtimeStarted: true, report: report)
        }
        let repaired = machine.resolverFile(for: "corp.example") == nil && repair.pending == nil
            && count("platform.split_dns_repaired") == 1 && !journal.hasRecords(for: .resolverFile)

        // Phase 4: a write refused with the tunnel up; the tunnel goes down
        // before the helper is back (the flip removes nothing: no file). The
        // retry removes, never writes.
        _ = gate.update(.connected)
        machine.privilege.failingDomains = ["corp.example"]
        if let outcome = gate.reconcileEntryFiles(config: config, dnsManager: dns, logger: logger, runtimeStarted: true) {
            repair.record(outcome, source: .vpnTransition, report: report)
        }
        _ = gate.update(.disconnected(reason: .userInitiated))
        machine.privilege.failingDomains = []
        let appliesBefore = machine.privilege.commands(matching: .applyDNS).count
        repair.retry(trigger: "helper_available", gate: gate, config: config, resolversManaged: true,
                     dnsManager: dns, logger: logger, runtimeStarted: true, report: report)
        let noStaleWrite = machine.privilege.commands(matching: .applyDNS).count == appliesBefore
            && machine.resolverFile(for: "corp.example") == nil && repair.pending == nil

        // Phase 5: a failure the helper is not behind stays pending, and the
        // helper check backs off up to its limit.
        _ = gate.update(.connected)
        machine.privilege.failingDomains = ["corp.example"]
        if let outcome = gate.reconcileEntryFiles(config: config, dnsManager: dns, logger: logger, runtimeStarted: true) {
            repair.record(outcome, source: .vpnTransition, report: report)
        }
        let base = Duration.seconds(60)
        let firstDelay = repair.helperCheckDelay(base: base)
        for _ in 0..<8 {
            repair.retry(trigger: "helper_check", gate: gate, config: config, resolversManaged: true,
                         dnsManager: dns, logger: logger, runtimeStarted: true, report: report)
        }
        let backedOff = repair.pending?.attempts == 9 && firstDelay == base
            && repair.helperCheckDelay(base: base) == base * SplitDNSEntryFileRepair.helperCheckBackoffLimit

        return ScenarioResult(
            name: "split-dns-helper-retry", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a refused removal on a VPN drop leaves the entry file and reports it", strandedAndReported),
                .init("nothing is retried while the helper still refuses", quietWhileRefused),
                .init("the first observation of the helper available removes the file, with its events", repaired),
                .init("a write refused with the tunnel up is not replayed after it went down", noStaleWrite),
                .init("a failure the helper is not behind stays pending and backs off to the limit", backedOff),
            ],
            notes: ["events=\(events.map(\.event).joined(separator: ","))"]
        )
    }
}
