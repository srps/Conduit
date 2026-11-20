// SPDX-License-Identifier: Apache-2.0
import ConduitRuntime
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import NIOCore
import NIOPosix
import PlatformMac
import ProxyKernel

enum VPNDNSOverrideScenarios {
    private static let corpIP = "198.51.100.10"
    private static let publicIP = "203.0.113.7"
    private static let vpnAnswerIP = "198.51.100.20"
    private static let internalName = "host.corp.example"
    private static let publicName = "www.example.com"
    private static let service = "com.cisco.anyconnect"
    private static let tunnelServers = ["192.0.2.53"]
    private static let overrideEvents: Set<String> = [
        "dns.vpn_override_armed", "dns.vpn_override_disarmed", "dns.vpn_override_published",
        "dns.vpn_override_withdrawn", "dns.vpn_override_failed", "dns.vpn_override_not_first",
    ]

    @RuntimeActor
    static func publishes() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-publishes") { stage, check in
            try await stage.connect()
            check("the helper publishes its own key once the set is live", try await stage.until { stage.ownKey != nil })
            check("the key names the relay's port as a domainless supplemental resolver",
                  stage.ownKey == VPNDNSOverridePublisher.ownKey(port: HelperConstants.vpnDNSOverrideRelayPort))
            check("the VPN's key keeps its servers", stage.machine.vpnDNSStore.serverAddresses(service) == tunnelServers)
            stage.publish()
            try await stage.pass()
            check("with the own key in the store, the tunnel's server still answers internal names",
                  try await stage.resolve(internalName) == corpIP)
            check("one arm, with the servers the client published",
                  stage.arms == [.arm(service: service, servers: tunnelServers)])
        } verify: { events, check in
            let lines = names(events)
            let set = lines.firstIndex { $0.hasPrefix("dns.split_table_changed detected_domains=1") }
            let armed = lines.firstIndex { $0 == "dns.vpn_override_armed service=\(service) servers=1" }
            let published = lines.firstIndex { $0 == "dns.vpn_override_published service=\(service)" }
            check("the set is in use before the arm, and the arm before the key",
                  set != nil && armed != nil && published != nil && set! < armed! && armed! < published!)
            check("the parser ignored the own key: the set never changed",
                  events.filter { $0.event == "dns.split_detected" }.compactMap(\.detail)
                      == ["interface=utun6 domains=corp.example servers=1 outcome=applied",
                          "interface=utun6 domains=corp.example servers=1 outcome=cleared"])
            check("resolver #1 is the helper's", !lines.contains { $0.hasPrefix("dns.vpn_override_not_first") })
            check("nothing failed", !lines.contains { $0.hasPrefix("dns.vpn_override_failed") })
        }
    }

    @RuntimeActor
    static func disconnect() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-disconnect") { stage, check in
            try await stage.connect()
            check("the key lands", try await stage.until { stage.ownKey != nil })
            stage.publish()

            check("the app has seen it", try await stage.landed())
            stage.machine.vpnDNSStore.clientRemove(service)
            check("a removed VPN key withdraws the own key at once", stage.ownKey == nil)
            stage.publish()
            check("the reading without the tunnel disarms", try await stage.until { stage.disarms == 1 })
            try await stage.report(.disconnected(reason: .userInitiated), live: [])
            try await stage.pass()
            check("the disconnect has nothing left to disarm", stage.disarms == 1)

            try await stage.connect()
            check("a reconnect publishes again", try await stage.landed(2))
            stage.publish()
            try await stage.report(.disconnected(reason: .networkLost), live: [])
            check("the gate turning off disarms and withdraws", try await stage.until { stage.disarms == 2 && stage.ownKey == nil })
        } verify: { events, check in
            let lines = names(events)
            check("the removed key disarms as not_in_use, the gate as gate",
                  lines.filter { $0.hasPrefix("dns.vpn_override_disarmed") }
                      == ["dns.vpn_override_disarmed reason=not_in_use", "dns.vpn_override_disarmed reason=gate"])
            check("resolver #1 was the helper's while the app read it", !lines.contains { $0.hasPrefix("dns.vpn_override_not_first") })
            let gate = lines.lastIndex { $0 == "dns.vpn_override_disarmed reason=gate" }
            let dropped = lines.lastIndex { $0.hasPrefix("dns.split_table_changed detected_domains=0") && $0.hasSuffix("reason=vpn_disconnected") }
            check("the gate's disarm lands before the set drops", gate != nil && dropped != nil && gate! < dropped!)
        }
    }

    @RuntimeActor
    static func stop() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-stop") { stage, check in
            try await stage.connect()
            check("the key lands", try await stage.until { stage.ownKey != nil })
            stage.publish()

            try await stage.setManageSystemDNS(false)
            check("turning Manage system DNS off withdraws the key and stops the relay",
                  try await stage.until { stage.ownKey == nil && !stage.machine.dnsRelayRunning })
            check("the disarm comes before the relay stops", stage.disarmThenRelayStop(since: 0))
            stage.publish()

            try await stage.setManageSystemDNS(true)
            check("turning it back on publishes again after the relay starts",
                  try await stage.until { stage.ownKey != nil && stage.machine.dnsRelayRunning })
            stage.publish()
            let mark = stage.machine.vpnDNSOverrideOutcomes.count
            await stage.host.stopRuntime()
            check("a Stop withdraws the key", try await stage.until { stage.ownKey == nil })
            check("the Stop's disarm comes before the relay stops", stage.disarmThenRelayStop(since: mark))
        } verify: { events, check in
            // A pass beside an explicit disarm may report the same reason again.
            let disarms = names(events).filter { $0.hasPrefix("dns.vpn_override_disarmed") }
                .reduce(into: [String]()) { if $0.last != $1 { $0.append($1) } }
            check("the toggle disarms first as manage_off, the Stop as stop",
                  Array(disarms.prefix(2)) == ["dns.vpn_override_disarmed reason=manage_off", "dns.vpn_override_disarmed reason=stop"])
        }
    }

    @RuntimeActor
    static func tcpBindFails() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-tcp-bind-fails", prepare: { $0.dnsTCPRelayBindFails = true }) { stage, check in
            check("the UDP relay serves without the TCP one", stage.machine.dnsRelayRunning && !stage.machine.dnsTCPRelayRunning)
            try await stage.connect()
            check("the app arms", try await stage.until { stage.arms.count == 1 })
            try await stage.pass()
            check("the helper holds the key back while its relay has no TCP half", stage.ownKey == nil)
            check("internal names still reach the tunnel's servers", try await stage.resolve(internalName) == corpIP)
        } verify: { events, check in
            check("nothing was published", !names(events).contains { $0.hasPrefix("dns.vpn_override_published") })
        }
    }

    @RuntimeActor
    static func splitTunnel() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-split-tunnel") { stage, check in
            stage.machine.vpnDNSStore.setTunnel("split", .init(dns: [
                "ServerAddresses": .strings(tunnelServers),
                "SupplementalMatchDomains": .strings(["corp.example"]),
            ], overridePrimary: false))
            stage.publish()
            try await stage.report(.connected, live: ["utun3"])
            check("the split tunnel's server answers its domain", try await stage.resolve(internalName) == corpIP)
            try await stage.pass()
            check("the helper is never asked to arm", stage.arms.isEmpty)
            check("no own key", stage.ownKey == nil)
        } verify: { events, check in
            check("no override event", !events.contains { overrideEvents.contains($0.event) })
        }
    }

    @RuntimeActor
    static func flap() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-flap") { stage, check in
            try await stage.connect()
            check("the key lands", try await stage.until { stage.ownKey != nil })
            stage.publish()
            try await stage.pass()

            for round in 1...5 {
                try await stage.withdrawIPv4()
                check("withdrawal \(round) withdraws the key at once", stage.ownKey == nil)
                if round == 1 {
                    try await stage.report(.reasserting, live: ["utun6"])
                    try await stage.report(.connected, live: ["utun6"])
                }
                try await stage.republishDNS()
                try await stage.republish(primary: false)
                check("flap \(round): no key while the VPN's service is not primary", stage.ownKey == nil)
                try await stage.republish(primary: true)
                check("flap \(round): the key is back once the VPN republishes", try await stage.until { stage.ownKey != nil })
            }
            check("the internal name still resolves through the tunnel's server", try await stage.resolve(internalName) == corpIP)

            stage.machine.resolverOrderIgnoresOwnKey = true
            try await stage.withdrawIPv4()
            try await stage.republish(primary: true)
            check("a resolver order that skips the own key is reported",
                  try await stage.until { stage.events.contains { $0.event == "dns.vpn_override_not_first" } })
        } verify: { events, check in
            let lines = names(events)
            check("nothing failed", !lines.contains { $0.hasPrefix("dns.vpn_override_failed") })
            check("the order is reported once", lines.filter { $0.hasPrefix("dns.vpn_override_not_first") }
                == ["dns.vpn_override_not_first service=\(service)"])
        }
    }

    @RuntimeActor
    static func ownKeyHelperDies() async throws -> ScenarioResult {
        try await run(name: "dns-own-key-helper-dies") { stage, check in
            try await stage.connect()
            check("the key lands", try await stage.until { stage.ownKey != nil })
            stage.publish()
            try await stage.pass()

            stage.machine.killVPNDNSOverrideHelper()
            check("configd removes the dead session's key", stage.ownKey == nil)
            check("the VPN's key was never written", stage.machine.vpnDNSStore.vpnKeyWrites.isEmpty)
            check("the app restarts the relay, re-arms the fresh helper and the key returns",
                  try await stage.until(seconds: 60) { stage.ownKey != nil && stage.arms.count == 2 })
            check("lookups resolve again", try await stage.resolve(internalName) == corpIP)
        } verify: { events, check in
            let lines = names(events)
            check("the app saw the key go with the helper", lines.contains("dns.vpn_override_withdrawn reason=helper_stopping"))
            check("and published again", lines.filter { $0.hasPrefix("dns.vpn_override_published") }.count == 2)
        }
    }

    @RuntimeActor
    static func ownKeyConfigdRestart() async throws -> ScenarioResult {
        try await run(name: "dns-own-key-configd-restart") { stage, check in
            try await stage.connect()
            check("the key lands", try await stage.until { stage.ownKey != nil })
            stage.publish()
            try await stage.pass()
            let arms = stage.arms.count

            stage.machine.vpnDNSStore.configdRestart()
            check("the helper republishes the key a configd restart dropped", stage.ownKey != nil)
            check("on its own, with no new arm", stage.arms.count == arms)
            check("the VPN's key was never written", stage.machine.vpnDNSStore.vpnKeyWrites.isEmpty)
            let published = stage.machine.vpnDNSOverrideOutcomes.filter { if case .published = $0 { true } else { false } }
            check("two publishes, one store call each", published.count == 2)
        } verify: { events, check in
            check("nothing failed", !names(events).contains { $0.hasPrefix("dns.vpn_override_failed") })
        }
    }

    @RuntimeActor
    static func ownKeyConduitGone() async throws -> ScenarioResult {
        try await rig(name: "dns-own-key-conduit-gone") { rig, check in
            check("Conduit answers through the relay", try await rig.lookup().answer == publicIP)
            await rig.conduit.stop()
            let gone = try await rig.lookup()
            check("with Conduit gone and the key still up, the VPN answers", gone.answer == vpnAnswerIP && rig.machine.vpnDNSStore.ownKey != nil)
            check("at once, on the refusal", gone.seconds < 1.0)
            rig.machine.vpnDNSOverrideOwnerExited()
            check("the owner's exit withdraws the key", rig.machine.vpnDNSStore.ownKey == nil)
            check("and leaves the relay on the VPN's servers", rig.relay.mode == .vpn)
            check("a lookup still in flight to the relay is answered", try await rig.lookup().answer == vpnAnswerIP)
        }
    }

    @RuntimeActor
    static func ownKeyConduitHung() async throws -> ScenarioResult {
        try await rig(name: "dns-own-key-conduit-hung") { rig, check in
            check("Conduit answers through the relay", try await rig.lookup().answer == publicIP)
            rig.conduit.silent = true
            let hung = try await rig.lookup()
            check("a hung Conduit's lookup is answered by the VPN", hung.answer == vpnAnswerIP)
            check("within the probe's budget", hung.seconds >= 1.0 && hung.seconds < 2.5)
            check("the relay switched to the VPN's servers", rig.relay.mode == .vpn)
            check("the next lookup goes to them at once", try await rig.lookup().seconds < 0.5)
            rig.machine.tickVPNDNSOverride()
            rig.machine.tickVPNDNSOverride()
            check("two silent ticks keep the key", rig.machine.vpnDNSStore.ownKey != nil)
            rig.machine.tickVPNDNSOverride()
            check("the third withdraws it", rig.machine.vpnDNSStore.ownKey == nil
                && rig.machine.vpnDNSOverrideOutcomes.contains(.withdrawn(service: service, reason: .targetSilent)))
            rig.conduit.silent = false
            rig.machine.tickVPNDNSOverride()
            check("an answered probe brings the key and Conduit back",
                  rig.machine.vpnDNSStore.ownKey != nil && rig.relay.mode == .conduit)
            check("Conduit answers again", try await rig.lookup().answer == publicIP)
        }
    }

    @RuntimeActor
    final class Stage {
        let host: RuntimeHost
        let control: any RuntimeClient
        let machine: FakeMachine
        let vpn: FakeVPNStatusObserver
        let pushed: FakePushedResolverObserver
        let corp: CountingDNSServer
        let environment: RuntimeEnvironment

        init(
            host: RuntimeHost, control: any RuntimeClient, machine: FakeMachine, vpn: FakeVPNStatusObserver,
            pushed: FakePushedResolverObserver, corp: CountingDNSServer, environment: RuntimeEnvironment
        ) {
            self.host = host
            self.control = control
            self.machine = machine
            self.vpn = vpn
            self.pushed = pushed
            self.corp = corp
            self.environment = environment
        }

        var ownKey: [String: VPNDNSValue]? { machine.vpnDNSStore.ownKey }

        var arms: [VPNDNSOverrideRequest] {
            machine.privilege.vpnDNSOverrideRequests.filter { if case .arm = $0 { true } else { false } }
        }

        var disarms: Int {
            machine.privilege.vpnDNSOverrideRequests.filter { $0 == .disarm }.count
        }

        var events: [RuntimeEvent] {
            (try? String(contentsOf: environment.eventsFile, encoding: .utf8))?.split(separator: "\n").compactMap {
                try? CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            } ?? []
        }

        func disarmThenRelayStop(since mark: Int) -> Bool {
            let log = Array(machine.vpnDNSOverrideOutcomes.dropFirst(mark))
            return log.contains(.withdrawn(service: service, reason: .disarmed))
                && !log.contains(.withdrawn(service: service, reason: .relayStopped))
                && !machine.dnsRelayRunning
        }

        func connect(servers: [String] = tunnelServers) async throws {
            machine.vpnDNSStore.connectFullTunnel(service, servers: servers, extra: ["DomainName": .string("corp.example")])
            publish()
            try await report(.connected, live: ["utun6"])
        }

        var ipv6Published: Set<String> = []

        func withdrawIPv4() async throws {
            guard var tunnel = machine.vpnDNSStore.tunnel(service) else { return }
            tunnel.ipv4 = false
            machine.vpnDNSStore.setTunnel(service, tunnel)
            machine.vpnDNSStore.primary = nil
            ipv6Published.insert(service)
            publish()
            try await pass()
        }

        func republishDNS() async throws {
            ipv6Published.remove(service)
            machine.vpnDNSStore.clientRewrite(service, servers: tunnelServers)
            publish()
            try await pass()
        }

        func republish(primary: Bool) async throws {
            guard var tunnel = machine.vpnDNSStore.tunnel(service) else { return }
            tunnel.ipv4 = true
            tunnel.overridePrimary = true
            machine.vpnDNSStore.setTunnel(service, tunnel)
            machine.vpnDNSStore.primary = primary ? service : nil
            ipv6Published.insert(service)
            publish()
            try await pass()
        }

        /// The store as the monitor reads it, the helper's own key included.
        func publish() {
            var keys: [String: Any] = [:]
            for (id, interface) in [(service, "utun6"), ("split", "utun3")] {
                guard let tunnel = machine.vpnDNSStore.tunnel(id) else { continue }
                if let dns = tunnel.dns { keys["State:/Network/Service/\(id)/DNS"] = dns.mapValues(Self.plist) }
                if ipv6Published.contains(id) { keys["State:/Network/Service/\(id)/IPv6"] = ["InterfaceName": interface] }
                if tunnel.ipv4 {
                    var ipv4: [String: Any] = ["InterfaceName": interface]
                    if tunnel.overridePrimary { ipv4["OverridePrimary"] = 1 }
                    keys["State:/Network/Service/\(id)/IPv4"] = ipv4
                }
            }
            if let own = machine.vpnDNSStore.ownKey {
                keys["State:/Network/Service/\(HelperConstants.vpnDNSOverrideServiceID)/DNS"] = own.mapValues(Self.plist)
            }
            pushed.emit(PushedResolverReading.parse(store: keys))
        }

        private static func plist(_ value: VPNDNSValue) -> Any {
            switch value {
            case .string(let text): text
            case .number(let number): NSNumber(value: number)
            case .bool(let flag): NSNumber(value: flag)
            case .strings(let list): list
            case .numbers(let list): list.map { NSNumber(value: $0) }
            }
        }

        func pass() async throws {
            await host.settleObserverDeliveries()
        }

        /// The key is up and the app has confirmed its `count`th publish.
        func landed(_ count: Int = 1) async throws -> Bool {
            let seen = try await until {
                ownKey != nil && events.filter { $0.event == "dns.vpn_override_published" }.count >= count
            }
            try await pass()
            return seen
        }

        func until(seconds: Int = 10, _ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<(seconds * 100) {
                if condition() { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return condition()
        }

        func setManageSystemDNS(_ on: Bool) async throws {
            try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageSystemDNS: on), in: environment)
            _ = await host.reloadConfiguration()
        }

        func report(_ state: VPNObservedState, live: [String]) async throws {
            vpn.liveInterfaceNames = live
            vpn.connectedInterfaceName = live.first
            vpn.emit(state)
            let expected: ControlVPNState = switch state {
            case .connected: .connected
            case .reasserting: .reasserting
            case .unknown: .unknown
            case .disconnected(reason: .userInitiated): .disconnected(.userInitiated)
            case .disconnected: .disconnected(.networkLost)
            }
            for _ in 0..<1000 {
                if try await control.readSnapshot(deadline: .after(.seconds(30), from: ContinuousClock.now)).vpnState == expected { return }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw ScenarioExecutionError(message: "the host never showed the VPN report \(expected)")
        }

        func resolve(_ name: String) async throws -> String? {
            guard let port = host.status().bindings.dnsPort else { return nil }
            let reply = try await DNSProbe.overUDP(query: DNSWireFormat.buildQuery(domain: name, txID: 0x5D49), port: port, timeout: 12)
            return reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip
        }
    }

    private static func names(_ events: [RuntimeEvent]) -> [String] {
        events.map { "\($0.event) \($0.detail ?? "")" }
    }

    @RuntimeActor
    private static func run(
        name: String,
        prepare: (FakeMachine) -> Void = { _ in },
        _ body: @RuntimeActor (Stage, (String, Bool) -> Void) async throws -> Void,
        verify: ([RuntimeEvent], (String, Bool) -> Void) -> Void
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

        let upstream = try await ClosingUpstream.open()
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 0
        config.localPACEnabled = false
        config.pacRoutingEnabled = false
        config.upstreams = [upstream.proxy]
        config.dnsForwarderEnabled = true
        config.dnsForwarderPort = 0
        config.dnsEntries = []
        config.dohProviders = ["http://127.0.0.1:\(doh.port)/dns-query"]
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageSystemDNS: true), in: environment)

        let machine = FakeMachine(resolverDirectory: scratch.appendingPathComponent("resolver", isDirectory: true))
        prepare(machine)
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
                connectivityProbe: .injected(SimulatedUpstreams.unreachable),
                portHolderProbe: FakeListenerPortHolderProbe(),
                loopbackPortProbe: FakeLoopbackPortProbe().liveness(port:),
                commandRunner: { try machine.run($0, $1) },
                dnsProbe: { _ in machine.dnsRelayRunning ? .live : .notLive },
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
            check("the helper's relay runs once DNS is managed", machine.dnsRelayRunning)
            let stage = Stage(
                host: host, control: clients.control, machine: machine, vpn: vpn, pushed: pushed, corp: corp,
                environment: environment
            )
            try await body(stage, check)
        } catch {
            notes.append("failed: \(error)")
            check("the scenario ran to its end", false)
        }

        await host.stopRuntime()
        let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        let flush = await host.flushEvents()
        check("the host settles and flushes", settled == .settled && flush.allConfirmed)
        check("no own key is left after the Stop", machine.vpnDNSStore.ownKey == nil)
        check("the VPN's keys were never written", machine.vpnDNSStore.vpnKeyWrites.isEmpty)
        do {
            let events = try String(contentsOf: environment.eventsFile, encoding: .utf8).split(separator: "\n").map {
                try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            }
            verify(events, check)
            check("no override event names a server address", !events.contains {
                overrideEvents.contains($0.event) && ($0.detail ?? "").contains("192.0.2.")
            })
            if assertions.contains(where: { !$0.passed }) {
                notes.append("override events: \(names(events.filter { $0.event.hasPrefix("dns.vpn_override") }))")
            }
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
        notes.append("helper override calls: \(machine.privilege.vpnDNSOverrideRequests.count); publisher outcomes: \(machine.vpnDNSOverrideOutcomes.count)")
        return result(name: name, began: began, assertions: assertions, notes: notes)
    }

    /// The helper's half alone: a real fail-safe relay between a stand-in forwarder and a stand-in VPN server.
    final class Rig: @unchecked Sendable {
        let machine: FakeMachine
        let relay: DNSFailoverRelay
        let conduit: StandInDNSServer
        let vpnServer: StandInDNSServer

        init(machine: FakeMachine, relay: DNSFailoverRelay, conduit: StandInDNSServer, vpnServer: StandInDNSServer) {
            self.machine = machine
            self.relay = relay
            self.conduit = conduit
            self.vpnServer = vpnServer
        }

        func lookup() async throws -> (answer: String?, seconds: Double) {
            guard let port = relay.listeningPort else { return (nil, 0) }
            let began = ContinuousClock.now
            let reply = try await DNSProbe.overUDP(
                query: DNSWireFormat.buildQuery(domain: publicName, txID: UInt16.random(in: 1...UInt16.max)), port: port, timeout: 5
            )
            let elapsed = ContinuousClock.now - began
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            return (reply.flatMap(DNSWireFormat.firstIPv4Answer)?.ip, seconds)
        }
    }

    @RuntimeActor
    private static func rig(
        name: String,
        _ body: @RuntimeActor (Rig, (String, Bool) -> Void) async throws -> Void
    ) async throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        var notes: [String] = []

        let group = MultiThreadedEventLoopGroup.singleton
        let conduit = StandInDNSServer(ip: publicIP)
        try await conduit.start(group: group)
        ScenarioCleanup.register { await conduit.stop() }
        let vpnServer = StandInDNSServer(ip: vpnAnswerIP)
        try await vpnServer.start(group: group)
        ScenarioCleanup.register { await vpnServer.stop() }
        let vpnPort = vpnServer.port
        // Every VPN server the relay may try is the loopback stand-in; nothing leaves the Mac.
        let relay = DNSFailoverRelay(listenPort: 0, maximumTCPSessions: 64, serverEndpoint: { _ in
            DNSFailoverEndpoint(host: "127.0.0.1", port: vpnPort)
        })
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(name)-\(UUID().uuidString)", isDirectory: true)
        let machine = FakeMachine(resolverDirectory: scratch, failoverRelay: relay)
        defer {
            relay.stop()
            do { try FileManager.default.removeItem(at: scratch) } catch { fputs("scratch kept at \(scratch.path)\n", stderr) }
        }

        do {
            machine.vpnDNSStore.connectFullTunnel(service, servers: tunnelServers)
            try machine.execute(.startDNSRelay, values: ["\(conduit.port)"])
            check("both halves of the relay listen", relay.listeningPort != nil)
            _ = try machine.vpnDNSOverride(.arm(service: service, servers: tunnelServers))
            check("the key is published, naming the relay's port",
                  relay.listeningPort.map { machine.vpnDNSStore.ownKey == VPNDNSOverridePublisher.ownKey(port: $0) } ?? false)
            try await body(Rig(machine: machine, relay: relay, conduit: conduit, vpnServer: vpnServer), check)
        } catch {
            notes.append("failed: \(error)")
            check("the scenario ran to its end", false)
        }
        check("the VPN's key was never written", machine.vpnDNSStore.vpnKeyWrites.isEmpty)
        notes.append("conduit asked: \(conduit.total); vpn asked: \(vpnServer.total)")
        return result(name: name, began: began, assertions: assertions, notes: notes)
    }

    private static func result(name: String, began: Date, assertions: [ScenarioAssertion], notes: [String]) -> ScenarioResult {
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }
}

