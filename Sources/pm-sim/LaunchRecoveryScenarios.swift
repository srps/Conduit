// SPDX-License-Identifier: Apache-2.0
import Darwin
import Foundation
import PlatformMac
import ProxyKernel

enum LaunchRecoveryScenarios {
    private struct Failure: Error, CustomStringConvertible { let description: String }

    private final class RelayHelper: PrivilegeClient, @unchecked Sendable {
        let relay = UDPRelay()
        let recording = RecordingPrivilegeClient()

        func dnsRelayStatus() throws -> DNSRelayStatus? { try relay.status() }

        func execute(_ operation: PrivilegedOperation, values: [String]) throws {
            try execute(batch: [PrivilegedBatchStep(operation, values)])
        }

        func execute(batch: [PrivilegedBatchStep]) throws {
            try recording.execute(batch: batch)
            if batch.contains(where: { $0.operation == .stopDNSRelay }) { relay.stop() }
        }
    }

    static func ownership() throws -> ScenarioResult {
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
                catch { fputs("launch-recovery-ownership journal cleanup failed: \(error.localizedDescription)\n", stderr) }
            }
        }
        let config = ProxyConfig()
        let journal = PlatformStateJournal(fileURL: file)
        let crashed = LocationSettingsRecovery(store: store, journal: journal, emit: { _ in })
        func crash() throws {
            try crashed.apply(kind: .dns, desired: ["ServerAddresses": .list(["127.0.0.1"])], config: config)
        }
        func dnsDecision(_ events: [RuntimeEvent]) -> String? {
            events.first {
                ["platform.launch_recovery_restored", "platform.launch_recovery_declined"].contains($0.event)
                    && $0.detail?.hasPrefix("surface=systemDNS") == true
            }
                .map { "\($0.event) \($0.detail ?? "")" }
        }

        try crash()
        try crashed.apply(kind: .proxies, desired: ["HTTPProxy": .text("127.0.0.1"), "HTTPPort": .number(config.localPort),
                                                     "HTTPEnable": .number(1)], config: config)
        let applied = try store.snapshot()
        let oldHelper = launch(store: store, journal: journal, helper: RecordingPrivilegeClient(),
                               dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe(timingOut: [config.localPort]))
        let declined = oldHelper.filter { $0.event == "platform.launch_recovery_declined" }.compactMap(\.detail)
        let oldHelperLeftAlone = try store.snapshot() == applied
            && journal.hasRecords(for: .systemDNS) && journal.hasRecords(for: .systemProxy)

        let gone = launch(store: store, journal: journal, helper: RecordingPrivilegeClient(), dns: FakeDNSProbe(), proxy: FakeLoopbackPortProbe())
        let restored = gone.filter { $0.event == "platform.launch_recovery_restored" }.compactMap(\.detail)
        let goneRestored = try store.snapshot().services == services
            && !journal.hasRecords(for: .systemDNS) && !journal.hasRecords(for: .systemProxy)

        try crash()
        let refusing = RecordingPrivilegeClient()
        refusing.relayStatus = .relaying(targetPort: 5354, target: .refused)
        let witnessed = launch(store: store, journal: journal, helper: refusing, dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe())
        let witnessRestored = try dnsDecision(witnessed) == "platform.launch_recovery_restored surface=systemDNS stale=false evidence=relay_target_refused"
            && store.snapshot().services == services && !journal.hasRecords(for: .systemDNS)
            && refusing.commands(matching: .stopDNSRelay).count == 1

        try crash()
        let rebinding = RecordingPrivilegeClient()
        rebinding.relayStatus = .relaying(targetPort: 5354, target: .refused)
        let rebound = launch(store: store, journal: journal, helper: rebinding, dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe(),
                             recheck: { _ in rebinding.relayStatus = .relaying(targetPort: 5354, target: .answered) })
        let reboundDeclined = dnsDecision(rebound) == "platform.launch_recovery_declined surface=systemDNS reason=live_listener evidence=relay_target_answered"
            && journal.hasRecords(for: .systemDNS) && rebinding.commands(matching: .stopDNSRelay).isEmpty

        let secondRoot = RecordingPrivilegeClient()
        secondRoot.relayStatus = .relaying(targetPort: 5354, target: .answered)
        let live = launch(store: store, journal: journal, helper: secondRoot, dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe())
        let liveDeclined = dnsDecision(live) == "platform.launch_recovery_declined surface=systemDNS reason=live_listener evidence=relay_target_answered"
            && journal.hasRecords(for: .systemDNS)

        let unreachable = launch(store: store, journal: journal, helper: RecordingPrivilegeClient(error: PrivilegeClientError.timedOut("busy")),
                                 dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe())
        let unreachableDeclined = dnsDecision(unreachable)
            == "platform.launch_recovery_declined surface=systemDNS reason=probe_inconclusive witness=helper_unavailable"

        let real = RelayHelper()
        defer { real.relay.stop() }
        try real.relay.start(listenPort: 0, targetPort: try closedPort())
        let realLaunch = launch(store: store, journal: journal, helper: real, dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe())
        let realRestored = try dnsDecision(realLaunch) == "platform.launch_recovery_restored surface=systemDNS stale=false evidence=relay_target_refused"
            && store.snapshot().services == services && !journal.hasRecords(for: .systemDNS)
            && real.relay.status() == .notRunning

        let corrupt = file.deletingLastPathComponent().appendingPathComponent("pm-launch-recovery-corrupt-\(UUID()).json")
        defer {
            do { try FileManager.default.removeItem(at: corrupt) }
            catch { fputs("launch-recovery-ownership corrupt journal cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        try Data("not json".utf8).write(to: corrupt)
        store.edit { $0.services[0].dns = ["ServerAddresses": .list(["127.0.0.1"])] }
        try real.relay.start(listenPort: 0, targetPort: try closedPort())
        let corruptLaunch = launch(store: store, journal: PlatformStateJournal(fileURL: corrupt), helper: real,
                                   dns: FakeDNSProbe(timingOut: [53]), proxy: FakeLoopbackPortProbe())
        let orphanStopped = try corruptLaunch.contains { $0.event == "platform.launch_recovery_failed" && $0.detail?.hasPrefix("surface=systemDNS") == true }
            && store.snapshot().services[0].dns["ServerAddresses"] != .list(["127.0.0.1"])
            && real.relay.status() == .notRunning

        return ScenarioResult(
            name: "launch-recovery-ownership", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("with no witness, timed-out probes decline both surfaces with an event", declined == [
                    "surface=systemDNS reason=probe_inconclusive witness=no_status", "surface=systemProxy reason=probe_inconclusive",
                ]),
                .init("a declined launch leaves the settings and their records alone", oldHelperLeftAlone),
                .init("refused probes restore both surfaces on the next launch", restored == [
                    "surface=systemDNS stale=false evidence=port_refused witness=no_status", "surface=systemProxy stale=false evidence=port_refused",
                ]),
                .init("the next launch puts the prior settings back and releases the records", goneRestored),
                .init("a crash whose relay target the helper finds refused is restored, and the relay stopped", witnessRestored),
                .init("a refusal the second reading contradicts is a live forwarder, left alone", reboundDeclined),
                .init("a relay target that answers is a live session, left alone", liveDeclined),
                .init("a helper that cannot be asked falls back to the probe, and declines", unreachableDeclined),
                .init("a real relay aimed at a closed port is read as refused, restored and stopped", realRestored),
                .init("with an unreadable journal, a refused relay target clears the leftover settings and stops the relay", orphanStopped),
            ],
            notes: [oldHelper, gone, witnessed, rebound, live, unreachable, realLaunch, corruptLaunch].flatMap { $0 }.map { "\($0.event) \($0.detail ?? "")" }
        )
    }

    private static func launch(store: FakeNetworkLocationStore, journal: PlatformStateJournal, helper: any PrivilegeClient,
                               dns: FakeDNSProbe, proxy: FakeLoopbackPortProbe,
                               recheck: @escaping @Sendable (TimeInterval) -> Void = { _ in }) -> [RuntimeEvent] {
        let events = RuntimeEventLog(capacity: 16)
        let recovery = LocationSettingsRecovery(store: store, journal: journal, emit: { events.append($0) })
        LaunchRecovery.recoverPlatformSurfaces(
            systemDNS: SystemDNSManager(privilegeClient: helper, journal: journal, resolverLiveness: dns.liveness(onPort:),
                                        relayRecheckPause: recheck, locationRecovery: recovery),
            systemProxy: SystemProxyManager(privilegeClient: RecordingPrivilegeClient(), journal: journal,
                                            portProbe: proxy.liveness(port:), locationRecovery: recovery),
            resolvers: nil,
            legacyResolvers: nil,
            emit: { events.append($0) },
            logger: nil
        )
        return events.events
    }

    private static func closedPort() throws -> Int {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { throw Failure(description: "socket: \(String(cString: strerror(errno)))") }
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, length) == 0 && getsockname(fd, $0, &length) == 0 }
        }
        guard bound else { throw Failure(description: "bind or getsockname: \(String(cString: strerror(errno)))") }
        return Int(UInt16(bigEndian: address.sin_port))
    }
}
