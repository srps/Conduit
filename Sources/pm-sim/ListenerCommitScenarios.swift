// SPDX-License-Identifier: Apache-2.0
import Foundation
import ProxyKernel

/// The kernel half of "the runtime sees committed config only" (#171
/// follow-up), on a real orchestrator with the DNS forwarder up:
///
/// - Every value typed into a listener field on the way to the final one
///   is classified as a listener replacement (`ConfigDiff.replacesListeners`),
///   which is what the app holds for a commit; a bypass edit is not.
/// - The forwarder listens on 127.0.0.1, where the resolver files and the
///   helper relay point, whatever the proxy's listen host: it starts there
///   under an `::1` listen host, and a committed listen-host edit leaves it
///   alone.
/// - A DNS section edit restarts it (`config.dns_restart reason=dns_section`).
///
/// The hold itself, the autosave pause and the commit triggers live in the
/// app's `AppState`, an executable pm-sim cannot link; they are covered end
/// to end by `AppStateHarnessTests`.
enum ListenerCommitScenarios {

    @RuntimeActor
    static func settingsListenerCommit() async throws -> ScenarioResult {
        let name = "settings-listener-commit"
        let began = Date()
        var config = GenericDefaults.shared.makeConfig()
        config.proxy.host = "::1"
        config.proxy.port = 0
        config.dns.forwarderPort = 0
        let orchestrator = ProxyOrchestrator(config: config, logger: DiscardingLogSink())
        ScenarioCleanup.register { await orchestrator.stopDNS() }
        var notes: [String] = []

        // 1. A port typed digit by digit, and a bypass edit.
        let typed = [3, 31, 312, 3128].map { port -> Bool in
            var draft = config
            draft.proxy.port = port
            return ConfigDiff(old: config, new: draft).replacesListeners
        }
        var bypass = config
        bypass.routing.noProxyHosts.append("bypass.example.test")
        let bypassReplaces = ConfigDiff(old: config, new: bypass).replacesListeners
        notes.append("typed=\(typed) bypass=\(bypassReplaces)")

        await orchestrator.startDNS()
        let startedOn = orchestrator.snapshot.bindings.dnsHost
        let startedPort = orchestrator.snapshot.bindings.dnsPort
        func restarts() -> [String] {
            orchestrator.eventLog.events.filter { $0.event == "config.dns_restart" }.compactMap(\.detail)
        }

        // 2. A committed listen-host edit.
        var moved = orchestrator.config
        moved.proxy.host = "127.0.0.2"
        await orchestrator.applyConfigChange(moved)
        let afterHostEdit = (restarts(), orchestrator.snapshot.bindings.dnsHost, orchestrator.snapshot.bindings.dnsPort)

        // 3. A committed DNS section edit.
        var dnsEdit = orchestrator.config
        dnsEdit.dns.dohProviders.removeLast()
        await orchestrator.applyConfigChange(dnsEdit)
        let afterDNSEdit = orchestrator.snapshot.bindings.dnsHost
        notes.append("started=\(startedOn ?? "nil") afterHost=\(afterHostEdit.1 ?? "nil") afterDNS=\(afterDNSEdit ?? "nil") restarts=\(restarts())")
        await orchestrator.stopDNS()

        return ScenarioResult(
            name: name, clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("every value typed into the port is held for a commit", typed.allSatisfy { $0 }),
                .init("a bypass edit is not", !bypassReplaces),
                .init("the forwarder started on 127.0.0.1 under an ::1 listen host", startedOn == "127.0.0.1"),
                .init("a listen-host edit left it running where it was",
                      afterHostEdit.0.isEmpty && afterHostEdit.1 == "127.0.0.1" && afterHostEdit.2 == startedPort),
                .init("a DNS section edit restarted it once, saying why", restarts() == ["reason=dns_section"]),
                .init("still on 127.0.0.1", afterDNSEdit == "127.0.0.1"),
            ],
            notes: notes
        )
    }
}
