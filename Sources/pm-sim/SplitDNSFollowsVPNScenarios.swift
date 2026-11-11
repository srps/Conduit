// SPDX-License-Identifier: Apache-2.0
import ConduitRuntime
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import PlatformMac
import ProxyAuth
import ProxyKernel

/// `pm-sim dns-split-follows-vpn`, `pm-sim dns-split-flap-holds` and `pm-sim dns-split-detection-failed`
/// (decision 0044): split DNS follows the resolvers a connected VPN pushes, through the actual `RuntimeHost` over a
/// scratch root.
///
/// The machine is fakes throughout: a fake VPN observer, a fake pushed-resolver observer, a loopback UDP server
/// standing in for the tunnel's DNS server at `192.0.2.53`, and a loopback DoH provider. The host's forwarder
/// answers real UDP queries, and each check reads which server was asked. The host is read only through what a
/// client sees: its control snapshot, its status and its events file.
enum SplitDNSFollowsVPNScenarios {
    private static let corpIP = "198.51.100.10"
    private static let publicIP = "203.0.113.7"
    private static let internalName = "host.corp.example"
    private static let publicName = "www.example.com"

    /// Off the VPN a name under the pushed domain is public. Once the tunnel is up and has pushed its resolver,
    /// the same name is asked of the tunnel's server, a public name gets one attempt there before DoH, and a
    /// disconnect stops both.
    @RuntimeActor
    static func followsVPN() async throws -> ScenarioResult {
        try await run(name: "dns-split-follows-vpn") { stage, check in
            try await stage.report(.disconnected(reason: .userInitiated), live: [])
            check("off the VPN the name resolves publicly", try await stage.resolve(internalName) == publicIP)
            check("off the VPN the tunnel's server is never asked", stage.corp.total == 0)

            stage.pushed.emit(PushedResolverReading(resolvers: [stage.corpResolver]))
            try await stage.report(.connected, live: ["utun6"])
            check("the pushed set shows as in use", try await stage.settles { $0.state == .inUse && $0.rows.count == 1 })
            check("on the VPN the tunnel's server answers, not the cached public answer", try await stage.resolve(internalName) == corpIP)
            check("the tunnel's server was asked once for the name", stage.corp.count(internalName) == 1)

            let publicAnswer = try await stage.resolve(publicName)
            check("a public name is asked of the tunnel's server once", stage.corp.count(publicName) == 1)
            check("DoH answers the public name after the server's NXDOMAIN", publicAnswer == publicIP)

            try await stage.report(.disconnected(reason: .userInitiated), live: [])
            check("after a disconnect the set shows as idle", try await stage.settles { $0.state == .idle })
            let asked = stage.corp.total
            let after = [try await stage.resolve(internalName), try await stage.resolve(publicName)]
            check("after a disconnect both names resolve publicly", after == [publicIP, publicIP])
            check("after a disconnect the tunnel's server is never asked again", stage.corp.total == asked)
        } verify: { events, saved, check in
            let swaps = events.filter { $0.event == "dns.split_table_changed" }.compactMap(\.detail)
            check("the table was swapped once on connect and once on disconnect", swaps == [
                "detected_domains=1 manual_domains=0 rules=1 reason=vpn_connected",
                "detected_domains=0 manual_domains=0 rules=0 reason=vpn_disconnected",
            ])
            let detected = events.filter { $0.event == "dns.split_detected" }.compactMap(\.detail)
            check("the host reported the set applied, then cleared", detected == [
                "interface=utun6 domains=corp.example servers=1 outcome=applied",
                "interface=utun6 domains=corp.example servers=1 outcome=cleared",
            ])
            check("no VPN transition restarted the forwarder", !events.contains { $0.event == "config.dns_restart" })
            check("nothing the network said was written to the configuration", saved.dnsEntries.isEmpty)
        }
    }

