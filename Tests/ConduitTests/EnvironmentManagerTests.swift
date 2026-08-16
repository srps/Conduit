// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// First coverage for `EnvironmentManager`, which edits the user's shell
/// profiles and their per-user launchd domain. Both are real, visible side
/// effects outside any sandbox, so these tests drive an isolated home directory
/// and a fake `launchctl` — running them against the real ones would rewrite the
/// developer's dotfiles and environment.
final class EnvironmentManagerTests: XCTestCase {

    private var home: URL!
    private var journal: PlatformStateJournal!
    private var launchctl: FakeLaunchctl!

    override func setUpWithError() throws {
        try super.setUpWithError()
        home = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("env-manager-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        journal = PlatformStateJournal(fileURL: home.appendingPathComponent("platform-state.json"))
        launchctl = FakeLaunchctl()
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: home)
        home = nil
        journal = nil
        launchctl = nil
        super.tearDown()
    }

    private func makeManager() -> EnvironmentManager {
        EnvironmentManager(journal: journal, homeDirectory: home, commandRunner: launchctl.run)
    }

    private func makeConfig() -> ProxyConfig {
        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128
        config.noProxyHosts = ["localhost", "*.internal"]
        return config
    }

    // MARK: - launchd prior state

    /// A developer who already exports `HTTP_PROXY` into their launchd domain
    /// must get it back. Teardown used to `unsetenv` every variable it knew
    /// about, with no record that any of them had a value beforehand.
    func testTeardownRestoresAPreExistingLaunchdValue() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"

        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://127.0.0.1:3128")

        try manager.clear(logger: nil)

        XCTAssertEqual(
            launchctl.environment["HTTP_PROXY"],
            "http://corp.example:8080",
            "a value that predated us must survive our teardown"
        )
    }

    /// Variables we introduced are removed, not left pointing at a proxy that
    /// is no longer listening — every GUI app launched afterwards would inherit
    /// a dead proxy.
    func testTeardownUnsetsVariablesThatDidNotExistBefore() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.clear(logger: nil)

        XCTAssertNil(launchctl.environment["HTTP_PROXY"])
        XCTAssertNil(launchctl.environment["NO_PROXY"])
    }

    /// Without a journal the class must behave exactly as it used to rather
    /// than refuse to clean up: an unknown prior is still cleared.
    func testTeardownWithoutAJournalStillUnsets() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"
        let manager = EnvironmentManager(homeDirectory: home, commandRunner: launchctl.run)

        try manager.apply(config: makeConfig(), logger: nil)
        try manager.clear(logger: nil)

        XCTAssertNil(launchctl.environment["HTTP_PROXY"], "unknown prior falls back to clearing, never to leaving ours")
    }

    /// Apply runs repeatedly per session; after the first, launchctl reports our
    /// own proxy URL. Recording that would make teardown "restore" our value.
    func testRepeatedApplyKeepsTheOriginalLaunchdPrior() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"

        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.clear(logger: nil)

        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080")
    }

    /// The same double-teardown trap as the system proxy. `clear` restores the
    /// pre-existing value and forgets the record; a second `clear` finding no
    /// record would `unsetenv` the value it just gave back. Both hosts clear on
    /// stop and again on quit.
    func testSecondTeardownDoesNotUnsetWhatTheFirstOneRestored() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"

        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.clear(logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080")

        try manager.clear(logger: nil)

        XCTAssertEqual(
            launchctl.environment["HTTP_PROXY"],
            "http://corp.example:8080",
            "quitting after a stop must not undo the restore the stop performed"
        )
    }

    /// A transient `launchctl` failure must not cost the user their record.
    /// Forgetting on a partial restore destroys the only copy of their original
    /// values while leaving some of ours in place, with no way to retry.
    func testRecordsSurviveAFailedLaunchctlRestore() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"

        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)

        launchctl.failSetenv = true
        try manager.clear(logger: nil)

        XCTAssertEqual(
            journal.prior(surface: .launchdEnvironment, scope: "HTTP_PROXY"),
            .wasPresent(["value": "http://corp.example:8080"]),
            "a failed restore keeps the record so the next teardown can retry"
        )

        // And the retry works once launchctl recovers.
        launchctl.failSetenv = false
        try manager.clear(logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080")
    }

    // MARK: - Shell profile block

    /// The marker block is the other ownership mechanism, and the reason it is
    /// kept rather than folded into the journal: it delimits our region inside a
    /// file we do not own, so everything around it survives untouched.
    func testProfileEditsLeaveTheRestOfTheFileAlone() throws {
        let zshrc = home.appendingPathComponent(".zshrc")
        try "export EDITOR=vim\nalias ll='ls -la'\n".write(to: zshrc, atomically: true, encoding: .utf8)

        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)

        let applied = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(applied.contains("export EDITOR=vim"))
        XCTAssertTrue(applied.contains("alias ll='ls -la'"))
        XCTAssertTrue(applied.contains("HTTP_PROXY='http://127.0.0.1:3128'"))

        try manager.clear(logger: nil)

        let cleared = try String(contentsOf: zshrc, encoding: .utf8)
        XCTAssertTrue(cleared.contains("export EDITOR=vim"), "the user's own lines must survive teardown")
        XCTAssertTrue(cleared.contains("alias ll='ls -la'"))
        XCTAssertFalse(cleared.contains("HTTP_PROXY"))
    }

    /// Re-applying must replace our block, not stack copies of it.
    func testRepeatedApplyDoesNotAccumulateBlocks() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.apply(config: makeConfig(), logger: nil)

        let contents = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        let blockCount = contents.components(separatedBy: "# >>> Conduit >>>").count - 1
        XCTAssertEqual(blockCount, 1, "each apply replaces our block rather than appending another")
    }
}

// MARK: - Fake launchctl

/// Models the per-user launchd domain as a dictionary, so `setenv`/`unsetenv`
/// are observable and `getenv` reflects them.
private final class FakeLaunchctl: @unchecked Sendable {
    var environment: [String: String] = [:]
    /// Simulates a transient launchctl failure on writes.
    var failSetenv = false
    private let lock = NSLock()

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        guard launchPath == "/bin/launchctl", let verb = arguments.first else {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
        lock.lock()
        defer { lock.unlock() }

        switch verb {
        case "setenv" where arguments.count >= 3:
            if failSetenv {
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "simulated failure")
            }
            environment[arguments[1]] = arguments[2]
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        case "unsetenv" where arguments.count >= 2:
            environment.removeValue(forKey: arguments[1])
            return CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        case "getenv" where arguments.count >= 2:
            // Real launchctl prints nothing and still exits 0 for an unset name.
            return CommandResult(exitCode: 0, standardOutput: environment[arguments[1]] ?? "", standardError: "")
        default:
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected launchctl verb")
        }
    }
}
