// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

final class NetworkLocationRecoveryTests: XCTestCase {
    private let home = "11111111-1111-1111-1111-111111111111"
    private let office = "22222222-2222-2222-2222-222222222222"
    private let homeService = "33333333-3333-3333-3333-333333333333"
    private let officeService = "44444444-4444-4444-4444-444444444444"
    private let localDNS: [String: NetworkSettingValue] = ["ServerAddresses": .list(["127.0.0.1"])]

    private func machine() -> FakeNetworkLocationStore {
        FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: [
            .init(locationID: home, serviceID: homeService, name: "Wi-Fi", enabled: true,
                  proxies: ["ProxyAutoConfigURLString": .text("https://home.example/proxy.pac")],
                  dns: ["ServerAddresses": .list(["192.0.2.1"])]),
            .init(locationID: office, serviceID: officeService, name: "Wi-Fi", enabled: true,
                  proxies: ["HTTPProxy": .text("proxy.office.example"), "HTTPPort": .number(8080), "HTTPEnable": .number(1)],
                  dns: ["ServerAddresses": .list(["192.0.2.2"])])
        ]))
    }

    private func withRecovery(_ body: (FakeNetworkLocationStore, PlatformStateJournal, LocationSettingsRecovery, RuntimeEventLog) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("location-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = machine()
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let events = RuntimeEventLog()
        let recovery = LocationSettingsRecovery(store: store, journal: journal, emit: { events.append($0) })
        try body(store, journal, recovery, events)
    }

    func testSwitchRestoresInactiveLocationAndCapturesDistinctPriorValues() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot()
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.activeLocationID = office }
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            let switched = try store.snapshot()
            XCTAssertEqual(switched.services[0].dns, original.services[0].dns)
            XCTAssertEqual(switched.services[1].dns, localDNS)
            XCTAssertEqual(journal.records(for: .systemDNS).map(\.locationID), [office])
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services, original.services)
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
        }
    }

    func testFreshJournalPreservesUserLoopbackDNSAndRestoresItAfterApply() throws {
        try withRecovery { store, _, recovery, _ in
            store.edit { $0.services[0].dns = localDNS }
            XCTAssertEqual(recovery.recover(kind: .dns, config: ProxyConfig(), listenerIsLive: false), .nothingToDo(.nothingRecorded))
            XCTAssertEqual(try store.snapshot().services[0].dns, localDNS)
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, localDNS)
        }
    }

    func testCorruptJournalClearsRecognizedResidueWithoutReplacingEvidence() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("location-corrupt-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let corrupt = Data("{broken}".utf8)
        try corrupt.write(to: file)
        let journal = PlatformStateJournal(fileURL: file)
        let store = machine()
        store.edit {
            $0.services[0].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
            $0.services[0].dns = localDNS
        }
        let events = RuntimeEventLog()
        let recovery = LocationSettingsRecovery(store: store, journal: journal, emit: { events.append($0) })
        for kind in [NetworkSettingsKind.proxies, .dns] {
            guard case .failed = recovery.recover(kind: kind, config: ProxyConfig(), listenerIsLive: false) else {
                XCTFail("Unreadable recovery must report unknown prior state")
                return
            }
            XCTAssertFalse(recovery.isCleared(kind: kind))
            XCTAssertThrowsError(try recovery.clear(kind: kind, config: ProxyConfig()))
        }
        XCTAssertEqual(try store.snapshot().services[0].proxies, [:])
        XCTAssertEqual(try store.snapshot().services[0].dns, [:])
        XCTAssertEqual(try store.snapshot().services[1].dns, ["ServerAddresses": .list(["192.0.2.2"])])
        XCTAssertThrowsError(try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig()))
        journal.markReleased(surface: .launchdEnvironment)
        XCTAssertEqual(journal.fileState, .unreadable)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" })
    }

    func testUnreadableProtocolRetainsItsRecordAndDoesNotBlockOtherRecovery() throws {
        try withRecovery { store, journal, recovery, events in
            let original = try store.snapshot()
            try recovery.apply(kind: .proxies, desired: ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)], config: ProxyConfig())
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.services[0].unreadableProxies = true; $0.services[1].unreadableProxies = true }
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, original.services[0].dns)
            XCTAssertThrowsError(try recovery.clear(kind: .proxies, config: ProxyConfig()))
            XCTAssertTrue(journal.hasRecords(for: .systemProxy))
            store.edit { $0.services[0].unreadableProxies = false }
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].proxies, original.services[0].proxies)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" })
        }
    }

    func testRelayFailureStillRestoresInactiveLocationBeforeWithholdingActiveDNS() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot()
            let privilege = RecordingPrivilegeClient()
            let dns = SystemDNSManager(privilegeClient: privilege, journal: journal, locationRecovery: recovery)
            try dns.apply(forwarderPort: 15053, logger: nil)
            store.edit { $0.activeLocationID = office }
            privilege.failing = [.startDNSRelay]
            XCTAssertThrowsError(try dns.reconcileLocation(apply: true, forwarderPort: 15053))
            XCTAssertEqual(try store.snapshot().services, original.services)
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            privilege.failing = []
            try dns.reconcileLocation(apply: true, forwarderPort: 15053)
            XCTAssertEqual(try store.snapshot().services[1].dns, localDNS)
            try dns.clear(logger: nil)
        }
    }

    func testLocationDNSApplyWaitsForRelaySuccessAndRetriesFailedStart() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot()
            let privilege = RecordingPrivilegeClient()
            privilege.failing = [.startDNSRelay]
            let dns = SystemDNSManager(privilegeClient: privilege, journal: journal, locationRecovery: recovery)
            XCTAssertThrowsError(try dns.apply(forwarderPort: 15053, logger: nil))
            store.edit { $0.activeLocationID = office }
            XCTAssertThrowsError(try dns.reconcileLocation(apply: true, forwarderPort: 15053))
            XCTAssertEqual(try store.snapshot().services, original.services)
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            privilege.failing = []
            try dns.reconcileLocation(apply: true, forwarderPort: 15053)
            XCTAssertEqual(privilege.commands(matching: .startDNSRelay).last, ["15053"])
            XCTAssertEqual(try store.snapshot().services[1].dns, localDNS)
            try dns.clear(logger: nil)
        }
    }

    func testStoppedManagersRestoreRetainedRecordsAfterReturningToTheirLocation() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot()
            let config = ProxyConfig()
            let privilege = RecordingPrivilegeClient()
            let proxy = SystemProxyManager(privilegeClient: privilege, journal: journal, locationRecovery: recovery)
            let dns = SystemDNSManager(privilegeClient: privilege, journal: journal, locationRecovery: recovery)
            try proxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true)
            try dns.apply(forwarderPort: 15053, logger: nil)
            store.edit { $0.activeLocationID = office }
            store.refuseWrites(true)
            XCTAssertThrowsError(try proxy.clear(logger: nil))
            XCTAssertThrowsError(try dns.clear(logger: nil))
            XCTAssertTrue(journal.hasRecords(for: .systemProxy))
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            store.refuseWrites(false)
            store.edit { $0.activeLocationID = home }
            let relayStarts = privilege.commands(matching: .startDNSRelay).count
            try proxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: false)
            try dns.reconcileLocation(apply: false, forwarderPort: 0)
            XCTAssertEqual(try store.snapshot().services, original.services)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            XCTAssertEqual(privilege.commands(matching: .startDNSRelay).count, relayStarts)
        }
    }

    func testPACReconcileRetriesFailurePreservesRewriteAndAvoidsUnchangedWrites() throws {
        try withRecovery { store, journal, recovery, events in
            let proxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            var config = ProxyConfig()
            config.localPACEnabled = true
            let url = "http://127.0.0.1:63145/proxy.pac"
            store.refuseWrites(true)
            XCTAssertThrowsError(try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true))
            store.refuseWrites(false)
            try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
            let applied = try store.snapshot().services[0].proxies
            store.refuseWrites(true)
            try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
            store.refuseWrites(false)
            let corporatePAC = NetworkSettingValue.text("http://corporate.example/proxy.pac")
            store.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = corporatePAC }
            try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
            XCTAssertEqual(try store.snapshot().services[0].proxies, applied)
            try proxy.clear(logger: nil)
            XCTAssertEqual(try store.snapshot().services[0].proxies["ProxyAutoConfigURLString"], corporatePAC)
            XCTAssertEqual(events.events.filter { $0.event == "platform.location_reconcile" }.count, 3)
        }
    }

    func testPACReconcileRepairsEthernetWhenWiFiAlreadyMatches() throws {
        try withRecovery { store, journal, recovery, _ in
            let corporatePAC: [String: NetworkSettingValue] = [
                "ProxyAutoConfigEnable": .number(1),
                "ProxyAutoConfigURLString": .text("http://corporate.example/proxy.pac")
            ]
            store.edit { snapshot in
                snapshot.services.append(.init(locationID: home,
                    serviceID: "55555555-5555-5555-5555-555555555555", name: "USB Ethernet", enabled: true,
                    proxies: corporatePAC, dns: [:]))
            }
            let proxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            var config = ProxyConfig()
            config.localPACEnabled = true
            let url = "http://127.0.0.1:63145/proxy.pac"
            try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
            store.edit { $0.services[2].proxies = corporatePAC }
            try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
            let repaired = try store.snapshot()
            XCTAssertEqual(repaired.services[0].proxies["ProxyAutoConfigURLString"], .text(url))
            XCTAssertEqual(repaired.services[2].proxies["ProxyAutoConfigURLString"], .text(url))
            try proxy.clear(logger: nil)
            XCTAssertEqual(try store.snapshot().services[2].proxies, corporatePAC)
        }
    }

    func testRepeatedExternalRewritesExhaustTheRepairBudgetAndReportContentionOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("location-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = machine()
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let events = RuntimeEventLog()
        let clock = ManualInstant()
        let recovery = LocationSettingsRecovery(store: store, journal: journal,
                                                limits: .init(maximumDriftRepairs: 2, driftRepairWindow: .seconds(60)),
                                                now: { clock.value }, emit: { events.append($0) })
        let proxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
        var config = ProxyConfig()
        config.localPACEnabled = true
        let url = "http://127.0.0.1:63145/proxy.pac"
        let enforced = NetworkSettingValue.text("http://enforced.example/proxy.pac")
        func rewriteAndReconcile() throws {
            store.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = enforced }
            try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
        }
        func count(_ name: String) -> Int { events.events.filter { $0.event == name }.count }

        try rewriteAndReconcile()
        try rewriteAndReconcile()
        XCTAssertEqual(try store.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        try rewriteAndReconcile()
        try rewriteAndReconcile()
        XCTAssertEqual(try store.snapshot().services[0].proxies["ProxyAutoConfigURLString"], enforced)
        XCTAssertEqual(count("platform.location_reconcile"), 2)
        XCTAssertEqual(count("platform.location_contended"), 1)

        clock.advance(.seconds(61))
        try rewriteAndReconcile()
        XCTAssertEqual(try store.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        XCTAssertEqual(count("platform.location_reconcile"), 3)

        // Another location has its own budget even inside the window.
        try rewriteAndReconcile()
        try rewriteAndReconcile()
        XCTAssertEqual(count("platform.location_contended"), 2)
        store.edit { $0.activeLocationID = office }
        try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true)
        XCTAssertEqual(try store.snapshot().services[1].proxies["ProxyAutoConfigURLString"], .text(url))

        // Stopping still restores every record; the budget only limits drift repair.
        try proxy.clear(logger: nil)
        XCTAssertFalse(journal.hasRecords(for: .systemProxy))
    }

    func testFailedRepairsDoNotSpendTheBudgetAndContentionReturnsTheRetryDelay() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("location-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = machine()
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let events = RuntimeEventLog()
        let clock = ManualInstant()
        let recovery = LocationSettingsRecovery(store: store, journal: journal,
                                                limits: .init(maximumDriftRepairs: 1, driftRepairWindow: .seconds(60)),
                                                now: { clock.value }, emit: { events.append($0) })
        let proxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
        var config = ProxyConfig()
        config.localPACEnabled = true
        let url = "http://127.0.0.1:63145/proxy.pac"
        store.refuseWrites(true)
        for _ in 0..<3 {
            XCTAssertThrowsError(try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true))
        }
        store.refuseWrites(false)
        XCTAssertNil(try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true))
        XCTAssertEqual(try store.snapshot().services[0].proxies["ProxyAutoConfigURLString"], .text(url))
        XCTAssertFalse(events.events.contains { $0.event == "platform.location_contended" })

        clock.advance(.seconds(10))
        store.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = .text("http://enforced.example/proxy.pac") }
        XCTAssertEqual(try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true), .seconds(50))
        let contended = try XCTUnwrap(events.events.first { $0.event == "platform.location_contended" })
        XCTAssertTrue(contended.detail?.contains("retry_seconds=50") == true, contended.detail ?? "")
        try proxy.clear(logger: nil)
    }

    func testPartialApplyCannotLoopWhenASiblingServiceKeepsFailing() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("location-tests-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = machine()
        let ethernet = "55555555-5555-5555-5555-555555555555"
        store.edit { $0.services.append(.init(locationID: home, serviceID: ethernet, name: "USB Ethernet", enabled: true,
                                              proxies: [:], dns: [:])) }
        store.refuseWrites(toService: ethernet, true)
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("journal.json"))
        let events = RuntimeEventLog()
        let recovery = LocationSettingsRecovery(store: store, journal: journal,
                                                limits: .init(maximumDriftRepairs: 2, driftRepairWindow: .seconds(60)),
                                                now: { ContinuousClock.now }, emit: { events.append($0) })
        let proxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
        var config = ProxyConfig()
        config.localPACEnabled = true
        let url = "http://127.0.0.1:63145/proxy.pac"

        // Our own Wi-Fi write notifies; later passes must not re-commit the unchanged Wi-Fi settings.
        XCTAssertThrowsError(try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true))
        let afterFirstPass = store.committedWrites
        XCTAssertGreaterThan(afterFirstPass, 0)
        for _ in 0..<10 {
            XCTAssertThrowsError(try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true))
        }
        XCTAssertEqual(store.committedWrites, afterFirstPass)

        // An enforcing writer on Wi-Fi: passes that wrote before Ethernet failed still spend the budget.
        let enforced = NetworkSettingValue.text("http://enforced.example/proxy.pac")
        var writesPerPass: [Int] = []
        for _ in 0..<10 {
            let before = store.committedWrites
            store.edit { $0.services[0].proxies["ProxyAutoConfigURLString"] = enforced }
            do { try proxy.reconcileLocation(config: config, mode: .pac, localPACURL: url, apply: true) }
            catch { /* Ethernet keeps failing; the budget, not the error, ends the loop. */ }
            writesPerPass.append(store.committedWrites - before)
        }
        XCTAssertTrue(writesPerPass.prefix(1).allSatisfy { $0 > 0 }, "\(writesPerPass)")
        XCTAssertTrue(writesPerPass.dropFirst(1).allSatisfy { $0 == 0 }, "\(writesPerPass)")
        XCTAssertEqual(events.events.filter { $0.event == "platform.location_contended" }.count, 1)

        store.refuseWrites(toService: ethernet, false)
        try proxy.clear(logger: nil)
        XCTAssertFalse(journal.hasRecords(for: .systemProxy))
    }

    func testManagersRetryApplyAfterEmptyLocationReleasedAllPriorRecords() throws {
        try withRecovery { store, journal, recovery, _ in
            let config = ProxyConfig()
            let proxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            let dns = SystemDNSManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            try proxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true)
            try dns.apply(forwarderPort: 15053, logger: nil)
            store.edit { $0.activeLocationID = "55555555-5555-5555-5555-555555555555" }
            XCTAssertThrowsError(try proxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true))
            XCTAssertThrowsError(try dns.reconcileLocation(apply: true, forwarderPort: 15053))
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            store.edit { $0.activeLocationID = office }
            try proxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true)
            try dns.reconcileLocation(apply: true, forwarderPort: 15053)
            XCTAssertEqual(try store.snapshot().services[1].proxies["HTTPProxy"], .text(config.effectiveClientHost))
            XCTAssertEqual(try store.snapshot().services[1].dns, localDNS)
            try proxy.clear(logger: nil)
            try dns.clear(logger: nil)
        }
    }

    func testSwitchDuringApplyRejectsStaleActiveWriteAndRetainsRecoveryEvidence() throws {
        try withRecovery { store, journal, recovery, events in
            store.switchDuringNextWrite(to: office)
            XCTAssertThrowsError(try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig()))
            XCTAssertEqual(try store.snapshot().services[1].dns, ["ServerAddresses": .list(["192.0.2.2"])])
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" })
        }
    }

    func testSuccessfulReapplyPreservesAnExternalEditBackToPreviousGeneration() throws {
        try withRecovery { store, journal, recovery, _ in
            let old: [String: NetworkSettingValue] = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
            var new = old
            new["HTTPPort"] = .number(4218)
            try recovery.apply(kind: .proxies, desired: old, config: ProxyConfig())
            try recovery.apply(kind: .proxies, desired: new, config: ProxyConfig())
            XCTAssertNil(journal.records(for: .systemProxy).first?.appliedValue?["previousNetworkSettings"])
            store.edit { $0.services[0].proxies = old }
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].proxies, old)
        }
    }

    func testCompareConflictRetriesWithinTheSameLocationAndHasAFixedBudget() throws {
        try withRecovery { store, journal, recovery, events in
            store.conflictNextWrites(1)
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, localDNS)
            XCTAssertEqual(events.events.filter { $0.event == "platform.location_retry" }.count, 1)
            try recovery.clear(kind: .dns, config: ProxyConfig())
            store.conflictNextWrites(10)
            XCTAssertThrowsError(try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig()))
            XCTAssertEqual(store.pendingCompareFailures, 8)
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            store.conflictNextWrites(0)
            try recovery.clear(kind: .dns, config: ProxyConfig())
        }
    }

    func testExternalDNSIsPreservedDuringRestore() throws {
        try withRecovery { store, journal, recovery, events in
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.services[0].dns = ["ServerAddresses": .list(["192.0.2.9"])] }
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, ["ServerAddresses": .list(["192.0.2.9"])])
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_external_preserved" })
        }
    }

    func testExternalBypassEditDoesNotKeepDeadProxyEndpoints() throws {
        try withRecovery { store, _, recovery, _ in
            let prior = try store.snapshot().services[0].proxies
            let desired: [String: NetworkSettingValue] = [
                "HTTPEnable": .number(1), "HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128),
                "ExceptionsList": .list(["localhost"])
            ]
            try recovery.apply(kind: .proxies, desired: desired, config: ProxyConfig())
            store.edit { $0.services[0].proxies["ExceptionsList"] = .list(["external.example"]) }
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            let restored = try store.snapshot().services[0].proxies
            XCTAssertNil(restored["HTTPProxy"])
            XCTAssertEqual(restored["ProxyAutoConfigURLString"], prior["ProxyAutoConfigURLString"])
            XCTAssertEqual(restored["ExceptionsList"], .list(["external.example"]))
        }
    }

    func testExternallyDisabledEndpointIsStillRemovedWithoutChangingExternalState() throws {
        try withRecovery { store, _, recovery, _ in
            try recovery.apply(kind: .proxies, desired: ["HTTPEnable": .number(1), "HTTPProxy": .text("127.0.0.1"),
                                                       "HTTPPort": .number(3128)], config: ProxyConfig())
            store.edit { $0.services[0].proxies["HTTPEnable"] = .number(0) }
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            let restored = try store.snapshot().services[0].proxies
            XCTAssertNil(restored["HTTPProxy"])
            XCTAssertNil(restored["HTTPPort"])
            XCTAssertEqual(restored["HTTPEnable"], .number(0))
        }
    }

    func testRenameUsesStableIdentityAndDeletionReleasesOnlyDeletedRecord() throws {
        try withRecovery { store, journal, recovery, events in
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.services[0].name = "Renamed Wi-Fi" }
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, ["ServerAddresses": .list(["192.0.2.1"])])
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.services.removeFirst() }
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_deleted" })
        }
    }

    func testFailedRestoreKeepsRecordsForIdempotentRetry() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot()
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.activeLocationID = office }
            store.refuseWrites(true)
            XCTAssertThrowsError(try recovery.clear(kind: .dns, config: ProxyConfig()))
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            store.refuseWrites(false)
            try recovery.clear(kind: .dns, config: ProxyConfig())
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services, original.services)
        }
    }

    func testClearedReadCannotSkipAnInactiveOutstandingRecord() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot().services[0].proxies
            try recovery.apply(kind: .proxies, desired: ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)], config: ProxyConfig())
            store.edit { $0.activeLocationID = office; $0.services[1].proxies = [:] }
            store.refuseWrites(true)
            XCTAssertThrowsError(try recovery.restore(kind: .proxies, inactiveOnly: true))
            store.refuseWrites(false)
            let manager = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            XCTAssertFalse(manager.isCleared())
            try manager.clear(logger: nil)
            XCTAssertEqual(try store.snapshot().services[0].proxies, original)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
            XCTAssertTrue(manager.isCleared())
        }
    }

    func testWholeRequestBudgetRejectsBeforeJournalCaptureAndReportsWhy() throws {
        try withRecovery { store, journal, recovery, events in
            store.edit { $0.services[0].proxies = ["HTTPProxy": .text(String(repeating: "\u{1}", count: 4096)),
                                                  "HTTPSProxy": .text(String(repeating: "\u{1}", count: 4096))] }
            let original = try store.snapshot()
            let oversized: [String: NetworkSettingValue] = ["HTTPEnable": .number(1)]
            XCTAssertThrowsError(try recovery.apply(kind: .proxies, desired: oversized, config: ProxyConfig()))
            XCTAssertEqual(try store.snapshot(), original)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" && $0.detail?.contains("operation=validate") == true })
        }
    }

    func testLegacyPriorIsNeverRestoredIntoGuessedLocation() throws {
        try withRecovery { store, journal, recovery, events in
            journal.recordPrior(surface: .systemDNS, scope: "Wi-Fi", value: ["servers": "203.0.113.99"])
            store.edit { $0.services[0].dns = localDNS; $0.activeLocationID = office }
            try recovery.clear(kind: .dns, config: ProxyConfig())
            let snapshot = try store.snapshot()
            XCTAssertEqual(snapshot.services[0].dns, [:])
            XCTAssertEqual(snapshot.services[1].dns, ["ServerAddresses": .list(["192.0.2.2"])])
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_legacy_retired" })
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
        }
    }

    func testLegacyRecordRetainsUnmatchedGatewayEndpointUntilResidueIsRemoved() throws {
        try withRecovery { store, journal, recovery, _ in
            journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["webHost": "corporate.example", "webPort": "8080", "webEnabled": "true"])
            let old: [String: NetworkSettingValue] = ["HTTPProxy": .text("192.0.2.25"), "HTTPPort": .number(54321), "HTTPEnable": .number(1)]
            store.edit { $0.services[0].proxies = old; $0.services[1].proxies = [:] }
            var config = ProxyConfig()
            config.gatewayMode = true
            config.localHost = "192.0.2.10"
            XCTAssertThrowsError(try recovery.clear(kind: .proxies, config: config))
            XCTAssertTrue(journal.hasRecords(for: .systemProxy))
            XCTAssertEqual(try store.snapshot().services[0].proxies, old)
            store.edit { $0.services[0].proxies = [:] }
            try recovery.clear(kind: .proxies, config: config)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
        }
    }

    func testLegacyCleanupPreservesUnrelatedCorporateServiceWithoutBlockingRecovery() throws {
        try withRecovery { store, journal, recovery, _ in
            journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["webHost": "old-corporate.example", "webPort": "8080", "webEnabled": "true"])
            let unrelated: [String: NetworkSettingValue] = ["HTTPProxy": .text("other-corporate.example"), "HTTPPort": .number(9090), "HTTPEnable": .number(1)]
            store.edit {
                $0.services[0].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
                $0.services[1].name = "Ethernet"
                $0.services[1].proxies = unrelated
            }
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].proxies, [:])
            XCTAssertEqual(try store.snapshot().services[1].proxies, unrelated)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
        }
    }

    func testLegacyKnownCorporatePriorDoesNotNeedGuessedRestoration() throws {
        try withRecovery { store, journal, recovery, _ in
            journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["webHost": "corporate.example", "webPort": "8080", "webEnabled": "true"])
            let corporate: [String: NetworkSettingValue] = ["HTTPProxy": .text("corporate.example"), "HTTPPort": .number(8080), "HTTPEnable": .number(1)]
            store.edit { $0.services[0].proxies = corporate; $0.services[1].proxies = [:] }
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].proxies, corporate)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
        }
    }

    func testLegacyRecordSurvivesAnUnrecognizedOldListenerPort() throws {
        try withRecovery { store, journal, recovery, events in
            journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["httpHost": "corporate.example"])
            store.edit { $0.services[0].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(54321), "HTTPEnable": .number(1)] }
            XCTAssertThrowsError(try recovery.clear(kind: .proxies, config: ProxyConfig()))
            XCTAssertTrue(journal.hasRecords(for: .systemProxy))
            XCTAssertEqual(try store.snapshot().services[0].proxies["HTTPPort"], .number(54321))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" && $0.detail?.contains("unattributed_proxy_endpoint") == true })
        }
    }

    func testAmbiguousLegacyCleanupDoesNotBlockKnownScopedRestoration() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot().services[0].proxies
            try recovery.apply(kind: .proxies, desired: ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)], config: ProxyConfig())
            journal.recordPrior(surface: .systemProxy, scope: "Legacy service", value: ["httpHost": "corporate.example"])
            store.edit { $0.services[1].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(54321), "HTTPEnable": .number(1)] }
            XCTAssertThrowsError(try recovery.clear(kind: .proxies, config: ProxyConfig()))
            XCTAssertEqual(try store.snapshot().services[0].proxies, original)
            XCTAssertEqual(journal.records(for: .systemProxy).map(\.scope), ["Legacy service"])
            XCTAssertEqual(try store.snapshot().services[1].proxies["HTTPPort"], .number(54321))
        }
    }

    func testReapplyPreservesInitialPriorAndRebasesExternalDNSRewrite() throws {
        try withRecovery { store, _, recovery, _ in
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, ["ServerAddresses": .list(["192.0.2.1"])])
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.edit { $0.services[0].dns = ["ServerAddresses": .list(["192.0.2.10"])] }
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, localDNS)
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, ["ServerAddresses": .list(["192.0.2.10"])])
        }
    }

    func testFailedJournalPersistencePreventsMutation() throws {
        let store = machine()
        let journal = PlatformStateJournal(fileURL: URL(fileURLWithPath: "/dev/null/journal.json"))
        let recovery = LocationSettingsRecovery(store: store, journal: journal, emit: { _ in })
        let original = try store.snapshot()
        XCTAssertThrowsError(try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig()))
        XCTAssertEqual(try store.snapshot(), original)
    }

    func testRecoveryAfterRestartUsesDurableScopedRecords() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("location-restart-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let store = machine()
        let original = try store.snapshot()
        let first = LocationSettingsRecovery(store: store, journal: PlatformStateJournal(fileURL: file), emit: { _ in })
        try first.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
        store.edit { $0.activeLocationID = office }
        let second = LocationSettingsRecovery(store: store, journal: PlatformStateJournal(fileURL: file), emit: { _ in })
        XCTAssertEqual(second.recover(kind: .dns, config: ProxyConfig(), listenerIsLive: false), .restored(stale: false))
        XCTAssertEqual(try store.snapshot().services, original.services)
        XCTAssertEqual(second.recover(kind: .dns, config: ProxyConfig(), listenerIsLive: false), .nothingToDo(.nothingRecorded))
    }

    func testRecoveryProtectsALiveListenerOnThePreviouslyConfiguredPort() throws {
        try withRecovery { store, journal, recovery, _ in
            let desired: [String: NetworkSettingValue] = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(7777), "HTTPEnable": .number(1)]
            try recovery.apply(kind: .proxies, desired: desired, config: ProxyConfig())
            var changedConfig = ProxyConfig()
            changedConfig.localPort = 8888
            let live = try recovery.proxyListenerIsLive(config: changedConfig, probe: { $0 == 7777 })
            XCTAssertTrue(live)
            XCTAssertEqual(recovery.recover(kind: .proxies, config: changedConfig, listenerIsLive: live), .declinedLiveListener)
            XCTAssertEqual(try store.snapshot().services[0].proxies["HTTPPort"], .number(7777))
            XCTAssertTrue(journal.hasRecords(for: .systemProxy))
        }
    }

    func testDisabledOrInactiveEndpointsDoNotProtectAnUnrelatedListener() throws {
        try withRecovery { store, _, recovery, _ in
            let disabled: [String: NetworkSettingValue] = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(7777), "HTTPEnable": .number(0),
                                                          "ProxyAutoConfigEnable": .number(0), "ProxyAutoConfigURLString": .text("http://localhost:7777/proxy.pac")]
            store.edit { $0.services[0].proxies = disabled; $0.services[1].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(7777), "HTTPEnable": .number(1)] }
            XCTAssertFalse(try recovery.proxyListenerIsLive(config: ProxyConfig(), probe: { _ in true }))
            store.edit { $0.services[0].proxies["HTTPEnable"] = .number(1); $0.services[0].enabled = false }
            XCTAssertFalse(try recovery.proxyListenerIsLive(config: ProxyConfig(), probe: { _ in true }))
            store.edit { $0.services[0].enabled = true }
            XCTAssertTrue(try recovery.proxyListenerIsLive(config: ProxyConfig(), probe: { _ in true }))
        }
    }

    func testPACModeWithoutAURLPreservesPriorProxyAndDoesNotCapture() throws {
        try withRecovery { store, journal, recovery, events in
            let original = try store.snapshot()
            let manager = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            XCTAssertFalse(manager.isApplied(config: ProxyConfig(), mode: .pac))
            XCTAssertThrowsError(try manager.apply(config: ProxyConfig(), mode: .pac, logger: nil))
            XCTAssertEqual(try store.snapshot(), original)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
            XCTAssertTrue(events.events.contains { $0.detail?.contains("missing_pac_url") == true })
        }
    }

    func testFailedReapplyRestoresThePreviousAppliedGeneration() throws {
        try withRecovery { store, journal, recovery, _ in
            let original = try store.snapshot()
            let first: [String: NetworkSettingValue] = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
            try recovery.apply(kind: .proxies, desired: first, config: ProxyConfig())
            store.refuseWrites(true)
            var second = first
            second["HTTPPort"] = .number(3129)
            XCTAssertThrowsError(try recovery.apply(kind: .proxies, desired: second, config: ProxyConfig()))
            store.refuseWrites(false)
            try recovery.clear(kind: .proxies, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services, original.services)
            XCTAssertFalse(journal.hasRecords(for: .systemProxy))
        }
    }

    func testLoginwindowRemovesLoopbackAndKeepsPriorForNextLogin() throws {
        try withRecovery { store, journal, recovery, events in
            try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig())
            store.atLoginwindow = true
            XCTAssertThrowsError(try recovery.clear(kind: .dns, config: ProxyConfig()))
            XCTAssertEqual(try store.snapshot().services[0].dns, [:])
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_cleanup_deferred" })
            store.atLoginwindow = false
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertEqual(try store.snapshot().services[0].dns, ["ServerAddresses": .list(["192.0.2.1"])])
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
        }
    }

    func testFailedRestorationStillAttemptsRelayStopWithoutLosingPriorEvidence() throws {
        try withRecovery { store, journal, recovery, events in
            let privilege = RecordingPrivilegeClient()
            let dns = SystemDNSManager(privilegeClient: privilege, journal: journal, locationRecovery: recovery)
            try dns.apply(forwarderPort: 15053, logger: nil)
            store.refuseWrites(true)
            privilege.failing = [.stopDNSRelay]
            XCTAssertThrowsError(try dns.clear(logger: nil)) { error in
                guard case NetworkSettingsError.unavailable = error else { return XCTFail("Relay stop must not replace restoration error") }
            }
            XCTAssertEqual(privilege.commands(matching: .stopDNSRelay).count, 1)
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" && $0.detail?.contains("operation=stop_relay") == true })
            store.refuseWrites(false)
            privilege.failing = []
            try dns.clear(logger: nil)
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
        }
    }

    func testDeferredProxyCleanupRemovesEnableFlagsEvenWhenPriorWasEnabled() throws {
        let pairs: [([String: NetworkSettingValue], [String: NetworkSettingValue], String)] = [
            (["HTTPProxy": .text("corporate.example"), "HTTPPort": .number(8080), "HTTPEnable": .number(1)],
             ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)], "HTTPEnable"),
            (["ProxyAutoConfigURLString": .text("https://corporate.example/proxy.pac"), "ProxyAutoConfigEnable": .number(1)],
             ["ProxyAutoConfigURLString": .text("http://127.0.0.1:8090/proxy.pac"), "ProxyAutoConfigEnable": .number(1)], "ProxyAutoConfigEnable")
        ]
        for (prior, applied, enable) in pairs {
            try withRecovery { store, journal, recovery, _ in
                store.edit { $0.services[0].proxies = prior }
                try recovery.apply(kind: .proxies, desired: applied, config: ProxyConfig())
                store.atLoginwindow = true
                XCTAssertThrowsError(try recovery.clear(kind: .proxies, config: ProxyConfig()))
                XCTAssertNil(try store.snapshot().services[0].proxies[enable])
                XCTAssertTrue(journal.hasRecords(for: .systemProxy))
                store.atLoginwindow = false
                try recovery.clear(kind: .proxies, config: ProxyConfig())
                XCTAssertEqual(try store.snapshot().services[0].proxies, prior)
            }
        }
    }

    func testSameLocationNetworkReconcileRetriesAfterInitiallyDisabledService() throws {
        try withRecovery { store, journal, recovery, _ in
            store.edit { $0.services[0].enabled = false }
            let dns = SystemDNSManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: recovery)
            XCTAssertThrowsError(try dns.apply(forwarderPort: 15053, logger: nil))
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
            store.edit { $0.services[0].enabled = true }
            dns.reconcile(logger: nil, forwarderPort: 15053)
            XCTAssertEqual(try store.snapshot().services[0].dns, localDNS)
            try dns.clear(logger: nil)
        }
    }

    func testLoginwindowDeferredRestorationStopsDNSRelayAndRetainsPrior() throws {
        try withRecovery { store, journal, recovery, _ in
            let privilege = RecordingPrivilegeClient()
            let manager = SystemDNSManager(privilegeClient: privilege, journal: journal, locationRecovery: recovery)
            try manager.apply(forwarderPort: 15053, logger: nil)
            store.atLoginwindow = true
            XCTAssertThrowsError(try manager.clear(logger: nil))
            XCTAssertEqual(privilege.commands(matching: .stopDNSRelay).count, 1)
            XCTAssertNil(journal.records(for: .systemDNS).first?.appliedValue?["previousNetworkSettings"])
            XCTAssertEqual(try store.snapshot().services[0].dns, [:])
            XCTAssertTrue(journal.hasRecords(for: .systemDNS))
            store.atLoginwindow = false
            try manager.clear(logger: nil)
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
        }
    }

    func testRecordCapacityFailsBeforeSecondServiceMutation() throws {
        try withRecovery { store, journal, _, events in
            store.edit { $0.services[1].locationID = home }
            let recovery = LocationSettingsRecovery(store: store, journal: journal,
                                                    limits: .init(maximumRecords: 1), emit: { events.append($0) })
            XCTAssertThrowsError(try recovery.apply(kind: .dns, desired: localDNS, config: ProxyConfig()))
            XCTAssertEqual(journal.records(for: .systemDNS).count, 1)
            XCTAssertEqual(try store.snapshot().services[1].dns, ["ServerAddresses": .list(["192.0.2.2"])])
            try recovery.clear(kind: .dns, config: ProxyConfig())
            XCTAssertFalse(journal.hasRecords(for: .systemDNS))
        }
    }

    func testISO8601JournalMigratesWithoutAssigningLegacyLocation() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("location-legacy-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let legacy = PlatformStateRecord(surface: .systemDNS, scope: "Wi-Fi", priorValue: ["servers": "192.0.2.1"], recordedAt: Date(timeIntervalSince1970: 1234))
        try JSONEncoder.prettyISO8601Encoder.encode([legacy]).write(to: file)
        let journal = PlatformStateJournal(fileURL: file)
        XCTAssertEqual(journal.records(for: .systemDNS), [legacy])
        try journal.recordNetworkState(surface: .systemProxy, locationID: home, serviceID: homeService,
                                       prior: [:], applied: [:], maximumRecords: 2)
        let records = try CanonicalJSON.decoder().decode([PlatformStateRecord].self, from: Data(contentsOf: file))
        XCTAssertNil(records.first?.locationID)
        XCTAssertEqual(records.first?.recordedAt, legacy.recordedAt)
        XCTAssertEqual(records.last?.locationID, home)
    }

    func testRequestRejectsArbitraryKeysMalformedIdentitiesAndCredentials() throws {
        var request = NetworkSettingsRequest(locationID: home, serviceID: homeService, kind: .proxies,
                                             expected: [:], replacement: ["HTTPProxy": .text("127.0.0.1")], requireActive: true)
        XCTAssertNoThrow(try NetworkSettingsRequest.decode(request.encoded()))
        request.replacement["HTTPPassword"] = .text("never accepted")
        XCTAssertThrowsError(try request.validate())
        request.replacement = ["ProxyAutoConfigURLString": .text("https://user:password@example.com/proxy.pac")]
        XCTAssertThrowsError(try request.validate())
        request.replacement = [:]
        request.locationID = "../other"
        XCTAssertThrowsError(try request.validate())
    }
}

private final class ManualInstant: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    var value: ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ duration: Duration) { lock.withLock { current = current.advanced(by: duration) } }
}
