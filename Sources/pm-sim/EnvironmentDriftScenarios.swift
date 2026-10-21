// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import PlatformMac
import ProxyKernel

/// #175 over `FakeMachine` and a scratch home: a silent wipe of the shell
/// environment surface is found and repaired with its events; a program
/// that keeps wiping it is withheld after the budget; an unsafe profile is
/// left alone and reported once; a repair overtaken by a clear writes
/// nothing; and with the journal unwritable, a teardown leaves a local
/// proxy and bypass list it never wrote alone.
enum EnvironmentDriftScenarios {
    static func run() throws -> ScenarioResult {
        let began = Date()
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("pm-env-drift-\(UUID())")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        defer {
            do { try FileManager.default.removeItem(at: home) }
            catch { fputs("environment-drift home cleanup failed: \(error.localizedDescription)\n", stderr) }
        }
        let machine = FakeMachine(resolverDirectory: home.appendingPathComponent("resolver"))
        let events = NIOLockedValueBox<[RuntimeEvent]>([])
        let sink: @Sendable (RuntimeEvent) -> Void = { event in events.withLockedValue { $0.append(event) } }
        let manager = EnvironmentManager(journal: PlatformStateJournal(fileURL: home.appendingPathComponent("platform-state.json")),
                                         homeDirectory: home, commandRunner: machine.run, eventSink: sink)
        let instant = NIOLockedValueBox(ContinuousClock.now)
        let repair = EnvironmentDriftRepair(manager: manager, eventSink: sink, logger: nil,
                                            limits: .init(maximumRepairs: 2, window: .seconds(600)),
                                            now: { instant.withLockedValue { $0 } })
        var config = GenericDefaults.shared.makeConfig()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        let zshrc = home.appendingPathComponent(".zshrc")
        func names() -> [String] { events.withLockedValue { $0.map(\.event) } }
        func count(_ name: String) -> Int { names().filter { $0 == name }.count }
        func wipe() throws {
            try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
            _ = try machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])
        }

        // Phase 1: applied, wiped behind Conduit's back, repaired.
        try manager.apply(config: config, logger: nil)
        try wipe()
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })
        let repaired = count("platform.environment_drift") == 1 && count("platform.environment_repaired") == 1
            && machine.launchdEnvironment["HTTP_PROXY"] == "http://127.0.0.1:3128"
            && manager.inspect(config: config).isClean
        let userTextKept = (try String(contentsOf: zshrc, encoding: .utf8)).hasPrefix("export A=1\n")

        // Phase 2: a program that keeps wiping it. The budget allows two
        // repairs in the window; the third is withheld once, with a retry.
        instant.withLockedValue { $0 += .seconds(60) }
        try wipe()
        repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        instant.withLockedValue { $0 += .seconds(60) }
        try wipe()
        let retry = repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        let withheld = retry != nil && count("platform.environment_repair_withheld") == 1
            && count("platform.environment_drift") == 3
            && machine.launchdEnvironment["HTTP_PROXY"] == nil
        instant.withLockedValue { $0 += .seconds(600) }
        repair.run(config: config, generation: manager.generation, trigger: .retry, isCurrent: { true })
        let reopened = machine.launchdEnvironment["HTTP_PROXY"] == "http://127.0.0.1:3128"

        // Phase 3: a profile that is not UTF-8 is left alone, reported once.
        let foreign = Data([0x65, 0xff, 0x0a])
        try foreign.write(to: zshrc)
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })
        // Nothing else drifted, so no repair runs: the pass itself reports
        // the profile it cannot edit, once.
        let unsafeLeftAlone = (try Data(contentsOf: zshrc)) == foreign
            && events.withLockedValue { $0.filter { $0.event == "platform.environment_repair_failed" } }
                .map { $0.detail ?? "" } == ["reason=unsafe_file unsafe=.zshrc:not_utf8"]

        // Phase 4: a clear (switch off, stop, quit) overtakes a pass that
        // already read the state: the repair writes nothing.
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        repair.reset()
        let generation = manager.generation
        try manager.clear(logger: nil)
        let superseded = try manager.repair(config: config, ifGeneration: generation, isCurrent: { true }, logger: nil) == nil
            && machine.launchdEnvironment["HTTP_PROXY"] == nil
            && !(try String(contentsOf: zshrc, encoding: .utf8)).contains("Conduit")

        // Phase 5: the journal cannot be written, so every launchd write is
        // withheld. Someone else's local proxy and bypass list survive a stop.
        let lockedState = home.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedState, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: lockedState.path)
        defer {
            do { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedState.path) }
            catch { fputs("environment-drift permission reset failed: \(error.localizedDescription)\n", stderr) }
        }
        let other = FakeMachine(resolverDirectory: home.appendingPathComponent("resolver-other"))
        let theirs = ["HTTP_PROXY": "http://127.0.0.1:9999", "NO_PROXY": "user.example", "no_proxy": "user.example"]
        for (name, value) in theirs { _ = try other.run("/bin/launchctl", ["setenv", name, value]) }
        let withheldManager = EnvironmentManager(journal: PlatformStateJournal(fileURL: lockedState.appendingPathComponent("platform-state.json")),
                                                 homeDirectory: home, commandRunner: other.run)
        let withheldApply = try withheldManager.apply(config: config, logger: nil)
        try withheldManager.clear(logger: nil)
        let foreignKept = withheldApply.launchd.written.isEmpty && other.launchdEnvironment == theirs

        return ScenarioResult(
            name: "environment-drift", clientCount: 0, clientsOpened: 0, clientsWithFirstByte: 0,
            clientsClosedEarly: 0, totalBytes: 0, durationSeconds: Date().timeIntervalSince(began),
            aggregateMBps: 0, minBytes: 0, maxBytes: 0, medianBytes: 0, earliestClose: nil, latestClose: nil,
            assertions: [
                .init("a silent wipe is found and repaired, with drift and repaired events", repaired),
                .init("the user's own profile text survives the repair", userTextKept),
                .init("repairs past the budget are withheld once, with a retry", withheld),
                .init("the retry repairs once the window reopens", reopened),
                .init("a non-UTF-8 profile is left alone and reported once", unsafeLeftAlone),
                .init("a repair overtaken by a clear writes nothing", superseded),
                .init("with every write withheld, a stop leaves a foreign local proxy and bypass list alone", foreignKept),
            ],
            notes: ["events=\(names().joined(separator: ","))"]
        )
    }
}