    /// A flap changes nothing a client can see: with the tunnel reasserting and its DNS key withdrawn, the held
    /// set keeps answering. The grace window ending in a disconnect stops it, and a reconnect resumes it.
    @RuntimeActor
    static func flapHolds() async throws -> ScenarioResult {
        try await run(name: "dns-split-flap-holds") { stage, check in
            stage.pushed.emit(PushedResolverReading(resolvers: [stage.corpResolver]))
            try await stage.report(.connected, live: ["utun6"])
            check("the pushed set shows as in use", try await stage.settles { $0.state == .inUse })
            check("on the VPN the tunnel's server answers", try await stage.resolve(internalName) == corpIP)

            try await stage.report(.reasserting, live: ["utun6"])
            stage.pushed.emit(PushedResolverReading())
            check("in a flap with the DNS key withdrawn the set shows as held", try await stage.settles { $0.state == .held && $0.rows.count == 1 })
            check("in a flap the tunnel's server keeps answering", try await stage.resolve(internalName) == corpIP)
            check("the tunnel's server was asked again", stage.corp.count(internalName) == 2)

            try await stage.report(.disconnected(reason: .networkLost), live: [])
            check("the grace window ending in a disconnect leaves nothing in use", try await stage.settles { $0.state == .idle })
            check("after the disconnect the name resolves publicly", try await stage.resolve(internalName) == publicIP)
            check("after the disconnect the tunnel's server is not asked", stage.corp.count(internalName) == 2)

            stage.pushed.emit(PushedResolverReading(resolvers: [stage.corpResolver]))
            try await stage.report(.connected, live: ["utun6"])
            check("a reconnect puts the set back in use", try await stage.settles { $0.state == .inUse })
            check("after the reconnect the tunnel's server answers again", try await stage.resolve(internalName) == corpIP)

            try await stage.report(.disconnected(reason: .networkLost), live: [])
            stage.pushed.emit(PushedResolverReading())
            check("a tunnel that went down with its key leaves no row", try await stage.settles { $0.state == .idle && $0.rows.isEmpty })
            try await stage.report(.connected, live: ["utun6"])
            // Both on this turn, so the host takes neither before the second has arrived.
            stage.pushed.emit(PushedResolverReading(resolvers: [stage.corpResolver]))
            stage.pushed.emit(PushedResolverReading())
            check(
                "a key published and withdrawn before the host's next turn is held",
                try await stage.settles { $0.state == .held && $0.rows.count == 1 }
            )
            check("the held server answers", try await stage.resolve(internalName) == corpIP)
        } verify: { events, _, check in
            let reasons = events.filter { $0.event == "dns.split_table_changed" }.compactMap(\.detail).map {
                $0.split(separator: " ").last.map(String.init) ?? ""
            }
            check(
                "the table was swapped on the push, each disconnect, the reconnect, the held key and the stop, and not in the flap",
                reasons == [
                    "reason=pushed", "reason=vpn_disconnected", "reason=vpn_connected", "reason=vpn_disconnected", "reason=pushed",
                    "reason=detection_off",
                ]
            )
            let outcomes = events.filter { $0.event == "dns.split_detected" }.compactMap(\.detail).map {
                $0.split(separator: " ").last.map(String.init) ?? ""
            }
            check("the host reported applied, held, cleared, applied, cleared, held, and cleared at the stop", outcomes == [
                "outcome=applied", "outcome=held", "outcome=cleared", "outcome=applied", "outcome=cleared", "outcome=held",
                "outcome=cleared",
            ])
        }
    }

    /// A store that cannot be read vouches for nothing: the set in use is dropped, held or not, the name takes
    /// the public path, and the next reading the store gives puts the tunnel's server back.
    @RuntimeActor
    static func detectionFailed() async throws -> ScenarioResult {
        try await run(name: "dns-split-detection-failed") { stage, check in
            stage.pushed.emit(PushedResolverReading(resolvers: [stage.corpResolver]))
            try await stage.report(.connected, live: ["utun6"])
            check("the pushed set shows as in use", try await stage.settles { $0.state == .inUse && $0.rows.count == 1 })
            check("on the VPN the tunnel's server answers", try await stage.resolve(internalName) == corpIP)

            stage.pushed.emit(PushedResolverReading(failure: .storeRead))
            check("after a failed reading no detected row is left", try await stage.settles { $0.rows.isEmpty })
            let asked = stage.corp.total
            check("after a failed reading the name resolves publicly", try await stage.resolve(internalName) == publicIP)
            check("after a failed reading the tunnel's server is not asked", stage.corp.total == asked)

            stage.pushed.emit(PushedResolverReading(resolvers: [stage.corpResolver]))
            check("the next good reading puts the set back in use", try await stage.settles { $0.state == .inUse && $0.rows.count == 1 })
            check("the tunnel's server answers again", try await stage.resolve(internalName) == corpIP)
        } verify: { events, _, check in
            let failures = events.filter { $0.event == "dns.split_detection_failed" }.compactMap(\.detail)
            check("the failure was reported once", failures == ["reason=store_read"])
            let swaps = events.filter { $0.event == "dns.split_table_changed" }.compactMap(\.detail)
            check("the table was swapped on the push, the failure, the recovery and the stop", swaps == [
                "detected_domains=1 manual_domains=0 rules=1 reason=pushed",
                "detected_domains=0 manual_domains=0 rules=0 reason=detection_failed",
                "detected_domains=1 manual_domains=0 rules=1 reason=pushed",
                "detected_domains=0 manual_domains=0 rules=0 reason=detection_off",
            ])
            let outcomes = events.filter { $0.event == "dns.split_detected" }.compactMap(\.detail).map {
                $0.split(separator: " ").last.map(String.init) ?? ""
            }
            check("the host reported applied, cleared, applied, and cleared at the stop", outcomes == [
                "outcome=applied", "outcome=cleared", "outcome=applied", "outcome=cleared",
            ])
        }
    }

