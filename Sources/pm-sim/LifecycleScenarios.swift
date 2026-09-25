// SPDX-License-Identifier: Apache-2.0
import Foundation
import PlatformMac
import ProxyKernel

/// Issue #47. The hosts apply and clear the machine's proxy settings on a
/// serial `PlatformWork` queue, ordered by a `LifecycleLane`. This drives the
/// same three pieces the hosts compose — the queue, the lane and a real
/// `SystemProxyManager` over `FakeMachine` — the way `startProxy` and
/// `stopProxy` compose them, with the start's platform step held on a gate:
///
/// - a stop issued while the start's apply is out queues its clear behind it,
///   so the machine ends cleared, and the start, overtaken, does nothing more
///   and says so with one `lifecycle.superseded`;
/// - stops issued while a stop is held join it instead of queueing teardowns.
///
/// The hosts themselves are executables and cannot be linked here; their
/// harness scenarios (`AppStateHarnessTests`, `DaemonRuntimeHostTests`) cover
/// the composition end to end.
enum LifecycleScenarios {

    /// Holds the first `networksetup` service listing made on the platform
    /// queue until `release()`, and tells the scenario when it arrived.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var armed = false
        private var reached = false
        private var waiter: CheckedContinuation<Void, Never>?
        private let gate = DispatchSemaphore(value: 0)

        func arm() { lock.withLock { armed = true; reached = false } }
        func release() { gate.signal() }

        func pass(_ arguments: [String]) {
            let resume: CheckedContinuation<Void, Never>?? = lock.withLock {
                guard armed, arguments.first == "-listallnetworkservices" else { return nil }
                armed = false
                reached = true
                defer { waiter = nil }
                return .some(waiter)
            }
            guard let resume else { return }
            resume?.resume()
            gate.wait()
        }

