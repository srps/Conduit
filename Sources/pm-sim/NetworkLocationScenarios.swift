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
        defer {
            do { try FileManager.default.removeItem(at: file) }
            catch { fputs("network-location-recovery journal cleanup failed: \(error.localizedDescription)\n", stderr) }
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
        let bypassRejectedAtBoundary = invalidBypassConfig.validate().contains {
            $0.blocksProxyStart && $0.errorDescription?.hasPrefix("routing.noProxyHosts:") == true
        }
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
                .init("bypass limits reject configuration before startup", bypassRejectedAtBoundary),
                .init("observable recovery and failure decisions", events.events.contains { $0.event == "platform.location_restore" }
                      && events.events.contains { $0.event == "platform.location_failed" })
            ], notes: ["fake locations only; no system settings, helpers, or serving listeners touched"]
        )
    }
}
