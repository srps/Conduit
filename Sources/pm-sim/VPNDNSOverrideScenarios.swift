// SPDX-License-Identifier: Apache-2.0
import ConduitRuntime
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import NIOPosix
import PlatformMac
import ProxyKernel

enum VPNDNSOverrideScenarios {
    private static let corpIP = "198.51.100.10"
    private static let publicIP = "203.0.113.7"
    private static let internalName = "host.corp.example"
    private static let service = "com.cisco.anyconnect"
    private static let tunnelServers = ["192.0.2.53"]
    private static let relay = ["127.0.0.1"]
    private static let overrideEvents: Set<String> = [
        "dns.vpn_override_applied", "dns.vpn_override_released", "dns.vpn_override_refused",
        "dns.vpn_override_suspended", "dns.vpn_override_failed",
    ]

    @RuntimeActor
    static func applies() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-applies") { stage, check in
            try await stage.connect()
            check("the helper points the tunnel's key at the relay", try await stage.until { stage.key == relay })
            check("the helper holds the tunnel's own servers", stage.machine.vpnDNSRecordFile.bytes != nil)
            stage.publish()
            let substituted = stage.pushed.substitutions()
            check("the observer reads the key through the host's substitution", substituted == [service: tunnelServers])
            check("with the key at the relay, the tunnel's server answers internal names",
                  try await stage.resolve(internalName) == corpIP)
            check("the forwarder never asked loopback as a tunnel server", stage.corp.count(internalName) == 1)
            check("one apply, against the servers the client published",
                  stage.applies == [.apply(service: service, expected: tunnelServers)])
        } verify: { events, check in
            let lines = names(events)
            let set = lines.firstIndex { $0.hasPrefix("dns.split_table_changed detected_domains=1") }
            let applied = lines.firstIndex { $0 == "dns.vpn_override_applied service=\(service) servers=1" }
            check("the set is in use before the override lands", set != nil && applied != nil && set! < applied!)
            check("the reading of the helper's write is not a rejection",
                  !lines.contains { $0.contains("reason=self_referential") })
            check("the overridden reading changes nothing in the set",
                  events.filter { $0.event == "dns.split_detected" }.compactMap(\.detail)
                      == ["interface=utun6 domains=corp.example servers=1 outcome=applied",
                          "interface=utun6 domains=corp.example servers=1 outcome=cleared"])
            check("no override was refused or failed", !lines.contains { $0.hasPrefix("dns.vpn_override_refused") || $0.hasPrefix("dns.vpn_override_failed") })
        }
    }

    @RuntimeActor
    static func clientRewrite() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-client-rewrite") { stage, check in
            try await stage.connect()
            check("the first apply lands", try await stage.until { stage.key == relay })
            stage.publish()
            try await stage.pass()
            for (index, servers) in [["192.0.2.54"], ["192.0.2.55"]].enumerated() {
                stage.clock.advance(.seconds(120))
                stage.machine.vpnDNSStore.clientRewrite(service, servers: servers)
                stage.publish()
                check("rewrite \(index + 1) is applied against the client's new servers",
                      try await stage.until { stage.key == relay && stage.applies.last == .apply(service: service, expected: servers) })
                stage.publish()
                try await stage.pass()
            }
            stage.clock.advance(.seconds(120))
            stage.machine.vpnDNSStore.clientRewrite(service, servers: ["192.0.2.56"])
            stage.publish()
            check("the third rewrite in ten minutes is not applied: the client's value stays",
                  try await stage.until { stage.events.contains { $0.event == "dns.vpn_override_suspended" } })
            check("the key holds the client's newest servers", stage.key == ["192.0.2.56"])
            stage.clock.advance(.seconds(599))
            stage.publish()
            try await stage.pass()
            check("just before its lifetime ends the suspension holds", stage.applies.count == 3 && stage.key == ["192.0.2.56"])
            stage.clock.advance(.seconds(1))
            check("when its lifetime ends the suspension expires and the app applies against the newest servers",
                  try await stage.until { stage.key == relay && stage.applies.last == .apply(service: service, expected: ["192.0.2.56"]) })
            stage.publish()

            stage.clock.advance(.seconds(30))
            try await stage.report(.disconnected(reason: .userInitiated), live: [])
            try await stage.connect(servers: ["192.0.2.56"])
            check("a reconnect applies again",
                  try await stage.until { stage.key == relay && stage.applies.count == 5 })
        } verify: { events, check in
            let lines = names(events)
            check("three applies, a fourth when the suspension expires, a fifth after the reconnect",
                  lines.filter { $0.hasPrefix("dns.vpn_override_applied") }.count == 5)
            check("one suspension", lines.filter { $0.hasPrefix("dns.vpn_override_suspended") } == ["dns.vpn_override_suspended service=\(service) cap=applied"])
            let suspended = lines.firstIndex { $0.hasPrefix("dns.vpn_override_suspended") }
            let expired = lines.firstIndex { $0 == "dns.vpn_override_suspension_expired service=\(service)" }
            check("the suspension's end is reported once, after it",
                  suspended != nil && expired != nil && suspended! < expired!
                      && lines.filter { $0.hasPrefix("dns.vpn_override_suspension_expired") }.count == 1)
        }
    }

    @RuntimeActor
    static func disconnect() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-disconnect") { stage, check in
            try await stage.connect()
            check("the override lands", try await stage.until { stage.key == relay })
            stage.publish()

            stage.machine.vpnDNSStore.clientRemove(service)
            let writesBefore = stage.machine.vpnDNSStore.writes.count
            stage.publish()
            try await stage.pass()
            check("a key removed while connected is held with the set", stage.released.isEmpty)
            try await stage.report(.disconnected(reason: .userInitiated), live: [])
            check("the disconnect releases it", try await stage.until { stage.released.count == 1 })
            check("the release found the key gone and wrote nothing",
                  stage.released.last == .keyGone && stage.machine.vpnDNSStore.writes.count == writesBefore)
            check("no key is left behind", stage.machine.vpnDNSStore.tunnel(service) == nil)

            stage.clock.advance(.seconds(30))
            try await stage.connect()
            check("a reconnect applies again", try await stage.until { stage.key == relay })
            stage.publish()
            try await stage.report(.disconnected(reason: .networkLost), live: [])
            check("the gate turning off releases", try await stage.until { stage.released.count == 2 })
            check("the release restored the client's servers", stage.released.last == .restored && stage.key == tunnelServers)
        } verify: { events, check in
            let lines = names(events)
            let releases = lines.filter { $0.hasPrefix("dns.vpn_override_released") }
            check("each disconnect releases once, for the gate",
                  releases == ["dns.vpn_override_released reason=gate", "dns.vpn_override_released reason=gate"])
            let gate = lines.lastIndex { $0 == "dns.vpn_override_released reason=gate" }
            let dropped = lines.lastIndex { $0.hasPrefix("dns.split_table_changed detected_domains=0") && $0.hasSuffix("reason=vpn_disconnected") }
            check("the gate's release lands before the set drops", gate != nil && dropped != nil && gate! < dropped!)
        }
    }

    @RuntimeActor
    static func stop() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-stop") { stage, check in
            try await stage.connect()
            check("the override lands", try await stage.until { stage.key == relay })
            stage.publish()

            try await stage.setManageSystemDNS(false)
            check("turning Manage system DNS off restores the tunnel's servers",
                  try await stage.until { stage.key == tunnelServers && !stage.machine.dnsRelayRunning })
            check("the app's release comes before the relay stops", stage.releaseThenRelayStop(since: 0))
            stage.publish()

            stage.clock.advance(.seconds(30))
            try await stage.setManageSystemDNS(true)
            check("turning it back on applies again after the relay starts",
                  try await stage.until { stage.key == relay && stage.machine.dnsRelayRunning })
            stage.publish()
            let mark = stage.machine.vpnDNSOverrideOutcomes.count
            await stage.host.stopRuntime()
            check("a Stop restores the tunnel's servers", try await stage.until { stage.key == tunnelServers })
            check("the Stop's release comes before the relay stops", stage.releaseThenRelayStop(since: mark))
        } verify: { events, check in
            let releases = names(events).filter { $0.hasPrefix("dns.vpn_override_released") }
            check("the toggle releases as manage_off, the Stop as stop",
                  releases == ["dns.vpn_override_released reason=manage_off", "dns.vpn_override_released reason=stop"])
        }
    }

    @RuntimeActor
    static func helperRelease() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-helper-release") { stage, check in
            try await stage.connect()
            check("the override lands", try await stage.until { stage.key == relay })
            // The helper's tick comes seconds after its write, so the app has read the key at the relay by then.
            stage.publish()
            try await stage.pass()

            stage.machine.vpnDNSProbe.verdict = .refused
            stage.machine.tickVPNDNSOverride()
            check("one refused tick keeps the override", stage.key == relay && stage.released.isEmpty)
            stage.machine.tickVPNDNSOverride()
            check("the second refused tick releases and restores the servers",
                  stage.released == [.restored] && stage.key == tunnelServers)

            stage.machine.vpnDNSProbe.verdict = .answered
            stage.publish()
            check("the app sees the helper's release",
                  try await stage.until { stage.events.contains { $0.event == "dns.vpn_override_released" } })
            stage.clock.advance(.seconds(59))
            stage.publish()
            try await stage.pass()
            check("inside the backoff nothing is applied", stage.applies.count == 1 && stage.key == tunnelServers)
            stage.clock.advance(.seconds(1))
            stage.publish()
            check("once the backoff ends the app applies again", try await stage.until { stage.key == relay && stage.applies.count == 2 })
        } verify: { events, check in
            let releases = names(events).filter { $0.hasPrefix("dns.vpn_override_released") }
            check("the release carries the helper's reason", releases.first == "dns.vpn_override_released reason=helper:target_refused")
        }
    }

    @RuntimeActor
    static func tcpBindFails() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-tcp-bind-fails", prepare: { $0.dnsTCPRelayBindFails = true }) { stage, check in
            check("the UDP relay serves without the TCP one", stage.machine.dnsRelayRunning && !stage.machine.dnsTCPRelayRunning)
            try await stage.connect()
            check("the app asks for the override", try await stage.until { stage.applies.count == 1 })
            check("the helper refuses it, relay_not_serving",
                  stage.machine.vpnDNSOverrideOutcomes.contains(.refused(service: service, reason: .relayNotServing)))
            check("the tunnel's key keeps its servers", stage.key == tunnelServers && stage.machine.vpnDNSStore.writes.isEmpty)
            check("internal names still reach the tunnel's servers", try await stage.resolve(internalName) == corpIP)
        } verify: { events, check in
            check("the app reports the refusal",
                  names(events).contains("dns.vpn_override_refused reason=relay_not_serving"))
            check("nothing was applied", !names(events).contains { $0.hasPrefix("dns.vpn_override_applied") })
        }
    }

    @RuntimeActor
    static func tcpRelayDies() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-tcp-relay-dies") { stage, check in
            try await stage.connect()
            check("the override lands with both relays up",
                  try await stage.until { stage.key == relay } && stage.machine.dnsTCPRelayRunning)
            stage.publish()
            try await stage.pass()

            stage.machine.killDNSTCPRelay()
            stage.machine.tickVPNDNSOverride()
            check("the next tick releases and restores the servers", stage.released == [.restored] && stage.key == tunnelServers)
            check("the release says the relay stopped", stage.machine.vpnDNSOverrideOutcomes.contains {
                if case .released(_, .relayStopped, _) = $0 { true } else { false }
            })
            stage.publish()
            check("the app sees the helper's release",
                  try await stage.until { stage.events.contains { $0.event == "dns.vpn_override_released" } })
        } verify: { events, check in
            let releases = names(events).filter { $0.hasPrefix("dns.vpn_override_released") }
            check("the release carries the helper's reason", releases.first == "dns.vpn_override_released reason=helper:relay_stopped")
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
            check("the helper is never asked to apply", stage.applies.isEmpty)
            check("the split tunnel's key keeps its servers", stage.machine.vpnDNSStore.serverAddresses("split") == tunnelServers)
            check("the store was never written", stage.machine.vpnDNSStore.writes.isEmpty)
        } verify: { events, check in
            check("no override event", !events.contains { overrideEvents.contains($0.event) })
        }
    }

    @RuntimeActor
    static func flap() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-flap") { stage, check in
            try await stage.connect()
            check("the override lands", try await stage.until { stage.key == relay })
            stage.publish()
            try await stage.pass()

            stage.clock.advance(.seconds(66))
            try await stage.withdrawIPv4()
            check("a reading with no full tunnel keeps the override",
                  stage.key == relay && stage.released.isEmpty && stage.machine.vpnDNSRecordFile.bytes != nil)
            check("the parser ignored the key and 0044 held the set", try await stage.until { stage.events.contains {
                $0.event == "dns.split_resolver_ignored" && $0.detail?.hasSuffix("reason=no_match_domains") == true
            } && stage.events.contains { $0.event == "dns.split_detected" && $0.detail?.hasSuffix("outcome=held") == true } })
            try await stage.report(.reasserting, live: ["utun6"])
            try await stage.report(.connected, live: ["utun6"])
            stage.clock.advance(.seconds(5))
            try await stage.republishDNS()
            check("the DNS key alone, with the client's servers, keeps the override", stage.released.isEmpty)
            try await stage.republish(primary: false)
            check("the client's own servers before its service is primary: refused, not released",
                  try await stage.until { stage.events.contains { $0.event == "dns.vpn_override_refused" } } && stage.released.isEmpty)
            stage.clock.advance(.seconds(1))
            try await stage.withdrawIPv4()
            stage.clock.advance(.seconds(1))
            try await stage.republish(primary: true)
            check("republished as primary: the relay is back", try await stage.until { stage.key == relay && stage.applies.count == 3 })
            stage.publish()
            try await stage.pass()

            stage.clock.advance(.seconds(25 * 60))
            for index in 0...1 {
                try await stage.withdrawIPv4()
                check("withdrawal \(index + 1) keeps the override", stage.key == relay && stage.released.isEmpty)
                if index == 0 {
                    try await stage.report(.reasserting, live: ["utun6"])
                    try await stage.report(.connected, live: ["utun6"])
                }
                stage.clock.advance(.seconds(2))
                try await stage.republishDNS()
                try await stage.republish(primary: true)
                if index == 1 {
                    check("a republish inside the spacing waits for it",
                          stage.applies.count == 4 && stage.key == tunnelServers)
                    stage.clock.advance(.seconds(3))
                }
                check("republish \(index + 1) puts the relay back",
                      try await stage.until { stage.key == relay && stage.applies.count == 4 + index })
                stage.publish()
                try await stage.pass()
                stage.clock.advance(.seconds(5))
            }

            for minute in 1...2 {
                stage.clock.advance(.seconds(120))
                try await stage.withdrawIPv4()
                try await stage.republishDNS()
                try await stage.republish(primary: true)
                check("flap \(minute + 3) puts the relay back", try await stage.until { stage.key == relay && stage.applies.count == 5 + minute })
                stage.publish()
                try await stage.pass()
            }
            check("nothing was released while connected", stage.released.isEmpty)
            check("no flap suspends the override", !stage.events.contains { $0.event == "dns.vpn_override_suspended" })
            check("the internal name still resolves through the tunnel's server", try await stage.resolve(internalName) == corpIP)
        } verify: { events, check in
            let lines = names(events)
            check("one refusal, not_primary", lines.filter { $0.hasPrefix("dns.vpn_override_refused") } == ["dns.vpn_override_refused reason=not_primary"])
            check("the only release is the Stop's", lines.filter { $0.hasPrefix("dns.vpn_override_released") } == ["dns.vpn_override_released reason=stop"])
        }
    }

    @RuntimeActor
    static func republishBurst() async throws -> ScenarioResult {
        try await run(name: "dns-vpn-override-republish-burst") { stage, check in
            try await stage.connect()
            check("the override lands", try await stage.until { stage.key == relay })
            stage.publish()
            try await stage.pass()

            let flaps = 48
            var reapplied = 0
            for flap in 1...flaps {
                stage.clock.advance(.seconds(25))
                try await stage.withdrawIPv4()
                try await stage.republishDNS()
                try await stage.republish(primary: true)
                guard try await stage.until({ stage.key == relay && stage.applies.count == 1 + flap }) else { break }
                reapplied = flap
                stage.publish()
                try await stage.pass()
            }
            check("every same-server rewrite is applied again at once (\(reapplied) of \(flaps))", reapplied == flaps)
            check("no rewrite suspends the override", !stage.events.contains { $0.event == "dns.vpn_override_suspended" })
            check("nothing was released", stage.released.isEmpty)

            stage.clock.advance(.seconds(3))
            try await stage.withdrawIPv4()
            try await stage.republishDNS()
            try await stage.republish(primary: true)
            check("a rewrite inside the spacing waits",
                  stage.applies.count == 1 + flaps && stage.key == tunnelServers)
            stage.clock.advance(.seconds(6))
            try await stage.pass()
            check("it still waits just before the spacing ends", stage.applies.count == 1 + flaps && stage.key == tunnelServers)
            stage.clock.advance(.seconds(1))
            check("the wake applies it once the spacing ends",
                  try await stage.until { stage.key == relay && stage.applies.count == 2 + flaps })
            stage.publish()
            check("the internal name still resolves through the tunnel's server", try await stage.resolve(internalName) == corpIP)
        } verify: { events, check in
            let lines = names(events)
            check("every rewrite and the first apply are applied",
                  lines.filter { $0.hasPrefix("dns.vpn_override_applied") }.count == 50)
            check("nothing suspended, nothing refused", !lines.contains {
                $0.hasPrefix("dns.vpn_override_suspended") || $0.hasPrefix("dns.vpn_override_refused")
            })
            check("the only release is the Stop's", lines.filter { $0.hasPrefix("dns.vpn_override_released") } == ["dns.vpn_override_released reason=stop"])
        }
    }

    final class ManualClock: @unchecked Sendable {
        struct Overused: Error {}

        private struct Sleeper {
            let id: UInt64
            let deadline: ContinuousClock.Instant
            let waiter: CheckedContinuation<Void, any Error>
        }

        static let capacity = 2

        private let lock = NSLock()
        private var instant = ContinuousClock.now
        private var sleepers: [Sleeper] = []
        private var issued: UInt64 = 0
        private var overflowed = false

        var now: ContinuousClock.Instant { lock.withLock { instant } }
        var overused: Bool { lock.withLock { overflowed } }

        func advance(_ by: Duration) {
            let due = lock.withLock { () -> [Sleeper] in
                instant += by
                let due = sleepers.filter { $0.deadline <= instant }
                sleepers.removeAll { $0.deadline <= instant }
                return due
            }
            for sleeper in due { sleeper.waiter.resume() }
        }

        func sleep(until deadline: ContinuousClock.Instant) async throws {
            let id = lock.withLock { () -> UInt64 in
                issued += 1
                return issued
            }
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (waiter: CheckedContinuation<Void, any Error>) in
                    // One locked step with the cancellation check, so a cancel between them is not missed.
                    let outcome = lock.withLock { () -> Result<Void, any Error>? in
                        if Task.isCancelled { return .failure(CancellationError()) }
                        if deadline <= instant { return .success(()) }
                        guard sleepers.count < Self.capacity else {
                            overflowed = true
                            return .failure(Overused())
                        }
                        sleepers.append(Sleeper(id: id, deadline: deadline, waiter: waiter))
                        return nil
                    }
                    if let outcome { waiter.resume(with: outcome) }
                }
            } onCancel: {
                let cancelled = lock.withLock { () -> Sleeper? in
                    guard let index = sleepers.firstIndex(where: { $0.id == id }) else { return nil }
                    return sleepers.remove(at: index)
                }
                cancelled?.waiter.resume(throwing: CancellationError())
            }
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
        let clock: ManualClock
        let environment: RuntimeEnvironment
        let config: ProxyConfig

        init(
            host: RuntimeHost, control: any RuntimeClient, machine: FakeMachine, vpn: FakeVPNStatusObserver,
            pushed: FakePushedResolverObserver, corp: CountingDNSServer, clock: ManualClock,
            environment: RuntimeEnvironment, config: ProxyConfig
        ) {
            self.host = host
            self.control = control
            self.machine = machine
            self.vpn = vpn
            self.pushed = pushed
            self.corp = corp
            self.clock = clock
            self.environment = environment
            self.config = config
        }

        var key: [String]? { machine.vpnDNSStore.serverAddresses(service) }

        var applies: [VPNDNSOverrideRequest] {
            machine.privilege.vpnDNSOverrideRequests.filter { if case .apply = $0 { true } else { false } }
        }

        var released: [VPNDNSReleaseWrite] {
            machine.vpnDNSOverrideOutcomes.compactMap { if case .released(_, _, let write) = $0 { write } else { nil } }
        }

        var events: [RuntimeEvent] {
            (try? String(contentsOf: environment.eventsFile, encoding: .utf8))?.split(separator: "\n").compactMap {
                try? CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            } ?? []
        }

        func releaseThenRelayStop(since mark: Int) -> Bool {
            let log = Array(machine.vpnDNSOverrideOutcomes.dropFirst(mark))
            let release = log.firstIndex { if case .released(_, .requested, _) = $0 { true } else { false } }
            let stop = log.firstIndex { $0 == .nothingToRelease(reason: .relayStopped) }
            let stopReleased = log.contains { if case .released(_, .relayStopped, _) = $0 { true } else { false } }
            return release != nil && stop != nil && release! < stop! && !stopReleased
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
            pushed.emit(PushedResolverReading.parse(store: keys, substitutions: pushed.substitutions()))
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

        func until(_ condition: () -> Bool) async throws -> Bool {
            for _ in 0..<1000 {
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
        let clock = ManualClock()
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
            dnsForwarderTuning: tuning,
            vpnDNSOverrideClock: { clock.now },
            vpnDNSOverrideSleep: { try await clock.sleep(until: $0) }
        )

        do {
            try await host.startRuntime()
            let clients = try host.makeInMemoryControlClient(
                limits: try SplitDNSFollowsVPNScenarios.controlLimits(),
                clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            check("the helper's relay runs once DNS is managed", machine.dnsRelayRunning)
            let stage = Stage(
                host: host, control: clients.control, machine: machine, vpn: vpn, pushed: pushed, corp: corp, clock: clock,
                environment: environment, config: config
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
        check("no key is left at the relay", machine.vpnDNSStore.serverAddresses(service) != relay)
        check("the override armed at most one wake at a time", !clock.overused)
        do {
            let events = try String(contentsOf: environment.eventsFile, encoding: .utf8).split(separator: "\n").map {
                try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            }
            verify(events, check)
            check("no override event names a server address", !events.contains {
                overrideEvents.contains($0.event) && ($0.detail ?? "").contains("192.0.2.")
            })
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
        notes.append("helper override calls: \(machine.privilege.vpnDNSOverrideRequests.count); ledger outcomes: \(machine.vpnDNSOverrideOutcomes.count)")
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }
}
