// SPDX-License-Identifier: Apache-2.0
import Foundation
import NIOConcurrencyHelpers
import Security
import XCTest
@testable import PlatformMac
@testable import ProxyAuth
@testable import ProxyKernel

/// Issue #98. The NTLM fallback read the Keychain on every handshake (1,248
/// reads in two bursts on one day) and swallowed a failed read with `try?`.
/// `CredentialManager` now reads the store once per invalidation, and the
/// factory reports a failed read as `auth.credentials_unavailable`.
final class NTLMCredentialCacheTests: XCTestCase {
    /// Kerberos with no ticket, which `NegotiateAuthenticator` answers with
    /// the NTLM fallback.
    private final class NoTicket: GSSTokenProvider, @unchecked Sendable {
        func generateToken(host: String, inputToken: Data?) throws -> Data? { throw KerberosAuthError.noTicket }
        func resetContext() {}
    }

    private final class Clock: @unchecked Sendable {
        private let box = NIOLockedValueBox(Date(timeIntervalSince1970: 1_800_000_000))
        var now: Date { box.withLockedValue { $0 } }
        func advance(_ seconds: TimeInterval) { box.withLockedValue { $0 += seconds } }
    }

    private let upstream = UpstreamProxy(name: "corp", host: "proxy.example.test", port: 3128, priority: 0)
    private let savedHash = SecretBytes(Array(repeating: UInt8(7), count: 16))

    private func makeConfig(authMode: AuthenticationMode = .systemNegotiated, username: String = "user") -> ProxyConfig {
        var config = GenericDefaults.shared.makeConfig()
        config.profileName = "Cache"
        config.username = username
        config.domain = "DOMAIN"
        config.authMode = authMode
        config.upstreams = [upstream]
        return config
    }

    private struct Fixture {
        let store: InMemorySecretStore
        let manager: CredentialManager
        let config: NIOLockedValueBox<ProxyConfig>
        let events: RuntimeEventLog
        let clock: Clock
        let factory: @Sendable (UpstreamProxy) throws -> ProxyAuthenticator

        var unavailable: [RuntimeEvent] { events.events.filter { $0.event == "auth.credentials_unavailable" } }
    }

    private func makeFixture(
        authMode: AuthenticationMode = .systemNegotiated,
        saved: Bool = true,
        pendingReadWait: TimeInterval = 2
    ) throws -> Fixture {
        let store = InMemorySecretStore()
        let clock = Clock()
        let config = NIOLockedValueBox(makeConfig(authMode: authMode))
        let manager = CredentialManager(
            identityProvider: {
                let c = config.withLockedValue { $0 }
                return (domain: c.domain, username: c.username, profileName: c.profileName)
            },
            store: store,
            pendingReadWait: pendingReadWait,
            now: { clock.now }
        )
        if saved { try manager.saveHash(savedHash, for: config.withLockedValue { $0 }) }
        let events = RuntimeEventLog(capacity: 64)
        let factory = credentialBasedAuthenticatorProvider(
            configProvider: { config.withLockedValue { $0 } },
            credentialProvider: manager,
            eventSink: { events.append($0) },
            kerberosTokenProvider: { NoTicket() },
            now: { clock.now }
        )
        return Fixture(store: store, manager: manager, config: config, events: events, clock: clock, factory: factory)
    }

    /// One handshake that falls back to NTLM; its first token names the scheme.
    private func fallbackToken(_ fixture: Fixture) throws -> String {
        try fixture.factory(upstream).initialToken(for: upstream.host)
    }

