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

    func testValidateDomainRejectsInvalid() {
        XCTAssertFalse(HelperInputValidator.validateDomain(""))
        XCTAssertFalse(HelperInputValidator.validateDomain("../../etc/hosts"))
        XCTAssertFalse(HelperInputValidator.validateDomain("-start.com"))
        XCTAssertFalse(HelperInputValidator.validateDomain("has spaces.com"))
        XCTAssertFalse(HelperInputValidator.validateDomain(String(repeating: "a", count: 254)))
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

    // MARK: - HelperBinaryLocator

    func testLocatorReturnsNilWhenNotBundled() {
        // In test context there's no app bundle with the helper embedded
        // so the locator should return nil gracefully
        let path = HelperBinaryLocator.sourcePath
        // Either nil or a valid path; should never crash
        if let path {
            XCTAssertFalse(path.isEmpty)
        }
    }
}
