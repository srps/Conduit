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

enum NetworkResolverScenarios {
    private static let networkServer = "192.0.2.1"
    private static let stubIP = "198.51.100.44"
    private static let publicName = "www.example.com"
    private static let upstreamName = "egress.corp.example"
    private static let pacName = "pacfiles.corp.example"

    @RuntimeActor
    static func offVPNNetworkResolver() async throws -> ScenarioResult {
        let name = "dns-offvpn-network-resolver"
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let stub = AnsweringDNSStub(ip: stubIP)
        try await stub.start(group: group)
        ScenarioCleanup.register { await stub.stop() }
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
        config.pacRoutingEnabled = true
        config.pacURL = "http://\(pacName)/proxy.pac"
        config.upstreams = [upstream.proxy]
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.80"], enabled: false)]
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(), in: environment)

        let forwarderPort = NIOLockedValueBox<Int?>(nil)
        let pac = ResolvingPACFetch(host: pacName, expecting: stubIP, port: forwarderPort)
        let probes = NIOLockedValueBox(0)
        let probe: @Sendable ([UpstreamProxy]) async -> UpstreamProbeSummary = { targets in
            probes.withLockedValue { $0 += 1 }
            let resolved = await ForwarderLookup.a(upstreamName, port: forwarderPort.withLockedValue { $0 })
            return UpstreamProbeSummary(results: targets.map { ProbeResult(proxy: $0, latencyMS: 0, reachable: resolved == stubIP) })
        }

        let machine = FakeMachine(resolverDirectory: scratch.appendingPathComponent("resolver", isDirectory: true))
        let vpn = FakeVPNStatusObserver()
        let pushed = FakePushedResolverObserver()
        var tuning = DNSForwarderTuning()
        let stubPort = stub.port
        let networkServer = Self.networkServer
        tuning.internalServerEndpoint = { server in ("127.0.0.1", server == networkServer ? stubPort : 9) }
        tuning.dohRequestTimeout = 0.5
        tuning.networkResolverTimeout = .milliseconds(500)
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
                pacEvaluator: pac,
                connectivityProbe: .injected(probe),
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
                for _ in 0..<1500 {
                    if condition(try await snapshot()) { return true }
                    try await Task.sleep(for: .milliseconds(10))
                }
                return false
            }
            guard let port = host.status().bindings.dnsPort else {
                throw ScenarioExecutionError(message: "the forwarder has no port")
            }
            forwarderPort.withLockedValue { $0 = port }

            vpn.emit(.disconnected(reason: .userInitiated))
            check("off the VPN, with every DoH request hanging, routing goes direct", try await settles {
                $0.vpnState == .disconnected(.userInitiated) && $0.directModeCause == .vpnDisconnected
            })
            let before = await ForwarderLookup.a(publicName, port: port)
            check("before the network's server is known, a public name gets no answer", before == nil)
            check("the network's server has not been asked", stub.total == 0)

            pushed.emit(PushedResolverReading.parse(store: [
                PushedResolverReading.globalIPv4Key: ["PrimaryService": "wifi", "PrimaryInterface": "en0"],
                "State:/Network/Service/wifi/IPv4": ["InterfaceName": "en0"],
                "State:/Network/Service/wifi/DNS": ["ServerAddresses": ["127.0.0.1", networkServer]],
            ]))
            try await Task.sleep(for: .milliseconds(100))

            check("a public name resolves through the network's server", await ForwarderLookup.a(publicName, port: port) == stubIP)
            check("an upstream's hostname resolves through it", await ForwarderLookup.a(upstreamName, port: port) == stubIP)
            check("routing returns to the upstream once the probe resolves it", try await settles {
                $0.directModeCause == .none && $0.activeUpstream != "DIRECT"
            })
            for _ in 0..<1500 where pac.loaded == 0 { try await Task.sleep(for: .milliseconds(10)) }
            check("a PAC whose host only the network's server knows loads", pac.loaded > 0)
            notes.append("PAC fetches \(pac.attempts) (loaded \(pac.loaded)), probes \(probes.withLockedValue { $0 }), stub saw \(stub.counts)")
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
            let details = { (event: String) in events.filter { $0.event == event }.compactMap(\.detail) }
            let changed = details("dns.network_resolver_changed")
            notes.append("dns.network_resolver_changed: \(changed)")
            check("the host gave the forwarder one network server, Conduit's loopback skipped", changed.first == "interface=en0 servers=1 skipped=1")
            let fallbacks = details("dns.network_resolver_fallback")
            notes.append("dns.network_resolver_fallback: \(fallbacks)")
            check(
                "the fallback event fires, answered, with a count and no address",
                fallbacks.contains { $0.contains(" servers=1 outcome=answered ") } && !fallbacks.contains { $0.contains(networkServer) }
            )
            let recovered = details("dns.resolution_recovered")
            notes.append("dns.resolution_recovered: \(recovered)")
            check(
                "the first answer after the dead period retries the PAC past its backoff and re-probes",
                recovered.count == 1 && recovered[0].contains("via=network_resolver pac=refresh reprobe=started")
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
        notes.append("the hanging DoH listener accepted \(doh.accepted) connections")
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }
}

