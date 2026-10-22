// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel

/// #194, narrow: a re-apply of the shell environment that does not throw
/// but leaves a launchd variable unpublished is reported as a failure, and
/// the retry's drift pass publishes it; a write that keeps failing is
/// retried a bounded number of times and abandoned with an event; a stop
/// after the failure abandons the retry without a write.
///
/// Drives the shared pieces both hosts use, `ConfigReapplyRetry` over a real
/// `EnvironmentManager` and `EnvironmentDriftRepair` on `FakeMachine` and a
/// scratch home, with the attempt the hosts run. The hosts are executables
/// and cannot be linked here; the system proxy, the hosts' wiring and the
/// lifecycle fences are covered by `AppStateHarnessTests` and
/// `DaemonRuntimeHostTests`.
enum ReapplyRetryScenarios {
    @MainActor
    static func run() async throws -> ScenarioResult {
        let began = Date()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pm-reapply-retry-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: home) }
            catch { fputs("reapply-retry home cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        let machine = FakeMachine(resolverDirectory: home.appendingPathComponent("resolver"))
        let platformEvents = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in platformEvents.withLockedValue { $0.append(event) } }
        let manager = EnvironmentManager(journal: PlatformStateJournal(fileURL: home.appendingPathComponent("platform-state.json")),
                                         homeDirectory: home, commandRunner: machine.run, eventSink: sink)
        let repair = EnvironmentDriftRepair(manager: manager, eventSink: sink, logger: nil)
        let lane = LifecycleLane(name: "proxy")
        var events: [RuntimeEvent] = []
        let retry = ConfigReapplyRetry(schedule: .init(delays: [.zero, .zero, .zero])) { event, _ in events.append(event) }
        var config = GenericDefaults.shared.makeConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        // What the hosts' attempt does for the environment: one drift pass
        // that may write after a failure, and its verdict.
        retry.attempt = { _, token in
            let pass = repair.pass(config: config, generation: manager.generation, trigger: .retry, isCurrent: { !token.isSuperseded })
            return pass.settled ? .applied : .failed(reason: pass.reason ?? "unsettled")
        }
        func names() -> [String] { events.map(\.event) }
        func reapply() throws {
            if let shortfall = try manager.apply(config: config, logger: nil).shortfall {
                retry.failed(.environment, cause: .configChange, reason: shortfall, token: lane.observationToken)
            }
        }

        // Phase 1: launchd refuses one variable during the re-apply, then
        // takes it again before the retry.
        try manager.apply(config: config, logger: nil)
        config.localPort = 3129
        machine.failingSetenv = ["HTTP_PROXY"]
        try reapply()
        let reported = events.first.map { $0.event == "config.reapply_failed"
            && ($0.detail ?? "").hasSuffix("reason=partial profiles_left= launchd_left=HTTP_PROXY") } ?? false
        machine.failingSetenv = []
        await retry.drain()
        let recovered = names().last == "config.reapply_recovered"
            && machine.launchdEnvironment["HTTP_PROXY"] == "http://127.0.0.1:3129"
            && manager.inspect(config: config).isClean

        // Phase 2: it keeps refusing. Three attempts, then abandoned.
        events = []
        config.localPort = 3130
        machine.failingSetenv = ["HTTP_PROXY"]
        try reapply()
        await retry.drain()
        let exhausted = names().filter { $0 == "config.reapply_retry" }.count == 3
            && events.last?.event == "config.reapply_abandoned"
            && (events.last?.detail ?? "").contains("reason=exhausted")
            && retry.pending.isEmpty

        // Phase 3: a stop after the failure owns the surface.
        events = []
        config.localPort = 3131
        try reapply()
        var stopAdmitted = false
        if case .run(let stop) = lane.begin(.stop) {
            lane.end(stop)
            stopAdmitted = true
        }
        machine.failingSetenv = []
        let before = machine.launchdEnvironment
        await retry.drain()
        let superseded = stopAdmitted && (events.last?.detail ?? "").contains("reason=superseded")
            && !names().contains("config.reapply_retry") && machine.launchdEnvironment == before

        return ScenarioResult(
            name: "reapply-retry", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a re-apply that left a variable unpublished is reported as failed, by name", reported),
                .init("the retry's drift pass publishes it and reports recovery", recovered),
                .init("a write that keeps failing is retried three times and abandoned", exhausted),
                .init("a stop after the failure abandons the retry without a write", superseded),
            ],
            notes: ["platform_events=\(platformEvents.withLockedValue { $0.map(\.event) }.joined(separator: ","))"]
        )
    }
}
