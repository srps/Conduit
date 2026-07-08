// SPDX-License-Identifier: Apache-2.0
import Foundation
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

final class ActivationPreflightTests: XCTestCase {

    // MARK: - IntegrationStatus

    func testDisabledIntegrationNeverNeedsChange() {
        let status = IntegrationStatus.disabled
        XCTAssertFalse(status.needsChange)
        XCTAssertFalse(status.willPromptAdmin)
    }

    func testEnabledAlreadyAppliedDoesNotNeedChange() {
        let status = IntegrationStatus(enabled: true, alreadyApplied: true, privilegeLevel: .requiresAdmin)
        XCTAssertFalse(status.needsChange)
        XCTAssertFalse(status.willPromptAdmin)
    }

    func testEnabledNotAppliedNoPrivilegeNeedsChangeButNoPrompt() {
        let status = IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .none)
        XCTAssertTrue(status.needsChange)
        XCTAssertFalse(status.willPromptAdmin)
    }

    func testEnabledNotAppliedMayRequireAdminWillPrompt() {
        let status = IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .mayRequireAdmin)
        XCTAssertTrue(status.needsChange)
        XCTAssertTrue(status.willPromptAdmin)
    }

    func testEnabledNotAppliedRequiresAdminWillPrompt() {
        let status = IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .requiresAdmin)
        XCTAssertTrue(status.needsChange)
        XCTAssertTrue(status.willPromptAdmin)
    }

    // MARK: - ActivationPreflight

    func testNoAdminPreflightDoesNotRequireAdmin() {
        let preflight = ActivationPreflight.noAdmin
        XCTAssertFalse(preflight.requiresAdmin)
        XCTAssertEqual(preflight.summary, "")
    }

    func testPreflightRequiresAdminWhenSystemProxyWillPrompt() {
        let preflight = ActivationPreflight(
            systemProxy: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .mayRequireAdmin),
            environmentVariables: .disabled,
            splitDNS: .disabled
        )
        XCTAssertTrue(preflight.requiresAdmin)
        XCTAssertTrue(preflight.summary.contains("system proxy"))
        XCTAssertFalse(preflight.summary.contains("DNS"))
    }

    func testPreflightRequiresAdminWhenDNSWillPrompt() {
        let preflight = ActivationPreflight(
            systemProxy: .disabled,
            environmentVariables: .disabled,
            splitDNS: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .requiresAdmin)
        )
        XCTAssertTrue(preflight.requiresAdmin)
        XCTAssertTrue(preflight.summary.contains("DNS"))
        XCTAssertFalse(preflight.summary.contains("system proxy"))
    }

    func testPreflightRequiresAdminWhenBothWillPrompt() {
        let preflight = ActivationPreflight(
            systemProxy: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .mayRequireAdmin),
            environmentVariables: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .none),
            splitDNS: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .requiresAdmin)
        )
        XCTAssertTrue(preflight.requiresAdmin)
        XCTAssertTrue(preflight.summary.contains("system proxy"))
        XCTAssertTrue(preflight.summary.contains("DNS"))
    }

    func testPreflightNoAdminWhenAllAlreadyApplied() {
        let preflight = ActivationPreflight(
            systemProxy: IntegrationStatus(enabled: true, alreadyApplied: true, privilegeLevel: .mayRequireAdmin),
            environmentVariables: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .none),
            splitDNS: IntegrationStatus(enabled: true, alreadyApplied: true, privilegeLevel: .requiresAdmin)
        )
        XCTAssertFalse(preflight.requiresAdmin)
        XCTAssertEqual(preflight.summary, "")
    }

    func testPreflightNoAdminWhenOnlyEnvEnabled() {
        let preflight = ActivationPreflight(
            systemProxy: .disabled,
            environmentVariables: IntegrationStatus(enabled: true, alreadyApplied: false, privilegeLevel: .none),
            splitDNS: .disabled
        )
        XCTAssertFalse(preflight.requiresAdmin)
    }

    func testPreflightEquatable() {
        let a = ActivationPreflight.noAdmin
        let b = ActivationPreflight(
            systemProxy: .disabled,
            environmentVariables: .disabled,
            splitDNS: .disabled
        )
        XCTAssertEqual(a, b)
    }

    // MARK: - PrivilegeLevel

    func testPrivilegeLevelEquality() {
        XCTAssertEqual(PrivilegeLevel.none, PrivilegeLevel.none)
        XCTAssertNotEqual(PrivilegeLevel.none, PrivilegeLevel.requiresAdmin)
        XCTAssertNotEqual(PrivilegeLevel.mayRequireAdmin, PrivilegeLevel.requiresAdmin)
    }

    // MARK: - Evaluator VPN gating

    /// Split-DNS entry files are withheld while the VPN is down (see
    /// `SplitDNSVPNGate`); the evaluator must count that deferral as
    /// "already applied" or the UI shows a spurious admin-prompt hint.
    func testEvaluatorTreatsVPNDeferredEntryFilesAsApplied() {
        var config = ProxyConfig.testFixture()
        config.dnsEntries = [
            DomainDNSEntry(domain: "preflight-gate-test.example", servers: ["10.9.9.9"])
        ]
        let platformConfig = PlatformIntegrationConfig(manageDNSResolvers: true)
        let client = NoopPrivilegeClient()

        func evaluate(vpnConnected: Bool) -> ActivationPreflight {
            ActivationPreflightEvaluator.evaluate(
                config: config,
                platformConfig: platformConfig,
                isRunning: false,
                helperStatus: .notInstalled,
                systemConduit: SystemProxyManager(privilegeClient: client),
                dnsManager: DNSManager(privilegeClient: client),
                vpnConnected: vpnConnected
            )
        }

        let vpnDown = evaluate(vpnConnected: false)
        XCTAssertTrue(vpnDown.splitDNS.alreadyApplied, "deferred entry files must count as applied")
        XCTAssertFalse(vpnDown.requiresAdmin, "no admin hint while the files are intentionally withheld")

        let vpnUp = evaluate(vpnConnected: true)
        XCTAssertFalse(vpnUp.splitDNS.alreadyApplied, "missing entry files with the VPN up do need applying")
        XCTAssertTrue(vpnUp.requiresAdmin, "no helper installed, so applying them will prompt")
    }
}

private final class NoopPrivilegeClient: PrivilegeClient, @unchecked Sendable {
    func execute(_ operation: PrivilegedOperation, values: [String]) throws {}
}