    // MARK: - Harness

    /// One started host and the fakes around it.
    @RuntimeActor
    private final class Stage {
        let host: RuntimeHost
        let control: any RuntimeClient
        let vpn: FakeVPNStatusObserver
        let pushed: FakePushedResolverObserver
        let corp: CountingDNSServer

        init(host: RuntimeHost, control: any RuntimeClient, vpn: FakeVPNStatusObserver, pushed: FakePushedResolverObserver, corp: CountingDNSServer) {
            self.host = host
            self.control = control
            self.vpn = vpn
            self.pushed = pushed
            self.corp = corp
        }

        let corpResolver = PushedResolver(
            serviceID: "com.cisco.anyconnect", searchOrder: 1, interface: "utun6", domains: ["corp.example"],
            servers: ["192.0.2.53"], overridesPrimary: true
        )

        private var reported = ControlVPNState.unknown

        /// Emits a VPN report with the live tunnels the observer names beside it, and waits until the host shows it.
        /// Throws when a snapshot cannot be read or the host has not shown it within ten seconds.
        func report(_ state: VPNObservedState, live: [String]) async throws {
            vpn.liveInterfaceNames = live
            vpn.connectedInterfaceName = live.first
            vpn.emit(state)
            reported = switch state {
            case .connected: .connected
            case .reasserting: .reasserting
            case .unknown: .unknown
            case .disconnected(reason: .userInitiated): .disconnected(.userInitiated)
            case .disconnected: .disconnected(.networkLost)
            }
            for _ in 0..<1000 {
                if try await snapshot().vpnState == reported { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ScenarioExecutionError(message: "the host never showed the VPN report \(reported)")
        }

        private func snapshot() async throws -> ControlRuntimeSnapshot {
            try await control.readSnapshot(deadline: .after(.seconds(30), from: ContinuousClock.now))
        }

        /// Whether the detected set a client reads comes to satisfy `condition`, within ten seconds.
        func settles(_ condition: (ControlDetectedSplitDNS) -> Bool) async throws -> Bool {
            for _ in 0..<1000 {
                if condition(try await snapshot().detectedSplitDNS) { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        /// The first A record the host's forwarder answers for `name`.
        func resolve(_ name: String) async throws -> String? {
            guard let port = host.status().bindings.dnsPort else { return nil }
            return try await Self.ask(name, port: port)
        }

        private nonisolated static func ask(_ name: String, port: Int) async throws -> String? {
            let reply = try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: name, txID: 0x5D44), port: port, timeout: 12)
            return reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        }
    }

    @RuntimeActor
    private static func run(
        name: String,
        _ body: @RuntimeActor (Stage, (String, Bool) -> Void) async throws -> Void,
        verify: ([RuntimeEvent], ProxyConfig, (String, Bool) -> Void) -> Void
    ) async throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let corp = CountingDNSServer(domain: "corp.example", ip: corpIP)
        try await corp.start(group: group)
        ScenarioCleanup.register { await corp.stop() }
        let doh = FakeAnsweringDoHProvider(group: group, ip: publicIP)
        try await doh.start()
        ScenarioCleanup.register { await doh.stop() }

        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(name)-\(UUID().uuidString)", isDirectory: true)
        let home = scratch.appendingPathComponent("home", isDirectory: true)
        let environment = RuntimeEnvironment.isolated(stateDirectory: scratch.appendingPathComponent("state", isDirectory: true))
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let releaseFailures = NIOLockedValueBox(0)
        var session: StateRootSession?
        switch StateRootBootstrap.acquire(
            environment, createRootIfMissing: true, fileSystem: OSStateRootFileSystem(), leasing: OSStateWriterLeasing(),
            onReleaseFailure: { _ in releaseFailures.withLockedValue { $0 += 1 } }
        ) {
        case .success(let taken): session = taken
        case .failure(let failure): throw ScenarioExecutionError(message: "state root refused: \(failure)")
        }

        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Synthetic", host: "127.0.0.1", port: 9, priority: 0)]
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = []
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)

        let machine = FakeMachine(resolverDirectory: scratch.appendingPathComponent("resolver", isDirectory: true))
        let vpn = FakeVPNStatusObserver()
        let pushed = FakePushedResolverObserver()
        var tuning = DNSForwarderTuning()
        let corpPort = corp.port
        tuning.internalServerEndpoint = { _ in ("127.0.0.1", corpPort) }
        let host = try await RuntimeHost.open(
            stateSession: session!,
            logger: DiscardingLogSink(),
            startupAllowsMissing: false,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            terminalExit: {},
            effects: RuntimeHostEffects(
                privilege: { _ in RuntimePrivilegeAdapters(client: machine, helperStatus: nil) },
                credentials: InMemorySecretStore(),
                kerberosTicketRecovery: FakeKerberosTicketRecovery(),
                gss: .injected { NoGSS() },
                pacEvaluator: FakePacEvaluator(),
                portHolderProbe: FakeListenerPortHolderProbe(),
                loopbackPortProbe: FakeLoopbackPortProbe().liveness(port:),
                commandRunner: { try machine.run($0, $1) },
                dnsProbe: FakeDNSProbe().liveness(onPort:),
                relayRecheckPause: { _ in },
                networkPath: FakeNetworkPathObserver(),
                networkLocation: FakeNetworkLocationObserver(),
                networkLocationStoreFactory: { _ in nil },
                vpnStatusMonitor: { _, _ in vpn },
                pushedResolvers: pushed,
                wake: FakeSystemWakeObserver(),
                homeDirectory: home,
                resolverDirectory: machine.resolverDirectory.path,
                stateFiles: StateFileAccess.operatingSystem()
            ),
            dnsForwarderTuning: tuning
        )

        do {
            try await host.startRuntime()
            let clients = try host.makeInMemoryControlClient(
                limits: try controlLimits(), clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            check("the pushed-resolver observer runs beside the forwarder", pushed.isObserving)
            try await body(Stage(host: host, control: clients.control, vpn: vpn, pushed: pushed, corp: corp), check)
        } catch {
            notes.append("failed: \(error)")
            check("the scenario ran to its end", false)
        }

        await host.stopRuntime()
        do {
            check("stopping the runtime stops the pushed-resolver observer", try await stopped(pushed))
        } catch {
            notes.append("the wait for the observer to stop ended early: \(error)")
            check("stopping the runtime stops the pushed-resolver observer", false)
        }
        let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        let flush = await host.flushEvents()
        check("the host settles and flushes", settled == .settled && flush.allConfirmed)
        do {
            let events = try String(contentsOf: environment.eventsFile, encoding: .utf8).split(separator: "\n").map {
                try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            }
            verify(events, try ProxyConfigPersistence.load(in: environment, allowMissing: false), check)
        } catch {
            notes.append("events or configuration unreadable: \(error)")
            check("the events file and the saved configuration are readable", false)
        }
        // The host creates the directory only to write a file into it, so a missing one holds none. Any other
        // failure to list it leaves the check unanswered, which fails it.
        var resolverFiles: [String]?
        do {
            resolverFiles = try FileManager.default.contentsOfDirectory(atPath: machine.resolverDirectory.path)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            resolverFiles = []
        } catch {
            notes.append("resolver directory unreadable: \(error)")
        }
        check("no resolver file was written for a detected domain", resolverFiles?.isEmpty == true)

        session = nil
        if settled == .settled, flush.allConfirmed, releaseFailures.withLockedValue({ $0 }) == 0 {
            do { try FileManager.default.removeItem(at: scratch) } catch { notes.append("scratch kept at \(scratch.path): \(error.localizedDescription)") }
        } else {
            notes.append("shutdown not confirmed: scratch kept at \(scratch.path)")
        }
        notes.append("tunnel server saw \(corp.total) queries")
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }

    /// The observer stops on the delivery that carries the forwarder's stopped state, a turn after the stop returns.
    @RuntimeActor
    private static func stopped(_ pushed: FakePushedResolverObserver) async throws -> Bool {
        for _ in 0..<1000 where pushed.isObserving {
            try await Task.sleep(for: .milliseconds(10))
        }
        return !pushed.isObserving
    }

    private static func controlLimits() throws -> RuntimeServiceLimits {
        try RuntimeServiceLimits(
            maxRequestBytes: 4096, maxReplyBytes: 64 * 1024,
            aliasCapacityPerPartition: 8, aliasByteCapacityPerPartition: 1 << 20,
            ordinaryPendingCapacity: 2, outcomeCapacity: 8, outcomeByteCapacity: 1 << 20,
            retentionAge: .seconds(60), janitorBatch: 4,
            ordinaryLaneCapacity: 2, readLaneCapacity: 2, streamLaneCapacity: 2, stopLaneCapacityPerModule: 1, subscriberLimit: 3,
            ringCapacity: 256, ringByteCapacity: 1 << 18, maxEventBytes: 4096,
            ingressCapacity: 256, ingressByteCapacity: 1 << 18, drainItemsPerTurn: 32, drainBytesPerTurn: 1 << 16,
            controlLogCapacity: 8, controlLogByteCapacity: 1 << 14, replayChunkItems: 32, replayChunkBytes: 1 << 14,
            collectionRowCapacity: 16, collectionByteCapacity: 1 << 14, collectionProofCapacityPerKind: 4,
            collectionRowRevisionsPerKind: 2, collectionRetainedByteCapacity: 1 << 14, collectionRowRetentionAge: .seconds(60),
            latestSnapshotByteCapacity: 1 << 14, subscriberRecordBytes: 256, retainedByteCeiling: 1 << 24
        )
    }
}

/// No scenario here authenticates, so a token request is a fault.
private final class NoGSS: GSSTokenProvider {
    func generateToken(host: String, inputToken: Data?) throws -> Data? {
        throw ScenarioExecutionError(message: "unplanned GSS token request for \(host)")
    }