/// A DNS server that answers every A query with one address, and can be made silent.
final class StandInDNSServer: @unchecked Sendable {
    private let ip: String
    private let state = NIOLockedValueBox((silent: false, asked: 0))
    private let channel = NIOLockedValueBox<Channel?>(nil)

    init(ip: String) {
        self.ip = ip
    }

    var port: Int { channel.withLockedValue { $0?.localAddress?.port } ?? 0 }
    var total: Int { state.withLockedValue { $0.asked } }

    var silent: Bool {
        get { state.withLockedValue { $0.silent } }
        set { state.withLockedValue { $0.silent = newValue } }
    }

    func start(group: EventLoopGroup) async throws {
        let handler = Responder(ip: ip, state: state)
        let bound = try await DatagramBootstrap(group: group)
            .channelInitializer { $0.pipeline.addHandler(handler) }
            .bind(host: "127.0.0.1", port: 0)
            .get()
        channel.withLockedValue { $0 = bound }
    }

    func stop() async {
        guard let bound = channel.withLockedValue({ current in defer { current = nil }; return current }) else { return }
        do { try await bound.close() } catch { fputs("stand-in DNS server close failed: \(error)\n", stderr) }
    }

    private final class Responder: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = AddressedEnvelope<ByteBuffer>
        typealias OutboundOut = AddressedEnvelope<ByteBuffer>

        private let ip: String
        private let state: NIOLockedValueBox<(silent: Bool, asked: Int)>

        init(ip: String, state: NIOLockedValueBox<(silent: Bool, asked: Int)>) {
            self.ip = ip
            self.state = state
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let envelope = unwrapInboundIn(data)
            var buffer = envelope.data
            let query = buffer.readBytes(length: buffer.readableBytes) ?? []
            let silent = state.withLockedValue { current in
                current.asked += 1
                return current.silent
            }
            guard !silent, let answer = DNSWireFormat.synthesizeDirectResponse(originalQuery: query, ip: ip) else { return }
            var out = context.channel.allocator.buffer(capacity: answer.count)
            out.writeBytes(answer)
            context.writeAndFlush(wrapOutboundOut(AddressedEnvelope(remoteAddress: envelope.remoteAddress, data: out)), promise: nil)
        }
    }
}
