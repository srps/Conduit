// SPDX-License-Identifier: Apache-2.0
import NIOPosix
import XCTest
@testable import ProxyKernel

/// The orchestrator's split-DNS table (decision 0044): the manual entries of its own config merged with the rules a
/// host pushed, read by the running forwarder. No host is involved, as in `pm-proxy`.
final class ProxyOrchestratorSplitDNSTests: XCTestCase {
    private let corpIP = "198.51.100.10"
    private let publicIP = "203.0.113.7"

    private struct Running {
        let orchestrator: ProxyOrchestrator
        let corp: FakeSplitDNSServer
        let doh: AnsweringDoHProvider
        var port: Int
    }

    /// An orchestrator with its forwarder started on an ephemeral port. `192.0.2.53` reaches the fake corp server.
    @RuntimeActor private func start(entries: [DomainDNSEntry]) async throws -> Running {
        let corp = try await FakeSplitDNSServer.start(domain: "corp.example", ip: corpIP)
        let doh = try await AnsweringDoHProvider.start(group: MultiThreadedEventLoopGroup.singleton, ip: publicIP)
        var config = ProxyConfig.testFixture()
        config.upstreams = []
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = entries
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        let orchestrator = ProxyOrchestrator(config: config, dnsForwarderTuning: SplitDNSProbe.tuning(["192.0.2.53": corp.port]))
        await orchestrator.startDNS()
        let port = try XCTUnwrap(orchestrator.snapshot.bindings.dnsPort)
        addTeardownBlock {
            await orchestrator.stopDNS()
            await corp.stop()
            try? await doh.channel.close()
        }
        return Running(orchestrator: orchestrator, corp: corp, doh: doh, port: port)
    }

    @RuntimeActor private func tableEvents(_ orchestrator: ProxyOrchestrator) -> [String] {
        orchestrator.eventLog.events.filter { $0.event == "dns.split_table_changed" }.map { $0.detail ?? "" }
    }

    private let pushed = [
        SplitDNSRule(domain: "corp.example", servers: ["192.0.2.53"], origins: [.detected(interface: "utun6")]),
    ]

    @RuntimeActor func testAManualEntryResolvesThroughItsServerWithNoHost() async throws {
        let running = try await start(entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.53"])])

        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(answer, corpIP)
        XCTAssertEqual(running.corp.queryCount("host.corp.example"), 1)
        XCTAssertEqual(running.doh.requestCount(), 0)
        XCTAssertEqual(tableEvents(running.orchestrator), [], "nothing was pushed and the config did not change")
    }

    @RuntimeActor func testPushedRulesRouteTheNextQueryWithoutARestart() async throws {
        let running = try await start(entries: [])
        let display = DetectedSplitDNSDisplay(
            state: .inUse, rows: [.init(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])]
        )
        let cached = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(cached, publicIP, "with no rule the name is public")

        running.orchestrator.applyDetectedSplitDNSRules(pushed, display: display, reason: .pushed)
        let onceInternal = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(onceInternal, corpIP, "the cached public answer is not served once the name is internal")
        XCTAssertEqual(tableEvents(running.orchestrator), ["detected_domains=1 manual_domains=0 rules=1 reason=pushed"])
        XCTAssertEqual(running.orchestrator.snapshot.detectedSplitDNS, display)
        XCTAssertEqual(running.orchestrator.snapshot.bindings.dnsPort, running.port, "the listener was not rebound")
        XCTAssertFalse(running.orchestrator.eventLog.events.contains { $0.event == "config.dns_restart" })

        running.orchestrator.applyDetectedSplitDNSRules(pushed, display: display, reason: .vpnConnected)
        XCTAssertEqual(tableEvents(running.orchestrator).count, 1, "the same rules swap nothing")

        running.orchestrator.applyDetectedSplitDNSRules([], display: .none, reason: .vpnDisconnected)
        XCTAssertEqual(tableEvents(running.orchestrator).last, "detected_domains=0 manual_domains=0 rules=0 reason=vpn_disconnected")
        XCTAssertEqual(running.orchestrator.snapshot.detectedSplitDNS, .none)
    }

    @RuntimeActor func testAConfigChangeRebuildsTheTableAndKeepsThePushedRules() async throws {
        let running = try await start(entries: [])
        let orchestrator = running.orchestrator
        orchestrator.applyDetectedSplitDNSRules(pushed, display: .none, reason: .pushed)

        var edited = orchestrator.config
        edited.dnsEntries = [DomainDNSEntry(domain: "lab.example", servers: ["192.0.2.54"])]
        await orchestrator.applyConfigChange(edited)

        XCTAssertEqual(tableEvents(orchestrator).last, "detected_domains=1 manual_domains=1 rules=2 reason=config")
        let port = try XCTUnwrap(orchestrator.snapshot.bindings.dnsPort)
        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: port)
        XCTAssertEqual(answer, corpIP, "the pushed rule survived the config change")
    }

    @RuntimeActor func testADirectConfigWriteReachesTheRunningForwarder() async throws {
        let running = try await start(entries: [])

        running.orchestrator.config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.53"])]
        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(answer, corpIP)
        XCTAssertEqual(tableEvents(running.orchestrator), ["detected_domains=0 manual_domains=1 rules=1 reason=config"])
    }

    @RuntimeActor func testAConfigWriteThatLeavesTheEntriesAloneSwapsNothing() async throws {
        let orchestrator = ProxyOrchestrator(config: ProxyConfig.testFixture())

        orchestrator.config.verboseLogging.toggle()

        XCTAssertEqual(tableEvents(orchestrator), [])
    }

    func testASnapshotWrittenBeforeTheFieldDecodesAsNone() throws {
        let display = DetectedSplitDNSDisplay(
            state: .held, rows: [.init(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])]
        )
        let encoded = try JSONEncoder().encode(ProxyOrchestratorSnapshot(detectedSplitDNS: display))
        XCTAssertEqual(try JSONDecoder().decode(ProxyOrchestratorSnapshot.self, from: encoded).detectedSplitDNS, display)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "detectedSplitDNS")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertEqual(try JSONDecoder().decode(ProxyOrchestratorSnapshot.self, from: older).detectedSplitDNS, .none)
    }

    func testFollowVPNResolversIsOnWhenTheFileNamesNoValue() throws {
        var config = ProxyConfig.testFixture()
        XCTAssertTrue(config.dns.followVPNResolvers)
        config.dns.followVPNResolvers = false
        let encoded = try JSONEncoder().encode(config)
        XCTAssertFalse(try JSONDecoder().decode(ProxyConfig.self, from: encoded).dns.followVPNResolvers)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "dnsFollowVPNResolvers")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertTrue(try JSONDecoder().decode(ProxyConfig.self, from: older).dns.followVPNResolvers)
    }
}