    func testConcurrentFallbacksReadTheStoreOnce() throws {
        let fixture = try makeFixture()
        // Long enough that every handshake arrives while the first read is
        // still out, as a burst does behind a Keychain prompt.
        fixture.store.loadDelay = 0.2
        let tokens = NIOLockedValueBox<[String]>([])
        let failures = NIOLockedValueBox(0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            do {
                let token = try fallbackToken(fixture)
                tokens.withLockedValue { $0.append(token) }
            } catch {
                failures.withLockedValue { $0 += 1 }
            }
        }
        XCTAssertEqual(failures.withLockedValue { $0 }, 0)
        XCTAssertEqual(tokens.withLockedValue { $0 }.count, 16)
        XCTAssertTrue(tokens.withLockedValue { $0 }.allSatisfy { $0.hasPrefix("NTLM ") })
        XCTAssertEqual(fixture.store.loads, 1)

        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 1, "a later handshake must use the cached credential")
    }

    /// Review of #105: a read sitting on a Keychain prompt nobody answers
    /// must not hold every handshake that needs the password. Each waits at
    /// most the bound, goes without NTLM, and none starts a second read.
    func testHandshakesWaitingOnAnUnansweredPromptGiveUpAtTheBound() throws {
        let fixture = try makeFixture(pendingReadWait: 0.2)
        fixture.store.holdLoads()
        // Safety net: without the bound the handshakes below would never
        // return; release late so a regression fails instead of hanging.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) { fixture.store.releaseLoads() }

        let answers = NIOLockedValueBox<[String]>([])
        let longestWait = NIOLockedValueBox<TimeInterval>(0)
        DispatchQueue.concurrentPerform(iterations: 16) { _ in
            // Timed per call: how many run at once depends on the runner's
            // cores; how long each one waits must not.
            let started = Date()
            do {
                let token = try fallbackToken(fixture)
                answers.withLockedValue { $0.append(token) }
            } catch is KerberosAuthError {
                answers.withLockedValue { $0.append("no-ntlm") }
            } catch {
                answers.withLockedValue { $0.append("unexpected: \(error)") }
            }
            let waited = Date().timeIntervalSince(started)
            longestWait.withLockedValue { $0 = max($0, waited) }
        }

        XCTAssertLessThan(longestWait.withLockedValue { $0 }, 2, "every handshake returns within the bound, not when the prompt is answered")
        XCTAssertEqual(answers.withLockedValue { $0 }, Array(repeating: "no-ntlm", count: 16))
        XCTAssertLessThanOrEqual(fixture.store.loads, 1, "no handshake starts a second read while one is out")
        XCTAssertEqual(fixture.unavailable.map(\.detail), ["host=proxy.example.test:3128 reason=read_pending source=handshake suppressed=0"])

        fixture.store.releaseLoads()
        // The released read lands on its own queue; a handshake that comes
        // before it does waits the bound again, so poll rather than time it.
        var answered: String?
        for _ in 0..<50 where answered == nil {
            answered = try? fallbackToken(fixture)
        }
        XCTAssertEqual(answered.map { $0.hasPrefix("NTLM ") }, true, "the answered read serves the next handshake")
        XCTAssertEqual(fixture.store.loads, 1, "the one read that was out is the one that answered")
        XCTAssertEqual(fixture.unavailable.count, 1, "waiting again is still one event per interval")
    }

    func testSaveAndClearInvalidateTheCache() throws {
        let fixture = try makeFixture()
        _ = try fallbackToken(fixture)
        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 1)

        try fixture.manager.saveHash(SecretBytes(Array(repeating: UInt8(9), count: 16)), for: fixture.config.withLockedValue { $0 })
        _ = try fallbackToken(fixture)
        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 2, "a save must be read back once")

        try fixture.manager.clear(for: fixture.config.withLockedValue { $0 })
        XCTAssertThrowsError(try fallbackToken(fixture), "no password, so Kerberos' failure stands")
        XCTAssertThrowsError(try fallbackToken(fixture))
        XCTAssertEqual(fixture.store.loads, 3, "a clear must be read back once, and the empty answer cached")
        XCTAssertTrue(fixture.unavailable.isEmpty, "no saved password is not a store failure")
    }

    func testIdentityChangeReadsTheNewIdentity() throws {
        let fixture = try makeFixture()
        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 1)
        fixture.config.withLockedValue { $0.username = "other" }
        XCTAssertThrowsError(try fallbackToken(fixture), "the other identity has no password saved")
        XCTAssertEqual(fixture.store.loads, 2)
        fixture.config.withLockedValue { $0.username = "user" }
        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 3, "the cache holds one identity")
    }

    func testFailingStoreReportsOncePerIntervalAndNeverCrashesTheHandshake() throws {
        let fixture = try makeFixture()
        fixture.store.loadFailure = KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed)
        for _ in 0..<10 {
            XCTAssertThrowsError(try fallbackToken(fixture)) { error in
                XCTAssertTrue(error is KerberosAuthError, "no NTLM answer, so Kerberos' own failure goes out: \(error)")
            }
        }
        XCTAssertEqual(fixture.unavailable.count, 1)
        XCTAssertEqual(fixture.unavailable.first?.kind, .auth)
        XCTAssertEqual(fixture.unavailable.first?.detail, "host=proxy.example.test:3128 reason=interaction_not_allowed source=handshake suppressed=0")
        XCTAssertEqual(fixture.store.loads, 1, "a failure is held too, so a burst makes one read")

        fixture.clock.advance(61)
        XCTAssertThrowsError(try fallbackToken(fixture))
        XCTAssertThrowsError(try fallbackToken(fixture))
        XCTAssertEqual(fixture.unavailable.count, 2)
        XCTAssertEqual(fixture.store.loads, 2, "a failure that may clear by itself is retried after the interval")

        fixture.store.loadFailure = nil
        fixture.clock.advance(61)
        XCTAssertTrue(try fallbackToken(fixture).hasPrefix("NTLM "))
        XCTAssertEqual(fixture.unavailable.count, 2)
    }

    func testDeniedAccessIsNotAskedAgainUntilTheUserActs() throws {
        let fixture = try makeFixture()
        fixture.store.loadFailure = KeychainStoreError.unexpectedStatus(errSecAuthFailed)
        XCTAssertThrowsError(try fallbackToken(fixture))
        fixture.clock.advance(3_600)
        XCTAssertThrowsError(try fallbackToken(fixture))
        XCTAssertEqual(fixture.store.loads, 1, "a refused prompt must not come back on its own")
        XCTAssertEqual(fixture.unavailable.map(\.detail), [
            "host=proxy.example.test:3128 reason=denied source=handshake suppressed=0",
            "host=proxy.example.test:3128 reason=denied source=handshake suppressed=0",
        ])

        fixture.store.loadFailure = nil
        try fixture.manager.saveHash(savedHash, for: fixture.config.withLockedValue { $0 })
        XCTAssertTrue(try fallbackToken(fixture).hasPrefix("NTLM "))
        XCTAssertEqual(fixture.store.loads, 2)
    }

    func testDirectNTLMReportsAndRethrowsAStoreFailure() throws {
        let fixture = try makeFixture(authMode: .ntlmv2)
        fixture.store.loadFailure = KeychainStoreError.invalidData
        XCTAssertThrowsError(try fixture.factory(upstream))
        XCTAssertThrowsError(try fixture.factory(upstream))
        XCTAssertEqual(fixture.unavailable.map(\.detail), ["host=proxy.example.test:3128 reason=invalid_payload source=handshake suppressed=0"])
        XCTAssertEqual(fixture.store.loads, 1)
    }

    func testDirectNTLMUsesTheCache() throws {
        let fixture = try makeFixture(authMode: .ntlmv2)
        for _ in 0..<5 { XCTAssertEqual(try fixture.factory(upstream).scheme, "NTLM") }
        XCTAssertEqual(fixture.store.loads, 1)
    }

    func testRejectedCredentialsAreReadAgainAtMostOncePerInterval() throws {
        let fixture = try makeFixture(authMode: .ntlmv2)
        let first = try fixture.factory(upstream)
        first.credentialsRejected(host: upstream.host)
        let second = try fixture.factory(upstream)
        XCTAssertEqual(fixture.store.loads, 2, "a 407 on the authenticate leg drops the cached credential")
        XCTAssertEqual(fixture.events.events.filter { $0.event == "auth.credentials_dropped" }.map(\.detail),
                       ["host=proxy.example.test:3128 reason=rejected"])

        second.credentialsRejected(host: upstream.host)
        _ = try fixture.factory(upstream)
        XCTAssertEqual(fixture.store.loads, 2, "a wrong password must not turn every request into a read")

        fixture.clock.advance(61)
        (try fixture.factory(upstream)).credentialsRejected(host: upstream.host)
        _ = try fixture.factory(upstream)
        XCTAssertEqual(fixture.store.loads, 3)
    }

    func testRejectionOfTheNTLMFallbackDropsTheCache() throws {
        let fixture = try makeFixture()
        let authenticator = try fixture.factory(upstream)
        XCTAssertTrue(try authenticator.initialToken(for: upstream.host).hasPrefix("NTLM "))
        authenticator.credentialsRejected(host: upstream.host)
        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 2)
    }

    func testWarmReadsOnceWhenAPasswordIsSaved() throws {
        let fixture = try makeFixture()
        fixture.manager.warmCache(eventSink: { fixture.events.append($0) })
        XCTAssertEqual(fixture.store.loads, 1)
        _ = try fallbackToken(fixture)
        XCTAssertEqual(fixture.store.loads, 1, "the handshake uses what the start read")
        fixture.manager.warmCache(eventSink: { fixture.events.append($0) })
        XCTAssertEqual(fixture.store.loads, 2, "each proxy start reads afresh")
    }

    func testWarmDoesNotReadWithoutASavedPassword() throws {
        let fixture = try makeFixture(saved: false)
        fixture.manager.warmCache(eventSink: { fixture.events.append($0) })
        XCTAssertEqual(fixture.store.loads, 0)
    }

    func testWarmReportsAFailedRead() throws {
        let fixture = try makeFixture()
        fixture.store.loadFailure = KeychainStoreError.unexpectedStatus(errSecUserCanceled)
        fixture.manager.warmCache(eventSink: { fixture.events.append($0) })
        XCTAssertEqual(fixture.unavailable.map(\.detail), ["reason=denied source=proxy_start"])
    }

    func testKeychainStatusesMapToEventReasons() {
        let cases: [(any Error, String)] = [
            (KeychainStoreError.unexpectedStatus(errSecItemNotFound), "not_found"),
            (KeychainStoreError.unexpectedStatus(errSecUserCanceled), "denied"),
            (KeychainStoreError.unexpectedStatus(errSecAuthFailed), "denied"),
            (KeychainStoreError.unexpectedStatus(errSecInteractionNotAllowed), "interaction_not_allowed"),
            (KeychainStoreError.unexpectedStatus(errSecDuplicateItem), "status=-25299"),
            (KeychainStoreError.invalidData, "invalid_payload"),
            (CredentialManagerError.invalidPayload, "invalid_payload"),
            (CredentialManagerError.missingCredentials, "not_found"),
            (URLError(.badURL), "other"),
        ]
        for (error, reason) in cases {
            XCTAssertEqual(error.credentialReadFailureReason, reason, "\(error)")
        }
    }
}
