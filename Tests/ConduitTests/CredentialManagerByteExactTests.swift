// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import XCTest
@testable import PlatformMac
@testable import ProxyKernel

/// #246: the cached credential belongs to one Keychain account, and the account is the identity's bytes. A respelled identity (see
/// `Respelled`) is read from the store under its own account, never answered from the other spelling's cache.
final class CredentialManagerByteExactTests: XCTestCase {

    private let upstream = UpstreamProxy(name: "Synthetic", host: "proxy.example.test", port: 3128, priority: 0)

    private static func account(_ username: String) -> String { "CORP|\(username)|Office" }

    func testARespelledIdentityReadsItsOwnAccount() throws {
        let identity = NIOLockedValueBox<CredentialManager.Identity>(
            (domain: "CORP", username: Respelled.composed, profileName: "Office"))
        let store = LastLoadSecretStore()
        let manager = CredentialManager(identityProvider: { identity.withLockedValue { $0 } }, store: store)

        _ = try manager.credentials(for: upstream)
        XCTAssertEqual(store.loadCount, 1)

        identity.withLockedValue { $0.username = Respelled.decomposed }
        _ = try manager.credentials(for: upstream)

        XCTAssertEqual(store.loadCount, 2, "the respelled identity is another account")
        XCTAssertEqual(store.lastLoadedAccountUTF8, Array(Self.account(Respelled.decomposed).utf8))
    }

    /// The identity is respelled while the old account's read is held, as behind a Keychain prompt. Once released, the old read's
    /// late answer does not stand for the new account: the new account is read under its own bytes and answers with its own entry.
    func testARespellingWhileTheOldReadIsHeldReadsTheNewAccountAfterTheRelease() throws {
        Respelled.assertRespelling(Self.account(Respelled.composed), Self.account(Respelled.decomposed))
        let identity = NIOLockedValueBox<CredentialManager.Identity>(
            (domain: "CORP", username: Respelled.composed, profileName: "Office"))
        let saved = try ProxyCredentials(
            username: Respelled.decomposed, domain: "CORP", workstation: "", ntHash: SecretBytes(Array(repeating: UInt8(7), count: 16))
        ).keychainData()
        // Only the respelled account has an entry; the old one answers none.
        let store = LastLoadSecretStore(entry: (account: Array(Self.account(Respelled.decomposed).utf8), secret: saved))
        let manager = CredentialManager(
            identityProvider: { identity.withLockedValue { $0 } }, store: store, pendingReadWait: 0.05)

        store.holdLoads()
        XCTAssertThrowsError(try manager.credentials(for: upstream), "the old account's read is held") {
            XCTAssertTrue($0 is CredentialReadPending, "\($0)")
        }
        identity.withLockedValue { $0.username = Respelled.decomposed }
        store.releaseLoads()

        var answer: ProxyCredentials?
        for _ in 0..<100 {
            do {
                answer = try manager.credentials(for: upstream)
                break
            } catch is CredentialReadPending {
                continue
            }
        }

        XCTAssertEqual(store.loadCount, 2, "the respelled account is read after the old read lands")
        XCTAssertEqual(store.lastLoadedAccountUTF8, Array(Self.account(Respelled.decomposed).utf8))
        XCTAssertEqual(answer.map { Array($0.username.utf8) }, Array(Respelled.decomposed.utf8),
                       "the answer is the respelled account's entry, not the old account's late none")
    }
}

/// A store with at most one entry, keyed by the account's UTF-8, that keeps the load count and the UTF-8 of the last account loaded.
/// `holdLoads()` blocks every load until `releaseLoads()`, as a read behind an unanswered Keychain prompt does.
private final class LastLoadSecretStore: SecretStore, @unchecked Sendable {
    private let condition = NSCondition()
    private let entry: (account: [UInt8], secret: SecretBytes)?
    private var count = 0
    private var last: [UInt8]?
    private var held = false

    init(entry: (account: [UInt8], secret: SecretBytes)? = nil) {
        self.entry = entry
    }

    var loadCount: Int { condition.withLock { count } }
    var lastLoadedAccountUTF8: [UInt8]? { condition.withLock { last } }

    func holdLoads() { condition.withLock { held = true } }

    func releaseLoads() {
        condition.withLock {
            held = false
            condition.broadcast()
        }
    }

    func save(secret: SecretBytes, account: String) throws {
        throw UnplannedFakeEffect(effect: "credential save")
    }

    func load(account: String) throws -> SecretBytes? {
        condition.lock()
        defer { condition.unlock() }
        count += 1
        last = Array(account.utf8)
        while held { condition.wait() }
        guard let entry, entry.account == Array(account.utf8) else { return nil }
        return entry.secret
    }

    func exists(account: String) throws -> Bool {
        guard let entry else { return false }
        return entry.account == Array(account.utf8)
    }

    func delete(account: String) throws {
        throw UnplannedFakeEffect(effect: "credential delete")
    }
}
