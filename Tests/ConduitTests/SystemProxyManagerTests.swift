// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

final class SystemProxyManagerTests: XCTestCase {

    /// Every manager needs a journal now — the optional one silently restored
    /// the old erasing teardown, which is not a mode worth being able to reach
    /// by omission.
    fileprivate func makeJournal() -> PlatformStateJournal {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sysproxy-journal-\(UUID().uuidString)")
            .appendingPathComponent("platform-state.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return PlatformStateJournal(fileURL: url)
    }

    func testEffectivePACURLUsesRemoteURLWhenLocalPACDisabled() {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://proxy.example.com/proxy.pac"
        config.localPACEnabled = false

        XCTAssertEqual(
            SystemProxyManager.effectivePACURL(config: config, localPACURL: "http://127.0.0.1:63145/proxy.pac"),
            "https://proxy.example.com/proxy.pac"
        )
    }

    func testEffectivePACURLUsesLocalURLWhenEnabledAndBound() {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://proxy.example.com/proxy.pac"
        config.localPACEnabled = true

        XCTAssertEqual(
            SystemProxyManager.effectivePACURL(config: config, localPACURL: "http://127.0.0.1:63145/proxy.pac"),
            "http://127.0.0.1:63145/proxy.pac"
        )
    }

    func testEffectivePACURLFallsBackToRemoteURLWhenLocalPACNotBound() {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://proxy.example.com/proxy.pac"
        config.localPACEnabled = true

        XCTAssertEqual(
            SystemProxyManager.effectivePACURL(config: config, localPACURL: nil),
            "https://proxy.example.com/proxy.pac"
        )
    }

    func testPACApplyDisablesManualProxiesBeforeEnablingAutoproxy() throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://proxy.example.com/proxy.pac"
        config.localPACEnabled = false

        let runner = FakeNetworksetupRunner()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .pac, logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        let webOff = try XCTUnwrap(script.range(of: "-setwebproxystate 'Wi-Fi' off"))
        let secureOff = try XCTUnwrap(script.range(of: "-setsecurewebproxystate 'Wi-Fi' off"))
        let setPAC = try XCTUnwrap(script.range(of: "-setautoproxyurl 'Wi-Fi' 'https://proxy.example.com/proxy.pac'"))
        XCTAssertLessThan(webOff.lowerBound, setPAC.lowerBound)
        XCTAssertLessThan(secureOff.lowerBound, setPAC.lowerBound)
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' on"))
    }

    func testPACApplyViaPrivilegeClientSetsPACBeforeClearingManualProxies() throws {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://proxy.example.com/proxy.pac"
        config.localPACEnabled = false

        let runner = FakeNetworksetupRunner()
        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        let privilegeClient = RecordingProxyPrivilegeClient()
        let manager = SystemProxyManager(privilegeClient: privilegeClient, journal: makeJournal(), commandRunner: runner.run)

        try manager.apply(config: config, mode: .pac, logger: nil)

        XCTAssertEqual(privilegeClient.commands.map(\.command), [.setAutoproxyURL, .clearSystemProxy, .setAutoproxyURL])
        XCTAssertEqual(privilegeClient.commands[0].values, ["Wi-Fi", "https://proxy.example.com/proxy.pac"])
        XCTAssertEqual(privilegeClient.commands[1].values, ["Wi-Fi"])
        XCTAssertEqual(privilegeClient.commands[2].values, ["Wi-Fi", "https://proxy.example.com/proxy.pac"])
    }

    func testPACIsAppliedRequiresAutoproxyAndManualProxiesOff() {
        var config = ProxyConfig.testFixture()
        config.pacURL = "https://proxy.example.com/proxy.pac"
        config.localPACEnabled = false

        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "https://proxy.example.com/proxy.pac"
        runner.webProxyEnabled = false
        runner.secureWebProxyEnabled = false
        let manager = SystemProxyManager(journal: makeJournal(), commandRunner: runner.run)

        XCTAssertTrue(manager.isApplied(config: config, mode: .pac))

        runner.webProxyEnabled = true
        XCTAssertFalse(manager.isApplied(config: config, mode: .pac))

        runner.webProxyEnabled = false
        runner.secureWebProxyEnabled = true
        XCTAssertFalse(manager.isApplied(config: config, mode: .pac))
    }

    func testIsClearedReturnsFalseWhenAutoproxyEnabled() {
        let runner = FakeNetworksetupRunner()
        runner.webProxyEnabled = false
        runner.secureWebProxyEnabled = false
        runner.autoProxyEnabled = true
        let manager = SystemProxyManager(journal: makeJournal(), commandRunner: runner.run)

        XCTAssertFalse(manager.isCleared())
    }

    func testIsClearedReturnsTrueWhenAllProxiesDisabled() {
        let runner = FakeNetworksetupRunner()
        runner.webProxyEnabled = false
        runner.secureWebProxyEnabled = false
        runner.autoProxyEnabled = false
        let manager = SystemProxyManager(journal: makeJournal(), commandRunner: runner.run)

        XCTAssertTrue(manager.isCleared())
    }

    func testPACIsNotAppliedWithoutEffectivePACURL() {
        var config = ProxyConfig.testFixture()
        config.pacURL = ""
        config.localPACEnabled = false

        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        let manager = SystemProxyManager(journal: makeJournal(), commandRunner: runner.run)

        XCTAssertFalse(manager.isApplied(config: config, mode: .pac))
    }
}

