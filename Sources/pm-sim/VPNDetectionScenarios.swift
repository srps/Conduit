// SPDX-License-Identifier: Apache-2.0
import ConduitRuntime
import ConduitShared
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel

/// The level-triggered VPN monitor (unit U3, decisions 0047 and 0048) inside the actual `RuntimeHost` (decision 0033),
/// over a scratch root. The monitor is the production `VPNStatusMonitor` over `FakeTunnelStore` and a held clock; every
/// other machine effect is a fake, the privilege client and the resolver directory are `FakeMachine`'s, the upstream
/// probe answers without dialing (`SimulatedUpstreams`), and the health loop dials the run's own `ClosingUpstream`. Time
/// moves only when a scenario fires the one wake-up the monitor holds, so the retries, deadlines and audits are counted, not timed.
/// The host is read through what a client sees: its control snapshot, the resolver files and its events file.
///
/// - `vpn-blind-gap-disconnect`: the store becomes unreadable as the tunnel loses its address. While blind the host
///   shows `.unknown`, which withholds the entry files. The recovery reading, past the flap windows measured from the
///   last good reading, is `.disconnected(.networkLost)` at once, never `.connected` or `.reasserting`.
/// - `vpn-audit-corrects-dropped-notification`: the store drops the notification for a removed tunnel; the 60 s audit
///   reads it and the host removes the entry file.
/// - `vpn-rapid-flap-burst`: six losses shorter than the debounce, each recovered before its deadline, reach the host
///   as nothing.
/// - `vpn-blind-flap-recovery`: a read fails during a flap and the next reading finds the tunnel back. The entry file is
///   withheld while blind and put back after; the host reports a flap recovery, not a cold connect.
/// - `vpn-tunnel-removed-while-stopped`: the tunnel goes away while the runtime is stopped. The next Start applies its
///   surfaces before the monitor's new session reads the store, and writes no entry file from the verdict the stop left
///   behind; the new session's first reading is a disconnect.
enum VPNDetectionScenarios {
    @RuntimeActor
    static func blindGapDisconnect() async throws -> ScenarioResult {
        try await run(name: "vpn-blind-gap-disconnect") { stage, check in
            check("the first reading is connected", try await stage.shows(.connected))
            check("the host reported the connect", try await stage.reported("vpn.connected", count: 1))
            check("connected installs the entry file", stage.entryFile)

            stage.store.readFailure = .init(.storeRead, code: 1001)
            stage.store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
            check("an unreadable store shows as unknown", try await stage.shows(.unknown))
            check("unknown withholds the entry file", !stage.entryFile)

            var delays: [TimeInterval] = []
            for attempt in 1...3 {
                guard let sleep = try await stage.wake(matching: { $0.seconds < 60 }) else { break }
                delays.append(sleep.seconds)
                if attempt == 3 { stage.store.readFailure = nil }
                stage.clock.fire()
                if attempt < 3 { check("no entry file while blind after retry \(attempt)", !stage.entryFile) }
            }
            check("the reads were retried after 1, 2 and 4 s", delays == [1, 2, 4])
            check(
                "7 s after the last good reading the loss is a disconnect at once (0047)",
                try await stage.shows(.disconnected(.networkLost))
            )
            check("the host reported the loss", try await stage.reported("vpn.disconnected.lost", count: 1))
            check("the disconnect leaves no entry file, written once", !stage.entryFile && stage.applies == 1)
        } verify: { events, check in
            check("the attempts 1 and 2 and the recovery were reported", storeEvents(events) == [
                "vpn.store_failed reason=store_read code=1001 attempt=1",
                "vpn.store_failed reason=store_read code=1001 attempt=2",
                "vpn.store_recovered attempts=3",
            ])
            check("the host never saw a flap", count("vpn.flap.start", in: events) == 0)
            check("the host reported the loss once", count("vpn.disconnected.lost", in: events) == 1)
        }
    }

    @RuntimeActor
    static func auditCorrectsDroppedNotification() async throws -> ScenarioResult {
        try await run(name: "vpn-audit-corrects-dropped-notification") { stage, check in
            check("the first reading is connected", try await stage.shows(.connected))
            check("the host reported the connect", try await stage.reported("vpn.connected", count: 1))
            check("connected installs the entry file", stage.entryFile)
            check("a healthy session waits 60 s for its audit", try await stage.wake()?.seconds == 60)

            stage.store.notifications = .dropped
            stage.store.setInterface("utun6", ipv4: nil, ipv6: nil)
            stage.settleMonitor()
            check("with the notification lost the host still shows connected", try await stage.snapshot().vpnState == .connected)
            check("with the notification lost the entry file stays", stage.entryFile)

            stage.clock.fire()
            check("the audit reads the removal", try await stage.shows(.disconnected(.userInitiated)))
            check("the host reported the removal", try await stage.reported("vpn.disconnected.user", count: 1))
            check("the disconnect removes the entry file", !stage.entryFile)
            check("the next audit is armed", try await stage.wake()?.seconds == 60)
        } verify: { events, check in
            check("a healthy store reports nothing", storeEvents(events).isEmpty)
            check("the host reported the removal once", count("vpn.disconnected.user", in: events) == 1)
        }
    }

