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

    func execute(_ operation: PrivilegedOperation, values: [String]) throws {
        commands.append((operation, values))
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

    /// A record is only safe to drop once the prior value is actually back. If
    /// restore fails and we forget anyway, the setting we changed is left with
    /// nothing recording that we changed it.
    func testRecordSurvivesAFailedRestore() throws {
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

        runner.shellResult = CommandResult(exitCode: 14, standardOutput: "", standardError: "requires admin")
        try manager.clear(logger: nil)

        guard case .wasPresent(let prior) = journal.prior(surface: .systemProxy, scope: "Wi-Fi") else {
            return XCTFail("a failed restore must keep the record so a later teardown can retry")
        }
        XCTAssertEqual(prior["autoURL"], "http://mdm.corp.example/managed.pac")
        XCTAssertEqual(prior["autoEnabled"], "true")
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
    private(set) var invocations: [(launchPath: String, arguments: [String])] = []

    var shellScripts: [String] {
        invocations.compactMap { invocation in
            guard invocation.launchPath == "/bin/sh", invocation.arguments.count == 2 else { return nil }
            return invocation.arguments[1]
        }
    }

    func run(_ launchPath: String, _ arguments: [String]) throws -> CommandResult {
        invocations.append((launchPath, arguments))
        if launchPath == "/bin/sh" {
            return shellResult
        }
        guard launchPath == "/usr/sbin/networksetup", let command = arguments.first else {
            return CommandResult(exitCode: 1, standardOutput: "", standardError: "unexpected command")
        }
        switch command {
        case "-listallnetworkservices":
            return CommandResult(
                exitCode: 0,
                standardOutput: "An asterisk (*) denotes that a network service is disabled.\nWi-Fi",
                standardError: ""
            )
        case "-getinfo":
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
