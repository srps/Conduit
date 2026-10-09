// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel
@testable import ConduitShared

final class HelperContractTests: XCTestCase {

    // MARK: - HelperRequest Encoding

    func testRequestRoundTrip() throws {
        let request = HelperRequest(command: .applyDNS, values: ["example.test", "10.0.0.53"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, HelperProtocolVersion.current)
        XCTAssertEqual(decoded.command, .applyDNS)
        XCTAssertEqual(decoded.values, ["example.test", "10.0.0.53"])
    }

    func testAllCommandsEncodable() throws {
        for command in HelperCommand.allCases {
            let request = HelperRequest(command: command, values: [])
            let data = try JSONEncoder().encode(request)
            let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
            XCTAssertEqual(decoded.command, command)
        }
    }

    func testRequestWithMultipleValues() throws {
        let request = HelperRequest(command: .applyDNS, values: ["example.test", "10.0.0.53,10.0.0.54"])
        let data = try JSONEncoder().encode(request)
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: data)
        XCTAssertEqual(decoded.values.count, 2)
        XCTAssertEqual(decoded.values[0], "example.test")
    }

    // MARK: - HelperResponse Encoding

    func testOkResponseRoundTrip() throws {
        let response = HelperResponse.ok()
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, HelperProtocolVersion.current)
        XCTAssertTrue(decoded.success)
        XCTAssertNil(decoded.errorMessage)
    }

    func testErrorResponseRoundTrip() throws {
        let response = HelperResponse.error("something went wrong")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertFalse(decoded.success)
        XCTAssertEqual(decoded.errorMessage, "something went wrong")
    }

    func testScriptResultRoundTrip() throws {
        let response = HelperResponse.scriptResult(exitCode: 0, stdout: "hello", stderr: "")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertEqual(decoded.protocolVersion, HelperProtocolVersion.current)
        XCTAssertTrue(decoded.success)
        XCTAssertEqual(decoded.exitCode, 0)
        XCTAssertEqual(decoded.standardOutput, "hello")
        XCTAssertEqual(decoded.standardError, "")
    }

    func testRequestMissingProtocolVersionDecodesAsUnknown() throws {
        let legacyJSON = #"{"command":"ping","values":[]}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HelperRequest.self, from: legacyJSON)
        XCTAssertEqual(decoded.protocolVersion, 0)
        XCTAssertEqual(decoded.command, .ping)
    }

    func testResponseDefaultsProtocolVersionWhenMissing() throws {
        let legacyJSON = #"{"success":true}"#.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: legacyJSON)
        XCTAssertEqual(decoded.protocolVersion, HelperProtocolVersion.current)
        XCTAssertTrue(decoded.success)
    }

    func testFailedScriptResultCarriesExitCode() throws {
        let response = HelperResponse.scriptResult(exitCode: 14, stdout: "", stderr: "requires admin")
        let data = try JSONEncoder().encode(response)
        let decoded = try JSONDecoder().decode(HelperResponse.self, from: data)
        XCTAssertFalse(decoded.success)
        XCTAssertEqual(decoded.exitCode, 14)
        XCTAssertEqual(decoded.standardError, "requires admin")
        XCTAssertTrue(decoded.errorMessage!.contains("14"))
    }

    // MARK: - HelperConstants

    func testConstantsAreSane() {
        XCTAssertTrue(HelperConstants.socketPath.hasPrefix("/var/run/"))
        XCTAssertTrue(HelperConstants.binaryInstallPath.hasPrefix("/Library/"))
        XCTAssertTrue(HelperConstants.launchdPlistPath.hasSuffix(".plist"))
        XCTAssertFalse(HelperConstants.serviceLabel.isEmpty)
    }

    // MARK: - HelperCommand Raw Values

    func testCommandRawValuesMatchCLI() {
        XCTAssertEqual(HelperCommand.applyDNS.rawValue, "apply-dns")
        XCTAssertEqual(HelperCommand.removeDNS.rawValue, "remove-dns")
        XCTAssertEqual(HelperCommand.applySystemProxy.rawValue, "apply-system-proxy")
        XCTAssertEqual(HelperCommand.clearSystemProxy.rawValue, "clear-system-proxy")
        XCTAssertEqual(HelperCommand.setProxyBypass.rawValue, "set-proxy-bypass")
        XCTAssertEqual(HelperCommand.setAutoproxyURL.rawValue, "set-autoproxy-url")
        XCTAssertEqual(HelperCommand.disableAutoproxy.rawValue, "disable-autoproxy")
        XCTAssertEqual(HelperCommand.setDNSServers.rawValue, "set-dns-servers")
        XCTAssertEqual(HelperCommand.ping.rawValue, "ping")
    }

    func testPrivilegedOperationsMapToHelperCommands() {
        for operation in PrivilegedOperation.allCases {
            XCTAssertEqual(HelperCommand(operation).rawValue, operation.rawValue)
        }
    }

    func testRunScriptCommandNoLongerExists() {
        let allRawValues = HelperCommand.allCases.map(\.rawValue)
        XCTAssertFalse(allRawValues.contains("run-script"),
                       "runScript was removed for security — arbitrary script execution is not allowed")
    }

    func testNewCommandsExist() {
        XCTAssertNotNil(HelperCommand(rawValue: "set-proxy-bypass"))
        XCTAssertNotNil(HelperCommand(rawValue: "set-autoproxy-url"))
        XCTAssertNotNil(HelperCommand(rawValue: "disable-autoproxy"))
        XCTAssertNotNil(HelperCommand(rawValue: "set-dns-servers"))
    }

    // MARK: - Version negotiation

    /// The helper outlives the app that installed it. A rolled-back app leaves
    /// a newer helper answering an older client — and shipped clients reject
    /// any reply not stamped with their own version, then rethrow rather than
    /// degrading to AppleScript. An exact-match helper therefore bricked every
    /// privileged operation until it was uninstalled by hand.
    func testHelperHonoursTheSupportedVersionRange() {
        XCTAssertTrue(HelperProtocolVersion.isSupported(HelperProtocolVersion.current))
        XCTAssertTrue(HelperProtocolVersion.isSupported(HelperProtocolVersion.minimumSupported))
        XCTAssertTrue(
            HelperProtocolVersion.isSupported(3),
            "a v3 frame is still read; see minimumSupported for why that is a trade-off and not a claim that nothing changed"
        )
        XCTAssertLessThanOrEqual(HelperProtocolVersion.minimumSupported, HelperProtocolVersion.current)
    }

    /// Replies carry the *requester's* version, which is the entire mechanism:
    /// an older client's exact-match guard has to be satisfied.
    func testReplyIsStampedWithTheRequestersVersion() {
        XCTAssertEqual(HelperProtocolVersion.replyVersion(forRequest: 3), 3)
        XCTAssertEqual(HelperProtocolVersion.replyVersion(forRequest: 4), 4)
    }

    /// An unversioned frame decodes as 0 and must still be refused — the threat
    /// model requires it, and a range must not become a way in.
    func testUnversionedAndOutOfRangeFramesAreStillRefused() {
        XCTAssertNil(HelperProtocolVersion.replyVersion(forRequest: 0))
        XCTAssertFalse(HelperProtocolVersion.isSupported(0))
        XCTAssertNil(HelperProtocolVersion.replyVersion(forRequest: 2),
                     "below the floor: those commands may have had different argument shapes")
        XCTAssertNil(HelperProtocolVersion.replyVersion(forRequest: HelperProtocolVersion.current + 1),
                     "a newer client must not be told we speak its version")
    }

    func testProtocolVersionBumped() {
        XCTAssertGreaterThanOrEqual(HelperProtocolVersion.current, 3,
                                    "Protocol version must be >= 3 after helper trust-boundary hardening")
    }

    // MARK: - Input Validation

    func testValidateDomainAcceptsValid() {
        XCTAssertTrue(HelperInputValidator.validateDomain("example.com"))
        XCTAssertTrue(HelperInputValidator.validateDomain("example.test"))
        XCTAssertTrue(HelperInputValidator.validateDomain("sub.domain.co.uk"))
        XCTAssertTrue(HelperInputValidator.validateDomain("a"))
    }

    /// The deliberate loosening of the helper's trust boundary, recorded on
    /// `HelperProtocolVersion.minimumSupported`. `/etc/resolver/<domain>` names
    /// a resolution domain rather than a hostname, so LDH was the wrong
    /// grammar; `_` is inert as a path component and as argv.
    func testValidateDomainAcceptsUnderscores() {
        XCTAssertTrue(HelperInputValidator.validateDomain("foo_bar.example"))
        XCTAssertTrue(HelperInputValidator.validateDomain("_dmarc.example.com"))
        XCTAssertTrue(HelperInputValidator.validateDomain("_http._tcp.example.com"))
    }

    func testValidateDomainRejectsInvalid() {
        XCTAssertFalse(HelperInputValidator.validateDomain(""))
        XCTAssertFalse(HelperInputValidator.validateDomain("../../etc/hosts"))
        XCTAssertFalse(HelperInputValidator.validateDomain("-start.com"))
        XCTAssertFalse(HelperInputValidator.validateDomain("has spaces.com"))
        XCTAssertFalse(HelperInputValidator.validateDomain(String(repeating: "a", count: 254)))
        // Loosening `_` did not loosen the shapes that reach the filesystem or
        // argv as something other than a name.
        XCTAssertFalse(HelperInputValidator.validateDomain("evil/path"))
        XCTAssertFalse(HelperInputValidator.validateDomain("bad\0.com"))
        XCTAssertFalse(HelperInputValidator.validateDomain("example.com."))
        XCTAssertFalse(HelperInputValidator.validateDomain("foo..bar"))
        XCTAssertFalse(HelperInputValidator.validateDomain("bücher.example"))
    }

    func testValidateIPAcceptsValid() {
        XCTAssertTrue(HelperInputValidator.validateIPAddress("10.0.0.53"))
        XCTAssertTrue(HelperInputValidator.validateIPAddress("127.0.0.1"))
        XCTAssertTrue(HelperInputValidator.validateIPAddress("::1"))
        XCTAssertTrue(HelperInputValidator.validateIPAddress("fe80::1"))
    }

    func testValidateIPRejectsInvalid() {
        XCTAssertFalse(HelperInputValidator.validateIPAddress(""))
        XCTAssertFalse(HelperInputValidator.validateIPAddress("not-an-ip"))
        XCTAssertFalse(HelperInputValidator.validateIPAddress("999.53.53.53"))
        XCTAssertFalse(HelperInputValidator.validateIPAddress("10.0.0.53; rm -rf /"))
    }

    /// The regex this replaced accepted anything spelled out of hex and
    /// colons. These all passed it and reach `networksetup` as argv.
    func testValidateIPRejectsWhatTheOldRegexLetThrough() {
        for value in ["::::::", "ffff", ":", "fe80::1%en0", "[::1]", "1:2:3:4:5:6:7:8:9"] {
            XCTAssertFalse(HelperInputValidator.validateIPAddress(value), value)
        }
    }

    func testValidateAutoproxyURLRejectsUserInfo() {
        XCTAssertTrue(HelperInputValidator.validateAutoproxyURL("https://proxy.example.com/proxy.pac"))
        XCTAssertFalse(HelperInputValidator.validateAutoproxyURL("https://user:secret@proxy.example.com/proxy.pac"))
    }

    func testValidateRelayBindHostAllowsOnlyLoopbackTargets() {
        XCTAssertTrue(HelperInputValidator.validateRelayBindHost("127.0.0.1"))
        XCTAssertTrue(HelperInputValidator.validateRelayBindHost("127.44.3.0"))
        XCTAssertFalse(HelperInputValidator.validateRelayBindHost("0.0.0.0"))
        XCTAssertFalse(HelperInputValidator.validateRelayBindHost("192.168.1.10"))
    }

    func testValidateServiceNameAcceptsValid() {
        XCTAssertTrue(HelperInputValidator.validateServiceName("Wi-Fi"))
        XCTAssertTrue(HelperInputValidator.validateServiceName("Ethernet"))
        XCTAssertTrue(HelperInputValidator.validateServiceName("USB 10/100/1000 LAN"))
        XCTAssertTrue(HelperInputValidator.validateServiceName("Thunderbolt Bridge"))
    }

    func testValidateServiceNameRejectsInvalid() {
        XCTAssertFalse(HelperInputValidator.validateServiceName(""))
        XCTAssertFalse(HelperInputValidator.validateServiceName("Wi-Fi; rm -rf /"))
        XCTAssertFalse(HelperInputValidator.validateServiceName(String(repeating: "a", count: 129)))
    }

    func testHelperClientRejectsInvalidSystemProxyBeforeIPC() {
        let client = HelperToolPrivilegeClient()

        XCTAssertThrowsError(
            try client.execute(.applySystemProxy, values: ["Wi-Fi", "bad host!", "8080"])
        )
        XCTAssertThrowsError(
            try client.execute(.applySystemProxy, values: ["Wi-Fi", "127.0.0.1", "not-a-port"])
        )
    }

    func testHelperClientRejectsInvalidRelayBindHostBeforeIPC() {
        let client = HelperToolPrivilegeClient()

        XCTAssertFalse(client.sendCommand(.startTCPRelay, values: ["443", "10443", "0.0.0.0"]))
        XCTAssertFalse(client.sendCommand(.startDNSRelay, values: ["0"]))
    }

    func testValidatePortAcceptsValid() {
        XCTAssertTrue(HelperInputValidator.validatePort("1"))
        XCTAssertTrue(HelperInputValidator.validatePort("8080"))
        XCTAssertTrue(HelperInputValidator.validatePort("65535"))
    }

    func testValidatePortRejectsInvalid() {
        XCTAssertFalse(HelperInputValidator.validatePort("0"))
        XCTAssertFalse(HelperInputValidator.validatePort("65536"))
        XCTAssertFalse(HelperInputValidator.validatePort("abc"))
        XCTAssertFalse(HelperInputValidator.validatePort(""))
    }

    // MARK: - Privilege Client Fallback

    func testHelperClientStatusNotInstalledByDefault() throws {
        let client = HelperToolPrivilegeClient()
        try XCTSkipIf(client.status == .installed,
                       "Helper is installed on this machine; skipping not-installed assertion")
        XCTAssertNotEqual(client.status, .installed,
                          "Helper should not appear installed unless actually set up with sudo")
    }

    func testHelperClientPingFailsWithoutHelper() throws {
        let client = HelperToolPrivilegeClient()
        try XCTSkipIf(client.status == .installed,
                       "Helper is installed on this machine; skipping ping-failure assertion")
        XCTAssertFalse(client.ping())
    }

    // MARK: - Restore operations

    func testRestoreCommandsExist() {
        XCTAssertNotNil(HelperCommand(rawValue: "set-web-proxy-endpoint"))
        XCTAssertNotNil(HelperCommand(rawValue: "set-autoproxy"))
    }

    /// Bypass entries were the one helper argument that reached `networksetup`
    /// unvalidated, because they are not domains — `*.local` and `169.254/16`
    /// are both real and neither passes `validateDomain`. That called for its
    /// own rule, not an exemption from the trust boundary.
    func testValidateProxyBypassEntryAcceptsRealWorldEntries() {
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry("*.local"))
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry("169.254/16"))
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry("*.corp.example"))
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry(".example.com"))
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry("10.0.0.1"))
    }

    /// The shipped `routing.noProxyHosts` default is the input this validator
    /// sees most often, and it has to pass. A bracketed IPv6 literal failed the
    /// character class, so on any machine where `networksetup` needs admin
    /// rights a stock install could not apply the proxy at all — and a bypass
    /// list captured off such a machine could not be restored either.
    func testValidateProxyBypassEntryAcceptsTheShippedDefaultList() {
        for entry in RoutingSection().noProxyHosts {
            XCTAssertTrue(
                HelperInputValidator.validateProxyBypassEntry(entry),
                "the default bypass list must survive its own validator: \(entry)"
            )
        }
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry("[::1]"))
        XCTAssertTrue(HelperInputValidator.validateProxyBypassEntry("[fe80::1]"))
    }

    func testValidateProxyBypassEntryRejectsArgumentInjection() {
        // These reach networksetup as argv, so a leading dash is the one shape
        // that changes what the command does.
        XCTAssertFalse(HelperInputValidator.validateProxyBypassEntry("-setwebproxystate"))
        XCTAssertFalse(HelperInputValidator.validateProxyBypassEntry(""))
        XCTAssertFalse(HelperInputValidator.validateProxyBypassEntry("has space"))
        XCTAssertFalse(HelperInputValidator.validateProxyBypassEntry("a;rm -rf /"))
        XCTAssertFalse(HelperInputValidator.validateProxyBypassEntry("$(whoami)"))
        XCTAssertFalse(HelperInputValidator.validateProxyBypassEntry("a\nb"))
    }

    /// Host and port travel together: `-setwebproxy` takes both or neither, and
    /// a port of `0` — what `-getwebproxy` reports for a service that never had
    /// a proxy — must not round-trip into a live but unusable endpoint.
    func testValidateOptionalEndpointRequiresHostAndPortTogether() {
        XCTAssertTrue(HelperInputValidator.validateOptionalEndpoint(host: "", port: ""))
        XCTAssertTrue(HelperInputValidator.validateOptionalEndpoint(host: "proxy.example", port: "8080"))
        // The clear instruction, distinct from "leave the address alone".
        XCTAssertTrue(HelperInputValidator.validateOptionalEndpoint(host: "Empty", port: ""))
        XCTAssertFalse(HelperInputValidator.validateOptionalEndpoint(host: "Empty", port: "8080"))
        XCTAssertFalse(HelperInputValidator.validateOptionalEndpoint(host: "proxy.example", port: ""))
        XCTAssertFalse(HelperInputValidator.validateOptionalEndpoint(host: "", port: "8080"))
        XCTAssertFalse(HelperInputValidator.validateOptionalEndpoint(host: "proxy.example", port: "0"))
        XCTAssertFalse(HelperInputValidator.validateOptionalEndpoint(host: "bad host!", port: "8080"))
    }

    func testHelperClientRejectsInvalidRestoreArgumentsBeforeIPC() {
        let client = HelperToolPrivilegeClient()

        XCTAssertThrowsError(try client.execute(.setWebProxyEndpoint, values: ["Wi-Fi", "sideways", "", "", "off"]))
        XCTAssertThrowsError(try client.execute(.setWebProxyEndpoint, values: ["Wi-Fi", "web", "", "", "maybe"]))
        XCTAssertThrowsError(try client.execute(.setAutoproxy, values: ["Wi-Fi", "file:///etc/passwd", "on"]))
        XCTAssertThrowsError(try client.execute(.setProxyBypass, values: ["Wi-Fi", "-setwebproxystate"]))
        XCTAssertThrowsError(try client.execute(.setProxyBypass, values: ["Wi-Fi"]),
                             "clearing the list has a spelling; a lost argument list must not look like one")
        XCTAssertThrowsError(try client.execute(.setProxyBypass, values: ["Wi-Fi", "Empty", "*.local"]))
    }

    /// The empty-URL and empty-endpoint forms are what make a restore
    /// expressible at all: `networksetup` keeps host, port and URL on a
    /// *disabled* proxy, so putting a user's setting back without switching it
    /// on is the common case, not an edge one.
    func testAppleScriptRendererWritesStateLastAndSkipsAbsentValues() throws {
        let client = AppleScriptPrivilegeClient()

        let disabledURL = try XCTUnwrap(
            client.shellScript(for: .setAutoproxy, values: ["Wi-Fi", "http://mdm.corp.example/a.pac", "off"])
        )
        let urlIndex = try XCTUnwrap(disabledURL.range(of: "-setautoproxyurl"))
        let stateIndex = try XCTUnwrap(disabledURL.range(of: "-setautoproxystate 'Wi-Fi' off"))
        XCTAssertLessThan(
            urlIndex.lowerBound, stateIndex.lowerBound,
            "-setautoproxyurl enables autoproxy as a side effect, so the state must be written last"
        )

        let stateOnly = try XCTUnwrap(client.shellScript(for: .setAutoproxy, values: ["Wi-Fi", "", "off"]))
        XCTAssertFalse(stateOnly.contains("-setautoproxyurl"), "no URL recorded means none to write back")

        let endpointOnly = try XCTUnwrap(
            client.shellScript(for: .setWebProxyEndpoint, values: ["Wi-Fi", "secure", "old.example", "9999", "off"])
        )
        XCTAssertTrue(endpointOnly.contains("-setsecurewebproxy 'Wi-Fi' 'old.example' '9999'"))
        XCTAssertTrue(endpointOnly.contains("-setsecurewebproxystate 'Wi-Fi' off"))
    }

    /// `AppleScriptPrivilegeClient` is `SystemProxyManager`'s *default*
    /// privilege client, so it is the unguarded way in whenever the helper
    /// client validates something it does not. The restore batch is
    /// `setAutoproxy`, two `setWebProxyEndpoint`s and `setProxyBypass`; the
    /// first three gained their guards with the operations themselves, and the
    /// bypass step was left rendering straight into a root shell.
    func testAppleScriptRendererRejectsAFlagShapedBypassEntry() {
        let client = AppleScriptPrivilegeClient()

        XCTAssertThrowsError(
            try client.shellScript(for: .setProxyBypass, values: ["Wi-Fi", "-setwebproxystate"]),
            "quoting stops metacharacters; it cannot stop an entry that reaches networksetup as a flag"
        )
        XCTAssertNoThrow(
            try client.shellScript(for: .setProxyBypass, values: ["Wi-Fi", "*.local", "169.254/16", "[::1]"]),
            "real bypass lists carry all three shapes and must still render"
        )
    }

    /// Restoring one service takes four operations, and the AppleScript
    /// fallback raises an admin prompt per invocation.
    func testAppleScriptBatchRendersAsASingleScript() throws {
        let client = AppleScriptPrivilegeClient()
        let script = try client.batchScript(for: [
            PrivilegedBatchStep(.setAutoproxy, ["Wi-Fi", "", "off"]),
            PrivilegedBatchStep(.setWebProxyEndpoint, ["Wi-Fi", "web", "", "", "off"]),
        ])
        XCTAssertTrue(script.contains("-setautoproxystate 'Wi-Fi' off"))
        XCTAssertTrue(script.contains("-setwebproxystate 'Wi-Fi' off"))
    }

    /// The failure this exists to stop. `osascript` exits 1 when the user
    /// dismisses the password dialog, and
    /// `CommandRunner.runPrivilegedShellScript` reports that as an ordinary
    /// `CommandResult` rather than throwing. Discarding it made a cancelled
    /// prompt look exactly like a completed restore, and `SystemProxyManager`
    /// then dropped the records holding the user's real proxy settings.
    func testCancelledAdminPromptIsAFailureNotASuccess() {
        let cancelled = CommandResult(
            exitCode: 1,
            standardOutput: "",
            standardError: "execution error: User canceled. (-128)"
        )
        let client = AppleScriptPrivilegeClient(runner: { _ in cancelled })

        XCTAssertThrowsError(try client.execute(.clearSystemProxy, values: ["Wi-Fi"])) { error in
            XCTAssertTrue(
                error.displayDescription.contains("User canceled"),
                "the reason the elevation failed has to survive to the caller: \(error)"
            )
        }
        XCTAssertThrowsError(
            try client.execute(batch: [PrivilegedBatchStep(.setAutoproxy, ["Wi-Fi", "", "off"])])
        )
    }

    func testSuccessfulPrivilegedScriptDoesNotThrow() throws {
        let client = AppleScriptPrivilegeClient(
            runner: { _ in CommandResult(exitCode: 0, standardOutput: "", standardError: "") }
        )
        try client.execute(.clearSystemProxy, values: ["Wi-Fi"])
        try client.execute(batch: [PrivilegedBatchStep(.setAutoproxy, ["Wi-Fi", "", "off"])])
    }

    /// `sh` reports only the last command's status, so a batch whose first
    /// write failed still exited 0. Every step here is an absolute set, so
    /// aborting and retrying the whole sequence is the safe behaviour.
    func testPrivilegedScriptsAbortOnTheFirstFailedCommand() throws {
        let recorder = RecordingPrivilegedScriptRunner()
        let client = AppleScriptPrivilegeClient(runner: recorder.run)

        try client.execute(batch: [
            PrivilegedBatchStep(.setAutoproxy, ["Wi-Fi", "", "off"]),
            PrivilegedBatchStep(.setWebProxyEndpoint, ["Wi-Fi", "web", "", "", "off"]),
        ])
        try client.execute(.clearSystemProxy, values: ["Wi-Fi"])

        for script in recorder.scripts {
            XCTAssertTrue(
                script.hasPrefix("set -e\n"),
                "a multi-command privileged script that ignores every status but the last cannot report a failure: \(script)"
            )
        }
    }

    /// `AppleScriptPrivilegeClient` is the default `privilegeClient` for
    /// `SystemProxyManager`, and these two operations interpolate `state` into
    /// a script that runs as root. The helper-client path validated first; this
    /// one validated nothing, so it was the unguarded way in.
    func testAppleScriptRendererValidatesTheArgumentsItInterpolatesAsRoot() {
        let client = AppleScriptPrivilegeClient()

        XCTAssertThrowsError(
            try client.shellScript(for: .setWebProxyEndpoint, values: ["Wi-Fi", "web", "", "", "off; touch /tmp/pwned"])
        )
        XCTAssertThrowsError(
            try client.shellScript(for: .setAutoproxy, values: ["Wi-Fi", "", "off && curl evil.example"])
        )
        XCTAssertThrowsError(
            try client.shellScript(for: .setWebProxyEndpoint, values: ["Wi-Fi", "sideways", "", "", "off"])
        )
        XCTAssertThrowsError(
            try client.shellScript(for: .setWebProxyEndpoint, values: ["Wi-Fi", "web", "old.example", "0", "on"])
        )
        XCTAssertThrowsError(
            try client.shellScript(for: .setAutoproxy, values: ["Wi-Fi", "file:///etc/passwd", "on"])
        )

        // The forms restore actually renders still pass.
        XCTAssertNoThrow(try client.shellScript(for: .setWebProxyEndpoint, values: ["Wi-Fi", "web", "Empty", "", "off"]))
        XCTAssertNoThrow(try client.shellScript(for: .setAutoproxy, values: ["Wi-Fi", "http://mdm.corp.example/a.pac", "off"]))
    }

    // MARK: - Install from Settings (#121)

    /// A stub app whose `install-helper.sh` records its arguments and prints
    /// what the real one prints last. The rendered script runs for real,
    /// unprivileged, so its argument passing and output routing are what is
    /// tested, not its text.
    private func makeStubApp(installer: String) throws -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("helper-install-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try FileManager.default.removeItem(at: root) }
        // A space and a quote, so quoting is exercised.
        let app = root.appendingPathComponent("Some Where/It's Conduit.app", isDirectory: true)
        let resources = app.appendingPathComponent("Contents/Resources", isDirectory: true)
        let services = app.appendingPathComponent("Contents/Library/LaunchServices", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: services, withIntermediateDirectories: true)
        try Data().write(to: services.appendingPathComponent(HelperConstants.serviceLabel))
        try installer.write(to: resources.appendingPathComponent("install-helper.sh"), atomically: true, encoding: .utf8)
        return app.path
    }

    private func runUnprivileged(_ script: String) throws -> CommandResult {
        try CommandRunner.run(launchPath: "/bin/sh", arguments: ["-c", script])
    }

    func testSettingsInstallRunsTheBundledInstallerForTheRunningApp() throws {
        let app = try makeStubApp(installer: """
        printf 'arg=%s\\n' "$@"
        echo "Privileged helper installed successfully."
        echo "caller-policy: enforced"
        """)
        let runner = RecordingPrivilegedScriptRunner()
        runner.execute = { try self.runUnprivileged($0) }
        let client = HelperToolPrivilegeClient(fallback: AppleScriptPrivilegeClient(runner: runner.run))

        XCTAssertEqual(try client.installHelper(bundlePath: app), .enforced)
        XCTAssertEqual(runner.scripts.count, 1, "one script, so one admin prompt")
        let output = try runUnprivileged(runner.scripts[0]).standardOutput
        XCTAssertEqual(
            output.split(separator: "\n").filter { $0.hasPrefix("arg=") },
            ["arg=--source", "arg=installed", "arg=--app", "arg=\(app)"],
            "the installer is told to install from and pin to the running app"
        )
    }

    func testSettingsInstallFailureCarriesTheInstallersReason() throws {
        let app = try makeStubApp(installer: """
        echo "The derived caller requirement does not accept this app; refusing to install a pin that would lock it out"
        exit 1
        """)
        let runner = RecordingPrivilegedScriptRunner()
        runner.execute = { try self.runUnprivileged($0) }
        let client = HelperToolPrivilegeClient(fallback: AppleScriptPrivilegeClient(runner: runner.run))

        XCTAssertThrowsError(try client.installHelper(bundlePath: app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("would lock it out"), "\(error.localizedDescription)")
        }
        let result = try runUnprivileged(runner.scripts[0])
        XCTAssertEqual(result.exitCode, 1)
        XCTAssertTrue(result.standardError.contains("would lock it out"), "a failure's output goes to stderr, where osascript reports it")
        XCTAssertEqual(result.standardOutput, "")
    }

    func testSettingsInstallWithoutAPolicyLineIsAnError() throws {
        let app = try makeStubApp(installer: "echo done")
        let runner = RecordingPrivilegedScriptRunner()
        runner.execute = { try self.runUnprivileged($0) }
        let client = HelperToolPrivilegeClient(fallback: AppleScriptPrivilegeClient(runner: runner.run))

        XCTAssertThrowsError(try client.installHelper(bundlePath: app)) { error in
            XCTAssertTrue(error.localizedDescription.contains("caller policy"), "\(error.localizedDescription)")
        }
    }

    func testSettingsInstallOutsideAnAppBundleNamesWhatIsMissing() throws {
        let runner = RecordingPrivilegedScriptRunner()
        let client = HelperToolPrivilegeClient(fallback: AppleScriptPrivilegeClient(runner: runner.run))
        let notAnApp = FileManager.default.temporaryDirectory.appendingPathComponent("not-an-app-\(UUID().uuidString)").path

        XCTAssertThrowsError(try client.installHelper(bundlePath: notAnApp)) { error in
            XCTAssertEqual(error as? HelperInstallerError, .notBundled(notAnApp + "/Contents/Resources/install-helper.sh"))
        }
        XCTAssertTrue(runner.scripts.isEmpty, "no admin prompt for an install that cannot work")
    }

    func testCallerPolicyIsReadFromTheInstallersLastPolicyLine() {
        XCTAssertEqual(HelperToolPrivilegeClient.callerPolicy(fromInstallerOutput: "a\rcaller-policy: unenforced\r"), .unenforced)
        XCTAssertEqual(HelperToolPrivilegeClient.callerPolicy(fromInstallerOutput: "caller-policy: enforced\ncaller-policy: unchanged"), .unchanged)
        XCTAssertNil(HelperToolPrivilegeClient.callerPolicy(fromInstallerOutput: "caller-policy: maybe"))
        XCTAssertNil(HelperToolPrivilegeClient.callerPolicy(fromInstallerOutput: ""))
    }

    /// A removal that fails stops the uninstall with that failure, rather
    /// than a later step's success standing for the whole. Every command the
    /// script runs is a stub on a PATH of its own, so nothing is removed.
    func testUninstallStopsAtTheFirstFailedRemoval() throws {
        let stubs = FileManager.default.temporaryDirectory.appendingPathComponent("uninstall-stubs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stubs, withIntermediateDirectories: true)
        addTeardownBlock { try FileManager.default.removeItem(at: stubs) }
        let log = stubs.appendingPathComponent("calls").path
        func stub(_ name: String, _ body: String) throws {
            let url = stubs.appendingPathComponent(name)
            try "#!/bin/sh\necho \"\(name) $*\" >> '\(log)'\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try stub("launchctl", "exit 0")
        try stub("rmdir", "exit 0")
        try stub("rm", "exit 1")

        let result = try CommandRunner.run(
            launchPath: "/bin/sh",
            arguments: ["-c", "PATH=\(stubs.path.shellQuoted)\n" + HelperToolPrivilegeClient.uninstallScript]
        )
        let calls = try String(contentsOfFile: log, encoding: .utf8).split(separator: "\n")

        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertEqual(calls.count, 2, "bootout, then the first rm, and nothing after it: \(calls)")
        XCTAssertTrue(calls.last?.hasPrefix("rm -f \(HelperConstants.binaryInstallPath)") ?? false, "\(calls)")
    }

    /// It used to be `try?`: a dismissed password prompt read as uninstalled.
    func testUninstallFailureIsThrown() {
        let runner = RecordingPrivilegedScriptRunner()
        runner.result = CommandResult(exitCode: 1, standardOutput: "", standardError: "User canceled. (-128)")
        let client = HelperToolPrivilegeClient(fallback: AppleScriptPrivilegeClient(runner: runner.run))

        XCTAssertThrowsError(try client.uninstallHelper()) { error in
            XCTAssertTrue(error.localizedDescription.contains("User canceled"), "\(error.localizedDescription)")
        }
    }
}

/// Stands in for the real elevation, which raises a password prompt and so can
/// never run under test.
private final class RecordingPrivilegedScriptRunner: @unchecked Sendable {
    private(set) var scripts: [String] = []
    var result = CommandResult(exitCode: 0, standardOutput: "", standardError: "")
    /// Runs the script instead of answering with `result`.
    var execute: ((String) throws -> CommandResult)?

    func run(_ script: String) throws -> CommandResult {
        scripts.append(script)
        return try execute?(script) ?? result
    }
}
