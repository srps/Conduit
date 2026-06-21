// SPDX-License-Identifier: Apache-2.0
import Foundation
import Security
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// Tests verifying keychain store error handling and credential manager behavior.
/// Note: Actual keychain operations may require entitlements; these tests
/// verify error handling and the credential manager logic.
final class KeychainAccessTests: XCTestCase {

    func testKeychainStoreErrorDescriptions() {
        let errors: [KeychainStoreError] = [
            .unexpectedStatus(errSecAuthFailed),
            .invalidData
        ]
        for error in errors {
            XCTAssertNotNil(error.errorDescription)
            XCTAssertFalse(error.errorDescription!.isEmpty)
        }
    }

    func testKeychainStoreUsesAfterFirstUnlockThisDeviceOnly() {
        XCTAssertEqual(
            KeychainStore.accessibleAttribute as String,
            kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String
        )
    }

    func testCredentialManagerErrorDescription() {
        let error = CredentialManagerError.missingCredentials
        XCTAssertNotNil(error.errorDescription)
    }

    func testCredentialManagerAccountKeyIsUnique() throws {
        var config1 = ProxyConfig.testFixture()
        config1.username = "user1"
        config1.domain = "DOMAIN1"

        var config2 = ProxyConfig.testFixture()
        config2.username = "user2"
        config2.domain = "DOMAIN2"

        // CredentialManager now requires an identityProvider closure
        // for the protocol-required `credentials(for: UpstreamProxy)` /
        // `setCredentials(_:for:)` methods. The legacy per-config API
        // (`loadCredentials(for:)`, `hasSavedCredentials(for:)`,
        // `clear(for:)`) doesn't depend on the closure, so any identity
        // works for these tests.
        let identity: CredentialManager.Identity = (domain: "test", username: "test", profileName: "test")
        let manager = CredentialManager(identityProvider: { identity })
        // Loading for non-existent accounts should throw
        XCTAssertThrowsError(try manager.loadCredentials(for: config1))
        XCTAssertThrowsError(try manager.loadCredentials(for: config2))
    }

    func testMissingCredentialCheckReturnsFalse() {
        let identity: CredentialManager.Identity = (domain: "test", username: "test", profileName: "test")
        let manager = CredentialManager(identityProvider: { identity })
        var config = ProxyConfig.testFixture()
        config.username = "nonexistent-test-user-\(UUID().uuidString)"
        config.domain = "NOSUCHTESTDOMAIN"
        XCTAssertFalse(manager.hasSavedCredentials(for: config))
    }

    func testProxyCredentialsCodableRoundTrip() throws {
        let original = ProxyCredentials(
            username: "testuser",
            domain: "EMEA",
            workstation: "MACBOOK",
            ntHash: SecretBytes.repeating(0x42, count: 16)
        )
        let envelope = try original.keychainData()
        let decoded = try ProxyCredentials(keychainPayload: envelope)
        XCTAssertEqual(decoded.username, original.username)
        XCTAssertEqual(decoded.domain, original.domain)
        XCTAssertEqual(decoded.workstation, original.workstation)
        // SecretBytes is Equatable (constant-time); compares by content.
        XCTAssertEqual(decoded.ntHash, original.ntHash)
    }
}