private final class RecordingProxyPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    private(set) var commands: [(command: PrivilegedOperation, values: [String])] = []
    /// One entry per elevation, so tests can pin how many times a user would be
    /// prompted rather than only what was run.
    private(set) var batches: [[PrivilegedBatchStep]] = []
    private let error: Error?

    init(error: Error? = nil) {
        self.error = error
    }

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        try execute(batch: [PrivilegedBatchStep(operation, values)])
    }

    func execute(batch: [PrivilegedBatchStep]) throws {
        batches.append(batch)
        commands.append(contentsOf: batch.map { ($0.operation, $0.values) })
        if let error { throw error }
    }
}

// MARK: - Prior-state ownership

extension SystemProxyManagerTests {

    /// The harm this exists to stop. A managed Mac can arrive with an MDM- or
    /// user-configured PAC URL already set; teardown used to blanket-disable
    /// every proxy on every service and keep no record, so the first stop, quit
    /// or failed start silently erased a setting Conduit never owned and
    /// nothing could put it back.
    func testClearRestoresTheProxyConfigurationThatWasThereBeforeApply() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        var config = ProxyConfig.testFixture()
        config.localPACEnabled = true
        try manager.apply(config: config, mode: .pac, logger: nil, localPACURL: "http://127.0.0.1:63145/proxy.pac")
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.contains("-setautoproxyurl 'Wi-Fi' 'http://mdm.corp.example/managed.pac'"),
            "teardown must put the user's own PAC URL back, not just switch autoproxy off: \(script)"
        )
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' on"))
    }

    /// A machine with nothing configured before us is restored exactly by
    /// turning everything off, which is also what teardown always did.
    func testClearDisablesEverythingWhenNothingWasConfiguredBefore() throws {
        let runner = FakeNetworksetupRunner()
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        try manager.clear(logger: nil)
        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"))
        XCTAssertFalse(script.contains("-setautoproxyurl"), "nothing to put back")
    }

    /// A journal that never recorded anything means we never applied anything,
    /// so teardown must leave the machine alone.
    ///
    /// This used to be impossible to express: with an optional journal, "we
    /// never applied" and "we cannot say what we applied" were the same state,
    /// and teardown blanket-disabled for both — so quitting an app that had
    /// never started the proxy would wipe a user's MDM proxy settings.
    /// The host asks this when the user has turned the integration *off*, so
    /// only evidence that we applied can drive the clear (#13). It must come
    /// from the journal, not from `isCleared()`: that reads whether *any*
    /// proxy is enabled, and a user's own proxy would make quitting with the
    /// switch off disable it.
    func testHasManagedStateFollowsTheJournalNotTheMachine() throws {
        let runner = FakeNetworksetupRunner()
        runner.webProxyEnabled = true
        runner.proxyHost = "proxy.corp.example"
        runner.proxyPort = "8080"
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        XCTAssertFalse(manager.isCleared(), "the user's own proxy is enabled")
        XCTAssertFalse(manager.hasManagedState(), "...but nothing of it is ours")

        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)
        XCTAssertTrue(manager.hasManagedState())

        try manager.clear(logger: nil)
        XCTAssertFalse(manager.hasManagedState(), "teardown restored the surface and marked it released")
    }

    func testClearLeavesTheMachineAloneWhenNothingWasEverApplied() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        try manager.clear(logger: nil)

        XCTAssertTrue(
            runner.shellScripts.isEmpty,
            "never having applied is not a licence to disable the user's own proxy"
        )
    }

    /// End-to-end first-write-wins. Apply runs repeatedly within a session, and
    /// every run after the first sees *our own* PAC URL as the current state —
    /// so a record that could be overwritten would make teardown restore what
    /// Conduit installed rather than what the user had.
    func testRepeatedApplyKeepsTheOriginalPriorState() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        var config = ProxyConfig.testFixture()
        config.localPACEnabled = true
        let ours = "http://127.0.0.1:63145/proxy.pac"
        try manager.apply(config: config, mode: .pac, logger: nil, localPACURL: ours)

        // The machine now reports our own setting, as it would on a reload.
        runner.autoProxyURL = ours
        try manager.apply(config: config, mode: .pac, logger: nil, localPACURL: ours)

        try manager.clear(logger: nil)
        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.contains("-setautoproxyurl 'Wi-Fi' 'http://mdm.corp.example/managed.pac'"),
            "the second apply must not have overwritten the original prior: \(script)"
        )
    }

    /// Teardown clears the whole surface, not just the services present at the
    /// time. A service can vanish between apply and clear — a VPN interface, an
    /// unplugged adapter — and forgetting only what is currently connected
    /// leaves its record behind for good; if it ever reappears,
    /// first-write-wins would then keep that stale record in preference to the
    /// state the service actually has.
    /// A service that is listed but has no address — a VPN link down, an
    /// adapter unplugged — still takes `networksetup` writes. Teardown restores
    /// it now; skipping it and forgetting its record would leave it pointed at
    /// a dead proxy for whenever it comes back.
    func testClearRestoresARecordedServiceThatIsListedButDisconnected() throws {
        let runner = FakeNetworksetupRunner()
        runner.services = ["Wi-Fi", "Ethernet"]
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://corp.example.com/proxy.pac"
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        XCTAssertEqual(Set(journal.scopes(for: .systemProxy)), ["Wi-Fi", "Ethernet"])

        runner.disconnectedServices = ["Ethernet"]
        runner.invocations.removeAll()
        try manager.clear(logger: nil)

        let restoreScripts = runner.shellScripts.joined(separator: "\n")
        XCTAssertTrue(restoreScripts.contains("Ethernet"), "the disconnected service is restored: \(restoreScripts)")
        XCTAssertTrue(restoreScripts.contains("http://corp.example.com/proxy.pac"))
        XCTAssertTrue(journal.scopes(for: .systemProxy).isEmpty, "nothing left outstanding")
    }

    /// Every field `apply` overwrites must have been read. A failed read used
    /// to be recorded as the empty default, which teardown then "restored" by
    /// erasing the user's setting.
    func testApplySkipsAServiceWhosePriorStateCannotBeRead() throws {
        for failing in ["-getwebproxy", "-getsecurewebproxy", "-getautoproxyurl", "-getproxybypassdomains"] {
            let runner = FakeNetworksetupRunner()
            runner.services = ["Wi-Fi", "Ethernet"]
            runner.failingReads = [failing]
            let journal = makeJournal()
            let manager = SystemProxyManager(
                privilegeClient: RecordingProxyPrivilegeClient(),
                journal: journal,
                commandRunner: runner.run
            )

            XCTAssertThrowsError(try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil), failing) { error in
                guard case SystemProxyManagerError.priorStateUnreadable = error else {
                    return XCTFail("\(failing): unexpected \(error)")
                }
            }
            XCTAssertTrue(journal.scopes(for: .systemProxy).isEmpty, "\(failing): nothing recorded")
            XCTAssertFalse(journal.isMarkedApplied(surface: .systemProxy), "\(failing): nothing applied")
            XCTAssertTrue(runner.shellScripts.isEmpty, "\(failing): nothing written")
        }
    }

    func testApplyTouchesOnlyTheServicesItCouldRead() throws {
        let runner = FakeNetworksetupRunner()
        runner.services = ["Wi-Fi", "Ethernet"]
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: { launchPath, arguments in
                // The bypass read fails on Ethernet only.
                if arguments.first == "-getproxybypassdomains", arguments.dropFirst().first == "Ethernet" {
                    return CommandResult(exitCode: 1, standardOutput: "", standardError: "** Error")
                }
                return try runner.run(launchPath, arguments)
            }
        )

        // Manual mode: the PAC script is empty when the fixture has no PAC URL.
        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)

        XCTAssertEqual(Set(journal.scopes(for: .systemProxy)), ["Wi-Fi", "Ethernet"])
        XCTAssertEqual(
            journal.prior(surface: .systemProxy, scope: "Ethernet"),
            .wasPresent([SystemProxyManager.untouchedMarkerKey: "unreadable"]),
            "the unreadable service is recorded as untouched, so teardown leaves it alone"
        )
        let script = runner.shellScripts.joined(separator: "\n")
        XCTAssertTrue(script.contains("Wi-Fi"), script)
        XCTAssertFalse(script.contains("Ethernet"), "an unreadable service is not written either")
    }

    /// One service readable, one not: the unreadable one is neither written
    /// nor, at teardown, cleared — the marker in the journal says apply never
    /// touched it.
    func testClearLeavesAServiceApplyCouldNotReadUntouched() throws {
        let runner = FakeNetworksetupRunner()
        runner.services = ["Wi-Fi", "Ethernet"]
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: { launchPath, arguments in
                if arguments.first == "-getwebproxy", arguments.dropFirst().first == "Ethernet" {
                    return CommandResult(exitCode: 1, standardOutput: "", standardError: "** Error")
                }
                return try runner.run(launchPath, arguments)
            }
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)
        runner.invocations.removeAll()

        try manager.clear(logger: nil)

        let scripts = runner.shellScripts.joined(separator: "\n")
        XCTAssertTrue(scripts.contains("Wi-Fi"))
        XCTAssertFalse(scripts.contains("Ethernet"), "teardown must not clear a service apply never wrote: \(scripts)")
        XCTAssertTrue(journal.scopes(for: .systemProxy).isEmpty)
    }

    /// A disabled service is starred in the listing, still holds settings and
    /// still takes writes — and is the one most likely to be re-enabled later
    /// with our settings on it.
    func testClearRestoresARecordedServiceThatWasDisabledSince() throws {
        let runner = FakeNetworksetupRunner()
        runner.services = ["Wi-Fi", "Ethernet"]
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://corp.example.com/proxy.pac"
        let journal = makeJournal()
        let manager = SystemProxyManager(privilegeClient: RecordingProxyPrivilegeClient(), journal: journal, commandRunner: runner.run)
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.disabledServices = ["Ethernet"]
        runner.invocations.removeAll()
        try manager.clear(logger: nil)

        XCTAssertTrue(runner.shellScripts.joined(separator: "\n").contains("Ethernet"))
        XCTAssertTrue(journal.scopes(for: .systemProxy).isEmpty)
    }

    /// Without a listing, "not enumerated this time" cannot be told from "gone
    /// for good", so records that were not restored stay for a later teardown.
    func testClearKeepsUnrestoredRecordsWhenTheListingFails() throws {
        let runner = FakeNetworksetupRunner()
        runner.services = ["Wi-Fi", "Ethernet"]
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://corp.example.com/proxy.pac"
        let journal = makeJournal()
        let manager = SystemProxyManager(privilegeClient: RecordingProxyPrivilegeClient(), journal: journal, commandRunner: runner.run)
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.disconnectedServices = ["Ethernet"]
        runner.listingFailuresRemaining = 1  // the first listing (all services) fails; the connected one succeeds
        runner.invocations.removeAll()
        try manager.clear(logger: nil)

        XCTAssertTrue(runner.shellScripts.joined(separator: "\n").contains("Wi-Fi"), "what could be restored, was")
        XCTAssertEqual(journal.scopes(for: .systemProxy), ["Ethernet"], "the unrestored service keeps its record")
        XCTAssertNotEqual(journal.ownership(of: .systemProxy), .released)
    }

    func testClearForgetsRecordsForServicesThatVanished() throws {
        let runner = FakeNetworksetupRunner()
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        // Stands in for a service that was present at apply and is gone by clear.
        journal.recordPrior(surface: .systemProxy, scope: "FakeVPN_utun99", value: ["autoURL": "http://old"])
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        try manager.clear(logger: nil)

        XCTAssertEqual(
            journal.prior(surface: .systemProxy, scope: "FakeVPN_utun99"),
            .notRecorded,
            "a vanished service must not keep a record across sessions"
        )
        XCTAssertTrue(journal.scopes(for: .systemProxy).isEmpty)
    }

    /// The regression this nearly shipped with. `clear` restores the recorded
    /// prior state and then forgets it, so a second `clear` finds no record —
    /// and the unconditional fallback would blanket-disable the settings the
    /// first call just put back. Both hosts really do call it twice: once on
    /// stop, once on quit.
    func testSecondTeardownDoesNotWipeWhatTheFirstOneRestored() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        try manager.clear(logger: nil)
        let scriptsAfterFirstClear = runner.shellScripts.count

        try manager.clear(logger: nil)

        XCTAssertEqual(
            runner.shellScripts.count,
            scriptsAfterFirstClear,
            "the second teardown must issue nothing, not blanket-disable the restored settings"
        )
    }

    /// The safety valve on that short-circuit: a journal that cannot be read
    /// must not be taken as "nothing to do", or a crash that corrupts it would
    /// strand the machine pointing at a proxy port nothing serves.
    func testUnreadableJournalStillFallsBackToClearing() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sysproxy-corrupt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("platform-state.json")
        try Data("{ truncated".utf8).write(to: file)

        let runner = FakeNetworksetupRunner()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: PlatformStateJournal(fileURL: file),
            commandRunner: runner.run
        )

        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"))
    }

    /// Manual mode also overwrites the bypass-domain list, and networksetup
    /// keeps host/port on a *disabled* proxy — so capturing only the enabled
    /// endpoints would leave Conduit's values in the user's fields.
    func testTeardownRestoresBypassDomainsAndDisabledEndpoints() throws {
        let runner = FakeNetworksetupRunner()
        runner.bypassDomains = ["*.corp.example", "internal.test"]
        runner.proxyHost = "oldproxy.example"
        runner.proxyPort = "9999"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.contains("-setproxybypassdomains 'Wi-Fi' '*.corp.example' 'internal.test'"),
            "the user's bypass list must come back: \(script)"
        )
        XCTAssertTrue(
            script.contains("-setwebproxy 'Wi-Fi' 'oldproxy.example' '9999'"),
            "a disabled proxy's endpoint is still the user's, not ours: \(script)"
        )
    }

    /// The restore path's exit code is the only evidence it landed, so unlike
    /// the blanket-clear path it must not suppress failures. With `|| true` a
    /// half-failed restore reports success, the record is dropped, and the
    /// user's remaining settings can never be recovered.
    func testRestoreScriptDoesNotSuppressFailures() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setautoproxyurl"), "precondition: this is the restore path")
        XCTAssertFalse(
            script.contains("|| true"),
            "a restore that cannot report failure cannot be retried: \(script)"
        )
    }

    /// The other half of the absent-journal question. "Nothing recorded" is
    /// "we never applied" on a clean install, but it is also "we applied and
    /// lost the record" after a failed journal write or a deleted state
    /// directory. Skipping on the second leaves every app on the machine
    /// pointed at a proxy that is not running, permanently.
    func testClearStillCleansUpWhenTheMachineStillPointsAtUs() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://127.0.0.1:63145/proxy.pac"   // our own residue

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),            // empty: the record is gone
            commandRunner: runner.run
        )

        try manager.clear(logger: nil)

        let script = try XCTUnwrap(
            runner.shellScripts.last,
            "a stranded local-proxy setting must be cleaned up even with no record of it"
        )
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"))
    }

    /// The residue probe must not fire on a *disabled* local proxy: it routes
    /// nothing, and blanket-disabling on its account is pure over-reach.
    func testResidueProbeIgnoresDisabledLocalProxySettings() throws {
        let runner = FakeNetworksetupRunner()
        runner.proxyHost = "127.0.0.1"
        runner.webProxyEnabled = false
        runner.secureWebProxyEnabled = false

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        try manager.clear(logger: nil)

        XCTAssertTrue(runner.shellScripts.isEmpty, "a disabled entry is not active residue")
    }

    /// networksetup keeps the autoproxy URL on a switched-off autoproxy, so
    /// leaving ours there hands the user a dead local PAC server the moment
    /// they switch automatic configuration back on. The sibling endpoint loop
    /// already restored disabled host/port; this branch had been missed.
    func testTeardownRestoresADisabledAutoproxyURL() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = false                                  // configured but off
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"
        runner.webProxyEnabled = true                                    // so prior state is captured

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.contains("-setautoproxyurl 'Wi-Fi' 'http://mdm.corp.example/managed.pac'"),
            "the user's URL must go back even though it was switched off: \(script)"
        )
        let urlIndex = try XCTUnwrap(script.range(of: "-setautoproxyurl"))
        let stateIndex = try XCTUnwrap(script.range(of: "-setautoproxystate 'Wi-Fi' off"))
        XCTAssertLessThan(
            urlIndex.lowerBound, stateIndex.lowerBound,
            "state must be set last, so the URL write cannot leave autoproxy enabled"
        )
    }

    /// A teardown that failed for a non-admin reason used to report nothing and
    /// then announce a successful restore anyway.
    /// The managers report a partial teardown by keeping its records, not by
    /// throwing, so a host that reconciles the switch asks the journal whether
    /// the clear landed. Records left means the next save must try again.
    func testHasManagedStateStaysTrueAfterAFailedTeardownUntilOneSucceeds() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.shellResult = CommandResult(exitCode: 3, standardOutput: "", standardError: "boom")
        try manager.clear(logger: nil)
        XCTAssertTrue(manager.hasManagedState(), "nothing was put back, so the surface is still ours to restore")

        runner.shellResult = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
        try manager.clear(logger: nil)
        XCTAssertFalse(manager.hasManagedState(), "the retry restored it")
    }

    func testFailedTeardownIsReportedAndNotClaimedAsSuccess() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let logger = RecordingLogSink(minLevel: .debug)
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.shellResult = CommandResult(exitCode: 3, standardOutput: "", standardError: "boom")
        try manager.clear(logger: logger)

        XCTAssertTrue(
            logger.containsMessage("networksetup failed during teardown", at: .warning),
            "the failure must be reported: \(logger.entries().map(\.message))"
        )
        XCTAssertFalse(
            logger.containsMessage("Restored the previous macOS proxy settings"),
            "a failed teardown must not announce a restore"
        )
        XCTAssertNotEqual(
            journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .notRecorded,
            "and the records stay for a retry"
        )
    }

    /// The blanket-clear branch must not suppress its failures either.
    ///
    /// Every command used to end in `2>/dev/null || true`, which forces the
    /// script's exit code to 0 and discards the "requires admin" text — so on a
    /// machine that cannot write proxy settings unprivileged, the privileged
    /// fallback never ran, nothing was cleared, the records were dropped as if
    /// it had worked, and the run reported success.
    func testBlanketClearScriptDoesNotSuppressFailures() throws {
        let runner = FakeNetworksetupRunner()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        // Residue with no recorded prior: takes the blanket-clear branch.
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://127.0.0.1:63145/proxy.pac"
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"), "precondition: blanket-clear branch")
        XCTAssertFalse(
            script.contains("|| true"),
            "a teardown that cannot report failure cannot fall back to the helper: \(script)"
        )
        XCTAssertFalse(script.contains("2>/dev/null"), "and the 'requires admin' text must survive: \(script)")
    }

    /// A record is only safe to drop once the prior value is actually back. If
    /// restore fails and we forget anyway, the setting we changed is left with
    /// nothing recording that we changed it.
    func testRecordSurvivesAFailedRestore() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(error: PrivilegeClientError.helperNotInstalled),
            journal: journal,
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        try manager.clear(logger: nil)

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("a failed restore must keep the record so a later teardown can retry")
        }
        XCTAssertEqual(prior["autoURL"], "http://mdm.corp.example/managed.pac")
        XCTAssertEqual(prior["autoEnabled"], "true")
    }
}

