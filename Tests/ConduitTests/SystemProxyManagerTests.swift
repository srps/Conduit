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

private final class FakeNetworksetupRunner: @unchecked Sendable {
    var shellResult = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    var autoProxyEnabled = false
    var autoProxyURL = ""
    var webProxyEnabled = false
    var secureWebProxyEnabled = false
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
            Server: 127.0.0.1
            Port: 3128
            """,
            standardError: ""
        )
    }
}