    @RuntimeActor
    static func rapidFlapBurst() async throws -> ScenarioResult {
        try await run(name: "vpn-rapid-flap-burst") { stage, check in
            check("the first reading is connected", try await stage.shows(.connected))
            check("the host reported the connect", try await stage.reported("vpn.connected", count: 1))
            var debounces = 0
            for _ in 0..<6 {
                stage.store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
                if try await stage.wake(matching: { $0.seconds == 1 }) != nil { debounces += 1 }
                stage.clock.advance(by: 0.25)
                stage.store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
                _ = try await stage.wake(matching: { $0.seconds == 60 })
            }
            check("each loss armed its debounce", debounces == 6)
            stage.settleMonitor()
            check("the host still shows connected", try await stage.snapshot().vpnState == .connected)
            check("the entry file stayed, written once", stage.entryFile && stage.applies == 1)
        } verify: { events, check in
            check("no store event", storeEvents(events).isEmpty)
            check("six losses under the debounce reach the host as nothing",
                  count("vpn.flap.start", in: events) == 0 && count("vpn.connected", in: events) == 1)
        }
    }

    @RuntimeActor
    static func blindFlapRecovery() async throws -> ScenarioResult {
        try await run(name: "vpn-blind-flap-recovery") { stage, check in
            check("the first reading is connected", try await stage.shows(.connected))
            check("the host reported the connect", try await stage.reported("vpn.connected", count: 1))
            stage.store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
            check("the loss arms its debounce", try await stage.wake(matching: { $0.seconds == 1 }) != nil)
            stage.clock.fire()
            check("past the debounce the host shows the flap", try await stage.shows(.reasserting))
            check("a flap keeps the entry file", stage.entryFile)

            stage.store.readFailure = .init(.storeRead, code: 1001)
            stage.store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::2"])
            check("a failed read mid-flap shows as unknown", try await stage.shows(.unknown))
            check("unknown withholds the entry file", !stage.entryFile)

            stage.store.readFailure = nil
            stage.store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::2"])
            check("the tunnel back shows as connected", try await stage.shows(.connected))
            check("the host reported the flap's recovery", try await stage.reported("vpn.flap.recovered", count: 1))
            check("the recovery puts the entry file back", stage.entryFile && stage.applies == 2)
            check("the host counts one flap", try await stage.snapshot().vpnFlap.count.rawValue == 1)
        } verify: { events, check in
            check("the failure and the recovery were reported", storeEvents(events) == [
                "vpn.store_failed reason=store_read code=1001 attempt=1",
                "vpn.store_recovered attempts=1",
            ])
            check("the flap started and recovered once", count("vpn.flap.start", in: events) == 1
                  && count("vpn.flap.recovered", in: events) == 1)
            check("the recovery is no cold connect", count("vpn.connected", in: events) == 1)
            check("the recovery reset the paths the flap left", events.contains {
                $0.event == "dns.transports_reset" && $0.detail == "source=vpn_flap_recovered"
            })
        }
    }

    @RuntimeActor
    static func tunnelRemovedWhileStopped() async throws -> ScenarioResult {
        try await run(name: "vpn-tunnel-removed-while-stopped") { stage, check in
            check("the first reading is connected", try await stage.shows(.connected))
            check("connected installs the entry file, written once", stage.entryFile && stage.applies == 1)

            await stage.stopRuntime()
            check("the stop removes the entry file", !stage.entryFile)
            stage.store.setInterface("utun6", ipv4: nil, ipv6: nil)

            try await stage.startRuntime()
            check("the start wrote no entry file before the new session read the store", stage.applies == 1 && !stage.entryFile)
            // A session that never saw the tunnel cannot say how it went: a disconnect of unknown cause.
            check("the new session's first reading is a disconnect", try await stage.shows(.disconnected(.unknown)))
            check("no entry file was ever written for the removed tunnel", stage.applies == 1 && !stage.entryFile)
        } verify: { events, check in
            check("a healthy store reports nothing", storeEvents(events).isEmpty)
        }
    }

    private static func storeEvents(_ events: [RuntimeEvent]) -> [String] {
        let store: Set = ["vpn.store_failed", "vpn.store_recovered", "vpn.store_key_malformed", "vpn.store_unsubscribe_failed",
                          "vpn.store_released_uncancelled"]
        return events.filter { store.contains($0.event) }.map { "\($0.event) \($0.detail ?? "")" }
    }

    private static func count(_ name: String, in events: [RuntimeEvent]) -> Int {
        events.filter { $0.event == name }.count
    }

    // MARK: - Harness

    /// One started host, its monitor's store and clock, and the machine it writes to.
    @RuntimeActor
    final class Stage {
        let control: any RuntimeClient
        let store: FakeTunnelStore
        let clock: FakeStoreObserverClock
        private let host: RuntimeHost
        private let eventsFile: URL
        private let machine: FakeMachine
        private let queue: DispatchQueue

