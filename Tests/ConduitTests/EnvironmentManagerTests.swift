// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
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

    func testUnreadableJournalWithholdsNewEnvironmentWrites() throws {
        let corrupt = Data("{broken}".utf8)
        let file = home.appendingPathComponent("platform-state.json")
        try corrupt.write(to: file)
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"
        let manager = makeManager()
        XCTAssertThrowsError(try manager.apply(config: makeConfig(), logger: nil))
        XCTAssertEqual(launchctl.environment, ["HTTP_PROXY": "http://corp.example:8080"])
        XCTAssertTrue(manager.targetFiles.allSatisfy { !FileManager.default.fileExists(atPath: $0.path) })
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }

    // MARK: - launchd prior state

    func testLocalhostExportsThePinnedLoopbackAddress() throws {
        var config = makeConfig()
        config.localHost = "localhost"
        let manager = makeManager()
        try manager.apply(config: config, logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://127.0.0.1:3128")
        XCTAssertEqual(launchctl.environment["HTTPS_PROXY"], "http://127.0.0.1:3128")
        try manager.clear(logger: nil)
    }

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

    /// A read that failed is not "absent". The variable is left alone by apply
    /// and by teardown; recording it as absent would have teardown unset a
    /// value we never saw.
    func testAVariableWhoseReadFailedIsNeitherWrittenNorUnset() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"
        launchctl.failingGetenv = ["HTTP_PROXY"]

        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080", "not overwritten")
        XCTAssertEqual(launchctl.environment["HTTPS_PROXY"], "http://127.0.0.1:3128", "the readable ones are")
        XCTAssertEqual(
            journal.prior(surface: .launchdEnvironment, scope: "HTTP_PROXY"),
            .wasPresent([EnvironmentManager.untouchedMarkerKey: "unreadable"])
        )

        try manager.clear(logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080", "and not unset by teardown")
        XCTAssertNil(launchctl.environment["HTTPS_PROXY"])
    }

    /// A read that failed once and works later: the untouched marker used to
    /// stand forever while the later apply wrote our value, and teardown,
    /// skipping untouched names, never removed it (#175).
    func testAVariableUnreadableAtFirstIsCapturedWhenItCanBeRead() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"
        launchctl.failingGetenv = ["HTTP_PROXY"]
        let manager = makeManager()
        let first = try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertEqual(first.launchd.unreadable, ["HTTP_PROXY"])

        launchctl.failingGetenv = []
        let second = try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertTrue(second.launchd.written.contains("HTTP_PROXY"))
        XCTAssertEqual(journal.prior(surface: .launchdEnvironment, scope: "HTTP_PROXY"),
                       .wasPresent(["value": "http://corp.example:8080"]), "the real prior replaced the marker")

        try manager.clear(logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080", "teardown puts it back")
    }

    /// A prior that cannot be journaled withholds the write, so teardown
    /// never has to guess; and teardown leaves a variable the journal never
    /// recorded alone while it holds other records, since every write is
    /// journaled first.
    func testAPriorThatCannotBeJournaledWithholdsTheWrite() throws {
        launchctl.environment["NO_PROXY"] = "user.example"
        // Readable (no file yet) but not writable: the state directory is read-only.
        let readOnly = home.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        let recorder = recordingSink()
        let manager = EnvironmentManager(journal: PlatformStateJournal(fileURL: readOnly.appendingPathComponent("platform-state.json")),
                                         homeDirectory: home, commandRunner: launchctl.run, eventSink: recorder.sink)

        let result = try manager.apply(config: makeConfig(), logger: nil)

        XCTAssertEqual(Set(result.launchd.withheld), ["HTTP_PROXY", "HTTPS_PROXY", "http_proxy", "https_proxy", "NO_PROXY", "no_proxy"])
        XCTAssertEqual(launchctl.environment, ["NO_PROXY": "user.example"], "nothing written without a record")
        XCTAssertEqual(recorder.events().last?.event, "platform.environment_launchd_incomplete")
        XCTAssertTrue(recorder.events().last?.detail?.hasPrefix("withheld=") == true)

        // No records, because nothing was written: not a lost journal.
        try manager.clear(logger: nil)
        XCTAssertEqual(launchctl.environment, ["NO_PROXY": "user.example"], "teardown leaves the foreign value alone")
    }

    /// Every capture withheld, so nothing was written: a loopback URL that
    /// was already there is someone else's local proxy, and the bypass list
    /// beside it theirs too.
    func testTeardownAfterWithheldCapturesLeavesForeignProxyValues() throws {
        let foreign = ["HTTP_PROXY": "http://127.0.0.1:9999", "HTTPS_PROXY": "http://foreign.example:8080",
                       "NO_PROXY": "user.example", "no_proxy": "user.example"]
        launchctl.environment = foreign
        let readOnly = home.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        let manager = EnvironmentManager(journal: PlatformStateJournal(fileURL: readOnly.appendingPathComponent("platform-state.json")),
                                         homeDirectory: home, commandRunner: launchctl.run)
        try manager.apply(config: makeConfig(), logger: nil)

        try manager.clear(logger: nil)

        XCTAssertEqual(launchctl.environment, foreign, "nothing was ours: a stop or a quit leaves every value as it was")
    }

    /// A `getenv` that hangs inside an inspection holds no lock, so the
    /// clear a stop or quit makes meanwhile goes ahead.
    func testAHungInspectionReadDoesNotHoldUpAClear() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        let reached = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = NIOLockedValueBox(true)
        let run = launchctl.run
        let blocking = EnvironmentManager(journal: journal, homeDirectory: home, commandRunner: { path, arguments in
            if arguments.first == "getenv", held.withLockedValue({ let first = $0; $0 = false; return first }) {
                reached.signal()
                release.wait()
            }
            return try run(path, arguments)
        })
        let inspected = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            _ = blocking.inspect(config: self.makeConfig())
            inspected.signal()
        }
        XCTAssertEqual(reached.wait(timeout: .now() + 5), .success)

        let cleared = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? blocking.clear(logger: nil)
            cleared.signal()
        }
        XCTAssertEqual(cleared.wait(timeout: .now() + 5), .success, "the clear did not wait for the hung read")
        XCTAssertNil(launchctl.environment["HTTP_PROXY"])
        release.signal()
        XCTAssertEqual(inspected.wait(timeout: .now() + 5), .success)
    }

    /// Our own URL, left by an earlier run, with the journal unwritable: it
    /// cannot be recorded, but it is ours. A stop that cannot read it keeps
    /// that knowledge, so the quit after it still removes it.
    func testAnOwnedValueUnreadableAtStopIsRemovedAtQuit() throws {
        launchctl.environment["HTTP_PROXY"] = makeConfig().localProxyURL
        let readOnly = home.appendingPathComponent("read-only", isDirectory: true)
        try FileManager.default.createDirectory(at: readOnly, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: readOnly.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: readOnly.path) }
        let manager = EnvironmentManager(journal: PlatformStateJournal(fileURL: readOnly.appendingPathComponent("platform-state.json")),
                                         homeDirectory: home, commandRunner: launchctl.run)
        try manager.apply(config: makeConfig(), logger: nil)

        launchctl.failingGetenv = ["HTTP_PROXY"]
        try manager.clear(logger: nil)
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], makeConfig().localProxyURL, "unreadable, so left for now")

        launchctl.failingGetenv = []
        try manager.clear(logger: nil)
        XCTAssertNil(launchctl.environment["HTTP_PROXY"], "the retry still knows it is ours")
    }

    /// A journal lost while running: what this manager wrote is still
    /// ours, but a value changed since is not.
    func testTeardownAfterALostJournalRemovesOnlyWhatIsStillOurs() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        journal.forgetAll(surface: .launchdEnvironment)
        launchctl.environment["no_proxy"] = "user.example"

        try manager.clear(logger: nil)

        XCTAssertEqual(launchctl.environment, ["no_proxy": "user.example"])
    }

    /// The user's own bypass list may equal ours. Without our address
    /// beside it, it is a prior to restore, not residue to remove.
    func testABypassListEqualToOursIsTheUsersOwnWithoutOurAddress() throws {
        let config = makeConfig()
        let list = config.noProxyHosts.joined(separator: ",")
        launchctl.environment = ["NO_PROXY": list, "no_proxy": list]
        let manager = makeManager()
        try manager.apply(config: config, logger: nil)

        try manager.clear(logger: nil)

        XCTAssertEqual(launchctl.environment, ["NO_PROXY": list, "no_proxy": list], "restored as the user's")
    }

    func testTeardownLeavesAnUnrecordedForeignValueAloneBesideRecords() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        journal.forgetAll(surface: .launchdEnvironment)
        journal.recordPrior(surface: .launchdEnvironment, scope: "HTTP_PROXY", value: nil)
        launchctl.environment["NO_PROXY"] = "user.example"

        try manager.clear(logger: nil)

        XCTAssertEqual(launchctl.environment["NO_PROXY"], "user.example", "never recorded, so never ours")
        XCTAssertNil(launchctl.environment["HTTPS_PROXY"], "our own address is still residue")
        XCTAssertNil(launchctl.environment["HTTP_PROXY"])
    }

    /// Already our values with no record (a lost journal): our address and,
    /// beside it, our bypass list are recorded as residue and not rewritten,
    /// so teardown unsets them instead of restoring them.
    func testValuesThatAreAlreadyOursAreRecordedAsResidue() throws {
        launchctl.environment["HTTP_PROXY"] = makeConfig().localProxyURL
        launchctl.environment["NO_PROXY"] = makeConfig().noProxyHosts.joined(separator: ",")
        let result = try makeManager().apply(config: makeConfig(), logger: nil)
        XCTAssertFalse(result.launchd.written.contains("HTTP_PROXY"))
        XCTAssertFalse(result.launchd.written.contains("NO_PROXY"))
        XCTAssertEqual(journal.prior(surface: .launchdEnvironment, scope: "NO_PROXY"), .wasAbsent)

        try makeManager().clear(logger: nil)
        XCTAssertNil(launchctl.environment["HTTP_PROXY"])
        XCTAssertNil(launchctl.environment["NO_PROXY"])
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

    /// The launchd twin of the system-proxy residue case. A stale proxy URL
    /// here is harder to find than one in Network Settings — it surfaces only
    /// as GUI apps mysteriously failing to reach anything — so an absent
    /// journal must not be taken as licence to leave it.
    func testTeardownUnsetsStaleVariablesWhenTheRecordIsLost() throws {
        // The domain still carries our address; the journal does not know it.
        launchctl.environment["HTTP_PROXY"] = "http://127.0.0.1:3128"
        launchctl.environment["HTTPS_PROXY"] = "http://127.0.0.1:3128"

        try makeManager().clear(logger: nil)

        XCTAssertNil(launchctl.environment["HTTP_PROXY"], "a stranded variable must still be cleaned up")
        XCTAssertNil(launchctl.environment["HTTPS_PROXY"])
    }

    /// And the converse: variables that are not ours are left alone.
    func testTeardownLeavesForeignVariablesAloneWhenNothingWasApplied() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"

        try makeManager().clear(logger: nil)

        XCTAssertEqual(
            launchctl.environment["HTTP_PROXY"], "http://corp.example:8080",
            "never having applied is not a licence to unset the user's own variable"
        )
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
    // MARK: - Ownership

    /// The host asks this when the user has turned the integration *off*:
    /// the flag no longer says to clear, so only evidence that we applied can
    /// (#13). Nothing applied means nothing to clean up; an apply means there
    /// is, until a clear puts everything back.
    func testHasManagedStateFollowsApplyAndClear() throws {
        let manager = makeManager()
        XCTAssertFalse(manager.hasManagedState(), "a fresh home and an empty journal hold nothing of ours")

        try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertTrue(manager.hasManagedState())

        try manager.clear(logger: nil)
        XCTAssertFalse(manager.hasManagedState(), "teardown released both the profiles and the launchd domain")
    }

    /// A managed block left in a profile — by a crash before teardown, or a
    /// state directory wiped since — is ours by its own delimiters, journal
    /// or no journal.
    func testHasManagedStateSeesAStrandedShellBlockWithoutAJournal() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try FileManager.default.removeItem(at: home.appendingPathComponent("platform-state.json"))

        XCTAssertTrue(
            EnvironmentManager(journal: PlatformStateJournal(fileURL: home.appendingPathComponent("platform-state.json")), homeDirectory: home, commandRunner: launchctl.run)
                .hasManagedState(),
            "the marker block identifies our region of the file without any record"
        )
    }

    /// Same contract as the system proxy: a launchd restore that failed keeps
    /// its records, and the journal tells a reconciling host to try again.
    func testHasManagedStateStaysTrueAfterAFailedLaunchdRestore() throws {
        launchctl.environment["HTTP_PROXY"] = "http://corp.example:8080"
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)

        launchctl.failSetenv = true
        try manager.clear(logger: nil)
        XCTAssertTrue(manager.hasManagedState(), "the prior value could not be put back")

        launchctl.failSetenv = false
        try manager.clear(logger: nil)
        XCTAssertFalse(manager.hasManagedState())
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://corp.example:8080")
    }

    // MARK: - Profiles that cannot be edited safely (#175)

    private var zshrc: URL { home.appendingPathComponent(".zshrc") }

    private func recordingSink() -> (sink: @Sendable (RuntimeEvent) -> Void, events: () -> [RuntimeEvent]) {
        let box = LockedEvents()
        return ({ box.append($0) }, { box.all })
    }

    /// Reading a non-UTF-8 profile used to fail into "", and the apply then
    /// replaced the whole file with just the block.
    func testANonUTF8ProfileIsLeftAloneAndReported() throws {
        let bytes = Data([0x65, 0x78, 0x70, 0xff, 0xfe, 0x0a])
        try bytes.write(to: zshrc)
        let recorder = recordingSink()
        let manager = EnvironmentManager(journal: journal, homeDirectory: home, commandRunner: launchctl.run,
                                         eventSink: recorder.sink)

        let outcomes = try manager.apply(config: makeConfig(), logger: nil).profiles

        XCTAssertEqual(try Data(contentsOf: zshrc), bytes, "the user's file is untouched")
        XCTAssertEqual(outcomes[.zshrc], .skipped(.notUTF8))
        XCTAssertEqual(outcomes[.zprofile], .written, "the other profiles are still written")
        XCTAssertEqual(launchctl.environment["HTTP_PROXY"], "http://127.0.0.1:3128")
        XCTAssertEqual(recorder.events().map(\.event), ["platform.environment_file_skipped"])
        XCTAssertEqual(recorder.events().first?.detail, "file=.zshrc reason=not_utf8 operation=apply")
    }

    /// An end marker before the start made the removal range invalid, which
    /// traps; a start without an end got a second block appended.
    func testMarkersThatDoNotPairAreNeitherRemovedNorStacked() throws {
        let manager = makeManager()
        for text in ["# <<< Conduit <<<\nexport A=1\n# >>> Conduit >>>\n",
                     "export A=1\n# >>> Conduit >>>\nexport HTTP_PROXY=x\n"] {
            try text.write(to: zshrc, atomically: true, encoding: .utf8)
            XCTAssertEqual(try manager.apply(config: makeConfig(), logger: nil).profiles[.zshrc], .skipped(.ambiguousMarkers))
            XCTAssertEqual(try manager.clear(logger: nil)[.zshrc], .skipped(.ambiguousMarkers))
            XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), text)
        }
    }

    /// Clear rewrote every profile, trimming the user's own blank lines and
    /// collapsing runs of them anywhere in the file, block or no block.
    func testClearLeavesAProfileWithoutABlockByteForByte() throws {
        let text = "\n\nexport A=1\n\n\n\nexport B=2\n\n"
        try text.write(to: zshrc, atomically: true, encoding: .utf8)

        XCTAssertEqual(try makeManager().clear(logger: nil)[.zshrc], .unchanged)
        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), text)
    }

    func testApplyThenClearRestoresTheProfileExactly() throws {
        let text = "export A=1\n\n\n\nexport B=2\n"
        try text.write(to: zshrc, atomically: true, encoding: .utf8)
        let manager = makeManager()

        try manager.apply(config: makeConfig(), logger: nil)
        try manager.clear(logger: nil)

        XCTAssertEqual(try String(contentsOf: zshrc, encoding: .utf8), text)
    }

    func testReapplyingTheSameConfigWritesNoProfile() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        let outcomes = try manager.apply(config: makeConfig(), logger: nil).profiles
        XCTAssertTrue(outcomes.values.allSatisfy { $0 == .unchanged }, "\(outcomes)")
    }

    func testAnOversizedProfileIsLeftAlone() throws {
        let big = Data(repeating: 0x61, count: ShellProfileBlock.maximumFileBytes + 1)
        try big.write(to: zshrc)
        XCTAssertEqual(try makeManager().apply(config: makeConfig(), logger: nil).profiles[.zshrc], .skipped(.oversized))
        XCTAssertEqual(try Data(contentsOf: zshrc).count, big.count)
    }

    // MARK: - Drift (#175)

    func testInspectionFindsNothingRightAfterApply() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertTrue(manager.inspect(config: makeConfig()).isClean)
    }

    /// The wipe that motivated #175: blocks stripped, variables unset.
    func testInspectionNamesEveryDriftedSurface() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: home.appendingPathComponent(".zprofile"))
        launchctl.environment["HTTP_PROXY"] = nil
        launchctl.environment["NO_PROXY"] = "elsewhere.example"

        var edited = makeConfig()
        edited.noProxyHosts = ["localhost", "*.internal"]
        let drift = manager.inspect(config: edited)
        XCTAssertEqual(drift.profiles, [.zshrc: .missing, .zprofile: .missing])
        XCTAssertEqual(Set(drift.launchd), ["HTTP_PROXY", "NO_PROXY"])

        var changed = makeConfig()
        changed.noProxyHosts.append("new.example")
        XCTAssertEqual(manager.inspect(config: changed).profiles[.environmentD], .stale, "a block for another config")
    }

    /// `launchctl getenv` prints nothing for an unset name and an empty one
    /// alike, so an applied empty bypass list must not look like drift.
    func testAnEmptyBypassListIsNotDrift() throws {
        var config = makeConfig()
        config.noProxyHosts = []
        let manager = makeManager()
        try manager.apply(config: config, logger: nil)
        XCTAssertTrue(manager.inspect(config: config).isClean)
    }

    func testAnUnreadableVariableIsReportedNotDrifted() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        launchctl.failingGetenv = ["NO_PROXY"]
        let drift = manager.inspect(config: makeConfig())
        XCTAssertFalse(drift.hasDrift)
        XCTAssertEqual(drift.unreadableLaunchd, ["NO_PROXY"])
    }

    /// A clear (switch off, stop, quit) or a newer apply after the pass read
    /// the generation wins: the repair from the older snapshot writes nothing.
    func testARepairOvertakenByAClearWritesNothing() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        let generation = manager.generation
        try manager.clear(logger: nil)

        XCTAssertNil(try manager.repair(config: makeConfig(), ifGeneration: generation, isCurrent: { true }, logger: nil))
        XCTAssertNil(launchctl.environment["HTTP_PROXY"])
        XCTAssertFalse(try String(contentsOf: zshrc, encoding: .utf8).contains("Conduit"))
    }

    func testARepairForAStaleLifecycleWritesNothing() throws {
        let manager = makeManager()
        let generation = manager.generation
        XCTAssertNil(try manager.repair(config: makeConfig(), ifGeneration: generation, isCurrent: { false }, logger: nil))
        XCTAssertTrue(launchctl.environment.isEmpty)
    }

    /// A repeated pass over the same unsafe profile reports it once.
    func testAnUnsafeProfileIsReportedOncePerEpisode() throws {
        try Data([0xff]).write(to: zshrc)
        let recorder = recordingSink()
        let manager = EnvironmentManager(journal: journal, homeDirectory: home, commandRunner: launchctl.run,
                                         eventSink: recorder.sink)
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertEqual(recorder.events().filter { $0.event == "platform.environment_file_skipped" }.count, 1)

        try "export A=1\n".write(to: zshrc, atomically: true, encoding: .utf8)
        try manager.apply(config: makeConfig(), logger: nil)
        try Data([0xff]).write(to: zshrc)
        try manager.apply(config: makeConfig(), logger: nil)
        XCTAssertEqual(recorder.events().filter { $0.event == "platform.environment_file_skipped" }.count, 2,
                       "a new episode after the file was fine again")
    }

    func testRepeatedApplyDoesNotAccumulateBlocks() throws {
        let manager = makeManager()
        try manager.apply(config: makeConfig(), logger: nil)
        try manager.apply(config: makeConfig(), logger: nil)

        let contents = try String(contentsOf: home.appendingPathComponent(".zshrc"), encoding: .utf8)
        let blockCount = contents.components(separatedBy: "# >>> Conduit >>>").count - 1
        XCTAssertEqual(blockCount, 1, "each apply replaces our block rather than appending another")
    }
}

private final class LockedEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [RuntimeEvent] = []
    func append(_ event: RuntimeEvent) { lock.withLock { events.append(event) } }
    var all: [RuntimeEvent] { lock.withLock { events } }
}

// MARK: - Fake launchctl

/// Models the per-user launchd domain as a dictionary, so `setenv`/`unsetenv`
/// are observable and `getenv` reflects them.
private final class FakeLaunchctl: @unchecked Sendable {
    var environment: [String: String] = [:]
    /// Simulates a transient launchctl failure on writes.
    var failSetenv = false
    /// Names whose `getenv` fails (non-zero exit).
    var failingGetenv: Set<String> = []
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
            if failingGetenv.contains(arguments[1]) {
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "simulated failure")
            }
            // Real launchctl prints nothing and still exits 0 for an unset name.
            return CommandResult(exitCode: 0, standardOutput: environment[arguments[1]] ?? "", standardError: "")
        default:
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected launchctl verb")
        }
    }
}
