// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// The repair policy over a scratch home and `FakeMachine`'s launchd
/// domain (#175).
final class EnvironmentDriftRepairTests: XCTestCase {
    private var home: URL!
    private var machine: FakeMachine!
    private var manager: EnvironmentManager!
    private var events: EventBox!
    private var clock: TestClock!
    private var repair: EnvironmentDriftRepair!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("env-drift-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        machine = FakeMachine(resolverDirectory: home.appendingPathComponent("resolver", isDirectory: true))
        events = EventBox()
        let machine = self.machine!
        let events = self.events!
        manager = EnvironmentManager(journal: PlatformStateJournal(fileURL: home.appendingPathComponent("platform-state.json")),
                                     homeDirectory: home, commandRunner: { try machine.run($0, $1) },
                                     eventSink: { events.append($0) })
        clock = TestClock()
        let clock = self.clock!
        repair = EnvironmentDriftRepair(manager: manager, eventSink: { events.append($0) }, logger: nil,
                                        limits: .init(maximumRepairs: 2, window: .seconds(600)), now: { clock.now })
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        super.tearDown()
    }

    private var config: ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        config.noProxyHosts = ["localhost", "*.internal"]
        return config
    }

    private var zshrc: URL { home.appendingPathComponent(".zshrc") }

    private func wipe() throws {
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        _ = try machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])
    }

    func testNothingDriftedIsQuiet() throws {
        try manager.apply(config: config, logger: nil)
        XCTAssertNil(repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true }))
        XCTAssertEqual(events.names.filter { $0.hasPrefix("platform.environment_") }, [])
    }

    /// The verdict a failed re-apply's retry reads (#194): settled only
    /// when the surface holds what the config asks.
    func testAPassSaysWhetherTheSurfaceSettled() throws {
        try manager.apply(config: config, logger: nil)
        func pass(_ trigger: EnvironmentDriftRepair.Trigger) -> EnvironmentDriftRepair.PassOutcome {
            repair.pass(config: config, generation: manager.generation, trigger: trigger, isCurrent: { true })
        }
        XCTAssertEqual(pass(.retry), .init(retry: nil, settled: true, reason: nil), "clean")

        try wipe()
        machine.failingSetenv = ["HTTP_PROXY"]
        XCTAssertEqual(pass(.retry), .init(retry: nil, settled: false, reason: "partial profiles_left= launchd_left=HTTP_PROXY"),
                       "a variable still not published, named as the apply's shortfall names it")
        XCTAssertEqual(pass(.observed), .init(retry: nil, settled: false, reason: "backing_off"),
                       "after a failure, a notification waits for the tick or a retry")
        XCTAssertEqual(pass(.retry).reason, "partial profiles_left= launchd_left=HTTP_PROXY")
        let withheld = pass(.retry)
        XCTAssertEqual(withheld.reason, "repair_withheld", "two attempts spent the budget")
        XCTAssertNotNil(withheld.retry)
        XCTAssertFalse(withheld.settled)

        machine.failingSetenv = []
        clock.advance(.seconds(600))
        XCTAssertEqual(pass(.retry), .init(retry: nil, settled: true, reason: nil), "repaired once the window reopens")
        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3128")
    }

    func testAPassOvertakenByAClearIsNotSettled() throws {
        try manager.apply(config: config, logger: nil)
        try wipe()
        let generation = manager.generation
        try manager.clear(logger: nil)
        XCTAssertEqual(repair.pass(config: config, generation: generation, trigger: .retry, isCurrent: { true }).reason, "superseded")
    }

    /// `apply` reports what it left instead of throwing; `shortfall` is how
    /// a caller that only catches stops reading that as success (#194).
    func testAnApplyResultNamesWhatItLeft() throws {
        XCTAssertNil(try manager.apply(config: config, logger: nil).shortfall)
        machine.failingSetenv = ["HTTP_PROXY", "NO_PROXY"]
        var changed = config
        changed.localPort = 3129
        changed.noProxyHosts.append("bypass.example")
        XCTAssertEqual(try manager.apply(config: changed, logger: nil).shortfall,
                       "partial profiles_left= launchd_left=HTTP_PROXY,NO_PROXY")
    }

    func testAWipeIsReportedAndRepaired() throws {
        try manager.apply(config: config, logger: nil)
        try wipe()

        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })

        XCTAssertEqual(events.names, ["platform.environment_drift", "platform.environment_repaired"])
        XCTAssertEqual(events.details.first, "trigger=timer profiles=.zshrc:missing launchd=HTTP_PROXY")
        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3128")
        let text = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("export A=1\n") && text.contains("# >>> Conduit >>>"))
        XCTAssertTrue(manager.inspect(config: config).isClean)
    }

    /// A program that keeps stripping the block gets `maximumRepairs`
    /// repairs per window, one withheld event, and a retry when it reopens.
    func testRepairsPastTheBudgetAreWithheldOnce() throws {
        try manager.apply(config: config, logger: nil)
        for _ in 0..<2 {
            try wipe()
            XCTAssertNil(repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true }))
            clock.advance(.seconds(60))
        }
        try wipe()
        let retry = repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        XCTAssertEqual(retry, .seconds(480), "the first repair, at 0 s, leaves the 600 s window at 120 s + 480 s")
        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"], "withheld")
        XCTAssertNotNil(repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true }))
        XCTAssertEqual(events.names.filter { $0 == "platform.environment_repair_withheld" }.count, 1, "once per episode")
        XCTAssertEqual(events.names.filter { $0 == "platform.environment_drift" }.count, 3,
                       "two repairs and the first withheld pass; the repeat stays quiet")

        clock.advance(.seconds(481))
        XCTAssertNil(repair.run(config: config, generation: manager.generation, trigger: .retry, isCurrent: { true }))
        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3128")
    }

    func testAnUnsafeProfileIsReportedOnceAndTheRestIsRepaired() throws {
        try manager.apply(config: config, logger: nil)
        try Data([0xff]).write(to: zshrc)
        _ = try machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])

        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })

        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3128", "the variable is repaired")
        XCTAssertEqual(try Data(contentsOf: zshrc), Data([0xff]), "the unsafe profile is not")
        XCTAssertFalse(events.names.contains("platform.environment_repaired"), "so the surface is not repaired")
        XCTAssertEqual(events.names.filter { $0 == "platform.environment_repair_failed" }.count, 1)
        XCTAssertTrue(events.details.contains { $0.hasPrefix("reason=partial") && $0.contains("profiles_left=.zshrc") })
        XCTAssertEqual(events.names.filter { $0 == "platform.environment_file_skipped" }.count, 1)
    }

    /// The host read config A and the generation, then queued the pass; B's
    /// apply landed first. The pass must not put A back.
    func testAPassQueuedBeforeANewerApplyWritesNothing() throws {
        try manager.apply(config: config, logger: nil)
        let generation = manager.generation
        var newer = config
        newer.localPort = 3129
        try manager.apply(config: newer, logger: nil)

        repair.run(config: config, generation: generation, trigger: .observed, isCurrent: { true })

        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3129")
        XCTAssertEqual(events.names, ["platform.environment_drift", "platform.environment_repair_superseded"])
    }

    /// An apply that throws after writing a profile is still an attempt.
    func testAnAttemptThatThrowsCountsAgainstTheBudget() throws {
        try manager.apply(config: config, logger: nil)
        // environment.d cannot be created under a regular file.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config"))
        try Data().write(to: home.appendingPathComponent(".config"))
        for _ in 0..<2 {
            try wipe()
            XCTAssertNil(repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true }))
        }
        try wipe()
        XCTAssertNotNil(repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true }),
                        "withheld after two attempts that threw")
        XCTAssertEqual(events.names.filter { $0 == "platform.environment_repair_withheld" }.count, 1)
    }

    /// The budget belongs to an episode: an apply from anything else (a
    /// config change, a restart) starts a new one.
    func testAnApplyFromElsewhereStartsANewEpisode() throws {
        try manager.apply(config: config, logger: nil)
        for _ in 0..<2 {
            try wipe()
            repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        }
        try wipe()
        XCTAssertNotNil(repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true }))

        var changed = config
        changed.localPort = 3129
        try manager.apply(config: changed, logger: nil)
        try wipe()
        XCTAssertNil(repair.run(config: changed, generation: manager.generation, trigger: .observed, isCurrent: { true }))
        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3129", "repaired in the new episode")
    }

    /// After a failed attempt, notifications wait for the tick: a failure
    /// that writes nothing must not spend the budget on one burst.
    func testAfterAFailedAttemptNotificationsWaitForTheTick() throws {
        try manager.apply(config: config, logger: nil)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config"))
        try Data().write(to: home.appendingPathComponent(".config"))
        try wipe()
        repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        let afterFailure = events.names.count
        repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        XCTAssertEqual(events.names.count, afterFailure, "no reads, no attempts, no events until the tick")

        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })
        XCTAssertGreaterThan(events.names.count, afterFailure, "the tick tries again")
    }

    /// A profile left alone is reported once, however many passes look.
    func testAnUnsafeOnlyStateIsReportedOnceAcrossPasses() throws {
        try manager.apply(config: config, logger: nil)
        try Data([0xff]).write(to: zshrc)
        for _ in 0..<3 {
            repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })
        }
        XCTAssertEqual(events.names.filter { $0 == "platform.environment_repair_failed" }.count, 1)
    }

    /// A profile that turns unsafe between the inspection and the write is
    /// left alone, so the pass is not a repair.
    func testAProfileTurningUnsafeMidPassIsNotARepair() throws {
        try manager.apply(config: config, logger: nil)
        _ = try machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])
        let zshrc = self.zshrc
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: {
            try? Data([0xff]).write(to: zshrc)
            return true
        })
        XCTAssertFalse(events.names.contains("platform.environment_repaired"))
        XCTAssertTrue(events.details.contains { $0.hasPrefix("reason=partial") && $0.contains("profiles_left=.zshrc") })
    }

    /// A host coalesces passes; the one it keeps must carry a tick's right
    /// to attempt after a failure, and never hand it to a notification.
    func testACoalescedPassKeepsTheStrongerTrigger() {
        typealias Trigger = EnvironmentDriftRepair.Trigger
        XCTAssertEqual(Trigger.observed.coalesced(with: nil), .observed)
        XCTAssertEqual(Trigger.observed.coalesced(with: .timer), .timer, "a notification does not take the tick's place")
        XCTAssertEqual(Trigger.timer.coalesced(with: .observed), .timer)
        XCTAssertEqual(Trigger.retry.coalesced(with: .observed), .retry)
    }

    /// A clean inspection ends the backoff: the next wipe is repaired on its
    /// notification, not left for the tick.
    func testACleanTickEndsTheBackoff() throws {
        try manager.apply(config: config, logger: nil)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config"))
        try Data().write(to: home.appendingPathComponent(".config"))
        try wipe()
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })

        // Recovered from outside: the obstruction is gone and a host applied.
        try FileManager.default.removeItem(at: home.appendingPathComponent(".config"))
        let generation = manager.generation
        _ = try manager.repair(config: config, ifGeneration: generation, isCurrent: { true }, logger: nil)
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { true })

        try wipe()
        repair.run(config: config, generation: manager.generation, trigger: .observed, isCurrent: { true })
        XCTAssertEqual(machine.launchdEnvironment["HTTP_PROXY"], "http://127.0.0.1:3128", "repaired on the notification")
    }

    /// A variable that drifted after the inspection and then failed to
    /// publish keeps the pass from counting as a repair.
    func testAVariableFailingAfterTheInspectionIsNotARepair() throws {
        let machine = self.machine!
        let failSet = SetenvFailure()
        let events = self.events!
        let manager = EnvironmentManager(
            journal: PlatformStateJournal(fileURL: home.appendingPathComponent("other-state.json")), homeDirectory: home,
            commandRunner: { path, arguments in
                if failSet.on, arguments.first == "setenv", arguments.dropFirst().first == "HTTP_PROXY" {
                    return CommandResult(exitCode: 1, standardOutput: "", standardError: "refused")
                }
                return try machine.run(path, arguments)
            })
        let repair = EnvironmentDriftRepair(manager: manager, eventSink: { events.append($0) }, logger: nil)
        try manager.apply(config: config, logger: nil)
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)   // profile-only drift

        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: {
            _ = try? machine.run("/bin/launchctl", ["unsetenv", "HTTP_PROXY"])
            failSet.on = true
            return true
        })

        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertFalse(events.names.contains("platform.environment_repaired"))
        XCTAssertTrue(events.details.contains { $0.hasPrefix("reason=partial") && $0.contains("launchd_left=HTTP_PROXY") })
    }

    func testAPassOvertakenByTheLifecycleWritesNothing() throws {
        try manager.apply(config: config, logger: nil)
        try wipe()
        repair.run(config: config, generation: manager.generation, trigger: .timer, isCurrent: { false })
        XCTAssertNil(machine.launchdEnvironment["HTTP_PROXY"])
        XCTAssertEqual(events.names, ["platform.environment_drift", "platform.environment_repair_superseded"])
    }
}

private final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []
    func append(_ event: RuntimeEvent) { lock.withLock { events.append(event) } }
    var names: [String] { lock.withLock { events.map(\.event) } }
    var details: [String] { lock.withLock { events.compactMap(\.detail) } }
}

private final class SetenvFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var on: Bool {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

private final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var instant = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { instant } }
    func advance(_ duration: Duration) { lock.withLock { instant += duration } }
}
