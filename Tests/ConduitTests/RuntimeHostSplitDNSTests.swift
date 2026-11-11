// SPDX-License-Identifier: Apache-2.0
import NIOPosix
import XCTest
import ConduitShared
@testable import ConduitRuntime
@testable import PlatformMac
@testable import ProxyKernel

/// Split DNS follows the resolvers a connected VPN pushes (decision 0044), through the actual host over a
/// `FakeMachine`, a fake VPN observer and a fake pushed-resolver observer. `192.0.2.53` reaches the tunnel's fake
/// server and `192.0.2.54` the manual entry's.
final class RuntimeHostSplitDNSTests: XCTestCase {
    private var harness: InteractiveHostHarness?
    private let corpIP = "198.51.100.10"
    private let manualIP = "198.51.100.20"
    private let publicIP = "203.0.113.7"

    override func tearDown() async throws {
        await harness?.tearDown()
        harness = nil
        try await super.tearDown()
    }

    private struct Running {
        let host: RuntimeHost
        let harness: InteractiveHostHarness
        let corp: FakeSplitDNSServer
        let manual: FakeSplitDNSServer
        let doh: AnsweringDoHProvider

        @RuntimeActor var port: Int { host.orchestrator.snapshot.bindings.dnsPort ?? 0 }

        @RuntimeActor func events(_ name: String) -> [String] {
            host.orchestrator.eventLog.events.filter { $0.event == name }.map { $0.detail ?? "" }
        }

        /// Emits a VPN report with the live tunnels the observer names beside it, and waits for the host to take it.
        @RuntimeActor func report(_ state: VPNObservedState, live: [String]) async {
            harness.vpn.liveInterfaceNames = live
            harness.vpn.connectedInterfaceName = live.first
            harness.vpn.emit(state)
            await host.deliveries.drain()
        }

        @RuntimeActor func push(_ reading: PushedResolverReading) async {
            harness.pushedResolvers.emit(reading)
            await host.deliveries.drain()
        }
    }

    private func corp(on interface: String = "utun6", service: String = "com.cisco.anyconnect") -> PushedResolver {
        PushedResolver(
            serviceID: service, searchOrder: 1, interface: interface, domains: ["corp.example"], servers: ["192.0.2.53"],
            overridesPrimary: true
        )
    }

    /// A started host with the DNS forwarder on an ephemeral port.
    @RuntimeActor private func start(
        entries: [DomainDNSEntry] = [],
        platform: PlatformIntegrationConfig = PlatformIntegrationConfig(),
        primed: PushedResolverReading? = nil,
        configure: (inout ProxyConfig) -> Void = { _ in }
    ) async throws -> Running {
        let group = MultiThreadedEventLoopGroup.singleton
        let corp = try await FakeSplitDNSServer.start(domain: "corp.example", ip: corpIP)
        let manual = try await FakeSplitDNSServer.start(domain: "corp.example", ip: manualIP)
        let doh = try await AnsweringDoHProvider.start(group: group, ip: publicIP)
        addTeardownBlock {
            await corp.stop()
            await manual.stop()
            await doh.channel.closeForTest()
        }
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = entries
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        configure(&config)
        let harness = try InteractiveHostHarness(config: config, platform: platform)
        self.harness = harness
        harness.dnsForwarderTuning = SplitDNSProbe.tuning(["192.0.2.53": corp.port, "192.0.2.54": manual.port])
        harness.pushedResolvers.primedReading = primed
        let host = try await harness.makeHost()
        try await host.startRuntime()
        await host.deliveries.drain()
        XCTAssertEqual(host.orchestrator.snapshot.dnsRunState, .running)
        return Running(host: host, harness: harness, corp: corp, manual: manual, doh: doh)
    }