private enum ForwarderLookup {
    static func a(_ name: String, port: Int?) async -> String? {
        guard let port else { return nil }
        let reply = NIOLockedValueBox<[UInt8]?>(nil)
        do {
            let client = try await DatagramBootstrap(group: MultiThreadedEventLoopGroup.singleton)
                .channelInitializer { $0.pipeline.addHandler(FirstReply(reply: reply)) }
                .bind(host: "127.0.0.1", port: 0)
                .get()
            defer { client.close(promise: nil) }
            let query = DNSWireFormat.buildQuery(domain: name, txID: UInt16.random(in: 1 ... .max))
            var buffer = client.allocator.buffer(capacity: query.count)
            buffer.writeBytes(query)
            let target = try SocketAddress(ipAddress: "127.0.0.1", port: port)
            try await client.writeAndFlush(AddressedEnvelope(remoteAddress: target, data: buffer)).get()
            for _ in 0..<1200 where reply.withLockedValue({ $0 }) == nil {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            fputs("pm-sim: lookup of \(name) failed: \(error)\n", stderr)
            return nil
        }
        return reply.withLockedValue { $0 }.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
    }

    private final class FirstReply: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        private let reply: NIOLockedValueBox<[UInt8]?>

        init(reply: NIOLockedValueBox<[UInt8]?>) { self.reply = reply }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            var buffer = unwrapInboundIn(data).data
            let bytes = buffer.readBytes(length: buffer.readableBytes) ?? []
            reply.withLockedValue { if $0 == nil { $0 = bytes } }
        }
    }
}

private final class ResolvingPACFetch: PacEvaluator, @unchecked Sendable {
    private struct DirectOnly: PacScriptEvaluating {
        func resolveProxyChain(for url: URL) throws -> [String] { ["DIRECT"] }
    }

    private let host: String
    private let expecting: String
    private let port: NIOLockedValueBox<Int?>
    private let counts = NIOLockedValueBox((attempts: 0, loaded: 0))

    init(host: String, expecting: String, port: NIOLockedValueBox<Int?>) {
        self.host = host
        self.expecting = expecting
        self.port = port
    }

    var attempts: Int { counts.withLockedValue { $0.attempts } }
    var loaded: Int { counts.withLockedValue { $0.loaded } }

    func fetchPAC(from urlString: String) async throws -> String {
        counts.withLockedValue { $0.attempts += 1 }
        guard await ForwarderLookup.a(host, port: port.withLockedValue { $0 }) == expecting else {
            throw ScenarioExecutionError(message: "could not resolve \(host)")
        }
        counts.withLockedValue { $0.loaded += 1 }
        return "function FindProxyForURL(url, host) { return \"DIRECT\"; }"
    }

    func makeEvaluator(pacScript: String) throws -> any PacScriptEvaluating { DirectOnly() }

    func routeChain(for entries: [String]) -> PACChain {
        PACChain.classify(entries) { _ in nil }
    }
}

private final class AnsweringDNSStub: @unchecked Sendable {
    private let ip: String
    private let asked = NIOLockedValueBox<[String: Int]>([:])
    private let channel = NIOLockedValueBox<Channel?>(nil)

    init(ip: String) { self.ip = ip }

    var port: Int { channel.withLockedValue { $0?.localAddress?.port } ?? 0 }
    var total: Int { asked.withLockedValue { $0.values.reduce(0, +) } }
    var counts: [String: Int] { asked.withLockedValue { $0 } }

    func start(group: EventLoopGroup) async throws {
        let handler = Responder(ip: ip, asked: asked)
        let bound = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        guard let bound = channel.withLockedValue({ $0 }) else { return }
        do { try await bound.close() } catch { fputs("network DNS stub close failed: \(error)\n", stderr) }
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let ip: String
        private let asked: NIOLockedValueBox<[String: Int]>

        init(ip: String, asked: NIOLockedValueBox<[String: Int]>) {
            self.ip = ip
            self.asked = asked
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            var buffer = envelope.data
            let query = buffer.readBytes(length: buffer.readableBytes) ?? []
            asked.withLockedValue { $0[DNSWireFormat.extractDomainName(from: query).lowercased(), default: 0] += 1 }
            guard let answer = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: ip) else { return }
            var out = context.channel.allocator.buffer(capacity: answer.count)
            out.writeBytes(answer)
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
        }
    }
}

private final class HangingListener: @unchecked Sendable {
    let port: Int
    private let channel: Channel
    private let acceptedBox: NIOLockedValueBox<Int>

    var accepted: Int { acceptedBox.withLockedValue { $0 } }

    private init(port: Int, channel: Channel, accepted: NIOLockedValueBox<Int>) {
        self.port = port
        self.channel = channel
        acceptedBox = accepted
    }

    static func open(group: EventLoopGroup) async throws -> HangingListener {
        let accepted = NIOLockedValueBox(0)
        let channel = try await ServerBootstrap(group: group)
            .childChannelInitializer { _ in
                accepted.withLockedValue { $0 += 1 }
                return group.next().makeSucceededVoidFuture()
            }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        guard let port = channel.localAddress?.port else {
            try await channel.close().get()
            throw ScenarioExecutionError(message: "the hanging DoH listener has no bound port")
        }
        return HangingListener(port: port, channel: channel, accepted: accepted)
    }

    func close() async {
        do { try await channel.close().get() } catch { fputs("hanging DoH listener close failed: \(error)\n", stderr) }
    }
}
