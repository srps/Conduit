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
}
