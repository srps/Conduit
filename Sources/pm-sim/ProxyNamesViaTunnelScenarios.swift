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

enum ProxyNamesViaTunnelScenarios {
    private static let silentServer = "192.0.2.53"
    private static let answeringServer = "192.0.2.54"
    private static let tunnelIP = "198.51.100.60"
    private static let proxyName = "proxy.example.com"
    private static let publicName = "www.example.com"

    /// On a full tunnel that pushes only `de.corp.example`, the upstream's own hostname is outside the pushed
    /// domains. With the first pushed server silent and DoH unanswered, as it is when DoH can only travel through
    /// that same proxy, the hostname still resolves through the second pushed server (decision 0051).
    @RuntimeActor
    static func proxyNamesViaTunnel() async throws -> ScenarioResult {
        let name = "dns-proxy-names-via-tunnel"
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let silent = SilentDNSServer()
        try await silent.start(group: group)
        ScenarioCleanup.register { await silent.stop() }
        let answering = CountingDNSServer(domain: proxyName, ip: tunnelIP)
        try await answering.start(group: group)
        ScenarioCleanup.register { await answering.stop() }
        let doh = try await HangingListener.open(group: group)
        ScenarioCleanup.register { await doh.close() }

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

        let upstream = try await ClosingUpstream.open()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [UpstreamProxy(name: "Tunnel proxy", host: proxyName, port: upstream.port, priority: 0)]
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
        let endpoints = [silentServer: silent.port, answeringServer: answering.port]
        tuning.internalServerEndpoint = { server in ("127.0.0.1", endpoints[server] ?? 9) }
        tuning.dohRequestTimeout = 0.5
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
                connectivityProbe: .injected(SimulatedUpstreams.unreachable),
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
                limits: try SplitDNSFollowsVPNScenarios.controlLimits(),
                clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            let control = clients.control
            func snapshot() async throws -> ControlRuntimeSnapshot {
                try await control.readSnapshot(deadline: .after(.seconds(30), from: ContinuousClock.now))
            }
            func settles(_ condition: (ControlRuntimeSnapshot) -> Bool) async throws -> Bool {
                for _ in 0..<1000 {
                    if condition(try await snapshot()) { return true }
                    try await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            guard let port = host.status().bindings.dnsPort else {
                throw ScenarioExecutionError(message: "the forwarder has no port")
            }
            func resolve(_ name: String) async throws -> String? {
                let reply = try await DNSProbe.overUDP(
                    query: DNSWireFormat.buildQuery(domain: name, txID: UInt16.random(in: 1 ... .max)), port: port, timeout: 12
                )
                return reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
            }

            vpn.emit(.disconnected(reason: .userInitiated))
            check("the host shows the VPN disconnected", try await settles { $0.vpnState == .disconnected(.userInitiated) })
            check("off the VPN the proxy's name gets no answer while DoH is unanswered", try await resolve(proxyName) == nil)
            check("off the VPN no tunnel server is asked", silent.received == 0 && answering.total == 0)

            pushed.emit(PushedResolverReading(resolvers: [PushedResolver(
                serviceID: "com.example.vpn", searchOrder: 1, interface: "utun6", domains: ["de.corp.example"],
                servers: [silentServer, answeringServer], overridesPrimary: true
            )]))
            vpn.liveInterfaceNames = ["utun6"]
            vpn.connectedInterfaceName = "utun6"
            vpn.emit(.connected)
            check("the pushed set is in use on the full tunnel", try await settles {
                $0.vpnState == .connected && $0.detectedSplitDNS.state == .inUse
            })

            let acceptedBefore = doh.accepted
            check("on the tunnel the proxy's name resolves through the second pushed server", try await resolve(proxyName) == tunnelIP)
            check("both pushed servers were asked for it, in order", silent.count(proxyName) == 1 && answering.count(proxyName) == 1)
            check("DoH was not asked for the proxy's own name", doh.accepted == acceptedBefore)

            _ = try await resolve(publicName)
            check("a public name still asks only the first pushed server", silent.count(publicName) == 1 && answering.count(publicName) == 0)
            check("a public name still goes on to DoH", doh.accepted > acceptedBefore)
            notes.append("silent server saw \(silent.counts), answering server saw \(answering.total), DoH accepted \(doh.accepted)")
        } catch {
            notes.append("failed: \(error)")
            check("the scenario ran to its end", false)
        }

        await host.stopRuntime()
        let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        let flush = await host.flushEvents()
        check("the host settles and flushes", settled == .settled && flush.allConfirmed)
        do {
            let events = try String(contentsOf: environment.eventsFile, encoding: .utf8).split(separator: "\n").map {
                try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            }
            let reported = events.filter { $0.event == "dns.proxy_host_via_tunnel" }.compactMap(\.detail)
            notes.append("dns.proxy_host_via_tunnel: \(reported)")
            check("the event reports the answer with a count of servers", reported == ["name=\(proxyName) servers=2 outcome=answered suppressed=0"])
            check(
                "no event carries a tunnel server's address",
                !events.contains { ($0.detail ?? "").contains(silentServer) || ($0.detail ?? "").contains(answeringServer) }
            )
        } catch {
            notes.append("events unreadable: \(error)")
            check("the events file is readable", false)
        }

        session = nil
        if settled == .settled, flush.allConfirmed, releaseFailures.withLockedValue({ $0 }) == 0 {
            do { try FileManager.default.removeItem(at: scratch) } catch { notes.append("scratch kept at \(scratch.path): \(error.localizedDescription)") }
        } else {
            notes.append("shutdown not confirmed: scratch kept at \(scratch.path)")
        }
        notes.append("the upstream accepted \(upstream.accepted) connections")
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }
}

/// A loopback UDP DNS server that counts queries per name and never replies.
private final class SilentDNSServer: @unchecked Sendable {
    private let asked = NIOLockedValueBox<[String: Int]>([:])
    private let channel = NIOLockedValueBox<Channel?>(nil)

    var port: Int { channel.withLockedValue { $0?.localAddress?.port } ?? 0 }
    var received: Int { asked.withLockedValue { $0.values.reduce(0, +) } }
    var counts: [String: Int] { asked.withLockedValue { $0 } }
    func count(_ name: String) -> Int { asked.withLockedValue { $0[name] ?? 0 } }

    func start(group: EventLoopGroup) async throws {
        let handler = Recorder(asked: asked)
        let bound = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        guard let bound = channel.withLockedValue({ $0 }) else { return }
        do { try await bound.close() } catch { fputs("silent DNS server close failed: \(error)\n", stderr) }
    }

    private final class Recorder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        private let asked: NIOLockedValueBox<[String: Int]>

        init(asked: NIOLockedValueBox<[String: Int]>) { self.asked = asked }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data).data
            let query = buffer.readBytes(length: buffer.readableBytes) ?? []
            asked.withLockedValue { $0[DNSWireFormat.extractDomainName(from: query).lowercased(), default: 0] += 1 }
        }
    }
}
