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
            let original = try store.snapshot()
            let oversized: [String: NetworkSettingValue] = ["ExceptionsList": .list(Array(repeating: String(repeating: "a", count: 253), count: 256))]
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

    func testLegacyRecordSurvivesAnUnrecognizedOldListenerPort() throws {
        try withRecovery { store, journal, recovery, events in
            journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["httpHost": "corporate.example"])
            store.edit { $0.services[0].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(54321), "HTTPEnable": .number(1)] }
            XCTAssertThrowsError(try recovery.clear(kind: .proxies, config: ProxyConfig()))
            XCTAssertTrue(journal.hasRecords(for: .systemProxy))
            XCTAssertEqual(try store.snapshot().services[0].proxies["HTTPPort"], .number(54321))
            XCTAssertTrue(events.events.contains { $0.event == "platform.location_failed" && $0.detail?.contains("unattributed_loopback_endpoint") == true })
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