    func resetContext() {}
}

/// A loopback UDP DNS server that answers an A query for a name at or under `domain` with `ip`, answers NXDOMAIN
/// for any other name, and counts the queries per name.
private final class CountingDNSServer: @unchecked Sendable {
    private let domain: String
    private let ip: String
    private let asked = NIOLockedValueBox<[String: Int]>([:])
    private let channel = NIOLockedValueBox<Channel?>(nil)

    init(domain: String, ip: String) {
        self.domain = domain
        self.ip = ip
    }

    var port: Int { channel.withLockedValue { $0?.localAddress?.port } ?? 0 }
    var total: Int { asked.withLockedValue { $0.values.reduce(0, +) } }
    func count(_ name: String) -> Int { asked.withLockedValue { $0[name] ?? 0 } }

    func start(group: EventLoopGroup) async throws {
        let handler = Responder(domain: domain, ip: ip, asked: asked)
        let bound = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        guard let bound = channel.withLockedValue({ $0 }) else { return }
        do { try await bound.close() } catch { fputs("tunnel DNS server close failed: \(error)\n", stderr) }
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let domain: String
        private let ip: String
        private let asked: NIOLockedValueBox<[String: Int]>

        init(domain: String, ip: String, asked: NIOLockedValueBox<[String: Int]>) {
            self.domain = domain
            self.ip = ip
            self.asked = asked
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            var buffer = envelope.data
            let query = buffer.readBytes(length: buffer.readableBytes) ?? []
            let name = DNSWireFormat.extractDomainName(from: query).lowercased()
            asked.withLockedValue { $0[name, default: 0] += 1 }
            let answer = name == domain || name.hasSuffix(".\(domain)")
                ? DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: ip)
                : DNSWireFormat.emptyDNSResponse(originalQuery: query, rcode: 3)
            guard let answer else { return }
            var out = context.channel.allocator.buffer(capacity: answer.count)
            out.writeBytes(answer)
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
        }

    }
}