    @RuntimeActor func testAPrimedReadingAndConnectedApplyTheSetOnce() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp()]))

        await running.report(.connected, live: ["utun6"])

        XCTAssertEqual(running.events("dns.split_table_changed"), ["detected_domains=1 manual_domains=0 rules=1 reason=pushed"])
        XCTAssertEqual(running.events("dns.split_detected"), ["interface=utun6 domains=corp.example servers=1 outcome=applied"])
        let row = DetectedSplitDNSDisplay.Row(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS, .init(state: .inUse, rows: [row]))
        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(answer, corpIP)
        XCTAssertFalse(running.host.orchestrator.eventLog.events.contains { $0.event == "config.dns_restart" })
    }

    @RuntimeActor func testTheSetReachesAClientThroughTheControlSnapshot() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp()]))
        let composition = RuntimeControlComposition(
            host: running.host, limits: try RuntimeServiceFixtures.hostLimits(), timing: .system, scheduling: TaskOwnerScheduling()
        )
        let client = try makeFramedRuntimeClient(
            transport: composition.transport, limits: ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
        )
        await running.report(.connected, live: ["utun6"])

        let snapshot = try await client.readSnapshot(deadline: .after(.seconds(30), from: ContinuousClock.now))

        XCTAssertEqual(snapshot.detectedSplitDNS, ControlDetectedSplitDNS(state: .inUse, rows: [
            ControlDetectedSplitDNSRow(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"]),
        ]))
    }

    @RuntimeActor func testDisconnectedWithholdsTheSetAndLeavesTheManualEntry() async throws {
        let running = try await start(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.54"])],
            primed: PushedResolverReading(resolvers: [corp()])
        )
        await running.report(.connected, live: ["utun6"])
        let onVPN = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(onVPN, corpIP, "the detected server comes before the manual one")

        await running.report(.disconnected(reason: .userInitiated), live: [])
        let offVPN = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(offVPN, manualIP)
        XCTAssertEqual(running.corp.queryCount("host.corp.example"), 1, "the tunnel's server is not asked once it is down")
        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=0 manual_domains=1 rules=1 reason=vpn_disconnected")
        XCTAssertEqual(running.events("dns.split_detected").last, "interface=utun6 domains=corp.example servers=1 outcome=cleared")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .idle)
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.rows.count, 1, "the last reading stays on display")
    }

    @RuntimeActor func testALANLaunchResolvesAManualEntryThroughItsServer() async throws {
        let running = try await start(entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.54"])])
        await running.report(.disconnected(reason: .userInitiated), live: [])

        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertEqual(answer, manualIP)
        XCTAssertEqual(running.events("dns.split_table_changed"), [], "nothing was detected, so nothing was pushed")
        XCTAssertEqual(running.doh.requestCount(), 0)
    }

    @RuntimeActor func testWithFollowingOffTheObserverNeverStarts() async throws {
        let running = try await start(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.54"])],
            primed: PushedResolverReading(resolvers: [corp()])
        ) { $0.dns.followVPNResolvers = false }
        await running.report(.connected, live: ["utun6"])

        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)

        XCTAssertFalse(running.harness.pushedResolvers.isObserving)
        XCTAssertEqual(answer, manualIP)
        XCTAssertEqual(running.corp.totalQueries, 0)
        XCTAssertEqual(running.events("dns.split_detected"), [])
    }

    @RuntimeActor func testStoppingDNSStopsTheObserverAndClearsTheSet() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp()]))
        await running.report(.connected, live: ["utun6"])
        XCTAssertTrue(running.harness.pushedResolvers.isObserving)

        _ = await running.host.stopDNS()
        await running.host.deliveries.drain()

        XCTAssertFalse(running.harness.pushedResolvers.isObserving)
        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=0 manual_domains=0 rules=0 reason=detection_off")
        XCTAssertEqual(running.events("dns.split_detected").last, "interface=utun6 domains=corp.example servers=1 outcome=cleared")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS, .none)
    }

    @RuntimeActor func testEntryFilesAreWrittenForManualEntriesOnly() async throws {
        let branch = PushedResolver(serviceID: "branch", searchOrder: 2, interface: "utun6", domains: ["branch.example"], servers: ["192.0.2.53"])
        let running = try await start(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.54"])],
            platform: PlatformIntegrationConfig(manageDNSResolvers: true),
            primed: PushedResolverReading(resolvers: [branch])
        )

        await running.report(.connected, live: ["utun6"])

        XCTAssertEqual(running.events("dns.split_detected"), ["interface=utun6 domains=branch.example servers=1 outcome=applied"])
        let files = try FileManager.default.contentsOfDirectory(atPath: running.harness.machine.resolverDirectory.path)
        XCTAssertEqual(files, ["corp.example"], "the detected domain writes no resolver file")
    }

    @RuntimeActor func testATunnelLeavingTheLiveSetDropsItsHeldResolvers() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp(on: "utun7")]))
        await running.report(.connected, live: ["utun3", "utun7"])
        await running.push(PushedResolverReading())
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held, "an empty reading keeps the set")
        XCTAssertEqual(running.events("dns.split_detected").last, "interface=utun7 domains=corp.example servers=1 outcome=held")

        await running.report(.connected, live: ["utun3"])

        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=0 manual_domains=0 rules=0 reason=vpn_connected")
        XCTAssertEqual(running.events("dns.split_detected").last, "interface=utun7 domains=corp.example servers=1 outcome=cleared")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.rows, [])
        _ = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(running.corp.totalQueries, 0, "the name takes the public path")
    }

    @RuntimeActor func testAReassertKeepsTheSetAndDisconnectClearsIt() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp()]))
        await running.report(.connected, live: ["utun6"])

        await running.report(.reasserting, live: ["utun6"])
        await running.push(PushedResolverReading())

        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)
        XCTAssertEqual(running.events("dns.split_table_changed").count, 1, "a flap swaps nothing")
        let held = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(held, corpIP)

        await running.report(.disconnected(reason: .networkLost), live: [])
        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=0 manual_domains=0 rules=0 reason=vpn_disconnected")
    }

    @RuntimeActor func testARepeatedRejectionIsReportedOnce() async throws {
        let running = try await start()
        let odd = PushedResolverRejection(serviceID: "odd", interface: "utun6", value: "bad domain", reason: .invalidDomain)
        let other = PushedResolverRejection(serviceID: "other", interface: nil, reason: .notTunnel)

        await running.push(PushedResolverReading(resolvers: [corp()], rejections: [odd]))
        await running.push(PushedResolverReading(resolvers: [corp(service: "renamed")], rejections: [odd]))
        XCTAssertEqual(running.events("dns.split_resolver_ignored"), ["service=odd interface=utun6 reason=invalid_domain"])

        await running.push(PushedResolverReading(resolvers: [corp()], rejections: [odd, other]))
        XCTAssertEqual(running.events("dns.split_resolver_ignored").last, "service=other interface=none reason=not_tunnel")
        XCTAssertEqual(running.events("dns.split_resolver_ignored").count, 2)
    }

    @RuntimeActor func testAStoreFailureIsReportedOncePerStart() async throws {
        let running = try await start(primed: PushedResolverReading(failure: .storeSubscribe))
        await running.push(PushedResolverReading(failure: .storeSubscribe))
        await running.push(PushedResolverReading(rejections: [], failure: .storeSubscribe))

        XCTAssertEqual(running.events("dns.split_detection_failed"), ["reason=store_subscribe"])
        XCTAssertEqual(running.events("dns.split_table_changed"), [], "the host runs on manual entries alone")
    }

    // MARK: - Readings that outrun the owner

    /// The fake delivers on the calling thread, which here is the owner's, so no delivery runs between the two.
    @RuntimeActor func testAWithdrawalThatArrivesBeforeTheOwnerTookTheResolverStillHoldsIt() async throws {
        let running = try await start()
        await running.report(.connected, live: ["utun6"])

        running.harness.pushedResolvers.emit(PushedResolverReading(resolvers: [corp()]))
        running.harness.pushedResolvers.emit(PushedResolverReading())
        await running.host.deliveries.drain()

        let row = DetectedSplitDNSDisplay.Row(interface: "utun6", domains: ["corp.example"], servers: ["192.0.2.53"])
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS, .init(state: .held, rows: [row]))
        XCTAssertEqual(running.events("dns.split_table_changed"), ["detected_domains=1 manual_domains=0 rules=1 reason=pushed"])
        XCTAssertEqual(
            running.events("dns.split_detected"), ["interface=utun6 domains=corp.example servers=1 outcome=held"],
            "the set that was in use for no owner turn is not reported"
        )
        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(answer, corpIP)
    }

    @RuntimeActor func testABurstOfReadingsQueuesOneDeliveryToTheOwner() async throws {
        let running = try await start()
        await running.report(.connected, live: ["utun6"])
        XCTAssertEqual(running.host.deliveries.inFlightCount, 0)

        for index in 0..<200 {
            running.harness.pushedResolvers.emit(PushedResolverReading(resolvers: [corp(service: "service-\(index)")]))
        }

        XCTAssertEqual(running.host.deliveries.inFlightCount, 1)
        await running.host.deliveries.drain()
        XCTAssertEqual(running.events("dns.split_table_changed").count, 1)
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .inUse)
    }

    // MARK: - A store that cannot be read

    @RuntimeActor func testAStoreReadFailureLeavesTheManualEntriesAloneUntilTheStoreReadsAgain() async throws {
        let running = try await start(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.54"])],
            primed: PushedResolverReading(resolvers: [corp()])
        )
        await running.report(.connected, live: ["utun6"])
        await running.push(PushedResolverReading())
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)

        await running.push(PushedResolverReading(failure: .storeRead))

        XCTAssertEqual(running.events("dns.split_detection_failed"), ["reason=store_read"])
        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=0 manual_domains=1 rules=1 reason=detection_failed")
        XCTAssertEqual(running.events("dns.split_detected").last, "interface=utun6 domains=corp.example servers=1 outcome=cleared")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS, .init(state: .inUse, rows: []))
        let failed = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(failed, manualIP)
        XCTAssertEqual(running.corp.totalQueries, 0, "the tunnel's server is not asked on a set nothing vouches for")

        await running.report(.connected, live: ["utun6"])
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.rows, [], "a VPN report brings nothing back")

        await running.push(PushedResolverReading(resolvers: [corp()]))

        XCTAssertEqual(running.events("dns.split_detection_failed").count, 1)
        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=1 manual_domains=1 rules=1 reason=pushed")
        XCTAssertEqual(running.events("dns.split_detected").last, "interface=utun6 domains=corp.example servers=1 outcome=applied")
        let restored = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(restored, corpIP)
    }

    // MARK: - Lifecycle

    /// The forwarder restarts for a DNS edit and passes through `stopped` on the way. Detection must not follow it
    /// down: stopping drops the held set, and the tunnel's withdrawn key would not bring it back.
    @RuntimeActor func testAForwarderRestartForADNSEditKeepsDetectionRunningAndTheHeldSet() async throws {
        let running = try await start(
            entries: [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.54"])],
            primed: PushedResolverReading(resolvers: [corp()])
        )
        await running.report(.connected, live: ["utun6"])
        await running.push(PushedResolverReading())
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)

        var edited = try ProxyConfigPersistence.load(in: running.harness.environment, allowMissing: false)
        edited.dnsEntries.append(DomainDNSEntry(domain: "branch.example", servers: ["192.0.2.54"]))
        try ProxyConfigPersistence.save(edited, in: running.harness.environment)
        await running.host.reloadConfiguration()
        await running.host.deliveries.drain()

        XCTAssertEqual(running.events("config.dns_restart").count, 1, "the edit restarted the forwarder")
        XCTAssertEqual(running.host.orchestrator.snapshot.dnsRunState, .running)
        XCTAssertTrue(running.harness.pushedResolvers.isObserving)
        XCTAssertEqual(running.harness.pushedResolvers.startCount, 1, "the observer was not stopped and started again")
        XCTAssertFalse(running.events("dns.split_table_changed").contains { $0.hasSuffix("reason=detection_off") })
        XCTAssertEqual(running.events("dns.split_table_changed").last, "detected_domains=1 manual_domains=2 rules=2 reason=config")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)
        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(answer, corpIP)
    }

    /// The restart above cannot tell the admission from the run state: the orchestrator publishes `stopped` and
    /// `starting` with no suspension between them, so the host's delivery reads `starting` whatever a bind or a
    /// delay holds. This publishes `stopped` by itself, under the admitted start, and gives the owner its turn.
    @RuntimeActor func testAStoppedRunStateUnderAnAdmittedStartKeepsDetectionRunningAndTheHeldSet() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp()]))
        await running.report(.connected, live: ["utun6"])
        await running.push(PushedResolverReading())
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)
        XCTAssertTrue(running.host.orchestrator.dnsForwarderAdmitted)

        running.host.orchestrator.mutateSnapshotForTesting { $0.dnsRunState = .stopped }
        await running.host.deliveries.drain()

        XCTAssertTrue(running.harness.pushedResolvers.isObserving)
        XCTAssertEqual(running.events("dns.split_table_changed"), ["detected_domains=1 manual_domains=0 rules=1 reason=pushed"])
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)

        running.host.orchestrator.mutateSnapshotForTesting { $0.dnsRunState = .starting }
        await running.host.deliveries.drain()
        running.host.orchestrator.mutateSnapshotForTesting { $0.dnsRunState = .running }
        await running.host.deliveries.drain()

        XCTAssertEqual(running.harness.pushedResolvers.startCount, 1, "the observer was not stopped and started again")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .held)
        let answer = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(answer, corpIP)
    }

    /// The VPN observer reports a verdict only when it changes, across its own stop and start too, so the verdict
    /// the gate holds at a stop is the one the next start has to judge by. Forgetting it would leave the gate at
    /// `.unknown`, which admits every reading, with no report coming to correct it.
    @RuntimeActor func testAStopKeepsTheVPNVerdictForTheNextStartsFirstReading() async throws {
        let running = try await start(primed: PushedResolverReading(resolvers: [corp()]))
        await running.report(.disconnected(reason: .userInitiated), live: [])
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .idle)
        let reported = running.events("dns.split_detected")

        await running.host.stopRuntime()
        await running.host.deliveries.drain()
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS, .none)
        try await running.host.startRuntime()
        await running.host.deliveries.drain()

        XCTAssertEqual(running.harness.pushedResolvers.startCount, 2, "the observer read the store again")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.state, .idle, "the reading is not in use off the VPN")
        XCTAssertEqual(running.host.orchestrator.snapshot.detectedSplitDNS.rows.count, 1)
        XCTAssertEqual(running.events("dns.split_detected"), reported, "nothing entered the set in use")
        let asked = running.corp.totalQueries
        _ = try await SplitDNSProbe.resolve("host.corp.example", port: running.port)
        XCTAssertEqual(running.corp.totalQueries, asked)
    }
}