        fileprivate init(
            control: any RuntimeClient, store: FakeTunnelStore, clock: FakeStoreObserverClock, host: RuntimeHost,
            eventsFile: URL, machine: FakeMachine, queue: DispatchQueue
        ) {
            self.control = control
            self.store = store
            self.clock = clock
            self.host = host
            self.eventsFile = eventsFile
            self.machine = machine
            self.queue = queue
        }

        var entryFile: Bool { machine.resolverFile(for: "corp.example") != nil }

        var applies: Int { machine.privilege.commands(matching: .applyDNS).count }

        func snapshot() async throws -> ControlRuntimeSnapshot {
            try await control.readSnapshot(deadline: .after(.seconds(30), from: ContinuousClock.now))
        }

        /// Whether the host comes to show `state`, within ten seconds. The host writes or removes the entry files before
        /// the orchestrator takes the report, so they are settled once it shows.
        func shows(_ state: ControlVPNState) async throws -> Bool {
            for _ in 0..<1000 {
                if try await snapshot().vpnState == state { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        /// Whether the host's events file comes to hold `count` events named `name`, within ten seconds. The host publishes a
        /// VPN state before the probe its reaction awaits, and reports the reaction after it, so a scenario that saw the state
        /// waits here before it checks what the reaction counted or stops the host.
        func reported(_ name: String, count: Int) async throws -> Bool {
            for _ in 0..<1000 {
                let flush = await host.flushEvents()
                guard flush.allConfirmed else { throw ScenarioExecutionError(message: "events flush unconfirmed: \(flush)") }
                let events = try String(contentsOf: eventsFile, encoding: .utf8).split(separator: "\n").map {
                    try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
                }
                if events.filter({ $0.event == name }).count >= count { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }

        /// The wake-up the monitor holds once one that `matching` accepts is pending, within ten seconds.
        func wake(matching: (FakeStoreObserverClock.Sleep) -> Bool = { _ in true }) async throws -> FakeStoreObserverClock.Sleep? {
            for _ in 0..<1000 {
                if let sleep = clock.pendingSleep, matching(sleep) { return sleep }
                try await Task.sleep(for: .milliseconds(10))
            }
            return nil
        }

        func stopRuntime() async {
            await host.stopRuntime()
        }

        func startRuntime() async throws {
            try await host.startRuntime()
        }

        /// Runs what the monitor's queue holds, so a reading it was prompted for has been delivered.
        func settleMonitor() {
            queue.sync {}
        }
    }

    @RuntimeActor
    private static func run(
        name: String,
        _ body: @RuntimeActor (Stage, (String, Bool) -> Void) async throws -> Void,
        verify: ([RuntimeEvent], (String, Bool) -> Void) -> Void
    ) async throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        var notes: [String] = []

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
        config.dnsForwarderEnabled = false
        config.upstreams = [upstream.proxy]
        config.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.53"])]
        try ProxyConfigPersistence.save(config, in: environment)
        try PlatformConfigPersistence.save(PlatformIntegrationConfig(manageDNSResolvers: true), in: environment)

        let machine = FakeMachine(resolverDirectory: scratch.appendingPathComponent("resolver", isDirectory: true))
        let store = FakeTunnelStore()
        store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
        let clock = FakeStoreObserverClock()
        let queue = DispatchQueue(label: "pm-sim.\(name)")
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
                vpnStatusMonitor: { grace, minVisible in
                    VPNStatusMonitor(
                        graceSecondsProvider: grace, minVisibleSecondsProvider: minVisible,
                        store: store, clock: clock.clock, queue: queue
                    )
                },
                pushedResolvers: FakePushedResolverObserver(),
                wake: FakeSystemWakeObserver(),
                homeDirectory: home,
                resolverDirectory: machine.resolverDirectory.path,
                stateFiles: StateFileAccess.operatingSystem()
            )
        )

        do {
            try await host.startRuntime()
            let clients = try host.makeInMemoryControlClient(
                limits: try SplitDNSFollowsVPNScenarios.controlLimits(), clientFrameLimits: try ControlFrameLimits(maxFrameBytes: 64 * 1024), wireBudgetCap: .seconds(30)
            )
            try await body(Stage(control: clients.control, store: store, clock: clock, host: host,
                                 eventsFile: environment.eventsFile, machine: machine, queue: queue), check)
        } catch {
            notes.append("failed: \(error)")
            check("the scenario ran to its end", false)
        }

        await host.stopRuntime()
        var leftWake = true
        for _ in 0..<1000 {
            leftWake = clock.pendingSleep != nil
            if !leftWake { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        check("the stop leaves no wake-up", !leftWake && clock.overlappingSleeps == 0)
        check("the stop removes the entry file", machine.resolverFile(for: "corp.example") == nil)
        let settled = await host.settleStoppedEffects(until: ContinuousClock.now.advanced(by: .seconds(5)))
        let flush = await host.flushEvents()
        check("the host settles and flushes", settled == .settled && flush.allConfirmed)
        notes.append("the owned upstream accepted \(upstream.accepted) connections")
        do {
            let events = try String(contentsOf: environment.eventsFile, encoding: .utf8).split(separator: "\n").map {
                try CanonicalJSON.decoder().decode(RuntimeEvent.self, from: Data($0.utf8))
            }
            verify(events, check)
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
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }
}