        func waitUntilReached() async {
            await withCheckedContinuation { continuation in
                let already = lock.withLock { () -> Bool in
                    if reached { return true }
                    waiter = continuation
                    return false
                }
                if already { continuation.resume() }
            }
        }
    }

    /// Errors a manager step threw, collected off the queue.
    private final class Failures: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        var all: [String] { lock.withLock { stored } }
        func record(_ error: Error) { lock.withLock { stored.append(error.localizedDescription) } }
    }

    /// `AppState.startProxy` / `stopProxy`, reduced to the platform step.
    @MainActor
    private final class Host {
        let lane = LifecycleLane(name: "proxy")
        let work = PlatformWork(label: "io.github.srps.Conduit.pm-sim.platform-work")
        let events = RuntimeEventLog(capacity: 64)
        let manager: SystemProxyManager
        let config: ProxyConfig
        let failures = Failures()
        private(set) var startFollowUps = 0

        init(manager: SystemProxyManager, config: ProxyConfig) {
            self.manager = manager
            self.config = config
        }

        func start() async {
            guard let token = await admit(.start, "proxy_start") else { return }
            defer { lane.end(token) }
            let manager = self.manager, config = self.config, failures = self.failures
            await work.run {
                manager.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try manager.apply(config: config, mode: .manual, logger: nil)
                    } catch {
                        failures.record(error)
                    }
                }
            }
            guard !token.isSuperseded else {
                events.append(lane.supersededEvent(operation: "proxy_start", token: token))
                return
            }
            // What a start does next: the forwarder, the save, the notice.
            startFollowUps += 1
        }

        func stop() async {
            guard let token = await admit(.stop, "proxy_stop") else { return }
            defer { lane.end(token) }
            let manager = self.manager, failures = self.failures
            await work.run {
                manager.serialized {
                    guard !token.isSuperseded else { return }
                    do {
                        try manager.clear(logger: nil)
                    } catch {
                        failures.record(error)
                    }
                }
            }
            if token.isSuperseded {
                events.append(lane.supersededEvent(operation: "proxy_stop", token: token))
            }
        }

        private func admit(_ kind: LifecycleLane.Kind, _ operation: String) async -> LifecycleLane.Token? {
            switch lane.begin(kind) {
            case .run(let token):
                return token
            case .coalesced(let generation):
                events.append(lane.coalescedEvent(operation: operation, joining: generation))
                await lane.join(generation)
                return nil
            }
        }

        func count(_ event: String) -> Int {
            events.events.filter { $0.event == event }.count
        }
    }

    /// Bounded: the scenario watchdog is the backstop, this is the budget.
    @MainActor
    private static func yield(until condition: () -> Bool) async -> Bool {
        for _ in 0..<100_000 where !condition() {
            await Task.yield()
        }
        return condition()
    }

    @MainActor
    static func stopOvertakesStart() async throws -> ScenarioResult {
        let name = "lifecycle-stop-overtakes-start"
        let began = Date()
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("pm-sim-lifecycle-\(UUID().uuidString)", isDirectory: true)
        ScenarioCleanup.register {
            do {
                try FileManager.default.removeItem(at: directory)
            } catch {
                ConsoleLogSink().log(.warning, "pm-sim could not remove \(directory.path): \(error.localizedDescription)", category: .general)
            }
        }
        let machine = FakeMachine(resolverDirectory: directory.appendingPathComponent("resolver", isDirectory: true))
        let journal = PlatformStateJournal(fileURL: directory.appendingPathComponent("platform-state.json"))
        let gate = Gate()
        let manager = SystemProxyManager(
            privilegeClient: machine,
            journal: journal,
            commandRunner: { launchPath, arguments in
                gate.pass(arguments)
                return try machine.run(launchPath, arguments)
            },
            portProbe: { _ in false }
        )
        var config = GenericDefaults.shared.makeConfig()
        config.localPort = 3128
        let host = Host(manager: manager, config: config)
        var notes: [String] = []

        // 1. A stop overtakes a start whose apply is out.
        gate.arm()
        let start = Task { await host.start() }
        await gate.waitUntilReached()
        let stop = Task { await host.stop() }
        let stopBegan = await yield { host.lane.current == 2 }
        gate.release()
        await start.value
        await stop.value
        let clearedAfterOvertake = !machine.service("Wi-Fi").routesThroughAProxy && journal.knowsSurfaceIsIdle(.systemProxy)
        let oneSuperseded = host.events.events.filter { $0.event == "lifecycle.superseded" }.map(\.detail)
            == ["operation=proxy_start generation=1 current=2 reason=superseded"]
        let followUpsAfterOvertake = host.startFollowUps
        notes.append("overtake: stopBegan=\(stopBegan) routed=\(machine.service("Wi-Fi").routesThroughAProxy) followUps=\(followUpsAfterOvertake)")

        // 2. Stops while a stop is held join it.
        await host.start()
        let appliedAgain = machine.service("Wi-Fi").routesThroughAProxy
        gate.arm()
        let firstStop = Task { await host.stop() }
        await gate.waitUntilReached()
        let repeats = (0..<3).map { _ in Task { await host.stop() } }
        let repeatsArrived = await yield { host.count("lifecycle.coalesced") == 3 || host.lane.current > 4 }
        gate.release()
        await firstStop.value
        for task in repeats { await task.value }
        notes.append("coalesce: generations=\(host.lane.current) coalesced=\(host.count("lifecycle.coalesced")) arrived=\(repeatsArrived)")
        notes.append(contentsOf: host.failures.all.map { "manager step threw: \($0)" })

        return ScenarioResult(
            name: name, clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("the stop began while the start's apply was held", stopBegan),
                .init("the stop's clear landed after the start's apply: machine cleared, journal released", clearedAfterOvertake),
                .init("the overtaken start recorded one lifecycle.superseded and did nothing more", oneSuperseded && followUpsAfterOvertake == 0),
                .init("a later start applied again", appliedAgain),
                .init("three stops during a held stop joined it: one teardown", host.lane.current == 4 && host.count("lifecycle.coalesced") == 3),
                .init("and the machine ended cleared", !machine.service("Wi-Fi").routesThroughAProxy && journal.knowsSurfaceIsIdle(.systemProxy)),
                .init("no manager step threw", host.failures.all.isEmpty),
            ],
            notes: notes
        )
    }
}
