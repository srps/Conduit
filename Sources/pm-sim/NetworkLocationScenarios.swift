// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel
import ConduitShared

enum NetworkLocationScenarios {
    static func recovery() throws -> ScenarioResult {
        let began = Date()
        let home = "11111111-1111-1111-1111-111111111111"
        let office = "22222222-2222-2222-2222-222222222222"
        let services = [
            LocationServiceSettings(locationID: home, serviceID: "33333333-3333-3333-3333-333333333333",
                                    name: "Wi-Fi", enabled: true, proxies: [:], dns: ["ServerAddresses": .list(["192.0.2.1"])]),
            LocationServiceSettings(locationID: office, serviceID: "44444444-4444-4444-4444-444444444444",
                                    name: "Wi-Fi", enabled: true, proxies: [:], dns: ["ServerAddresses": .list(["192.0.2.2"])])
        ]
        let store = FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: services))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pm-location-\(UUID()).json")
        let corruptFile = FileManager.default.temporaryDirectory.appendingPathComponent("pm-location-corrupt-\(UUID()).json")
        defer {
            for journalFile in [file, corruptFile] where FileManager.default.fileExists(atPath: journalFile.path) {
                do { try FileManager.default.removeItem(at: journalFile) }
                catch { fputs("network-location-recovery journal cleanup failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        let journal = PlatformStateJournal(fileURL: file)
        let events = RuntimeEventLog(capacity: 64)
        let recovery = LocationSettingsRecovery(store: store, journal: journal, emit: { events.append($0) })
        let config = ProxyConfig()
        let localDNS: [String: NetworkSettingValue] = ["ServerAddresses": .list(["127.0.0.1"])]
        try recovery.apply(kind: .dns, desired: localDNS, config: config)
        store.edit { $0.activeLocationID = office }
        try recovery.apply(kind: .dns, desired: localDNS, config: config)
        let switched = try store.snapshot()
        let inactiveRecovered = switched.services[0].dns == services[0].dns && switched.services[1].dns == localDNS
        store.refuseWrites(true)
        var restoreFailed = false
        do { try recovery.clear(kind: .dns, config: config) }
        catch { restoreFailed = journal.hasRecords(for: .systemDNS) }
        store.refuseWrites(false)
        // The administrator replaces DNS before the retry. Recovery must preserve that edit.
        let external: [String: NetworkSettingValue] = ["ServerAddresses": .list(["192.0.2.9"])]
        store.edit { $0.services[1].dns = external; $0.services[1].name = "Renamed Wi-Fi" }
        try recovery.clear(kind: .dns, config: config)
        try recovery.clear(kind: .dns, config: config)
        let externalPreserved = try store.snapshot().services[1].dns == external
        store.switchDuringNextWrite(to: home)
        var racedApplyRejected = false
        do { try recovery.apply(kind: .dns, desired: localDNS, config: config) }
        catch { racedApplyRejected = true }
        try recovery.clear(kind: .dns, config: config)
        let beforePAC = try store.snapshot()
        var emptyPACRejected = false
        do {
            try recovery.apply(kind: .proxies, desired: ["ProxyAutoConfigEnable": .number(1), "ProxyAutoConfigURLString": .text("")], config: config)
        } catch NetworkSettingsError.invalidRequest { emptyPACRejected = true }
        let afterPAC = try store.snapshot()
        let invalidPACPreservedPrior = emptyPACRejected && afterPAC == beforePAC
        let cleanup = NetworkSettingsRequest(locationID: home, serviceID: services[0].serviceID, kind: .proxies,
            expected: ["HTTPProxy": .text("127.0.0.2"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)],
            replacement: [:], requireActive: false)
        try recovery.apply(kind: .proxies, desired: cleanup.expected, config: config)
        store.edit { $0.activeLocationID = office }
        store.refuseWrites(true)
        do { try recovery.restore(kind: .proxies, inactiveOnly: true) }
        catch { /* Recovery emits the failure and retains its record for the retry below. */ }
        let outstandingPreventsSkip = !recovery.isCleared(kind: .proxies)
        store.refuseWrites(false)
        try recovery.clear(kind: .proxies, config: config)
        let inactiveProxyRestored = try store.snapshot().services[0].proxies == beforePAC.services[0].proxies
        store.edit { $0.activeLocationID = home }
        store.edit { $0.services[0].proxies = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(7777), "HTTPEnable": .number(0)] }
        let disabledIgnored = try !recovery.proxyListenerIsLive(config: config, probe: { _ in true })
        let beforeOversized = try store.snapshot()
        var oversizedRejected = false
        do {
            try recovery.apply(kind: .proxies, desired: ["ExceptionsList": .list(Array(repeating: String(repeating: "a", count: 253), count: 256))], config: config)
        } catch NetworkSettingsError.invalidRequest { oversizedRejected = true }
        let afterOversized = try store.snapshot()
        var invalidBypassConfig = config
        invalidBypassConfig.noProxyHosts = Array(repeating: "short.example", count: 257)
        let bypassWarningAtBoundary = invalidBypassConfig.validate().contains {
            !$0.blocksProxyStart && $0.errorDescription?.hasPrefix("routing.noProxyHosts:") == true
        }
        let retryStore = FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: services))
        let retryRecovery = LocationSettingsRecovery(store: retryStore, journal: journal, emit: { events.append($0) })
        let retryProxy = SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: retryRecovery)
        let retryDNS = SystemDNSManager(privilegeClient: RecordingPrivilegeClient(), journal: journal, locationRecovery: retryRecovery)
        try retryProxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true)
        try retryDNS.apply(forwarderPort: 15053, logger: nil)
        retryStore.edit { $0.activeLocationID = "55555555-5555-5555-5555-555555555555" }
        var emptyFailures = 0
        do { try retryProxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true) }
        catch NetworkSettingsError.unavailable { emptyFailures += 1 }
        do { try retryDNS.reconcileLocation(apply: true, forwarderPort: 15053) }
        catch NetworkSettingsError.unavailable { emptyFailures += 1 }
        let emptyReleased = !journal.hasRecords(for: .systemProxy) && !journal.hasRecords(for: .systemDNS)
        retryStore.edit { $0.activeLocationID = office }
        try retryProxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true)
        try retryDNS.reconcileLocation(apply: true, forwarderPort: 15053)
        let retrySnapshot = try retryStore.snapshot()
        let emptyRetrySucceeded = emptyFailures == 2 && emptyReleased
            && retrySnapshot.services[1].proxies["HTTPProxy"] == .text(config.effectiveClientHost)
            && retrySnapshot.services[1].dns == localDNS
        try retryProxy.clear(logger: nil)
        try retryDNS.clear(logger: nil)
        retryStore.edit { $0.activeLocationID = home }
        let beforeStoppedRecovery = try retryStore.snapshot()
        try retryProxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: true)
        try retryDNS.apply(forwarderPort: 15053, logger: nil)
        retryStore.edit { $0.activeLocationID = office }
        retryStore.refuseWrites(true)
        do { try retryProxy.clear(logger: nil) }
        catch { /* Retained proxy records are retried after returning to home. */ }
        do { try retryDNS.clear(logger: nil) }
        catch { /* Retained DNS records are retried after returning to home. */ }
        let stoppedRecordsRetained = journal.hasRecords(for: .systemProxy) && journal.hasRecords(for: .systemDNS)
        retryStore.refuseWrites(false)
        retryStore.edit { $0.activeLocationID = home }
        try retryProxy.reconcileLocation(config: config, mode: .manual, localPACURL: nil, apply: false)
        try retryDNS.reconcileLocation(apply: false, forwarderPort: 0)
        let stoppedActiveRestored = try stoppedRecordsRetained && retryStore.snapshot().services == beforeStoppedRecovery.services
            && !journal.hasRecords(for: .systemProxy) && !journal.hasRecords(for: .systemDNS)
        let relayPrivilege = RecordingPrivilegeClient()
        let relayDNS = SystemDNSManager(privilegeClient: relayPrivilege, journal: journal, locationRecovery: retryRecovery)
        retryStore.edit { $0.activeLocationID = home }
        try relayDNS.apply(forwarderPort: 15053, logger: nil)
        retryStore.edit { $0.activeLocationID = office }
        relayPrivilege.failing = [.startDNSRelay]
        var failedRelayWithheld = false
        do { try relayDNS.reconcileLocation(apply: true, forwarderPort: 15053) }
        catch { failedRelayWithheld = true }
        let afterRelayFailure = try retryStore.snapshot()
        let relayFailurePreserved = failedRelayWithheld && afterRelayFailure.services[0].dns == services[0].dns
            && afterRelayFailure.services[1].dns == services[1].dns && !journal.hasRecords(for: .systemDNS)
        relayPrivilege.failing = []
        try relayDNS.reconcileLocation(apply: true, forwarderPort: 15053)
        let relayRetryApplied = try retryStore.snapshot().services[1].dns == localDNS
        try relayDNS.clear(logger: nil)
        let oldProxy: [String: NetworkSettingValue] = ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(3128), "HTTPEnable": .number(1)]
        var newProxy = oldProxy
        newProxy["HTTPPort"] = .number(4218)
        try retryRecovery.apply(kind: .proxies, desired: oldProxy, config: config)
        try retryRecovery.apply(kind: .proxies, desired: newProxy, config: config)
        retryStore.edit { $0.services[1].proxies = oldProxy }
        try retryRecovery.clear(kind: .proxies, config: config)
        let externalPreviousPreserved = try retryStore.snapshot().services[1].proxies == oldProxy
        retryStore.edit { $0.services[1].proxies = [:] }
        retryStore.conflictNextWrites(1)
        try retryRecovery.apply(kind: .dns, desired: localDNS, config: config)
        let compareRetrySucceeded = try retryStore.snapshot().services[1].dns == localDNS
        try retryRecovery.clear(kind: .dns, config: config)
        retryStore.conflictNextWrites(10)
        var retryExhausted = false
        do { try retryRecovery.apply(kind: .dns, desired: localDNS, config: config) }
        catch { retryExhausted = retryStore.pendingCompareFailures == 8 && journal.hasRecords(for: .systemDNS) }
        retryStore.conflictNextWrites(0)
        try retryRecovery.clear(kind: .dns, config: config)
        retryStore.edit { $0.services[1].enabled = false }
        do { try relayDNS.apply(forwarderPort: 15053, logger: nil) }
        catch NetworkSettingsError.unavailable { /* Empty service failure is observable. */ }
        retryStore.edit { $0.services[1].enabled = true }
        relayDNS.reconcile(logger: nil, forwarderPort: 15053)
        let sameLocationRetryApplied = try retryStore.snapshot().services[1].dns == localDNS
        try relayDNS.clear(logger: nil)
        let gatewayStore = FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: services))
        let gatewayRecovery = LocationSettingsRecovery(store: gatewayStore, journal: journal, emit: { events.append($0) })
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["webHost": "corporate.example", "webPort": "8080", "webEnabled": "true"])
        gatewayStore.edit { $0.services[0].proxies = ["HTTPProxy": .text("192.0.2.25"), "HTTPPort": .number(54321), "HTTPEnable": .number(1)] }
        var gatewayConfig = config
        gatewayConfig.gatewayMode = true
        gatewayConfig.localHost = "192.0.2.10"
        var gatewayLegacyRetained = false
        do { try gatewayRecovery.clear(kind: .proxies, config: gatewayConfig) }
        catch { gatewayLegacyRetained = journal.hasRecords(for: .systemProxy) }
        gatewayStore.edit { $0.services[0].proxies = [:] }
        try gatewayRecovery.clear(kind: .proxies, config: gatewayConfig)
        journal.recordPrior(surface: .systemProxy, scope: "Wi-Fi", value: ["webHost": "old-corporate.example", "webPort": "8080", "webEnabled": "true"])
        let unrelatedCorporate: [String: NetworkSettingValue] = ["HTTPProxy": .text("other-corporate.example"), "HTTPPort": .number(9090), "HTTPEnable": .number(1)]
        gatewayStore.edit {
            $0.services[0].proxies = oldProxy
            $0.services[1].name = "Ethernet"
            $0.services[1].proxies = unrelatedCorporate
        }
        try gatewayRecovery.clear(kind: .proxies, config: config)
        let unrelatedCorporatePreserved = try gatewayStore.snapshot().services[1].proxies == unrelatedCorporate
        let corrupt = Data("{broken}".utf8)
        try corrupt.write(to: corruptFile)
        let corruptJournal = PlatformStateJournal(fileURL: corruptFile)
        let corruptStore = FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: services))
        corruptStore.edit {
            $0.services[0].proxies = ["HTTPProxy": .text(config.effectiveClientHost), "HTTPPort": .number(config.localPort), "HTTPEnable": .number(1)]
            $0.services[0].dns = localDNS
        }
        let corruptRecovery = LocationSettingsRecovery(store: corruptStore, journal: corruptJournal, emit: { events.append($0) })
        var corruptFailures = 0
        for kind in [NetworkSettingsKind.proxies, .dns] {
            if case .failed = corruptRecovery.recover(kind: kind, config: config, listenerIsLive: false) { corruptFailures += 1 }
        }
        corruptJournal.markReleased(surface: .launchdEnvironment)
        let corruptSnapshot = try corruptStore.snapshot()
        let corruptEvidencePreserved = try Data(contentsOf: corruptFile) == corrupt
        let corruptResidueCleared = corruptSnapshot.services[0].proxies.isEmpty && corruptSnapshot.services[0].dns.isEmpty
        let corruptHome = FileManager.default.temporaryDirectory.appendingPathComponent("pm-location-home-\(UUID())")
        try FileManager.default.createDirectory(at: corruptHome, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: corruptHome) }
            catch { fputs("network-location-recovery home cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        let machine = FakeMachine(resolverDirectory: corruptHome)
        let environment = EnvironmentManager(journal: corruptJournal, homeDirectory: corruptHome, commandRunner: machine.run)
        let resolvers = DNSManager(privilegeClient: machine, resolverDirectory: corruptHome.path, journal: corruptJournal)
        var resolverConfig = config
        resolverConfig.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.1"])]
        var environmentBlocked = false
        var resolverBlocked = false
        do { try environment.apply(config: config, logger: nil) }
        catch { environmentBlocked = true }
        do { try resolvers.applyEntryFiles(config: resolverConfig, logger: nil) }
        catch { resolverBlocked = true }
        let newSurfaceWritesBlocked = environmentBlocked && resolverBlocked && machine.privilege.commands.isEmpty
            && environment.targetFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) }
        store.edit { $0.services[0].proxies = [:] }
        let dnsPrivilege = RecordingPrivilegeClient()
        let dnsManager = SystemDNSManager(privilegeClient: dnsPrivilege, journal: journal, locationRecovery: recovery)
        try dnsManager.apply(forwarderPort: 15053, logger: nil)
        store.atLoginwindow = true
        var cleanupDeferred = false
        do { try dnsManager.clear(logger: nil) }
        catch PrivilegeClientError.refused(.noConsoleUser, _) { cleanupDeferred = true }
        let deferredRelayStopped = cleanupDeferred && dnsPrivilege.commands(matching: .stopDNSRelay).count == 1 && journal.hasRecords(for: .systemDNS)
            && journal.records(for: .systemDNS).first?.appliedValue?["previousNetworkSettings"] == nil
        store.atLoginwindow = false
        try dnsManager.clear(logger: nil)
        try dnsManager.apply(forwarderPort: 15053, logger: nil)
        store.refuseWrites(true)
        let stopsBeforeFailure = dnsPrivilege.commands(matching: .stopDNSRelay).count
        var ordinaryRestoreFailed = false
        do { try dnsManager.clear(logger: nil) }
        catch { ordinaryRestoreFailed = journal.hasRecords(for: .systemDNS) }
        let failedRestoreRelayStopped = ordinaryRestoreFailed && dnsPrivilege.commands(matching: .stopDNSRelay).count == stopsBeforeFailure + 1
        store.refuseWrites(false)
        try dnsManager.clear(logger: nil)
        let enabledPrior: [String: NetworkSettingValue] = ["HTTPProxy": .text("corporate.example"), "HTTPPort": .number(8080), "HTTPEnable": .number(1)]
        store.edit { $0.services[0].proxies = enabledPrior }
        try recovery.apply(kind: .proxies, desired: oldProxy, config: config)
        store.atLoginwindow = true
        do { try recovery.clear(kind: .proxies, config: config) }
        catch PrivilegeClientError.refused(.noConsoleUser, _) { /* Prior stays recorded until login. */ }
        let cleanupProxy = try store.snapshot().services[0].proxies
        let proxyDisabledOnDeferredCleanup = cleanupProxy["HTTPProxy"] == nil && cleanupProxy["HTTPEnable"] == nil
        store.atLoginwindow = false
        try recovery.clear(kind: .proxies, config: config)
        return ScenarioResult(
            name: "network-location-recovery", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("inactive location restored without applying its values to the new location", inactiveRecovered),
                .init("interrupted recovery retains durable evidence", restoreFailed),
                .init("external edit and rename survive retry and repeated recovery", externalPreserved),
                .init("external switch racing apply rejects stale active-location write", racedApplyRejected),
                .init("recovery releases all records", !journal.hasRecords(for: .systemDNS)),
                .init("empty PAC URL cannot overwrite prior proxy settings", invalidPACPreservedPrior),
                .init("loginwindow cleanup accepts non-default IPv4 loopback", cleanup.isCleanup),
                .init("disabled endpoint cannot protect an unrelated listener", disabledIgnored),
                .init("inactive recovery failure cannot skip teardown on an empty active location", outstandingPreventsSkip && inactiveProxyRestored),
                .init("oversized request rejects before journal capture or mutation", oversizedRejected && beforeOversized == afterOversized && !journal.hasRecords(for: .systemProxy)),
                .init("manual bypass limits warn without blocking routing or PAC startup", bypassWarningAtBoundary),
                .init("corrupt journal recovery clears recognized residue and preserves evidence", corruptFailures == 2 && corruptResidueCleared && corruptEvidencePreserved && !corruptRecovery.isCleared(kind: .dns)),
                .init("unreadable journal withholds new environment and resolver publication", newSurfaceWritesBlocked),
                .init("apply retries in a valid location after an empty location released all records", emptyRetrySucceeded),
                .init("stopped reconciliation restores retained records after returning to their location", stoppedActiveRestored),
                .init("failed relay start still restores inactive DNS, withholds active redirection, and retries later", relayFailurePreserved && relayRetryApplied),
                .init("successful reapply no longer claims external edits back to the previous generation", externalPreviousPreserved),
                .init("same-location compare failures retry with a fixed budget and retain evidence on exhaustion", compareRetrySucceeded && retryExhausted),
                .init("loginwindow deferred prior restoration still stops the DNS relay", deferredRelayStopped),
                .init("ordinary restoration failure still stops the relay and keeps retry evidence", failedRestoreRelayStopped),
                .init("malformed scoped admission retains its invalid-arguments diagnostic", HelperAdmission.scopedSettingsAdmission(values: ["{broken}"]) == .invalidArguments),
                .init("same-location network reconcile retries DNS after an initially unavailable service", sameLocationRetryApplied),
                .init("unmatched legacy gateway endpoints retain recovery evidence", gatewayLegacyRetained),
                .init("unrelated corporate service does not block legacy recovery", unrelatedCorporatePreserved),
                .init("deferred proxy cleanup removes enable flags with endpoints", proxyDisabledOnDeferredCleanup),
                .init("observable recovery and failure decisions", events.events.contains { $0.event == "platform.location_restore" }
                      && events.events.contains { $0.event == "platform.location_failed" })
            ], notes: ["fake locations only; no system settings, helpers, or serving listeners touched"]
        )
    }
}
