// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// The level-triggered VPN monitor (unit U3, decisions 0047 and 0048) over
/// `FakeTunnelStore` and a held clock, with its verdicts fed to the entry-file
/// policy both hosts share: `SplitDNSVPNGate` over a `DNSManager` on
/// `FakeMachine`. Time moves only when a scenario fires the one wake-up the
/// monitor holds, so the retries, deadlines and audits are counted, not
/// timed.
///
/// - `vpn-blind-gap-disconnect`: the store becomes unreadable as the tunnel
///   loses its address. While blind the verdict is `.unknown`, which
///   withholds the entry files, and none is written. The recovery reading,
///   past the flap windows measured from the last good reading, reports
///   `.disconnected(.networkLost)` at once, never `.connected` or
///   `.reasserting`.
/// - `vpn-audit-corrects-dropped-notification`: the store drops the
///   notification for a removed tunnel; the 60 s audit reads it and the entry
///   file is removed.
/// - `vpn-rapid-flap-burst`: six losses shorter than the debounce, each
///   recovered before its deadline, report nothing.
enum VPNDetectionScenarios {
    static func blindGapDisconnect() throws -> ScenarioResult {
        try run(name: "vpn-blind-gap-disconnect") { stage, check in
            stage.store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
            stage.monitor.start()
            check("the first reading is connected", stage.states(1) == [.connected])
            check("connected installs the entry file", stage.entryFile)

            stage.store.readFailure = .init(.storeRead, code: 1001)
            stage.store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
            check("an unreadable store is unknown", stage.states(2).last == .unknown)
            check("unknown withholds the entry file", !stage.entryFile)

            var delays: [TimeInterval] = []
            var installedWhileBlind = false
            for _ in 0..<3 {
                guard let sleep = stage.clock.awaitSleep() else { break }
                delays.append(sleep.seconds)
                if delays.count == 3 { stage.store.readFailure = nil }
                stage.clock.fire()
                installedWhileBlind = installedWhileBlind || stage.entryFile
            }
            check("the reads were retried after 1, 2 and 4 s", delays == [1, 2, 4])
            check("no entry file was installed while blind", !installedWhileBlind && stage.applies == 1)
            check(
                "7 s after the last good reading the loss is a disconnect at once (0047)",
                stage.states(3) == [.connected, .unknown, .disconnected(reason: .networkLost)]
            )
            check("the disconnect leaves no entry file", !stage.entryFile && stage.applies == 1)
        } verify: { events, check in
            check("the attempts 1 and 2 and the recovery were reported", events == [
                "vpn.store_failed reason=store_read code=1001 attempt=1",
                "vpn.store_failed reason=store_read code=1001 attempt=2",
                "vpn.store_recovered attempts=3",
            ])
        }
    }

    static func auditCorrectsDroppedNotification() throws -> ScenarioResult {
        try run(name: "vpn-audit-corrects-dropped-notification") { stage, check in
            stage.store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
            stage.monitor.start()
            check("the first reading is connected", stage.states(1) == [.connected])
            check("connected installs the entry file", stage.entryFile)
            check("a healthy session waits 60 s for its audit", stage.clock.awaitSleep()?.seconds == 60)

            stage.store.notifications = .dropped
            stage.store.setInterface("utun6", ipv4: nil, ipv6: nil)
            check("with the notification lost nothing is reported", stage.settled == [.connected])

            stage.clock.fire()
            check("the audit reads the removal", stage.states(2) == [.connected, .disconnected(reason: .userInitiated)])
            check("the disconnect removes the entry file", !stage.entryFile)
            check("the next audit is armed", stage.clock.awaitSleep()?.seconds == 60)
        } verify: { events, check in
            check("a healthy store reports nothing", events.isEmpty)
        }
    }

