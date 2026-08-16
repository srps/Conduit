// SPDX-License-Identifier: Apache-2.0
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

final class SystemProxyManagerTests: XCTestCase {

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
        let manager = SystemProxyManager(privilegeClient: privilegeClient, commandRunner: runner.run)

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
        let manager = SystemProxyManager(commandRunner: runner.run)

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
        let manager = SystemProxyManager(commandRunner: runner.run)

        XCTAssertFalse(manager.isCleared())
    }

    func testIsClearedReturnsTrueWhenAllProxiesDisabled() {
        let runner = FakeNetworksetupRunner()
        runner.webProxyEnabled = false
        runner.secureWebProxyEnabled = false
        runner.autoProxyEnabled = false
        let manager = SystemProxyManager(commandRunner: runner.run)

        XCTAssertTrue(manager.isCleared())
    }

    func testPACIsNotAppliedWithoutEffectivePACURL() {
        var config = ProxyConfig.testFixture()
        config.pacURL = ""
        config.localPACEnabled = false

        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        let manager = SystemProxyManager(commandRunner: runner.run)

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

    private func makeJournal() -> PlatformStateJournal {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("sysproxy-journal-\(UUID().uuidString)")
            .appendingPathComponent("platform-state.json")
        addTeardownBlock { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        return PlatformStateJournal(fileURL: url)
    }

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
        XCTAssertEqual(journal.prior(surface: .systemProxy, scope: "Wi-Fi"), .wasAbsent)

        try manager.clear(logger: nil)
        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"))
        XCTAssertFalse(script.contains("-setautoproxyurl"), "nothing to put back")
    }

    /// The safety rule: no record means *unknown*, never *leave it alone*.
    /// A journal that was wiped, never wired in, or lost with the process that
    /// wrote it must still leave the machine usable — a system proxy pointing
    /// at a port nothing serves breaks every client on the machine, while
    /// over-clearing costs a visible setting the user can restore.
    func testClearStillDisablesProxiesWhenNothingWasRecorded() throws {
        let runner = FakeNetworksetupRunner()
        runner.autoProxyEnabled = true
        runner.autoProxyURL = "http://mdm.corp.example/managed.pac"

        // Note: no journal at all — the pre-existing configuration.
        let manager = SystemProxyManager(
            privilegeClient: RecordingProxyPrivilegeClient(),
            commandRunner: runner.run
        )

        try manager.clear(logger: nil)

        let script = try XCTUnwrap(runner.shellScripts.last)
        XCTAssertTrue(script.contains("-setwebproxystate 'Wi-Fi' off"))
        XCTAssertTrue(script.contains("-setsecurewebproxystate 'Wi-Fi' off"))
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"))
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

        XCTAssertEqual(
            journal.prior(surface: .systemProxy, scope: "Wi-Fi"),
            .wasPresent([
                "webEnabled": "false", "webHost": "127.0.0.1", "webPort": "3128",
                "secureEnabled": "false", "secureHost": "127.0.0.1", "securePort": "3128",
                "autoEnabled": "true", "autoURL": "http://mdm.corp.example/managed.pac",
            ]),
            "a failed restore must keep the record so a later teardown can retry"
        )
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