// MARK: - Restoring where writes need admin rights

extension SystemProxyManagerTests {

    /// The gap this whole change exists to close.
    ///
    /// On a machine where the user cannot write proxy settings without admin
    /// rights — verified to be this project's own primary target — every
    /// teardown degraded to `clearSystemProxy` per service: the recorded prior
    /// state was kept and never applied, so the feature bought "nothing is lost
    /// permanently" rather than "your settings come back".
    func testPrivilegedTeardownRestoresThePriorStateInsteadOfBlanketClearing() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"
        runner.bypassDomains = ["*.corp.example"]
        runner.proxyHost = "oldproxy.example"
        runner.proxyPort = "9999"
        runner.webProxyEnabled = true

        let privilegeClient = RecordingProxyPrivilegeClient()
        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: privilegeClient,
            journal: journal,
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)

        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        try manager.clear(logger: nil)

        XCTAssertFalse(
            privilegeClient.commands.contains { $0.command == .clearSystemProxy },
            "teardown must no longer degrade to a blanket clear: \(privilegeClient.commands)"
        )
        XCTAssertEqual(
            privilegeClient.commands.map(\.command),
            [.setAutoproxy, .setWebProxyEndpoint, .setWebProxyEndpoint, .setProxyBypass]
        )
        XCTAssertEqual(
            privilegeClient.commands[0].values,
            ["Wi-Fi", "http://mdm.corp.example/managed.pac", "on"],
            "the user's PAC URL goes back, enabled as it was"
        )
        XCTAssertEqual(
            privilegeClient.commands[1].values,
            ["Wi-Fi", "web", "oldproxy.example", "9999", "on"]
        )
        XCTAssertEqual(
            privilegeClient.commands[2].values,
            ["Wi-Fi", "secure", "oldproxy.example", "9999", "off"],
            "an endpoint that was configured but off must go back configured and off"
        )
        XCTAssertEqual(privilegeClient.commands[3].values, ["Wi-Fi", "*.corp.example"])
        XCTAssertTrue(
            journal.scopes(for: .systemProxy).isEmpty,
            "a restore that landed may drop its records"
        )
    }

    /// Restoring one service takes four operations, and the AppleScript
    /// fallback prompts for a password per invocation. Looping would ask a user
    /// with two services for eight passwords.
    func testPrivilegedTeardownElevatesOncePerService() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let privilegeClient = RecordingProxyPrivilegeClient()
        let manager = SystemProxyManager(
            privilegeClient: privilegeClient,
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        try manager.clear(logger: nil)

        XCTAssertEqual(privilegeClient.batches.count, 1, "one elevation, not one per write")
        XCTAssertEqual(privilegeClient.batches[0].count, 4)
    }

    /// `sh -c` reports only the *last* command's exit status, so a restore
    /// whose endpoint write failed but whose trailing bypass write succeeded
    /// used to report success — after which the records, the only copy of the
    /// user's real settings, were dropped.
    func testRestoreScriptAbortsOnTheFirstFailedCommand() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.hasPrefix("set -e\n"),
            "without `set -e` only the last command's status survives: \(script)"
        )
    }

    /// A user who empties their bypass list must still be able to turn the
    /// proxy on. `setProxyBypass` needs the `Empty` sentinel for a list with no
    /// domains — teardown has always sent it — but apply hand-assembled
    /// `[service] + noProxyHosts`, which is a single value the contract
    /// rejects. Run through the client that actually ships as the default, so
    /// the contract guard is the thing being tested rather than a fake's
    /// tolerance of it.
    func testApplyWithAnEmptyBypassListSendsTheClearSentinel() throws {
        var config = ProxyConfig.testFixture()
        config.noProxyHosts = []

        let runner = FakeNetworksetupRunner()
        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        let recorder = RecordingProxyPrivilegeClient()
        let manager = SystemProxyManager(
            privilegeClient: recorder,
            journal: makeJournal(),
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .manual, logger: nil)

        let bypass = try XCTUnwrap(recorder.commands.last { $0.command == .setProxyBypass })
        XCTAssertEqual(bypass.values, ["Wi-Fi", "Empty"])
        XCTAssertNoThrow(
            try AppleScriptPrivilegeClient().shellScript(for: .setProxyBypass, values: bypass.values),
            "apply must send what the privileged contract accepts"
        )
    }

    /// The same hole on the unprivileged path: a bare
    /// `-setproxybypassdomains <service>` with no domains is answered by
    /// `networksetup` with its usage text and a non-zero exit, so apply threw
    /// instead of turning the proxy on.
    func testApplyScriptWithAnEmptyBypassListWritesTheClearSentinel() throws {
        var config = ProxyConfig.testFixture()
        config.noProxyHosts = []

        let runner = FakeNetworksetupRunner()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .manual, logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.contains("-setproxybypassdomains 'Wi-Fi' Empty"),
            "an empty list has a spelling; a command with no domains at all is not it: \(script)"
        )
    }

    /// Each service is its own unit of work. A failure on one must not decide
    /// the outcome for the others, and must not drop their records.
    func testOneServiceFailingDoesNotDropAnotherServicesRecord() throws {
        let runner = FakeNetworksetupRunner()
        runner.services = ["Wi-Fi", "Ethernet"]
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"
        runner.failingServices = ["Ethernet"]

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(error: PrivilegeClientError.helperNotInstalled),
            journal: journal,
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        try manager.clear(logger: nil)

        XCTAssertNotEqual(
            journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .notRecorded,
            "one service failing must keep every record, so a later teardown can retry the lot"
        )
        XCTAssertNotEqual(journal.prior(surface: .systemProxy, scope: "Ethernet"), .notRecorded)
    }

    /// A user whose *own* proxy is a loopback address — a local mitmproxy, or a
    /// second tool — gets it read as our residue by the residue probe. Before
    /// the journal remembered that a teardown had completed, the second
    /// teardown of a session then disabled the settings the first one had just
    /// restored: the double-teardown erase, through the residue door.
    func testSecondTeardownDoesNotDisableARestoredLoopbackProxy() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://127.0.0.1:8888/user-own.pac"   // the user's, not ours

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)
        try manager.clear(logger: nil)
        let scriptsAfterFirstClear = runner.shellScripts.count

        try manager.clear(logger: nil)

        XCTAssertEqual(
            runner.shellScripts.count, scriptsAfterFirstClear,
            "the restored setting is the user's own loopback proxy, not our residue"
        )
    }

    /// A service that had no manual proxy before us must not be left holding
    /// ours.
    ///
    /// `networksetup` keeps host and port on a *disabled* proxy, so switching
    /// the state off is not enough: our `127.0.0.1:<port>` stays in the
    /// `Server` field and is handed to the user the moment they re-enable the
    /// proxy by hand — the exact harm restoring disabled endpoints exists to
    /// prevent. Found by driving the real helper: the recorded prior said "no
    /// endpoint", and an empty host meant "write only the state".
    func testTeardownClearsOurAddressWhenTheServiceHadNoneBefore() throws {
        let runner = FakeNetworksetupRunner()
        runner.proxyHost = ""            // nothing configured before us
        runner.proxyPort = "0"           // what -getwebproxy reports for "none"
        runner.webProxyEnabled = false
        runner.autoProxyEnabled = true   // so a prior is captured at all
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let privilegeClient = RecordingProxyPrivilegeClient()
        let manager = SystemProxyManager(
            privilegeClient: privilegeClient,
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(
            script.contains("-setwebproxy 'Wi-Fi' '' 0"),
            "our address must be blanked, not just switched off: \(script)"
        )
        XCTAssertTrue(script.contains("-setsecurewebproxy 'Wi-Fi' '' 0"))

        _ = privilegeClient
    }

    /// The privileged renderer must say the same thing as the shell one — that
    /// is the whole point of driving both from one description.
    func testPrivilegedTeardownClearsOurAddressWhenTheServiceHadNoneBefore() throws {
        let runner = FakeNetworksetupRunner()
        runner.proxyHost = ""
        runner.proxyPort = "0"
        runner.webProxyEnabled = false
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let privilegeClient = RecordingProxyPrivilegeClient()
        let manager = SystemProxyManager(
            privilegeClient: privilegeClient,
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)

        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        try manager.clear(logger: nil)

        XCTAssertTrue(
            privilegeClient.commands.contains {
                $0.command == .setWebProxyEndpoint && $0.values == ["Wi-Fi", "web", "Empty", "", "off"]
            },
            "the privileged path must clear it too: \(privilegeClient.commands)"
        )
        XCTAssertTrue(
            privilegeClient.commands.contains {
                $0.command == .setWebProxyEndpoint && $0.values == ["Wi-Fi", "secure", "Empty", "", "off"]
            }
        )
    }

    /// The other side of that rule. A blanket clear runs when there is *no*
    /// record, and an endpoint we never recorded is not ours to erase —
    /// switching the proxy off is enough to stop it routing.
    func testBlanketClearSwitchesOffWithoutErasingAnUnrecordedAddress() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://127.0.0.1:63145/proxy.pac"   // residue, no record

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )

        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setwebproxystate 'Wi-Fi' off"), "precondition: blanket-clear branch")
        XCTAssertFalse(
            script.contains("-setwebproxy 'Wi-Fi'"),
            "an address we have no record of is not ours to erase: \(script)"
        )
    }

    /// `-setwebproxy` switches the proxy *on* as a side effect, exactly like
    /// `-setautoproxyurl` — verified on macOS 26, documented nowhere. So the
    /// state line has to come last on the manual endpoints too, or restoring a
    /// configured-but-disabled proxy would switch it on behind the user's back.
    func testEndpointStateIsAlwaysWrittenAfterTheAddress() throws {
        let runner = FakeNetworksetupRunner()
        runner.proxyHost = "oldproxy.example"
        runner.proxyPort = "9999"
        runner.webProxyEnabled = false
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .manual, logger: nil)
        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        let address = try XCTUnwrap(script.range(of: "-setwebproxy 'Wi-Fi' 'oldproxy.example' '9999'"))
        let state = try XCTUnwrap(script.range(of: "-setwebproxystate 'Wi-Fi' off"))
        XCTAssertLessThan(
            address.lowerBound, state.lowerBound,
            "-setwebproxy enables the proxy, so the state must be written after it: \(script)"
        )
    }

    // MARK: - Not capturing our own residue as the user's setting

    /// Observed on a real machine. A teardown that only switched autoproxy
    /// *off* left our local PAC URL in the field; the next cold start read it
    /// back and recorded it as "what the user had", and the corporate PAC URL
    /// it had replaced was gone for good. First-write-wins guards a single
    /// session; across sessions the machine is the input, and it can already be
    /// carrying our leftovers.
    func testCaptureDiscardsOurOwnLocalPACURLLeftByAnEarlierSession() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = false                                  // partial teardown
        runner.autoProxyURL = "http://127.0.0.1:63145/proxy.pac"         // ours, left behind

        var config = ProxyConfig.testFixture()
        config.localPACEnabled = true
        config.localPACPort = 63145

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .pac, logger: nil, localPACURL: "http://127.0.0.1:63145/proxy.pac")

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("expected a recorded prior")
        }
        XCTAssertEqual(prior["autoURL"], "", "our own dead local PAC URL is residue, not the user's setting")
        XCTAssertEqual(prior["autoEnabled"], "false")
    }

    /// The trap in the obvious version of that rule. "Discard anything equal to
    /// what we are about to write" looks equivalent and is not: with
    /// `localPACEnabled` off, `apply` writes the user's *own* configured PAC
    /// URL to the system, so that test would throw away the very setting
    /// teardown exists to restore. Ownership is about the address, not the
    /// write.
    func testCaptureKeepsTheUsersPACURLEvenWhenWeAreAboutToApplyItOurselves() throws {
        let corporate = "http://rbins.example.com/lis.pac"
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = corporate

        var config = ProxyConfig.testFixture()
        config.localPACEnabled = false
        config.pacURL = corporate                                        // we apply the user's own URL

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .pac, logger: nil)

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("expected a recorded prior")
        }
        XCTAssertEqual(prior["autoURL"], corporate, "a remote PAC URL is the user's, whoever wrote it last")
        XCTAssertEqual(prior["autoEnabled"], "true")
    }

    /// Someone running their own proxy on loopback is entitled to have it
    /// restored, so the rule cannot be "is this loopback".
    func testCaptureKeepsALoopbackProxyThatIsNotOurs() throws {
        let runner = FakeNetworksetupRunner()
        runner.webProxyEnabled = true
        runner.proxyHost = "127.0.0.1"
        runner.proxyPort = "8888"                                        // not our port

        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .manual, logger: nil)

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("expected a recorded prior")
        }
        XCTAssertEqual(prior["webHost"], "127.0.0.1")
        XCTAssertEqual(prior["webPort"], "8888")
        XCTAssertEqual(prior["webEnabled"], "true")
    }

    /// A stale URL on a local PAC port we no longer use is still ours — the
    /// port is ephemeral across sessions, the path is not.
    func testCaptureDiscardsOurLocalPACURLOnAStalePort() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://127.0.0.1:51999/proxy.pac"         // last session's port

        var config = ProxyConfig.testFixture()
        config.localPACEnabled = true
        config.localPACPort = 63145

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .pac, logger: nil, localPACURL: "http://127.0.0.1:63145/proxy.pac")

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("expected a recorded prior")
        }
        XCTAssertEqual(prior["autoURL"], "")
    }

    /// And our own manual endpoint, from a session that ran in manual mode.
    func testCaptureDiscardsOurOwnManualEndpoint() throws {
        let runner = FakeNetworksetupRunner()
        runner.webProxyEnabled = false
        runner.proxyHost = "127.0.0.1"
        runner.proxyPort = "3128"
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"      // so a prior exists

        var config = ProxyConfig.testFixture()
        config.localHost = "127.0.0.1"
        config.localPort = 3128

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run
        )

        try manager.apply(config: config, mode: .manual, logger: nil)

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("expected a recorded prior")
        }
        XCTAssertEqual(prior["webHost"], "", "our own address must not become the user's prior")
        XCTAssertEqual(prior["webPort"], "")
        XCTAssertEqual(
            prior["autoURL"], "http://mdm.corp.example/managed.pac",
            "and the rest of the prior is untouched"
        )
    }

    // MARK: - Crash recovery

    /// A run that was `SIGKILL`ed never tore down, so the machine keeps
    /// pointing at a proxy port nothing serves. Launch is when the recorded
    /// prior state is most likely still the truth.
    func testRestoreIfNeededRestoresOrphanedSettingsWhenNothingIsListening() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run,
            portProbe: { _ in false }
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        // The crash: our own PAC is on the machine, the records survive, and
        // nothing is serving the port.
        runner.autoProxyURL = "http://127.0.0.1:63145/proxy.pac"
        let freshManager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run,
            portProbe: { _ in false }
        )
        runner.invocations.removeAll()

        freshManager.restoreIfNeeded(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last, "orphaned settings must be restored at launch")
        XCTAssertTrue(script.contains("-setautoproxyurl 'Wi-Fi' 'http://mdm.corp.example/managed.pac'"))
    }

    /// The safety valve: a live listener on the port the machine points at
    /// means another instance is serving it, and taking its settings away would
    /// break every client on the machine.
    func testRestoreIfNeededLeavesAServedProxyAlone() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let journal = makeJournal()
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: journal,
            commandRunner: runner.run,
            portProbe: { _ in true }
        )
        try manager.apply(config: ProxyConfig.testFixture(), mode: .pac, logger: nil)

        runner.autoProxyURL = "http://127.0.0.1:63145/proxy.pac"
        runner.invocations.removeAll()

        manager.restoreIfNeeded(logger: nil)

        XCTAssertTrue(
            runner.shellScripts.isEmpty,
            "a proxy that is still being served is not orphaned"
        )
    }

    /// Nothing recorded means nothing of ours is outstanding, whatever the
    /// machine currently holds.
    func testRestoreIfNeededDoesNothingWithoutRecords() {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            journal: makeJournal(),
            commandRunner: runner.run,
            portProbe: { _ in false }
        )

        manager.restoreIfNeeded(logger: nil)

        XCTAssertTrue(runner.shellScripts.isEmpty)
    }
}