    static func rapidFlapBurst() throws -> ScenarioResult {
        try run(name: "vpn-rapid-flap-burst") { stage, check in
            stage.store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
            stage.monitor.start()
            check("the first reading is connected", stage.states(1) == [.connected])
            var debounces = 0
            for _ in 0..<6 {
                stage.store.setInterface("utun6", ipv4: nil, ipv6: ["fe80::1"])
                if stage.clock.awaitSleep(matching: { $0.seconds == 1 }) != nil { debounces += 1 }
                stage.clock.advance(by: 0.25)
                stage.store.setInterface("utun6", ipv4: ["192.0.2.10"], ipv6: ["fe80::1"])
                _ = stage.clock.awaitSleep(matching: { $0.seconds == 60 })
            }
            check("each loss armed its debounce", debounces == 6)
            check("six losses under the debounce report nothing", stage.settled == [.connected])
        } verify: { events, check in
            check("no store event", events.isEmpty)
        }
    }

    // MARK: - Harness

    final class Stage: @unchecked Sendable {
        let store = FakeTunnelStore()
        let clock = FakeStoreObserverClock()
        let monitor: VPNStatusMonitor
        private let queue = DispatchQueue(label: "pm-sim.vpn-detection")
        fileprivate let machine: FakeMachine
        private let dns: DNSManager
        private let config: ProxyConfig
        private let condition = NSCondition()
        private var delivered: [VPNObservedState] = []
        fileprivate var events: [String] = []
        private var gate = SplitDNSVPNGate()

        fileprivate init(directory: URL) {
            machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver"))
            dns = DNSManager(
                privilegeClient: machine, resolverDirectory: machine.resolverDirectory.path,
                journal: PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json"))
            )
            var entries = GenericDefaults.shared.makeConfig()
            entries.dnsEntries = [DomainDNSEntry(domain: "corp.example", servers: ["192.0.2.53"])]
            config = entries
            monitor = VPNStatusMonitor(store: store, clock: clock.clock, queue: queue)
            monitor.setOnChange { [self] state in
                condition.withLock {
                    // As the hosts do: act on a flip of what the gate wants.
                    if gate.update(state) {
                        _ = gate.reconcileEntryFiles(config: self.config, dnsManager: dns, logger: DiscardingLogSink(), runtimeStarted: true)
                    }
                    delivered.append(state)
                    condition.broadcast()
                }
            }
            monitor.setOnEvent { [self] event, _ in
                condition.withLock { events.append("\(event.event) \(event.detail ?? "")") }
            }
        }

        var entryFile: Bool { machine.resolverFile(for: "corp.example") != nil }

        var applies: Int { machine.privilege.commands(matching: .applyDNS).count }

        /// The states delivered once the monitor's queue ran what it holds.
        var settled: [VPNObservedState] {
            queue.sync {}
            return condition.withLock { delivered }
        }

        /// The states once there are at least `count`, or after five seconds.
        func states(_ count: Int) -> [VPNObservedState] {
            let limit = Date(timeIntervalSinceNow: 5)
            condition.lock()
            defer { condition.unlock() }
            while delivered.count < count, condition.wait(until: limit) {}
            return delivered
        }
    }

    private static func run(
        name: String,
        _ body: (Stage, (String, Bool) -> Void) throws -> Void,
        verify: ([String], (String, Bool) -> Void) -> Void
    ) throws -> ScenarioResult {
        let began = Date()
        var assertions: [ScenarioAssertion] = []
        func check(_ name: String, _ passed: Bool) { assertions.append(.init(name, passed)) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("pm-\(name)-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var notes: [String] = []
        do {
            let stage = Stage(directory: directory)
            try body(stage, check)
            stage.monitor.stop()
            check("a stop leaves no wake-up", stage.clock.awaitNoSleep() && stage.clock.overlappingSleeps == 0)
            verify(stage.events, check)
        }
        do { try FileManager.default.removeItem(at: directory) } catch { notes.append("scratch kept: \(error.localizedDescription)") }
        let passed = assertions.filter(\.passed).count
        return ScenarioResult(
            name: name, clientCount: assertions.count, clientsOpened: assertions.count, clientsWithFirstByte: passed,
            clientsClosedEarly: assertions.count - passed, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: assertions, notes: notes
        )
    }
}
