// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

enum LaunchRecoveryScenarios {
    static func inconclusiveProbe() throws -> ScenarioResult {
        let began = Date()
        let home = "11111111-1111-1111-1111-111111111111"
        let services = [
            LocationServiceSettings(locationID: home, serviceID: "33333333-3333-3333-3333-333333333333", name: "Wi-Fi", enabled: true,
                                    proxies: [:], dns: ["ServerAddresses": .list(["192.0.2.1"])])
        ]
        let store = FakeNetworkLocationStore(snapshot: .init(activeLocationID: home, services: services))
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pm-launch-recovery-\(UUID()).json")
        defer {
            if FileManager.default.fileExists(atPath: file.path) {
                do { try FileManager.default.removeItem(at: file) }
                catch { fputs("launch-recovery-inconclusive-probe journal cleanup failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        let config = ProxyConfig()
        let journal = PlatformStateJournal(fileURL: file)
        let crashed = LocationSettingsRecovery(store: store, journal: journal, emit: { _ in })
        try crashed.apply(kind: .dns, desired: ["ServerAddresses": .list(["127.0.0.1"])], config: config)
        try crashed.apply(kind: .proxies, desired: ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(config.localPort),
                                                     "HTTPEnable": .number(1)], config: config)
        let applied = try store.snapshot()

        let slow = launch(store: store, journal: journal,
                          dns: FakeDNSProbe(timingOut: [53]),
                          proxy: FakeLoopbackPortProbe(timingOut: [config.localPort]))
        let declined = slow.filter { $0.event == "platform.launch_recovery_declined" }.compactMap(\.detail)
        let slowLeftAlone = try store.snapshot() == applied
            && journal.hasRecords(for: .systemDNS) && journal.hasRecords(for: .systemProxy)

        let gone = launch(store: store, journal: journal, dns: FakeDNSProbe(), proxy: FakeLoopbackPortProbe())
        let restored = gone.filter { $0.event == "platform.launch_recovery_restored" }.compactMap(\.detail)
        let goneRestored = try store.snapshot().services == services
            && !journal.hasRecords(for: .systemDNS) && !journal.hasRecords(for: .systemProxy)

        try crashed.apply(kind: .dns, desired: ["ServerAddresses": .list(["127.0.0.1"])], config: config)
        let again = launch(store: store, journal: journal, dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe())
        let declinedAgain = again.contains { $0.event == "platform.launch_recovery_declined" && $0.detail == "surface=systemDNS reason=probe_inconclusive" }
        let helper = RecordingPrivilegeClient()
        let session = SystemDNSManager(privilegeClient: helper, journal: journal, resolverLiveness: FakeDNSProbe().liveness(onPort:),
                                       locationRecovery: LocationSettingsRecovery(store: store, journal: journal, emit: { _ in }))
        try session.saveCurrentDNS(logger: nil)
        try session.apply(forwarderPort: 5354, logger: nil)
        let startRepointed = helper.commands(matching: .startDNSRelay).last == ["5354"] && journal.hasRecords(for: .systemDNS)
        try session.clear(logger: nil)
        let stopRestored = try store.snapshot().services == services && !journal.hasRecords(for: .systemDNS)
            && helper.commands(matching: .stopDNSRelay).count == 1

        return ScenarioResult(
            name: "launch-recovery-inconclusive-probe", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("timed-out probes decline both surfaces with an event", declined == [
                    "surface=systemDNS reason=probe_inconclusive", "surface=systemProxy reason=probe_inconclusive",
                ]),
                .init("a declined launch leaves the settings and their records alone", slowLeftAlone),
                .init("refused probes restore both surfaces on the next launch", restored == [
                    "surface=systemDNS stale=false", "surface=systemProxy stale=false",
                ]),
                .init("the next launch puts the prior settings back and releases the records", goneRestored),
                .init("a silent relay after another crash is declined again", declinedAgain),
                .init("a DNS Start after the decline points the relay at its forwarder and keeps the record", startRepointed),
                .init("a DNS Stop after that Start puts the recorded servers back", stopRestored),
            ],
            notes: (slow + gone + again).map { "\($0.event) \($0.detail ?? "")" }
        )
    }

    private static func launch(store: FakeNetworkLocationStore, journal: PlatformStateJournal, dns: FakeDNSProbe,
                               proxy: FakeLoopbackPortProbe) -> [RuntimeEvent] {
        let events = RuntimeEventLog(capacity: 16)
        let recovery = LocationSettingsRecovery(store: store, journal: journal, emit: { events.append($0) })
        LaunchRecovery.recoverPlatformSurfaces(
            systemDNS: SystemDNSManager(privilegeClient: RecordingPrivilegeClient(), journal: journal,
                                        resolverLiveness: dns.liveness(onPort:), locationRecovery: recovery),
            systemProxy: SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal,
                                            portProbe: proxy.liveness(port:), locationRecovery: recovery),
            resolvers: nil,
            legacyResolvers: nil,
            emit: { events.append($0) },
            logger: nil
        )
        return events.events
    }
}