private final class FakeNetworksetupRunner: @unchecked Sendable {
    var shellResult = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    var autoProxyEnabled = false
    var autoProxyURL = ""
    var webProxyEnabled = false
    var secureWebProxyEnabled = false
    var proxyHost = "127.0.0.1"
    var proxyPort = "3128"
    var bypassDomains: [String] = []
    var services = ["Wi-Fi"]
    /// Services whose write scripts fail as if `networksetup` rejected them —
    /// a non-admin failure, so no privileged fallback is attempted.
    var failingServices: [String] = []
    /// Listed services with no IP address: `networksetup -getinfo` reports
    /// them, `connectedNetworkServices` does not.
    var disconnectedServices: Set<String> = []
    /// Listed with the leading asterisk `networksetup` uses for a disabled service.
    var disabledServices: Set<String> = []
    /// How many `-listallnetworkservices` calls fail before they succeed.
    var listingFailuresRemaining = 0
    /// `networksetup -get…` reads that fail (non-zero exit), by command.
    var failingReads: Set<String> = []
    var invocations: [(launchPath: String, arguments: [String])] = []

    var shellScripts: [String] {
        invocations.compactMap { invocation in
            guard invocation.launchPath == "/bin/sh", invocation.arguments.count == 2 else { return nil }
            return invocation.arguments[1]
        }
    }

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        invocations.append((launchPath, arguments))
        if launchPath == "/bin/sh" {
            let script = arguments.count == 2 ? arguments[1] : ""
            if failingServices.contains(where: { script.contains("'\($0)'") }) {
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "networksetup: unsupported")
            }
            return shellResult
        }
        guard launchPath == "/usr/sbin/networksetup", let command = arguments.first else {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
        if failingReads.contains(command) {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "** Error: read failed")
        }
        switch command {
        case "-listallnetworkservices":
            if listingFailuresRemaining > 0 {
                listingFailuresRemaining -= 1
                return CommandResult(exitCode: 1, standardOutput: "", standardError: "** Error: transient")
            }
            let lines = services.map { disabledServices.contains($0) ? "*\($0)" : $0 }
            return CommandResult(
                exitCode: 0,
                standardOutput: (["An asterisk (*) denotes that a network service is disabled."] + lines)
                    .joined(separator: "\n"),
                standardError: ""
            )
        case "-getinfo":
            let service = arguments.count > 1 ? arguments[1] : ""
            if disconnectedServices.contains(service) || disabledServices.contains(service) {
                return CommandResult(exitCode: 0, standardOutput: "IP address:\nSubnet mask:", standardError: "")
            }
            return CommandResult(exitCode: 0, standardOutput: "IP address: 192.0.2.10", standardError: "")
        case "-getwebproxy":
            return proxyState(enabled: webProxyEnabled)
        case "-getsecurewebproxy":
            return proxyState(enabled: secureWebProxyEnabled)
        case "-getproxybypassdomains":
            return CommandResult(
                exitCode: 0,
                standardOutput: bypassDomains.isEmpty
                    ? "There aren't any bypass domains set on this network service."
                    : bypassDomains.joined(separator: "\n"),
                standardError: ""
            )
        case "-getautoproxyurl":
            return CommandResult(
                exitCode: 0,
                standardOutput: """
                URL: \(autoProxyURL)
                Enabled: \(autoProxyEnabled ? "Yes" : "No")
                """,
                standardError: ""
            )
        default:
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected networksetup command")
        }
    }

    private func proxyState(enabled: Bool) -> CommandResult {
        CommandResult(
            exitCode: 0,
            standardOutput: """
            Enabled: \(enabled ? "Yes" : "No")
            Server: \(proxyHost)
            Port: \(proxyPort)
            """,
            standardError: ""
        )
    }
}
